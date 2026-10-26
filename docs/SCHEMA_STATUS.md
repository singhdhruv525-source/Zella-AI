# Database: what the repo can and can't rebuild

Checked on 2026-10-26 against the 98 files in `sql/`. The live Supabase project was not connected
during this check, so anything below marked "live only" could not be verified.

## The database can't be rebuilt from this repo yet

The `sql/` files add to a base schema that was created directly in Supabase and never saved here.
These 27 tables are used by the SQL files, the edge functions or the web app, but nothing in the
repo creates them:

`ai_agent_configs`, `ai_agents`, `appointments`, `audit_logs`, `automation_runs`, `automations`,
`business_invitations`, `business_members`, `business_modules`, `businesses`, `calls`,
`conversation_messages`, `conversations`, `customers`, `email_messages`, `industries`,
`industry_configurations`, `industry_modules`, `integrations`, `notification_preferences`,
`payments`, `plans`, `platform_admins`, `profiles`, `sms_messages`, `subscriptions`, `support_tickets`

Missing functions: `is_platform_admin()` and `is_business_member()`. `zella_brain_prompt_base`,
`zella_claim_followup_emails_base` and `zella_claim_followup_texts_base` are made by renaming
inside later files. They aren't missing, but they only exist once those files have run in order.

The row security policies on these tables are also live only. That includes `customers`,
`appointments`, `calls`, `conversations` and `business_members`, which the business app reads and
writes directly. Nothing in the repo shows whether those policies are correct.

### How to recover it (schema only, no customer data)

Run this on a computer with the Supabase CLI. It writes table, view, function and policy
definitions only, never rows:

```
npx supabase login
npx supabase db dump --project-ref pffqxlumqhjdbzvvoszm --schema public -f sql/000_base_schema.sql
```

Read the file before committing it. It should hold no data and no secrets. Then open a new
Supabase project, run `000_base_schema.sql` and the rest in order, and run the checks below before
calling the database reproducible.

### Checks to run on the live project (read-only)

```sql
-- 1. Tables with business data and no row security, open policies, anonymous access. All three should be [].
select public.zella_tenant_leak_check();

-- 2. Policies on the tables the browser writes to directly.
select tablename, policyname, cmd, roles, qual, with_check from pg_policies
 where schemaname = 'public' and tablename in ('customers', 'appointments', 'calls', 'conversations', 'business_members',
   'knowledge_items', 'blocked_times', 'staff_members') order by 1, 3;

-- 3. What signed-in users may do to calls (after the lock step, only SELECT on unprotected columns).
select privilege_type, count(*) from information_schema.column_privileges
 where table_schema = 'public' and table_name = 'calls' and grantee = 'authenticated' group by 1;
```

Every insert from the browser into `customers`, `appointments`, `knowledge_items`, `blocked_times`
and `staff_members` sends a `business_id`. The policies must check it with a `with check` that
matches the person's active membership. Query 2 shows whether they do.

## `zella_run_all.sql`

`zella_run_all.sql` is an older bundle. Its 96 functions and 19 tables match copies in the
separate files (mostly `zella_workflows.sql` and `zella_industry_crm.sql`). Later files have since
replaced or patched four of those functions:

| Function | Changed later by |
| --- | --- |
| `zella_claim_reminders` | `zella_email_sender.sql`, `zella_followup_emails.sql`, `zella_reschedule.sql` |
| `zella_replace_reminders` | `zella_reminder_rules.sql`, `zella_reschedule.sql` |
| `zella_queue_lead_reactivation` | `zella_messaging_extras.sql` (patched in place) |
| `zella_resolve_duplicate` | `zella_customer_records.sql` (patched in place) |

**Don't re-run `zella_run_all.sql` on the live database.** It would put the old versions of these
four functions back. On a fresh database, run it first and then the later files, in the order in
the "Needs" line at the top of `sql/zella_dispatcher.sql`.

Branch note: `zella_reminder_minutes.sql` and `zella_reminder_rules.sql` are on `main` but not on
`n8n-engine`.

## New in this change (2026-10-26)

None of these have been run on the live project. Run them in this order; each one is safe to re-run.

| File | What it does | Changes tables? |
| --- | --- | --- |
| `zella_role_check_hardening.sql` | Anonymous requests no longer pass `zella_has_role` | No |
| `zella_call_writes.sql` | `zella_call_mark_followed_up`, `zella_call_set_escalation`. Section 2 (the lock) stays commented out | No |
| `zella_staff_invite_binding.sql` | A team invitation can only be accepted by the account it was sent to | No |
| `zella_business_settings.sql` | Business Settings: profile, hours, holidays, my profile | No |
| `zella_receptionist_editor.sql` | Managers can read the receptionist's live settings to edit them | No |

Each file lists its dependencies, what it means for access, how to undo it, and a rolled-back
check. All five were run against a local PostgreSQL 16 with stand-ins for the Supabase roles and
`auth.uid()`. The checks there: the right member is allowed; another business's owner, staff below
the required role, and anonymous callers are refused; bad input is rejected; a second run changes
nothing.
