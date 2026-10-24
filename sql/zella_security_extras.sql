-- Zella - security and operations extras (checklist 279, 285, 302, 318, 324, 325, 338). Safe to run more than once.
-- Needs zella_ops_extras.sql (approvals, recording accessor, tenant check).
--   318 erasing a customer needs a second owner or admin to approve, once the business has two of them
--   324 calls_view hides recordings and transcripts from people below manager; zella_lock_call_columns() makes that the only way
--   325 the tenant check also finds open policies and anonymous access, and raises a platform alert daily
--   279 owners are told once a day when their messages could not be sent
--   285 a manager can see failed work and send it back to try again
--   302 active businesses missing a phone number or calendar get a weekly reminder
--   338 which automatic messages work: sent, failed, and bookings within a week

-- 1. Approval for erasing a customer (318). One approval is used once, within two days.
alter table public.sensitive_approvals add column if not exists used_at timestamptz;

create or replace function public.zella_approval_ok(p_business_id uuid, p_action text, p_entity_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  -- a business with a single owner or admin has no second person to ask; the action is still logged
  if (select count(*) from public.business_members m where m.business_id = p_business_id and m.status = 'active' and m.role in ('owner', 'admin')) < 2 then return true; end if;
  select id into v_id from public.sensitive_approvals
   where business_id = p_business_id and action = p_action and entity_id is not distinct from p_entity_id and status = 'approved' and used_at is null and expires_at > now() - interval '0 seconds'
   order by decided_at desc limit 1 for update;
  if v_id is null then return false; end if;
  update public.sensitive_approvals set used_at = now() where id = v_id;
  return true;
end $$;
revoke execute on function public.zella_approval_ok(uuid, text, uuid) from public, anon, authenticated;
grant execute on function public.zella_approval_ok(uuid, text, uuid) to service_role;

do $$
declare d text;
begin
  d := pg_get_functiondef('public.zella_erase_customer(uuid,uuid)'::regprocedure);
  if d not like '%zella_approval_ok%' then
    d := replace(d, E'  update public.sms_messages set message_body = ''[removed]''',
      E'  if not public.zella_approval_ok(p_business_id, ''erase_customer'', p_customer_id) then raise exception ''APPROVAL_REQUIRED''; end if;\n  update public.sms_messages set message_body = ''[removed]''');
    if d not like '%zella_approval_ok%' then raise exception 'PATCH_FAILED_ERASE'; end if;
    execute d;
  end if;
end $$;

-- 2. Recordings and transcripts (324). Read calls through calls_view; below manager the two columns are empty.
create or replace view public.calls_view with (security_invoker = true) as
  select c.id, c.business_id, c.customer_id, c.conversation_id, c.direction, c.status, c.from_number, c.to_number, c.started_at, c.answered_at, c.ended_at, c.duration_seconds, c.ai_handled, c.external_call_id, c.metadata, c.created_at, c.updated_at, c.needs_human, c.escalation_reason, c.escalated_at, c.escalation_resolved_at, c.escalation_resolved_by, c.summary, c.transfer_status, c.failure_reason, c.failure_context, c.assigned_to, c.outcome, c.outcome_note, c.outcome_at, c.escalation_acknowledged_at, c.escalation_acknowledged_by, c.escalation_reminded_at,
         case when public.zella_has_role(c.business_id, array['owner','admin','manager']) then c.recording_url end as recording_url,
         case when public.zella_has_role(c.business_id, array['owner','admin','manager']) then c.transcript end as transcript
    from public.calls c;
grant select on public.calls_view to authenticated;

-- Run once the app reads calls through calls_view (docs/FRONTEND_TODO.md): after this, nobody can read the two columns from the table directly.
create or replace function public.zella_lock_call_columns() returns text
language plpgsql security definer set search_path = public as $$
declare cols text;
begin
  select string_agg(quote_ident(column_name), ', ') into cols from information_schema.columns
   where table_schema = 'public' and table_name = 'calls' and column_name not in ('recording_url', 'transcript');
  execute 'revoke select on public.calls from authenticated';
  execute 'grant select (' || cols || ') on public.calls to authenticated';
  return 'locked';
end $$;
revoke execute on function public.zella_lock_call_columns() from public, anon, authenticated;
grant execute on function public.zella_lock_call_columns() to service_role;

-- 3. Tenant isolation check (325): no row security, open policies, and anonymous access to business data. Should all be empty.
create or replace function public.zella_tenant_leak_check()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'no_row_security', coalesce((select jsonb_agg(c.relname order by c.relname) from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
          and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'business_id' and not a.attisdropped)), '[]'::jsonb),
    'open_policies', coalesce((select jsonb_agg(p.tablename || '.' || p.policyname order by p.tablename) from pg_policies p
        where p.schemaname = 'public' and p.cmd in ('SELECT', 'ALL') and p.qual = 'true'
          and exists (select 1 from information_schema.columns k where k.table_schema = 'public' and k.table_name = p.tablename and k.column_name = 'business_id')), '[]'::jsonb),
    'anon_can_read', coalesce((select jsonb_agg(g.table_name order by g.table_name) from information_schema.role_table_grants g
        where g.table_schema = 'public' and g.grantee = 'anon' and g.privilege_type = 'SELECT'
          and exists (select 1 from information_schema.columns k where k.table_schema = 'public' and k.table_name = g.table_name and k.column_name = 'business_id')), '[]'::jsonb));
$$;
revoke execute on function public.zella_tenant_leak_check() from public, anon, authenticated;
grant execute on function public.zella_tenant_leak_check() to service_role;

-- Daily: a platform alert if anything shows up.
create or replace function public.zella_run_tenant_check() returns integer
language plpgsql security definer set search_path = public as $$
declare r jsonb := public.zella_tenant_leak_check(); n integer;
begin
  n := jsonb_array_length(r -> 'no_row_security') + jsonb_array_length(r -> 'open_policies') + jsonb_array_length(r -> 'anon_can_read');
  if n > 0 then
    perform public.zella_platform_alert('tenant_leak', 'Customer data may be visible across businesses', left(r::text, 400), 'critical', null, 'tenant_leak', r);
  else
    perform public.zella_resolve_platform_alerts('tenant_leak', null, 'tenant_leak', 'Isolation check is clean');
  end if;
  return n;
end $$;
revoke all on function public.zella_run_tenant_check() from public, anon, authenticated;
grant execute on function public.zella_run_tenant_check() to service_role;

-- 4. Failure notices for owners (279): once a day, how many of their messages could not be sent.
create or replace function public.zella_notify_message_failures() returns integer
language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0;
begin
  for r in
    select business_id, sum(k)::int as failed from (
      select business_id, count(*) k from public.sms_messages where direction = 'outbound' and status = 'failed' and created_at > now() - interval '24 hours' group by business_id
      union all
      select business_id, count(*) from public.email_messages where direction = 'outbound' and status = 'failed' and created_at > now() - interval '24 hours' group by business_id) x
    group by business_id loop
    continue when exists (select 1 from public.staff_notifications where business_id = r.business_id and kind = 'messages_failed' and created_at > now() - interval '20 hours');
    perform public.zella_notify_owners(r.business_id, 'messages_failed', r.failed || (case when r.failed = 1 then ' message' else ' messages' end) || ' could not be sent',
      'Check the phone number and email address on the customer, or ask for help if this keeps happening.', 'warning', 'inbox');
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.zella_notify_message_failures() from public, anon, authenticated;
grant execute on function public.zella_notify_message_failures() to service_role;

-- 5. Manual recovery (285): see failed work, send it back to try again. Managers and above; every retry is logged.
create or replace function public.zella_failed_work(p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  return jsonb_build_object(
    'tasks', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'channel', channel, 'outcome', outcome, 'at', updated_at) order by updated_at desc)
                         from (select * from public.followup_tasks where business_id = p_business_id and status = 'failed' and updated_at > now() - interval '7 days' limit 50) t), '[]'::jsonb),
    'reminders', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'channel', channel, 'error', error, 'due_at', due_at) order by due_at desc)
                         from (select * from public.appointment_reminders where business_id = p_business_id and status = 'failed' and due_at > now() - interval '7 days' limit 50) t), '[]'::jsonb),
    'social', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'channel', channel, 'error', last_error, 'at', created_at) order by created_at desc)
                         from (select * from public.meta_outbox where business_id = p_business_id and status = 'failed' and created_at > now() - interval '7 days' limit 50) t), '[]'::jsonb));
end $$;
revoke execute on function public.zella_failed_work(uuid) from public, anon;
grant execute on function public.zella_failed_work(uuid) to authenticated, service_role;

create or replace function public.zella_retry_failed(p_business_id uuid, p_kind text, p_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  if p_kind = 'task' then
    update public.followup_tasks set status = 'pending', attempts = 0, due_at = now(), claimed_at = null, updated_at = now() where id = p_id and business_id = p_business_id and status = 'failed';
  elsif p_kind = 'reminder' then
    update public.appointment_reminders set status = 'pending', attempts = 0, error = null where id = p_id and business_id = p_business_id and status = 'failed'
       and exists (select 1 from public.appointments a where a.id = appointment_id and a.start_time > now());
  elsif p_kind = 'social' then
    update public.meta_outbox set status = 'queued', attempts = 0, next_try_at = now(), last_error = null where id = p_id and business_id = p_business_id and status = 'failed';
  else raise exception 'BAD_KIND'; end if;
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'NOT_RETRYABLE'; end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data) values (p_business_id, auth.uid(), 'failed_work_retried', p_kind, p_id, jsonb_build_object('kind', p_kind));
  return 'queued';
end $$;
revoke execute on function public.zella_retry_failed(uuid, text, uuid) from public, anon;
grant execute on function public.zella_retry_failed(uuid, text, uuid) to authenticated, service_role;

-- 6. Integration reminders (302): active businesses with no phone number or calendar are reminded once a week.
create or replace function public.zella_remind_integrations() returns integer
language plpgsql security definer set search_path = public as $$
declare b record; v_missing text[]; n integer := 0;
begin
  for b in select id from public.businesses where onboarding_status = 'active' and suspended_at is null and cancelled_at is null loop
    v_missing := '{}';
    if not exists (select 1 from public.business_phone_numbers p where p.business_id = b.id and p.status = 'active') then v_missing := array_append(v_missing, 'a phone number for your assistant'::text); end if;
    if not exists (select 1 from public.calendar_connections c where c.business_id = b.id and c.status = 'active') then v_missing := array_append(v_missing, 'your calendar'::text); end if;
    continue when cardinality(v_missing) = 0;
    continue when exists (select 1 from public.staff_notifications where business_id = b.id and kind = 'integration_reminder' and created_at > now() - interval '7 days');
    perform public.zella_notify_owners(b.id, 'integration_reminder', 'Connect ' || array_to_string(v_missing, ' and '), 'Zella works best when these are connected. Open Settings to finish.', 'info', 'settings');
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.zella_remind_integrations() from public, anon, authenticated;
grant execute on function public.zella_remind_integrations() to service_role;

-- 7. Which automatic messages work (338).
create or replace function public.zella_workflow_effectiveness(p_business_id uuid, p_days integer default 30)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d interval := make_interval(days => greatest(1, least(coalesce(p_days, 30), 365)));
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((select jsonb_agg(r order by r.total desc) from (
    select f.kind, f.channel, count(*) as total,
           count(*) filter (where f.status = 'done') as done,
           count(*) filter (where f.status = 'failed') as failed,
           count(*) filter (where f.status = 'skipped') as skipped,
           count(*) filter (where f.status = 'done' and exists (select 1 from public.appointments a where a.customer_id = f.customer_id and a.business_id = f.business_id
                                  and a.created_at between f.completed_at and f.completed_at + interval '7 days' and a.status <> 'cancelled')) as booked_within_7_days
      from public.followup_tasks f where f.business_id = p_business_id and f.created_at > now() - d group by f.kind, f.channel) r), '[]'::jsonb);
end $$;
revoke execute on function public.zella_workflow_effectiveness(uuid, integer) from public, anon;
grant execute on function public.zella_workflow_effectiveness(uuid, integer) to authenticated, service_role;
