Audited support access: opens recorded, contacts masked, reveal with a reason (edge; needs owner approval before deploy)
base: claude/lane-e-automations-live

**Needs owner approval before deploy.** Opening a business starts writing audit rows, and the masking changes what
support staff see.

## What and why
**BIZ-22 part b.** Opening a business showed people's contact details with no record of who looked.
- **Opens are recorded:** `business_detail` writes one `business.viewed` row per admin and business in
  `VIEW_DEDUPE_MINUTES` (30). A failed write never blocks the page; it raises the `audit_write_failed` alert.
- **Kept out of Activity:** the Activity list and its count leave out `business.viewed` and
  `support.contacts_revealed`; they come back as `supportAccess` (20 newest, with who) for audit.view holders. On
  /audit-logs they are ordinary rows with their own action, so its existing action filter separates them (labels are
  in the shared catalog). Tell lane A (ACC-08, ACC-12).
- **Masked by default:** members' and invitees' emails and invitation errors are masked now too (caller numbers and
  connection accounts already were), and the response says `contactsMasked: true`.
- **Reveal:** `business_contacts_reveal` (permission `REVEAL_PERMISSION` = businesses.manage) needs a reason of 10 to
  300 characters. It writes `support.contacts_revealed` with the reason, the field names and counts (no values)
  **first**; if that write fails nothing is revealed (503, fails closed). Then it returns, for that response only,
  member and invitee emails, the 10 latest calls' numbers and connection accounts. No second audit row from the
  dispatcher.

The web half (reason dialog in DialogFocus, values shown for that response only, Support access list) is in the
Business page web PRs.

## Known gap (not fixed here)
`setup_load` (the wizard's read, businesses.view) still returns the owner's email unmasked; it belongs to the setup
wizard (lane B). Recorded in ARCHITECTURE.md under REQ-LC-19.

## Defaults taken (owner can change)
- Every open audited, `VIEW_DEDUPE_MINUTES = 30`, view rows excluded from Activity and listed under Support access.
- `REVEAL_PERMISSION = "businesses.manage"`; a typed reason (`REVEAL_REASON = {min: 10, max: 300}`), no ticket link.
- Contact data = member and invitee emails, invitation errors, caller numbers, connection accounts.
- A failed reveal audit blocks the reveal (fail closed).

## Deploy order
Edge function on its own (needs approval), then the web half. The old web app shows the masked strings in the same
fields. No SQL. Rollback: redeploy `owner-provision-business` from the main commit before this PR's merge commit.

## Tests
- Automated local: `deno test` 71 passed, 0 failed. New `support_access_test.ts`: the defaults; an open writes one
  `business.viewed` row and a second inside the window writes none; Activity's query excludes view rows; emails
  masked in members, invitations and the owner invitation (and its error); a short and a long reason refused; one
  audit row with the reason and field names and no email or number, then the values; a failed audit write gives 503
  with nothing revealed; an unknown business 404. `deno check index.ts` passes. `npm run lint` catalog drift: 216
  audit actions match (two added).
- Local end to end (isolated `zle_ui`): `ops@zella.test` opens the page twice: 1 view row, Activity has none, Support
  access lists it, emails read `o…@lanee.test`. Reveal with "short" 400; with a real reason returns both emails and
  10 calls and writes one row `{reason, fields, counts}`; `readonly@zella.test` 403; anonymous 401; unknown business
  404.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
