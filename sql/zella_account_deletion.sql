-- Zella Voice: a business owner can ask for the account to be deleted (security audit 18 Nov 2026, 12.3, H5; owner
-- decisions 18 Nov 2026). There was no way to delete a business on request.
--   1. The owner asks in Settings (zella_business_deletion_request: an active owner, the business name typed exactly,
--      a reason). Zella Voice is alerted; nothing changes for the business yet. The owner can cancel any time before
--      the data is removed (zella_business_deletion_cancel).
--   2. A Zella Voice admin with security.manage (the permission lane G's purges need) confirms (zella_admin_business_deletion_confirm, audited). The
--      account is frozen at once: the business is suspended, so the AI receptionist stops answering its numbers and its
--      automations pause (the existing suspension rules); the purge date is 30 days later. Cancelling lifts this freeze.
--   3. zella_business_deletion_purge_due (daily job group) removes every confirmed business past its 30 days, using
--      lane G's purge path: the same switch (retention_purge_enabled, owner only, off), the same refusals (a legal
--      hold, audit history at risk until lane B's SET NULL is applied, billing or offer records kept, phone numbers
--      still assigned), a retention_purge_runs row approved by the confirming admin, the same "business.purged" audit,
--      the same storage file hand off (zella_business_purge_files_done), and the business row deleted (everything that
--      belongs to it goes with it; audit_logs keep their rows with business_id set to null, ACC-10). Its calls are
--      queued for deletion at Vapi first (provider_deletions, sent only while vapi_deletion_live is on). A request that
--      can't be purged yet is marked blocked with the reason and Zella Voice is alerted; it is tried again each day.
-- Every object is new; a function that exists already must be exactly this file's version (VERSION_MISMATCH).
-- Needs sql/zella_business_purge.sql and sql/zella_privacy_retention.sql.
-- Rollback: sql/rollback/zella_account_deletion_rollback.sql
begin;

do $$
declare f record;
  mine constant jsonb := '{"public.zella_business_deletion_freeze_note()": "50e160e55012c38d51692dab5e1f7dd8",
    "public.zella_business_deletion_purge_due()": "fc8d2e45a59f598a90ab8db73b1970dd",
    "public.zella_business_deletion_status(uuid)": "ac7156772cbfd63060438b4137217983",
    "public.zella_business_deletion_request(uuid,text,text)": "5ea41bd703309f71ff4b7cddaefcdca6",
    "public.zella_business_deletion_cancel(uuid)": "68fb5357ca6cb2a935fcd547848650e9",
    "public.zella_admin_business_deletion_confirm(uuid,text)": "c67e99fa02dda6fc8456382964e06521",
    "public.zella_admin_business_deletion_requests()": "e4c264caa842e2dae0394ea0e1699620"}';
begin
  if to_regclass('public.retention_purge_runs') is null or to_regprocedure('public.zella_business_purge_files_done(uuid,uuid,text[],text)') is null
     or to_regprocedure('public.zella_queue_provider_deletion(uuid,text,text)') is null or to_regprocedure('public.zella_admin_require(text)') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing (lane G business purge and zella_privacy_retention first)';
  end if;
  for f in select key, value from jsonb_each_text(mine) loop
    if to_regprocedure(f.key) is not null and md5(pg_get_functiondef(f.key::regprocedure)) <> f.value then
      raise exception 'VERSION_MISMATCH: % already exists in another version', f.key;
    end if;
  end loop;
end $$;

-- kept after the business is gone (no foreign key), as the record that the owner asked and who confirmed
create table if not exists public.business_deletion_requests (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  business_name text not null,
  status text not null default 'requested' check (status in ('requested', 'confirmed', 'blocked', 'cancelled', 'purged')),
  reason text not null check (length(btrim(reason)) between 3 and 300),
  requested_by uuid not null,
  requested_at timestamptz not null default now(),
  confirmed_by uuid,
  confirmed_at timestamptz,
  purge_after timestamptz,
  cancelled_by uuid,
  cancelled_at timestamptz,
  purged_at timestamptz,
  run_id uuid,
  last_error text check (last_error is null or length(last_error) <= 300)
);
comment on table public.business_deletion_requests is
  'Owner requests to delete a business account: confirmed by a Zella Voice admin, frozen, purged 30 days later (kept after the purge)';
create unique index if not exists business_deletion_requests_open on public.business_deletion_requests (business_id) where status in ('requested', 'confirmed', 'blocked');
alter table public.business_deletion_requests enable row level security;
revoke all on public.business_deletion_requests from public, anon, authenticated;
grant all on public.business_deletion_requests to service_role;

create or replace function public.zella_business_deletion_freeze_note() returns text language sql immutable as $$ select 'Account deletion confirmed: frozen until it is deleted'::text $$;

-- what the owner's Settings page shows
create or replace function public.zella_business_deletion_status(p_business_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when public.zella_has_role(p_business_id, array['owner', 'admin']) then coalesce(
    (select jsonb_build_object('id', r.id, 'status', r.status, 'requested_at', r.requested_at, 'confirmed_at', r.confirmed_at, 'purge_after', r.purge_after)
       from public.business_deletion_requests r where r.business_id = p_business_id and r.status in ('requested', 'confirmed', 'blocked')), '{}'::jsonb) end
$$;

create or replace function public.zella_business_deletion_request(p_business_id uuid, p_confirm_name text, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare b public.businesses; r public.business_deletion_requests; v_reason text := left(btrim(coalesce(p_reason, '')), 300);
begin
  if auth.uid() is null or not exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = auth.uid()
                                         and m.role = 'owner' and m.status = 'active') then raise exception 'NOT_ALLOWED'; end if;
  if not public.zella_mfa_satisfied() then raise exception 'MFA_REQUIRED'; end if;
  select * into b from public.businesses where id = p_business_id for update;
  if coalesce(p_confirm_name, '') <> b.name then raise exception 'CONFIRM_MISMATCH'; end if;
  if length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  if exists (select 1 from public.business_deletion_requests where business_id = b.id and status in ('requested', 'confirmed', 'blocked')) then raise exception 'ALREADY_REQUESTED'; end if;
  insert into public.business_deletion_requests (business_id, business_name, reason, requested_by) values (b.id, b.name, v_reason, auth.uid()) returning * into r;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (b.id, auth.uid(), 'business.deletion_requested', 'business_deletion_request', r.id, jsonb_build_object('reason', v_reason));
  perform public.zella_platform_alert('business_deletion_requested', 'An owner asked to delete their account', b.name, 'warning', b.id, r.id::text);
  return jsonb_build_object('id', r.id, 'status', r.status);
end $$;

create or replace function public.zella_business_deletion_cancel(p_business_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.business_deletion_requests;
begin
  if auth.uid() is null or not (public.zella_has_role(p_business_id, array['owner']) or public.zella_admin_can('businesses.manage')) then raise exception 'NOT_ALLOWED'; end if;
  update public.business_deletion_requests set status = 'cancelled', cancelled_by = auth.uid(), cancelled_at = now()
   where business_id = p_business_id and status in ('requested', 'confirmed', 'blocked') returning * into r;
  if r.id is null then raise exception 'NOT_FOUND'; end if;
  -- lift only the freeze this flow put on (an admin's own suspension stays)
  update public.businesses set suspended_at = null, suspension_reason = null, updated_at = now()
   where id = p_business_id and suspension_reason = public.zella_business_deletion_freeze_note();
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id) values (p_business_id, auth.uid(), 'business.deletion_cancelled', 'business_deletion_request', r.id);
  perform public.zella_resolve_platform_alerts('business_deletion_requested', p_business_id, null, 'Cancelled');
  return jsonb_build_object('id', r.id, 'status', r.status);
end $$;

create or replace function public.zella_admin_business_deletion_confirm(p_business_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.business_deletion_requests; v_reason text := left(btrim(coalesce(p_reason, '')), 300);
begin
  -- security.manage, as for lane G's purges: the confirming admin is the run's approver and executor, who finishes
  -- the file removal (zella_business_purge_files_done needs it)
  perform public.zella_admin_require('security.manage');
  if length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  update public.business_deletion_requests set status = 'confirmed', confirmed_by = auth.uid(), confirmed_at = now(), purge_after = now() + interval '30 days'
   where business_id = p_business_id and status = 'requested' returning * into r;
  if r.id is null then raise exception 'NOT_FOUND'; end if;
  -- frozen at once: a suspended business isn't answered and its automations pause (the lifecycle rules)
  update public.businesses set suspended_at = coalesce(suspended_at, now()),
         suspension_reason = coalesce(suspension_reason, public.zella_business_deletion_freeze_note()), updated_at = now() where id = p_business_id;
  perform public.zella_admin_audit('business.deletion_confirmed', 'business_deletion_request', r.id, p_business_id, null,
    jsonb_build_object('purge_after', r.purge_after, 'reason', v_reason));
  begin
    perform public.zella_notify_owners(p_business_id, 'account_deletion_confirmed', 'Your account will be deleted',
      'Zella Voice confirmed your request. Your account is frozen and everything will be deleted on ' || to_char(r.purge_after, 'FMMonth FMDD, YYYY')
      || '. You can cancel until then in Settings.', 'warning', 'settings');
  exception when others then null;
  end;
  return jsonb_build_object('id', r.id, 'status', r.status, 'purge_after', r.purge_after);
end $$;

-- Zella Voice admins: the requests waiting, confirmed or blocked, and the last 50 closed ones
create or replace function public.zella_admin_business_deletion_requests()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.zella_admin_require('businesses.view');
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.requested_at desc) from (
    (select r.id, r.business_id, r.business_name, r.status, r.reason, r.requested_at, r.confirmed_at, r.purge_after, r.last_error
       from public.business_deletion_requests r where r.status in ('requested', 'confirmed', 'blocked'))
    union all
    (select r.id, r.business_id, r.business_name, r.status, r.reason, r.requested_at, r.confirmed_at, r.purge_after, r.last_error
       from public.business_deletion_requests r where r.status in ('cancelled', 'purged') order by r.requested_at desc limit 50)) x), '[]'::jsonb);
end $$;

-- the daily job: lane G's purge path for every confirmed request past its 30 days
create or replace function public.zella_business_deletion_purge_due()
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.business_deletion_requests; b public.businesses; v_run public.retention_purge_runs; v_paths text[]; v_audit int; v_why text; v_n int := 0;
begin
  if not coalesce((select value = 'true'::jsonb from public.platform_settings where key = 'retention_purge_enabled'), false) then
    return jsonb_build_object('skipped', 'switched_off');
  end if;
  -- the same lock as lane G's purges and zella_legal_hold_place: a hold never lands in the middle of a purge
  perform pg_advisory_xact_lock(hashtextextended('zella_legal_holds', 0));
  for r in select * from public.business_deletion_requests where status in ('confirmed', 'blocked') and purge_after <= now() order by purge_after for update skip locked loop
    select * into b from public.businesses where id = r.business_id for update;
    v_why := case
      when b.id is null then 'BUSINESS_NOT_FOUND'
      when public.zella_retention_on_hold(b.id) then 'LEGAL_HOLD'
      when (select confdeltype from pg_constraint where conrelid = 'public.audit_logs'::regclass and conname = 'audit_logs_business_id_fkey') is distinct from 'n'
           or position('deleted_business_id' in pg_get_functiondef('public.zella_audit_privileged()'::regprocedure)) = 0 then 'AUDIT_HISTORY_AT_RISK'
      when exists (select 1 from public.payments where business_id = b.id) or exists (select 1 from public.billing_events where business_id = b.id)
           or exists (select 1 from public.customer_charge_payments where business_id = b.id) or exists (select 1 from public.usage_charges where business_id = b.id)
           or (to_regclass('public.billing_periods') is not null and exists (select 1 from public.billing_periods where business_id = b.id)) then 'BILLING_RECORDS_KEPT'
      when exists (select 1 from public.offer_redemptions where business_id = b.id) then 'OFFER_HISTORY_KEPT'
      when exists (select 1 from public.business_phone_numbers where business_id = b.id) then 'NUMBERS_STILL_ASSIGNED' end;
    if v_why is not null then
      update public.business_deletion_requests set status = 'blocked', last_error = v_why where id = r.id;
      perform public.zella_platform_alert('business_deletion_blocked', 'An account deletion is waiting', r.business_name || ': ' || v_why, 'warning', r.business_id, r.id::text);
      continue;
    end if;
    perform public.zella_queue_provider_deletion(b.id, c.external_call_id, 'business_deletion') from public.calls c where c.business_id = b.id and c.external_call_id is not null;
    insert into public.retention_purge_runs (data_class, business_id, status, requested_by, request_reason, cutoff, items, item_count, owner_approved_by, owner_approved_at, executed_by, executed_at)
    values ('cancelled_business', b.id, 'running', r.requested_by, 'The owner asked to delete the account', now(), jsonb_build_array(jsonb_build_object('source', 'businesses', 'id', b.id)), 1,
            r.confirmed_by, r.confirmed_at, r.confirmed_by, now()) returning * into v_run;
    select coalesce(array_agg(distinct x order by x), '{}') into v_paths from (
      select 'business-documents/' || file_path as x from public.business_verification_documents where business_id = b.id
      union select 'record-files/' || path from public.crm_record_files where business_id = b.id
      union select o.bucket_id || '/' || o.name from storage.objects o
       where o.bucket_id in ('business-documents', 'record-files', 'brand-assets') and o.name like b.id::text || '/%') s;
    select count(*) into v_audit from public.audit_logs where business_id = b.id;
    perform public.zella_actor_audit(r.confirmed_by, 'business.purged', 'business', b.id, null,
      jsonb_build_object('name', b.name, 'industry_id', b.industry_id, 'created_at', b.created_at),
      jsonb_build_object('run', v_run.id, 'deletion_request', r.id, 'requested_at', r.requested_at, 'confirmed_at', r.confirmed_at,
                         'audit_rows_kept', v_audit, 'files_to_remove', coalesce(array_length(v_paths, 1), 0)));
    delete from public.legal_holds where business_id = b.id and released_at is not null;
    delete from public.businesses where id = b.id;
    update public.retention_purge_runs set status = case when coalesce(array_length(v_paths, 1), 0) > 0 then 'files_pending' else 'done' end,
           removed_count = 1, file_paths = v_paths, updated_at = now() where id = v_run.id;
    update public.business_deletion_requests set status = 'purged', purged_at = now(), run_id = v_run.id, last_error = null where id = r.id;
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('purged', v_n);
end $$;

revoke all on function public.zella_business_deletion_freeze_note(), public.zella_business_deletion_purge_due() from public, anon, authenticated;
grant execute on function public.zella_business_deletion_freeze_note(), public.zella_business_deletion_purge_due() to service_role;
revoke all on function public.zella_business_deletion_status(uuid), public.zella_business_deletion_request(uuid, text, text),
  public.zella_business_deletion_cancel(uuid), public.zella_admin_business_deletion_confirm(uuid, text), public.zella_admin_business_deletion_requests() from public, anon;
grant execute on function public.zella_business_deletion_status(uuid), public.zella_business_deletion_request(uuid, text, text),
  public.zella_business_deletion_cancel(uuid), public.zella_admin_business_deletion_confirm(uuid, text), public.zella_admin_business_deletion_requests() to authenticated, service_role;

-- the daily group runs it (after zella_retention_auto_run, which sql/zella_privacy_retention.sql added)
do $$
declare d text; s1 constant text := 'public.zella_run_scheduled_job(text)'; s2 constant text := 'public.zella_run_schedule_group(text)';
  a1 constant text := $a$  if p_job not in ('zella_retention_auto_run', '$a$;
  w1 constant text := $w$  if p_job not in ('zella_retention_auto_run', 'zella_business_deletion_purge_due', '$w$;
  a2 constant text := $a$'zella_retention_auto_run']$a$;
  w2 constant text := $w$'zella_retention_auto_run', 'zella_business_deletion_purge_due']$w$;
begin
  d := pg_get_functiondef(s1::regprocedure);
  if position('zella_business_deletion_purge_due' in d) = 0 then
    if (length(d) - length(replace(d, a1, ''))) / length(a1) <> 1 then raise exception 'VERSION_MISMATCH: % (apply sql/zella_privacy_retention.sql first)', s1; end if;
    insert into public.zella_function_archive (migration, signature, definition, definition_md5) values ('zella_account_deletion', s1, d, md5(d)) on conflict do nothing;
    execute replace(d, a1, w1);
  end if;
  d := pg_get_functiondef(s2::regprocedure);
  if position('zella_business_deletion_purge_due' in d) = 0 then
    if (length(d) - length(replace(d, a2, ''))) / length(a2) <> 1 then raise exception 'VERSION_MISMATCH: % (apply sql/zella_privacy_retention.sql first)', s2; end if;
    insert into public.zella_function_archive (migration, signature, definition, definition_md5) values ('zella_account_deletion', s2, d, md5(d)) on conflict do nothing;
    execute replace(d, a2, w2);
  end if;
end $$;

commit;
