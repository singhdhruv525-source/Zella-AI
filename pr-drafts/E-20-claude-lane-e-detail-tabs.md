Business page: one file per tab, tabs in the address, accessible keyboard tabs (web only)
base: claude/lane-e-drop-detail-calls (this branch also merges claude/admin-businesses-list: open it after the Businesses list PR merges)

## What and why
Plan PR 2 (lane E order). Web only.

**BIZ-30 part a.**
- `BusinessDetails.jsx` is now the page shell (header, banners, confirm dialog, tabs). Each tab moved **unchanged**
  into `web/src/business/OverviewTab.jsx`, `ConfigurationTab.jsx`, `PeopleTab.jsx`, `ReceptionistTab.jsx`,
  `PhoneTab.jsx`, `AutomationsTab.jsx`, `CallsTab.jsx`, `ActivityTab.jsx`; shared pieces (Card, Facts, Empty, Check,
  labels) in `business/shared.jsx`. The move was done by a script (only indentation and imports change); review the
  tab files with `git diff --color-moved`.
- Tabs are in the address: `/businesses/<id>/<slug>` (`business/tabs.js`: overview, configuration, people,
  receptionist, phone, automations, calls, activity; one word, no dashes). `readRoute` (OwnerDashboard.jsx, three
  lines plus the props block) returns `detailTab`; `/businesses/<id>/setup` still opens the wizard; an unknown slug
  shows Overview. Changing tab replaces the history entry.
- WAI-ARIA tabs: labelled tablist, `aria-controls`, a `tabpanel` labelled by its tab, roving `tabIndex` (one tab
  stop), ArrowLeft and ArrowRight wrap, Home and End.

**UI-34.** On a phone the tab row's edges fade into `--zella-bg` and the open tab is scrolled into view
(`business/businessDetail.css`, tokens only).

## Deviations from the plan (and why)
- The shared `Tabs` in `admin/adminOps.jsx` is not changed: it is on the open polish branch (PR #88), and changing it
  would touch every ops page. The accessible pattern lives in the business page shell; adminOps can adopt it later.
- "See all in Audit logs" (`/audit-logs?business=<id>`) is not added: `AuditLogs.jsx` belongs to lane A (ACC-12), which
  adds the business filter. The Activity tab keeps its 30 newest rows and the total comes in the payload (PR 9).

## Defaults taken (owner can change)
- UI-34: an edge fade (recommended), not a select on phones.

## Deploy order
Web only; safe with every edge version (no new fields read). Merge after the Businesses list PR.

## Tests
- Automated local: `node --test web/tests/*.test.mjs` 127 pass, 0 fail (new `businessTabs.test.mjs`: one word
  slugs, never `setup`; key moves; the route and ARIA attributes). `npm run lint` 0 errors, check-dashes 0, catalog
  drift passes. `npx vite build` passes.
- Local browser (isolated `zle_ui`, local stand in, real function), 1440x900 and 390 wide, deviceScaleFactor 1, no
  page errors, no failed requests, no sideways overflow: each of the seven tab addresses opens its panel with the
  right tab selected; ArrowRight from Configuration moves focus and the address to People; Home returns to the plain
  address; `/businesses/<id>/nonsense` shows Overview; exactly one tab stop. Screenshots:
  `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-e/shots/pr2_overview_1440.png`,
  `pr2_people_1440.png`, `pr2_receptionist_1440.png`, `pr2_phone_1440.png`, `pr2_automations_1440.png`,
  `pr2_calls_1440.png`, `pr2_activity_1440.png`, `pr2_configuration_1440.png`, `pr2_people_390.png`,
  `pr2_overview_390.png` (same folder).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
