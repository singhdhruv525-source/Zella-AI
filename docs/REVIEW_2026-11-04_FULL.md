# Full review and fixes, 2026-11-04 (second pass)

Covers:

- security and backend;
- admin dashboard, all settings, CRM pages and modules;
- setup wizard;
- navigation, fonts, themes, accessibility and content.

It follows `docs/SECURITY_REVIEW_2026-11-04.md` (invitations, billing, MFA, navigation).

**Nothing was deployed or applied to production.** The live database was only read. Every write in a check ran inside a transaction that was rolled back.

## How it was checked

| Kind | What | Data |
|---|---|---|
| Live, read-only | Function signatures (676) compared with the repo baseline plus migrations; key security functions compared body by body; RLS on every table; MFA policies and the pre-request check; storage buckets; advisors; repros run as an admin and rolled back | Production schema; no customer rows read beyond counts and config shapes |
| Isolated DB integration | `tests/security/run.sh`: invitations, billing, isolation (408 table checks, 272 function calls), MFA, platform roles, platform alerts. Each migration is applied twice. | Postgres 16 restored from `sql/baseline`, test data |
| Real-backend browser | The production build of the app against a local Supabase stand-in (`tests/browser/local-backend.mjs`). Real RLS and RPCs, and the real `owner-provision-business`, `staff-invite`, `continue-plan`, `reschedule-appointment` and `website-lead` code under Deno. | The same isolated DB; reference config copied read-only from production; test people only |
| Mocked unit tests | Deno logic tests (fakes); node tests for pure modules | No network |

What "real-backend browser" does **not** cover: Supabase's real auth service, storage, email delivery and the HTTP gateway. The stand-in imitates them for the query shapes this app uses.

## Confirmed findings and fixes (most severe first)

| # | Severity | Finding | Evidence | Fix | Status |
|---|---|---|---|---|---|
| 1 | High | **Five CRM pages crash** (`/app/automations`, Settings > Calendar > Notifications, Industry > Workflow rules, Automations > Library and History). The confirmation automation stores `hours_before` as a single number; the description code called `.map` on it. | Production holds this shape in 2 businesses (read-only count). Reproduced in the browser: error screen. | `hoursList()` accepts a list or a number (`web/src/automationOptions.js`). Used in `BusinessAutomationRuns.jsx` and the wizard. Test: `automationOptions.test.mjs`. | Fixed in repo. The pages pass in the browser. |
| 2 | High | **Admin alerts bell never loads.** The `platform_alerts` read policy queries `platform_admins`, which signed-in users can't read, so every read fails ("permission denied for table platform_admins"). The bell then said "All systems calm". | Reproduced on production (rolled back). Seen on all 96 admin routes. | Migration `sql/zella_platform_alerts_policy_fix.sql`: the policy uses `zella_admin_role()`. The bell shows "Alerts couldn't be loaded" with Try again, never a false all-clear. Test: `tests/security/platform_alerts_test.sql`. | **Migration needs approval.** UI fix in repo. |
| 3 | High | **Setup completion could invite the wrong person** (item C). Owner and staff invitations share `business_invitations`. `finishSetup`, resend, owner save, the owner contact and the dashboard took the newest row of any role, so a newer staff invitation became "the owner". The sent/failed writes were unconditional, so a cancellation during sending was overwritten. | Code; real-backend browser test with a newer staff invitation. Production has 0 staff invitations today, so no business was affected. | `owner-provision-business/ownerInvitation.ts`: every owner lookup filters `role = 'owner'` and skips revoked rows. Status moves only out of an open state; a late write reports `closed` and creates no seat. Test: `ownerInvitation_test.ts` (mocked). | Fixed in repo. **Needs deploy approval**; see below. |
| 4 | High | **Restricted platform roles can't be used.** Billing, support, security, operations and read-only admin are offered in the admin UI and enforced by `zella_admin_can`, but an older trigger rejects them (`INVALID_ADMIN_ROLE`). Inviting or changing anyone to one of them fails. | Live trigger definition read. Reproduced on the isolated DB. | Migration `sql/zella_platform_roles_fix.sql`: the trigger accepts exactly the roles the table's check constraint allows. Restricted roles still don't get `is_platform_admin()`. Test: `tests/security/platform_roles_test.sql`. | **Migration needs approval.** It is a security decision to enable these roles. |
| 5 | Medium | **Message templates mixed workspaces** (item H). The query had no business filter, so a person in two businesses saw both businesses' templates labelled "Yours". This is scoping confusion; it is not cross-tenant access, because row security only allows their own businesses. | Browser test with overlapping keys in two businesses. | `templatePrecedence.js` mirrors `zella_resolve_template` (own, then industry, then Zella; newest first). The query is filtered to the business. The page shows Source and In use. Test: `templatePrecedence.test.mjs`. | Fixed |
| 6 | Medium | **Customer search mixed workspaces.** `PersonPicker` (callbacks, tasks, bookings, records) searched every business the person belongs to, so a customer from another business could be linked to the wrong one. | The old query, run against the real backend as the owner of A and B, returns B's customer "Clinic Patient". After the fix, the browser search in A finds A's customers only. | It now searches only the business being worked in. A search failure is shown. | Fixed |
| 7 | Medium | **Setup wizard** (item I). Step headings jumped without saving; checkmarks meant "before the current step"; nothing guarded unsaved changes; no double-submit guard; finishing wasn't validated on the server. | Code; real-backend browser journey. | Save / Discard / Stay dialog (focus trap, Escape means stay, focus returns) for step changes, Back and Close. Router guard for links, Back/Forward and reload. Checkmarks from saved data (`wizardProgress.js`). The Review step reads saved data. Single-flight saves. Server refuses `setup_finish` without name, industry and saved hours. | Fixed (finish check needs deploy) |
| 8 | Medium | **Appearance saves** (item K). Failures went only to the console. A cached copy of the account was merged, so two tabs (admin and CRM) could overwrite each other's look. Old background pictures were deleted before the new choice was saved. A reload during the 600 ms wait lost the change. | Browser journey with a failing account service. | Saving / saved / failed status with Try again. Fresh `getUser()` before merging. Pictures are deleted only after a successful save, and only if neither app uses them. Unsaved changes are kept locally and sent on the next load. A palette-only change doesn't save. | Fixed |
| 9 | Medium | **Text contrast** (item M). Classic secondary `#77716B` was 3.5–4.8:1 and faint `#A39C95` was 2.0–2.7:1. Faint is used for real text: times, labels, placeholders. | Measured against every Classic surface. axe confirms. | Secondary `#615B55` (4.8–6.7:1); faint `#6C6660` (4.5–5.7:1 on text surfaces). | Fixed. axe reports no contrast failures in Classic. |
| 10 | Medium | **Glass contrast.** Avatar initials and selected offer chips were dark on dark (1.23:1). The Glass rule forced "on-primary" text onto elements that sit on the soft tint. | axe in the Glass pass on all CRM pages. | Removed those two from the on-primary list in `styles/glass.css`. | Fixed |
| 11 | Medium | **Misleading status text** (item P). Leaked-password protection was hardcoded as "currently off"; recordings were said to be "limited to managers" (every member role can read the link and transcript, M-4); Messaging setup said texts are sent while sending is off; the go-live card said "You're live, answering calls" while checks were failing; the alerts bell gave a false all-clear (#2). | Code; live grants and policies; browser. | Each now states what is verified, reads live status (`zella_messaging_status`), or says plainly that it can't be seen here. | Fixed |
| 12 | Low | **Icon font** (item O). If Google Fonts is blocked or slow, clipped icon words show. | Browser test with the fonts blocked. | The font load is watched; until it has loaded the glyph text is hidden and the layout kept. Icons were already `aria-hidden`; buttons keep their names. | Fixed. Self-hosting remains a recommendation. |
| 13 | Low | **Font weights** (item N). Inter was loaded at 400–700 while the CSS uses 550–800, which the browser substitutes or synthesises. | `index.html` and the CSS. | Variable Inter at `wght@400..800`. | Fixed |
| 14 | Low | **Accessibility:** unnamed controls on mobile (header buttons hid their text with `display:none`), the compact admin sidebar's status button, the owner email and website fields in the wizard, the time zone selects; `role="grid"` without rows on the calendar; `aria-label` on a plain div; 41 scrollable tables not reachable by keyboard. | axe at desktop and 390 px. | Visually-hidden text, `label` props, `role="region"`, `aria-hidden` on the decorative meter, `tabIndex=0` plus a focus outline on the table boxes. | Fixed |
| 15 | Low | **Mobile overflow:** receptionist pages were 109 px wider than the screen. A `1fr` grid couldn't shrink, and a `nowrap` checkbox label. | Browser at 390 px. | `minmax(0, 1fr)`, `min-width: 0`, wrapping checkboxes in forms. | Fixed |
| 16 | Info | **Hosting rewrite** (item L). No SPA rewrite was configured. | Repo | `web/public/_redirects` (Cloudflare Pages: every path goes to `index.html`). | Added. Verify after hosting. |

### Already fixed before this pass, re-verified

| Item | Result |
|---|---|
| A (invitation cancel race), B (email ownership), D (billing events), E (currency), F (MFA on every entry point) | `tests/security/run.sh`: all pass, including concurrency. Production function bodies match the repo apart from comments and blank lines (hash comparison). The pre-request check and 132 MFA policies are live. |
| G (functions "missing" from repo SQL) | All 8 are defined in `sql/baseline/05_functions_*.sql`, captured from production. None are missing; they simply aren't in the numbered migration files. Live function signatures equal baseline plus migrations exactly (676 functions). |
| J (invitation failures after sign-in) | A banner with retry and an email-link option; existing workspaces keep working. |
| L (malformed paths, error boundaries) | `/app/%` and other malformed paths show "Page not found"; no crashes on any route. |

## Coverage matrix

All results below come from the real-backend browser runs on the final build. "Passed" means:

- opened by direct address as that person;
- no crash, page error or error screen;
- no failed backend call, except intended permission refusals;
- no axe WCAG 2.1 AA violations;
- no sideways overflow;
- a screenshot taken.

Restricted roles count as passed when they get a clear "isn't available" and no data.

The isolated database had both pending migrations applied, so the admin alerts bell passes here. **In production it still fails until `zella_platform_alerts_policy_fix.sql` is applied.**

| Run | Routes | Passed | Failed |
|---|---|---|---|
| Admin, desktop | 96 | 96 | 0 |
| Admin, 390px | 96 | 96 | 0 |
| Admin, Glass | 96 | 96 | 0 |
| Read-only admin | 18 | 18 | 0 |
| Owner (business B) | 122 | 122 | 0 |
| Owner (business A) | 122 | 122 | 0 |
| Owner A, 390px | 122 | 122 | 0 |
| Owner A, Glass | 122 | 122 | 0 |
| Staff | 30 | 30 | 0 |
| Viewer | 30 | 30 | 0 |
| Visitor | 8 | 8 | 0 |

No failures in the final run.

<details><summary>Every route, every run</summary>

**Admin pages**

| Route | Admin, desktop | Admin, 390px | Admin, Glass | Read-only admin |
|---|---|---|---|---|
| `/` | ✓ | ✓ | ✓ | ✓ |
| `/businesses` | ✓ | ✓ | ✓ | ✓ |
| `/verification` | ✓ | ✓ | ✓ | ✓ |
| `/industries` | ✓ | ✓ | ✓ | ✓ |
| `/modules` | ✓ | ✓ | ✓ | ✓ |
| `/plans` | ✓ | ✓ | ✓ | ✓ |
| `/offers` | ✓ | ✓ | ✓ | ✓ |
| `/agents` | ✓ | ✓ | ✓ | ✓ |
| `/voice` | ✓ | ✓ | ✓ | ✓ |
| `/messaging` | ✓ | ✓ | ✓ | ✓ |
| `/operations` | ✓ | ✓ | ✓ | ✓ |
| `/automations` | ✓ | ✓ | ✓ | ✓ |
| `/integrations` | ✓ | ✓ | ✓ | ✓ |
| `/support` | ✓ | ✓ | ✓ | ✓ |
| `/security-abuse` | ✓ | ✓ | ✓ | ✓ |
| `/users` | ✓ | ✓ | ✓ | ✓ |
| `/audit-logs` | ✓ | ✓ | ✓ | ✓ |
| `/businesses/b0000000-0000-0000-0000-000000000001` | ✓ | ✓ | ✓ | — |
| `/businesses/b0000000-0000-0000-0000-000000000001/setup` | ✓ | ✓ | ✓ | — |
| `/businesses/new` | ✓ | ✓ | ✓ | — |

**Admin settings (75)**

| Route | Admin, desktop | Admin, 390px | Admin, Glass |
|---|---|---|---|
| `/settings/general/profile` | ✓ | ✓ | ✓ |
| `/settings/general/branding` | ✓ | ✓ | ✓ |
| `/settings/general/localization` | ✓ | ✓ | ✓ |
| `/settings/general/maintenance` | ✓ | ✓ | ✓ |
| `/settings/general/operations` | ✓ | ✓ | ✓ |
| `/settings/tenants/all` | ✓ | ✓ | ✓ |
| `/settings/tenants/onboarding` | ✓ | ✓ | ✓ |
| `/settings/tenants/lifecycle` | ✓ | ✓ | ✓ |
| `/settings/tenants/details` | ✓ | ✓ | ✓ |
| `/settings/tenants/provisioning` | ✓ | ✓ | ✓ |
| `/settings/tenants/data` | ✓ | ✓ | ✓ |
| `/settings/users/admins` | ✓ | ✓ | ✓ |
| `/settings/users/roles` | ✓ | ✓ | ✓ |
| `/settings/users/permissions` | ✓ | ✓ | ✓ |
| `/settings/users/auth` | ✓ | ✓ | ✓ |
| `/settings/plans/plans` | ✓ | ✓ | ✓ |
| `/settings/plans/entitlements` | ✓ | ✓ | ✓ |
| `/settings/plans/subscriptions` | ✓ | ✓ | ✓ |
| `/settings/plans/promotions` | ✓ | ✓ | ✓ |
| `/settings/plans/enforcement` | ✓ | ✓ | ✓ |
| `/settings/offers/overview` | ✓ | ✓ | ✓ |
| `/settings/offers/rules` | ✓ | ✓ | ✓ |
| `/settings/offers/monitoring` | ✓ | ✓ | ✓ |
| `/settings/offers/reports` | ✓ | ✓ | ✓ |
| `/settings/billing/overview` | ✓ | ✓ | ✓ |
| `/settings/billing/payments` | ✓ | ✓ | ✓ |
| `/settings/billing/invoices` | ✓ | ✓ | ✓ |
| `/settings/billing/refunds` | ✓ | ✓ | ✓ |
| `/settings/billing/calling-usage` | ✓ | ✓ | ✓ |
| `/settings/billing/config` | ✓ | ✓ | ✓ |
| `/settings/ai/providers` | ✓ | ✓ | ✓ |
| `/settings/ai/registry` | ✓ | ✓ | ✓ |
| `/settings/ai/configuration` | ✓ | ✓ | ✓ |
| `/settings/ai/testing` | ✓ | ✓ | ✓ |
| `/settings/ai/guardrails` | ✓ | ✓ | ✓ |
| `/settings/voice/providers` | ✓ | ✓ | ✓ |
| `/settings/voice/numbers` | ✓ | ✓ | ✓ |
| `/settings/voice/usage` | ✓ | ✓ | ✓ |
| `/settings/voice/costs` | ✓ | ✓ | ✓ |
| `/settings/voice/limits` | ✓ | ✓ | ✓ |
| `/settings/comms/sms` | ✓ | ✓ | ✓ |
| `/settings/comms/email` | ✓ | ✓ | ✓ |
| `/settings/comms/templates` | ✓ | ✓ | ✓ |
| `/settings/comms/delivery` | ✓ | ✓ | ✓ |
| `/settings/integrations/registry` | ✓ | ✓ | ✓ |
| `/settings/integrations/oauth` | ✓ | ✓ | ✓ |
| `/settings/integrations/n8n` | ✓ | ✓ | ✓ |
| `/settings/integrations/monitoring` | ✓ | ✓ | ✓ |
| `/settings/integrations/webhooks` | ✓ | ✓ | ✓ |
| `/settings/security/overview` | ✓ | ✓ | ✓ |
| `/settings/security/isolation` | ✓ | ✓ | ✓ |
| `/settings/security/secrets` | ✓ | ✓ | ✓ |
| `/settings/security/retention` | ✓ | ✓ | ✓ |
| `/settings/security/privacy` | ✓ | ✓ | ✓ |
| `/settings/security/audit` | ✓ | ✓ | ✓ |
| `/settings/alerts/rules` | ✓ | ✓ | ✓ |
| `/settings/alerts/channels` | ✓ | ✓ | ✓ |
| `/settings/alerts/history` | ✓ | ✓ | ✓ |
| `/settings/support/health` | ✓ | ✓ | ✓ |
| `/settings/support/incidents` | ✓ | ✓ | ✓ |
| `/settings/support/logs` | ✓ | ✓ | ✓ |
| `/settings/analytics/global` | ✓ | ✓ | ✓ |
| `/settings/analytics/reporting` | ✓ | ✓ | ✓ |
| `/settings/analytics/quality` | ✓ | ✓ | ✓ |
| `/settings/legal/documents` | ✓ | ✓ | ✓ |
| `/settings/legal/versions` | ✓ | ✓ | ✓ |
| `/settings/legal/policy` | ✓ | ✓ | ✓ |
| `/settings/developer/api` | ✓ | ✓ | ✓ |
| `/settings/developer/environment` | ✓ | ✓ | ✓ |
| `/settings/developer/system` | ✓ | ✓ | ✓ |
| `/settings/profile/me` | ✓ | ✓ | ✓ |
| `/settings/profile/security` | ✓ | ✓ | ✓ |
| `/settings/profile/notifications` | ✓ | ✓ | ✓ |
| `/settings/profile/appearance` | ✓ | ✓ | ✓ |
| `/settings/profile/signout` | ✓ | ✓ | ✓ |

**CRM pages**

| Route | Owner (business B) | Owner (business A) | Owner A, 390px | Owner A, Glass | Staff | Viewer |
|---|---|---|---|---|---|---|
| `/app/today` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `/app/calendar` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `/app/checkins` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `/app/waitlist` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `/app/tasks` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `/app/leads` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `/app/customers` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `/app/attention` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `/app/inbox` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `/app/messages` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `/app/calls` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `/app/callbacks` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `/app/drafts` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ refused |
| `/app/failed` | ✓ | ✓ | ✓ | ✓ | ✓ refused | ✓ refused |
| `/app/spam` | ✓ | ✓ | ✓ | ✓ | ✓ refused | ✓ refused |
| `/app/receptionist` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `/app/transcripts` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `/app/knowledge` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `/app/automations` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `/app/lead-sources` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `/app/reviews` | ✓ | ✓ | ✓ | ✓ | ✓ refused | ✓ refused |
| `/app/reports` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `/app/team` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `/app/scorecards` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `/app/access` | ✓ | ✓ | ✓ | ✓ | ✓ refused | ✓ refused |
| `/app/approvals` | ✓ | ✓ | ✓ | ✓ | ✓ refused | ✓ refused |
| `/app/security` | ✓ | ✓ | ✓ | ✓ | ✓ refused | ✓ refused |
| `/app/integrations` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `/app/settings` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `/app/record-settings` | ✓ | ✓ | ✓ | ✓ | ✓ refused | ✓ refused |
| `/app/records/x-unknown` | ✓ | ✓ | ✓ | ✓ | — | — |

**CRM settings (91)**

| Route | Owner (business B) | Owner (business A) | Owner A, 390px | Owner A, Glass |
|---|---|---|---|---|
| `/app/settings/profile/info` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/profile/address` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/profile/hours` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/profile/locale` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/profile/branding` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/team/members` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/team/roles` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/team/invitations` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/team/availability` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/team/assignment` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/team/security` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/receptionist/overview` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/receptionist/voice` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/receptionist/languages` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/receptionist/services` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/receptionist/knowledge` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/receptionist/website` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/receptionist/calls` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/receptionist/escalation` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/receptionist/booking` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/receptionist/testing` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/receptionist/versions` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/phone/numbers` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/phone/setup` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/phone/routing` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/phone/usage` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/phone/recording` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/phone/troubleshooting` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/billing/plan` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/billing/usage` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/billing/calling` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/billing/protection` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/billing/rollover` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/billing/offers` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/billing/payment-methods` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/billing/invoices` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/billing/changes` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/billing/cancellation` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/calendar/connections` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/calendar/settings` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/calendar/types` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/calendar/rules` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/calendar/notifications` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/crm/records` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/crm/leads` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/crm/forms` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/crm/assignment` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/crm/questions` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/crm/pipeline` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/crm/fields` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/crm/export` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/crm/communication` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/industry/profile` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/industry/terminology` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/industry/fields` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/industry/workflows` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/industry/services` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/industry/modules` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/automations/library` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/automations/events` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/automations/history` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/automations/suggestions` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/automations/recovery` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/integrations/available` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/integrations/calendar` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/integrations/health` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/messages/config` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/messages/templates` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/messages/rules` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/messages/reviews` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/messages/history` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/notifications/team` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/notifications/usage` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/notifications/history` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/security/account` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/security/team` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/security/privacy` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/security/audit` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/security/data` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/reports/dashboard` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/reports/reporting` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/reports/performance` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/reports/export` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/help/center` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/help/tickets` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/help/status` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/help/feedback` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/me/profile` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/me/security` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/me/appearance` | ✓ | ✓ | ✓ | ✓ |
| `/app/settings/me/logout` | ✓ | ✓ | ✓ | ✓ |

**Public links**

| Route | Visitor |
|---|---|
| `/status` | ✓ |
| `/r/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa` | ✓ |
| `/u/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb` | ✓ |
| `/w/cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc` | ✓ |
| `/welcome` | ✓ |
| `/app` | ✓ |
| `/` | ✓ |
| `/continue-plan` | ✓ |

</details>


**Not tested here:**

- Real email links (invite, magic link, reset) and Supabase's real auth or MFA screens.
- Real storage uploads (documents and pictures are in memory).
- Voice calls, texts and payments.
- Tablet widths, 200% zoom, reduced motion beyond code review.
- Screen-reader walkthroughs.

Forms were filled and saved in the wizard, appearance and search journeys. The other pages were checked for render, state and accessibility, but not every button was clicked.

## Tests run (this pass)

| Suite | Kind | Result |
|---|---|---|
| `tests/security/run.sh`: 6 suites plus concurrency; each migration applied twice | Isolated Postgres 16 | ALL PASSED |
| `platform_roles_test.sql`, `platform_alerts_test.sql` | Isolated DB | Fail before the fix (reproduced), pass after |
| Deno: billing-webhook, staff-invite, voice-rules, `ownerInvitation_test.ts` | Mocked | 40 passed |
| `deno check owner-provision-business/index.ts` | Type check | 0 errors |
| node: router, templatePrecedence, wizardProgress, automationOptions | Unit | All pass |
| `tests/browser/wizard-journey.cjs` | Real backend | 23/23 |
| `tests/browser/ui-journeys.cjs` | Real backend | 17/17 |
| `tests/browser/page-review.cjs` (all personas; desktop, mobile, Glass) | Real backend | See the matrix |
| `n8n/test.mjs` | Local | 391 passed. Workflow JSON regenerated unchanged. |
| `npm run build`, `oxlint` | | Build passes. Lint: 0 errors, 182 warnings (182 before). |

## Needs your approval (not applied, not deployed)

Apply in this order. Each file is safe to run twice. Run the matching test against an isolated DB first: `tests/security/run.sh` already includes both.

1. **`sql/zella_platform_alerts_policy_fix.sql`.** It replaces one read policy on `platform_alerts`. Rollback: recreate the old policy from `sql/baseline/09_policies.sql` (line 187).
2. **`sql/zella_platform_roles_fix.sql`.** It replaces the `platform_admins` role trigger. It enables the five restricted platform roles, which is a decision for you. Rollback: re-run the old function body (`sql/zella_workflows.sql`).
3. **Deploy `owner-provision-business`.** It carries:
   - the owner invitation fixes (#3);
   - the server-side finish checks (#7);
   - the earlier admin-invite and rebrand changes that still aren't live.

   It is too large for the MCP deploy tool:

   ```bash
   npx supabase functions deploy owner-provision-business
   ```

4. **Web app.** Everything else ships with hosting. Nothing in it needs a migration, except that the alerts bell keeps showing "couldn't be loaded" until #1 is applied.

## Still open

- **Owner decisions:**
  - who may read call transcripts and recordings (M-4; the copy now says plainly that all members can);
  - read-only access for suspended businesses (L-5);
  - the typo super admin.
- **Leaked-password protection** is reported off by the Supabase advisor. It's a dashboard setting (Authentication > Attack Protection); the app can't read or change it. Email confirmation and OTP expiry likewise can't be read here.
- **Vapi status and end-of-call events** still arrive without auth headers (from the earlier review).
- **Icon font:** self-hosting or SVG icons would remove the external dependency. Today the app degrades without broken words.
- **`inbound_email_token`** is readable by every member (8b; low).
- **Wizard:** industry-specific required answers are checked in the browser, but on the server only name, industry and hours are enforced at finish.

## Release readiness

**Not ready.**

- Two migrations and one function deploy are waiting for your approval.
- The app is not hosted yet, so nothing in this pass has run against the real Supabase auth and gateway.
- Providers (texts, email, billing) are off, and Vapi events are still refused.

The code paths reviewed here pass their checks against the real schema and real functions, but that is not the same as a production check.
