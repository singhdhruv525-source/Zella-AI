-- Zella - callback controls, daily callback digest, contact preferences, customer data export and erasure, call
-- recording access log, tenant-isolation check and two-person approval. Safe to run more than once. Database only.

create or replace function public.zella_has_role(p_business_id uuid, p_roles text[])
returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is null or exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active' and m.role = any (p_roles));
$$;

-- 1. Callback controls: reassign, reschedule, cancel.
create or replace function public.zella_reassign_callback(p_callback_id uuid, p_to_user uuid)
returns text language plpgsql security definer set search_path = public as $$
declare cb record;
begin
  select * into cb from public.callbacks where id = p_callback_id;
  if cb.id is null then return 'not_found'; end if;
  if not public.zella_has_role(cb.business_id, array['owner','admin','manager','staff']) then raise exception 'NOT_ALLOWED'; end if;
  if p_to_user is not null and not exists (select 1 from public.business_members m where m.business_id = cb.business_id and m.user_id = p_to_user and m.status = 'active') then raise exception 'TARGET_NOT_ACTIVE'; end if;
  update public.callbacks set assigned_to = p_to_user, updated_at = now() where id = p_callback_id and status not in ('completed','cancelled');
  if p_to_user is not null then
    perform public.zella_notify(cb.business_id, 'callback', 'A callback was assigned to you', coalesce(cb.summary, 'Please call them back.'), 'info', 'callbacks', cb.id, p_to_user);
  end if;
  return 'reassigned';
end $$;

create or replace function public.zella_reschedule_callback(p_callback_id uuid, p_new_time timestamptz)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare cb record; v_tz text; v_due timestamptz;
begin
  select * into cb from public.callbacks where id = p_callback_id;
  if cb.id is null then raise exception 'NOT_FOUND'; end if;
  if not public.zella_has_role(cb.business_id, array['owner','admin','manager','staff']) then raise exception 'NOT_ALLOWED'; end if;
  select coalesce(timezone, 'America/New_York') into v_tz from public.businesses where id = cb.business_id;
  v_due := public.zella_next_call_time(greatest(p_new_time, now()), v_tz);
  update public.callbacks set due_at = v_due, preferred_at = p_new_time, status = 'scheduled', locked_at = null, overdue_notified_at = null, overdue_escalated_at = null, updated_at = now()
   where id = p_callback_id and status not in ('completed','cancelled');
  return v_due;
end $$;

create or replace function public.zella_cancel_callback(p_callback_id uuid, p_reason text default null)
returns text language plpgsql security definer set search_path = public as $$
declare cb record;
begin
  select * into cb from public.callbacks where id = p_callback_id;
  if cb.id is null then return 'not_found'; end if;
  if not public.zella_has_role(cb.business_id, array['owner','admin','manager','staff']) then raise exception 'NOT_ALLOWED'; end if;
  update public.callbacks set status = 'cancelled', note = coalesce(left(p_reason, 500), note), updated_at = now() where id = p_callback_id and status not in ('completed','cancelled');
  return 'cancelled';
end $$;

-- 2. Daily callback digest: at 8 in the morning (business time), tell the owners what is open and overdue. Once a day.
create or replace function public.zella_post_callback_digests()
returns integer language plpgsql security definer set search_path = public as $$
declare b record; v_open int; v_over int; n int := 0;
begin
  for b in select id, coalesce(timezone, 'America/New_York') tz from public.businesses where suspended_at is null and cancelled_at is null loop
    continue when extract(hour from now() at time zone b.tz) <> 8;
    continue when exists (select 1 from public.staff_notifications s where s.business_id = b.id and s.kind = 'callback_digest' and s.created_at > now() - interval '20 hours');
    select count(*), count(*) filter (where due_at < now()) into v_open, v_over from public.callbacks
     where business_id = b.id and status not in ('completed','done','reached','cancelled','failed');
    continue when v_open = 0;
    perform public.zella_notify_owners(b.id, 'callback_digest', 'Callbacks for today', v_open || ' open' || case when v_over > 0 then ', ' || v_over || ' overdue' else '' end || '. Open Callbacks to work through them.', case when v_over > 0 then 'warning' else 'info' end, 'callbacks');
    n := n + 1;
  end loop;
  return n;
end $$;

-- 3. Contact preferences, changed by the team on a person's behalf (opt-outs also go to the consent record).
create or replace function public.zella_set_contact_preferences(p_business_id uuid, p_customer_id uuid, p_preferred text default null,
  p_do_not_sms boolean default null, p_do_not_email boolean default null, p_do_not_call boolean default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c record;
begin
  if not public.zella_has_role(p_business_id, array['owner','admin','manager','staff']) then raise exception 'NOT_ALLOWED'; end if;
  select * into c from public.customers where id = p_customer_id and business_id = p_business_id;
  if c.id is null then raise exception 'NOT_FOUND'; end if;
  if p_preferred is not null and p_preferred not in ('voice','sms','email') then raise exception 'BAD_PREFERENCE'; end if;
  update public.customers set preferred_contact_method = coalesce(p_preferred, preferred_contact_method), do_not_sms = coalesce(p_do_not_sms, do_not_sms),
         do_not_email = coalesce(p_do_not_email, do_not_email), do_not_call = coalesce(p_do_not_call, do_not_call), updated_at = now() where id = c.id;
  if p_do_not_sms is true and public.zella_digits(c.phone) is not null then
    insert into public.contact_consents (business_id, customer_id, phone_digits, channel, purpose, status, source, recorded_by, evidence)
    values (p_business_id, c.id, public.zella_digits(c.phone), 'sms', 'marketing', 'opted_out', 'staff', auth.uid(), '{"via":"preferences"}');
  end if;
  if p_do_not_email is true and c.email is not null then
    insert into public.contact_consents (business_id, customer_id, email_lower, channel, purpose, status, source, recorded_by, evidence)
    values (p_business_id, c.id, lower(c.email), 'email', 'marketing', 'opted_out', 'staff', auth.uid(), '{"via":"preferences"}');
  end if;
  return (select jsonb_build_object('preferred', preferred_contact_method, 'do_not_sms', do_not_sms, 'do_not_email', do_not_email, 'do_not_call', do_not_call) from public.customers where id = c.id);
end $$;

-- 4. Data rights: everything held about one person (admins only), and erasure that keeps the audit trail.
create or replace function public.zella_export_customer_data(p_business_id uuid, p_customer_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  if not public.zella_has_role(p_business_id, array['owner','admin']) then raise exception 'NOT_ALLOWED'; end if;
  if not exists (select 1 from public.customers where id = p_customer_id and business_id = p_business_id) then raise exception 'NOT_FOUND'; end if;
  select jsonb_build_object(
    'customer', (select to_jsonb(c) - 'business_id' from public.customers c where c.id = p_customer_id),
    'appointments', coalesce((select jsonb_agg(to_jsonb(a) - 'business_id') from public.appointments a where a.customer_id = p_customer_id and a.business_id = p_business_id), '[]'),
    'texts', coalesce((select jsonb_agg(jsonb_build_object('direction', m.direction, 'body', m.message_body, 'at', m.created_at)) from public.sms_messages m where m.customer_id = p_customer_id and m.business_id = p_business_id), '[]'),
    'emails', coalesce((select jsonb_agg(jsonb_build_object('direction', m.direction, 'subject', m.subject, 'body', m.body_text, 'at', m.created_at)) from public.email_messages m where m.customer_id = p_customer_id and m.business_id = p_business_id), '[]'),
    'calls', coalesce((select jsonb_agg(jsonb_build_object('direction', k.direction, 'at', k.started_at, 'summary', k.summary, 'transcript', k.transcript)) from public.calls k where k.customer_id = p_customer_id and k.business_id = p_business_id), '[]'),
    'callbacks', coalesce((select jsonb_agg(to_jsonb(k) - 'business_id') from public.callbacks k where k.customer_id = p_customer_id and k.business_id = p_business_id), '[]'),
    'consents', coalesce((select jsonb_agg(jsonb_build_object('channel', x.channel, 'purpose', x.purpose, 'status', x.status, 'source', x.source, 'at', x.recorded_at)) from public.contact_consents x where x.customer_id = p_customer_id and x.business_id = p_business_id), '[]'),
    'requests', coalesce((select jsonb_agg(to_jsonb(q) - 'business_id') from public.customer_requests q where q.customer_id = p_customer_id and q.business_id = p_business_id), '[]'))
  into r;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id) values (p_business_id, auth.uid(), 'customer_data_exported', 'customer', p_customer_id);
  return r;
end $$;

create or replace function public.zella_erase_customer(p_business_id uuid, p_customer_id uuid)
returns text language plpgsql security definer set search_path = public as $$
begin
  if not public.zella_has_role(p_business_id, array['owner','admin']) then raise exception 'NOT_ALLOWED'; end if;
  if not exists (select 1 from public.customers where id = p_customer_id and business_id = p_business_id) then raise exception 'NOT_FOUND'; end if;
  update public.sms_messages set message_body = '[removed]' where customer_id = p_customer_id and business_id = p_business_id;
  update public.email_messages set subject = '[removed]', body_text = '[removed]', body_html = null where customer_id = p_customer_id and business_id = p_business_id;
  update public.calls set transcript = null, recording_url = null, summary = null, from_number = null, to_number = null where customer_id = p_customer_id and business_id = p_business_id;
  update public.callbacks set contact_number = null, summary = null, note = null where customer_id = p_customer_id and business_id = p_business_id;
  update public.followup_tasks set status = 'cancelled', updated_at = now() where customer_id = p_customer_id and business_id = p_business_id and status in ('pending','in_progress');
  update public.customers set first_name = 'Deleted', last_name = null, phone = null, email = null, address = null, notes = null, date_of_birth = null, company_name = null,
         tags = '{}', metadata = '{}'::jsonb, qualification = '{}'::jsonb, do_not_contact = true, status = 'archived', updated_at = now()
   where id = p_customer_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id) values (p_business_id, auth.uid(), 'customer_erased', 'customer', p_customer_id);
  return 'erased';
end $$;

-- 5. Recordings and transcripts: a named accessor for managers and above that writes who looked at what.
create or replace function public.zella_get_call_recording(p_call_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare k record;
begin
  select id, business_id, recording_url, transcript into k from public.calls where id = p_call_id;
  if k.id is null then raise exception 'NOT_FOUND'; end if;
  if not public.zella_has_role(k.business_id, array['owner','admin','manager']) then raise exception 'NOT_ALLOWED'; end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id) values (k.business_id, auth.uid(), 'call_recording_viewed', 'call', k.id);
  return jsonb_build_object('recording_url', k.recording_url, 'transcript', k.transcript);
end $$;

-- 6. Tenant isolation check: tables that hold business data without row-level security (should be empty).
create or replace function public.zella_tenant_leak_check()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(c.relname order by c.relname), '[]'::jsonb)
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
     and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'business_id' and not a.attisdropped);
$$;

-- 7. Two-person approval for sensitive actions: one person asks, a different owner or admin decides.
create table if not exists public.sensitive_approvals (
  id uuid primary key default gen_random_uuid(), business_id uuid not null, action text not null, entity_id uuid, details jsonb not null default '{}'::jsonb,
  requested_by uuid, status text not null default 'pending' check (status in ('pending','approved','rejected','expired')),
  decided_by uuid, decided_at timestamptz, created_at timestamptz not null default now(), expires_at timestamptz not null default now() + interval '2 days');
alter table public.sensitive_approvals enable row level security;
drop policy if exists sensitive_approvals_read on public.sensitive_approvals;
create policy sensitive_approvals_read on public.sensitive_approvals for select to authenticated using (public.zella_has_role(business_id, array['owner','admin']));

create or replace function public.zella_request_approval(p_business_id uuid, p_action text, p_entity_id uuid default null, p_details jsonb default '{}'::jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not public.zella_has_role(p_business_id, array['owner','admin','manager']) then raise exception 'NOT_ALLOWED'; end if;
  insert into public.sensitive_approvals (business_id, action, entity_id, details, requested_by) values (p_business_id, left(p_action, 80), p_entity_id, coalesce(p_details, '{}'), auth.uid()) returning id into v_id;
  perform public.zella_notify_owners(p_business_id, 'approval_requested', 'An action needs your approval', 'Someone asked to: ' || left(p_action, 80) || '. Open Approvals to decide.', 'warning', 'settings');
  return v_id;
end $$;

create or replace function public.zella_decide_approval(p_approval_id uuid, p_approve boolean)
returns text language plpgsql security definer set search_path = public as $$
declare a record;
begin
  select * into a from public.sensitive_approvals where id = p_approval_id for update;
  if a.id is null then raise exception 'NOT_FOUND'; end if;
  if not public.zella_has_role(a.business_id, array['owner','admin']) then raise exception 'NOT_ALLOWED'; end if;
  if auth.uid() is not null and a.requested_by = auth.uid() then raise exception 'CANNOT_APPROVE_OWN_REQUEST'; end if;
  if a.status <> 'pending' then return a.status; end if;
  if a.expires_at < now() then update public.sensitive_approvals set status = 'expired' where id = a.id; return 'expired'; end if;
  update public.sensitive_approvals set status = case when p_approve then 'approved' else 'rejected' end, decided_by = auth.uid(), decided_at = now() where id = a.id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data) values (a.business_id, auth.uid(), 'approval_' || case when p_approve then 'approved' else 'rejected' end, 'approval', a.id, jsonb_build_object('action', a.action));
  return case when p_approve then 'approved' else 'rejected' end;
end $$;

do $$
declare f text;
begin
  foreach f in array array['zella_post_callback_digests()','zella_tenant_leak_check()'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
  foreach f in array array['zella_has_role(uuid,text[])','zella_reassign_callback(uuid,uuid)','zella_reschedule_callback(uuid,timestamptz)','zella_cancel_callback(uuid,text)',
    'zella_set_contact_preferences(uuid,uuid,text,boolean,boolean,boolean)','zella_export_customer_data(uuid,uuid)','zella_erase_customer(uuid,uuid)',
    'zella_get_call_recording(uuid)','zella_request_approval(uuid,text,uuid,jsonb)','zella_decide_approval(uuid,boolean)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;
