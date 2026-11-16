Setup: record every setup step in provisioning_steps (SET-ONB-RETRY part 1)
base: claude/lane-b-document-orphans

## What and why

**SET-ONB-RETRY, part 1.** Nothing ever wrote `provisioning_steps`. `zella_track_provisioning` had no caller in web/ or n8n/, so the Failed steps column on Business onboarding and the Provisioning errors card were always empty, and there was nothing to retry.

- `lifecycle.ts` adds `trackSetup(admin, action, fields, run)` and `SETUP_STEPS`. It covers the steps business, owner, operations, team, terminology, modules, receptionist, integrations, spam, automations and finish.
  - **When the business id is known:** it records `pending`, runs the save, then records `done`. An unexpected error records `failed` with the message, which raises the existing `provisioning_failed` alert through the database function.
  - **Deliberate refusals:** an `InputError` (bad input, or "can't finish yet", such as no plan check or no app address) is answered before anything is provisioned, so the step is put back as it was. The earlier row is restored, or the new pending row is deleted. This raises no false alert.
  - **New draft:** `business` is recorded `done` once the id exists.
  - **Finish:** records `owner_invitation` as its own step. A failed email marks both it and `finish` failed. A finish cancelled during the send puts the step back.
  - **Never in the way:** a recording failure is logged and never changes the save's answer.
- `index.ts` has one line in the main handler: `await trackSetup(adminClient, action, fields, handler)`. It returns the handler unchanged for every action that isn't a setup step. There is no change to the handlers map.

## Defaults taken (owner can change)
- A refusal (InputError, any status) is not a failed provisioning step.
- The step names above. Part 2 (retry) uses them: modules, automations and receptionist are internal; owner_invitation is manual.

## Deploy order (each step needs the owner's approval)
1. `owner-provision-business`.

There is no migration (it uses the applied `zella_track_provisioning`) and no web change. Failed steps and Provisioning errors start filling.

## Tests
- **Deno** (`lifecycle_test.ts`, 6 new; the whole function 50 passed):
  - four setup saves record pending then done with the right step name;
  - an unexpected error records failed with the message;
  - a 400 refusal deletes the new pending row, or restores an earlier failed row;
  - a 503 refusal ("can't finish yet") is not a failure either;
  - a new draft records `business=done`, and other actions are not tracked;
  - finish records owner_invitation done and finish done, an invitation failure records both failed, and a cancelled finish puts the step back;
  - with every database call throwing, the save's answer is unchanged.
  - `deno check index.ts` is clean.
- **Local, through the real function against an isolated DB** (`/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-b/b6.mjs`): 8 checks, all passing. The steps are create draft (business=done), save owner (owner=done), a refused owner save (400, still done) and terminology (done). A finish refused before any work (503, because this database has no plan tables) records nothing and raises no provisioning alert.
- `npm run lint` (0 dashes).

There is no browser check, because no page changed.

No migration, so there are no md5s to confirm.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
