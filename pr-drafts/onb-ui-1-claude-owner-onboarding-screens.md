Owner onboarding journey: the seven screens, wired to the contract
base: main

Already open as PR #90 (https://github.com/singhdhruv525-source/Zella-AI/pull/90). Head: claude/owner-onboarding-screens at 0897ec9.

## What this is

The screens of the owner onboarding journey (`docs/ADMIN_AUDIT_2026-11-16.md`, "Add on task: owner onboarding journey"): what a business owner sees after opening their invitation, at `/welcome/setup`. The server side is the separate backend job (`claude/owner-onboarding-backend`); the screens call exactly what `docs/OWNER_ONBOARDING_CONTRACT.md` **version 2** lists (version 2 only clarified: `MFA_REQUIRED` from the request check is handled by asking for the code, `NOT_ALLOWED` for an unknown business), and the database decides every rule (`NN-6`). Nothing is applied, deployed or switched on.

## Screens built

| # | Screen | What it does |
|---|---|---|
| 1 | Welcome | Business name and the six steps ahead. `/welcome` opens the journey for an invited owner when `zella_owner_onboarding_list` has one waiting (after `zella_accept_my_invitations`, as the contract says); anything else (staff invitations, not deployed, an error) keeps today's password page, so invitations always work |
| 2 | Password and two step sign in | Password (existing `PasswordField` / `ConfirmPasswordField`), then the authenticator through a new shared `AuthenticatorSetup` component on the same `mfa.js` calls the admin set up uses. The parts follow `state.security`. Admin sign in (`App.jsx` `mfasetup`) and Settings `MfaCard` are unchanged |
| 3 | Check your details | Business, hours and services, team, AI receptionist and phone, one part at a time, Looks right or Change. Change sends a note to the Zella Voice team (`zella_owner_onboarding_section`), as contract §5.4 says; "Changed, check again" comes back with the team's note. Only Looks right on all four finishes the step |
| 4 | Verify your identity | Documents needed, Checking, Verified, Try again, In review, as the server says. Manual upload of the same documents as the Create Business wizard (same kinds, types, 10 MB limit, same private bucket by one time upload link) through `owner-onboarding`. Polls every 30 seconds while checking. One reserved place (`IdentityProviderSlot`) for a provider widget, empty while `rules.identity_provider` is `none` |
| 5 | Your plan | Tier, price, setup fee, minutes, texts, emails, seats, numbers, locations, languages, exactly as saved; accept only (no switching). `PLAN_CHANGED` reloads the new plan |
| 6 | Pay | "Payment opens here soon" (or "Payment opens after verification"); never a fake success. "Payment received" only when `payment.status` is `confirmed` |
| 7 | You're all set | Test call, going live, the server's go live checks, and Open my CRM (completes step `done`) |

On every screen: progress bar (step n of 7, `role="progressbar"`), Finish later (`zella_owner_onboarding_finish_later`; coming back calls `..._resume` and lands on `current_step`; the CRM shows owners a "Finish setting up" banner while the journey isn't finished), loading, error, empty and "This step isn't ready yet" states, phone first layout that also works on desktop, Classic and Glass (dark) looks, and focus moving to each new step's heading. Finish later is hidden on the last screen, where there is nothing left to finish.

Error codes are shown as the contract's words (§4), never raw codes.

## Graceful degradation

A call that isn't deployed (PostgREST `PGRST202`, or the edge function's 404) reads as "This step isn't ready yet", never a crash. So this can merge before or after the backend PR: until it is deployed, `/welcome` behaves exactly as today and `/welcome/setup` says the setup isn't switched on yet.

## Waiting on

- **Backend:** the `zella_owner_onboarding_*` functions and the `owner-onboarding` edge function (branch `claude/owner-onboarding-backend`), then their deploy, which needs the owner's approval.
- **Stripe:** Checkout and the payment webhook (step 4 of billing). Screen 6 shows the waiting state until then.
- **Identity provider:** an owner decision (Persona, Stripe Identity, or manual upload). Manual upload is the working path.

## Requests for the contract

Small, none blocking; also in `docs/OWNER_ONBOARDING_SCREENS_NEEDS.md`:
1. Confirm `hours[].weekday` is `business_hours.weekday`, 0 = Sunday (as the CRM's hours page uses it). The screens read it that way and list Monday first.
2. Whether `services[].duration` and `price` are always display text.
3. For Stripe: the states between `waiting` and `confirmed`, and how the screens open Checkout.
4. For a provider: what the screens need to start its check.

## Tests

Automated, local:
- `cd web && node --test tests/ownerOnboarding.test.mjs`: 17 tests, all pass. Resume at the server's step, progress, the security parts, section, identity and payment state mapping (nothing unknown reads as Verified or Payment received), error words, not ready detection, and a whole journey through the stand in with the server's gates (`STEP_LOCKED`, `SECURITY_INCOMPLETE`, `SECTIONS_NOT_CONFIRMED`, `UPLOAD_NOT_ALLOWED`, `IDENTITY_NOT_VERIFIED`, `PLAN_CHANGED`, `PAYMENT_NOT_CONFIRMED`), Finish later and a new page load, try again twice to In review.
- Every other `web/tests` and `web/src/*.test.mjs` file still passes.
- `npm run lint`: no errors, `check-dashes: 0 found`. `npx vite build`: builds; the production build contains no stand in (checked by grepping the output).

Local browser (Playwright, against a local preview built with `VITE_ONBOARDING_FAKE=1`, a stand in that answers in the contract's shapes and rules; no database, nothing sent, every request to Supabase refused and counted):
- `tests/browser/owner-onboarding-journey.cjs`: 60 checks, all pass. Every screen in order, at 390 wide and 1440x900, in Classic and Glass; focus on each new heading; wrong authenticator code refused; Looks right and Change; Finish later then a reload lands on the same step; the team's change comes back to check; uploads, Try again with the reason, Verified; the plan; Pay waiting with no Continue and no "Payment received" until the server confirms; Back; Open my CRM; no sideways scroll; no page errors; no Supabase calls during the journey; and the not deployed, failed load (with retry), nothing waiting, upload not deployed and returning owner states.

Checked by reading the backend branch: every database function name and argument name the screens call, and every state field they read, exist in `sql/zella_owner_onboarding.sql` and the `owner-onboarding` function as written.

Not tested: the screens against the real database functions and edge function running (on the backend branch, not merged), staging, or a real provider.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
