<!-- coderabbit-ai-generated:v1 -->

<!-- coderabbit-ai-generated-section:v1:35c3602596f87b0e44de37965982006b0cf3d713b299bc5eb4243698317122ee -->

# CodeRabbit findings from singhdhruv525-source/Zella-AI#48 (remaining tests and root files)

Findings in review order. Dispositions below were verified against the current source; checked items are resolved. Earlier fixes are recorded from source inspection, not a fresh run of every database suite.

- [x] `tests/batch3/run.sh:9` — Parse the pending list as data, as the other runners do. **Disposition:** Already fixed: parses and validates the complete assignment as data without executing it.
- [x] `tests/deploy/run_all.sh:83` — Compare the re-apply result with the first apply, not only with "before". **Disposition:** Already fixed: compares the re-apply state with the saved first-apply state (`after`).
- [x] `tests/industry/presets_v2_check.sh:16` — Call the isolation guard before the drop and the dump. **Disposition:** Already fixed: isolation guard runs before both the drop and dump.
- [x] `tests/setup/make_rollback.py:104` — Resolve `SRC` and `DST` against the repository root, not the working directory. **Disposition:** Already fixed: both reads and writes resolve paths against `ROOT` derived from `__file__`.
- [x] `tests/setup/run.sh:18` — Run the isolation guard in the test runner. **Disposition:** Already fixed: runner invokes the isolation guard before database work.
- [x] `tests/staging/checks.sql:127` — Scope the audit-log cleanup to the plumbing business. **Disposition:** Already fixed: cleanup filters both the plumbing business ID and `charge_created` action.
- [x] `tests/staging/run.sh:17` — Add the isolation guard before the build and the database drops. **Disposition:** Already fixed: isolation guard runs before the build and database drops.
- [x] `tests/vapi/load-test-assistant.mjs:36` — This script changes a live Vapi assistant. Remove it from `tests/` or block it. **Disposition:** Fixed: entrypoint unconditionally refuses; all network calls and configuration loading removed.
- [x] `tests/vapi/switch-credential-to-bearer.mjs:23` — The original script can change the credential ID supplied as an argument and prints the new token; the target is not necessarily the shared production credential. **Disposition:** Already fixed: entrypoint unconditionally refuses; no rotation or token output remains.
- [x] `tests/vapi/test-saloon-assistant.json:11` — Replace the production identifiers in this fixture with obviously fake values. **Disposition:** Already fixed: fixture uses `example.test` endpoints and synthetic credential UUIDs.
- [x] `tests/workflows/industry_matrix.mjs:26` — Guard the server before dropping the test databases. **Disposition:** Already fixed: isolation guard runs before database operations; libpq redirects are cleared.


<!-- /coderabbit-ai-generated:v1 -->