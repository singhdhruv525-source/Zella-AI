-- Undoes sql/zella_tenant_business_id.sql: removes the triggers, the two trigger functions, the foreign keys, the
-- indexes and the business_id columns it added. The column is a copy of the parent's business_id, so dropping it
-- loses no information; no row is deleted. Safe to run again.
begin;
do $$
declare r record;
begin
  for r in select * from (values ('ai_agent_configs'), ('conversation_messages'), ('business_report_runs'),
                                 ('integration_secrets'), ('on_call_reminders_sent'), ('industry_automation_runs')) v(tbl) loop
    continue when to_regclass('public.' || r.tbl) is null;
    execute format('drop trigger if exists zella_business_id_trg on public.%I', r.tbl);
    execute format('alter table public.%I drop constraint if exists %I', r.tbl, r.tbl || '_business_id_fkey');
    execute format('drop index if exists public.%I', r.tbl || '_business_id_idx');
    execute format('alter table public.%I drop column if exists business_id', r.tbl);
  end loop;
  for r in select * from (values ('ai_agents'), ('conversations'), ('business_report_schedules'),
                                 ('integrations'), ('on_call_shifts'), ('automations')) v(tbl) loop
    continue when to_regclass('public.' || r.tbl) is null;
    execute format('drop trigger if exists zella_business_id_parent_trg on public.%I', r.tbl);
  end loop;
end $$;
drop function if exists public.zella_child_business_id_trg();
drop function if exists public.zella_parent_business_id_trg();
commit;
