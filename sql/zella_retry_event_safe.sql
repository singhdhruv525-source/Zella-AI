-- Zella Voice: Retry on Platform operations can't repeat a message (docs/ADMIN_AUDIT_2026-11-16.md OPS-05).
-- zella_retry_event put any failed event back in the queue with its attempts reset, even when a run of it had already
-- succeeded a step (for example a text went out) or reached a provider, so a retry could send the same message twice.
-- The Automations page's retry (zella_admin_run_retry_check) already refuses those. Now this one does too:
--   * refused (NOT_RETRYABLE, with the reason in words) when a run of the event is running or succeeded, has a step
--     that succeeded, or reached a provider;
--   * needs a reason (REASON_REQUIRED), kept in the audit row with the event;
--   * allowed for admins with integrations.manage, the same permission as the Automations retry (it was owner and
--     super admin only).
-- The function gains a reason argument, so the app and this file go live together. It is archived first and must
-- match production exactly (16 Nov 2026), otherwise VERSION_MISMATCH.
-- Rollback: sql/rollback/zella_retry_event_safe_rollback.sql
begin;

do $$
declare s constant text := 'public.zella_retry_event(uuid)'; d text;
begin
  if to_regclass('public.zella_function_archive') is null or to_regprocedure('public.zella_admin_can(text)') is null
     or to_regprocedure('public.zella_admin_reason(text)') is null or to_regclass('public.workflow_executions') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  if to_regprocedure(s) is null then
    if to_regprocedure('public.zella_retry_event(uuid,text)') is not null then return; end if;   -- already applied
    raise exception 'VERSION_MISMATCH: % is missing', s;
  end if;
  d := pg_get_functiondef(s::regprocedure);
  if md5(d) <> '1220fb998a76d857af2ca791ad2c7ae2' then raise exception 'VERSION_MISMATCH: % is not the version this file was written for', s; end if;
  insert into public.zella_function_archive (migration, signature, definition, definition_md5)
  values ('zella_retry_event_safe', s, d, md5(d)) on conflict (migration, signature) do nothing;
  drop function public.zella_retry_event(uuid);
end $$;

create or replace function public.zella_retry_event(p_event_id uuid, p_reason text default null) returns text
language plpgsql security definer set search_path = public as $$
declare e public.automation_events; v_reason text; v_done int;
begin
  if auth.uid() is null or not public.zella_admin_can('integrations.manage') then raise exception 'NOT_ALLOWED'; end if;
  v_reason := public.zella_admin_reason(p_reason);
  select * into e from public.automation_events where id = p_event_id for update;
  if e.id is null or e.status <> 'failed' then raise exception 'NOT_RETRYABLE: Only failed events can be sent back. Reload the page.'; end if;
  if exists (select 1 from public.workflow_executions w where w.event_id = p_event_id and w.status in ('running', 'succeeded')) then
    raise exception 'NOT_RETRYABLE: A run of this event already ran or is running, so sending it back could repeat what it did.';
  end if;
  select count(*) into v_done from public.workflow_executions w,
         jsonb_array_elements(case when jsonb_typeof(w.steps) = 'array' then w.steps else '[]'::jsonb end) s
   where w.event_id = p_event_id and s ->> 'status' in ('succeeded', 'done', 'ok', 'sent');
  if v_done > 0 then
    raise exception 'NOT_RETRYABLE: % step(s) of an earlier run already succeeded (for example a message went out). Running it again could repeat them; fix the cause and handle the rest by hand.', v_done;
  end if;
  if exists (select 1 from public.workflow_executions w where w.event_id = p_event_id
              and jsonb_typeof(w.provider_refs) = 'object' and w.provider_refs <> '{}'::jsonb) then
    raise exception 'NOT_RETRYABLE: A provider already received a request for this event, so it may have acted. Check the provider first.';
  end if;
  update public.automation_events set status = 'received', attempts = 0, next_attempt_at = now(), claimed_at = null, error_category = null, error_message = null
   where id = p_event_id and status = 'failed';
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (e.business_id, auth.uid(), 'event_retried', 'automation_event', e.id,
          jsonb_build_object('reason', v_reason, 'event_type', e.event_type, 'attempts_before', e.attempts));
  return 'queued';
end $$;
revoke all on function public.zella_retry_event(uuid, text) from public, anon;
grant execute on function public.zella_retry_event(uuid, text) to authenticated, service_role;

commit;
