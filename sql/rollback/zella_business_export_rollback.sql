-- Undoes sql/zella_business_export.sql: drops the eight export functions, the business_export_jobs table and the
-- business-exports bucket. It refuses (EXPORTS_EXIST) while an export is running or ready, or the bucket still holds
-- files: remove those first, so no export file is left without its record. Every function must be exactly that
-- file's version, otherwise ROLLBACK_DRIFT and nothing changes. Deploy the earlier owner-provision-business and switch
-- the business-export worker off first. Safe to run twice.
begin;
do $$
declare f record;
begin
  for f in select * from (values
      ('public.zella_export_request(uuid,uuid,text)', 'f47b159a55dbc664012efcc5f31a91d3'),
      ('public.zella_export_decide(uuid,uuid,boolean,text)', 'd629f795bb5d2cdbfe5f35ae7d3cc153'),
      ('public.zella_export_claim()', 'ff8042f03db758b059a9e0d195e6fb6d'),
      ('public.zella_export_progress(uuid,uuid,jsonb)', 'dd7783ebcb736ed012d29a56adfa02cd'),
      ('public.zella_export_finish(uuid,uuid,boolean,text,text)', '83b5834fc4d29a12c2e5c849c3d93877'),
      ('public.zella_export_tables()', '5a84e8a9605c8e20d1ffbfcf4537d600'),
      ('public.zella_export_rows(uuid,uuid,text,integer,integer)', 'b0da0326b04c813ccd7ddd5b443063d9'),
      ('public.zella_export_files(uuid,uuid)', '580156e5758c1d2fbbcae6e8387969c0')) as t(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(to_regprocedure(f.sig))) <> f.want then
      raise exception 'ROLLBACK_DRIFT: % has changed since this migration', f.sig;
    end if;
  end loop;
  if to_regclass('public.business_export_jobs') is not null then
    if exists (select 1 from public.business_export_jobs where status in ('running', 'ready')) then
      raise exception 'EXPORTS_EXIST: an export is running or ready';
    end if;
  end if;
  if exists (select 1 from storage.objects where bucket_id = 'business-exports') then
    raise exception 'EXPORTS_EXIST: the business-exports bucket still holds files';
  end if;
end $$;
drop function if exists public.zella_export_request(uuid, uuid, text);
drop function if exists public.zella_export_decide(uuid, uuid, boolean, text);
drop function if exists public.zella_export_claim();
drop function if exists public.zella_export_progress(uuid, uuid, jsonb);
drop function if exists public.zella_export_finish(uuid, uuid, boolean, text, text);
drop function if exists public.zella_export_tables();
drop function if exists public.zella_export_rows(uuid, uuid, text, integer, integer);
drop function if exists public.zella_export_files(uuid, uuid);
drop table if exists public.business_export_jobs;
delete from storage.buckets where id = 'business-exports';
commit;
