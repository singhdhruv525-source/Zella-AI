Automations: one live rule for saves, behind an off switch (edge)
base: claude/lane-e-audit-before-after

## What and why
**BIZ-07 part a (server half).** Turning an automation on for a business that is already live saved it "paused", and
it stayed paused for ever; turning one on while suspended was never restarted; industry rules were "active" for
businesses still being tested (is_active is true from testing on).
- New pure `live.ts`: `liveFor(b)` = onboarding_status active, not suspended, not cancelled; `savedStatus(...)`.
- `saveAutomations` and `saveIndustryRules` use it. With the switch on:
  - live business: an enabled automation or rule is saved **active** (starts at once: real messages);
  - a business that went live and is suspended: saved paused with `paused_by_suspension = true`, so the lifecycle
    trigger restarts it on reactivation;
  - not live yet (draft, testing): paused; going live activates it (`zella_request_activation` activates every
    paused automation of the business, rules included: tested).
- **The switch:** edge secret `ZELLA_AUTOMATIONS_START_ON_SAVE = "on"`. Off (the default), every save behaves exactly
  as before this change (tested over every business state and current status).

The web half (Pause and Resume on the business page, links to the wizard and to `/automations/directory?business=`,
copy that depends on state) is in the Business page web PRs.

## Critic corrections applied
- **Deploys are cut from main** (MEMORY: v18 deployed from main), and all four production businesses are
  onboarding_status active, so merging this would start real messages at the next deploy of anything. Hence the
  switch: merging and deploying change nothing until the owner sets the secret.
- **The reactivation path:** `zella_suspend_business` pauses the running rows itself and lists them in
  `setup_data.suspended_state` (it doesn't flag them); rows with `paused_by_suspension` are restarted by the lifecycle
  trigger when `suspended_at` goes back to null. The tests assert that trigger path and do not add ids to
  `suspended_state`.
- **Industry rules saved during testing** are now paused with the switch on; the isolated test proves
  `zella_request_activation` activates them at go live.

## Needs owner decisions (not built)
- No backfill of automations already left paused on live businesses (either choice sends or withholds real messages).
- Part b (the `zella_admin_ops` live rule migration, PR 21) waits on the owner.

## Defaults taken (owner can change)
- `ZELLA_AUTOMATIONS_START_ON_SAVE` off. Restart automations turned on while suspended at reactivation (recommended,
  via `paused_by_suspension`).

## Deploy order
Edge function (window B, needs approval) with the switch off: no behaviour change. Turning the switch on is its own
live change: it needs the owner's explicit approval that turning on an automation for a live business starts real
messages.
Rollback: redeploy `owner-provision-business` from the main commit before this PR's merge commit, or unset the secret.

## Tests
- Automated local: `deno test` 64 passed, 0 failed. New `live_test.ts`: liveFor for draft, testing, live,
  suspended, suspended draft, cancelled; the switch is off unless "on"; switch off is exactly the old behaviour for
  every state and current status (standard and rules); switch on matrix. `deno check index.ts` passes.
- Isolated database, `tests/automations_live/run.sh` (zprod3, test data): ALL PASS. Suspending pauses the running
  automation itself and lists it in suspended_state (unflagged); reactivating restarts every flagged automation,
  including one saved while suspended, and leaves an unflagged paused one paused; a seeded ready testing business
  goes live through `zella_request_activation` as its owner, and both its standard automation and its industry rule
  saved paused become active.
- Local end to end (isolated `zle_ui`, real function): switch off, enabling three automations on the live test
  business leaves the paused ones paused (as today). Switch on: all three active; with the business suspended, all
  three paused and flagged; clearing the suspension restarts all three (trigger); with the business in testing, all
  three paused and unflagged.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
