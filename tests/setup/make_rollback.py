# Writes a rollback for a migration that patches functions with replace(def, $a$old$a$, $a$new$a$): each is undone as
# replace(def, new, old), so only that file's additions go and other migrations' changes stay.
#   python3 -I tests/setup/make_rollback.py [setup|messaging|orders|buffers|channel|escalation|knowledge|configmig|planlang|holiday|windows|tables|slotblocks]
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
which = sys.argv[1] if len(sys.argv) > 1 else "setup"
CFG = {
  "setup": ("sql/zella_setup_enforcement.sql", "sql/rollback/zella_setup_enforcement_rollback.sql", [
    "drop trigger if exists zella_setup_knowledge_trg on public.ai_agent_configs;",
    "drop function if exists public.zella_setup_knowledge_trg();",
    "update public.knowledge_items set status = 'archived', updated_at = now() where source_key like 'setup:%' and source_page_id is null and status <> 'archived';",
    "drop function if exists public.zella_setup_knowledge_sync(uuid);",
    "drop function if exists public.zella_setup_language_apply(uuid, text, text);",
    "drop function if exists public.zella_setup_disabled_tools(uuid);",
    "drop function if exists public.zella_booking_rules(uuid);"]),
  "messaging": ("sql/zella_message_settings_fix.sql", "sql/rollback/zella_message_settings_fix_rollback.sql", [
    "drop trigger if exists zella_reminder_settings_trg on public.automations;",
    "drop function if exists public.zella_reminder_settings_trg();",
    "drop function if exists public.zella_resync_reminders(uuid);",
    "-- the channel switch for reminders that asked for a call is kept (their old channel is in channel_requested): putting",
    "-- it back would leave those reminders unsent again"]),
}
CFG["orders"] = ("sql/zella_order_lookup_assurance.sql", "sql/rollback/zella_order_lookup_assurance_rollback.sql", [
    "drop function if exists public.zella_order_lookup_report(uuid, integer);",
    "drop index if exists public.ai_tool_calls_lookup_idx;",
    "-- the lookup records keep their found_caller_id / found_email results (they are the audit trail)"])
CFG["buffers"] = ("sql/zella_booking_buffers.sql", "sql/rollback/zella_booking_buffers_rollback.sql", [
    "drop trigger if exists zella_appointment_conflict_guard on public.appointments;",
    "drop function if exists public.zella_appointment_conflict_guard();",
    "drop function if exists public.zella_appointment_holds_time(text, text, timestamptz);",
    "drop function if exists public.zella_booking_buffer(uuid);",
    "alter function public.zella_capability_catalog() reset search_path;",
    "alter function public.zella_asset_type_keys() reset search_path;",
    "-- zella_capability_appointment_trg stays not callable by anon (a trigger function; nothing calls it directly)"])
CFG["channel"] = ("sql/zella_channel_review.sql", "sql/rollback/zella_channel_review_rollback.sql", [
    "drop trigger if exists zella_channel_review_trg on public.automations;",
    "drop function if exists public.zella_channel_review_trg();",
    "drop function if exists public.zella_resolve_channel_review(uuid, text, boolean);",
    "drop function if exists public.zella_channel_reviews(uuid);",
    "drop function if exists public.zella_channel_on_hold(uuid, text);",
    "do $$ begin if position('zella_channel_supported' in pg_get_functiondef('public.zella_replace_reminders(uuid, boolean, text)'::regprocedure)) > 0 then raise exception 'channel dependency remains'; end if; end $$;",
    "drop function if exists public.zella_channel_supported(text, text);",
    "-- the review table is kept (renamed) so the owners' decisions and their consent confirmations are not lost",
    "alter table if exists public.automation_channel_reviews rename to automation_channel_reviews_rolled_back;",
    "-- automations put back on the owner's AI-call setting stay that way: nothing claims call reminders, so nothing is sent"])
CFG["escalation"] = ("sql/zella_escalation_rules.sql", "sql/rollback/zella_escalation_rules_rollback.sql", [
    "drop function if exists public.zella_owner_rules_prompt(uuid, text);",
    "drop function if exists public.zella_escalation_triggers(uuid);",
    "drop function if exists public.zella_escalation_trigger_keys();",
    "-- Keep transfer_approved_at and its timestamps; reapplying the migration reuses them."])
CFG["knowledge"] = ("sql/zella_knowledge_live.sql", "sql/rollback/zella_knowledge_live_rollback.sql", [
    "drop trigger if exists zella_knowledge_zcheck_trg on public.knowledge_items;",
    "drop function if exists public.zella_knowledge_check_trg();",
    "-- items that went live stay live (they passed the same check the workflow runs)"])
CFG["configmig"] = ("sql/zella_config_migration.sql", "sql/rollback/zella_config_migration_rollback.sql", [
    "drop function if exists public.zella_config_migration_restore(uuid);",
    "drop function if exists public.zella_config_migration_apply(uuid);",
    "drop function if exists public.zella_config_migration_preview(uuid);",
    "drop function if exists public.zella_setup_language_check(text, text);",
    "drop function if exists public.zella_mask_phone(text);",
    "-- snapshots are kept (renamed): restore any applied business with them before rolling this file back",
    "alter table if exists public.config_migration_snapshots rename to config_migration_snapshots_rolled_back;"])
CFG["planlang"] = ("sql/zella_plan_languages.sql", "sql/rollback/zella_plan_languages_rollback.sql", [
    "drop function if exists public.zella_language_allowance(uuid);"])
CFG["holiday"] = ("sql/zella_holiday_availability.sql", "sql/rollback/zella_holiday_availability_rollback.sql", [])
CFG["windows"] = ("sql/zella_arrival_windows.sql", "sql/rollback/zella_arrival_windows_rollback.sql", [
    "drop function if exists public.zella_arrival_window(uuid);",
    "drop function if exists public.zella_slot_say(timestamptz, text, integer);",
    "drop function if exists public.zella_booking_choices(uuid, timestamptz, timestamptz, integer, integer, integer);"])
CFG["tables"] = ("sql/zella_tables.sql", "sql/rollback/zella_tables_rollback.sql", [
    "update public.industry_configurations set features = jsonb_set(features, '{capabilities,on}', (features #> '{capabilities,on}') - 'tables') where features #> '{capabilities,on}' ? 'tables';",
    "update public.industry_configurations set features = jsonb_set(features, '{capabilities,optional}', (features #> '{capabilities,optional}') - 'tables') where features #> '{capabilities,optional}' ? 'tables';",
    "do $$\ndeclare t text; v_generation bigint;\nbegin\n  create table if not exists public.table_data_rolled_back (source_table text not null, business_id uuid, row_data jsonb not null, archived_at timestamptz not null default now());\n  alter table public.table_data_rolled_back add column if not exists id bigint generated always as identity;\n  alter table public.table_data_rolled_back add column if not exists generation_id bigint;\n  lock table public.table_data_rolled_back in share row exclusive mode;\n  alter table public.table_data_rolled_back enable row level security;\n  revoke all on public.table_data_rolled_back from public, anon, authenticated;\n  -- Record a generation even when every archive query is empty.\n  insert into public.table_data_rolled_back (source_table, row_data) values ('rollback_generation', '{}') returning id into v_generation;\n  foreach t in array array['business_capabilities', 'appointments', 'waitlist_entries', 'table_states'] loop\n    continue when to_regclass('public.' || t) is null;\n    execute format('lock table public.%I in share row exclusive mode', t);\n    execute format('insert into public.table_data_rolled_back (source_table, business_id, row_data, generation_id) select %L, business_id, to_jsonb(r), %L from public.%I r where %s', t, v_generation, t,\n      case t when 'business_capabilities' then 'capability = ''tables'''\n      when 'appointments' then 'to_jsonb(r) ->> ''table_ids'' is not null'\n      when 'waitlist_entries' then '(to_jsonb(r) ->> ''party_size'' is not null or to_jsonb(r) ->> ''preferences'' is not null or to_jsonb(r) ->> ''contact_ok'' is not null)'\n      else 'true' end);\n  end loop;\nend $$;",
    "delete from public.business_capabilities where capability = 'tables';",
    "drop trigger if exists zella_table_clearing_trg on public.appointments;",
    "drop function if exists public.zella_table_clearing_trg();",
    "drop trigger if exists zella_appointment_conflict_guard on public.appointments;",
    "create trigger zella_appointment_conflict_guard before insert or update of start_time, end_time, staff_id, status, booking_state on public.appointments for each row execute function public.zella_appointment_conflict_guard();",
    "drop function if exists public.zella_book_appointment(uuid, uuid, text, timestamptz, integer, uuid, integer, text, jsonb);",
    "drop function if exists public.zella_table_action(uuid, text, jsonb);",
    "drop function if exists public.zella_save_combinations(uuid, jsonb);",
    "drop function if exists public.zella_tables_check_bookings(uuid);",
    "drop function if exists public.zella_tables_affected(uuid);",
    "drop function if exists public.zella_table_board(uuid, timestamptz);",
    "drop function if exists public.zella_save_tables(uuid, jsonb);",
    "drop function if exists public.zella_tables(uuid);",
    "drop function if exists public.zella_table_event(uuid, uuid, uuid, text, jsonb);",
    "drop function if exists public.zella_max_party_ai(uuid);",
    "drop function if exists public.zella_offer_times(boolean, integer, uuid, timestamptz, timestamptz, integer, integer, text);",
    "drop function if exists public.zella_table_times(uuid, timestamptz, timestamptz, integer, integer, integer, text, text[]);",
    "drop function if exists public.zella_seating_pref(uuid, text);",
    "drop function if exists public.zella_pick_tables(uuid, integer, timestamptz, timestamptz, uuid, text, text[]);",
    "drop function if exists public.zella_tables_fit(uuid, uuid[], integer, text, text[]);",
    "drop function if exists public.zella_tables_free(uuid[], timestamptz, timestamptz, uuid);",
    "drop function if exists public.zella_table_mode(uuid);",
    "-- Reservation, waitlist, capability and state data are archived privately before removal. To bring them back,",
    "-- re-apply sql/zella_tables.sql and then run sql/rollback/zella_tables_restore.sql.",
    "drop index if exists public.appointments_table_ids_idx;",
    "alter table public.appointments drop column if exists table_ids;",
    "alter table public.waitlist_entries drop column if exists party_size, drop column if exists preferences, drop column if exists contact_ok;",
    "drop table if exists public.table_states;",
    "do $$\ndeclare t text; i record; v_stamp text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS');\nbegin\n  foreach t in array array['table_events', 'table_blocks', 'table_combinations', 'restaurant_tables'] loop\n    continue when to_regclass('public.' || t) is null;\n    for i in select ix.relname, ix.oid from pg_index x join pg_class ix on ix.oid = x.indexrelid\n      where x.indrelid = to_regclass('public.' || t) and not x.indisprimary loop\n      execute format('alter index public.%I rename to %I', i.relname, left(i.relname, 20) || '_rb' || i.oid || '_' || v_stamp);\n    end loop;\n    if to_regclass('public.' || t || '_rolled_back') is not null then\n      execute format('alter table public.%I rename to %I', t || '_rolled_back', t || '_rb_' || v_stamp);\n    end if;\n    execute format('alter table public.%I rename to %I', t, t || '_rolled_back');\n    execute format('alter table public.%I enable row level security', t || '_rolled_back');\n    execute format('revoke all on public.%I from public, anon, authenticated', t || '_rolled_back');\n  end loop;\nend $$;"])
CFG["slotblocks"] = ("sql/zella_slots_resource_blocks.sql", "sql/rollback/zella_slots_resource_blocks_rollback.sql", [])
SRC, DST, DROPS = CFG[which]
src = (ROOT / SRC).read_text()
fns = re.findall(r"pg_get_functiondef\('([^']+)'::regprocedure\);\n  if position\('([a-z_]+)' in def\) = 0 then\n(.*?)\n    execute def;", src, re.S)
if not fns:
    raise ValueError(f"{SRC}: no function patches found")
out = [f"-- GENERATED by tests/setup/make_rollback.py {which} from {SRC}. Do not edit by hand.",
       "-- Undoes that file: its additions to existing functions come out (other migrations' changes stay), and what it",
       "-- created goes (see below).",
       "begin;", "do $$", "declare def text; previous_def text;", "begin"]
for sig, marker, body in fns:
    pairs = re.findall(r"replace\(def, \$a\$(.*?)\$a\$,\s*\$a\$(.*?)\$a\$\)", body, re.S)
    if not pairs:
        raise ValueError(f"{sig}: no reversible replacements found")
    out.append(f"  def := pg_get_functiondef('{sig}'::regprocedure);")
    out.append(f"  if position('{marker}' in def) > 0 then")
    for old, new in reversed(pairs):
        if old == new or not new:
            raise ValueError(f"{sig}: non-reversible replacement")
        out.append("    previous_def := def;")
        out.append(f"    def := replace(def, $a${new}$a$, $a${old}$a$);")
        out.append("    if def = previous_def then raise exception 'rollback replacement did not match'; end if;")
    out.append(f"    if position('{marker}' in def) > 0 then raise exception '{sig}: could not remove this patch'; end if;")
    if which == "setup" and "booking" in sig:
        out.append("    if def ~ 'v_notice|v_ahead|zella_booking_rules' then raise exception 'booking patch remains'; end if;")
    if which == "channel":
        out.append("    if position('zella_channel_supported' in def) > 0 then raise exception 'channel dependency remains'; end if;")
    out.append("    execute def;")
    out.append("  end if;")
out += ["end $$;"] + DROPS + ["commit;"]
(ROOT / DST).write_text("\n".join(out) + "\n")
print(len(fns), "functions,", sum(len(re.findall(r'replace\(def', b)) for _, _, b in fns), "replacements")
