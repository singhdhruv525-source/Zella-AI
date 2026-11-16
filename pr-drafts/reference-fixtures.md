UI-35: reference configuration fixture copied read only from production
base: main

## What

- `tests/fixtures/reference_config.sql`: production CONFIGURATION for local test databases (owner approved 16 Nov 2026: configuration only, never customer data). 28 industries, 280 industry modules, 28 industry configurations, 191 automation defaults, 56 platform message templates, 45 platform settings. Fixed order; idempotent (`on conflict ... do update`, matching on slugs, so it loads onto a schema copy whose industry ids differ from production).
- `tests/fixtures/export_reference.mjs`: the exporter. It documents the allowlist, prints the exact read only SELECTs (`queries`), can run them itself in a read only transaction (`fetch`), and builds the fixture (`build`). It refuses any table, column or setting not on the allowlist, any business_id or created_by column, inactive templates, and any email address, phone number or link in a value.
- `tests/fixtures/load_reference.sh <db>`: loads the fixture only after `tests/lib/isolated_guard.sh` confirms the isolated test server (socket, data directory, test database name); prints the row counts and how many live switches are on.
- `tests/fixtures/reference_guard.mjs`: fails if the fixture holds an email address, phone number, link, any id other than the 28 industry ids, a business_id value, created_by, an excluded setting, or a live switch that is on. It also checks that the exporter refuses what is off the allowlist.
- `tests/fixtures/run.sh`: runs the guard, checks the loader refuses non isolated targets, then loads into a fresh `zfix_reference` copy of `zprod3` twice.
- `tests/browser/crawl-db.sh [db]`: builds the crawl database (a copy of `TEMPLATE`, default `zprod3`) and loads the reference fixture. `tests/browser/README.md` now uses it; `docs/MEMORY.md` records the decision.

## Left out on purpose

- Column checks: none of the six tables has a business_id column except message_templates (exported only where business_id is null, and the column itself is never written). No table has an email, phone or person name column. `message_templates.created_by` holds the user id of the person who wrote the template, so it is left out. Ids (other than industry ids) and timestamps are left to local defaults.
- Platform settings: keys ending in `_url`, `email_from_address`, `sms_from_number` and keys starting with `vapi_`, as the allowlist says. Also every key ending in `_model` or `_model_multilingual` (7 keys), because the rulebook bans model ids in code and fixtures. Every `_live` key (12) and `n8n_dispatch_enabled` (on in production) are written as false, and a final update in the fixture turns off any live switch already in the target database.
- `voice_tts_choices` is kept: those are the voice provider's stock voice names (Burt, Sarah, ...), not people.

## Why

The crawl and journey databases had only the industries seed and hand loaded presets, so pages that depend on modules, automation defaults, platform templates and settings showed fewer items than production. Copying configuration (not data) closes that gap with no customer data and nothing able to send.

## Tests

- Read only production checks (Supabase, SELECT only, allowlisted tables): row counts 28 / 280 / 56 / 28 / 191, and the column check above.
- Local, isolated server: `tests/fixtures/run.sh` passes. The guard passes 26 checks; the loader refuses a network host, a different socket directory and a non test database name. Loading into a fresh `zfix_reference` copy of `zprod3` gives `industries=28 modules=280 platform_templates=56 configurations=28 automation_defaults=191 live_switches_on=0`. A second load changes nothing, and there are no business templates.
- Fidelity check (local versus production): checksums of each table, computed the same way on production (read only) and on the loaded `zfix_` database, all match for industries, modules, configurations, automation defaults, platform templates and settings. Settings are compared after the exclusions, with live switches false.
- `tests/browser/crawl-db.sh zfix_crawl` builds and loads the same counts.
- No web files changed, so no lint or build was needed.

## Deploy order

Nothing to deploy and nothing touches production: test fixtures and scripts only. After merge, rebuild a crawl database with `tests/browser/crawl-db.sh zella_ui` (isolated server).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
