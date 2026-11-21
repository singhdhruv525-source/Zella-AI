-- Undoes sql/zella_privacy_retention.sql: zella_erase_customer, zella_run_scheduled_job and zella_run_schedule_group
-- come back from zella_function_archive (each only if undoing this file's change gives back exactly the archived
-- definition, otherwise ROLLBACK_DRIFT and nothing changes); the new functions and the vapi_deletion_live setting are
-- removed; the provider_deletions queue and its rows stay (deletions still owed at Vapi are never lost; applying the file
-- again reuses it); recordings and transcripts go back to exactly the periods they had before (ROLLBACK_DRIFT if either
-- was changed since); the two drafts are removed unless someone accepted them (then they
-- stay, as the acceptances point at them). Grants are kept. Safe to run twice.
begin;
do $$
declare a record; d text;
  undo constant jsonb := jsonb_build_object(
    'public.zella_erase_customer(uuid,uuid)', jsonb_build_array($w$  -- zella_privacy_retention: the copies at Vapi are deleted too (sent while vapi_deletion_live is on)
  perform public.zella_queue_provider_deletion(p_business_id, c.external_call_id, 'customer_erasure') from public.calls c where c.customer_id = p_customer_id and c.business_id = p_business_id;
$w$, ''),
    'public.zella_run_scheduled_job(text)', jsonb_build_array($w$  if p_job not in ('zella_retention_auto_run', '$w$, $a$  if p_job not in ('$a$),
    'public.zella_run_schedule_group(text)', jsonb_build_array($w$'zella_run_permission_check', 'zella_retention_auto_run']$w$, $a$'zella_run_permission_check']$a$));
begin
  if to_regclass('public.zella_function_archive') is not null
     and exists (select 1 from public.zella_function_archive where migration = 'zella_privacy_retention') then
    for a in select signature, definition from public.zella_function_archive where migration = 'zella_privacy_retention' loop
      d := replace(pg_get_functiondef(a.signature::regprocedure), undo -> a.signature ->> 0, undo -> a.signature ->> 1);
      if d <> a.definition then raise exception 'ROLLBACK_DRIFT: % has changed since this migration', a.signature; end if;
    end loop;
    for a in select definition from public.zella_function_archive where migration = 'zella_privacy_retention' loop
      execute a.definition;
    end loop;
    delete from public.zella_function_archive where migration = 'zella_privacy_retention';
  end if;
  -- the periods go back to exactly what they were, only if nobody changed them since (still 90 days)
  if to_regclass('public.data_retention_policies') is not null and to_regclass('public.zella_migration_values') is not null then
    if exists (select 1 from public.data_retention_policies p join public.zella_migration_values v on v.migration = 'zella_privacy_retention' and v.key = 'days:' || p.data_class
                where p.days <> 90) then
      raise exception 'ROLLBACK_DRIFT: a recording or transcript period was changed after this migration';
    end if;
    update public.data_retention_policies p set days = (v.value #>> '{}')::integer,
           note = coalesce((select n.value #>> '{}' from public.zella_migration_values n
                             where n.migration = 'zella_privacy_retention' and n.key = 'note:' || p.data_class),
                           case when exists (select 1 from public.zella_migration_values n
                                              where n.migration = 'zella_privacy_retention' and n.key = 'note:' || p.data_class) then null
                                else regexp_replace(p.note, '^Owner decision 18 Nov 2026: 90 days, deleted automatically \(zella_retention_auto_run\)\. ', '') end)
      from public.zella_migration_values v where v.migration = 'zella_privacy_retention' and v.key = 'days:' || p.data_class;
    delete from public.zella_migration_values where migration = 'zella_privacy_retention';
    if not exists (select 1 from public.zella_migration_values) then drop table public.zella_migration_values; end if;
  end if;
end $$;
drop function if exists public.zella_owner_onboarding_legal_accept(uuid);
drop function if exists public.zella_legal_current(text);
drop function if exists public.zella_retention_auto_run();
drop function if exists public.zella_provider_deletion_result(uuid, text, text);
drop function if exists public.zella_provider_deletions_claim(integer);
drop function if exists public.zella_queue_provider_deletion(uuid, text, text);
delete from public.platform_settings where key = 'vapi_deletion_live' and value = 'false'::jsonb;
delete from public.legal_documents d where d.kind in ('privacy', 'terms') and d.version = '0.1' and d.status = 'draft'
   and not exists (select 1 from public.legal_acceptances a where a.document_id = d.id);
commit;
