Business page server: activity only with audit.view, caller numbers masked, invitation roles
base: claude/lane-e-audit-labels

## What and why

**BIZ-04 (server).** `business_detail` needed only `businesses.view` but always returned the business's audit
history and the email of every admin who acted on it. Now:
- `adminPermissions(admin, role)` in the new module `owner-provision-business/detail.ts` gives the signed in admin's
  whole permission set. It follows the dispatcher's own rule (owner everything; super admin all but admins and roles;
  restricted roles their grants in `platform_role_permissions`; anything else nothing; a failed lookup grants
  nothing). A table test checks it against the dispatcher's rule for every key of `PERMISSIONS` and every role, and
  against `me_admin`'s answer.
- Without `audit.view`, `audit_logs` is not read at all and no actor is looked up: `activity: []`,
  `activityAllowed: false` (never null, so the old web app still renders). The response also carries
  `permissions: [...]` for the web app (PR 5).

**BIZ-22 part a (masked by default).** `calls.from_number` and `to_number`, and `integrations.account_email` and
`error_message` (critic: these were missed), are masked with `mask.ts`. `profiles.phone` is no longer selected.

**BIZ-21 part a.** The invitations select includes `role`, with the owner's invitation first, so staff invitations
stop showing as Owner.

`businessDetail` moved from `index.ts` into `detail.ts` unchanged apart from the above, so it can be unit tested
(index.ts starts the server on import). index.ts gains one import and one `?? DETAIL_PERMISSIONS[action]` in the
permission lookup, as `platform.ts` does (supervisor rule 1).

## Critic corrections applied
- **Mask rules differ** (platform.ts `Unknown` and last 4 characters vs `zella_admin_mask` null and last 4 digits).
  Picked the database rule for this page, so the Voice page (masked in SQL) and the business page agree. `mask_test.ts`
  checks `mask()` against fixtures produced by `zella_admin_mask` itself on the isolated database. The Spam page keeps
  its own rule in `platform.ts`, untouched, so its tests and screens don't change in this PR.
- **The dispatcher check is not refactored.** The plan had the dispatcher call the new helper; that block belongs to
  lane A and supervisor rule 1 forbids moving it. Instead the helper restates the rule and the table test proves both
  agree for every action and role.

## Hidden decision to say in the window A approval request (critic)
Caller numbers are masked from this deploy on, before any reveal path exists (PR 14 adds the audited reveal). Support
staff who need a full number meanwhile use the Voice page's call drawer, which is masked the same way.

## Shared with the Businesses list job
`adminPermissions(admin, role): Promise<Set<string>>` is exported from `detail.ts`. The list job can reuse it rather
than writing a second one.

## Defaults taken (owner can change)
- `audit.view` gates the Activity list and actor emails (BIZ-04 recommended).
- Masked by default (BIZ-22 part a): calls' from and to numbers, connection account email, connection error text
  (each email and each run of 7 or more digits inside it).

## Deploy order
Edge function only (window A, needs approval). Additive for the old web app: activity is [] rather than null for
roles without audit.view, calls keep their shape with masked numbers, role is a new field. No SQL.
Rollback: redeploy `owner-provision-business` from the main commit before this PR's merge commit.

## Tests
- Automated local: `deno test` in owner-provision-business: 38 passed, 0 failed (new `detail_test.ts`: no activity
  read and no actor resolved without audit.view; activity with it; no 7+ digit number or connection email anywhere in
  calls and integrations; invitations carry role, owner first; a failed read refuses; adminPermissions equals the
  dispatcher's rule for every action and role and equals me_admin; a failed lookup grants nothing. New `mask_test.ts`).
  `deno check index.ts` passes.
- Local end to end (isolated `zle_ui`, local stand in, the real function under Deno): anonymous 401; a signed in
  business owner who is not an admin 403; a business that doesn't exist 404; `readonly@zella.test` (businesses.view
  only) gets `activityAllowed false`, 0 activity rows, masked numbers (`…0003`), invitation roles owner then staff;
  `ops@zella.test` (with audit.view) gets 11 activity rows; no full number in any call.
- No browser check: no web change in this PR.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
