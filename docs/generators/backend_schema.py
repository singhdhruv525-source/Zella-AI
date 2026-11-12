#!/usr/bin/env python3
"""Writes docs/BACKEND_SCHEMA.md from a Postgres database that has the Zella Voice schema.

Usage (isolated test database only, never production with a password on the command line):
    python3 -I docs/generators/backend_schema.py --host /var/lib/postgresql/zella-sec --port 55433 --db zprod \
        > docs/BACKEND_SCHEMA.md

It reads the catalog only (tables, columns, keys, policies, triggers, functions, grants). It never reads rows.
Table purposes and groups are kept by hand below: a new table without an entry is listed under "Not yet described",
so the gap is visible. Keep this file and the generated document in the same pull request.
"""
import argparse
import json
import subprocess
import sys

# group, then table -> one-line purpose
GROUPS = [
    ("Tenancy, people and access", {
        "businesses": "One row per business (tenant): name, industry, status, time zone, plan link.",
        "business_members": "A person's membership in a business and their role (owner, admin, manager, staff, viewer).",
        "business_invitations": "Team and owner invitations: email, role, token, expiry, who accepted.",
        "profiles": "One row per signed-in person: name, phone, preferences.",
        "staff_members": "Staff who do the work (may or may not sign in): name, role, skills, colour.",
        "staff_handovers": "Moving one person's open work to another person, with what was moved.",
        "time_off_requests": "Staff time off, requested and decided by a manager.",
        "platform_admins": "Zella Voice staff who can use the platform admin, and their platform role.",
        "platform_role_permissions": "Which named permissions each platform role has.",
        "sensitive_approvals": "Two-person approval for risky actions (exports, erasure, role changes).",
        "legal_documents": "Versions of the terms and policies people accept.",
        "legal_acceptances": "Who accepted which legal document version, and when.",
        "audit_logs": "Append-only record of every privileged action. Only the server can write it.",
        "rate_limits": "Counters that slow down repeated requests per key and window.",
    }),
    ("Business setup and industry configuration", {
        "industries": "The 28 industries Zella Voice serves.",
        "industry_configurations": "Each industry's versioned configuration (terms, booking model, defaults).",
        "industry_modules": "CRM modules available per industry.",
        "business_modules": "Which modules a business has switched on.",
        "business_capabilities": "Which kinds of work are on for a business (scheduling, check-ins, waitlist, dispatch, ...).",
        "industry_crm_presets": "Default record types and fields per industry.",
        "industry_automation_presets": "Default automations per industry.",
        "industry_automation_defaults": "Default automation settings applied when a business is created.",
        "industry_automation_runs": "Log of applying industry automation presets to a business.",
        "industry_message_policy": "Per-industry message policy (for example drafts only in regulated industries).",
        "business_hours": "Weekly opening hours per business (several ranges a day allowed).",
        "business_closures": "Holidays and one-off closures, whole or part day.",
        "business_languages": "Languages the receptionist offers for a business.",
        "business_voice": "The voice a business chose for its receptionist.",
        "business_phone_numbers": "Phone numbers assigned to a business (and their Vapi number id).",
        "business_verification_documents": "Business and owner verification documents (files in private storage).",
        "provisioning_steps": "Progress of each Create Business wizard step.",
        "activation_tests": "Results of the checks run before a business goes live.",
        "config_migration_snapshots": "Copy of a business's settings before a configuration upgrade, so it can be restored.",
        "zella_milestones": "First-time moments a business reached (first call answered, first booking, ...).",
        "platform_settings": "Platform-wide switches and settings (live switches, provider choices). No secrets.",
        "business_usage_preferences": "What a business wants to happen near or over its usage limits.",
    }),
    ("Customers and CRM", {
        "customers": "A person the business serves (caller, client, patient, guest). Leads are customers not yet converted.",
        "customer_relationships": "Verified links between people (parent, guardian, partner) with what each may do.",
        "customer_requests": "Things a customer asked for that staff must handle, with owner and due time.",
        "customer_consents": "Per-customer consent flags (older table; contact_consents is the history).",
        "contact_consents": "Append-only consent history per phone or email, channel and purpose.",
        "duplicate_reviews": "Possible duplicate customers waiting for staff to merge or keep apart.",
        "crm_tasks": "Tasks for staff on customers and records.",
        "crm_record_types": "A business's industry record types (pet, vehicle, matter, job, ...) and their fields.",
        "crm_records": "Industry records (one pet, one vehicle, one matter) linked to customers.",
        "crm_record_events": "History of each industry record.",
        "crm_record_files": "Files attached to records, with the upload check verdict.",
        "crm_record_secrets": "Private record fields (access codes, member IDs) kept apart and shown only to allowed roles.",
        "record_workflow_presets": "Default approvals, milestones and checks per record type.",
        "record_approvals": "Approvals waiting or decided on a record.",
        "record_milestones": "Dates coming up on a record (renewals, due services).",
        "record_inspections": "Checklists done on a record during a visit.",
        "record_exceptions": "Problems holding up work on a record until resolved.",
        "record_credits": "Units added to or used from a record (packages, class passes).",
        "quotes": "Quotes sent to customers and their status.",
        "customer_charges": "Money owed by a customer (records only; no card data).",
        "customer_charge_payments": "Payments recorded against a customer charge.",
        "data_rights_requests": "Customer data access, export and erasure requests.",
    }),
    ("Leads", {
        "lead_rules": "Per-business rules for new leads (sources, qualification, call-back timing).",
        "lead_questions": "Questions the receptionist asks a lead, and when an answer qualifies them.",
        "lead_submissions": "Raw lead submissions from forms and integrations, before they become customers.",
        "website_forms": "A business's website forms and chat widgets, with their public form key.",
        "website_sources": "Websites a business lets Zella Voice read for knowledge.",
        "website_pages": "Pages read from those websites.",
        "google_lead_keys": "Keys for Google Ads lead form webhooks (stored hashed).",
        "google_lead_events": "Google lead deliveries received, for de-duplication.",
        "assignment_rules": "How new work is assigned to staff, and when to alert about unassigned work.",
    }),
    ("Calls and the AI receptionist", {
        "calls": "Every inbound and outbound call: numbers, status, outcome, summary, transcript (role-restricted).",
        "call_messages": "Messages the receptionist took for the business.",
        "call_insights": "AI call intelligence results (topics, sentiment) when switched on.",
        "callbacks": "Calls the business owes a customer, with status and owner.",
        "callback_attempts": "Each attempt to make a callback.",
        "ai_agents": "Receptionist agents per business.",
        "ai_agent_configs": "Receptionist settings per business (greeting, rules, escalation, safety lines).",
        "agent_config_versions": "Versions of the assistant configuration that was built and sent to Vapi.",
        "assistant_deliveries": "Which configuration version each call actually received.",
        "ai_tool_calls": "Every receptionist tool call, its arguments, answer and idempotency key.",
        "ai_answer_reports": "Staff reports of a wrong receptionist answer, with the right one.",
        "ai_response_samples": "Calls sampled for quality review and the reviewer's verdict.",
        "ai_eval_cases": "Test cases the receptionist must pass per industry.",
        "vapi_request_receipts": "Vapi requests already accepted, so a replay is refused.",
        "on_call_settings": "After-hours and emergency transfer settings per business.",
        "on_call_shifts": "The on-call rota: who takes transfers, when.",
        "on_call_reminders_sent": "Reminders sent to on-call staff, so each is sent once.",
        "store_lookup_guards": "Limits on order lookups by phone, per call and caller.",
    }),
    ("Knowledge", {
        "knowledge_items": "Approved answers the receptionist may use.",
        "knowledge_versions": "History of each knowledge item.",
        "knowledge_gaps": "Questions the receptionist could not answer, for the owner to fill in.",
    }),
    ("Scheduling", {
        "appointments": "Bookings of every kind (appointments, jobs, visits, reservations, classes).",
        "appointment_reminders": "Reminders and confirmations due for each appointment.",
        "appointment_reschedule_links": "Private reschedule links sent to customers (stored hashed).",
        "blocked_times": "Times a staff member or the business cannot be booked.",
        "resources": "Rooms, chairs, bays and equipment bookings need.",
        "resource_needs": "Which resources each service needs, and how many.",
        "recurring_plans": "Repeat work (every two weeks, monthly) per customer.",
        "recurring_visits": "The visits generated from a recurring plan.",
        "job_dispatch": "Field job progress: en route, on site, finished, checklist.",
        "waitlist_entries": "People waiting for a time to free up.",
        "waitlist_offer_links": "Private links offering a freed time to someone on the waitlist.",
        "calendar_connections": "Connected Google or Outlook calendars (tokens in Vault, not here).",
        "calendar_sync_queue": "Calendar sync work waiting for the calendar worker.",
        "restaurant_tables": "A restaurant's tables and seats.",
        "table_combinations": "Tables that can be joined for larger parties.",
        "table_states": "Each table's live state (free, seated, needs cleaning).",
        "table_blocks": "Times a table cannot be booked.",
        "table_events": "History of table changes.",
    }),
    ("Messages and conversations", {
        "conversations": "A thread with a customer on one channel.",
        "conversation_messages": "Messages in a conversation.",
        "conversation_notes": "Staff notes on a conversation.",
        "message_templates": "Text and email templates (platform defaults and business copies).",
        "message_drafts": "Suggested messages waiting for staff approval.",
        "sms_messages": "Every text prepared, sent, skipped or received, with status.",
        "email_messages": "Every email prepared, sent or skipped, with status.",
        "email_events": "Delivery, bounce and complaint events from the email provider.",
        "email_unsubscribe_tokens": "Private unsubscribe links (stored hashed).",
        "followup_tasks": "Follow-ups due (no-show, thank-you, quote, reactivation, callback fallback).",
        "automation_channel_reviews": "Automations whose channel needs an owner decision before they can run.",
        "meta_connections": "Connected Facebook, Instagram and WhatsApp accounts (tokens in Vault).",
        "meta_contacts": "People met on Meta channels, linked to customers.",
        "meta_events": "Webhook events received from Meta.",
        "meta_outbox": "Meta messages waiting to be sent.",
        "meta_templates": "Approved WhatsApp templates.",
        "social_flows": "Where a social-media conversation is in its question flow.",
        "live_notices": "Short notices the receptionist reads out (closed today, running late).",
    }),
    ("Spam and abuse", {
        "spam_settings": "Per-business spam protection settings.",
        "spam_incidents": "Detected spam calls, texts and form posts, with score and outcome.",
        "spam_incident_events": "History of each spam incident.",
        "spam_list_entries": "Numbers, addresses and words a business blocks or always allows.",
    }),
    ("Automations and background work", {
        "automations": "A business's automations and whether each is on.",
        "automation_runs": "Each run of an automation.",
        "automation_events": "Durable events waiting for, or handled by, the event router.",
        "automation_dead_letters": "Events that failed for good or have no handler yet, kept visible.",
        "workflow_executions": "Record of n8n workflow runs reported back to the database.",
        "n8n_dispatch_state": "How often the dispatcher called each n8n worker, and the stuck-item guard.",
        "integrations": "A business's connected integrations and their status.",
        "integration_secrets": "References to secrets for integrations (values in Vault).",
        "provider_health": "Latest health check per provider.",
    }),
    ("Offers, reviews and growth", {
        "offers": "Platform offers and promotions.",
        "offer_rules": "Who an offer applies to and when.",
        "offer_redemptions": "Offers a business redeemed.",
        "offer_events": "History of offer changes.",
        "offer_job_runs": "Runs of the offer background jobs.",
        "cross_sell_rules": "'You might also need' follow-up suggestions per service.",
        "review_sources": "Where a business's reviews come from (Google).",
        "reviews": "Reviews received and the reply drafts waiting for owner approval.",
    }),
    ("Billing and usage", {
        "plans": "Subscription plans. Empty until the Zella Voice owner creates them.",
        "subscriptions": "A business's subscription and its state.",
        "payments": "Payments reported by the payment provider (no card data).",
        "billing_events": "Payment provider webhook events, applied once and in order.",
        "usage_records": "Append-only usage ledger (one entry per finalised call; adjustments, never edits).",
        "usage_thresholds": "Usage warning levels per business.",
        "usage_threshold_events": "Warnings already raised, so each is raised once.",
        "usage_processing_issues": "Calls whose usage could not be recorded yet, retried until resolved.",
        "voice_pricing": "Provider unit costs used for cost estimates.",
    }),
    ("Notifications, reports and support", {
        "notifications": "In-app notifications for business members.",
        "notification_preferences": "What each person wants to be told about, and how.",
        "staff_notifications": "Notifications for staff who don't sign in (by text or email).",
        "admin_alert_prefs": "Platform admin alert preferences.",
        "platform_alerts": "Platform alerts for Zella Voice staff (grouped, with resolution).",
        "platform_incidents": "Incidents shown on the public status page.",
        "business_report_schedules": "Which reports a business gets and when.",
        "business_report_runs": "Reports produced.",
        "support_tickets": "Support requests from businesses.",
    }),
]

SQL = r"""
with t as (
  select c.oid, c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r','p') and c.relname not like 'backup\_%'
)
select json_build_object(
 'tables', (select json_agg(json_build_object(
    'name', t.relname,
    'rls', (select relrowsecurity from pg_class where oid = t.oid),
    'cols', (select json_agg(json_build_object('n', a.attname, 't', format_type(a.atttypid, a.atttypmod),
                     'nn', a.attnotnull, 'd', pg_get_expr(d.adbin, d.adrelid)) order by a.attnum)
               from pg_attribute a left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
              where a.attrelid = t.oid and a.attnum > 0 and not a.attisdropped),
    'pk', (select string_agg(a.attname, ', ' order by array_position(k.conkey, a.attnum))
             from pg_constraint k join pg_attribute a on a.attrelid = k.conrelid and a.attnum = any(k.conkey)
            where k.conrelid = t.oid and k.contype = 'p'),
    'fks', (select json_agg(json_build_object(
                'cols', (select string_agg(a.attname, ', ') from pg_attribute a where a.attrelid = k.conrelid and a.attnum = any(k.conkey)),
                'ref', (select n2.nspname || '.' || c2.relname from pg_class c2 join pg_namespace n2 on n2.oid = c2.relnamespace where c2.oid = k.confrelid),
                'del', k.confdeltype) order by k.conname)
              from pg_constraint k where k.conrelid = t.oid and k.contype = 'f'),
    'uniq', (select json_agg(pg_get_constraintdef(k.oid) order by k.conname) from pg_constraint k where k.conrelid = t.oid and k.contype = 'u'),
    'pol', (select json_agg(json_build_object('n', p.policyname, 'c', p.cmd, 'r', p.roles) order by p.policyname)
              from pg_policies p where p.schemaname = 'public' and p.tablename = t.relname),
    'trg', (select json_agg(g.tgname order by g.tgname) from pg_trigger g where g.tgrelid = t.oid and not g.tgisinternal)
  ) order by t.relname) from t),
 'views', (select json_agg(viewname order by viewname) from pg_views where schemaname = 'public'),
 'funcs', (select json_agg(json_build_object('n', p.proname, 'a', pg_get_function_identity_arguments(p.oid),
             'r', pg_get_function_result(p.oid), 'sd', p.prosecdef, 'k', p.prokind,
             'anon', has_function_privilege('anon', p.oid, 'execute'),
             'auth', has_function_privilege('authenticated', p.oid, 'execute')) order by p.proname, 2)
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public')
)
"""

DEL = {"a": "no action", "r": "restrict", "c": "cascade", "n": "set null", "d": "set default"}


def esc(s):
    return str(s).replace("|", "\\|").replace("\n", " ")


def short_default(d):
    if d is None:
        return ""
    d = d.replace("::text", "").replace("::jsonb", "").replace("::character varying", "")
    return d if len(d) <= 40 else d[:37] + "..."


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--port", default="5432")
    ap.add_argument("--db", required=True)
    ap.add_argument("--user", default="postgres")
    args = ap.parse_args()
    out = subprocess.run(["psql", "-X", "-h", args.host, "-p", args.port, "-U", args.user, "-d", args.db, "-Atq", "-c", SQL],
                         check=True, capture_output=True, text=True).stdout
    data = json.loads(out)
    tables = {t["name"]: t for t in data["tables"]}
    funcs = data["funcs"]
    w = sys.stdout.write

    described = {name for _, g in GROUPS for name in g}
    missing = sorted(set(tables) - described)
    gone = sorted(described - set(tables))

    w("# Zella Voice backend schema\n\n")
    w("The database is the single source of truth and the single enforcer of rules (`NN-6` in `ZELLA_VOICE_RULES.md`).\n")
    w("This is the reference for what is in it: every table and column, its keys, its row security policies and\n")
    w("triggers, and every function with who may call it. How the parts work together is in `docs/ARCHITECTURE.md`;\n")
    w("which migration is applied to production is in `docs/SCHEMA_STATUS.md`.\n\n")
    w("**Generated, do not edit by hand.** Run `docs/generators/backend_schema.py` against an isolated copy of the\n")
    w("production schema and commit the result with the migration that changed it. Table purposes live in that script.\n")
    w("It reads the catalog only, never rows.\n\n")
    npol = sum(len(t["pol"] or []) for t in tables.values())
    nrls = sum(1 for t in tables.values() if t["rls"])
    secdef = sum(1 for f in funcs if f["sd"])
    anon = sum(1 for f in funcs if f["anon"])
    w("## At a glance\n\n")
    w("| What | Count |\n|---|---|\n")
    w(f"| Tables (schema `public`) | {len(tables)} |\n")
    w(f"| Tables with row security on | {nrls} of {len(tables)} |\n")
    w(f"| Row security policies | {npol} |\n")
    w(f"| Columns | {sum(len(t['cols']) for t in tables.values())} |\n")
    w(f"| Views | {len(data['views'] or [])} |\n")
    w(f"| Functions | {len(funcs)} ({secdef} security definer, {anon} callable by `anon`) |\n\n")
    w("Rules every table follows:\n\n")
    w("- Business data carries `business_id`; row security and every function check the caller's membership and role\n")
    w("  in that business. Hiding something in the app is never the protection.\n")
    w("- Row security is on for every table. A new table without it is a defect.\n")
    w("- Secrets (provider tokens, keys) are never in these tables: they live in Supabase Vault and edge function\n")
    w("  secrets. Tables keep only a reference or a hash.\n")
    w("- History tables (`audit_logs`, `contact_consents`, `usage_records`, `*_events`) are append-only.\n")
    w("- Nothing is dropped or recreated. Changes are new, version-guarded migrations with a rollback in `sql/rollback/`.\n\n")
    w("Other schemas Zella Voice uses: `auth` (Supabase sign-in users), `storage` (files), `vault` (secrets),\n")
    w("`cron` (timed jobs), `net` (outbound calls from the database to n8n).\n\n")
    w("### Storage buckets\n\n| Bucket | Public | Holds |\n|---|---|---|\n")
    w("| `brand-assets` | yes | Zella Voice and business logos and backgrounds (no private data) |\n")
    w("| `business-documents` | no | Business and owner verification documents |\n")
    w("| `record-files` | no | Files attached to industry records, checked after upload |\n\n")
    w("### Timed jobs (`cron.job`)\n\n")
    w("Each is a database job; most stay off until the owner approves going live (see `docs/MEMORY.md`).\n\n")
    w("| Job | Schedule (UTC) | Does |\n|---|---|---|\n")
    for j in [
        ("zella_dispatch", "every minute", "Wakes n8n workers only when work is due (`zella_dispatch_n8n`)"),
        ("zella_jobs_every5", "every 5 min", "Overdue leads, expire held slots and waitlist offers, transfer failures"),
        ("zella_jobs_every15", "every 15 min", "Quote follow-ups"),
        ("zella_jobs_hourly", "hourly", "Daily summaries at each business's local 8am"),
        ("zella_jobs_daily", "04:00", "Lead reactivation, setup incomplete, trials, payment policy"),
        ("zella_jobs_weekly", "Mon 08:00", "Weekly reviews"),
        ("zella_cron_cleanup", "03:30", "Clears old job history"),
        ("zella_usage_thresholds", "hourly at :23", "Usage warnings"),
        ("zella_spam_hourly", "hourly at :17", "Spam follow-up work"),
        ("zella_billing_reconcile", "every 15 min", "Applies billing events that arrived out of order"),
    ]:
        w(f"| `{j[0]}` | {j[1]} | {j[2]} |\n")
    w("\n## Contents\n\n")
    for title, g in GROUPS:
        anchor = title.lower().replace(",", "").replace(" ", "-")
        w(f"- [{title}](#{anchor}): {', '.join(f'`{n}`' for n in g if n in tables)}\n")
    if missing:
        w(f"- [Not yet described](#not-yet-described): {', '.join(f'`{n}`' for n in missing)}\n")
    w("- [Functions](#functions)\n\n")

    def table(name, purpose):
        t = tables[name]
        w(f"### `{name}`\n\n{purpose}\n\n")
        w("| Column | Type | Required | Default |\n|---|---|---|---|\n")
        for c in t["cols"]:
            w(f"| `{c['n']}` | {esc(c['t'])} | {'yes' if c['nn'] else ''} | {esc(short_default(c['d']))} |\n")
        w("\n")
        bits = []
        if t["pk"]:
            bits.append(f"Primary key: `{t['pk']}`.")
        for u in t["uniq"] or []:
            bits.append(f"Unique: `{esc(u.replace('UNIQUE ', ''))}`.")
        for f in t["fks"] or []:
            bits.append(f"`{f['cols']}` → `{f['ref']}` (on delete {DEL.get(f['del'], f['del'])}).")
        pols = t["pol"] or []
        rls = "on" if t["rls"] else "**off**"
        if pols:
            names = ", ".join("{} ({})".format(esc(p["n"]), p["c"].lower()) for p in pols)
            bits.append("Row security: {}; policies: {}.".format(rls, names))
        elif t["rls"]:
            bits.append("Row security: on; no policies, so roles subject to row security (signed-in users and anon) "
                        "get no rows directly. Roles that bypass it (table owners, superusers, `BYPASSRLS` roles such "
                        "as the server key) are not limited by it; security definer functions run as the owner.")
        else:
            bits.append("Row security: **off**; no policies. Access depends on table grants alone: a defect.")
        if t["trg"]:
            bits.append(f"Triggers: {', '.join(f'`{x}`' for x in t['trg'])}.")
        w("\n".join(f"- {b}" for b in bits) + "\n\n")

    for title, g in GROUPS:
        w(f"## {title}\n\n")
        for name, purpose in g.items():
            if name in tables:
                table(name, purpose)
    if missing:
        w("## Not yet described\n\nAdd a purpose for each in `docs/generators/backend_schema.py`.\n\n")
        for name in missing:
            table(name, "No description yet.")
    if gone:
        sys.stderr.write("described but not in the database: " + ", ".join(gone) + "\n")

    w("## Functions\n\n")
    w("Most rules live here. `SD` = security definer (runs with the owner's rights, so it must check the caller\n")
    w("itself and has a fixed `search_path`). `anon` = callable without signing in (public links and webhooks only).\n")
    w("`signed in` = callable by any signed-in person; the function then checks their business and role.\n")
    w("Functions callable by neither are for the server key, triggers and jobs only.\n\n")
    prefixes = {}
    for f in funcs:
        n = f["n"]
        key = n.split("_")[1] if n.startswith("zella_") and "_" in n[6:] else ("zella" if n.startswith("zella_") else "other")
        prefixes.setdefault(key, []).append(f)
    # small groups go together so the list stays readable
    big = {k: v for k, v in prefixes.items() if len(v) >= 3}
    small = [f for k, v in prefixes.items() if len(v) < 3 for f in v]
    order = sorted(big)
    for k in order + (["(other)"] if small else []):
        fs = big.get(k, small) if k != "(other)" else sorted(small, key=lambda f: f["n"])
        label = {"zella": "`zella_<word>` (one-word names)", "(other)": "Smaller groups and older helpers"}.get(k, f"`zella_{k}_*`")
        w(f"### {label} ({len(fs)})\n\n")
        w("| Function | Returns | SD | Who may call |\n|---|---|---|---|\n")
        for f in fs:
            callers = [name for name, ok in (("anon", f["anon"]), ("signed in", f["auth"])) if ok]
            who = ", ".join(callers) if callers else "server only"
            kind = " (procedure)" if f["k"] == "p" else ""
            w(f"| `{f['n']}({esc(f['a'])})`{kind} | {esc(f['r'] or '')} | {'yes' if f['sd'] else ''} | {who} |\n")
        w("\n")


if __name__ == "__main__":
    main()
