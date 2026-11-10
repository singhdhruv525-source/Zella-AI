# CodeRabbit findings from singhdhruv525-source/Zella-AI#47 (browser, feature, security and voice-reliability tests)

Fix list, in the order CodeRabbit posted them. CodeRabbit fixes them on this branch; each fix is checked and re-reviewed before merge.

- [ ] `tests/browser/appearance-save.cjs:129` — Fix the operator precedence in this assertion.
- [ ] `tests/browser/brand-check.cjs:20` — Add the isolated-database guard before `look()` writes to `auth.users`.
- [ ] `tests/browser/industry-journey.cjs:16` — Guard the database target before the first write.
- [ ] `tests/browser/local-backend.mjs:17` — Verify the isolated cluster before the stand-in serves requests.
- [ ] `tests/browser/local-backend.mjs:432` — Bind the stand-in to loopback and restrict CORS to trusted origins.
- [ ] `tests/browser/record-files-e2e.mjs:18` — Guard the database target before writes.
- [ ] `tests/browser/ui-journeys.cjs:15` — Add the isolated-database guard before the template and `auth.users` writes.
- [ ] `tests/browser/wizard-journey.cjs:13` — Add the isolated-database guard before the verification-document, hours and invitation inserts.
- [ ] `tests/features/status_test.sql:75` — Make the anonymous-read check fail when it is false.
- [ ] `tests/security/batch1/run.sh:15` — Print the "applies twice" PASS only when both runs succeed.
- [ ] `tests/voice-reliability/mock-rest.mjs:21` — Quote or validate the argument names before you build the SQL.
- [ ] `tests/voice-reliability/transfer_test.sql:49` — Turn the "model is no longer told the number" check into an assertion.
