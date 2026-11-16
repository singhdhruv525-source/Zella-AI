Admin polish: wizard step bar, plan allowances in words, one group name
base: main

<!-- Already open as PR #89 (https://github.com/singhdhruv525-source/Zella-AI/pull/89). Pushed head 817c904 has CodeRabbit success and 0 unresolved threads. A local merge of origin/main (commit 5f13ebe, audit table conflict resolved keeping both rows) is in /home/user/singhdhruv525-source/wt-ui3 and is NOT pushed. -->

Screen only fixes from the admin audit's visual pass (`docs/ADMIN_AUDIT_2026-11-16.md`) on the Create business wizard, Plans and Offers. No server, SQL or permission change.

## What and why

**UI-30: Create business wizard.**
- The step bar overflowed at 1440 px: step 10, Review, was cut off with no cue. The ten steps now sit in two even rows of five (CSS grid in `CreateBusinessWizard.css`), so every step is visible at 1440 and 1280 px; a long name is ellipsized only if a column gets very narrow. Below 700 px, where only the current step shows its name, the numbers wrap onto a second row instead of scrolling out of sight.
- Back was already disabled on step 1 but still drawn; it is now hidden there too (`visibility: hidden`, so the footer keeps its layout and the button is out of the tab order and the accessibility tree). From step 2 it shows as before.
- The time zone search said "like Kolkata or +05:30" for a US launch; it now says "like Chicago" (`TimeZoneSelect` in `formFields.jsx`, so Settings, Localization gets the same hint). Typing "los angeles" still finds America/Los_Angeles.

**UI-12 (screen part): Plans.** Cards showed raw keys ("languages: 2") and only what the plan's `limits` happened to hold. A label map, `web/src/copy/planAllowances.js`, now lists every allowance on each card in words and in a fixed order: AI voice minutes, texts, emails, phone numbers, team seats, locations, languages, automations and integrations ("No limit" when empty, as the plan entitlements form defines it), then reporting, support level and onboarding when set, then any other key the page receives, in words. `texts` and `sms_messages` show as one line. Features read "Included" or "Not included". The heading is "Allowances". The page still uses only `plans_list`; showing the per business plans that are live (CFG-14) needs server work and is not part of this PR.

**UI-13: Offers.** The eyebrow said "Growth" while the menu puts the page under Configuration; it now says "Configuration". Plans had the same mismatch ("Billing" under Configuration) and now says "Configuration" too, like Industry configuration and Modules & features.

**Same pages, found while there:** Offers had hyphens in text: "win-back" (the payment banner), "Claim-to-paid" and "view-to-claim" (Reports tab). Plans showed "None" for an empty billing interval; it now says "Not set" (and a set one is shown through the shared labels, "Monthly").

## How it was tested

Local browser check against the stand in backend (`tests/browser/local-backend.mjs` with the real `owner-provision-business` code under Deno) over an isolated test database made from template `zcrawl` (`zui_polish`), signed in through the real sign in page as `admin@zella.test`. Nothing was sent and nothing touched production.

- Plans, Offers and the wizard at 1440 by 900 and 390 wide, device scale 1, before and after; the wizard also at 1280 by 720. No page errors, no failed requests, no sideways page scroll. Measured at 1280 and 1440: the step bar's content width equals its box (nothing hidden), the Review step ends inside it, and Back on step 1 is disabled and hidden.
- `tests/browser/wizard-journey.cjs` against this build and database: the first 18 checks pass (draft save, stepper states, unsaved changes dialog with focus trap and Escape, Discard, Save, server refusing to finish without hours). It then stops at a fixture step that inserts an invitation for a fixed admin id that the `zcrawl` template doesn't have (a foreign key error in the test's own SQL, not in the app).
- `npm run lint`: 0 dashes; 220 warnings, the same as `main`.
- `npx vite build`: builds.
- `node --test web/tests/*.test.mjs`: 103 of 103 pass, including the new `planAllowances.test.mjs`.

## Before and after

- Wizard: before, one row of steps cut off after "Plan & pricing", the time zone hint "like Kolkata or +05:30", a greyed Back on step 1; after, two rows of five with Review visible, "like Chicago", no Back on step 1.
- Plans: before, "LIMITS: languages: 2" and nothing else; after, "ALLOWANCES" with nine lines in words ("Languages the receptionist speaks: 2"), and the eyebrow "Configuration".
- Offers: before, eyebrow "Growth" and "win-back"; after, "Configuration" and "win back".

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
