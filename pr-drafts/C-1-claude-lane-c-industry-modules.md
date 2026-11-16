Industry modules: honest copy, "N businesses lose X" confirmation, deactivate and reactivate an industry (CFG-01, CFG-08)
base: main

## What and why

**CFG-01 (one item; the triage had two rows for it).** Switching a module off for an industry removes it at once from every business in that industry that has it on, because `zella_module_on` (sql/zella_navigation.sql:33-46) needs `industry_modules.is_active`. The page said the opposite ("businesses keep the modules they already have", "Switch one off to stop offering it").
- The copy now says what happens, and each module row shows how many businesses have it on.
- New action `industry_module_usage` (`businesses.view`) counts, per module, the businesses with it on by the same rule as `zella_module_on` (enabled row, business in the module's industry). It reads in pages until a page comes back empty, so it stays right past PostgREST's 1,000 row cap (tested with 1,101 businesses and the cap on).
- Saving a switch off of a used module opens a confirmation listing "N businesses lose X" and asks for a reason. `industry_save` refuses (409) an unconfirmed switch off: the module ids must be in `confirmOff`. The audit row records the modules switched off, their counts and the reason.
- `industriesList` business counts were a single unbounded read, so they stopped at 1,000. They are read in pages now.

**CFG-08.** New action `industry_set_active` (`platform.configure`, reason required, audited as `industry.deactivated` or `industry.reactivated`, a repeat that changes nothing writes no row). Inactive industries show an Inactive pill in the list and header. A Deactivate or Reactivate button sits in the header. Inactive industries are not offered when a business is created (`zella_create_business_draft` already refuses them). Businesses already in the industry keep working, with their modules and words. Rename and delete stay out of scope (presets and default automations match on the name).

**Code layout.** New Lane C module `config.ts` (`CONFIG_PERMISSIONS`, `configHandlers` with its own `audited` map), hooked into index.ts the way `platform.ts` is: one import, `?? CONFIG_PERMISSIONS[action]` in the permission lookup, and the handler and audit lookups chained after `platform`. In place edits only inside Lane C ranges (`industriesList`, `industrySave`, the `industry_save` audit entry). The local stand in gets an optional `ZMAX_ROWS` cap that works like PostgREST's `max_rows`.

## Defaults taken (owner can change)
- **Switching a module off stays a kill switch** (CFG-01 owner decision, recommended answer): it is removed from every business in the industry, with the count shown and a confirmation first. Keeping it for existing businesses would need a migration of `zella_module_on` and `zella_workspace_navigation`.
- **`LEGACY_SWITCH_OFF_ALLOWED = true`** in config.ts: an older web app that sends no `confirmOff` at all may still switch a used module off, and the audit row says `switched_off_without_confirmation`. Set it to false in a follow up once the new web app is live.

## Deploy order
1. **The web app first.** It sends `confirmOff` and `reason`, which the server currently live ignores, so it is safe on its own. It also calls `industry_module_usage` and `industry_set_active`. Until the function is deployed, those calls get "Unknown action": the counts show nothing, and Deactivate gives an error.
2. **Then `owner-provision-business`**, with the owner's approval. Until the web app is deployed everywhere, the function still accepts a switch off without `confirmOff` (`LEGACY_SWITCH_OFF_ALLOWED`), so the old app keeps working.
3. No SQL.

## Side effects reported to other jobs
- **The Businesses list job:** `dashboard_data` loads only active industries (index.ts, held by that job). A business in a deactivated industry would be labelled "Unassigned" there. That job should load all industries for labels and only active ones for the create menu.
- **The wizard (Lane B and the polish agent):** the wizard should still show a draft's current industry if that industry becomes inactive. Not changed here.

## Tests
Automated, local:
- `tests/industry_modules/run.sh` (29 checks, all pass). It runs the real function under Deno against the local stand in, on an isolated database (template zprod3 plus writing cleanup) with reads capped at 1,000 rows:
  - the counts match `zella_module_on`: 1,101, 2 and 0, and another industry's row is not counted;
  - the list counts 1,203 businesses (it said 1,000 before);
  - an unconfirmed switch off is refused and writes nothing, and confirming a different module doesn't count;
  - a confirmed switch off removes Calendar from all 1,101 businesses and is audited with the count and reason;
  - an unused module needs no confirmation;
  - the legacy path works and is flagged;
  - deactivate and reactivate are audited once, existing modules are kept, and creating a business in an inactive industry is refused;
  - read only admin (with `businesses.view` granted) can read the counts but can't save or deactivate (403), a business owner gets 403, anonymous gets 401, an unknown industry gets 404.
  - On origin/main the same script fails 15 checks, which reproduces the gap (for example, the unconfirmed switch off returns 200).
- Deno: `config_test.ts`, 5 tests: permissions and no name clashes, paging past a lower cap, the count rule, the confirmation rule including the legacy flag, and set_active validation and audit. `deno check index.ts` is clean.
- Web: `node --test web/tests/industryModules.test.mjs`, 4 tests.
- `npm run lint`: 0 dashes, and no new warnings in changed files. `npx vite build` passes.

Local browser (stand in, 1440x900 and 390x844, deviceScaleFactor 1, no page errors, no failed calls, no sideways scroll). Screenshots in `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-c/`:
- c1-industry-1440.png, c1-industry-390.png
- c1-confirm-modules-1440.png, c1-confirm-modules-390.png ("1,101 businesses lose Calendar")
- c1-confirm-deactivate-1440.png, c1-inactive-1440.png

No migration.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
