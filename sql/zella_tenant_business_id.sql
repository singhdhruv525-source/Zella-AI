-- Zella Voice: business_id on the six business-owned tables that reached their business only through a parent
-- (TEN-1, conformance gap G-8). Expand step only: authorization does not change.
--
--   table                      parent (key)                       today's protection
--   ai_agent_configs           ai_agents (agent_id)               policies join through ai_agents
--   conversation_messages      conversations (conversation_id)    policies join through conversations
--   business_report_runs       business_report_schedules          server only (no direct-access policy)
--   integration_secrets        integrations (integration_id)      server only
--   on_call_reminders_sent     on_call_shifts (shift_id)          server only
--   industry_automation_runs   automations (automation_id)        server only
--
-- For each table: a business_id column, filled from the parent, required, with a foreign key to businesses (on
-- delete cascade, as the parent already is) and an index. A trigger on the table sets business_id from the parent on
-- every insert and on every change of the parent key, and refuses a business_id that is not the parent's
-- (TENANT_MISMATCH). A trigger on the parent carries a change of the parent's business_id to its rows, so the copy
-- can never go stale. Writers need no change: they don't name business_id and the trigger fills it.
-- The row security policies are NOT changed here. Moving them to business_id is an authorization change and gets
-- its own reviewed step once this has run in production.
-- A row whose parent no longer exists stops the file (ORPHANS) instead of being deleted: production has none
-- (checked read-only on 13 Nov 2026; 4 rows in these tables in all). Safe to run twice.
-- Rollback: sql/rollback/zella_tenant_business_id_rollback.sql

begin;   -- all or nothing: a stop (ORPHANS, VERSION_MISMATCH) leaves the database as it was

-- child side: business_id always equals the parent's
create or replace function public.zella_child_business_id_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_parent text := tg_argv[0]; v_key text := tg_argv[1]; v_ref uuid; v_biz uuid;
begin
  v_ref := nullif(to_jsonb(new) ->> v_key, '')::uuid;
  execute format('select business_id from public.%I where id = $1', v_parent) into v_biz using v_ref;
  if v_biz is null then
    raise exception 'TENANT_MISMATCH: %.% does not point to an existing %', tg_table_name, v_key, v_parent using errcode = '23503';
  end if;
  if new.business_id is not null and new.business_id <> v_biz then
    raise exception 'TENANT_MISMATCH: %.business_id is not the business of its %', tg_table_name, v_parent using errcode = '23514';
  end if;
  new.business_id := v_biz;
  return new;
end $$;

-- parent side: a change of the parent's business carries to its rows (pairs "table:key" in tg_argv)
create or replace function public.zella_parent_business_id_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare spec text;
begin
  if new.business_id is distinct from old.business_id then
    foreach spec in array tg_argv loop
      execute format('update public.%I set business_id = $1 where %I = $2', split_part(spec, ':', 1), split_part(spec, ':', 2))
        using new.business_id, new.id;
    end loop;
  end if;
  return null;
end $$;

revoke all on function public.zella_child_business_id_trg() from public, anon, authenticated;
revoke all on function public.zella_parent_business_id_trg() from public, anon, authenticated;

do $$
declare r record; v_orphans bigint;
begin
  for r in select * from (values
      ('ai_agent_configs',         'ai_agents',                 'agent_id'),
      ('conversation_messages',    'conversations',             'conversation_id'),
      ('business_report_runs',     'business_report_schedules', 'schedule_id'),
      ('integration_secrets',      'integrations',              'integration_id'),
      ('on_call_reminders_sent',   'on_call_shifts',            'shift_id'),
      ('industry_automation_runs', 'automations',               'automation_id')
    ) v(tbl, parent, key)
  loop
    -- the shape this file was written against
    if to_regclass('public.' || r.tbl) is null or to_regclass('public.' || r.parent) is null
       or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = r.tbl and column_name = r.key and data_type = 'uuid')
       or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = r.parent and column_name = 'business_id' and is_nullable = 'NO')
       or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = r.parent and column_name = 'id' and data_type = 'uuid') then
      raise exception 'VERSION_MISMATCH: %.% or %.business_id is not as this file expects', r.tbl, r.key, r.parent;
    end if;
    execute format('alter table public.%I add column if not exists business_id uuid', r.tbl);
    execute format('update public.%I c set business_id = p.business_id from public.%I p where p.id = c.%I and c.business_id is distinct from p.business_id',
                   r.tbl, r.parent, r.key);
    execute format('select count(*) from public.%I c where not exists (select 1 from public.%I p where p.id = c.%I)', r.tbl, r.parent, r.key) into v_orphans;
    if v_orphans > 0 then
      raise exception 'ORPHANS: % row(s) of % point to a % that no longer exists; review them before running this file', v_orphans, r.tbl, r.parent;
    end if;
    execute format('alter table public.%I alter column business_id set not null', r.tbl);
    if not exists (select 1 from pg_constraint where conrelid = ('public.' || r.tbl)::regclass and conname = r.tbl || '_business_id_fkey') then
      execute format('alter table public.%I add constraint %I foreign key (business_id) references public.businesses (id) on delete cascade',
                     r.tbl, r.tbl || '_business_id_fkey');
    end if;
    execute format('create index if not exists %I on public.%I (business_id)', r.tbl || '_business_id_idx', r.tbl);
    execute format('drop trigger if exists zella_business_id_trg on public.%I', r.tbl);
    execute format('create trigger zella_business_id_trg before insert or update of business_id, %I on public.%I
                      for each row execute function public.zella_child_business_id_trg(%L, %L)', r.key, r.tbl, r.parent, r.key);
  end loop;

  -- parents (one trigger each; conversations and the others have exactly one child here)
  for r in select * from (values
      ('ai_agents',                 'ai_agent_configs:agent_id'),
      ('conversations',             'conversation_messages:conversation_id'),
      ('business_report_schedules', 'business_report_runs:schedule_id'),
      ('integrations',              'integration_secrets:integration_id'),
      ('on_call_shifts',            'on_call_reminders_sent:shift_id'),
      ('automations',               'industry_automation_runs:automation_id')
    ) v(parent, spec)
  loop
    execute format('drop trigger if exists zella_business_id_parent_trg on public.%I', r.parent);
    execute format('create trigger zella_business_id_parent_trg after update of business_id on public.%I
                      for each row execute function public.zella_parent_business_id_trg(%L)', r.parent, r.spec);
  end loop;
end $$;
commit;
