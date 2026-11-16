Plans page around each business's own plan: list, details drawer with balances, fallback limits, banner (CFG-14, CFG-15, CFG-18, CFG-19, CFG-21)
base: claude/lane-c-plans-server

This branch merges origin/main at e950754, which brings in the polish agent's Plans change (#89, UI-12) and #85. The docs conflicts were resolved by keeping both sides. Once the earlier Lane C branches are merged, the diff against them is only this PR's files.

## What and why
`web/src/PlansPage.jsx` is rebuilt around `business_plans_list` (C5).
- **Business plans (CFG-14, CFG-21):**
  - every business, a page at a time with a search, showing tier and version ("Pro, version 3 of 3"), price ("$399.00 a year, plus $50.00 setup"), minutes, texts and emails, and subscription status;
  - "No plan saved" when there is none, and never "Unknown plan";
  - the summary line reads "20 of 34 businesses have a plan saved";
  - the old unbounded Subscriptions table is gone.
- **Details drawer (CFG-14 part 2):**
  - every allowance (seats, numbers, locations, languages, extra minute price, trial) and the subscription;
  - this period's dates and balances, from the existing `zella_billing_overview` (`billing.view`);
  - every saved version, from the existing `zella_admin_plan_get`;
  - a note that plans are changed at the business's Plan & pricing step, and an Open business button.
- **Banner (CFG-15):** "Prices are set per business in Create Business, at the Plan & pricing step. Payments aren't connected yet, so nothing here charges anyone." "Pricing not configured" is gone.
- **Fallback limits:**
  - The shared plans are moved into a "Fallback limits" section, which says their limits apply only to a business with no plan of its own, and that their prices aren't used.
  - UI-12's allowance wording is kept.
  - **CFG-18:** "Available for new businesses" is relabelled "Accepted from the payment provider" (Accepted or Not accepted), and the slug is shown as "Payment provider name".
- **CFG-19:** the New shared plan and Edit controls show only with `plans.manage`, which the server checks for `plan_save`. The page reads `me_admin` for this.
- Formatting helpers are in the new `web/src/businessPlans.js`.

**Not done (need migrations; listed for the owner):** CFG-16 (version the shared fallback limits so an edit can't change a live business mid period) and CFG-17 (shared plan prices in minor units and USD only). Neither fitted this lane's time.

## Defaults taken (owner can change)
- **CFG-19 "one permission":** each kind of plan keeps the one permission its server path already checks. Shared fallback plans need `plans.manage` (`plan_save` and `plan_entitlements_save`); each business's own plan needs `billing.manage` (`zella_admin_plan_save`, REQ-BIL-10); reading needs `billing.view`. Moving `plan_save` to `billing.manage` would mean editing `settings.ts` PERMISSIONS, and it was left alone. Recorded in MEMORY.md.

## To confirm
`zella_billing_overview` is the same function the owner's Billing page calls. It may open the current billing period (`zella_billing_open_period`) if none is open yet, so opening the drawer can do that too, exactly as the owner's page would. On the test data no period could be opened, and the drawer said so.

## Deploy order
Web deploy with the owner's approval, after C5's function deploy. No SQL.

## Tests
Automated, local:
- `node --test web/tests/*.test.mjs`: 115 pass, including the new `businessPlans.test.mjs`.
- `npm run lint`: 0 dashes. The only warning in PlansPage.jsx is the pre-existing `load()` in an effect.
- `npx vite build` passes.
- On this branch, every Lane C DB and function test passes: industry_modules, connection_state run and pages, agent_delivery_admin, plans_list. Deno has 36 passing and `deno check` is clean.

Local browser (stand in; 1440x900 and 390x844, deviceScaleFactor 1; no page errors, no failed calls, no sideways scroll):
- No "Unknown plan" and no "Pricing not configured" anywhere.
- The Test Plans 01 row reads "Pro, version 3 of 3 · $399.00 a year · 900 minutes · 200 texts · 200 emails · Active".
- The drawer lists every allowance and the three saved versions.
- With a shared plan present, the Zella Voice owner sees New shared plan and Edit. A read only admin with only `billing.view` and `businesses.view` sees neither.
- Screenshots in `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-c/`: c5-plans-1440.png, c5-plans-390.png, c5-plans-readonly-1440.png, c6-plan-drawer-1440.png, c6-plan-drawer-390.png, c6-plan-drawer-readonly-1440.png.

No migration.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
