-- Undoes sql/zella_industry_data.sql exactly: zella_sensitive_industry comes back from zella_function_archive and the
-- four columns it added are dropped (with their constraints). The function must be exactly that file's version first,
-- otherwise ROLLBACK_DRIFT and nothing changes. Safe to run twice.
-- Run sql/rollback/zella_brain_safety_rules_rollback.sql first if that migration is applied (it reads safety_rules),
-- and deploy the earlier owner-provision-business first (it reads the columns when they exist).
begin;
do $$
declare a record; s constant text := 'public.zella_sensitive_industry(uuid)';
begin
  if to_regclass('public.zella_function_archive') is null
     or not exists (select 1 from public.zella_function_archive where migration = 'zella_industry_data') then
    return;   -- not applied, or already rolled back
  end if;
  if md5(pg_get_functiondef(s::regprocedure)) <> 'be26e6cd036052ebd206de5573fed180' then
    raise exception 'ROLLBACK_DRIFT: % has changed since this migration', s;
  end if;
  if position('safety_rules' in pg_get_functiondef('public.zella_brain_prompt_base(uuid)'::regprocedure)) > 0 then
    raise exception 'ROLLBACK_DRIFT: zella_brain_prompt_base reads safety_rules; roll back zella_brain_safety_rules.sql first';
  end if;
  for a in select definition from public.zella_function_archive where migration = 'zella_industry_data' loop
    execute a.definition;
  end loop;
  alter table public.industries drop column if exists sensitive, drop column if exists booking_model;
  alter table public.industry_configurations drop column if exists automation_defaults, drop column if exists safety_rules;
  delete from public.zella_function_archive where migration = 'zella_industry_data';
end $$;
commit;
