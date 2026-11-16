Setup: retry failed internal steps, by hand or on a timer that starts off (SET-ONB-RETRY part 2)
base: claude/lane-b-provisioning-steps

## What and why

**SET-ONB-RETRY, part 2.** Part 1 (the base branch) records every setup step. This branch lets a failed step be retried. It reuses the safe retry PR's approach: a server only function with explicit checks and an audit row. Only internal steps are ever retried without a person.

New migration `sql/zella_provisioning_retry.sql`. It replaces nothing and both functions are server only.
- `zella_retry_provisioning(p_business, p_step, p_actor)` locks the business and refuses a cancelled one. It repairs only what is missing and never changes what an admin chose:
  - **modules:** it adds a row for every active industry module that has none, switched on as a new draft has it. A module an admin turned off stays off.
  - **receptionist:** it adds a disabled receptionist and its settings row when they are missing.
  - **automations:** it invents nothing. The step is done only when the business has automations. Otherwise it stays failed with the note "save the Automations step again".
  - **Any other step** (the owner invitation email, finish, integrations and so on) is refused with `NOT_INTERNAL`.
  - It records the outcome through `zella_track_provisioning`, which resolves or raises the provisioning alert, and audits `provisioning.step_retried` with the admin, or "timer".
- `zella_retry_provisioning_due()` retries failed internal steps last changed over an hour ago, at most 3 timed attempts per step, and skips locked rows. Its timed job `zella_provisioning_retry` (hourly at :17) is **created OFF** with `cron.alter_job`, following `zella_email_delivery.sql`. Turning it on is the owner's switch.
- Server, `lifecycle.ts`: the `retry_step` action needs businesses.manage and only accepts `RETRYABLE_STEPS`. For the invitation email it answers "Use Send owner invite", and for anything else "Use Continue setup". The database writes the audit row.
- Web, Business onboarding: each failed step shows **Retry step** (internal steps) or **Send owner invite** (the invitation email). The "isn't built" note now says the timed retry exists and is off.

## Defaults taken (owner can change)
- Only internal database steps are retried without a person: modules, the receptionist, and automations as a check only (owner_decisions SET-ONB-RETRY, recommended). The owner invitation email and provider steps get a manual button, or Continue setup.
- The timed retry runs at most 3 times per step, on steps over an hour old, hourly, and is off until the owner switches it on.

## Deploy order (each step needs the owner's approval)
1. SQL: `sql/zella_provisioning_retry.sql`.
2. `owner-provision-business`.
3. Web app.
4. Enabling the timed job is a separate live switch for the owner.

## Tests
- **Automated local, isolated DB** (`tests/provisioning_retry/run.sh`, on template zprod3, and on zprod3 plus every merged, not applied migration): 22 checks, all passing. They cover:
  - before the migration, no retry exists;
  - apply, and apply again;
  - the job exists once and is off;
  - modules: only missing rows are added and a module turned off stays off, then the step is done, the alert resolved, and the retry audited with the admin;
  - receptionist: a disabled one and its settings are added, and a second retry adds nothing;
  - automations: no rows means it stays failed with a note, and with rows it is done;
  - owner_invitation, finish and integrations are refused, and so is a cancelled business;
  - the timed run retries only failed internal steps over an hour old (not a fresh failure, not the invitation email) and is audited as the timer;
  - at most 3 timed attempts;
  - only service_role can execute;
  - rollback twice removes the job and both functions;
  - reapply, and VERSION_MISMATCH and ROLLBACK_DRIFT on drift.
- **Deno** (`lifecycle_test.ts`, 1 new; the whole function 51 passed): the actor is passed, the invitation email, finish and integrations are refused without a call, NOT_FOUND gives 404, CANCELLED 409, a missing function 503, and a bad id is refused. `deno check index.ts` is clean.
- **Web unit:** `retryAction`. `node --test web/tests/*.test.mjs`: 109 passed. `npm run lint` (0 dashes) and `npx vite build` pass.
- **Local browser** (isolated DB, 390x844 and 1440x900, deviceScaleFactor 1): 10 checks, all passing, no page errors. They cover:
  - a failed modules step shows Retry step, and a failed invitation email shows Send owner invite;
  - Retry step repairs the modules, says so and is audited;
  - no sideways scroll.
  The onboarding table was already wider than the card before this change; the page itself doesn't scroll sideways.
  Screenshots: `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-b/shots/b7-retry-390.png`, `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-b/shots/b7-retry-1440.png`.

## Migration fingerprints
New functions (this file's versions): `zella_retry_provisioning(uuid,text,uuid)` `b5b05c27d48b7c001a8f6b453c484b78`, `zella_retry_provisioning_due()` `f608e26c9df1d31cccd43c638fa8d26b`. Production md5s to be confirmed by the supervisor before apply. The new job name must not already exist in production (`zella_provisioning_retry`).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
