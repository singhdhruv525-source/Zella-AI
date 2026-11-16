-- Rollback of sql/zella_business_purge.sql: removes the business purge functions. Safe to run twice. Refuses
-- (ROLLBACK_DRIFT) if any function differs from that file's version, or once a business purge has run or is waiting
-- (its record is in retention_purge_runs, which stays). Runs only asked for or approved are cancelled with it.
begin;

do $$
declare
  f record;
    mine constant jsonb := '{
    "public.zella_business_purge_request(uuid,uuid,timestamp with time zone,text,text)": "605fbfcb53d71fe8f9bdd0aa8df8d58a",
    "public.zella_business_purge_execute(uuid,uuid,text)": "e4e2918390f85a92db61877cce30d413",
    "public.zella_business_purge_files_done(uuid,uuid,text[],text)": "61fb59cee8b0ff4f2c20e068ca7e1428"
  }';
begin
  for f in select key as sig, value #>> '{}' as want from jsonb_each(mine) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'ROLLBACK_DRIFT: % has changed since zella_business_purge.sql', f.sig;
    end if;
  end loop;
  if exists (select 1 from public.retention_purge_runs where data_class = 'cancelled_business' and (executed_at is not null or status in ('running', 'files_pending'))) then
    raise exception 'ROLLBACK_DRIFT: a business purge has run; keep its functions so its record can be finished and read';
  end if;
end $$;

update public.retention_purge_runs set status = 'cancelled', error = 'Cancelled: business purge rolled back', updated_at = now()
 where data_class = 'cancelled_business' and status in ('requested', 'approved');
drop function if exists public.zella_business_purge_files_done(uuid, uuid, text[], text);
drop function if exists public.zella_business_purge_execute(uuid, uuid, text);
drop function if exists public.zella_business_purge_request(uuid, uuid, timestamptz, text, text);

commit;
