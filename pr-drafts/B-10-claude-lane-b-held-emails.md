Emails to businesses: read, release or discard a held email, and a business filter (COM-18, COM-22)
base: main

## What and why

**COM-18.** `zella_claim_platform_emails` (sql/zella_email_delivery.sql, applied) holds an email after its fifth try and raises `platform_email_held` ("Check it before sending it again"), but nothing could read it, send it again or drop it. The admin list leaves the bodies out, so there was nothing to check.

New migration `sql/zella_platform_email_actions.sql` adds three functions. It replaces nothing.
- `zella_admin_platform_email_detail(p_id)`: one email with its subject, HTML and text. Needs businesses.view. Each view is audited (`comms.platform_email_viewed`), like other message content views. It also returns `can_manage`.
- `zella_admin_platform_email_release(p_id, p_reason)`: puts a **held** email back to queued, with attempts at 0, no claim and due now. Needs comms.manage and a reason (`zella_admin_reason`), is audited (`comms.platform_email_released`) and resolves the matching `platform_email_held` alert by its dedupe key.
- `zella_admin_platform_email_discard(p_id, p_reason)`: ends a **held** email as `failed`. That status was already allowed by the CHECK and nothing else writes it. No claim takes it again. Same permission, reason, audit (`comms.platform_email_discarded`) and alert resolution.

This follows the applied design, as the critic asked. The claim and finish functions are untouched (the test checks their fingerprints). An email is still held after its fifth try, and the sender never writes a new "failed" path. Release and discard refuse any email that isn't held (`NOT_HELD`).

**COM-22.** `web/src/admin/BusinessEmails.jsx`:
- The Outbox gets a Business filter, sent as `p_business`.
- A row now opens an email drawer instead of leaving the page. The drawer shows the facts, the real email in a sandboxed iframe or as plain text, "Open business", and Release and Discard for a held email when `can_manage` is true. Each action asks for a reason through the existing ReasonDialog.
- The status option "Failed" (always empty) is now "Discarded".

Not changed: MessagingPage.jsx and adminOps.jsx (both on the open polish PR #88). BusinessEmails loads its own business list with `useOptions()`.

## Defaults taken (owner can change)
- A discarded email ends as `failed` and is shown as **Discarded** (no new status, no table change).
- Viewing an email body is audited for every viewer.
- Release keeps the last error text as history. Only status, attempts and the claim are reset.

## Deploy order (each step needs the owner's approval)
1. SQL: `sql/zella_platform_email_actions.sql`. It is additive and nothing calls it yet.
2. Web app.

No edge function changes. A released email goes nowhere until email_live, the sender address and RESEND_API_KEY are set. While email_live is off, the next claim marks it test mode, as for every queued email.

## Tests
- **Automated local, isolated DB** (`tests/platform_email_actions/run.sh`, template zprod3 and also zprod3 plus every merged, not applied migration): 26 checks, all passing. They cover:
  - before the migration, release doesn't exist (the gap);
  - apply, and apply again;
  - the detail returns bodies for businesses.view and is audited;
  - release resets the email to queued with attempts at 0, closes the alert and is audited with the reason;
  - with email_live off, the released email goes to dry_run and nothing is handed out;
  - discard is terminal and is never claimed, even with email_live on;
  - a role without comms.manage, a support admin, a business owner and anonymous are all refused, a reason is required, a non held email is refused, and an unknown id is NOT_FOUND;
  - claim and finish are unchanged;
  - rollback twice, reapply, and VERSION_MISMATCH and ROLLBACK_DRIFT on drift.
- **Lint and build:** `npm run lint` (0 dashes), `npx vite build`.
- **Local browser** (real web app against the local stand in and an isolated DB, 1440x900 and 390x844, deviceScaleFactor 1): all 22 checks pass, with no page errors. They cover:
  - the business filter sends `p_business` and narrows the list;
  - the status options show Discarded and no Failed;
  - a row opens the drawer, which keeps you on the page and shows the real HTML in a `sandbox=""` iframe;
  - Release asks for a reason, puts the email back to queued, is audited and shows Waiting in the list;
  - Discard ends it, and the list shows Discarded;
  - no sideways scroll at 390.
  Screenshots: `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-b/shots/b10-drawer-1440.png`, `b10-drawer-390.png`, `b10-release-1440.png`, `b10-after-release-1440.png` (same folder).

## Migration fingerprints
New functions (this file's versions): detail `94b421aa140fc4c0642d6366b02b3c5d`, release `c0fe74e7fde7d1f56e97991dc7022b74`, discard `7dd8e3e18e0f6c032a229a7c55dc3fb9`. No production function is replaced. Production md5s to be confirmed by the supervisor before apply.

Rollback: `sql/rollback/zella_platform_email_actions_rollback.sql` drops the three functions and refuses on drift. Released and discarded emails keep their status, and their audit rows stay.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
