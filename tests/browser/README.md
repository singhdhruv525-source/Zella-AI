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

5. Install axe-core for the accessibility scan (pinned in `tests/browser/package.json`, installed into
   `tests/browser/node_modules`, never deployed):

   ```bash
   npm ci --prefix tests/browser
   ```

   `glitch-sweep.cjs` and `page-review.cjs` stop with "axe-core is not installed" when it is missing, instead of
   reporting no accessibility problems. `glitch-sweep.cjs --no-axe` skips the scan on purpose (each page then says
   `axe: "skipped"`); a page where the scan couldn't run shows `axe-failed`. `AXE=/path/to/axe.min.js` uses another copy.

   Rerun the crawl after a UI change, on desktop, phone and dark:

   ```bash
   node tests/browser/glitch-sweep.cjs admin
   node tests/browser/glitch-sweep.cjs admin --mobile
   node tests/browser/glitch-sweep.cjs admin --dark
   ```

## Run

| Script | What it checks |
|---|---|
| `page-review.cjs <persona> [--mobile] [--glass]` | Signs in through the real sign-in page and opens every route from the app's own registries. Records crashes, error screens, failed calls, axe-core results (WCAG 2.1 AA), sideways overflow, icon words and a screenshot. Personas: admin, readonly, owner, staff, viewer, public. Set `BUSINESS=<id>` to choose the owner's business. |
| `wizard-journey.cjs` | The setup wizard: no skipping, unsaved changes (Save / Discard / Stay, focus trap), leaving and reloading, double-click, checkmarks from saved data, server-side finish checks, owner versus staff invitation. |
| `ui-journeys.cjs` | Template and customer-search scoping across two businesses, appearance save failure and retry, a reload during a pending save, the icon font blocked, automations with live-shaped data. |
| `admin-mfa-journey.cjs` | Two step sign in for every admin: an admin without an authenticator gets only their own role from the server and nothing from the database, is walked through setting one up (wrong code refused), lands on the dashboard; the only authenticator can't be removed; the next sign in asks for the code. Needs `sql/zella_admin_mfa.sql` in the test database. |
| `incident-updates.cjs` | OPS-12 and OPS-11: open in a dialog, the similar open incident warning, internal updates and Tell affected businesses, edit, an empty public status text, resolve, Load more, and no browser prompts. Needs `sql/zella_admin_permissions.sql` and `sql/zella_incident_updates.sql`. |
| `admin-sessions.cjs` | ACC-18 and ACC-30: a role change warns and then signs the admin out on every device (count shown, audited); Sign out other devices goes through the database and is audited. Needs `sql/zella_admin_sessions.sql`. |
| `admin-fresh-code.cjs` | ACC-19: adding an admin is refused without a code from the last 5 minutes, the page asks for one (a wrong code is refused), then the same change goes through; a second change within 5 minutes isn't asked again. The stand in records the code time in amr on verify. |
| `admin-self-service.cjs` | ACC-30: anonymous, a business member and an admin without a fresh code are refused; the last authenticator can't be removed on the server; removing one of two, adding one and changing the password work from Account security and are audited, and the password never reaches the audit log. |
| `admin-refusals.cjs` | ACC-15: refusals (not an admin, two step sign in not set up, a role without the permission) are recorded with ip and user agent, a flood is capped at 5 per person and reason, an unsigned call and an allowed call record nothing, and Users & access lists them in words. |
| `admin-audit-log.cjs` | ACC-12: 68 entries, 65 at the same instant, page through once each; person, date and record filters; a malformed filter or page marker is refused; export is refused for a read only admin, a member and anonymous, works for the owner with formula cells defused, is audited with its filters, and downloads from the page. |
| `support-replies.cjs` | OPS-25: a business owner sends an urgent request (alert raised), support replies and adds a note, the owner reads the reply but never the note and answers, staff read without an answer box and are refused by the database. Needs `sql/zella_support_notes.sql` and `sql/zella_support_replies.sql`. |
| `owner-onboarding-journey.cjs` | The owner onboarding journey (`/welcome/setup`), every screen from Welcome to You're all set, against the stand in api (`web/src/onboarding/fakeApi.js`, built in only with `VITE_ONBOARDING_FAKE=1`), which follows `docs/OWNER_ONBOARDING_CONTRACT.md`: focus on each step's heading, the progress bar, Finish later and resuming, Looks right and Change, the identity states, the plan, the payment waiting screen, not ready and failed loads. Screenshots at 390 wide and 1440x900, Classic and Glass. Needs no database; the header of the script has the build and serve commands. |
| `brand-check.cjs` | Sidebar logo and default theme: expanded, collapsed, frames during the transition, tablet rail, phone drawer, reduced motion, accessible name, saved looks kept. |
| `probe.cjs <email> <route> "<js>"` | Opens one page and prints a browser expression (for debugging). |

The stand-in covers the query shapes this app uses. It is not a full PostgREST or GoTrue: auth is simplified to test users with one password, storage is kept in memory, and embedded-resource filters are not supported.
