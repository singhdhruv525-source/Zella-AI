# Writes a rollback for a migration that patches functions with replace(def, $a$old$a$, $a$new$a$): each is undone as
# replace(def, new, old), so only that file's additions go and other migrations' changes stay.
#   python3 -I tests/setup/make_rollback.py [setup|messaging|orders|buffers|channel|escalation|knowledge|configmig|planlang|holiday]
import re, sys
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
    "drop function if exists public.zella_channel_supported(text, text);",
    "-- the review table is kept (renamed) so the owners' decisions and their consent confirmations are not lost",
    "alter table if exists public.automation_channel_reviews rename to automation_channel_reviews_rolled_back;",
    "-- automations put back on the owner's AI-call setting stay that way: nothing claims call reminders, so nothing is sent"])
CFG["escalation"] = ("sql/zella_escalation_rules.sql", "sql/rollback/zella_escalation_rules_rollback.sql", [
    "drop function if exists public.zella_owner_rules_prompt(uuid, text);",
    "drop function if exists public.zella_escalation_triggers(uuid);",
    "drop function if exists public.zella_escalation_trigger_keys();",
    "alter table public.calls drop column if exists transfer_approved_at;"])
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
SRC, DST, DROPS = CFG[which]
src = open(SRC).read()
fns = re.findall(r"pg_get_functiondef\('([^']+)'::regprocedure\);\n  if position\('([a-z_]+)' in def\) = 0 then\n(.*?)\n    execute def;", src, re.S)
out = [f"-- GENERATED by tests/setup/make_rollback.py {which} from {SRC}. Do not edit by hand.",
       "-- Undoes that file: its additions to existing functions come out (other migrations' changes stay), and what it",
       "-- created goes (see below).",
       "\\set ON_ERROR_STOP on", "begin;", "do $$", "declare def text;", "begin"]
for sig, marker, body in fns:
    pairs = re.findall(r"replace\(def, \$a\$(.*?)\$a\$,\s*\$a\$(.*?)\$a\$\)", body, re.S)
    out.append(f"  def := pg_get_functiondef('{sig}'::regprocedure);")
    out.append(f"  if position('{marker}' in def) > 0 then")
    for old, new in reversed(pairs):
        out.append(f"    def := replace(def, $a${new}$a$, $a${old}$a$);")
    out.append(f"    if position('{marker}' in def) > 0 then raise exception '{sig}: could not remove this patch'; end if;")
    out.append("    execute def;")
    out.append("  end if;")
out += ["end $$;"] + DROPS + ["commit;"]
open(DST, 'w').write("\n".join(out) + "\n")
print(len(fns), "functions,", sum(len(re.findall(r'replace\(def', b)) for _, _, b in fns), "replacements")
