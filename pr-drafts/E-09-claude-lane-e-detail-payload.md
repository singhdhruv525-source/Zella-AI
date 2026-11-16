Business page data v2: readiness, plan, usage, numbers, alerts, go live checklist, routing, deliveries (edge)
base: claude/lane-e-suspended-and-modules

## What and why
One additive revision of `business_detail` (`owner-provision-business/detail.ts`), so the page can show what
REQ-ADM-02 asks for. Every part is read with the server key and reports `{available: false}` on its own when its
table or function is missing (PGRST202, PGRST205, 42P01), so one card never fails the page. The web cards follow in
the Business page web PRs; this PR only adds fields.

| Field | Item | Source | Who gets it |
|---|---|---|---|
| `readiness` | BIZ-11 | `zella_business_readiness` (server branch) | businesses.view |
| `plan` | BIZ-11 | latest `business_plans` row; price, fee, overage and estimate fields removed without billing.view (`planView`) | businesses.view |
| `usage` | BIZ-11 | the current `billing_periods` row and its `allowance_buckets`, counted like `zella_billing_balance` (the appointment message reserve kept apart). **Never** `zella_billing_overview` or `zella_billing_open_period`, which can create a period | businesses.view |
| `numbers` | BIZ-11, UI-08 | `business_phone_numbers`, 20 newest | businesses.view |
| `alerts` | BIZ-11 | unresolved `platform_alerts`, 10 newest and a count | businesses.view |
| `activation` | BIZ-12 phase 1 | `zella_activation_report` and the latest `activation_tests` row | **businesses.manage** |
| `routing` | UI-07 | `routingFrom`, the same output as `zella_admin_routing_get` (which refuses the server key) | businesses.view |
| `deliveries` | COM-03 | `zella_assistant_delivery_status`, the 10 latest `assistant_deliveries` (no provider call id, no numbers), 7 day not_ready and unknown_number counts | businesses.view |
| `members[].last_sign_in_at`, `two_step` | UI-06 part a | the auth account (100 members at most) | **businesses.manage** |
| `activityCount` | BIZ-30 part b | count of the business's audit rows | audit.view |
| `connections` | COM-01 (shared) | lane C's `zella_business_connections(uuid[])` | businesses.view |

`resolveUsers` is no longer used by the page: one `getUserById` per person gives email, last sign in and two step.

## Shared with lane C (critic: shared RPCs)
Uses lane C's signature from `claude/lane-c-connection-state` exactly: `zella_business_connections(p_business_ids
uuid[]) returns table(business_id, business_state, receptionist, phone, phone_numbers, vapi_linked, answering,
last_served_at, calendar, leads, lead_sources, email, problems, live)`. Until that migration is applied the field is
`{available: false}`. The readiness ladder's own voice rung still reads the empty `integrations` table (readiness v2
is deferred, waiting on the owner's "one ladder" decision).

## Critic corrections applied
- **BIZ-12:** the activation report goes to businesses.manage, as the audit item says, not to every businesses.view
  admin. Named constant `ACTIVATION_PERMISSION`.
- **Wider reads before the read audit (critic risk):** the parts added here are the business's own configuration
  (plan, balances, numbers, routing) and counts. Caller data stays out (deliveries carry no call id or number); last
  sign in and two step are limited to businesses.manage until BIZ-22 is decided. The open audit (PR 14) is built in
  this lane's later PR.
- **Production data is empty** (0 plans, periods, numbers, alerts, integrations in zprod3): the tests use seeded
  fixtures; the web cards must explain empty states (web PRs).

## Defaults taken (owner can change)
- `PRICES_PERMISSION = "billing.view"` (BIZ-11 recommended).
- `ACTIVATION_PERMISSION = "businesses.manage"` (BIZ-12 audit row).
- `SIGN_IN_FACTS_PERMISSION = "businesses.manage"` (until BIZ-22).
- `DETAIL_LIMITS = { numbers: 20, alerts: 10, deliveries: 10, members: 100, deliveryDays: 7 }`.

## Deploy order
Edge function only (window A, needs approval). No SQL. Every field is additive; the old web app ignores them.
Rollback: redeploy `owner-provision-business` from the main commit before this PR's merge commit.

## Tests
- Isolated database, `tests/admin_detail/run.sh` (template zprod3, seeded test business with a plan, subscription,
  current period, plan, rollover and reserve balances, a number, an open and a resolved alert, served and not_ready
  deliveries): ALL PASS. Readiness, activation and delivery functions answer the server key; routing refuses it;
  reading them creates no billing period; `routingFrom` equals `zella_admin_routing_get` for the same rules (run as a
  zella_owner admin); `usageSummary` equals `zella_billing_overview`'s included, remaining and reserve remaining for
  minutes, texts and emails (run as an admin with billing.view).
- Automated local: `deno test` 50 passed, 0 failed. New in `detail_test.ts`: prices stripped without billing.view;
  activation and sign in facts only with businesses.manage; usage from the current period's balances with the
  reserve apart and no billing overview or open period call; numbers, open alerts, routing and deliveries without a
  provider call id; a missing table or function marks only its card unavailable; current period and plan helpers;
  routing defaults and fallbacks. `deno check index.ts` passes.
- Local end to end (isolated `zle_ui`, the real function under Deno): `readonly@zella.test` gets no activation
  (`notAllowed`), no sign in facts, no activity total; `ops@zella.test` (businesses.manage, audit.view) gets them;
  only `admin@zella.test` (owner) gets prices; `billing_periods` row count 0 before and after; no read failures logged.
- No browser check: no web change in this PR.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
