Settings, Business onboarding: delete a never finished draft, and audit history is never deleted with a business (BIZ-13a, ACC-10)
base: claude/lane-b-creation-key

## What and why

**BIZ-13a.** There was no way to delete a mistaken draft. A delete was also unsafe or impossible for two reasons, one of them found while testing:
- `audit_logs.business_id` is ON DELETE CASCADE (ACC-10), so a delete erases the business's audit rows, and would erase a deletion entry that carried the business_id.
- `zella_audit_privileged` (the trigger on businesses, ai_agents, automations and business_members) writes a `privileged_delete` row pointing at the business being deleted. That fails the audit foreign key, so **any** delete of a business made the real way (it has a receptionist) failed. The test reproduces this before the migration.

New migration `sql/zella_draft_delete.sql`:
- **The audit foreign key becomes ON DELETE SET NULL** (ACC-10, the owner's decision). The guard checks that `audit_logs_business_id_fkey` is exactly production's `ON DELETE CASCADE` before changing it. If it is anything else, the file refuses with VERSION_MISMATCH and changes nothing. Re-running is allowed only when it is already this file's SET NULL.
  - A deleted draft's earlier audit rows **survive**, with business_id null.
  - The deletion's own entry `business.draft_deleted` is written after the delete with **business_id null**. Its `old_data` keeps the business id, name, industry, setup step, created and updated dates, and the ids of the earlier audit rows (at most 1000), so they can still be found together; audit_logs has no name column. The reason goes in `new_data`.
- `zella_audit_privileged` is changed in one place only. On DELETE, when the business no longer exists (it is being deleted in the same statement), it writes business_id null and keeps the id as `new_data.deleted_business_id`. The function is archived first and must match production's fingerprint, which is the same on zprod3 and after every merged migration.
- `zella_delete_draft_business(p_business_id, p_actor, p_confirm_name, p_reason)` is server only:
  - it requires the actor to be an active zella_owner or super_admin, the typed name (case and spaces ignored), and a reason (`zella_admin_reason`);
  - under FOR UPDATE it refuses (`NOT_A_DRAFT: <list>`) any business that is in testing, ready or active, is active, is cancelled or cancelling, has an accepted owner invitation or an active member, or has calls, phone numbers, subscriptions, payments, assistant deliveries or offer history;
  - a pending owner invitation goes with the cascade, so its link stops working;
  - it returns every business-documents path of the business: the document rows plus any storage object under its folder, orphans included.
- Server `lifecycle.ts`: the new action `business_delete_draft` needs businesses.manage **and** the zella_owner or super_admin role (`DRAFT_DELETE_ROLES`), checked before any database call. It maps every refusal to plain words, then removes the returned files (only paths under that business's folder, in chunks of 100). If storage fails, it reports `filesLeft`, and those files are then plain orphans for the orphan cleanup (BIZ-18a). The database writes the audit entry in the same transaction, so index.ts writes no second one.
- Web: the Onboarding panel moves from AdminPanels.jsx into `web/src/settings/panels/Onboarding.jsx`, the panel file rule. AdminPanels.jsx now only re-exports it. The panel adds a **Delete draft** button for owners and super admins, for rows that are still drafts. The confirm needs the name typed and a reason, and is portalled to the body because the settings pane is animated.

## Owner decisions
- **ACC-10 (owner, 16 Nov 2026): audit history is never deleted along with a business.** `audit_logs_business_id_fkey` changes from ON DELETE CASCADE to ON DELETE SET NULL, version guarded, and the rollback restores CASCADE. This changes what every future delete of a business does to its audit rows: they now stay.

## Defaults taken (owner can change)
- Who may delete a draft: Zella Voice owner and super admin only, with the name typed and a reason (owner_decisions BIZ-13a, recommended answer). This is `DRAFT_DELETE_ROLES` in lifecycle.ts and `web/src/businessLifecycle.js`, and the role list in the SQL function.
- What counts as "never finished": the refusal list above.
- The name and the earlier row ids are kept in the deletion entry's old_data, not in a new column (supervisor change).

## Deploy order (destructive action, so the owner must approve each step explicitly)
1. SQL: `sql/zella_draft_delete.sql`. It changes the audit foreign key to SET NULL (the owner's ACC-10 decision).
2. `owner-provision-business`.
3. Web app.

## Coordination
- Stacked on `claude/lane-b-creation-key` (lifecycle.ts).
- AdminPanels.jsx changes only the Onboarding function, which becomes a re-export. The open polish PR #88 edits other panels in that file.

## Tests
- **Automated local, isolated DB** (`tests/draft_delete/run.sh`, on template zprod3, and on zprod3 plus every merged, not applied migration): 32 checks, all passing. They cover:
  - before the migration, a draft with a receptionist can't be deleted (FK error), and a bare one loses its audit rows;
  - apply, and apply again;
  - a read only admin, a person who isn't an admin, a wrong name and a blank reason are refused;
  - an owner deletes the draft (name typed in a different case) and gets the document paths, orphans included;
  - the business, receptionist, modules and pending invitation are gone;
  - a foreign key that isn't exactly CASCADE stops the file and changes nothing;
  - after applying, the foreign key is SET NULL, and the earlier audit rows survive with business_id null;
  - the deletion row survives with business_id null, and carries the business id, name, industry, the earlier row ids, the reason and the actor;
  - the cascade's own privileged rows are kept;
  - a super admin can delete too;
  - eleven kinds of business that is not a draft (live, testing, active, cancelled, accepted owner, member, calls, number, subscription, payment, delivery) are refused and left untouched, and an unknown id is NOT_FOUND;
  - only service_role can execute;
  - rollback twice restores the trigger function and CASCADE exactly, drops the delete, and keeps the deletion entries and the earlier rows;
  - reapply, and VERSION_MISMATCH and ROLLBACK_DRIFT on drift.
  Offer history is in the refusal list but has no fixture.
- **Deno** (`lifecycle_test.ts`, 10 tests): the four new tests check that six roles (and a missing role) are refused with 403 before any call; that the name and reason are required; that the actor is passed and only that business's files are removed (another business's path is ignored); that `filesLeft` is reported when storage fails; that every refusal maps to plain words with the right status; and that database errors are kept. The whole function: 38 passed. `deno check index.ts` is clean.
- **Lint, build and unit:** `npm run lint` (0 dashes), `npx vite build`, `node --test web/tests/*.test.mjs` 104 passed.
- **Local browser** (real Settings page and real function against the local stand in and an isolated DB, 390x844 and 1440x900, deviceScaleFactor 1): 19 checks, all passing, no page errors. They cover:
  - Delete draft is shown for a draft and not for a business past setup;
  - the confirm stays disabled until both the name and the reason are filled in;
  - at 1440 the draft is deleted, the audit entry has the name and reason, and the page says so;
  - a read only admin sees no button and gets 403 from the server;
  - anonymous gets 401;
  - a wrong name gets 400;
  - a live business (the wrong business) gets 409 with the reason.
  Screenshots: `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-b/shots/b2-delete-390.png`, `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-b/shots/b2-delete-1440.png`, `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-b/shots/b2-deleted-1440.png`.
  The browser database (an older baseline copy) has no `assistant_deliveries` table, so the test creates an empty one there. Production and zprod3 have it.

## Migration fingerprints
- `zella_audit_privileged()`: production version `0df0acdb83754ec20a082bdc6f48c50a` (zprod3, unchanged by any merged migration). After this file: `8f2909322446a24d4880c17a0bab98b9`.
- `zella_delete_draft_business`: `d6bedb36457b54e476f5a0f214f2abc3`.
- `audit_logs_business_id_fkey` must be exactly CASCADE (confirmed in production by the supervisor). This file changes it to SET NULL, and the rollback changes it back.

Production md5s to be confirmed by the supervisor before apply.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
