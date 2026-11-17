# Browser tests

Two kinds:

- `security-journeys.cjs`: an earlier check that runs against a stubbed backend (canned answers).
- Everything else here runs against a **real local backend**:
  - an isolated Postgres restored from `sql/baseline` (the live schema, no data);
  - test-only people and businesses;
  - a small local stand-in for Supabase's HTTP APIs (`local-backend.mjs`);
  - the real edge-function code running under Deno.

  Row security, grants, RPCs and `owner-provision-business` are therefore the real ones. Nothing is sent: no email, no text, no call.

Never point any of this at production.

## Set up (once per machine)

1. Start an isolated Postgres 16 and build the crawl database. `crawl-db.sh` copies an isolated copy of the
   production schema (`TEMPLATE`, default `zprod3`; `zfull` from `tests/lib/build_full.sh` also works) and loads the
   reference configuration into it:

   ```bash
   tests/browser/crawl-db.sh zella_ui
   # industries=28 modules=280 platform_templates=56 configurations=28 automation_defaults=191 live_switches_on=0
   ```

2. Load the test data:
   - **Reference data** (loaded by step 1): `tests/fixtures/reference_config.sql`, production CONFIGURATION copied
     read only (UI-35): industries, industry modules, industry configurations, automation defaults, Zella Voice's own
     message templates (platform templates only, never a business's) and platform settings. No customer data, no
     links, no sender addresses or numbers, no voice provider ids, no model ids; every `*_live` switch and
     `n8n_dispatch_enabled` is off. Load it into any other test database with `tests/fixtures/load_reference.sh <db>`
     (isolated server only; it refuses anything else). To refresh it from production, see the header of
     `tests/fixtures/export_reference.mjs`; `tests/fixtures/run.sh` checks the result.
   - **Test people:** `admin@zella.test` (zella_owner), `readonly@zella.test` (read_only_admin), `owner@glow.test` (owner of two businesses), `staff@glow.test`, `viewer@glow.test`. Every test password is `Test-pass-1`. These accounts exist only in the isolated database.

3. Start the backend and the functions:

   ```bash
   ZFUNCTIONS='{"owner-provision-business":54401,"staff-invite":54402,"continue-plan":54403,"reschedule-appointment":54404,"website-lead":54405}' \
     node tests/browser/local-backend.mjs
   ```

   Run each function with:

   ```bash
   SUPABASE_URL=http://localhost:54321 SUPABASE_ANON_KEY=sb_publishable_local_test_only \
     ZELLA_SERVER_SECRET_KEY=sb_secret_local_test_only ZELLA_APP_URL=http://localhost:5199 \
     deno run -A --no-lock --config web/supabase/functions/<name>/deno.json tests/browser/run-function.ts <name> <port>
   ```

   Every admin needs two step sign in (ACC-01). For page crawls, give the test admins a verified authenticator
   (`insert into auth.mfa_factors (id, user_id, factor_type, status) select gen_random_uuid(), id, 'totp', 'verified'
   from auth.users where email like '%@zella.test'`) and start the stand in with `ZTEST_PASSWORD_AAL2=1`, so a password
   sign in counts as verified. `admin-mfa-journey.cjs` checks the real set up and code screens and runs without it (the
   stand in's only working code is 123456).

4. Build and serve the app. The app only accepts `https://<project>.supabase.co`, so the tests reroute that address to the stand-in:

   ```bash
   cd web
   VITE_SUPABASE_URL=https://zlocal.supabase.co VITE_SUPABASE_PUBLISHABLE_KEY=sb_publishable_local_test_only npx vite build --outDir /tmp/zella-local
   npx vite preview --outDir /tmp/zella-local --port 5199
   ```

## Run

| Script | What it checks |
|---|---|
| `page-review.cjs <persona> [--mobile] [--glass]` | Signs in through the real sign-in page and opens every route from the app's own registries. Records crashes, error screens, failed calls, axe-core results (WCAG 2.1 AA), sideways overflow, icon words and a screenshot. Personas: admin, readonly, owner, staff, viewer, public. Set `BUSINESS=<id>` to choose the owner's business. |
| `wizard-journey.cjs` | The setup wizard: no skipping, unsaved changes (Save / Discard / Stay, focus trap), leaving and reloading, double-click, checkmarks from saved data, server-side finish checks, owner versus staff invitation. |
| `ui-journeys.cjs` | Template and customer-search scoping across two businesses, appearance save failure and retry, a reload during a pending save, the icon font blocked, automations with live-shaped data. |
| `admin-mfa-journey.cjs` | Two step sign in for every admin: an admin without an authenticator gets only their own role from the server and nothing from the database, is walked through setting one up (wrong code refused), lands on the dashboard; the only authenticator can't be removed; the next sign in asks for the code. Needs `sql/zella_admin_mfa.sql` in the test database. |
| `brand-check.cjs` | Sidebar logo and default theme: expanded, collapsed, frames during the transition, tablet rail, phone drawer, reduced motion, accessible name, saved looks kept. |
| `weekly-report.cjs` | Settings, Reporting configuration: the owner sees the weekly platform report's schedule, every figure with its definition and earlier weeks at 1440 x 900 and 390 px with no sideways scrolling; a read only admin without `reports.view` sees the refusal. Needs `sql/zella_weekly_platform_report.sql` and a few reports in the test database. Screenshots go to `SHOTS`. |
| `probe.cjs <email> <route> "<js>"` | Opens one page and prints a browser expression (for debugging). |

The stand-in covers the query shapes this app uses. It is not a full PostgREST or GoTrue: auth is simplified to test users with one password, storage is kept in memory, and embedded-resource filters are not supported.
