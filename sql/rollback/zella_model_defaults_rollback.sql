-- Undoes sql/zella_model_defaults.sql: each function gets back the exact definition saved in zella_function_archive
-- when the migration ran. Only a function that is still this migration's version is restored; one changed since
-- stops the rollback (VERSION_MISMATCH) so a later change is never overwritten. Safe to run again: a function already
-- back to its archived definition is skipped. The archive rows are kept (no tenant data); the table stays.
begin;
do $$
declare a record; v_have text;
begin
  if to_regclass('public.zella_function_archive') is null then return; end if;
  for a in select * from public.zella_function_archive where migration = 'zella_model_defaults' order by signature loop
    if to_regprocedure(a.signature) is null then raise exception 'VERSION_MISMATCH: % is missing', a.signature; end if;
    v_have := md5(pg_get_functiondef(to_regprocedure(a.signature)));
    continue when v_have = a.definition_md5;
    if v_have <> (case a.signature
        when 'public.zella_assistant_config(uuid)'       then '99dadcfe4ae7812d2126146882f07241'
        when 'public.zella_claim_call_insights(integer)' then '7bc295835cdc9d35fc6ae6d34cd7e57a'
        when 'public.zella_claim_gap_drafts(integer)'    then '8b8dfaf4dfa4d1073ff34f1407511fd8'
        when 'public.zella_review_claim_ai(integer)'     then 'e914bd6f8e47a67942185421dcfc7072'
        when 'public.zella_spam_claim_work(integer)'     then '2d36d89897de8777e2c1da25c66a7026' end) then
      raise exception 'VERSION_MISMATCH: % has changed since zella_model_defaults; not restored', a.signature;
    end if;
    execute a.definition;
    if md5(pg_get_functiondef(to_regprocedure(a.signature))) <> a.definition_md5 then
      raise exception 'VERSION_MISMATCH: % did not restore exactly', a.signature;
    end if;
  end loop;
end $$;
commit;
