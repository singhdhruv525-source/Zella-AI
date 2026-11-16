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

1. Start an isolated Postgres 16, then restore it with the security migrations:

   ```bash
   sql/baseline/restore.sh zella_ui sql/zella_invitation_hardening.sql sql/zella_billing_hardening.sql \
     sql/zella_mfa_enforcement.sql sql/zella_platform_roles_fix.sql sql/zella_platform_alerts_policy_fix.sql \
     sql/zella_admin_mfa.sql
   ```

2. Load the test data:
   - **Reference data:** industries, industry modules, presets, Zella's own message templates and offer rules. These are configuration rows, not customer data. Copy them read-only from the project, or load them from `sql/zella_industries_seed.sql` and the preset files.
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
| `owner-onboarding-journey.cjs` | The owner onboarding journey (`/welcome/setup`), every screen from Welcome to You're all set, against the stand in api (`web/src/onboarding/fakeApi.js`, built in only with `VITE_ONBOARDING_FAKE=1`), which follows `docs/OWNER_ONBOARDING_CONTRACT.md`: focus on each step's heading, the progress bar, Finish later and resuming, Looks right and Change, the identity states, the plan, the payment waiting screen, not ready and failed loads. Screenshots at 390 wide and 1440x900, Classic and Glass. Needs no database; the header of the script has the build and serve commands. |
| `brand-check.cjs` | Sidebar logo and default theme: expanded, collapsed, frames during the transition, tablet rail, phone drawer, reduced motion, accessible name, saved looks kept. |
| `probe.cjs <email> <route> "<js>"` | Opens one page and prints a browser expression (for debugging). |

The stand-in covers the query shapes this app uses. It is not a full PostgREST or GoTrue: auth is simplified to test users with one password, storage is kept in memory, and embedded-resource filters are not supported.
