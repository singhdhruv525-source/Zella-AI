-- Zella Voice: an owner approved purge of a cancelled business past its retention date, the whole business at once
-- (docs/ADMIN_AUDIT_2026-11-16.md BIZ-13d; ARCHITECTURE.md REQ-LC-20, REQ-PRV-01). Cancelled businesses were kept
-- forever: nothing could delete one, and deleting one by hand would also have erased its audit history.
-- The same purge runs as sql/zella_retention_purge.sql (two different people, one a Zella Voice owner, approve with
-- zella_retention_run_approve), with these steps of its own:
--   1. zella_business_purge_request(admin, business, export offered at, how it was offered, reason): security.manage.
--      Only a business the dry run lists (cancelled, at least the "cancelled_business" period ago, past its
--      retention_until, not on a legal hold), only while that period is legally approved, and only with the final
--      export offer recorded (when and how the owner was offered their data). The whole business export job isn't
--      built yet (lane B, B8 and B9): until it is, the admin records the offer they made.
--   2. zella_business_purge_execute(admin, run, typed name): only one of the two approvers; only while
--      retention_purge_enabled is on, the period is still approved, the business is still listed (cancelled, past
--      retention, no hold) and at least 14 days have passed since the export offer; only with the business's name
--      typed exactly. Refused while:
--        * deleting would erase its audit history: audit_logs.business_id must not be ON DELETE CASCADE and
--          zella_audit_privileged must keep a deleted business's rows. Lane B's sql/zella_draft_delete.sql does both
--          (ACC-10, the owner's decision of 16 Nov 2026: audit history kept, business_id set null), so this refuses
--          until that file is applied (AUDIT_HISTORY_AT_RISK);
--        * it has payment or billing records (BILLING_RECORDS_KEPT): how long those are kept after a business is
--          deleted is a legal decision not taken yet;
--        * it has offer history (OFFER_HISTORY_KEPT) or phone numbers still in Zella Voice (NUMBERS_STILL_ASSIGNED:
--          release them first, which is also where the Telnyx and Vapi copies are dealt with).
--      Then, in one transaction: the purge is audited (name, dates, counts; never content), released legal holds of
--      the business are removed, and the business row is deleted, which removes everything that belongs to it. Its
--      storage files (verification documents, record files, brand images under the business's folder) are handed to
--      the server to remove, then recorded (zella_business_purge_files_done).
-- Nothing is scheduled. Every function here is new; if one already exists it must be exactly this file's version.
-- Needs sql/zella_retention_purge.sql. Rollback: sql/rollback/zella_business_purge_rollback.sql
begin;

do $$
declare
  f record;
  mine constant jsonb := '{
    "public.zella_business_purge_request(uuid,uuid,timestamp with time zone,text,text)": "605fbfcb53d71fe8f9bdd0aa8df8d58a",
    "public.zella_business_purge_execute(uuid,uuid,text)": "a3b29b5adcb84dadb12b2ebbe3a87ceb",
    "public.zella_business_purge_files_done(uuid,uuid,text[],text)": "61fb59cee8b0ff4f2c20e068ca7e1428"
  }';
begin
  if to_regprocedure('public.zella_retention_run_approve(uuid,uuid,text)') is null or to_regclass('public.retention_purge_runs') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing (apply sql/zella_retention_purge.sql first)';
  end if;
  for f in select key as sig, value #>> '{}' as want from jsonb_each(mine) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'VERSION_MISMATCH: % exists and is not this file''s version', f.sig;
    end if;
  end loop;
end $$;

create or replace function public.zella_business_purge_request(p_actor uuid, p_business uuid, p_offered_at timestamptz, p_offer_note text, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p public.data_retention_policies; r public.retention_purge_runs; v_reason text := left(btrim(coalesce(p_reason, '')), 300);
        v_note text := left(btrim(coalesce(p_offer_note, '')), 300); v_cutoff timestamptz; v_name text;
begin
  if not public.zella_actor_can(p_actor, 'security.manage') then raise exception 'NOT_ALLOWED'; end if;
  if length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  select * into p from public.data_retention_policies where data_class = 'cancelled_business';
  if p.legal_status <> 'approved' then raise exception 'LEGAL_REVIEW_PENDING'; end if;
  if p_offered_at is null or p_offered_at > now() or length(v_note) < 3 then raise exception 'EXPORT_OFFER_REQUIRED'; end if;
  select name into v_name from public.businesses where id = p_business;
  if v_name is null then raise exception 'BUSINESS_NOT_FOUND'; end if;
  v_cutoff := now() - make_interval(days => p.days);
  if not exists (select 1 from public.zella_retention_candidates('cancelled_business', v_cutoff) where row_id = p_business) then
    raise exception 'NOT_PAST_RETENTION';
  end if;
  if exists (select 1 from public.retention_purge_runs where business_id = p_business and status in ('requested', 'approved', 'running', 'files_pending')) then
    raise exception 'RUN_OPEN';
  end if;
  insert into public.retention_purge_runs (data_class, business_id, requested_by, request_reason, cutoff, items, item_count, export_offered_at, export_offer_note)
  values ('cancelled_business', p_business, p_actor, v_reason, v_cutoff, jsonb_build_array(jsonb_build_object('source', 'businesses', 'id', p_business)), 1, p_offered_at, v_note)
  returning * into r;
  perform public.zella_actor_audit(p_actor, 'business.purge_requested', 'retention_purge_run', r.id, p_business, null,
    jsonb_build_object('business', v_name, 'export_offered_at', p_offered_at, 'export_offer', v_note, 'reason', v_reason));
  return to_jsonb(r) - 'items';
end $$;

create or replace function public.zella_business_purge_execute(p_actor uuid, p_run uuid, p_confirm_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.retention_purge_runs; p public.data_retention_policies; b public.businesses; v_paths text[]; v_audit int; v_released int;
begin
  select * into r from public.retention_purge_runs where id = p_run for update;
  if r.id is null or r.data_class <> 'cancelled_business' or r.business_id is null then raise exception 'NOT_FOUND'; end if;
  if p_actor is null or not coalesce(p_actor = any (array_remove(array[r.owner_approved_by, r.second_approved_by], null)), false) then raise exception 'APPROVER_REQUIRED'; end if;
  if not public.zella_actor_can(p_actor, 'security.manage') then raise exception 'NOT_ALLOWED'; end if;
  if not coalesce((select value = 'true'::jsonb from public.platform_settings where key = 'retention_purge_enabled'), false) then raise exception 'PURGE_SWITCHED_OFF'; end if;
  if r.status <> 'approved' then raise exception 'NOT_APPROVED'; end if;
  select * into p from public.data_retention_policies where data_class = 'cancelled_business';
  if p.legal_status <> 'approved' then raise exception 'LEGAL_REVIEW_PENDING'; end if;
  select * into b from public.businesses where id = r.business_id for update;
  if b.id is null then raise exception 'BUSINESS_NOT_FOUND'; end if;
  if coalesce(p_confirm_name, '') <> b.name then raise exception 'CONFIRM_MISMATCH'; end if;
  if not exists (select 1 from public.zella_retention_candidates('cancelled_business', now() - make_interval(days => p.days)) where row_id = b.id) then
    raise exception 'NOT_PAST_RETENTION';
  end if;
  if r.export_offered_at is null or r.export_offered_at > now() - interval '14 days' then raise exception 'EXPORT_OFFER_TOO_RECENT'; end if;
  if (select confdeltype from pg_constraint where conrelid = 'public.audit_logs'::regclass and conname = 'audit_logs_business_id_fkey') is distinct from 'n'
     or position('deleted_business_id' in pg_get_functiondef('public.zella_audit_privileged()'::regprocedure)) = 0 then
    raise exception 'AUDIT_HISTORY_AT_RISK: needs sql/zella_draft_delete.sql and audit_logs.business_id not CASCADE (ACC-10)';
  end if;
  if exists (select 1 from public.payments where business_id = b.id) or exists (select 1 from public.billing_events where business_id = b.id)
     or exists (select 1 from public.customer_charge_payments where business_id = b.id) or exists (select 1 from public.usage_charges where business_id = b.id) then
    raise exception 'BILLING_RECORDS_KEPT';
  end if;
  if exists (select 1 from public.offer_redemptions where business_id = b.id) then raise exception 'OFFER_HISTORY_KEPT'; end if;
  if exists (select 1 from public.business_phone_numbers where business_id = b.id) then raise exception 'NUMBERS_STILL_ASSIGNED'; end if;

  update public.retention_purge_runs set status = 'running', executed_by = p_actor, executed_at = now(), updated_at = now() where id = r.id;
  select coalesce(array_agg(distinct x order by x), '{}') into v_paths from (
    select 'business-documents/' || file_path as x from public.business_verification_documents where business_id = b.id
    union select 'record-files/' || path from public.crm_record_files where business_id = b.id
    union select o.bucket_id || '/' || o.name from storage.objects o
     where o.bucket_id in ('business-documents', 'record-files', 'brand-assets') and o.name like b.id::text || '/%') s;
  select count(*) into v_audit from public.audit_logs where business_id = b.id;
  perform public.zella_actor_audit(p_actor, 'business.purged', 'business', b.id, null,
    jsonb_build_object('name', b.name, 'industry_id', b.industry_id, 'created_at', b.created_at, 'cancelled_at', b.cancelled_at, 'retention_until', b.retention_until),
    jsonb_build_object('run', r.id, 'export_offered_at', r.export_offered_at, 'export_offer', r.export_offer_note, 'audit_rows_kept', v_audit,
                       'files_to_remove', coalesce(array_length(v_paths, 1), 0)));
  delete from public.legal_holds where business_id = b.id and released_at is not null;
  get diagnostics v_released = row_count;
  delete from public.businesses where id = b.id;
  update public.retention_purge_runs set status = case when coalesce(array_length(v_paths, 1), 0) > 0 then 'files_pending' else 'done' end,
         removed_count = 1, file_paths = v_paths, updated_at = now() where id = r.id returning * into r;
  return to_jsonb(r) - 'items';
end $$;

create or replace function public.zella_business_purge_files_done(p_actor uuid, p_run uuid, p_removed text[], p_error text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.retention_purge_runs; v_n int;
begin
  select * into r from public.retention_purge_runs where id = p_run for update;
  if r.id is null or r.data_class <> 'cancelled_business' then raise exception 'NOT_FOUND'; end if;
  if r.status <> 'files_pending' then raise exception 'NOT_RUNNING'; end if;
  if p_actor is distinct from r.executed_by then raise exception 'APPROVER_REQUIRED'; end if;
  select count(*) into v_n from unnest(r.file_paths) f where f = any (coalesce(p_removed, '{}'));
  update public.retention_purge_runs set status = case when p_error is null and v_n = coalesce(array_length(r.file_paths, 1), 0) then 'done' else 'failed' end,
         files_removed = v_n, error = left(p_error, 500), updated_at = now() where id = r.id returning * into r;
  perform public.zella_actor_audit(p_actor, 'business.purge_files_removed', 'retention_purge_run', r.id, null, null,
    jsonb_build_object('business_id', r.business_id, 'files_removed', v_n, 'files_listed', coalesce(array_length(r.file_paths, 1), 0), 'error', r.error));
  return to_jsonb(r) - 'items';
end $$;

revoke all on function public.zella_business_purge_request(uuid, uuid, timestamptz, text, text), public.zella_business_purge_execute(uuid, uuid, text),
  public.zella_business_purge_files_done(uuid, uuid, text[], text) from public, anon, authenticated;
grant execute on function public.zella_business_purge_request(uuid, uuid, timestamptz, text, text), public.zella_business_purge_execute(uuid, uuid, text),
  public.zella_business_purge_files_done(uuid, uuid, text[], text) to service_role;

commit;
