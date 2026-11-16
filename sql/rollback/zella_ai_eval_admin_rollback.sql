-- Undoes sql/zella_ai_eval_admin.sql exactly: drops the two admin functions and the ai_eval_runs table it added (the
-- stored runs go with it; nothing else was changed). Each function must be exactly that file's version first,
-- otherwise ROLLBACK_DRIFT and nothing changes. Safe to run twice. Deploy the earlier web app first.
begin;
do $$
declare f record;
begin
  for f in select * from (values
      ('public.zella_admin_eval_run(uuid)', '62985f4f137dc339d4d6cc9cb5b18c72'),
      ('public.zella_admin_eval_overview(integer,integer)', 'fd4467bf8facbd909b42dd112965b010')) v(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'ROLLBACK_DRIFT: % has changed since this migration', f.sig;
    end if;
  end loop;
  drop function if exists public.zella_admin_eval_run(uuid);
  drop function if exists public.zella_admin_eval_overview(integer, integer);
  drop table if exists public.ai_eval_runs;
end $$;
commit;
