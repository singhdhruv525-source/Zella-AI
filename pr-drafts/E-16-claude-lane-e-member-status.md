Member support: deactivate or reactivate one membership, with a reason (edge; needs owner approval before deploy)
base: claude/lane-e-invitation-cancel

**Needs owner approval before deploy.** It acts on real people's access.

## What and why
**UI-06 part c.** Support had no way to remove one person's access to a business from the business page.
`member_set_status` (`detail.ts`; guards in the new pure `member_support.ts`):
- permission `MEMBER_SUPPORT_PERMISSION` = businesses.manage; ACC-19 (a fresh admin code, lane A) doesn't exist yet,
  so a typed reason of 10 to 300 characters is required instead; when ACC-19 lands its step up goes in front;
- active to suspended, or suspended back to active, only from the status the page saw (409 if it changed);
- refuses the business's **only active owner**, anyone who isn't a member of that business (404), and statuses other
  than active and suspended (the database allows invited, active, suspended);
- records `member.suspended` or `member.reactivated` with role and status before and after, and the reason (both
  added to the shared catalog).

The web half (a row menu on People, gated by permission) is in the Business page web PRs. Role changes (part e) are
deferred until the owner asks (REQ-LC-06 role rules).

## Defaults taken (owner can change)
- `MEMBER_SUPPORT_PERMISSION = "businesses.manage"`, `MEMBER_REASON = {min: 10, max: 300}`; the last active owner
  can't be deactivated.

## Deploy order
Edge function on its own (needs approval), then the web half. The old app never calls it. No SQL. The database's own
trigger row for the membership change stays unattributed until ACC-07 (PR 20, waiting on the owner).
Rollback: redeploy `owner-provision-business` from the main commit before this PR's merge commit.

## Tests
- Automated local: `deno test` 79 passed, 0 failed. New `member_support_test.ts`: defaults; the status rules (last
  active owner, a second owner, staff, reactivate, already active, another business's person, a wrong status, an
  invited seat); the action deactivates and reactivates with old and new; refuses a short reason, the last owner, a
  person of another business and a change meanwhile. `npm run lint` catalog drift passes (219 actions).
- Local end to end (isolated `zle_ui`): deactivating the only owner 409; deactivating the staff member 200, after
  which `zella_is_member` is false for them (signed in claims) and the audit row reads active to suspended;
  `readonly@zella.test` 403; anonymous 401; the same person on another business 404; reactivating 200 and
  `zella_is_member` true again.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
