Member support: reset a member's two step sign in after a recorded identity check (edge; needs owner approval before deploy)
base: claude/lane-e-member-status

**Needs owner approval before deploy**, including approval of the identity check procedure written in
ARCHITECTURE.md (REQ-LC-19). This is the most sensitive action on the page (account takeover if the check is weak).

## What and why
**UI-06 part d.** `member_mfa_reset` (`detail.ts`):
- permission businesses.manage; ACC-19 (fresh admin code) doesn't exist yet, so a reason of 10 to 300 characters
  and `identityChecked: true` (the admin ticks "I checked who is asking") are required; ACC-19's step up goes in front
  once built;
- refuses a Zella Voice admin (their reset is in Users & access), the acting admin themselves, anyone who isn't a
  member of that business, and a member with no verified authenticator;
- **audit first, fail closed:** writes `member.mfa_reset` (member id, reason, identity_checked, the number of
  verified authenticators; no factor ids or secrets) before anything is removed; if that write fails, 503 and nothing
  changes;
- removes only that person's verified factors (`auth.admin.mfa.listFactors({userId})`, `deleteFactor({id,
  userId})`); a failure part way says how many were removed.

The web half (a reset dialog with the identity check checkbox and a reason) is in the Business page web PRs.

## Defaults taken (owner can change)
- businesses.manage plus a typed reason and the identity check box until ACC-19; never a platform admin's.

## Deploy order
Edge function on its own (needs approval), then the web half. No SQL. No real reset outside a test project.
Rollback: redeploy `owner-provision-business` from the main commit before this PR's merge commit.

## Tests
- Automated local (mocked `auth.admin.mfa`): `deno test` 83 passed, 0 failed. New `member_mfa_test.ts`: permission,
  reason and identity check required (a string "yes" is not true); only that member's verified factors are deleted
  (2 of 3) and only their count is recorded, no factor ids; a failed audit write gives 503 with nothing deleted; a
  platform admin 403 with nothing deleted, yourself 403, another business's person 404, nobody with a factor 409
  with nothing recorded. `npm run lint` catalog drift passes (220 actions).
- Local end to end (isolated `zle_ui`): `readonly@zella.test` 403; anonymous 401; without the identity check 400;
  a person of another business 404. The local stand in has no admin MFA endpoints, so the removal itself is proved
  by the mocked test only.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
