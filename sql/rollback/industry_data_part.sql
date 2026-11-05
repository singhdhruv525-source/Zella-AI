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

-- 1. private values back into record data, then emptied
do $$ begin
  if to_regclass('public.crm_record_secrets') is not null then
    update public.crm_records r set data = r.data || s.v
      from (select record_id, jsonb_object_agg(field_key, value) v from public.crm_record_secrets group by record_id) s
     where s.record_id = r.id;
    delete from public.crm_record_secrets;
  end if;
end $$;

-- 2. presets as they were
delete from public.industry_crm_presets p where not exists (select 1 from public.backup_20261104_presets b where b.key = p.key);
update public.industry_crm_presets p set match = b.match, config = b.config from public.backup_20261104_presets b where b.key = p.key;

-- 3. record types as they were; added ones go only when empty
update public.crm_record_types t set singular = b.singular, plural = b.plural, icon = b.icon, title_label = b.title_label, link_person = b.link_person,
       statuses = b.statuses, closed_statuses = b.closed_statuses, fields = b.fields, columns = b.columns, notice = b.notice, enabled = b.enabled,
       position = b.position, preset_key = b.preset_key, updated_at = b.updated_at
  from public.backup_20261104_types b where b.id = t.id;
delete from public.crm_record_types t
 where not exists (select 1 from public.backup_20261104_types b where b.id = t.id)
   and not exists (select 1 from public.crm_records r where r.business_id = t.business_id and r.type_key = t.key);

-- 4. capability defaults off the industry configuration
update public.industry_configurations set features = features - 'capabilities' where features ? 'capabilities';

-- 5. the staff transcript opt-in
update public.businesses set setup_data = case when (setup_data -> 'privacy') - 'staff_read_call_content' = '{}'::jsonb then setup_data - 'privacy'
                                               else setup_data #- '{privacy,staff_read_call_content}' end
 where setup_data -> 'privacy' ? 'staff_read_call_content';

-- 6. the 15 starter automations added by zella_automation_presets_v2.sql (and copies installed but never run)
with v(industry_key, name) as (values ('legal', 'Deadline in 30 days'), ('legal', 'Deadline in 7 days'), ('legal', 'Deadline tomorrow'),
  ('insurance', 'Policy renewal coming up'), ('insurance', 'New claim not yet submitted'), ('insurance', 'Quote waiting for an answer'),
  ('healthcare', 'Refill request waiting'), ('healthcare', 'Prior authorization pending'), ('dental', 'Treatment plan not accepted'),
  ('fitness', 'Freeze or cancellation request waiting'), ('childcare', 'Incident report still open'), ('property_management', 'Vendor insurance expiring'),
  ('travel', 'Passport expiring'), ('automotive', 'Declined work reminder'), ('cleaning', 'Visit not started'))
, gone as (delete from public.industry_automation_presets p using v where p.industry_key = v.industry_key and p.name = v.name returning p.name)
delete from public.automations a where a.name in (select name from v)
   and not exists (select 1 from public.industry_automation_runs r where r.automation_id = a.id);
