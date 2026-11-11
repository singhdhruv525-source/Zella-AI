-- ---------- data (hand-written; included at the top of industry_2026_11_04_rollback.sql) ----------
-- Puts data back the way it was before the ten industry migrations of 4 Nov 2026, without losing anything recorded
-- since:
--   * private values (access codes, member IDs ...) go back into their records' data, as they were before;
--   * industry presets and every business's record types come back from the backups taken before deploying
--     (backup_20261104_presets, backup_20261104_types; see docs/INDUSTRY_WORK_2026-11-04.md section 4). The rollback
--     refuses to run without them;
--   * record types added by the deploy are removed when they hold no records; with records they stay;
--   * capability defaults, the staff transcript opt-in and the new starter automations are removed;
--   * the new tables (capability choices, private values, money) are dropped when empty, otherwise kept under
--     "<name>_rolled_back_20261104" so nothing recorded is lost. Private values are emptied once copied back.
-- Audit log rows written since are kept.

do $$ begin
  if to_regclass('public.backup_20261104_presets') is null or to_regclass('public.backup_20261104_types') is null then
    raise exception 'ROLLBACK_NEEDS_BACKUPS: take backup_20261104_presets and backup_20261104_types before deploying (see the deployment notes)';
  end if;
end $$;

-- Retires a table added by the deploy: dropped when empty, renamed when it holds rows.
create or replace function pg_temp.zella_rb_retire_table(p_table text) returns void language plpgsql as $f$
declare v_has boolean;
begin
  if to_regclass('public.' || p_table) is null then return; end if;
  execute format('select exists (select 1 from public.%I)', p_table) into v_has;
  if v_has then execute format('alter table public.%I rename to %I', p_table, p_table || '_rolled_back_20261104');
  else execute format('drop table public.%I cascade', p_table); end if;
end $f$;

-- 1. Copy only missing keys in object data, for the same business. Existing keys (including
-- nulls and values of a different type) win; non-object data and conflicting secrets stay archived.
do $$ begin
  if to_regclass('public.crm_record_secrets') is not null then
    lock table public.crm_record_secrets, public.crm_records in share row exclusive mode;
    with copied as (
      update public.crm_records r set data = r.data || s.v
      from (select s.record_id, s.business_id, jsonb_object_agg(s.field_key, s.value) v
        from public.crm_record_secrets s join public.crm_records r
          on r.id = s.record_id and r.business_id = s.business_id
        where jsonb_typeof(r.data) = 'object' and not r.data ? s.field_key
        group by s.record_id, s.business_id) s
      where r.id = s.record_id and r.business_id = s.business_id
      returning r.id, r.business_id, s.v
    )
    delete from public.crm_record_secrets s using copied c
      where s.record_id = c.id and s.business_id = c.business_id
        and c.v ? s.field_key and c.v -> s.field_key = to_jsonb(s.value);
  end if;
end $$;

-- 2. the 15 starter automations added by zella_automation_presets_v2.sql (and copies installed but never run).
--    Runs before the presets are restored: zella_industry_key_for() reads the presets, so this must see the
--    deployed ones (an insurance business only matches as insurance while the new presets are still in place).
with v(industry_key, name) as (values ('legal', 'Deadline in 30 days'), ('legal', 'Deadline in 7 days'), ('legal', 'Deadline tomorrow'),
  ('insurance', 'Policy renewal coming up'), ('insurance', 'New claim not yet submitted'), ('insurance', 'Quote waiting for an answer'),
  ('healthcare', 'Refill request waiting'), ('healthcare', 'Prior authorization pending'), ('dental', 'Treatment plan not accepted'),
  ('fitness', 'Freeze or cancellation request waiting'), ('childcare', 'Incident report still open'), ('property_management', 'Vendor insurance expiring'),
  ('travel', 'Passport expiring'), ('automotive', 'Declined work reminder'), ('cleaning', 'Visit not started'))
, gone as (delete from public.industry_automation_presets p using v where p.industry_key = v.industry_key and p.name = v.name returning p.industry_key, p.name, p.description, p.trigger_type, p.trigger_config)
-- Match the tenant industry and the unchanged installer defaults from zella_apply_industry_automations.
-- Keep authored, customized, and previously run rules; a shared name alone is never enough.
delete from public.automations a using gone p, public.businesses b
 where a.business_id = b.id and public.zella_industry_key_for(b.id) = p.industry_key
   and a.name = p.name and a.description is not distinct from p.description
   and a.status = 'active' and a.actions = '[]'::jsonb and a.conditions = '{}'::jsonb
   and a.trigger_type = p.trigger_type and a.trigger_config = p.trigger_config
   and a.created_by is null
   and not exists (select 1 from public.industry_automation_runs r where r.automation_id = a.id);

-- 3. presets as they were
delete from public.industry_crm_presets p where not exists (select 1 from public.backup_20261104_presets b where b.key = p.key);
update public.industry_crm_presets p set match = b.match, config = b.config from public.backup_20261104_presets b where b.key = p.key;

insert into public.industry_crm_presets select * from public.backup_20261104_presets on conflict (key) do nothing;

-- 4. Restore by ID or the business/key used by records; keep a replacement ID on key collisions.
-- Added types go only when empty.
update public.crm_record_types t set singular = b.singular, plural = b.plural, icon = b.icon, title_label = b.title_label, link_person = b.link_person,
       statuses = b.statuses, closed_statuses = b.closed_statuses, fields = b.fields, columns = b.columns, notice = b.notice, enabled = b.enabled,
       position = b.position, preset_key = b.preset_key, updated_at = b.updated_at
  from public.backup_20261104_types b where b.id = t.id or (b.business_id = t.business_id and b.key = t.key);
insert into public.crm_record_types (id, business_id, key, singular, plural, icon, title_label, link_person, statuses, closed_statuses, fields, columns, notice, enabled, position, preset_key, created_at, updated_at)
select b.id, b.business_id, b.key, b.singular, b.plural, b.icon, b.title_label, b.link_person, b.statuses, b.closed_statuses, b.fields, b.columns, b.notice, b.enabled, b.position, b.preset_key, b.created_at, b.updated_at
  from public.backup_20261104_types b where not exists (select 1 from public.crm_record_types t where t.id = b.id or (t.business_id = b.business_id and t.key = b.key));
delete from public.crm_record_types t
 where not exists (select 1 from public.backup_20261104_types b where b.id = t.id or (b.business_id = t.business_id and b.key = t.key))
   and not exists (select 1 from public.crm_records r where r.business_id = t.business_id and r.type_key = t.key);

-- 5. capability defaults off the industry configuration
update public.industry_configurations set features = features - 'capabilities' where features ? 'capabilities';

-- 6. the staff transcript opt-in
update public.businesses set setup_data = case when (setup_data -> 'privacy') - 'staff_read_call_content' = '{}'::jsonb then setup_data - 'privacy'
                                               else setup_data #- '{privacy,staff_read_call_content}' end
 where setup_data -> 'privacy' ? 'staff_read_call_content';

-- 7. photos and files (zella_record_files.sql): the storage policies go, so signed-in users can no longer reach the
--    bucket; the bucket and any files already in it are kept (nothing a customer uploaded is deleted). The file list
--    table is retired like the other new tables (kept, renamed, when it holds rows).
drop policy if exists record_files_insert on storage.objects;
drop policy if exists record_files_select on storage.objects;
drop policy if exists record_files_delete on storage.objects;
delete from storage.buckets b where b.id = 'record-files' and not exists (select 1 from storage.objects o where o.bucket_id = b.id);

-- 8. message policy (zella_message_courtesy.sql): the industry defaults table holds only reference settings and is
--    dropped; an owner's own choices stay in businesses.setup_data.message_policy (ignored by the earlier code, and
--    back in force if the migration is applied again). Messages already held back stay on record as skipped.
drop table if exists public.industry_message_policy cascade;

-- 9. calendar connections (zella_calendar_providers.sql): the earlier schema allows Google only. Outlook connections
--    made since are kept, with their Vault keys, in calendar_connections_outlook_rolled_back_20261104 (nothing a business
--    connected is lost; reconnecting works again once the migration is re-applied), and their future busy times are
--    removed so they don't block bookings without a sync. Google connections, including ones made through the new
--    sign-in, keep working.
do $$ begin
  if exists (select 1 from public.calendar_connections where provider <> 'google') then
    create table if not exists public.calendar_connections_outlook_rolled_back_20261104 as select * from public.calendar_connections where false;
    alter table public.calendar_connections_outlook_rolled_back_20261104 enable row level security;
    revoke all on public.calendar_connections_outlook_rolled_back_20261104 from anon, authenticated, public;
    insert into public.calendar_connections_outlook_rolled_back_20261104 select * from public.calendar_connections where provider <> 'google';
    delete from public.blocked_times where connection_id in (select id from public.calendar_connections where provider <> 'google') and end_time > now();
    delete from public.calendar_connections where provider <> 'google';
  end if;
end $$;
alter table public.calendar_connections drop constraint if exists calendar_connections_provider_check;
alter table public.calendar_connections add constraint calendar_connections_provider_check check (provider = 'google');
