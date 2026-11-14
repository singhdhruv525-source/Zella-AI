-- Undoes sql/zella_tenant_business_id.sql: removes the triggers, the two trigger functions, the foreign keys, the
-- indexes and the business_id columns it added. The column is a copy of the parent's business_id, so dropping it
-- loses no information while every row still has its parent; if a row has lost its parent the rollback stops
-- (ORPHANS) and changes nothing. No row is deleted. Safe to run again.
begin;
do $$
declare r record; v_orphans bigint;
begin
  -- two of these tables have no foreign key to their parent (on_call_reminders_sent, industry_automation_runs): a row
  -- whose parent was deleted keeps business_id as its only link to its business. Dropping the column would lose it,
  -- so the rollback stops instead and changes nothing.
  for r in select * from (values ('ai_agent_configs', 'ai_agents', 'agent_id'), ('conversation_messages', 'conversations', 'conversation_id'),
                                 ('business_report_runs', 'business_report_schedules', 'schedule_id'), ('integration_secrets', 'integrations', 'integration_id'),
                                 ('on_call_reminders_sent', 'on_call_shifts', 'shift_id'), ('industry_automation_runs', 'automations', 'automation_id')) v(tbl, parent, key) loop
    continue when to_regclass('public.' || r.tbl) is null or to_regclass('public.' || r.parent) is null;
    continue when not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = r.tbl and column_name = 'business_id');
    execute format('select count(*) from public.%I c where not exists (select 1 from public.%I p where p.id = c.%I)', r.tbl, r.parent, r.key) into v_orphans;
    if v_orphans > 0 then
      raise exception 'ORPHANS: % row(s) of % have no %; business_id is their only link to their business, so it is not dropped. Review them first', v_orphans, r.tbl, r.parent;
    end if;
  end loop;
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
