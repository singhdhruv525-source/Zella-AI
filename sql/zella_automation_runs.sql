-- Retry a failed automation run. Owners, admins and managers only; the run is
-- put back in the queue and the automation must still be on. Opt-outs and
-- contact limits are checked again when it actually runs. Every retry is logged.

create or replace function public.zella_retry_automation_run(p_run_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare r public.automation_runs; a public.automations;
begin
  select * into r from public.automation_runs where id = p_run_id for update;
  if not found or not public.zella_can_manage(r.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if r.status <> 'failed' then raise exception 'NOT_FAILED'; end if;
  select * into a from public.automations where id = r.automation_id;
  if not found or a.status <> 'active' then raise exception 'AUTOMATION_OFF'; end if;
  update public.automation_runs
     set status = 'queued', next_run_at = now(), completed_at = null,
         execution_log = coalesce(execution_log, '[]'::jsonb) || jsonb_build_array(jsonb_build_object('at', now(), 'event', 'retry_requested', 'by', auth.uid()))
   where id = p_run_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (r.business_id, auth.uid(), 'automation.run_retried', 'automation', r.automation_id,
          jsonb_build_object('run_id', p_run_id, 'status', 'failed', 'error', r.error_message), jsonb_build_object('status', 'queued'));
  return 'queued';
end $$;

revoke all on function public.zella_retry_automation_run(uuid) from public, anon;
grant execute on function public.zella_retry_automation_run(uuid) to authenticated, service_role;
