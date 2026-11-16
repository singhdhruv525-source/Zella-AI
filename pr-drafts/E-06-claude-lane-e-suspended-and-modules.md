No finishing setup while suspended; module dependencies checked on the server
base: claude/lane-e-detail-permissions

## What and why

**BIZ-06.** Finishing setup for a suspended business made its workspace active and sent the owner an invitation.
- `owner_invite.ts`: `FinishDeps.business()` carries `suspended_at`; `finishSetupWith` refuses a suspended business
  with 409 "This business is suspended. Reactivate it on the business page before finishing setup." before anything is
  claimed or sent.
- `activate()` in `finishSetup` now updates only a business that is still not suspended or cancelled
  (`.is("suspended_at", null).is("cancelled_at", null)`) and reports whether it did. **Critic correction:** a
  suspension that lands while the invitation is going out no longer turns into a silent success: the finish returns
  `completed: false` with a warning ("The business was suspended or cancelled while setup was being finished, so its
  workspace was not turned on").

**CFG-02.** `saveModules` checked a dependency only when the industry offered it, so "AI receptionist" could be
switched on in an industry without "Calls".
- New pure `module_deps.ts`: `MODULE_DEPENDENCIES` (moved from index.ts), `businessModuleProblems` (a dependency
  switched off, or not offered by the industry, refuses) and `industryModuleProblems` (for the industry editor).
- `setup_load` (and so `business_detail`) returns `requires` on each module, so the web app can stop keeping its own
  copy.

## Not in this PR (and why)
- **The industry editor check** (`industrySave` refusing to switch off a needed module): lane C's open branch
  `claude/lane-c-industry-modules` (CFG-01) rewrites the same lines of `industrySave`. `industryModuleProblems` is
  built and tested here; wiring it is one line next to lane C's `switchOffCheck` once CFG-01 merges.
- **The web half** (Continue setup disabled while suspended; the module switch disabled with "Needs Calls, which this
  industry doesn't offer", reading `requires`): `BusinessDetails.jsx` and `BusinessAdminControls.jsx` are being edited
  on the Businesses list job's branch, on the same lines. They follow in the Business page web PRs built on that
  branch. Meanwhile the old web app shows the new 409 and 400 messages through its existing error box.
- Note for lane B: `finishSetup` and `saveModules` are in lane B's index.ts ranges; the edits here are the
  `activate()` body and the dependency loop only.

## Data check
Isolated database (zle_base: zprod3, writing cleanup, the merged unapplied migrations): no industry and no business
breaks the new rule today (0 of 150 industry modules are switched off; 0 businesses with a module whose dependency is
off).

## Defaults taken (owner can change)
- A finish that loses the race to a suspension sends the invitation and leaves the workspace off with a warning,
  rather than trying to recall the email.

## Deploy order
Edge function only (window A, needs approval). No SQL. The old web app is unchanged and shows the new refusals.
Rollback: redeploy `owner-provision-business` from the main commit before this PR's merge commit.

## Tests
- Automated local: `deno test` 44 passed, 0 failed. New: a suspended business is refused before any claim or email
  (0 claims, 0 emails, invitation still pending); a suspension during the finish leaves `completed: false` with the
  warning; `module_deps_test.ts`: dependency on passes, dependency off refused, dependency not offered refused (was
  skipped), industry rules. `deno check index.ts` passes.
- Local end to end (isolated `zle_ui`, real function under Deno): finishing a suspended test draft 409 with the
  message; AI receptionist without Calls 400 "AI receptionist requires Calls."; with Calls switched off for the
  industry 400 "AI receptionist needs Calls, which this industry doesn't offer."; both on 200; `setup_load` returns
  `requires`; `readonly@zella.test` 403, anonymous 401, unknown business 404.
- No browser check: no web change in this PR.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
