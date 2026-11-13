# Zella Voice: conformance check against the architecture and the rulebook (13 Nov 2026)

**What was checked:** the rules in `ZELLA_VOICE_RULES.md` and the architecture in `docs/ARCHITECTURE.md` and
`docs/PAYMENTS_ARCHITECTURE.md`, against the code on branch `claude/bold-pasteur-efhksy` (PR #59). Where a rule
can be checked mechanically, it was checked across the whole system:

- **Database:** an isolated full build equal to production plus PR #59's billing migration (`zui`, isolated test
  server only). Every public function, table, view, policy, grant, column and foreign key was queried.
- **Code:** every edge function and the web app, by search.
- **Billing:** the payments design was compared line by line with the built billing code
  (`PAYMENTS_ARCHITECTURE.md` §17).

**What was not re-checked here:** each product feature's behaviour (`REQ-*` one by one). Their honest status is kept
in `docs/PRODUCT.md`, from the tests run when each was built. This check did not re-run those tests.

**Evidence kind:** the database and code checks are local (isolated database and repository). Nothing was run
against production; nothing was deployed.

## Summary

| Result | Count |
|---|---|
| Rules checked mechanically and passing | 14 |
| Gaps fixed in this PR | 5 |
| Gaps that need their own PR (and, where live, the owner's approval) | 11 |

## Passing (checked across the whole system)

| Rule | Check | Result |
|---|---|---|
| `SEC-5` | every `security definer` function pins `search_path` | 0 without it |
| `SEC-5` | definer functions callable by signed-in users start with an authorisation check | 360 checked; the 36 without an obvious check delegate to a checking helper (`zella_admin_require`, `zella_workflow_record`, `zella_inbox_conv`) or are read-only helpers used by policies |
| `SEC-6` | functions callable without sign-in are few, small and free of tenant data | 26: pure helpers, public status, unsubscribe, MFA check (rate limit on unsubscribe: gap G-7) |
| `SEC-8` | row security on every table | 0 tables without it |
| `SEC-8` | no write grants to the public role | 0 |
| `SEC-8` | no "allow everything" write policy | 0 |
| `SEC-10` | views with tenant data enforce membership inside | `calls_view`, the only definer view, filters on membership, module and MFA and masks call content |
| `DB-10` | all times are `timestamptz` | 0 `timestamp without time zone` columns |
| `NN-2` | no secrets in the repository | 0 matches for live or test keys, signing secrets, JWTs, private keys |
| `NN-9` | no card data | no card fields anywhere; billing design keeps card entry on Stripe's pages |
| `BE-6` | every edge function type-checks | 11 of 11 (`check.sh`), unit tests pass for the changed ones |
| `SEC-11` | public entry points authenticate first | session, signature or signed link checked before reads or writes in every function |
| `DB-4` | migrations have tested rollbacks | billing: rollback, re-apply and index ownership tested (33 checks) |
| Tests | database tests run only on the isolated server | every script that builds through `tests/lib/build_full.sh` or `sql/baseline/restore.sh` is guarded (gap G-10 for the rest) |

## Fixed in this PR

| # | Rule | Gap | Fix |
|---|---|---|---|
| F-1 | `BE-3` | `store-connect` (3 calls) and `calendar-connect` (2 calls) called Supabase or the calendar provider with no timeout | 10-second timeouts with a safe "try again" answer; type-checked and unit tests pass |
| F-2 | `DB-15` | 7 foreign keys in the unapplied billing migration had no index | indexes added; 33 billing checks pass, including rollback and re-apply |
| F-3 | `PRV-7` | `owner-provision-business` logged the provider's whole error object | logs only the error name and status |
| F-4 | `NN-12` | the dev container was named "Zella AI" and "Zella app" | "Zella Voice" |
| F-5 | `NN-12` | a page named the n8n workflow "Zella - Spam Response" | "the spam response workflow" (the live workflow names are G-5) |

## Gaps that need their own PR

| # | Rule | Gap | Proposed fix | Needs approval to go live |
|---|---|---|---|---|
| G-1 | Billing | the deployed `billing-webhook` doesn't follow the Stripe design (`PAYMENTS_ARCHITECTURE.md` §17, C-1 to C-8) | rebuilt in step 4; `STRIPE_WEBHOOK_SECRET` stays unset until then | yes |
| G-2 | `DB-15` | 38 foreign keys on existing tables have no index (for example `customer_consents(business_id)`, `record_inspections(business_id)`, `table_events(business_id)`, `usage_records(adjusts_record_id)`) | one new migration with `create index concurrently if not exists` for each, tested on the isolated copy | yes (production migration) |
| G-3 | `DB-11` | money in `numeric`, not integer cents: `plans.price_monthly`, `plans.price_yearly`, `payments.amount`; per-minute `voice_pricing.unit_cost` | expand, then contract: add `*_cents` / micro-unit columns, move readers, then drop (`DB-6`); billing step 2 already uses cents | yes |
| G-4 | Rulebook (no model IDs) | three production functions carry a model ID as a default (`call_intel_model`, `knowledge_ai_model`, `voice_llm_model` in `sql/baseline`) | defaults read only from `platform_settings`, with no fallback in code | yes |
| G-5 | `NN-12` | live n8n workflows are named "Zella - …" (Spam Response, Review Replies, Email Events, Meta Sender, Website Crawler, Receptionist Brain, …) | rename to "Zella Voice - …" in n8n and in `n8n/` sources | yes (live workflows) |
| G-6 | `SEC-12` | `continue-plan`, `calendar-connect` and `store-connect` have no rate limit (signed-in owner endpoints) | call `zella_rate_limit` per user and business before the work | yes (deploy) |
| G-7 | `SEC-6` | the public unsubscribe functions have no rate limit (already in `MEMORY.md`) | rate limit per token and per IP | yes |
| G-8 | `TEN-1` | six business-owned tables have no `business_id` (already in `MEMORY.md`) | add and backfill, then policies on it | yes |
| G-9 | `BIZ-10` | industry branches inside database functions (already in `MEMORY.md`) | move to industry configuration | yes |
| G-10 | Tests | `tests/features/run.sh` and three `tests/voice-reliability/` scripts use another local cluster (`/var/tmp/zella-pg`) that the isolation guard doesn't accept, so they run without it | extend the guard to that cluster, or move them to the isolated server | no (tests only) |
| G-11 | `DB-7` | headers of a few applied migrations still say "Zella AI" (`zella_tenant_links.sql`, `zella_offers.sql`) | left as they are: applied migrations are never edited; comments only | — |

## Order proposed

1. Merge PR #59 (this check, the billing step 2 and 3 work, the payments design).
2. A tests-only PR for G-10.
3. One migration PR for G-2 (indexes) and one for G-4 (model defaults), each with a rollback, tested on the
   isolated copy; applied only with the owner's approval.
4. G-6 and G-7 (rate limits) in one PR; deployed with approval.
5. G-3 (money columns) as expand-then-contract over two releases.
6. G-5 (workflow names) when the owner approves touching live workflows.
7. G-1 is step 4 (Stripe), after the owner's account checklist.
