# CodeRabbit findings from singhdhruv525-source/Zella-AI#48 (remaining tests and root files)

Fix list, in the order CodeRabbit posted them. CodeRabbit fixes them on this branch; each fix is checked and re-reviewed before merge.

- [ ] `tests/batch3/run.sh:9` — Parse the pending list as data, as the other runners do.
- [ ] `tests/deploy/run_all.sh:83` — Compare the re-apply result with the first apply, not only with "before".
- [ ] `tests/industry/presets_v2_check.sh:16` — Call the isolation guard before the drop and the dump.
- [ ] `tests/setup/make_rollback.py:104` — Resolve `SRC` and `DST` against the repository root, not the working directory.
- [ ] `tests/setup/run.sh:18` — Run the isolation guard in the test runner.
- [ ] `tests/staging/checks.sql:127` — Scope the audit-log cleanup to the plumbing business.
- [ ] `tests/staging/run.sh:17` — Add the isolation guard before the build and the database drops.
- [ ] `tests/vapi/load-test-assistant.mjs:36` — This script changes a live Vapi assistant. Remove it from `tests/` or block it.
- [ ] `tests/vapi/switch-credential-to-bearer.mjs:23` — This script rotates the shared production Vapi credential and prints the new secret.
- [ ] `tests/vapi/test-saloon-assistant.json:11` — Replace the production identifiers in this fixture with obviously fake values.
- [ ] `tests/workflows/industry_matrix.mjs:26` — Guard the server before dropping the test databases.
