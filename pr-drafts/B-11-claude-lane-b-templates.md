Messaging templates: create and retire industry and language versions, case insensitive script guard (UI-20, COM-27)
base: claude/lane-b-held-emails

## What and why

**UI-20.** Messaging, Templates could only edit. **COM-27.** The script guard in `zella_admin_template_save` was case sensitive (`~`), so `<SCRIPT>` got through. Variables were added at the end of the text.

New migration `sql/zella_admin_templates_manage.sql`:
- `zella_admin_template_create(p_key, p_channel, p_industry, p_locale, p_subject, p_body, p_reason)` makes an **industry version** or a **Spanish version** of a key that already has an active platform version on that channel. Senders only ever send existing keys, resolving business, then industry, then platform (`zella_resolve_template`).
  - Refusals: `NO_PLATFORM_VERSION`, `ALREADY_EXISTS` (also for the platform version itself), `LOCALE` (en-US and es-US only), `INDUSTRY_NOT_FOUND`.
  - Same checks as saving: length, email subject, script guard, STOP for marketing texts, known variables.
  - Purpose is inherited from the platform version. Audited as `comms.template_created`.
- `zella_admin_template_retire(p_id, p_reason)` archives an industry version or a platform version in another language, so senders fall back to the platform version. It refuses the English platform version (`PLATFORM_BASE`), which every sender falls back to, and a business's own copy (`BUSINESS_TEMPLATE`). Audited as `comms.template_retired` with the old text.
- `zella_admin_template_save`: the only change is that the script guard is `~*` and covers the subject too. It is archived first and must match production's version (`bab3d1281f36ad1f5da6c31fd4ac5008`, the same on zprod3 and after every merged migration).
- Every change needs comms.manage and a reason (`zella_admin_reason`).

Web:
- `web/src/admin/TemplateVersions.jsx` (new) has the NewVersion form (for: all businesses or an industry; language; subject; message) and Retire, each confirmed with a reason.
- `MessagingPage.jsx` TemplateDrawer shows "Add industry or language version" on platform templates and Retire on overrides, and inserts a variable **at the cursor** (COM-27).

## Defaults taken (owner can change)
- Create only makes industry or language versions of existing keys, and Retire only removes such overrides (owner_decisions UI-20, recommended scope).
- Languages: English and Spanish (en-US, es-US), the receptionist's languages.

## Deploy order (each step needs the owner's approval)
1. SQL: `sql/zella_admin_templates_manage.sql`.
2. Web app.

## Coordination
- Stacked on `claude/lane-b-held-emails`.
- **MessagingPage.jsx is also on the open polish PR #88.** A test merge with `claude/admin-ui-polish-2` (16 Nov) conflicts in MessagingPage.jsx, PRODUCT.md and ADMIN_AUDIT. **Merge after #88**: merge origin/main in, resolve by keeping #88's layout and copy plus this branch's TemplateDrawer additions, then rerun the tests above.
- The versions list part of COM-27 is not built.

## Tests
- **Automated local, isolated DB** (`tests/admin_templates/run.sh`, on template zprod3, and on zprod3 plus every merged, not applied migration): 20 checks, all passing. They cover:
  - before the migration, `<SCRIPT>` gets through a save and create doesn't exist;
  - apply, and apply again;
  - the save refuses script in three case variants;
  - create makes an industry version and a Spanish version, both audited with the reason;
  - create refuses a missing platform key, a second copy, the platform version itself, fr-FR, a marketing text without STOP, unknown variables, script and a blank reason;
  - a business of that industry now resolves to the industry version;
  - read_only_admin and a business owner are refused create and retire;
  - retire archives the override, the business falls back to the platform text, and it is audited;
  - the English platform version and a business copy can't be retired;
  - rollback twice restores the save exactly and drops both new functions;
  - reapply, and VERSION_MISMATCH and ROLLBACK_DRIFT on drift.
- `npm run lint` (0 dashes), `npx vite build`, and `node --test web/tests/*.test.mjs` (100 passed on this branch) all pass.
- **Local browser** (isolated DB; 1440x900 and 390x844, deviceScaleFactor 1): 9 checks, all passing, no page errors. They cover:
  - the variable goes in at the cursor;
  - a Spanish version is created through the form and audited;
  - at 390 the Spanish version offers Retire, retiring archives it, and the English platform version offers no Retire;
  - no sideways scroll.
  Screenshots: `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-b/shots/b11-new-version-1440.png`, `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-b/shots/b11-drawer-390.png`, `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-b/shots/b11-retire-390.png`.

## Migration fingerprints
- `zella_admin_template_save`: production `bab3d1281f36ad1f5da6c31fd4ac5008`, after this file `f450f6f47333d8198151ae5c5d33523c`.
- `zella_admin_template_create`: `f28fd02113f908cd6f5fee54f274ca19`.
- `zella_admin_template_retire`: `22bbf6bbbb86b0d57932599e220f9171`.

Production md5s to be confirmed by the supervisor before apply.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
