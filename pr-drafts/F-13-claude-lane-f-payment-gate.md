Onboarding: the first payment is required for go live only once payments are live (owner decision)
base: claude/lane-f-plan-change

## What and why
Owner decision relayed by the supervisor (16 Nov 2026): the pay before go live check is off until Stripe is live. While `platform_settings.payments_live` is false (the default), go live doesn't wait for a payment and onboarding screen 6 shows "Payment opens here soon"; once the owner switches payments on (`zella_payments_switch`), "pay before going live" applies.

- `sql/zella_stripe_payment_gate.sql`
  - `zella_onboarding_rules()`: `first_payment` = `pay_before_live` while payments are live, else `not_until_payments_live`.
  - `zella_onboarding_payment_passed(business)`: not required yet, or a bound Stripe payment confirmed (an unbound payments row never counts).
  - `zella_activation_checks`, `zella_request_activation`, `zella_owner_onboarding_complete_step`: use it instead of "a payment confirmed"; `zella_onboarding_payment` adds `required`. Each is changed by an exact text replacement on a known md5 (archived first), so nothing else in those bodies moves.
- Screens: `paymentPassed` treats `required: false` as passed (status stays waiting, label "Payment opens here soon", never "Payment received"); the Pay screen offers Continue with "You can continue now. We'll ask for payment here once it's switched on." The stand in follows the same rule (scenario `payrequired` keeps the old one for tests). `docs/OWNER_ONBOARDING_CONTRACT.md` version 4.
- `tests/browser/owner-onboarding-journey.cjs`: step 6 now expects Continue while payments are off (Payment received after a real payment stays covered by `stripe-pay-screen.cjs`).

## Defaults taken (owner can change)
- Switching payments on applies the rule to every business not live yet, including one already past step 6.

## Deploy order
After step 5 (plan change); with the web app. **Production md5s to be confirmed by the supervisor before apply.**

## Tests
Automated, local:
- `tests/stripe_payment_gate/run.sh`: 17 passed. Before: with payments off, go live still waited for a payment and step 6 couldn't be passed. Apply, apply again, rollback twice, apply again, drift refused both ways. **Off:** rule `not_until_payments_live`; step 6 waiting, payments not connected, not required, never confirmed; gate passes; the owner passes step 6. **On:** rule `pay_before_live`; gate and step 6 wait; required; an unbound row doesn't count; a bound Stripe payment passes both.
- `node --test web/tests/ownerOnboarding.test.mjs`: 20 passed (new: not required passes, label stays "Payment opens here soon", only a real false skips). `npm run lint` 0 errors, 0 dashes; `npx vite build` clean.

Local browser (stand in, deviceScaleFactor 1): `owner-onboarding-journey.cjs` 61 passed, 0 failed (390 and 1440, light and dark); `stripe-pay-screen.cjs` all passed. Screenshots:
- /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-f/onbshots/16-pay-later-phone-light.png
- /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-f/onbshots/16-pay-later-desktop-light.png

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
