-- Zella Voice: an approved purge of data past its retention period, run by hand, one run at a time, by two people
-- (docs/ADMIN_AUDIT_2026-11-16.md SET-RETENTION, BIZ-18b; REQ-PRV-01). sql/zella_data_retention.sql lists what is past
-- its period (the dry run); this file lets it be removed, and only when every guard agrees:
--   1. a server only table, retention_purge_runs: one row per run, holding the exact rows listed when it was asked for
--      (at most 1000, oldest first), so approving a run approves those rows and nothing that appears later;
--   2. request (security.manage, a reason): refused while the kind's period is still pending legal review
--      (LEGAL_REVIEW_PENDING) or when nothing is past its period. Whole businesses are not purged here
--      (sql/zella_business_purge.sql);
--   3. approve: two different people, one of them a Zella Voice owner, the other an owner or holds security.manage
--      (the person who asked may be one of them);
--   4. execute: only one of the two approvers, only while retention_purge_enabled is true (PURGE_SWITCHED_OFF), only
--      while the kind is still legally approved, and only with the typed confirmation "PURGE <number of rows>". Rows
--      that are no longer past their period, or whose business went on a legal hold, are left alone. Recordings and
--      message words are removed from their row (the row stays); a transcript is replaced by 'Removed under the
--      retention policy.' (emptying it would make zella_call_integrity re-mark a short old call as missed and start a
--      callback); old audit rows are deleted;
--      document rows are kept (the verification outcome) and their files are handed to the server to remove from
--      storage, then recorded in retention_removed_files (files_done);
--   5. every step is audited in the same transaction, with counts and never content.
-- Nothing is scheduled, here or anywhere: a run happens only when two people approve it and one of them runs it.
-- Every function here is new. If one already exists it must be exactly this file's version (VERSION_MISMATCH otherwise).
-- Needs sql/zella_data_retention.sql. Rollback: sql/rollback/zella_retention_purge_rollback.sql
begin;

do $$
declare
  f record;
  mine constant jsonb := '{
    "public.zella_retention_run_request(uuid,text,text)": "5b7a202c8301b7bc61b91027a0a4df21",
    "public.zella_retention_run_approve(uuid,uuid,text)": "eb2ce3685d80968db535e35930b93a93",
    "public.zella_retention_run_execute(uuid,uuid,text)": "ba48c56b8077b51afb6e7b17f6150fd4",
    "public.zella_retention_run_files_done(uuid,uuid,text[],text)": "dac2d38238f1817aa8500a152382e6b5",
    "public.zella_retention_run_cancel(uuid,uuid,text)": "f7808954fe2da8c900c77f9c1827fb29",
    "public.zella_retention_runs(uuid,integer)": "64a8d562f80cdf654e0cc185804c58ac",
    "public.zella_retention_run_files_resume(uuid,uuid)": "2daf163e4a47b309ad52d92c382ec4ec"
  }';
begin
  if to_regprocedure('public.zella_retention_candidates(text,timestamp with time zone)') is null or to_regclass('public.data_retention_policies') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing (apply sql/zella_data_retention.sql first)';
  end if;
  if (to_regclass('public.retention_purge_runs') is not null and not exists (select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'retention_purge_runs' and column_name = 'second_approved_by'))
     or to_regclass('public.retention_removed_files') is null then
    raise exception 'VERSION_MISMATCH: a different retention_purge_runs table exists, or retention_removed_files is missing';
  end if;
  for f in select key as sig, value #>> '{}' as want from jsonb_each(mine) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'VERSION_MISMATCH: % exists and is not this file''s version', f.sig;
    end if;
  end loop;
end $$;

create table if not exists public.retention_purge_runs (
  id uuid primary key default gen_random_uuid(),
  data_class text not null references public.data_retention_policies(data_class),
  business_id uuid,
  status text not null default 'requested'
    check (status in ('requested', 'approved', 'running', 'files_pending', 'done', 'failed', 'cancelled')),
  requested_by uuid not null,
  request_reason text not null check (length(btrim(request_reason)) between 3 and 300),
  cutoff timestamptz not null,
  items jsonb not null default '[]'::jsonb,
  item_count integer not null check (item_count between 0 and 1000),
  export_offered_at timestamptz,
  export_offer_note text check (export_offer_note is null or length(export_offer_note) <= 300),
  owner_approved_by uuid,
  owner_approved_at timestamptz,
  second_approved_by uuid,
  second_approved_at timestamptz,
  executed_by uuid,
  executed_at timestamptz,
  removed_count integer,
  file_paths text[] not null default '{}',
  files_removed integer,
  error text check (error is null or length(error) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (owner_approved_by is null or second_approved_by is null or owner_approved_by <> second_approved_by)
);
-- every listed file the server has confirmed gone (removed now or already absent), so a stopped removal can be finished
alter table public.retention_purge_runs add column if not exists removed_paths text[] not null default '{}';
create unique index if not exists retention_purge_runs_one_open on public.retention_purge_runs (data_class, coalesce(business_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where status in ('requested', 'approved', 'running', 'files_pending');
alter table public.retention_purge_runs enable row level security;
revoke all on table public.retention_purge_runs from public, anon, authenticated;
grant all on table public.retention_purge_runs to service_role;

create or replace function public.zella_retention_run_request(p_actor uuid, p_class text, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p public.data_retention_policies; r public.retention_purge_runs; v_reason text := left(btrim(coalesce(p_reason, '')), 300);
        v_cutoff timestamptz; v_items jsonb;
begin
  if not public.zella_actor_can(p_actor, 'security.manage') then raise exception 'NOT_ALLOWED'; end if;
  if length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  select * into p from public.data_retention_policies where data_class = p_class;
  if p.data_class is null then raise exception 'UNKNOWN_CLASS'; end if;
  if p.data_class = 'cancelled_business' then raise exception 'BUSINESS_PURGE_SEPARATE'; end if;
  if p.legal_status <> 'approved' then raise exception 'LEGAL_REVIEW_PENDING'; end if;
  if exists (select 1 from public.retention_purge_runs where data_class = p_class and business_id is null and status in ('requested', 'approved', 'running', 'files_pending')) then
    raise exception 'RUN_OPEN';
  end if;
  v_cutoff := now() - make_interval(days => p.days);
  select coalesce(jsonb_agg(jsonb_build_object('source', source, 'id', row_id) order by dated, row_id), '[]'::jsonb) into v_items
    from (select * from public.zella_retention_candidates(p_class, v_cutoff) order by dated, row_id limit 1000) c;
  if jsonb_array_length(v_items) = 0 then raise exception 'NOTHING_TO_PURGE'; end if;
  insert into public.retention_purge_runs (data_class, requested_by, request_reason, cutoff, items, item_count)
  values (p_class, p_actor, v_reason, v_cutoff, v_items, jsonb_array_length(v_items)) returning * into r;
  perform public.zella_actor_audit(p_actor, 'retention.purge_requested', 'retention_purge_run', r.id, null, null,
    jsonb_build_object('data_class', p_class, 'items', r.item_count, 'cutoff', v_cutoff, 'days', p.days, 'reason', v_reason));
  return to_jsonb(r) - 'items';
end $$;

-- Two different people: one a Zella Voice owner, the other an owner or someone holding security.manage.
create or replace function public.zella_retention_run_approve(p_actor uuid, p_run uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.retention_purge_runs; v_reason text := left(btrim(coalesce(p_reason, '')), 300); v_slot text;
begin
  if not public.zella_actor_can(p_actor, 'security.manage') then raise exception 'NOT_ALLOWED'; end if;
  if length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  select * into r from public.retention_purge_runs where id = p_run for update;
  if r.id is null then raise exception 'NOT_FOUND'; end if;
  if r.status <> 'requested' then raise exception 'NOT_PENDING'; end if;
  if coalesce(p_actor = any (array_remove(array[r.owner_approved_by, r.second_approved_by], null)), false) then raise exception 'ALREADY_APPROVED'; end if;
  if public.zella_actor_role(p_actor) = 'zella_owner' and r.owner_approved_by is null then
    v_slot := 'owner';
    update public.retention_purge_runs set owner_approved_by = p_actor, owner_approved_at = now(), updated_at = now() where id = r.id returning * into r;
  elsif r.second_approved_by is null then
    v_slot := 'second';
    update public.retention_purge_runs set second_approved_by = p_actor, second_approved_at = now(), updated_at = now() where id = r.id returning * into r;
  else
    raise exception 'OWNER_REQUIRED';
  end if;
  if r.owner_approved_by is not null and r.second_approved_by is not null then
    update public.retention_purge_runs set status = 'approved', updated_at = now() where id = r.id returning * into r;
  end if;
  perform public.zella_actor_audit(p_actor, 'retention.purge_approved', 'retention_purge_run', r.id, r.business_id, null,
    jsonb_build_object('as', v_slot, 'status', r.status, 'data_class', r.data_class, 'items', r.item_count, 'reason', v_reason));
  return to_jsonb(r) - 'items';
end $$;

-- The purge itself. Every guard is checked here, whoever calls it.
create or replace function public.zella_retention_run_execute(p_actor uuid, p_run uuid, p_confirm text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.retention_purge_runs; p public.data_retention_policies; v_now jsonb; v_n int := 0; v_k int; v_paths text[] := '{}';
begin
  select * into r from public.retention_purge_runs where id = p_run for update;
  if r.id is null then raise exception 'NOT_FOUND'; end if;
  if p_actor is null or not coalesce(p_actor = any (array_remove(array[r.owner_approved_by, r.second_approved_by], null)), false) then raise exception 'APPROVER_REQUIRED'; end if;
  if not public.zella_actor_can(p_actor, 'security.manage') then raise exception 'NOT_ALLOWED'; end if;
  if not coalesce((select value = 'true'::jsonb from public.platform_settings where key = 'retention_purge_enabled'), false) then
    raise exception 'PURGE_SWITCHED_OFF';
  end if;
  if r.status <> 'approved' then raise exception 'NOT_APPROVED'; end if;
  if r.data_class = 'cancelled_business' or r.business_id is not null then raise exception 'BUSINESS_PURGE_SEPARATE'; end if;
  select * into p from public.data_retention_policies where data_class = r.data_class;
  if p.legal_status <> 'approved' then raise exception 'LEGAL_REVIEW_PENDING'; end if;
  if coalesce(btrim(p_confirm), '') <> 'PURGE ' || r.item_count then raise exception 'CONFIRM_MISMATCH'; end if;
  update public.retention_purge_runs set status = 'running', executed_by = p_actor, executed_at = now(), updated_at = now() where id = r.id;
  -- legal holds are placed and released under the same lock, so a hold can't land between this read and the removal
  perform pg_advisory_xact_lock(hashtextextended('zella_legal_holds', 0));

  -- only the rows listed when the run was asked for that are still past their period (the earlier of the approved
  -- cutoff and the cutoff of the period as it is now, so a longer period never removes a row it now keeps) and not on
  -- hold
  select coalesce(jsonb_agg(jsonb_build_object('source', c.source, 'id', c.row_id)), '[]'::jsonb) into v_now
    from public.zella_retention_candidates(r.data_class, least(r.cutoff, now() - make_interval(days => p.days))) c
   where exists (select 1 from jsonb_array_elements(r.items) i where i ->> 'source' = c.source and (i ->> 'id')::uuid = c.row_id);

  if r.data_class = 'call_recordings' then
    update public.calls set recording_url = null where id in (select (x ->> 'id')::uuid from jsonb_array_elements(v_now) x where x ->> 'source' = 'calls'); get diagnostics v_n = row_count;
  elsif r.data_class = 'call_transcripts' then
    update public.calls set transcript = 'Removed under the retention policy.' where id in (select (x ->> 'id')::uuid from jsonb_array_elements(v_now) x where x ->> 'source' = 'calls'); get diagnostics v_n = row_count;
  elsif r.data_class = 'message_bodies' then
    update public.sms_messages set message_body = null where id in (select (x ->> 'id')::uuid from jsonb_array_elements(v_now) x where x ->> 'source' = 'sms_messages'); get diagnostics v_k = row_count; v_n := v_k;
    update public.email_messages set body_text = null, body_html = null where id in (select (x ->> 'id')::uuid from jsonb_array_elements(v_now) x where x ->> 'source' = 'email_messages'); get diagnostics v_k = row_count; v_n := v_n + v_k;
    update public.conversation_messages set content = null where id in (select (x ->> 'id')::uuid from jsonb_array_elements(v_now) x where x ->> 'source' = 'conversation_messages'); get diagnostics v_k = row_count; v_n := v_n + v_k;
  elsif r.data_class = 'audit_logs' then
    delete from public.audit_logs where id in (select (x ->> 'id')::uuid from jsonb_array_elements(v_now) x where x ->> 'source' = 'audit_logs'); get diagnostics v_n = row_count;
  elsif r.data_class like 'documents_%' then
    select coalesce(array_agg(d.file_path order by d.file_path), '{}') into v_paths from public.business_verification_documents d
     where d.id in (select (x ->> 'id')::uuid from jsonb_array_elements(v_now) x where x ->> 'source' = 'business_verification_documents')
       and not exists (select 1 from public.retention_removed_files f where f.document_id = d.id);
    v_n := coalesce(array_length(v_paths, 1), 0);
  end if;

  update public.retention_purge_runs set status = case when r.data_class like 'documents_%' and v_n > 0 then 'files_pending' else 'done' end,
         removed_count = case when r.data_class like 'documents_%' then 0 else v_n end, file_paths = v_paths, updated_at = now()
   where id = r.id returning * into r;
  perform public.zella_actor_audit(p_actor, 'retention.purge_executed', 'retention_purge_run', r.id, null, null,
    jsonb_build_object('data_class', r.data_class, 'listed', r.item_count, 'removed', r.removed_count, 'files_to_remove', coalesce(array_length(v_paths, 1), 0),
                       'skipped', r.item_count - v_n));
  return to_jsonb(r) - 'items';
end $$;

-- The server removed the document files from storage: record which, so the dry run doesn't list them again.
create or replace function public.zella_retention_run_files_done(p_actor uuid, p_run uuid, p_removed text[], p_error text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.retention_purge_runs; v_new int; v_total int; v_listed int;
begin
  select * into r from public.retention_purge_runs where id = p_run for update;
  if r.id is null then raise exception 'NOT_FOUND'; end if;
  if r.data_class = 'cancelled_business' or r.business_id is not null then raise exception 'BUSINESS_PURGE_SEPARATE'; end if;
  -- only the attempt in progress reports (execute, or files_resume after a stop); a late report once the run was
  -- recorded as failed changes nothing
  if r.status <> 'files_pending' or r.executed_at is null then raise exception 'NOT_RUNNING'; end if;
  if p_actor is null or not coalesce(p_actor = any (array_remove(array[r.executed_by, r.owner_approved_by, r.second_approved_by], null)), false) then
    raise exception 'APPROVER_REQUIRED';
  end if;
  if not public.zella_actor_can(p_actor, 'security.manage') then raise exception 'NOT_ALLOWED'; end if;
  insert into public.retention_removed_files (document_id, file_path, run_id)
  select d.id, d.file_path, r.id from public.business_verification_documents d
   where d.file_path = any (r.file_paths) and d.file_path = any (coalesce(p_removed, '{}'))
  on conflict (document_id) do nothing;
  get diagnostics v_new = row_count;
  v_listed := coalesce(array_length(r.file_paths, 1), 0);
  update public.retention_purge_runs
     set removed_paths = (select coalesce(array_agg(distinct x order by x), '{}') from unnest(removed_paths || array(
                            select f from unnest(r.file_paths) f where f = any (coalesce(p_removed, '{}')))) x),
         updated_at = now()
   where id = r.id returning * into r;
  v_total := coalesce(array_length(r.removed_paths, 1), 0);
  update public.retention_purge_runs set status = case when p_error is null and v_total = v_listed then 'done' else 'failed' end,
         files_removed = v_total, removed_count = v_total, error = left(p_error, 500), updated_at = now()
   where id = r.id returning * into r;
  perform public.zella_actor_audit(p_actor, 'retention.purge_files_removed', 'retention_purge_run', r.id, null, null,
    jsonb_build_object('data_class', r.data_class, 'files_removed_now', v_new, 'files_removed', v_total, 'files_listed', v_listed, 'error', r.error));
  return to_jsonb(r) - 'items';
end $$;

-- resume a stopped file removal. One attempt at a time: refused (REMOVAL_IN_PROGRESS) while the run is files_pending
-- and was last changed less than 10 minutes ago, longer than any request to the server can run, so an earlier attempt
-- has ended before another starts. The same rules as execute apply again now: the purge switch on, the period still
-- legally approved, and only files of documents still past their period (the earlier of the approved cutoff and the
-- current period) and not on a legal hold. The run goes back to files_pending, so no hold can be placed for a business
-- whose files it lists until the attempt reports through files_done.
create or replace function public.zella_retention_run_files_resume(p_actor uuid, p_run uuid)
returns text[] language plpgsql security definer set search_path = public as $$
declare r public.retention_purge_runs; p public.data_retention_policies;
begin
  perform pg_advisory_xact_lock(hashtextextended('zella_legal_holds', 0));
  select * into r from public.retention_purge_runs where id = p_run for update;
  if r.id is null then raise exception 'NOT_FOUND'; end if;
  if r.data_class = 'cancelled_business' or r.business_id is not null then raise exception 'BUSINESS_PURGE_SEPARATE'; end if;
  if r.status not in ('files_pending', 'failed') or r.executed_at is null then raise exception 'NOT_RUNNING'; end if;
  if p_actor is null or not coalesce(p_actor = any (array_remove(array[r.executed_by, r.owner_approved_by, r.second_approved_by], null)), false) then
    raise exception 'APPROVER_REQUIRED';
  end if;
  if not public.zella_actor_can(p_actor, 'security.manage') then raise exception 'NOT_ALLOWED'; end if;
  if r.status = 'files_pending' and r.updated_at > now() - interval '10 minutes' then raise exception 'REMOVAL_IN_PROGRESS'; end if;
  if not coalesce((select value = 'true'::jsonb from public.platform_settings where key = 'retention_purge_enabled'), false) then
    raise exception 'PURGE_SWITCHED_OFF';
  end if;
  select * into p from public.data_retention_policies where data_class = r.data_class;
  if p.legal_status is distinct from 'approved' then raise exception 'LEGAL_REVIEW_PENDING'; end if;
  update public.retention_purge_runs set status = 'files_pending', updated_at = now() where id = r.id;
  return array(select d.file_path from public.business_verification_documents d
                where d.file_path = any (r.file_paths) and not (d.file_path = any (r.removed_paths))
                  and d.id in (select c.row_id from public.zella_retention_candidates(r.data_class, least(r.cutoff, now() - make_interval(days => p.days))) c
                                where c.source = 'business_verification_documents')
                order by d.file_path);
end $$;

create or replace function public.zella_retention_run_cancel(p_actor uuid, p_run uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.retention_purge_runs; v_reason text := left(btrim(coalesce(p_reason, '')), 300);
begin
  if not public.zella_actor_can(p_actor, 'security.manage') then raise exception 'NOT_ALLOWED'; end if;
  if length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  update public.retention_purge_runs set status = 'cancelled', error = left('Cancelled: ' || v_reason, 500), updated_at = now()
   where id = p_run and status in ('requested', 'approved') returning * into r;
  if r.id is null then raise exception 'NOT_PENDING'; end if;
  perform public.zella_actor_audit(p_actor, 'retention.purge_cancelled', 'retention_purge_run', r.id, r.business_id, null,
    jsonb_build_object('data_class', r.data_class, 'reason', v_reason));
  return to_jsonb(r) - 'items';
end $$;

create or replace function public.zella_retention_runs(p_actor uuid, p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.zella_actor_can(p_actor, 'security.view') then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((select jsonb_agg(to_jsonb(r) - 'items' - 'file_paths' || jsonb_build_object(
      'requested_by_email', (select email from auth.users where id = r.requested_by),
      'owner_approved_by_email', (select email from auth.users where id = r.owner_approved_by),
      'second_approved_by_email', (select email from auth.users where id = r.second_approved_by),
      'business_name', (select name from public.businesses where id = r.business_id),
      'files_left', (select count(*) from unnest(r.file_paths) f where not (f = any (r.removed_paths)))) order by r.created_at desc)
    from (select * from public.retention_purge_runs order by created_at desc limit least(greatest(coalesce(p_limit, 50), 1), 200)) r), '[]'::jsonb);
end $$;

revoke all on function public.zella_retention_run_request(uuid, text, text), public.zella_retention_run_approve(uuid, uuid, text),
  public.zella_retention_run_execute(uuid, uuid, text), public.zella_retention_run_files_done(uuid, uuid, text[], text),
  public.zella_retention_run_cancel(uuid, uuid, text), public.zella_retention_runs(uuid, integer),
  public.zella_retention_run_files_resume(uuid, uuid) from public, anon, authenticated;
grant execute on function public.zella_retention_run_request(uuid, text, text), public.zella_retention_run_approve(uuid, uuid, text),
  public.zella_retention_run_execute(uuid, uuid, text), public.zella_retention_run_files_done(uuid, uuid, text[], text),
  public.zella_retention_run_cancel(uuid, uuid, text), public.zella_retention_runs(uuid, integer),
  public.zella_retention_run_files_resume(uuid, uuid) to service_role;

commit;
