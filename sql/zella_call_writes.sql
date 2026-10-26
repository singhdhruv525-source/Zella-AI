-- Zella - call writes go through database functions (2026-10-26). Safe to re-run.
--
-- Purpose
--   The browser used to write to public.calls directly in three places (BusinessCalls.jsx, BusinessProfile.jsx,
--   BusinessToday.jsx). Two of them rebuilt `metadata` from a copy that may be out of date, so a newer change made
--   by n8n or another person could be lost. Any member allowed to update calls could also change any column,
--   including recording_url and transcript. These two functions are the only writes the app needs:
--     zella_call_mark_followed_up(call)            sets metadata.followed_up_at, merged on the server
--     zella_call_set_escalation(call, flag, reason) flags a call for a person, or marks the hand-off as handled
--
-- Needs: zella_calls.sql (zella_call_update), zella_workflows.sql (zella_is_member), zella_security_extras.sql
--   (calls_view, zella_lock_call_columns). The calls table and its row security come from the base schema, which
--   is not in this repo yet (see docs/SCHEMA_STATUS.md).
--
-- Authorization
--   Both functions check that the signed-in person is an active member of the call's business. They never take a
--   business_id from the browser. Each change is written to audit_logs.
--
-- Rollout (in this order; section 2 is NOT run by this file)
--   1. Run this file. It only adds functions, so it changes nothing for the current app.
--   2. Deploy the web app from this branch (it calls the functions instead of writing to calls).
--   3. Check in a browser: mark a missed call as followed up, flag a call for a human, mark it handled.
--   4. Then run section 2 by hand in the SQL editor.
--
-- Rollback
--   Section 1: drop function public.zella_call_mark_followed_up(uuid);
--              drop function public.zella_call_set_escalation(uuid, boolean, text);
--   Section 2: grant select, update on public.calls to authenticated;  (restores the previous grants)
--
-- Validation (rolled back, nothing stays):
--   do $$ declare r jsonb; begin
--     perform set_config('request.jwt.claims', json_build_object('sub', '<member user id>', 'role', 'authenticated')::text, true);
--     perform set_config('role', 'authenticated', true);
--     perform public.zella_call_mark_followed_up('<call id>');
--     select to_jsonb(c) into r from public.calls_view c where id = '<call id>';
--     raise exception 'RESULT %', r -> 'metadata';
--   end $$;

-- 1. Functions ------------------------------------------------------------------------------------------------

create or replace function public.zella_call_mark_followed_up(p_call_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare c public.calls;
begin
  select * into c from public.calls where id = p_call_id for update;
  if not found or not public.zella_is_member(c.business_id) then raise exception 'NOT_ALLOWED'; end if;
  update public.calls
     set metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('followed_up_at', now(), 'followed_up_by', auth.uid()),
         updated_at = now()
   where id = p_call_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (c.business_id, auth.uid(), 'call.followed_up', 'call', p_call_id, jsonb_build_object('followed_up_at', now()));
  return true;
end $$;

-- p_flag true: needs a person (p_reason required). p_flag false: the hand-off was dealt with.
create or replace function public.zella_call_set_escalation(p_call_id uuid, p_flag boolean, p_reason text default null)
returns boolean language plpgsql security definer set search_path = public as $$
declare c public.calls; v_reason text := nullif(left(trim(coalesce(p_reason, '')), 200), '');
begin
  if p_flag is null then raise exception 'BAD_INPUT'; end if;
  select * into c from public.calls where id = p_call_id for update;
  if not found or not public.zella_is_member(c.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_flag then
    if v_reason is null then raise exception 'REASON_REQUIRED'; end if;
    update public.calls
       set needs_human = true, escalation_reason = v_reason, escalated_at = now(),
           escalation_resolved_at = null, escalation_resolved_by = null, updated_at = now()
     where id = p_call_id;
  else
    -- Already handled: nothing to change (a second click, or two people at once).
    if c.escalation_resolved_at is not null then return false; end if;
    update public.calls
       set escalation_resolved_at = now(), escalation_resolved_by = auth.uid(), updated_at = now()
     where id = p_call_id;
  end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (c.business_id, auth.uid(), case when p_flag then 'call.escalated' else 'call.escalation_resolved' end, 'call', p_call_id,
          jsonb_build_object('needs_human', c.needs_human, 'escalation_resolved_at', c.escalation_resolved_at),
          jsonb_build_object('needs_human', case when p_flag then true else c.needs_human end, 'reason', v_reason));
  return true;
end $$;

revoke all on function public.zella_call_mark_followed_up(uuid) from public, anon;
revoke all on function public.zella_call_set_escalation(uuid, boolean, text) from public, anon;
grant execute on function public.zella_call_mark_followed_up(uuid) to authenticated, service_role;
grant execute on function public.zella_call_set_escalation(uuid, boolean, text) to authenticated, service_role;

-- 2. Lock the table (run by hand after rollout step 3; left commented on purpose) -------------------------------
--
-- After this, signed-in users read calls only through calls_view (recordings and transcripts for managers and
-- above) and change them only through the zella_call_* functions. n8n and edge functions use the server key and
-- are not affected.
--
--   revoke insert, update, delete on public.calls from authenticated;
--   select public.zella_lock_call_columns();
--
-- Check afterwards (expect only SELECT on the non-protected columns for authenticated):
--   select privilege_type, count(*) from information_schema.column_privileges
--    where table_schema = 'public' and table_name = 'calls' and grantee = 'authenticated' group by 1;
