-- Zella Voice: AI testing for platform admins, with stored runs and one pass rule (docs/ADMIN_AUDIT_2026-11-16.md
-- AI-TESTING). zella_brain_run_evals checks a business's test questions (ai_eval_cases) against its knowledge, but
-- stores nothing and lets only the two top admin roles or the business's owners run it. Now:
--   ai_eval_runs                       every admin run: who, when, how many cases, passed, the failed questions, and
--                                      whether the business passes. Server only (row security on, no policies).
--   zella_admin_eval_run(uuid)         runs one business's cases and stores the run; businesses.manage, so a
--                                      restricted role that has it can run it too
--   zella_admin_eval_overview(int,int) the businesses with test questions, a page at a time, each with its latest
--                                      run; businesses.view
-- The pass rule, as zella_brain_run_evals has it: a case passes when knowledge search finds an answer and every
-- expected phrase is in the top answer, or, for a "should find nothing" case, when it finds nothing. A business passes
-- when it has at least 3 cases (ZELLA_EVAL_MIN_CASES) and every one passes. This checks knowledge retrieval only, not
-- live calls: no provider is called and nothing is sent. A failing run is a warning only; it never blocks going live.
-- Nothing is replaced. Rerunning needs this file's exact versions, otherwise VERSION_MISMATCH.
-- Rollback: sql/rollback/zella_ai_eval_admin_rollback.sql
begin;
set local client_min_messages = warning;

do $$
declare f record;
begin
  for f in select * from (values
      ('public.zella_admin_eval_run(uuid)', '62985f4f137dc339d4d6cc9cb5b18c72'),
      ('public.zella_admin_eval_overview(integer,integer)', 'fd4467bf8facbd909b42dd112965b010')) v(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'VERSION_MISMATCH: % already exists and is not this file''s version', f.sig;
    end if;
  end loop;
  if to_regprocedure('public.zella_admin_can(text)') is null or to_regprocedure('public.zella_brain_search(uuid,text,integer)') is null
     or to_regclass('public.ai_eval_cases') is null then
    raise exception 'VERSION_MISMATCH: zella_admin_can, zella_brain_search or ai_eval_cases is missing';
  end if;
end $$;

create table if not exists public.ai_eval_runs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  run_by uuid,
  run_at timestamptz not null default now(),
  total integer not null check (total >= 0),
  passed integer not null check (passed >= 0 and passed <= total),
  failed jsonb not null default '[]' check (jsonb_typeof(failed) = 'array'),
  business_passes boolean not null
);
create index if not exists ai_eval_runs_business_idx on public.ai_eval_runs (business_id, run_at desc);
alter table public.ai_eval_runs enable row level security;
revoke all on public.ai_eval_runs from anon, authenticated;
comment on table public.ai_eval_runs is 'Each admin AI testing run of a business''s test questions (zella_admin_eval_run).';

CREATE OR REPLACE FUNCTION public.zella_admin_eval_run(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  ZELLA_EVAL_MIN_CASES constant int := 3;   -- a business passes with at least this many cases, all passing
  e record; r jsonb; v_pass boolean; v_text text; w text; v_total int := 0; v_passed int := 0; v_failed jsonb := '[]'::jsonb; v_id uuid;
begin
  if coalesce(auth.role(), '') <> 'service_role' and not public.zella_admin_can('businesses.manage') then
    raise exception 'NOT_ALLOWED' using errcode = '42501';
  end if;
  if not exists (select 1 from public.businesses where id = p_business_id) then
    raise exception 'BUSINESS_NOT_FOUND' using errcode = 'P0002';
  end if;
  -- the same rule as zella_brain_run_evals, case by case
  for e in select * from public.ai_eval_cases where business_id = p_business_id order by created_at, id loop
    v_total := v_total + 1;
    r := public.zella_brain_search(p_business_id, e.question, 3);
    if e.expect_none then
      v_pass := r ->> 'confidence' = 'none';
    else
      v_text := lower(coalesce((r -> 'results' -> 0 ->> 'answer'), '') || ' ' || coalesce((r -> 'results' -> 0 ->> 'title'), ''));
      v_pass := r ->> 'confidence' <> 'none';
      foreach w in array e.expect_contains loop
        if position(lower(w) in v_text) = 0 then v_pass := false; end if;
      end loop;
    end if;
    if v_pass then v_passed := v_passed + 1;
    else v_failed := v_failed || jsonb_build_array(jsonb_build_object('question', e.question, 'confidence', r ->> 'confidence',
                                  'expected', case when e.expect_none then 'nothing' else array_to_string(e.expect_contains, ', ') end));
    end if;
  end loop;
  insert into public.ai_eval_runs (business_id, run_by, total, passed, failed, business_passes)
  values (p_business_id, auth.uid(), v_total, v_passed, v_failed, v_total >= ZELLA_EVAL_MIN_CASES and v_passed = v_total)
  returning id into v_id;
  return jsonb_build_object('run_id', v_id, 'business_id', p_business_id, 'total', v_total, 'passed', v_passed, 'failed', v_failed,
    'business_passes', v_total >= ZELLA_EVAL_MIN_CASES and v_passed = v_total, 'min_cases', ZELLA_EVAL_MIN_CASES);
end $function$;
revoke all on function public.zella_admin_eval_run(uuid) from public, anon;
grant execute on function public.zella_admin_eval_run(uuid) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.zella_admin_eval_overview(p_limit integer DEFAULT 25, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_limit int := least(greatest(coalesce(p_limit, 25), 1), 100); v_offset int := greatest(coalesce(p_offset, 0), 0);
begin
  if coalesce(auth.role(), '') <> 'service_role' and not public.zella_admin_can('businesses.view') then
    raise exception 'NOT_ALLOWED' using errcode = '42501';
  end if;
  return (
    with tested as (
      select b.id, b.name, (select count(*) from public.ai_eval_cases c where c.business_id = b.id)::int as cases
        from public.businesses b
       where exists (select 1 from public.ai_eval_cases c where c.business_id = b.id)
          or exists (select 1 from public.ai_eval_runs r where r.business_id = b.id))
    select jsonb_build_object(
      'total', (select count(*) from tested),
      'passing', (select count(*) from tested t where (select r.business_passes from public.ai_eval_runs r where r.business_id = t.id order by r.run_at desc, r.id limit 1)),
      'limit', v_limit, 'offset', v_offset, 'min_cases', 3,
      'businesses', coalesce((
        select jsonb_agg(jsonb_build_object('business_id', p.id, 'name', p.name, 'cases', p.cases, 'last_run', p.last_run) order by p.name, p.id)
          from (select t.id, t.name, t.cases,
                       (select jsonb_build_object('run_id', r.id, 'run_at', r.run_at, 'total', r.total, 'passed', r.passed, 'failed', r.failed,
                                                  'business_passes', r.business_passes)
                          from public.ai_eval_runs r where r.business_id = t.id order by r.run_at desc, r.id limit 1) as last_run
                  from tested t order by t.name, t.id limit v_limit offset v_offset) p), '[]'::jsonb)));
end $function$;
revoke all on function public.zella_admin_eval_overview(integer, integer) from public, anon;
grant execute on function public.zella_admin_eval_overview(integer, integer) to authenticated, service_role;

commit;
