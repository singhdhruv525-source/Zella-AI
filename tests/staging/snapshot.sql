-- Schema and data fingerprint of an isolated staging database, for before / after / rolled-back comparisons.
-- data: one checksum per table over every row (as JSON, without updated_at, which the deploy may touch), plus counts.
do $$
declare t text; h text; n bigint; d jsonb := '{}'; c jsonb := '{}';
begin
  for t in select c.relname from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' order by 1 loop
    execute format('select md5(coalesce(string_agg(x, ''|'' order by x), '''')), count(*) from (select (to_jsonb(r) - ''updated_at'')::text x from public.%I r) s', t) into h, n;
    d := d || jsonb_build_object(t, h); c := c || jsonb_build_object(t, n);
  end loop;
  perform set_config('zella.snap_data', d::text, false); perform set_config('zella.snap_counts', c::text, false);
end $$;
select json_build_object(
 'schema', json_build_object(
   'functions', (select json_object_agg(p.oid::regprocedure::text, md5(pg_get_functiondef(p.oid)) || ':' || coalesce((select string_agg(x::text, ',' order by x::text) from unnest(p.proacl) x), 'default')) from pg_proc p where p.pronamespace = 'public'::regnamespace),
   'triggers', (select coalesce(json_object_agg(c.relname || '.' || t.tgname, md5(pg_get_triggerdef(t.oid))), '{}') from pg_trigger t join pg_class c on c.oid = t.tgrelid where not t.tgisinternal and c.relnamespace = 'public'::regnamespace),
   'policies', (select coalesce(json_object_agg(tablename || '.' || policyname, md5(cmd || roles::text || permissive || coalesce(qual, '') || coalesce(with_check, ''))), '{}') from pg_policies where schemaname = 'public'),
   'storage_policies', (select coalesce(json_object_agg(policyname, md5(cmd || roles::text || permissive || coalesce(qual, '') || coalesce(with_check, ''))), '{}') from pg_policies where schemaname = 'storage'),
   'buckets', (select md5(coalesce(string_agg(id || public::text || coalesce(file_size_limit::text, '') || coalesce(allowed_mime_types::text, ''), '|' order by id), '')) from storage.buckets),
   'views', (select coalesce(json_object_agg(c.relname, md5(pg_get_viewdef(c.oid) || coalesce(c.reloptions::text, ''))), '{}') from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'v'),
   -- grants compared as a set: the same grants in another order are the same
   'tables', (select md5(string_agg(c.relname || coalesce((select string_agg(x::text, ',' order by x::text) from unnest(c.relacl) x), ''), '|' order by c.relname)) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'v')),
   'columns', (select md5(string_agg(table_name || '.' || column_name || data_type || is_nullable || coalesce(column_default, ''), '|' order by table_name, column_name)) from information_schema.columns where table_schema = 'public'),
   'column_grants', (select md5(coalesce(string_agg(table_name || column_name || grantee || privilege_type, '|' order by table_name, column_name, grantee, privilege_type), '')) from information_schema.column_privileges where table_schema = 'public' and grantee in ('anon', 'authenticated', 'service_role')),
   'indexes', (select md5(string_agg(indexdef, '|' order by indexname)) from pg_indexes where schemaname = 'public'),
   'rls', (select md5(string_agg(relname || relrowsecurity, '|' order by relname)) from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r')),
 'data', current_setting('zella.snap_data')::json,
 'counts', current_setting('zella.snap_counts')::json);
