-- Zella - staff operations and reliability. Safe to run more than once. Database only; nothing here sends anything.
-- Rate limiting, escalation acknowledgement, shift handover, staff offboarding, orphaned-work recovery, setup validation.

-- 1. Rate limiting for public entry points (forms, chat, webhooks). True = allowed.
create table if not exists public.rate_limits (key text not null, window_start timestamptz not null, hits integer not null default 0, primary key (key, window_start));
alter table public.rate_limits enable row level security;
create or replace function public.zella_rate_limit(p_key text, p_max integer, p_window_seconds integer default 60)
returns boolean language plpgsql security definer set search_path = public as $$
declare w timestamptz; h integer;
begin
  w := to_timestamp(floor(extract(epoch from now()) / greatest(p_window_seconds, 1)) * greatest(p_window_seconds, 1));
  insert into public.rate_limits as r (key, window_start, hits) values (left(p_key, 200), w, 1)
    on conflict (key, window_start) do update set hits = r.hits + 1 returning hits into h;
  if random() < 0.01 then delete from public.rate_limits where window_start < now() - interval '1 day'; end if;
  return h <= p_max;
end $$;

-- 2. Escalations must be acknowledged by a person.
alter table public.calls add column if not exists escalation_acknowledged_at timestamptz;
alter table public.calls add column if not exists escalation_acknowledged_by uuid;
alter table public.calls add column if not exists escalation_reminded_at timestamptz;

create or replace function public.zella_acknowledge_escalation(p_call_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_biz uuid;
begin
  select business_id into v_biz from public.calls where id = p_call_id;
  if v_biz is null then return 'not_found'; end if;
  if auth.uid() is not null and not public.zella_is_member(v_biz) then raise exception 'NOT_ALLOWED'; end if;
  update public.calls set escalation_acknowledged_at = now(), escalation_acknowledged_by = auth.uid(),
         assigned_to = coalesce(assigned_to, auth.uid()), updated_at = now()
   where id = p_call_id and escalation_acknowledged_at is null;
  return 'acknowledged';
end $$;

create or replace function public.zella_check_escalation_acks()
returns integer language plpgsql security definer set search_path = public as $$
declare c record; n integer := 0;
begin
  for c in select id, business_id from public.calls
            where needs_human and escalation_resolved_at is null and escalation_acknowledged_at is null
              and escalated_at < now() - interval '10 minutes' and escalated_at > now() - interval '2 days'
              and escalation_reminded_at is null limit 100 loop
    perform public.zella_notify(c.business_id, 'escalation_unacknowledged', 'A call needing a person has not been picked up',
      'This call was passed to the team more than 10 minutes ago and nobody has acknowledged it.', 'critical', 'calls', c.id);
    update public.calls set escalation_reminded_at = now() where id = c.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- 3. Shift handover: move one person's open work to another, with a note.
create table if not exists public.staff_handovers (
  id uuid primary key default gen_random_uuid(), business_id uuid not null, from_user uuid, to_user uuid not null,
  note text, moved jsonb not null default '{}'::jsonb, created_by uuid, created_at timestamptz not null default now());
alter table public.staff_handovers enable row level security;
drop policy if exists staff_handovers_read on public.staff_handovers;
create policy staff_handovers_read on public.staff_handovers for select to authenticated using (public.zella_is_member(business_id));

create or replace function public.zella_move_open_work(p_business_id uuid, p_from uuid, p_to uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a int; b int; c int;
begin
  update public.customers set assigned_to = p_to, updated_at = now()
   where business_id = p_business_id and assigned_to = p_from and lead_stage in ('new','contacted','qualified','quote_sent');
  get diagnostics a = row_count;
  update public.callbacks set assigned_to = p_to, updated_at = now()
   where business_id = p_business_id and assigned_to = p_from and status not in ('completed','done','reached','cancelled','failed');
  get diagnostics b = row_count;
  update public.customer_requests set assigned_to = p_to, updated_at = now()
   where business_id = p_business_id and assigned_to = p_from and status not in ('resolved','closed','cancelled');
  get diagnostics c = row_count;
  return jsonb_build_object('leads', a, 'callbacks', b, 'requests', c);
end $$;

create or replace function public.zella_create_handover(p_business_id uuid, p_to_user uuid, p_note text default null, p_from_user uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_from uuid := coalesce(p_from_user, auth.uid()); v_moved jsonb;
begin
  if auth.uid() is not null and not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if v_from is not null and v_from <> coalesce(auth.uid(), v_from)
     and not exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active' and m.role in ('owner','admin','manager')) then
    raise exception 'NOT_ALLOWED';
  end if;
  if not exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = p_to_user and m.status = 'active') then raise exception 'TARGET_NOT_ACTIVE'; end if;
  v_moved := public.zella_move_open_work(p_business_id, v_from, p_to_user);
  insert into public.staff_handovers (business_id, from_user, to_user, note, moved, created_by) values (p_business_id, v_from, p_to_user, left(p_note, 1000), v_moved, auth.uid());
  perform public.zella_notify(p_business_id, 'shift_handover', 'Work handed over to you',
    coalesce(left(p_note, 300), 'Open leads, callbacks and requests were moved to you.'), 'info', 'inbox', null, p_to_user);
  return v_moved;
end $$;

-- 4. Offboarding: stop a person's access and hand their work on. Never removes the last owner.
create or replace function public.zella_offboard_member(p_business_id uuid, p_user_id uuid, p_reassign_to uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_role text; v_moved jsonb := '{}'::jsonb;
begin
  if auth.uid() is not null and not exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active' and m.role in ('owner','admin')) then
    raise exception 'NOT_ALLOWED';
  end if;
  select role into v_role from public.business_members where business_id = p_business_id and user_id = p_user_id;
  if v_role is null then raise exception 'NOT_A_MEMBER'; end if;
  if v_role = 'owner' and not exists (select 1 from public.business_members m where m.business_id = p_business_id and m.role = 'owner' and m.status = 'active' and m.user_id <> p_user_id) then
    raise exception 'LAST_OWNER';
  end if;
  update public.business_members set status = 'suspended', accepts_work = false where business_id = p_business_id and user_id = p_user_id;
  if p_reassign_to is not null then
    v_moved := public.zella_move_open_work(p_business_id, p_user_id, p_reassign_to);
  else
    update public.customers set assigned_to = null where business_id = p_business_id and assigned_to = p_user_id;
    update public.callbacks set assigned_to = null where business_id = p_business_id and assigned_to = p_user_id and status not in ('completed','done','reached','cancelled','failed');
    update public.customer_requests set assigned_to = null where business_id = p_business_id and assigned_to = p_user_id and status not in ('resolved','closed','cancelled');
  end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (p_business_id, auth.uid(), 'member_offboarded', 'business_member', p_user_id, jsonb_build_object('reassigned_to', p_reassign_to, 'moved', v_moved));
  return v_moved;
end $$;

-- 5. Recover orphaned work (timed): stuck follow-ups go back in the queue, work held by inactive people is released.
create or replace function public.zella_recover_orphaned_work()
returns integer language plpgsql security definer set search_path = public as $$
declare a int; b int; c int; d int; e int;
begin
  update public.followup_tasks set status = 'pending', updated_at = now()
   where status = 'in_progress' and claimed_at < now() - interval '30 minutes' and attempts < max_attempts;
  get diagnostics a = row_count;
  update public.followup_tasks set status = 'failed', outcome = 'stuck', completed_at = now(), updated_at = now()
   where status = 'in_progress' and claimed_at < now() - interval '30 minutes' and attempts >= max_attempts;
  get diagnostics b = row_count;
  update public.customers x set assigned_to = null
   where x.assigned_to is not null and not exists (select 1 from public.business_members m where m.business_id = x.business_id and m.user_id = x.assigned_to and m.status = 'active');
  get diagnostics c = row_count;
  update public.callbacks x set assigned_to = null
   where x.assigned_to is not null and x.status not in ('completed','done','reached','cancelled','failed')
     and not exists (select 1 from public.business_members m where m.business_id = x.business_id and m.user_id = x.assigned_to and m.status = 'active');
  get diagnostics d = row_count;
  update public.customer_requests x set assigned_to = null
   where x.assigned_to is not null and x.status not in ('resolved','closed','cancelled')
     and not exists (select 1 from public.business_members m where m.business_id = x.business_id and m.user_id = x.assigned_to and m.status = 'active');
  get diagnostics e = row_count;
  if a + b > 0 then
    perform public.zella_platform_alert('stuck_followups', 'Follow-up tasks were stuck', (a + b) || ' tasks were claimed but never finished and were reset or failed.', 'warning', null, 'stuck_followups');
  end if;
  return a + b + c + d + e;
end $$;

-- 6. Setup check: what is missing for a business to work properly.
create or replace function public.zella_validate_business_config(p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare b record; v jsonb := '[]'::jsonb;
begin
  if auth.uid() is not null and not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select * into b from public.businesses where id = p_business_id;
  if b.id is null then return jsonb_build_object('ok', false, 'issues', jsonb_build_array('Business not found')); end if;
  if nullif(trim(coalesce(b.timezone, '')), '') is null then v := v || to_jsonb('Set the business time zone'::text); end if;
  if nullif(trim(coalesce(b.phone, '')), '') is null then v := v || to_jsonb('Add the business phone number'::text); end if;
  if nullif(trim(coalesce(b.email, '')), '') is null then v := v || to_jsonb('Add the business email'::text); end if;
  if not exists (select 1 from public.business_phone_numbers n where n.business_id = p_business_id) then v := v || to_jsonb('Connect a phone number for the AI receptionist'::text); end if;
  if not exists (select 1 from public.knowledge_items k where k.business_id = p_business_id) then v := v || to_jsonb('Add answers to the knowledge base'::text); end if;
  if not exists (select 1 from public.business_members m where m.business_id = p_business_id and m.status = 'active' and m.role = 'owner') then v := v || to_jsonb('The business has no active owner'::text); end if;
  if not exists (select 1 from public.business_members m where m.business_id = p_business_id and m.status = 'active' and m.accepts_work) then v := v || to_jsonb('Nobody is set to receive leads and callbacks'::text); end if;
  return jsonb_build_object('ok', jsonb_array_length(v) = 0, 'issues', v);
end $$;

do $$
declare f text;
begin
  foreach f in array array['zella_rate_limit(text,integer,integer)','zella_check_escalation_acks()','zella_recover_orphaned_work()','zella_move_open_work(uuid,uuid,uuid)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
  foreach f in array array['zella_acknowledge_escalation(uuid)','zella_create_handover(uuid,uuid,text,uuid)','zella_offboard_member(uuid,uuid,uuid)','zella_validate_business_config(uuid)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;
