-- Undoes sql/zella_record_workflows.sql. One transaction: all or nothing.
-- Nothing recorded is lost: the six tables are kept, renamed (record_approvals_rolled_back, record_milestones_rolled_back,
-- record_inspections_rolled_back, record_exceptions_rolled_back, record_credits_rolled_back,
-- record_workflow_presets_rolled_back), and crm_record_types.workflow stays with each business's setting. The trigger and
-- functions are removed. Linked estimates keep the status an approval gave them, and records keep their statuses and
-- history (the same as if staff had changed them by hand). Applying the migration again starts new, empty tables.
\set ON_ERROR_STOP on
begin;
drop trigger if exists zella_record_workflow_defaults on public.crm_record_types;
drop function if exists public.zella_workflow_due(uuid, integer);
drop function if exists public.zella_record_workflow_save(uuid, text, jsonb);
drop function if exists public.zella_record_workflow_defaults_trg();
drop function if exists public.zella_workflow_clean(jsonb);
drop function if exists public.zella_credit_add(uuid, text, integer, uuid, text, integer);
drop function if exists public.zella_credit_balance(uuid);
drop function if exists public.zella_exception_resolve(uuid, text);
drop function if exists public.zella_exception_open(uuid, text, text, date);
drop function if exists public.zella_inspection_save(uuid, uuid, text, jsonb, boolean, uuid, uuid, timestamptz);
drop function if exists public.zella_inspection_clean(jsonb);
drop function if exists public.zella_milestone_done(uuid, boolean, date);
drop function if exists public.zella_milestone_save(uuid, uuid, text, date, text, uuid, text);
drop function if exists public.zella_approval_approvers(uuid);
drop function if exists public.zella_approval_withdraw(uuid, text);
drop function if exists public.zella_approval_decide(uuid, text, text, uuid, text, uuid);
drop function if exists public.zella_approval_approver(public.crm_records, uuid);
drop function if exists public.zella_approval_request(uuid, text, text, bigint, text, date, uuid, text);
drop function if exists public.zella_workflow_move(public.crm_records, text, text);
drop function if exists public.zella_workflow_log(uuid, uuid, text, text, text, uuid, jsonb);
drop function if exists public.zella_workflow_record(uuid, boolean);
do $$
declare t text; i record; v_stamp text := to_char(now(), 'YYYYMMDDHH24MISS');
begin
  foreach t in array array['record_credits', 'record_exceptions', 'record_inspections', 'record_milestones', 'record_approvals', 'record_workflow_presets'] loop
    continue when to_regclass('public.' || t) is null;
    -- free the index names, so applying the migration again creates its own
    for i in select ix.relname from pg_index x join pg_class ix on ix.oid = x.indexrelid
              where x.indrelid = to_regclass('public.' || t) and not x.indisprimary loop
      execute format('alter index public.%I rename to %I', i.relname, left(i.relname, 40) || '_rb' || v_stamp);
    end loop;
    if to_regclass('public.' || t || '_rolled_back') is not null then
      execute format('alter table public.%I rename to %I', t || '_rolled_back', t || '_rolled_back_' || v_stamp);
    end if;
    execute format('alter table public.%I rename to %I', t, t || '_rolled_back');
    execute format('revoke all on public.%I from authenticated', t || '_rolled_back');
  end loop;
end $$;
commit;
