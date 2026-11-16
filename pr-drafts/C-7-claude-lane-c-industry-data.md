Industry data: sensitive flag, booking model and default automations stored per industry (CFG-05 part 1, UI-28 data)
base: claude/lane-c-plans-server

## What and why
A new industry got only words and modules. Three things were lists in the code:
- whether it is sensitive: a slug list inside `zella_sensitive_industry`, so a new medical industry would show transcripts to staff;
- its default automations: a map by name in `web/src/industryAutomations.js`, falling back to the base set;
- the receptionist's industry safety lines: a CASE in `zella_brain_prompt_base`.

Nothing stored a booking model.

`sql/zella_industry_data.sql`:
- Adds `industries.sensitive` (default true) and `industries.booking_model` (a checked list of the PRODUCT.md §6 models).
- Adds `industry_configurations.automation_defaults` (a jsonb object) and `industry_configurations.safety_rules` (text).
- **Seeds on the first apply exactly from today's values:**
  - the same seven sensitive slugs;
  - the booking model per slug from PRODUCT.md §6;
  - the automation map by normalised name (generated from `automationDefaultsFor`);
  - each industry's safety lines, from the CASE text plus the two later legal and healthcare lines, worked out through `zella_industry_key_for`'s rule on **the database it runs on**, so production gets production's lines.
- `zella_sensitive_industry` now reads the column. It keeps production's access check: it answers only for server code, a member of the business, or a top platform admin, and anyone else gets false. It is archived first and checked against production's version (md5 ad2e363e…, the version the supervisor read). A rerun seeds nothing, so later edits survive.

owner-provision-business:
- `industriesList` returns `sensitive`, `bookingModel`, `automationDefaults`, `industryData` and `bookingModels`. Before the migration it returns `industryData: false` instead of failing.
- `industrySave` saves `bookingModel` (from the list) and `automationDefaults` (validated: known shape only), only when the page sends them, and audits them.
- `industryCreate` with "copy from" also copies the booking model, defaults and safety lines. A new industry always starts sensitive.
- New, in config.ts:
  - `industry_set_sensitive` (`platform.configure`, **Zella Voice owner only**, a reason, `confirm: true` to turn it off, audited as `industry.sensitive_on` or `industry.sensitive_off`);
  - `industry_automation_defaults` (`businesses.view`): a **separate action, as agreed; `setup_load` is unchanged**, because it feeds `business_detail`.

Industry configuration:
- A "Privacy and booking" section: a Sensitive pill, and Turn off or Turn on for the Zella Voice owner only. Turning off asks for a reason and the typed words TURN OFF.
- A booking model select.
- A "Default automations" editor: switches per automation, saved with the industry.

## UI-28 and the wizard (C8), not done here
- **UI-28:** the defaults are now data, exposed by `industry_automation_defaults` and `industries_list.industries[].automationDefaults`. `web/src/admin/AutomationsPage.jsx` belongs to Lane D and the polish agent, so it isn't edited. **Note for Lane D:** list every default automation from `industry_automation_defaults` (or `industries_list`), with industry names from `industries_list`.
- **C8, the wizard using server defaults:** `CreateBusinessWizard.jsx` belongs to Lane B (B1, not merged), so it isn't edited. `industryAutomations.js` stays as the fallback. The test that the server defaults equal `automationDefaultsFor` for every industry is included here: `web/tests/industryDefaultsSeed.test.mjs`.

## Defaults taken (owner can change)
- **Who may change sensitive:** the Zella Voice owner only (`SENSITIVE_ROLE` in config.ts), with a reason and an audit row. Turning it off needs a typed confirmation. This is the CFG-05 owner decision's recommended answer.
- **A new industry starts sensitive** (the column default), with no booking model and the base automations.
- **The seed should be checked against the reference configuration once UI-35 is decided.** The test template has only 2 CRM presets, so only cleaning and insurance get safety lines there. Production's presets decide production's lines, and the seed works them out on apply.

## Deploy order (each step needs the owner's approval)
1. Apply `sql/zella_industry_data.sql`. Behaviour is identical, because the seed equals today's values.
2. Deploy `owner-provision-business`. If it goes before the migration, it leaves the industry data out and every save still works.
3. Deploy the web app.
- The receptionist doesn't read `safety_rules` until C9 (`sql/zella_brain_safety_rules.sql`), which needs its own approval.
- Rollback: deploy the earlier function, roll back C9 if applied, then `sql/rollback/zella_industry_data_rollback.sql`.

## Tests
Automated, local, on isolated databases (zprod3, writing cleanup, admin_permissions, admin_mfa, then this):
- `tests/industry_data/run.sh`, 23 checks, all pass. Production's `zella_sensitive_industry` (`tests/industry_data/production_zella_sensitive_industry.sql`) is loaded first, so the "before" state is production's:
  - the gap is reproduced first: a new medical industry is not sensitive;
  - apply, then apply again;
  - `zella_sensitive_industry` gives the same answer for every business before and after, and production's access check is kept (a member gets true, a stranger false);
  - exactly the seven slugs; 28 booking models; 28 automation sets; the plumbing defaults;
  - for each of the 26 industries with safety lines, the seeded text is found verbatim in that business's prompt today; other and professional services have none, as today;
  - an edit made after the first apply survives a rerun, and the server reads the column;
  - a new industry starts sensitive, while an industry that existed before keeps today's answer;
  - a bad booking model is refused;
  - rollback twice restores the function and grants exactly and drops the columns;
  - reapply; ROLLBACK_DRIFT; VERSION_MISMATCH.
- `tests/industry_data/function.sh`, 25 checks, all pass, with production's definition loaded first. It runs the real function under Deno against the stand in:
  - before the migration, `industryData` is false, an old save works, and the defaults read "not available";
  - after it, the list carries the data;
  - sensitive: a super admin, read only admin, business owner (403) and anonymous (401) are refused; a reason is needed; turning it off without confirmation gets 409 with the transcripts warning, and refused calls write nothing; the owner turns it off and the transcript rule follows; it is audited once with the reason, and a repeat writes nothing;
  - booking model and defaults save; bad ones are refused; read only can't save but may read the defaults;
  - a copy takes the data and starts sensitive; an empty new industry starts sensitive with the base automations.
- Deno `config_test.ts`, 10 tests (the whole suite is 38), including the automation defaults validation and the sensitive role and confirmation. `deno check index.ts` is clean.
- `node --test web/tests/*.test.mjs` passes, including `industryDefaultsSeed.test.mjs`: the seed equals `automationDefaultsFor` for all 28 industries.
- `npm run lint` 0 dashes; `npx vite build` passes.
- Every earlier Lane C test passes on this branch.

Local browser (stand in; 1440x900 and 390x844, deviceScaleFactor 1; no page errors, no failed calls, no sideways scroll):
- Dental shows Sensitive and Turn off. Booking model and the Waitlist offers switch save (database: consultation, waitlist off).
- The Turn off dialog explains that staff may then read transcripts, asks for a reason and TURN OFF, and the pill then reads Not sensitive.
- A read only admin sees "Only a Zella Voice owner can change this".
- Screenshots in `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-c/`: c7-privacy-1440.png, c7-privacy-390.png, c7-privacy-readonly-1440.png, c7-sensitive-dialog-1440.png, c7-automations-1440.png.

## Production md5s
- The guard needs `zella_sensitive_industry(uuid)` to be either:
  - production's version, md5 ad2e363ec6fa112404cc2710cc7132e4 (the supervisor read it, and loading `tests/industry_data/production_zella_sensitive_industry.sql` into zprod3 reproduces it); or
  - this file's version, be26e6cd036052ebd206de5573fed180.
- The rollback restores production's version from the archive. This was tested: it gives md5 ad2e363e… again.
- Any other version stops the file (VERSION_MISMATCH), including the template's older 7a6c1c0c….
- The production md5 was confirmed by the supervisor before apply.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
