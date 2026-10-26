# Admin dashboard audit (2026-10-26)

Scope: the platform admin app (`OwnerDashboard.jsx` and the pages it opens, `settings/*` admin panels, the
`owner-provision-business` function). The CRM, business app and Create Business wizard are out of scope.

## Existing (kept)

| Area | Where | State |
|---|---|---|
| Overview | `OwnerOverview.jsx` (`overview_data`) | Works: counts, attention lists, setup drafts |
| Businesses, details, lifecycle | `OwnerDashboard` list, `BusinessDetails.jsx` (8 tabs), suspend/reactivate/cancel, invitation resend | Works |
| Create / resume business | Create Business wizard | Works (out of scope) |
| Admins, roles, permissions | Users & Access, Settings > Users (roles matrix, 7 roles, per-action permission checked server-side by `zella_admin_can`) | Works |
| Industries | Industry Configuration: description, terminology, AI defaults, generic modules | Works |
| Modules | Modules & Features (read-only matrix) | Works |
| Plans, subscriptions, billing | Plans page, Settings > Plans / Billing | Works; invoices, refunds, tax live in the payment provider |
| Offers | Offers page + Settings > Offers | Works |
| AI agents and settings | AI Agents page, Settings > AI | Works |
| Telephony, usage, numbers | Settings > Voice | Works; buying numbers needs the provider |
| SMS / email | Settings > Communications | Works; live sending needs provider keys |
| Integrations, n8n, automations | Integrations page, Settings > Integrations (go-live checklist, monitoring) | Works |
| Platform operations | Platform Operations, Settings > Support (health, incidents, logs) | Works |
| Support | Support tickets | Works |
| Audit | Audit Logs | Works |
| Security, privacy, legal, analytics, profile | Settings categories | Works, with honest "not built" notes |

Security check: platform admins have no broad table access in the database; every admin read and write goes
through the admin function, which checks sign-in, two-step sign-in where enrolled, the admin's role and the
action's permission. Admin call lists never include recordings or transcripts.

## Defects found (fixed)

1. The sidebar showed every page to restricted roles (billing, support, read-only...), which then failed with
   "your role doesn't allow this". Now built from the admin's own permissions.
2. "⌘ K" was shown in the search box but did nothing. Now focuses search (⌘K / Ctrl+K).
3. "Zella Platform ⌄" looked like a switcher and did nothing. Now a plain label showing the admin's real role.
4. The avatar always said "Platform owner". Now shows the signed-in admin's email and role.
5. Duplicated settings pages: Webhooks (twice), admin sessions (same as My profile > Account security), personal
   notifications (twice), support tickets (a link to the Support page). Duplicates removed; old addresses fall back
   to their category.
6. Audit entries for settings actions recorded empty before/after values (fixed earlier with the wizard work).

## Missing (added)

1. Grouped sidebar: Overview; Businesses (all, verification); Configuration (industries, modules, plans, offers);
   AI & communications (agents, voice, messaging); Operations (platform operations, automations, integrations,
   support); Administration (users & access, audit logs, settings).
2. Industry records: admins manage each industry's own record types (restaurant: tables, events; dental:
   recalls...): names, icon, fields, statuses, notice. Shared presets are flagged. New types reach existing
   businesses of that industry the next time their CRM opens; existing businesses' copies are never overwritten.
3. Per-business control: switch a business's modules and industry record types on or off from its details page.
4. Verification queue: every business's uploaded documents in one place, with view, verify and reject.
5. Verification status on the business details overview.

## Genuinely external (left as clear notes)

Payment invoices, refunds and tax (payment provider); sign-up policy, password and session rules, failed sign-in
monitoring (Supabase Auth); buying numbers (Telnyx); n8n's own execution logs (n8n API key); OAuth client secrets
(Google Cloud). Each page says so and shows what Zella itself already tracks.

## Not built (documented, not faked)

Editable alert rules, scheduled reports, a public API, secret rotation tracking, per-type retention jobs,
automatic provisioning retries, a global prompt rollout. Each has a clear note on its page.

## Backend changes in this pass

- `owner-provision-business/platform.ts` (new): `industry_records_get` (businesses.view), `industry_records_save`
  (platform.configure), `business_records_get` (businesses.view), `business_records_save` (businesses.manage),
  `documents_queue` (businesses.manage). Each is audited where it changes something. Record type definitions are
  validated on the server (keys, field types, choices, statuses, icon names, limits).
- `setup_save_modules` takes `advance: false` so changing a business's modules from its details page doesn't move
  its setup progress.
- No new tables or migrations. Industry records reuse `industry_crm_presets` and `crm_record_types`; verification
  reuses `business_verification_documents` from `sql/zella_onboarding.sql`.

## Deploy

1. `supabase functions deploy owner-provision-business` (adds `platform.ts`, `onboarding.ts`).
2. Deploy the web app.
3. For the verification queue and documents: apply `sql/zella_onboarding.sql` (after a backup).
