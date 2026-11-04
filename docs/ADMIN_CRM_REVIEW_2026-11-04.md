# Admin, CRM, wizard and themes: second pass (2026-11-04), addendum to REVIEW_2026-11-04_FULL.md

A parallel session reviewed the same areas and pushed first (`cefc994`, report in `docs/REVIEW_2026-11-04_FULL.md`).
Its `owner-provision-business` was deployed (version 11) and its alerts policy fix was applied.

This pass was rebased onto that work. Where both sessions fixed the same thing, the pushed (deployed) version was
kept. Below is only what this pass **adds or changes** on top of it. Nothing below is deployed or applied.

## Kept from the parallel session (not redone)

- Owner-only invitation lookups (`ownerInvitation.ts`).
- Wizard Save / Discard / Stay, leave guard and marks from saved data.
- Appearance save status, fresh read and deferred picture deletion.
- WCAG AA text tokens.
- Icon words hidden until the font loads (`watchIconFont`).
- `zella_platform_roles_fix.sql`, the same fix this pass had written as `zella_admin_roles_fix.sql` (dropped).
- The Cloudflare `_redirects` file.

## Added in this pass

| # | Severity | Finding (how verified) | Fix | Files |
|---|---|---|---|---|
| A1 | High | **Setup completion.** The deployed `finishSetup` still **activated the workspace before the owner's email was sent**, so a failed email left an active workspace and the wizard said "is set up". Two clicks, or two windows, could each send an invitation email, because nothing was claimed before sending. A `sent` invitation whose link had expired was reported as "sent" (code reading; fake-world tests). | `finishSetupWith`: required setup checked from saved data → the owner's invitation decides → an open invitation is **claimed (open → sent) before the email**, so a second request gets "already being finished" → the workspace is activated **only after** the email went out (or the invitation was already sent or accepted). A failed email returns `completed: false` and frees the claim so it can be retried. A cancel while sending returns `closed`, and nothing is activated. A `sent` invitation with an expired link stops: "use Resend invitation". The parallel session's lookups and its policy that an `expired` status may be re-sent are kept. | `owner-provision-business/index.ts`, `owner_invite.ts`, `owner_invite_test.ts` |
| A2 | Medium | **Wizard result screen.** It always said "is set up" and "Active". | When `completed` is false: "isn't finished yet", "Not active yet", **Try again**. | `CreateBusinessWizard.jsx` |
| A3 | Medium | **Restricted platform admins could open pages by direct link** (page sweep): `read_only_admin` and `support_admin` could open Create business, Verification, Support, Plans, Offers, Security & Abuse and Users & access. The menu hid them; the server already refused the actions. | A direct link shows "This page isn't available" with the role's name. | `OwnerDashboard.jsx` |
| A4 | Medium | **Customer links cut short** (`/r/…`, `/u/…`, `/w/…`) showed the **admin "OWNER ACCESS" sign-in** to customers (browser). Reschedule and waitlist replaced the function's message with "Something went wrong". Unsubscribe said "This link isn't valid" when Zella was down. Continue-plan still said "zellaai". | `BrokenLink.jsx` ("This link isn't complete"); the function's message is shown; "We can't reach Zella right now" with Try again; brand fixed. | `App.jsx`, `BrokenLink.jsx`, `Reschedule.jsx`, `WaitlistOffer.jsx`, `Unsubscribe.jsx`, `ContinuePlan.jsx` |
| A5 | Low | **A failed load looked like "nothing yet"** (sweep, error mode): Plans, Users & access ("0 active admins"), Verification, Support, Industries and CRM Custom fields. Record types ignored load errors. The wizard showed an empty industry picker with no reason. | "Couldn't load…" (with Try again where there is one); `useRecordTypes` keeps the error; a wizard warning. | `PlansPage.jsx`, `UsersAccess.jsx`, `VerificationQueue.jsx`, `SupportTickets.jsx`, `IndustryConfiguration.jsx`, `BusinessRecords.jsx`, `BusinessApp.jsx`, `BusinessSettings.jsx`, `CreateBusinessWizard.jsx` |
| A6 | Low | **A look change made outside Settings** (the sidebar's dock button) failed with no message. | A notice with Try again in both apps (uses the parallel session's save state). | `AppearanceSaveNotice.jsx`, `index.css`, `OwnerDashboard.jsx`, `BusinessApp.jsx` |
| A7 | Medium | **Header and tablet sidebar** (screenshots at 1366, 820 and 390): the header ran past the window (+44 px at 1366, +284 px at 820). Tablet icon-sidebar headings were cut ("WORKSP"), because a later rule showed them again. Phone header buttons lost their accessible names. | Long names shorten with "…"; below 1440 the header buttons show their icon only, with visually hidden names and tooltips; the tablet sidebar rules win; the switcher and search give way; if the icon font is missing, the header buttons show their names. | `BusinessApp.css`, `BusinessApp.jsx` |
| A8 | Info | **Lifecycle functions captured from live** (`is_platform_admin`, `zella_advance_onboarding`, `zella_change_business_industry`, `zella_create_business_draft`, `zella_process_cancellations`, `zella_reactivate_business`, `zella_set_business_modules`, `zella_suspend_business`). Their `pg_get_functiondef` checksums are **identical** between live (read-only) and the restored baseline. | `tests/security/lifecycle_test.sql`, 9 checks: who may call them; `is_platform_admin` for each admin role; draft state; onboarding only moves forward; modules limited to the business's industry, other businesses untouched; an industry change resets modules and words; suspend and reactivate restore exactly what was running; scheduled cancellation only for due businesses, audited, runs once. | `tests/security/lifecycle_test.sql` |
| A9 | Low | A dialog focus helper (`useDialogFocus.js`) for dialogs that don't have their own. | Added; not yet used by existing dialogs (the wizard dialog keeps the parallel session's own focus handling). | `useDialogFocus.js` |

## Hosting

`web/public/_redirects` (parallel session) sends every path to `index.html`. Two checks with the production build
under `vite preview`:
- Malformed percent-encoding (`/app/%`) gets a 404 from the static server before the app loads.
- A missing `/assets/*.js` gets `index.html` with status 200.

On Cloudflare Pages, check both after the first deploy. Missing asset files should return 404, so a browser holding
an old build's script names never receives HTML as a script.

## Tests run on the merged code

| Suite | Kind | Result |
|---|---|---|
| `tests/browser/wizard-journey.cjs` (parallel session) against the **real** `owner-provision-business` code under Deno, the local Supabase stand-in and an isolated Postgres | Real function code; isolated DB | **23/23**, including "finishing setup invites the owner, never a newer staff invitation" and "refuses to finish without saved opening hours", on the merged `finishSetup` |
| `owner_invite_test.ts` (7) + `ownerInvitation_test.ts` (4) | Deno, fakes | 11/11: double submit sends 1 email; a failed email isn't "completed" and activates nothing; Retry works; a cancel while sending gives "closed"; revoked, expired-link and incomplete setup send nothing |
| `tests/browser/appearance-save.cjs` (17) | Playwright, stubbed Auth and Storage | 17/17 on the parallel session's appearance code plus A6 |
| `tests/browser/security-journeys.cjs` (23) | Playwright, stubbed | 23/23 |
| `tests/browser/page-sweep.cjs`: every CRM menu page × owner, admin, manager, staff, viewer; CRM and admin settings subpages; every admin page × `zella_owner`, `read_only_admin`, `support_admin`; 10 public links; "empty" and "error" backends | Playwright, stubbed | See the coverage section |
| `tests/browser/visual-a11y.cjs`: Zella Voice (the new default), Classic and Glass × 1366, 820 and 390 × 9 pages (axe WCAG 2.1 AA), Google Fonts blocked, reduced motion | Playwright + axe-core 4.10.2 (outside the repo) | **0 axe violations, 0 overflow, 0 page errors**; with fonts blocked no icon text shows; reduced motion: no running animations |
| `tests/security/run.sh` (with lifecycle) | Isolated Postgres 16 restored from the baseline | 43 PASS, ALL PASSED |
| Deno: staff-invite 9, billing-webhook 8, voice-rules 19 | Fakes | All pass |
| `node --test web/src/*.test.mjs` | node:test | 11/11 |
| n8n `test.mjs` | Local | 391 passed; no workflow JSON changed |
| `npm ci` (existing lockfile), `npm run build`, `oxlint` | | Clean install, build OK; lint 0 errors |

## Needs approval

1. **Deploy `owner-provision-business` again** (A1). Live is the parallel session's version 11, which activates before sending.
2. Apply `sql/zella_platform_roles_fix.sql`, if not done yet (parallel session).
3. Deploy the web app (A2–A7) with hosting.

## Page coverage (sweep on the merged code)

224 pages from the app's own registries (CRM menu and settings tree, admin menu and settings tree, public links), 893 visits. **0 crashes, 0 role leaks.** Business switching: 5/5 roles switched and stayed on the page.

† "contained (stub only)": the error panel catches the page when the stub answers `null` or `{}`. The real functions behind these pages raise `NOT_ALLOWED` or return an object, never null (checked: zella_business_settings, zella_business_services_get, zella_business_entitlements, zella_website_forms, zella_integration_summary, zella_cross_sell_list, zella_business_language_get). Admin actions always return full objects. These are robustness gaps, not live defects.
"Static or no load" means the page shows information that needs no data, or a "not available yet" explanation.
Not covered: pages behind a record (customer detail, record pages `/app/records/<type>`, booking forms) were opened empty only. Their forms weren't exercised.

| App | Page | Roles | Empty backend | Every call fails |
|---|---|---|---|---|
| crm | today | owner, admin, manager, staff, viewer | tested | tested; error shown |
| crm | calendar | owner, admin, manager, staff, viewer | tested | tested; error shown |
| crm | checkins | owner, admin, manager, staff, viewer | tested | tested; error shown |
| crm | waitlist | owner, admin, manager, staff, viewer | tested | tested; error shown |
| crm | tasks | owner, admin, manager, staff, viewer | tested | tested; error shown |
| crm | leads | owner, admin, manager, staff, viewer | tested | tested; error shown |
| crm | customers | owner, admin, manager, staff, viewer | tested | tested; error shown |
| crm | attention | owner, admin, manager, staff, viewer | tested | tested; error shown |
| crm | inbox | owner, admin, manager, staff, viewer | tested | tested; error shown |
| crm | messages | owner, admin, manager, staff, viewer | tested | tested; error shown |
| crm | calls | owner, admin, manager, staff, viewer | tested | tested; error shown |
| crm | callbacks | owner, admin, manager, staff, viewer | tested | tested; error shown |
| crm | drafts | owner, admin, manager, staff, viewer | tested; tested; refused for role | tested; error shown |
| crm | failed | owner, admin, manager, staff, viewer | tested; tested; refused for role | tested; error shown; tested; refused for role |
| crm | spam | owner, admin, manager, staff, viewer | tested; tested; refused for role | tested; error shown; tested; refused for role |
| crm | receptionist | owner, admin, manager, staff, viewer | tested | tested; error shown |
| crm | transcripts | owner, admin, manager, staff, viewer | tested | tested; error shown |
| crm | knowledge | owner, admin, manager, staff, viewer | tested | tested; error shown |
| crm | automations | owner, admin, manager, staff, viewer | tested | tested; error shown |
| crm | lead-sources | owner, admin, manager, staff, viewer | tested | tested; error shown |
| crm | reviews | owner, admin, manager, staff, viewer | tested; tested; refused for role | tested; error shown; tested; refused for role |
| crm | reports | owner, admin, manager, staff, viewer | tested | tested; error shown |
| crm | team | owner, admin, manager, staff, viewer | tested | tested; error shown |
| crm | scorecards | owner, admin, manager, staff, viewer | tested | tested; error shown |
| crm | access | owner, admin, manager, staff, viewer | tested; tested; refused for role | tested; error shown; tested; refused for role |
| crm | approvals | owner, admin, manager, staff, viewer | tested; tested; refused for role | tested; error shown; tested; refused for role |
| crm | security | owner, admin, manager, staff, viewer | tested; tested; refused for role | tested; error shown; tested; refused for role |
| crm | integrations | owner, admin, manager, staff, viewer | tested | tested; error shown |
| crm | settings | owner, admin, manager, staff, viewer | contained (stub only †) | tested; error shown |
| crm | settings/profile/info | owner, staff, viewer | contained (stub only †) | tested; error shown |
| crm | settings/profile/address | owner, staff, viewer | contained (stub only †) | tested; error shown |
| crm | settings/profile/hours | owner, staff, viewer | contained (stub only †) | tested; error shown |
| crm | settings/profile/locale | owner, staff, viewer | contained (stub only †) | tested; error shown |
| crm | settings/profile/branding | owner, staff, viewer | tested | tested; static or no load |
| crm | settings/team/members | owner, staff, viewer | tested | tested; error shown |
| crm | settings/team/roles | owner, staff, viewer | tested | tested; static or no load |
| crm | settings/team/invitations | owner, staff, viewer | tested | tested; error shown |
| crm | settings/team/availability | owner, staff, viewer | tested | tested; error shown |
| crm | settings/team/assignment | owner, staff, viewer | tested | tested; error shown |
| crm | settings/team/security | owner, staff, viewer | tested | tested; error shown |
| crm | settings/receptionist/overview | owner, staff, viewer | tested | tested; error shown |
| crm | settings/receptionist/voice | owner, staff, viewer | tested | tested; error shown |
| crm | settings/receptionist/languages | owner, staff, viewer | contained (stub only †) | tested; error shown |
| crm | settings/receptionist/services | owner, staff, viewer | contained (stub only †) | tested; error shown |
| crm | settings/receptionist/knowledge | owner, staff, viewer | tested | tested; error shown |
| crm | settings/receptionist/website | owner, staff, viewer | contained (stub only †) | tested; error shown |
| crm | settings/receptionist/calls | owner, staff, viewer | tested | tested; error shown |
| crm | settings/receptionist/escalation | owner, staff, viewer | tested | tested; error shown |
| crm | settings/receptionist/booking | owner, staff, viewer | tested | tested; error shown |
| crm | settings/receptionist/testing | owner, staff, viewer | tested | tested; error shown |
| crm | settings/receptionist/versions | owner, staff, viewer | tested | tested; error shown |
| crm | settings/phone/numbers | owner, staff, viewer | tested | tested; error shown |
| crm | settings/phone/setup | owner, staff, viewer | tested; not available | tested; error shown |
| crm | settings/phone/routing | owner, staff, viewer | tested | tested; error shown |
| crm | settings/phone/usage | owner, staff, viewer | contained (stub only †) | tested; error shown |
| crm | settings/phone/recording | owner, staff, viewer | tested | tested; static or no load |
| crm | settings/phone/troubleshooting | owner, staff, viewer | contained (stub only †) | tested; error shown |
| crm | settings/billing/plan | owner, staff, viewer | contained (stub only †) | tested; error shown |
| crm | settings/billing/usage | owner, staff, viewer | contained (stub only †) | tested; error shown |
| crm | settings/billing/calling | owner, staff, viewer | tested | tested; error shown |
| crm | settings/billing/protection | owner, staff, viewer | contained (stub only †) | tested; error shown |
| crm | settings/billing/rollover | owner, staff, viewer | contained (stub only †) | tested; error shown |
| crm | settings/billing/offers | owner, staff, viewer | tested | tested; error shown |
| crm | settings/billing/payment-methods | owner, staff, viewer | tested | tested; static or no load |
| crm | settings/billing/invoices | owner, staff, viewer | tested | tested; static or no load |
| crm | settings/billing/changes | owner, staff, viewer | tested | tested; error shown |
| crm | settings/billing/cancellation | owner, staff, viewer | tested | tested; static or no load |
| crm | settings/calendar/connections | owner, staff, viewer | tested | tested; error shown |
| crm | settings/calendar/settings | owner, staff, viewer | tested | tested; static or no load |
| crm | settings/calendar/types | owner, staff, viewer | tested | tested; static or no load |
| crm | settings/calendar/rules | owner, staff, viewer | tested | tested; static or no load |
| crm | settings/calendar/notifications | owner, staff, viewer | tested | tested; error shown |
| crm | settings/crm/records | owner, staff, viewer | tested | tested; error shown |
| crm | settings/crm/leads | owner, staff, viewer | tested | tested; error shown |
| crm | settings/crm/forms | owner, staff, viewer | contained (stub only †) | tested; error shown |
| crm | settings/crm/assignment | owner, staff, viewer | tested | tested; error shown |
| crm | settings/crm/questions | owner, staff, viewer | tested | tested; error shown |
| crm | settings/crm/pipeline | owner, staff, viewer | tested | tested; static or no load |
| crm | settings/crm/fields | owner, staff, viewer | tested | tested; error shown |
| crm | settings/crm/export | owner, staff, viewer | tested; not available | tested; error shown |
| crm | settings/crm/communication | owner, staff, viewer | tested | tested; error shown |
| crm | settings/industry/profile | owner, staff, viewer | tested | tested; static or no load |
| crm | settings/industry/terminology | owner, staff, viewer | tested | tested; static or no load |
| crm | settings/industry/fields | owner, staff, viewer | tested | tested; error shown |
| crm | settings/industry/workflows | owner, staff, viewer | tested | tested; error shown |
| crm | settings/industry/services | owner, staff, viewer | contained (stub only †) | tested; error shown |
| crm | settings/industry/modules | owner, staff, viewer | tested; not available | tested; error shown |
| crm | settings/automations/library | owner, staff, viewer | tested | tested; error shown |
| crm | settings/automations/events | owner, staff, viewer | tested | tested; static or no load |
| crm | settings/automations/history | owner, staff, viewer | tested | tested; error shown |
| crm | settings/automations/suggestions | owner, staff, viewer | contained (stub only †) | tested; error shown |
| crm | settings/automations/recovery | owner, staff, viewer | tested | tested; error shown |
| crm | settings/integrations/available | owner, staff, viewer | tested | tested; error shown |
| crm | settings/integrations/calendar | owner, staff, viewer | tested | tested; error shown |
| crm | settings/integrations/health | owner, staff, viewer | contained (stub only †) | tested; error shown |
| crm | settings/messages/config | owner, staff, viewer | tested | tested; error shown |
| crm | settings/messages/templates | owner, staff, viewer | tested; not available | tested; error shown |
| crm | settings/messages/rules | owner, staff, viewer | tested | tested; static or no load |
| crm | settings/messages/reviews | owner, staff, viewer | tested | tested; error shown |
| crm | settings/messages/history | owner, staff, viewer | tested | tested; error shown |
| crm | settings/notifications/team | owner, staff, viewer | tested | tested; static or no load |
| crm | settings/notifications/usage | owner, staff, viewer | contained (stub only †) | tested; error shown |
| crm | settings/notifications/history | owner, staff, viewer | tested | tested; error shown |
| crm | settings/security/account | owner, staff, viewer | tested | tested; error shown |
| crm | settings/security/team | owner, staff, viewer | tested | tested; error shown |
| crm | settings/security/privacy | owner, staff, viewer | tested | tested; error shown |
| crm | settings/security/audit | owner, staff, viewer | tested | tested; error shown |
| crm | settings/security/data | owner, staff, viewer | tested | tested; static or no load |
| crm | settings/reports/dashboard | owner, staff, viewer | tested | tested; static or no load |
| crm | settings/reports/reporting | owner, staff, viewer | tested | tested; static or no load |
| crm | settings/reports/performance | owner, staff, viewer | tested | tested; error shown |
| crm | settings/reports/export | owner, staff, viewer | tested | tested; static or no load |
| crm | settings/help/center | owner, staff, viewer | tested | tested; static or no load |
| crm | settings/help/tickets | owner, staff, viewer | tested | tested; error shown |
| crm | settings/help/status | owner, staff, viewer | contained (stub only †) | tested; error shown |
| crm | settings/help/feedback | owner, staff, viewer | tested | tested; error shown |
| crm | settings/me/profile | owner, staff, viewer | tested | tested; static or no load |
| crm | settings/me/security | owner, staff, viewer | tested | tested; error shown |
| crm | settings/me/appearance | owner, staff, viewer | tested | tested; static or no load |
| crm | settings/me/logout | owner, staff, viewer | tested | tested; static or no load |
| admin | / | zella_owner, read_only_admin, support_admin | tested | tested; error shown |
| admin | /businesses | zella_owner, read_only_admin, support_admin | tested | tested; error shown |
| admin | /businesses/new | zella_owner, read_only_admin, support_admin | tested; tested; refused for role | tested; static or no load |
| admin | /verification | zella_owner, read_only_admin, support_admin | tested; tested; refused for role | tested; static or no load |
| admin | /industries | zella_owner, read_only_admin, support_admin | tested | tested; error shown |
| admin | /modules | zella_owner, read_only_admin, support_admin | tested | tested; error shown |
| admin | /plans | zella_owner, read_only_admin, support_admin | tested; tested; refused for role | tested; error shown |
| admin | /offers | zella_owner, read_only_admin, support_admin | tested; tested; refused for role | tested; error shown |
| admin | /agents | zella_owner, read_only_admin, support_admin | tested | tested; error shown |
| admin | /voice | zella_owner, read_only_admin, support_admin | tested | tested; error shown |
| admin | /messaging | zella_owner, read_only_admin, support_admin | tested | tested; error shown |
| admin | /operations | zella_owner, read_only_admin, support_admin | tested | tested; error shown |
| admin | /automations | zella_owner, read_only_admin, support_admin | tested | tested; error shown |
| admin | /integrations | zella_owner, read_only_admin, support_admin | tested | tested; error shown |
| admin | /support | zella_owner, read_only_admin, support_admin | tested; tested; refused for role | tested; error shown |
| admin | /security-abuse | zella_owner, read_only_admin, support_admin | tested; tested; refused for role | tested; static or no load |
| admin | /users | zella_owner, read_only_admin, support_admin | tested; tested; refused for role | tested; error shown |
| admin | /audit-logs | zella_owner, read_only_admin, support_admin | contained (stub only †); tested; refused for role | tested; error shown |
| admin | /settings | zella_owner, read_only_admin, support_admin | contained (stub only †) | tested; error shown |
| admin | /settings/general/profile | zella_owner, read_only_admin | contained (stub only †) | tested; error shown |
| admin | /settings/general/branding | zella_owner, read_only_admin | contained (stub only †) | tested; error shown |
| admin | /settings/general/localization | zella_owner, read_only_admin | contained (stub only †) | tested; error shown |
| admin | /settings/general/maintenance | zella_owner, read_only_admin | contained (stub only †) | tested; error shown |
| admin | /settings/general/operations | zella_owner, read_only_admin | contained (stub only †) | tested; error shown |
| admin | /settings/tenants/all | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/tenants/onboarding | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/tenants/lifecycle | zella_owner, read_only_admin | contained (stub only †) | tested; error shown |
| admin | /settings/tenants/details | zella_owner, read_only_admin | tested | tested; static or no load |
| admin | /settings/tenants/provisioning | zella_owner, read_only_admin | contained (stub only †) | tested; error shown |
| admin | /settings/tenants/data | zella_owner, read_only_admin | contained (stub only †) | tested; error shown |
| admin | /settings/users/admins | zella_owner, read_only_admin | contained (stub only †) | tested; error shown |
| admin | /settings/users/roles | zella_owner, read_only_admin | contained (stub only †) | tested; error shown |
| admin | /settings/users/permissions | zella_owner, read_only_admin | contained (stub only †) | tested; error shown |
| admin | /settings/users/auth | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/plans/plans | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/plans/entitlements | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/plans/subscriptions | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/plans/promotions | zella_owner, read_only_admin | tested | tested; static or no load |
| admin | /settings/plans/enforcement | zella_owner, read_only_admin | tested | tested; static or no load |
| admin | /settings/offers/overview | zella_owner, read_only_admin | contained (stub only †); tested | tested; error shown |
| admin | /settings/offers/rules | zella_owner, read_only_admin | tested | tested; static or no load |
| admin | /settings/offers/monitoring | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/offers/reports | zella_owner, read_only_admin | tested | tested; static or no load |
| admin | /settings/billing/overview | zella_owner, read_only_admin | contained (stub only †) | tested; error shown |
| admin | /settings/billing/payments | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/billing/invoices | zella_owner, read_only_admin | tested | tested; static or no load |
| admin | /settings/billing/refunds | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/billing/calling-usage | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/billing/config | zella_owner, read_only_admin | contained (stub only †) | tested; error shown |
| admin | /settings/ai/providers | zella_owner, read_only_admin | contained (stub only †) | tested; error shown |
| admin | /settings/ai/registry | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/ai/configuration | zella_owner, read_only_admin | tested | tested; static or no load |
| admin | /settings/ai/testing | zella_owner, read_only_admin | tested | tested; static or no load |
| admin | /settings/ai/guardrails | zella_owner, read_only_admin | tested | tested; static or no load |
| admin | /settings/voice/providers | zella_owner, read_only_admin | contained (stub only †) | tested; error shown |
| admin | /settings/voice/numbers | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/voice/usage | zella_owner, read_only_admin | contained (stub only †) | tested; error shown |
| admin | /settings/voice/costs | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/voice/limits | zella_owner, read_only_admin | tested | tested; static or no load |
| admin | /settings/comms/sms | zella_owner, read_only_admin | contained (stub only †) | tested; error shown |
| admin | /settings/comms/email | zella_owner, read_only_admin | contained (stub only †) | tested; error shown |
| admin | /settings/comms/templates | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/comms/delivery | zella_owner, read_only_admin | contained (stub only †) | tested; error shown |
| admin | /settings/integrations/registry | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/integrations/oauth | zella_owner, read_only_admin | tested | tested; static or no load |
| admin | /settings/integrations/n8n | zella_owner, read_only_admin | contained (stub only †) | tested; error shown |
| admin | /settings/integrations/monitoring | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/integrations/webhooks | zella_owner, read_only_admin | tested | tested; static or no load |
| admin | /settings/security/overview | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/security/isolation | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/security/secrets | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/security/retention | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/security/privacy | zella_owner, read_only_admin | contained (stub only †) | tested; error shown |
| admin | /settings/security/audit | zella_owner, read_only_admin | tested | tested; static or no load |
| admin | /settings/alerts/rules | zella_owner, read_only_admin | tested | tested; static or no load |
| admin | /settings/alerts/channels | zella_owner, read_only_admin | contained (stub only †) | tested; error shown |
| admin | /settings/alerts/history | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/support/health | zella_owner, read_only_admin | tested | tested; static or no load |
| admin | /settings/support/incidents | zella_owner, read_only_admin | tested | tested; static or no load |
| admin | /settings/support/logs | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/analytics/global | zella_owner, read_only_admin | contained (stub only †) | tested; error shown |
| admin | /settings/analytics/reporting | zella_owner, read_only_admin | tested | tested; static or no load |
| admin | /settings/analytics/quality | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/legal/documents | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/legal/versions | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/legal/policy | zella_owner, read_only_admin | tested | tested; static or no load |
| admin | /settings/developer/api | zella_owner, read_only_admin | tested | tested; static or no load |
| admin | /settings/developer/environment | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/developer/system | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/profile/me | zella_owner, read_only_admin | tested | tested; static or no load |
| admin | /settings/profile/security | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/profile/notifications | zella_owner, read_only_admin | tested | tested; error shown |
| admin | /settings/profile/appearance | zella_owner, read_only_admin | tested | tested; static or no load |
| admin | /settings/profile/signout | zella_owner, read_only_admin | tested | tested; static or no load |
| public | reschedule link | visitor | tested | tested; error shown |
| public | broken reschedule link | visitor | tested | tested; static or no load |
| public | unsubscribe link | visitor | tested | tested; error shown |
| public | broken unsubscribe link | visitor | tested | tested; static or no load |
| public | waitlist offer link | visitor | tested | tested; error shown |
| public | broken waitlist link | visitor | tested | tested; static or no load |
| public | status page | visitor | tested | tested; static or no load |
| public | welcome without a code | visitor | tested | tested; static or no load |
| public | expired email link | visitor | tested | tested; error shown |
| public | continue plan without a code | visitor | tested | tested; static or no load |
