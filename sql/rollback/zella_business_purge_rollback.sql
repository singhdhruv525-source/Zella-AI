-- Rollback of sql/zella_business_purge.sql: removes the business purge functions. Safe to run twice. Refuses
-- (ROLLBACK_DRIFT) if any function differs from that file's version, or once a business purge has run or is waiting
-- (its record is in retention_purge_runs, which stays). Runs only asked for or approved are cancelled with it. The
-- runs table is locked against writes first, so a purge can't start between the check and the removal.
begin;

do $$
declare
  f record;
    mine constant jsonb := '{
    "public.zella_business_purge_request(uuid,uuid,timestamp with time zone,text,text)": "605fbfcb53d71fe8f9bdd0aa8df8d58a",
    "public.zella_business_purge_execute(uuid,uuid,text)": "e224a1fefa197dc7c3b2e7290cc7fb95",
    "public.zella_business_purge_files_done(uuid,uuid,text[],text)": "124074d759f4db993693a7328b95b284"
  }';
begin
  -- no purge can start or move on while this checks and removes (held to the end of the transaction)
  lock table public.retention_purge_runs in share row exclusive mode;
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
