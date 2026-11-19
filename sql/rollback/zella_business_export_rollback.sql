-- Undoes sql/zella_business_export.sql: drops the nine export functions and the business-exports bucket, and the
-- business_export_jobs table only when it is empty: export records (who asked, who decided, why) are kept otherwise
-- (server only, as before), and applying the file again uses them as they are. It refuses (EXPORTS_EXIST) while an export is running or ready, or the bucket still holds
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
      ('public.zella_export_tables()', 'aba79deaddde7257e17b778805caa099'),
      ('public.zella_export_rows(uuid,uuid,text,text,integer)', 'e369de5aa2fd5a1a13083c961c5bce9d'),
      ('public.zella_export_pause(uuid,uuid,jsonb)', '730410e6d2a55eec1baeddfec0bdc502'),
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
drop function if exists public.zella_export_rows(uuid, uuid, text, text, integer);
drop function if exists public.zella_export_pause(uuid, uuid, jsonb);
drop function if exists public.zella_export_files(uuid, uuid);
do $$ begin
  if to_regclass('public.business_export_jobs') is not null and not exists (select 1 from public.business_export_jobs) then
    drop table public.business_export_jobs;
  end if;
end $$;
delete from storage.buckets where id = 'business-exports';
commit;
