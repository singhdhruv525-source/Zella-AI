Business onboarding: mark drafts abandoned after 30 days without changes, and alert once (BIZ-13b)
base: claude/lane-b-draft-delete

## What and why

**BIZ-13b (D-30).** ARCHITECTURE.md said "Abandoned drafts expire [D-30]", but nothing flagged or expired a draft, and Business onboarding showed no age. This PR builds the supervisor's chosen default, which is the recommended answer: flag drafts untouched for 30 days as Abandoned, alert once, and never delete anything automatically.

- `lifecycle.ts` `draftAges()`:
  - **last change** is the later of the business row's `updated_at` and its newest audit entry (every setup save is audited);
  - a draft whose last change is older than `draft_abandon_days` (default `DRAFT_ABANDON_DAYS_DEFAULT = 30`; a stored value is used only if it is between 7 and 365) is **abandoned**;
  - for each newly abandoned draft it raises one `draft_abandoned` alert (info) through `zella_platform_alert`, **once ever per business**. It checks for any earlier alert of that kind, resolved ones included. Alert errors are logged and never fail the page.
- `settings.ts` `onboarding_overview` (Lane B owned) returns `last_activity_at`, `abandoned` and `abandon_days`. The helper comes in through the settings kit from index.ts, because `web/tests/tenantSearch.test.mjs` loads settings.ts without its imports.
- `index.ts`: `draft_abandon_days` is **appended** to `EDITABLE_SETTINGS` (7 to 365), as the supervisor asked. The kit passes `draftAges`.
- Web:
  - the Onboarding panel shows a "Last change" column ("40 days ago") with an **Abandoned** pill, and says in the card text that nothing is deleted automatically;
  - Settings, Operational rules lists the new setting under Onboarding and trials. Until the row exists it shows the default 30, through a small `UNSET_DEFAULTS` map, and saving creates the row (the save already upserts);
  - the label is added to `web/src/copy/settingLabels.js`;
  - helpers are in `web/src/businessLifecycle.js`.

**Honest limit:** the alert is raised when Business onboarding is opened. No scheduled job runs it yet, because adding one would mean replacing a schedule function owned elsewhere. This is written in MEMORY.md.

## Defaults taken (owner can change)
- 30 days without changes marks a draft Abandoned (`draft_abandon_days`, 7 to 365). It raises one alert ever per business, and **nothing is deleted automatically**. A person uses Delete draft (BIZ-13a).
- "Last change" = the business row's own change or its newest audit entry.

## Deploy order (each step needs the owner's approval)
1. `owner-provision-business`.
2. Web app.

There is no migration. Without the platform setting row, the code uses 30.

## Coordination
Stacked on `claude/lane-b-draft-delete`, which owns the Onboarding panel file. The AdminPanels.jsx change is 4 lines in OperationalRules and OPERATIONAL, which PR #88 doesn't touch. The settingLabels.js change is one appended line.

## Tests
- **Deno** (`lifecycle_test.ts`, 2 new, 12 in the file; the whole function 40 passed):
  - a draft untouched for 40 days is abandoned;
  - a draft with a recent audit entry is not, and neither is a new draft;
  - the last change uses the newest audit entry;
  - exactly one alert is raised, with the right kind, business and dedupe key;
  - an existing alert (even a resolved one) means none is raised;
  - the setting of 14 days is used, and 3, 1000, a word or null fall back to 30;
  - an alert failure doesn't fail the page;
  - an empty list makes no query for ages.
- **Web unit** (`web/tests/businessLifecycle.test.mjs`): the delete roles, and the "Today", "Yesterday", "31 days ago" and "Not known" wording. `node --test web/tests/*.test.mjs`: 106 passed.
- `deno check index.ts`, `npm run lint` (0 dashes) and `npx vite build` all pass.
- **Local browser** (1440x900 and 390x844, deviceScaleFactor 1, real page and function against an isolated DB): 13 checks, all passing, no page errors. They cover:
  - a draft last changed 40 days ago shows "40 days ago" and Abandoned, and a recent draft doesn't;
  - one alert is raised, and opening the page again leaves it at one;
  - nothing is deleted;
  - the setting shows on Operational rules with 30;
  - no sideways scroll.
  The draft delete journey from the PR below was re-run on this branch, and all 19 checks pass.
  Screenshots: `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-b/shots/b13b-abandoned-1440.png`, `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-b/shots/b13b-abandoned-390.png`, `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-b/shots/b13b-setting-1440.png`.

No migration, so there are no md5s to confirm.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
