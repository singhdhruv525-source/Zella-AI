-- Photos and files on records (5 Nov 2026): job photos, inspection photos, signed estimates, before / after pictures,
-- damage reports, documents a customer sent.
--
--   * Stored in a private bucket, "record-files" (never public): images (JPEG, PNG, WEBP, HEIC) and PDFs, 10 MB each,
--     at most 50 per record. Paths are <business>/<record>/<random>.<ext>; nothing in a path is chosen by the user.
--   * Uploading is two steps: zella_begin_record_file checks the person (staff and above), the record (this business,
--     not archived), the type and size, and reserves one path; the storage policy then accepts an upload to exactly
--     that reserved path by that person; zella_finish_record_file confirms the file arrived (and its type and size)
--     and adds it to the record's history.
--   * Who sees a file: members of the business. A file marked private is seen only by owners, admins, managers and
--     staff assigned to the record or to a current job linked to it (the same rule as private fields). In health, legal,
--     financial, insurance, vet and childcare businesses every file is private.
--   * Removing: owners, admins and managers, or the uploader within a day. The file disappears from the record at once
--     (no one can open it), and the storage object can then be deleted. Every addition and removal is in the record's
--     history: by file name, or as "A private file" for private ones (a name can give away what the file shows).
--   * Viewing goes through short-lived signed links that storage only issues to people the policy allows; individual
--     views of a file aren't written to the record's history (storage keeps its own access log).
-- Needs zella_viewer_read_only.sql, zella_call_content_privacy.sql and zella_record_links_secrets.sql. Safe to run twice.
-- Needs the owner's approval before it is applied.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('record-files', 'record-files', false, 10485760, array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

create table if not exists public.crm_record_files (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  record_id uuid not null references public.crm_records(id) on delete cascade,
  path text not null unique,
  file_name text not null,
  mime_type text not null check (mime_type in ('image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf')),
  size_bytes bigint not null check (size_bytes > 0 and size_bytes <= 10485760),
  kind text not null check (kind in ('photo', 'document')),
  caption text,
  private boolean not null default false,
  status text not null default 'pending' check (status in ('pending', 'ready', 'removed')),
  uploaded_by uuid,
  created_at timestamptz not null default now(),
  removed_at timestamptz,
  removed_by uuid
);
create index if not exists crm_record_files_record on public.crm_record_files (record_id, created_at desc);
alter table public.crm_record_files enable row level security;
revoke all on public.crm_record_files from anon, authenticated;
grant select on public.crm_record_files to authenticated;
grant select, insert, update, delete on public.crm_record_files to service_role;

-- Can this person open this file?
create or replace function public.zella_can_see_record_file(p_file public.crm_record_files) returns boolean
language sql stable security definer set search_path = public as $$
  select p_file.status <> 'removed' and public.zella_is_member(p_file.business_id)
     and (not p_file.private or public.zella_can_read_record_secrets(p_file.record_id))
     and (p_file.status = 'ready' or p_file.uploaded_by = auth.uid());
$$;
revoke execute on function public.zella_can_see_record_file(public.crm_record_files) from public, anon;
grant execute on function public.zella_can_see_record_file(public.crm_record_files) to authenticated, service_role;

drop policy if exists crm_record_files_read on public.crm_record_files;
create policy crm_record_files_read on public.crm_record_files for select to authenticated using (public.zella_can_see_record_file(crm_record_files));
do $$ begin
  if exists (select 1 from pg_proc where proname = 'zella_mfa_satisfied') and not exists (
    select 1 from pg_policies where tablename = 'crm_record_files' and policyname = 'zella_mfa_required') then
    execute 'create policy zella_mfa_required on public.crm_record_files as restrictive for all to authenticated using (public.zella_mfa_satisfied()) with check (public.zella_mfa_satisfied())';
  end if;
end $$;

-- Storage: upload only to a path reserved for you; open only what you may see; delete only once removed. The decision
-- reads crm_record_files directly (security definer): a policy's own lookup would be filtered by that table's row
-- security, which hides removed files from everyone and would leave their storage objects undeletable.
create or replace function public.zella_record_file_storage_ok(p_name text, p_action text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.crm_record_files f
     where f.path = p_name
       and case p_action
             when 'insert' then f.status = 'pending' and f.uploaded_by = auth.uid() and public.zella_can_edit(f.business_id)
             when 'select' then public.zella_can_see_record_file(f)
                                or (f.status = 'removed' and (public.zella_has_role(f.business_id, array['owner', 'admin', 'manager']) or f.removed_by = auth.uid()))
             when 'delete' then f.status = 'removed' and (public.zella_has_role(f.business_id, array['owner', 'admin', 'manager']) or f.removed_by = auth.uid())
             else false end);
$$;
revoke execute on function public.zella_record_file_storage_ok(text, text) from public, anon;
grant execute on function public.zella_record_file_storage_ok(text, text) to authenticated, service_role;

drop policy if exists record_files_insert on storage.objects;
create policy record_files_insert on storage.objects for insert to authenticated with check (bucket_id = 'record-files' and public.zella_record_file_storage_ok(name, 'insert'));
drop policy if exists record_files_select on storage.objects;
create policy record_files_select on storage.objects for select to authenticated using (bucket_id = 'record-files' and public.zella_record_file_storage_ok(name, 'select'));
drop policy if exists record_files_delete on storage.objects;
create policy record_files_delete on storage.objects for delete to authenticated using (bucket_id = 'record-files' and public.zella_record_file_storage_ok(name, 'delete'));

-- 1. reserve a path
create or replace function public.zella_begin_record_file(p_record_id uuid, p_file_name text, p_mime_type text, p_size_bytes bigint,
  p_caption text default null, p_private boolean default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; v_id uuid := gen_random_uuid(); v_path text; v_private boolean;
begin
  select x.id, x.business_id, x.archived_at into r from public.crm_records x where x.id = p_record_id;
  if not found or not public.zella_can_edit(r.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if r.archived_at is not null then raise exception 'NOT_VALID'; end if;
  if p_mime_type is null or p_mime_type not in ('image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf') then raise exception 'BAD_FILE_TYPE'; end if;
  if p_size_bytes is null or p_size_bytes <= 0 or p_size_bytes > 10485760 then raise exception 'FILE_TOO_BIG'; end if;
  if (select count(*) from public.crm_record_files where record_id = p_record_id and status <> 'removed') >= 50 then raise exception 'TOO_MANY_FILES'; end if;
  -- reservations nobody finished within a day are let go
  delete from public.crm_record_files where record_id = p_record_id and status = 'pending' and created_at < now() - interval '1 day';
  v_private := public.zella_sensitive_industry(r.business_id) or coalesce(p_private, false);
  v_path := r.business_id || '/' || r.id || '/' || v_id || case p_mime_type when 'image/jpeg' then '.jpg' when 'image/png' then '.png'
            when 'image/webp' then '.webp' when 'image/heic' then '.heic' else '.pdf' end;
  insert into public.crm_record_files (id, business_id, record_id, path, file_name, mime_type, size_bytes, kind, caption, private, uploaded_by)
  values (v_id, r.business_id, r.id, v_path, left(coalesce(nullif(trim(p_file_name), ''), 'file'), 200), p_mime_type, p_size_bytes,
          case when p_mime_type like 'image/%' then 'photo' else 'document' end, left(nullif(trim(coalesce(p_caption, '')), ''), 300), v_private, auth.uid());
  return jsonb_build_object('id', v_id, 'path', v_path, 'bucket', 'record-files', 'private', v_private);
end $$;

-- 2. confirm the upload arrived
create or replace function public.zella_finish_record_file(p_file_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f public.crm_record_files; o record;
begin
  select * into f from public.crm_record_files where id = p_file_id for update;
  if not found or f.uploaded_by is distinct from auth.uid() or not public.zella_can_edit(f.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if f.status <> 'pending' then return jsonb_build_object('id', f.id, 'status', f.status); end if;
  select metadata into o from storage.objects where bucket_id = 'record-files' and name = f.path;
  if not found then raise exception 'UPLOAD_MISSING'; end if;
  -- where storage recorded them, the real type and size must be what was reserved
  if o.metadata ? 'mimetype' and o.metadata ->> 'mimetype' <> f.mime_type then raise exception 'BAD_FILE_TYPE'; end if;
  if o.metadata ? 'size' and (o.metadata ->> 'size')::bigint > 10485760 then raise exception 'FILE_TOO_BIG'; end if;
  update public.crm_record_files set status = 'ready', size_bytes = coalesce((o.metadata ->> 'size')::bigint, size_bytes) where id = f.id;
  insert into public.crm_record_events (business_id, record_id, kind, detail, actor)
  -- a private file's name can itself be private ("gate code 1234.jpg"): the history, which every member reads, doesn't show it
  values (f.business_id, f.record_id, 'file_added', case when f.private then 'A private file' else f.file_name end, auth.uid());
  return jsonb_build_object('id', f.id, 'status', 'ready');
end $$;

-- 3. remove: managers and above, or the uploader within a day
create or replace function public.zella_remove_record_file(p_file_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f public.crm_record_files;
begin
  select * into f from public.crm_record_files where id = p_file_id for update;
  if not found or not (public.zella_has_role(f.business_id, array['owner', 'admin', 'manager'])
                       or (f.uploaded_by = auth.uid() and f.created_at > now() - interval '1 day' and public.zella_can_edit(f.business_id))) then
    raise exception 'NOT_ALLOWED';
  end if;
  if f.status = 'removed' then return jsonb_build_object('id', f.id, 'path', f.path, 'status', 'removed'); end if;
  update public.crm_record_files set status = 'removed', removed_at = now(), removed_by = auth.uid() where id = f.id;
  if f.status = 'ready' then
    insert into public.crm_record_events (business_id, record_id, kind, detail, actor)
    values (f.business_id, f.record_id, 'file_removed', case when f.private then 'A private file' else f.file_name end, auth.uid());
  end if;
  return jsonb_build_object('id', f.id, 'path', f.path, 'status', 'removed');
end $$;

revoke execute on function public.zella_begin_record_file(uuid, text, text, bigint, text, boolean), public.zella_finish_record_file(uuid),
  public.zella_remove_record_file(uuid) from public, anon;
grant execute on function public.zella_begin_record_file(uuid, text, text, bigint, text, boolean), public.zella_finish_record_file(uuid),
  public.zella_remove_record_file(uuid) to authenticated, service_role;
