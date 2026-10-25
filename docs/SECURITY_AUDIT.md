# Security and one-business-data audit (2026-10-25)

## What was tested (live database)
- Every table in `public` has row-level security on. Only `industries` and `plans` (public catalogues of active rows) are readable without signing in.
- **Isolation test, rolled back afterwards:** a throwaway user with their own new business tried to read the real business through all 81 tables that carry a business id, `businesses`, `business_members` and `profiles`, and through 26 read functions. Result: 0 rows leaked. The user saw 1 business, 1 profile, 1 membership and only their own 29 rows. 25 of the 26 functions refused; the 26th (`zella_business_open`, opening hours) is now closed.
- Write protection was checked by reading the rules instead of running attacks on live data: every insert/update/delete rule is limited to active members of the same business (owner/admin/manager for settings, automations, integrations, tickets). `businesses` and `business_members` have no write access at all from the app; changes go through checked functions.
- All 147 functions that signed-in users can call were checked: all but three contain their own membership or role check. The three: `zella_inbox_mark_read` (uses a checked helper), and the two unsubscribe functions (public by design, they need the secret token in the link).
- Secrets: the database exposes only safe columns of `integrations` and `calendar_connections` to signed-in users; no keys or tokens are in the repo; edge functions check their own proof (billing signature, form key, admin check).

## Fixed
- 14 internal trigger functions were callable from the public API: closed (`sql/zella_security_sweep.sql`). New functions are closed to anonymous callers by default.
- `zella_business_open` closed to everyone but the database itself.
- 4 helper functions now have a fixed search path.
- 46 foreign keys had no index: added. 26 row rules re-ran `auth.uid()` per row: now once per query (`sql/zella_performance_sweep.sql`).
- **Bug:** Inbox internal notes never loaded because signed-in users had no read right on `conversation_notes`: fixed (`sql/zella_gap_fixes.sql`).
- Added a root `.gitignore` so a `.env` file can never be committed.

## Left, with reasons
- **Leaked-password protection is off.** It is a dashboard switch (Authentication > Providers > Email > "Prevent use of leaked passwords", Pro plan). Turn it on before go-live.
- 20 tables have row-level security and no rules on purpose (server-only: secrets, queues, platform settings). The app cannot read them, which is the point.
- 12 other tables have member read rules but no SELECT right (`business_hours`, `business_closures`, `call_insights`, `call_messages`, `meta_connections`, `website_forms`, `staff_handovers`, `sensitive_approvals`, `ai_tool_calls`, `ai_eval_cases`, `lead_submissions`, `meta_templates`). The app reads them through checked functions, not directly, so nothing is broken; grant a table only if a screen needs it.
- Two leftover test edge functions (`smart-action`, `zella-admin-check-v2`) only say whether you are a platform admin. They are harmless; delete them when convenient.
- Not tested end to end: a real second user through the real sign-in screen, and write attacks against live data (the test runner cancels those).
