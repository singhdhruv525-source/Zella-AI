Owner invitation: cancel with a reason, resend cooldown, failed seat insert recorded (edge; needs owner approval before deploy)
base: claude/lane-e-support-access

**Needs owner approval before deploy.** Cancel revokes access; Resend still sends a real email.

## What and why
**BIZ-21 part b.**
- `invitation_cancel` (`detail.ts`, `CANCEL_PERMISSION` = businesses.manage): a reason of 10 to 300 characters; moves
  the owner's invitation to `revoked` only from an open or sent state and only `role = 'owner'` (an acceptance or
  send that lands first wins: 409); records `invitation.revoked` with old and new status, the reason and a masked
  email.
- **Critic correction (seat):** a seat can't be set `inactive` (`business_members_status_check` allows invited,
  active, suspended), and leaving or suspending it breaks a later re-invite (recordSent and Resend skip the insert when
  any row exists, and `zella_accept_my_invitations` only activates `invited`). So the cancel **deletes** the invited
  owner seat (`status = 'invited'`, `role = 'owner'`). The isolated test cancels, re-invites and accepts.
- **Resend cooldown (critic correction):** `invited_at` is the reminder job's clock and a failed send never sets it,
  so it is not used as the claim. The cooldown is read from `invited_at` (last successful send): 429 "It can be sent
  again in N minutes" inside `RESEND_COOLDOWN_MINUTES` (5); a failed send can be retried at once. The claim is a
  compare and set on `updated_at`, so two clicks at once send one email (the other gets 409). `invited_at` and
  `last_reminded_at` are not touched by the claim.
- `invitation.revoked` added to the shared catalog.

**BIZ-02 part a.** When Resend sends the email but the owner's seat insert fails, it writes
"Seat not created: …" to the invitation's `last_error` and returns a warning instead of only logging.

The web half (Cancel with a reason dialog; Resend disabled with "Can be sent again at <time>") is in the Business page
web PRs; until then the old app shows the 429 text through its error box.

## Defaults taken (owner can change)
- `RESEND_COOLDOWN_MINUTES = 5`; `CANCEL_PERMISSION = "businesses.manage"`; `CANCEL_REASON = {min: 10, max: 300}`.
- A never used auth account is kept after a cancel (not deleted).

## Deploy order
Edge function on its own (needs approval), then the web half. The cooldown applies to the old app's Resend at once.
No SQL. Rollback: redeploy `owner-provision-business` from the main commit before this PR's merge commit.

## Tests
- Automated local: `deno test` 75 passed, 0 failed. New `invitation_cancel_test.ts`: defaults; cancel from pending,
  sent, failed and expired revokes, removes the invited seat and records old and new; a short reason refused; an
  accepted invitation 409; none 404; accepted while the cancel was on its way 409 with nothing changed; the cooldown
  window. `deno check index.ts` passes. `npm run lint` catalog drift passes (217 actions).
- Isolated database, `tests/invitation_cancel/run.sh` (zprod3): ALL PASS. A revoked owner invitation activates
  nothing even with the seat left behind; a seat can't be set inactive; after the cancel's delete, inviting the same
  person again and signing in through the link (amr otp) activates the seat.
- Local end to end (isolated `zle_ui`, the stand in sends no email): two Resends at the same moment: one 200, one
  409; a third 429 "It can be sent again in 5 minutes"; `invited_at` moved only by the successful send,
  `last_reminded_at` untouched. Cancel with "no" 400; `readonly@zella.test` 403; `ops@zella.test` 200: invitation
  revoked, owner seat removed, audit `{"status":"sent"}` to `{"status":"revoked","reason":…,"seat_removed":true,"email":"n…@lanee.test"}`;
  cancelling an accepted invitation 409.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
