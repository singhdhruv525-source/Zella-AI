-- Photos and files on records (zella_record_files.sql), including the storage policies.
\set ON_ERROR_STOP on
begin;
insert into public.industries (id, name, slug) values ('ea000000-0000-0000-0000-000000000001', 'Plumbing F', 'plumbing-f'), ('ea000000-0000-0000-0000-000000000002', 'Dental F', 'dental') on conflict do nothing;
insert into auth.users (id, email, email_confirmed_at) values
 ('ea000000-0000-0000-0000-00000000000a', 'own@f.test', now()), ('ea000000-0000-0000-0000-00000000000b', 'mgr@f.test', now()),
 ('ea000000-0000-0000-0000-00000000000c', 'tech@f.test', now()), ('ea000000-0000-0000-0000-00000000000d', 'tech2@f.test', now()),
 ('ea000000-0000-0000-0000-00000000000e', 'view@f.test', now()), ('ea000000-0000-0000-0000-00000000000f', 'other@f.test', now());
insert into public.businesses (id, name, timezone, is_active, onboarding_status, industry_id) values
 ('ea000000-0000-0000-0000-0000000000a1', 'Pipes', 'UTC', true, 'active', 'ea000000-0000-0000-0000-000000000001'),
 ('ea000000-0000-0000-0000-0000000000a2', 'Teeth', 'UTC', true, 'active', (select id from public.industries where slug = 'dental')),
 ('ea000000-0000-0000-0000-0000000000b1', 'Other', 'UTC', true, 'active', 'ea000000-0000-0000-0000-000000000001');
insert into public.business_members (business_id, user_id, role, status)
select b::uuid, u::uuid, r, 'active' from (values
 ('ea000000-0000-0000-0000-0000000000a1', 'ea000000-0000-0000-0000-00000000000a', 'owner'), ('ea000000-0000-0000-0000-0000000000a1', 'ea000000-0000-0000-0000-00000000000b', 'manager'),
 ('ea000000-0000-0000-0000-0000000000a1', 'ea000000-0000-0000-0000-00000000000c', 'staff'), ('ea000000-0000-0000-0000-0000000000a1', 'ea000000-0000-0000-0000-00000000000d', 'staff'),
 ('ea000000-0000-0000-0000-0000000000a1', 'ea000000-0000-0000-0000-00000000000e', 'viewer'), ('ea000000-0000-0000-0000-0000000000a2', 'ea000000-0000-0000-0000-00000000000c', 'staff'),
 ('ea000000-0000-0000-0000-0000000000b1', 'ea000000-0000-0000-0000-00000000000f', 'owner')) v(b, u, r);
insert into public.crm_record_types (business_id, key, singular, plural, statuses) values
 ('ea000000-0000-0000-0000-0000000000a1', 'jobs', 'Job', 'Jobs', '[{"key":"open","label":"Open"}]'),
 ('ea000000-0000-0000-0000-0000000000a2', 'plans', 'Plan', 'Plans', '[{"key":"open","label":"Open"}]');
insert into public.crm_records (id, business_id, type_key, title, status, assigned_to) values
 ('ea000000-0000-0000-0000-0000000000f1', 'ea000000-0000-0000-0000-0000000000a1', 'jobs', 'Leak', 'open', 'ea000000-0000-0000-0000-00000000000c'),
 ('ea000000-0000-0000-0000-0000000000f2', 'ea000000-0000-0000-0000-0000000000a2', 'plans', 'Crown', 'open', null);
create temp table ids (k text primary key, v jsonb) on commit drop;
grant all on ids to authenticated, service_role;
-- storage as the storage server writes it (metadata with the real type and size)
create or replace function pg_temp.put(p text, mime text, sz int) returns void language sql as $$
  insert into storage.objects (bucket_id, name, owner, metadata) values ('record-files', p, auth.uid(), jsonb_build_object('mimetype', mime, 'size', sz)) $$;
set local role authenticated;

-- the assigned tech adds a job photo (public) and a private one
select set_config('request.jwt.claims', '{"sub":"ea000000-0000-0000-0000-00000000000c","role":"authenticated","aal":"aal1"}', true);
do $$ declare a jsonb; p jsonb; begin
  begin perform public.zella_begin_record_file('ea000000-0000-0000-0000-0000000000f1', 'x.exe', 'application/x-msdownload', 100); raise exception 'exe accepted';
  exception when others then if sqlerrm <> 'BAD_FILE_TYPE' then raise; end if; end;
  begin perform public.zella_begin_record_file('ea000000-0000-0000-0000-0000000000f1', 'big.jpg', 'image/jpeg', 10485761); raise exception 'too big accepted';
  exception when others then if sqlerrm <> 'FILE_TOO_BIG' then raise; end if; end;
  a := public.zella_begin_record_file('ea000000-0000-0000-0000-0000000000f1', 'before.jpg', 'image/jpeg', 2000, 'Under the sink');
  p := public.zella_begin_record_file('ea000000-0000-0000-0000-0000000000f1', 'gate-code.jpg', 'image/jpeg', 2000, null, true);
  insert into ids values ('a', a), ('p', p);
  -- only to the reserved path
  begin perform pg_temp.put('ea000000-0000-0000-0000-0000000000a1/ea000000-0000-0000-0000-0000000000f1/mine.jpg', 'image/jpeg', 10); raise exception 'upload to an unreserved path';
  exception when insufficient_privilege then null; end;
  begin perform public.zella_finish_record_file((a ->> 'id')::uuid); raise exception 'finished without the file';
  exception when others then if sqlerrm <> 'UPLOAD_MISSING' then raise; end if; end;
  perform pg_temp.put(a ->> 'path', 'image/jpeg', 2000);
  perform pg_temp.put(p ->> 'path', 'image/jpeg', 2000);
  assert (public.zella_finish_record_file((a ->> 'id')::uuid)) ->> 'status' = 'checking', 'arrived: checking, not ready';
  perform public.zella_finish_record_file((p ->> 'id')::uuid);
  -- the uploader can't pass their own file: the verdict is server-only
  begin perform public.zella_record_file_checked((a ->> 'id')::uuid, true, null, null, 2000); raise exception 'member recorded a verdict';
  exception when insufficient_privilege then null; end;
  begin perform public.zella_record_file_cleanup(); raise exception 'member ran cleanup'; exception when insufficient_privilege then null; end;
  begin perform public.zella_record_files_purged(array['x']); raise exception 'member marked purged'; exception when insufficient_privilege then null; end;
  begin update public.crm_record_files set status = 'ready'; raise exception 'member updated file rows'; exception when insufficient_privilege then null; end;
end $$;
-- while checking, nobody else (not even the manager) can see or open it
select set_config('request.jwt.claims', '{"sub":"ea000000-0000-0000-0000-00000000000b","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  assert (select count(*) from public.crm_record_files) = 0, 'manager: checking files are hidden';
  assert (select count(*) from storage.objects where bucket_id = 'record-files') = 0, 'manager: checking files can''t be opened';
end $$;
-- the server's verdict (record-files function): both are real photos
reset role; set local role service_role;
do $$ begin
  perform public.zella_record_file_checked(((select v from ids where k = 'a') ->> 'id')::uuid, true, null, repeat('a', 64), 2000);
  perform public.zella_record_file_checked(((select v from ids where k = 'p') ->> 'id')::uuid, true, null, repeat('b', 64), 2000);
  -- a second verdict changes nothing
  assert (public.zella_record_file_checked(((select v from ids where k = 'a') ->> 'id')::uuid, false, 'late', null, null)) ->> 'status' = 'ready', 'verdict is final';
end $$;
reset role; set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"ea000000-0000-0000-0000-00000000000c","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  assert (select count(*) from public.crm_record_files where status = 'ready') = 2, 'both ready';
  assert (select count(*) from storage.objects where bucket_id = 'record-files') = 2, 'assigned tech sees both files';
end $$;

-- a PDF with JavaScript (the function's verdict): rejected, hidden from everyone, its stored copy may be deleted, history says so
do $$ declare x jsonb; begin
  x := public.zella_begin_record_file('ea000000-0000-0000-0000-0000000000f1', 'estimate.pdf', 'application/pdf', 500);
  perform pg_temp.put(x ->> 'path', 'application/pdf', 500);
  perform public.zella_finish_record_file((x ->> 'id')::uuid);
  insert into ids values ('bad', x);
end $$;
reset role; set local role service_role;
do $$ begin perform public.zella_record_file_checked(((select v from ids where k = 'bad') ->> 'id')::uuid, false, 'PDF with active content (JavaScript)', repeat('c', 64), 500); end $$;
reset role; set local role authenticated;
do $$ declare x jsonb := (select v from ids where k = 'bad'); begin
  assert not exists (select 1 from public.crm_record_files where id = (x ->> 'id')::uuid), 'rejected: not visible, not even to the uploader';
  assert not exists (select 1 from storage.objects where name = x ->> 'path'), 'rejected: can''t be opened';
end $$;
reset role;
do $$ begin
  assert (select status from public.crm_record_files where id = ((select v from ids where k = 'bad') ->> 'id')::uuid) = 'rejected', 'recorded as rejected';
  assert exists (select 1 from public.crm_record_events where kind = 'file_rejected' and detail like 'estimate.pdf: PDF with active content%'), 'history shows the refusal';
end $$;
set local role authenticated;

-- a file that turns out to be another type is refused
do $$ declare x jsonb; begin
  x := public.zella_begin_record_file('ea000000-0000-0000-0000-0000000000f1', 'fake.jpg', 'image/jpeg', 100);
  perform pg_temp.put(x ->> 'path', 'text/html', 100);
  begin perform public.zella_finish_record_file((x ->> 'id')::uuid); raise exception 'disguised file accepted';
  exception when others then if sqlerrm <> 'BAD_FILE_TYPE' then raise; end if; end;
end $$;

-- the other tech: the public photo only; can't remove someone else's file
select set_config('request.jwt.claims', '{"sub":"ea000000-0000-0000-0000-00000000000d","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  assert (select count(*) from public.crm_record_files where status = 'ready') = 1, 'unassigned tech: the private file is hidden';
  assert (select count(*) from storage.objects where bucket_id = 'record-files') = 1, 'unassigned tech can open only the public photo';
  begin perform public.zella_remove_record_file(((select v from ids where k = 'a') ->> 'id')::uuid); raise exception 'removed someone else''s file';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
end $$;
-- viewer: sees the public photo, can't add
select set_config('request.jwt.claims', '{"sub":"ea000000-0000-0000-0000-00000000000e","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  assert (select count(*) from storage.objects where bucket_id = 'record-files') = 1, 'viewer opens the public photo only';
  begin perform public.zella_begin_record_file('ea000000-0000-0000-0000-0000000000f1', 'v.jpg', 'image/jpeg', 10); raise exception 'viewer uploaded';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
end $$;
-- another business: nothing
select set_config('request.jwt.claims', '{"sub":"ea000000-0000-0000-0000-00000000000f","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  assert (select count(*) from storage.objects where bucket_id = 'record-files') = 0, 'other business opens nothing';
  assert (select count(*) from public.crm_record_files) = 0, 'other business sees no file rows';
  begin perform public.zella_begin_record_file('ea000000-0000-0000-0000-0000000000f1', 'x.jpg', 'image/jpeg', 10); raise exception 'other business uploaded';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
  begin delete from storage.objects where bucket_id = 'record-files'; end;
end $$;
-- manager: sees both; removes the public one; then the object can be deleted, and nobody can open it any more
select set_config('request.jwt.claims', '{"sub":"ea000000-0000-0000-0000-00000000000b","role":"authenticated","aal":"aal1"}', true);
do $$ declare a jsonb := (select v from ids where k = 'a'); begin
  assert (select count(*) from storage.objects where bucket_id = 'record-files') = 2, 'manager opens both';
  delete from storage.objects where name = a ->> 'path';
  assert (select count(*) from storage.objects where bucket_id = 'record-files') = 2, 'a live file can''t be deleted from storage directly';
  perform public.zella_remove_record_file((a ->> 'id')::uuid);
  assert (select count(*) from public.crm_record_files where id = (a ->> 'id')::uuid) = 0, 'removed: gone from the record at once';
  delete from storage.objects where name = a ->> 'path';
  assert (select count(*) from storage.objects where name = a ->> 'path') = 0, 'manager deleted the removed object';
end $$;
select set_config('request.jwt.claims', '{"sub":"ea000000-0000-0000-0000-00000000000d","role":"authenticated","aal":"aal1"}', true);
do $$ begin assert (select count(*) from storage.objects where bucket_id = 'record-files') = 0, 'unassigned tech opens nothing now'; end $$;
reset role;
do $$ begin
  assert not exists (select 1 from storage.objects where name = (select v ->> 'path' from ids where k = 'a')), 'the removed photo is gone from storage';
  assert exists (select 1 from storage.objects where name = (select v ->> 'path' from ids where k = 'p')), 'the private file is still there';
end $$;
-- cleanup (server): lists the rejected PDF's stored copy, an abandoned upload and an orphan object; the removed photo
-- whose object the manager already deleted is not listed; purging is audited
do $$ declare ab jsonb; list jsonb; n int; begin
  insert into storage.objects (bucket_id, name, metadata, created_at) values ('record-files', 'ea000000-0000-0000-0000-0000000000a1/ea000000-0000-0000-0000-0000000000f1/orphan.png', '{}', now() - interval '2 days');
  insert into public.crm_record_files (business_id, record_id, path, file_name, mime_type, size_bytes, kind, status, uploaded_by, created_at)
  values ('ea000000-0000-0000-0000-0000000000a1', 'ea000000-0000-0000-0000-0000000000f1', 'ea000000-0000-0000-0000-0000000000a1/ea000000-0000-0000-0000-0000000000f1/left.jpg',
          'left.jpg', 'image/jpeg', 10, 'photo', 'checking', 'ea000000-0000-0000-0000-00000000000c', now() - interval '25 hours');
  insert into storage.objects (bucket_id, name, metadata) values ('record-files', 'ea000000-0000-0000-0000-0000000000a1/ea000000-0000-0000-0000-0000000000f1/left.jpg', '{}');
  set local role service_role;
  list := public.zella_record_file_cleanup();
  assert list ? ((select v from ids where k = 'bad') ->> 'path'), 'rejected copy listed';
  assert list ? 'ea000000-0000-0000-0000-0000000000a1/ea000000-0000-0000-0000-0000000000f1/orphan.png', 'orphan listed';
  assert list ? 'ea000000-0000-0000-0000-0000000000a1/ea000000-0000-0000-0000-0000000000f1/left.jpg', 'abandoned upload listed';
  assert not list ? ((select v from ids where k = 'p') ->> 'path'), 'a live file is never listed';
  assert jsonb_array_length(list) = 3, 'exactly those three: ' || list::text;
  delete from storage.objects where name in (select jsonb_array_elements_text(list)); -- what the storage API does
  n := public.zella_record_files_purged(array(select jsonb_array_elements_text(list)));
  assert n = 2, 'two file records purged (the orphan had none)';
  assert jsonb_array_length(public.zella_record_file_cleanup()) = 0, 'nothing left to clean';
  reset role;
  assert exists (select 1 from public.audit_logs where action = 'record_files_purged' and (new_data ->> 'objects')::int = 3), 'purge audited';
end $$;

-- a tech removed from the business can no longer see or open anything, even files on records they were assigned to
delete from public.business_members where business_id = 'ea000000-0000-0000-0000-0000000000a1' and user_id = 'ea000000-0000-0000-0000-00000000000c';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"ea000000-0000-0000-0000-00000000000c","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  assert (select count(*) from public.crm_record_files where business_id = 'ea000000-0000-0000-0000-0000000000a1') = 0, 'removed staff: no file rows';
  assert (select count(*) from storage.objects where bucket_id = 'record-files' and name like 'ea000000-0000-0000-0000-0000000000a1/%') = 0, 'removed staff: can''t open (no new signed links)';
  begin perform public.zella_begin_record_file('ea000000-0000-0000-0000-0000000000f1', 'x.jpg', 'image/jpeg', 10); raise exception 'removed staff uploaded';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
end $$;
reset role;
insert into public.business_members (business_id, user_id, role, status) values ('ea000000-0000-0000-0000-0000000000a1', 'ea000000-0000-0000-0000-00000000000c', 'staff', 'active');
do $$ begin
  assert (select count(*) from public.crm_record_events where kind = 'file_added') = 2 and (select count(*) from public.crm_record_events where kind = 'file_removed') = 1, 'history';
  assert not exists (select 1 from public.crm_record_events where detail like '%gate-code%'), 'a private file''s name isn''t in the history';
end $$;
-- dental: every file is private, even when the uploader says otherwise
select set_config('request.jwt.claims', '{"sub":"ea000000-0000-0000-0000-00000000000c","role":"authenticated","aal":"aal1"}', true);
do $$ declare d jsonb; begin
  d := public.zella_begin_record_file('ea000000-0000-0000-0000-0000000000f2', 'xray.jpg', 'image/jpeg', 100, null, false);
  assert (d ->> 'private')::boolean, 'dental files are always private';
end $$;
select 'PASS record files: type/size/path checks, checking until the server verdict (members can''t pass their own), rejected files hidden, cleanup of rejected/abandoned/orphan objects audited, staff removal cuts access, disguised files refused, private files for assigned staff and managers only, viewer read-only, other business nothing, removal hides at once, history, dental always private';
rollback;
