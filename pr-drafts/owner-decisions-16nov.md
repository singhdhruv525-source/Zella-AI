Record the owner's decisions of 16 Nov 2026 in the docs
base: main

## What

Docs only. Records the owner's decisions of 16 Nov 2026 in `docs/MEMORY.md` (Decisions) and in `docs/ARCHITECTURE.md` where each requirement lives, plus a new decisions table (§23.1a):

1. **Growth page (REQ-ADM-18, ACC-36): later**, not before launch. Marked in §2 (REQ-ROLE-02), §10.2, §18.5 and D-05. `growth.manage` removed from `docs/PRODUCT.md`'s list of existing permissions (it exists nowhere in the code or database).
2. **Platform wide default receptionist script (AI-GLOBAL-PROMPT): later** (§18.5).
3. **Weekly platform summary report for admins: yes**, being built in `claude/weekly-admin-report` (§18.5).
4. **Billing emails: build now, held** until Stripe and email are live (§14.4).
5. **Audit history is never deleted with a business (ACC-10):** `audit_logs` keeps its rows with `business_id` set to null; the deletion row keeps the business id and name (§7, §20 retention, §29). The migration is still to build.
6. **Production configuration (never customer data) may be copied read only into test fixtures**, through an allowlist (UI-35, §21).
7. **Pay before go live applies only once Stripe is live**; until then the go live gate doesn't wait for payment (REQ-LC-14, REQ-BIL-29).
8. **No public API, API keys or outgoing webhooks:** cross reference to PR #91 (§36).

Also:
- New `docs/MEMORY.md` open problem: Zella Voice's assistant config never sets Vapi's recording option, so Vapi's default decides whether calls are recorded. The owner checks the Vapi dashboard now; a fix on the live call path needs its own approval. (Checked: no recording option is set anywhere in the repo.)
- New "Waiting on the owner" item: once Stripe is live, does a business on a trial go live on its confirmed saved card trial setup (REQ-BIL-12) instead of a first payment?
- `docs/ADMIN_AUDIT_2026-11-16.md` checklist updated to match: billing emails (was "build later"), global default prompt, Growth page, UI-35, first payment.

## Why

The owner made these decisions on 16 Nov 2026. CLAUDE.md asks for decisions to be recorded in MEMORY and for disagreements between documents to be fixed in the same pull request.

## Tests

- Lint (local): `npm run lint` in `web`, check-dashes reports 0 found.
- No code, schema or web changes, so no build, database or provider tests.

## Merge notes

- `claude/weekly-admin-report` changes the same permission line in `docs/PRODUCT.md` (adds `reports.view`). On conflict keep both: keep `reports.view` and leave `growth.manage` out. Its MEMORY bullet goes after the "No public API" bullet, which this PR doesn't touch.

## Deploy order

Nothing to deploy (docs only).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
