-- Zella Voice: a held email to a business can be read, released or discarded (docs/ADMIN_AUDIT_2026-11-16.md COM-18,
-- COM-22).
-- zella_claim_platform_emails (sql/zella_email_delivery.sql, applied) holds an email after 5 tries and raises the
-- platform_email_held alert saying "Check it before sending it again", but nothing could check it, send it again or
-- drop it, and the admin list leaves the bodies out, so there was nothing to read. Now, for platform admins:
--   * zella_admin_platform_email_detail(p_id): one email with its subject, HTML and text (businesses.view). Each view
--     is audited (comms.platform_email_viewed), like every other message content view;
--   * zella_admin_platform_email_release(p_id, p_reason): a held email goes back to the queue with its tries reset
--     (comms.manage, reason required, audited). It still goes nowhere until email_live, the sender address and the
--     provider key are set: while email_live is off the next claim marks it test mode, as for every queued email;
--   * zella_admin_platform_email_discard(p_id, p_reason): a held email is never sent (comms.manage, reason required,
--     audited). It ends as 'failed', a status the outbox already allows and nothing else writes, shown as Discarded.
-- Both close the matching platform_email_held alert (its dedupe key). The claim and finish functions are unchanged: an
-- email is still held after its fifth try, never marked failed by the sender.
-- Nothing existing is replaced, so nothing is archived. Each new function must be absent or exactly this file's
-- version, otherwise VERSION_MISMATCH. Rollback: sql/rollback/zella_platform_email_actions_rollback.sql
begin;

do $$
declare f record;
begin
  if to_regclass('public.platform_emails') is null or to_regprocedure('public.zella_admin_require(text)') is null
     or to_regprocedure('public.zella_admin_reason(text)') is null or to_regclass('public.platform_alerts') is null
     or to_regprocedure('public.zella_admin_audit(text,text,uuid,uuid,jsonb,jsonb)') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  for f in select * from (values
      ('public.zella_admin_platform_email_detail(uuid)', '94b421aa140fc4c0642d6366b02b3c5d'),
      ('public.zella_admin_platform_email_release(uuid,text)', 'c0fe74e7fde7d1f56e97991dc7022b74'),
      ('public.zella_admin_platform_email_discard(uuid,text)', '7dd8e3e18e0f6c032a229a7c55dc3fb9')) as t(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'VERSION_MISMATCH: % is not a version this file was written for', f.sig;
    end if;
  end loop;
end $$;

CREATE OR REPLACE FUNCTION public.zella_admin_platform_email_detail(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare e public.platform_emails; v_name text;
begin
  perform public.zella_admin_require('businesses.view');
  select * into e from public.platform_emails where id = p_id;
  if e.id is null then raise exception 'NOT_FOUND'; end if;
  select name into v_name from public.businesses where id = e.business_id;
  perform public.zella_admin_audit('comms.platform_email_viewed', 'platform_email', e.id, e.business_id, null,
    jsonb_build_object('code', e.code, 'status', e.status));
  return jsonb_build_object('id', e.id, 'business_id', e.business_id, 'business_name', v_name, 'code', e.code,
    'to_email', e.to_email, 'cc', to_jsonb(e.cc), 'subject', e.subject, 'html', e.html, 'text_body', e.text_body,
    'mandatory', e.mandatory, 'status', e.status, 'attempts', e.attempts, 'last_error', e.last_error,
    'created_at', e.created_at, 'sent_at', e.sent_at, 'next_attempt_at', e.next_attempt_at,
    'can_manage', public.zella_admin_can('comms.manage'));
end
$function$;

CREATE OR REPLACE FUNCTION public.zella_admin_platform_email_release(p_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare e public.platform_emails; v_reason text := public.zella_admin_reason(p_reason);
begin
  perform public.zella_admin_require('comms.manage');
  select * into e from public.platform_emails where id = p_id for update;
  if e.id is null then raise exception 'NOT_FOUND'; end if;
  if e.status <> 'held' then raise exception 'NOT_HELD'; end if;
  -- back to the queue as new: tries reset, no claim; the sender still decides test mode or a real send
  update public.platform_emails set status = 'queued', attempts = 0, next_attempt_at = now(), claim_token = null, claimed_at = null
   where id = e.id;
  update public.platform_alerts set status = 'resolved', resolved_by = auth.uid(), resolved_at = now(),
         resolution_note = left('Released: ' || v_reason, 300)
   where kind = 'platform_email_held' and dedupe_key = 'platform_email_held:' || e.dedupe_key and status <> 'resolved';
  perform public.zella_admin_audit('comms.platform_email_released', 'platform_email', e.id, e.business_id,
    jsonb_build_object('status', e.status, 'attempts', e.attempts, 'last_error', e.last_error),
    jsonb_build_object('status', 'queued', 'attempts', 0, 'code', e.code, 'reason', v_reason));
  return jsonb_build_object('id', e.id, 'status', 'queued');
end
$function$;

CREATE OR REPLACE FUNCTION public.zella_admin_platform_email_discard(p_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare e public.platform_emails; v_reason text := public.zella_admin_reason(p_reason);
begin
  perform public.zella_admin_require('comms.manage');
  select * into e from public.platform_emails where id = p_id for update;
  if e.id is null then raise exception 'NOT_FOUND'; end if;
  if e.status <> 'held' then raise exception 'NOT_HELD'; end if;
  -- 'failed' is terminal: no claim takes it again (claims take queued and sending only)
  update public.platform_emails set status = 'failed', claim_token = null,
         last_error = left('Discarded by an admin: ' || v_reason, 500)
   where id = e.id;
  update public.platform_alerts set status = 'resolved', resolved_by = auth.uid(), resolved_at = now(),
         resolution_note = left('Discarded: ' || v_reason, 300)
   where kind = 'platform_email_held' and dedupe_key = 'platform_email_held:' || e.dedupe_key and status <> 'resolved';
  perform public.zella_admin_audit('comms.platform_email_discarded', 'platform_email', e.id, e.business_id,
    jsonb_build_object('status', e.status, 'attempts', e.attempts, 'last_error', e.last_error),
    jsonb_build_object('status', 'failed', 'code', e.code, 'reason', v_reason));
  return jsonb_build_object('id', e.id, 'status', 'failed');
end
$function$;

revoke all on function public.zella_admin_platform_email_detail(uuid) from public, anon;
revoke all on function public.zella_admin_platform_email_release(uuid, text) from public, anon;
revoke all on function public.zella_admin_platform_email_discard(uuid, text) from public, anon;
grant execute on function public.zella_admin_platform_email_detail(uuid) to authenticated;
grant execute on function public.zella_admin_platform_email_release(uuid, text) to authenticated;
grant execute on function public.zella_admin_platform_email_discard(uuid, text) to authenticated;

commit;
