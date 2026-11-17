# Admin panel audit, 16 Nov 2026

A page by page and end to end check of the Zella Voice platform admin panel (the Zella staff app, not the business
CRM), and the inventory of what to build, add, fix, change, remove or verify. Nothing was changed by this audit: it is
a list of work, each item with its evidence, what to do, how to tell it is done, and whether it needs the owner's
approval (a production migration, a deploy, a live switch or a provider setup).

## How it was checked, and what kind of evidence each item has

| Kind | What was done | What it can prove |
|---|---|---|
| Code review | Five reviewers read every admin page, the edge function actions and SQL behind it, and the docs (ARCHITECTURE, PRODUCT, RULES, MEMORY). Every item cites `file:line` on `main` as of 16 Nov 2026. | What the code does. A behaviour not confirmed in code is marked VERIFY. |
| Local browser crawl | `tests/browser/glitch-sweep.cjs` signed in through the real sign in page as `admin@zella.test` (Zella Voice owner) and `readonly@zella.test` (read only admin) and opened every admin page and every Settings page (95 per persona) on desktop and in dark mode; on a phone it opened the 26 main pages only, because the phone crawl can't open the Settings tree. It ran against the isolated test database (the production schema as of 15 Nov with test only people and businesses), the local Supabase stand in and the real edge function code. Nothing was sent. | Crashes, error screens, failed calls, sideways scrolling and empty pages, for these two roles. |
| Visual pass | Every admin page and every tab (46 screens) was opened and looked at, at 1440 px desktop, and the main pages on a phone; the text of all 74 Settings pages was read. Findings are the UI rows. | Layout, wording, missing actions and pages that contradict each other. |
| Production, read only | Supabase security advisors; `cron.job`; row security and grants on `support_tickets` and `audit_logs`; the live platform role matrix; the live `zella_platform_admin_trigger`; `calls_view`; row counts for `integrations` and `business_phone_numbers`. No data about any customer was read or copied. | The live state of those items on 16 Nov 2026. |
| Not done | No staging run, no real provider test (Vapi, Telnyx, Resend, Stripe), no test with restricted roles other than read only admin, no automated accessibility scan (axe-core is not installed; PLT-06). | Items that need these are marked VERIFY. |

## The numbers

**Browser crawl (local, isolated test database):**

| Run | Pages opened | Pages with a problem | What the problems were |
|---|---|---|---|
| Zella Voice owner, desktop | 95 | 3 | Two Settings developer pages failed to load through the local stand in (PLT-04); the all businesses table scrolls sideways (PLT-05). |
| Zella Voice owner, dark mode | 95 | 3 | The same three. |
| Zella Voice owner, phone | 26 | 0 | The phone crawl can't open the Settings tree, so it covered the main pages only. |
| Read only admin, desktop | 95 | 8 | The three above, plus five refusals: Offers, Platform operations health, Settings AI providers, Settings n8n readiness and Settings service health all get NOT_ALLOWED from functions that only allow owners and super admins (OPS-04, ACC-04, CFG-23). |
| Read only admin, dark mode | 95 | 8 | The same eight. |
| Read only admin, phone | 26 | 2 | Offers and Platform operations health refused, as above. |

No page crashed, showed the error screen, got stuck loading or showed "Page not found" in any run. The crawl doesn't
judge whether the content is right; the code review, the visual pass and the production reads do.

| Type | Count | | Severity | Count |
|---|---|---|---|---|
| BUILD (does not exist) | 2 | | P1 (broken or wrong for real use) | 16 |
| ADD (to an existing page or flow) | 32 | | P2 (incomplete, confusing, inconsistent) | 103 |
| FIX (broken or incorrect) | 50 | | P3 (polish) | 91 |
| CHANGE (incomplete, confusing, outdated) | 102 | |  | |
| REMOVE (obsolete, duplicated, misleading) | 10 | |  | |
| VERIFY (evidence insufficient) | 14 | |  | |
| **Total** | **210** | | | |

No item is P0: nothing found leaks one business's data to another business, and nothing sends a real message by
itself. The P1 items below are the ones to fix before the admin panel is used for real businesses.

## Fix first: the P1 items

| ID | What is wrong | Checked how |
|---|---|---|
| ACC-01 | Two step sign in is only required for admins who chose to set it up; a password alone gives full platform access. | Code (`owner-provision-business/index.ts:3000-3008`) |
| BIZ-01 | <!-- coderabbit-ai-generated:v1 --> <!-- coderabbit-ai-generated-section:v1:8ebb4e5be5f844cb9e427fbcaaecf63ca939aac9dde417147c8e5041cb208af0 --> Current code rejects an unusable app address before sending an owner invitation or changing state; production deployment and live `ZELLA_APP_URL` still need verification. <!-- /coderabbit-ai-generated:v1 --> | <!-- coderabbit-ai-generated:v1 --> <!-- coderabbit-ai-generated-section:v1:df84a29f8a666b7b3dd14695faa887818544e4228a46c8f1c9116cbe159979ee --> Code (`owner_invite.ts:97-100`; `index.ts:2758-2759`) <!-- /coderabbit-ai-generated:v1 --> |
| BIZ-02 | <!-- coderabbit-ai-generated:v1 --> <!-- coderabbit-ai-generated-section:v1:710c0f8e7ca02e3c321e18da9ceb757a9f8429f3ba35270335d34922b4b126db --> Existing-account owner linking is implemented; post-sign-in acceptance on the deployed revision still needs verification. <!-- /coderabbit-ai-generated:v1 --> | Code |
| BIZ-03 | Scheduled cancellations only happen when an admin opens Overview or Businesses: no job runs them. | Code, and production `cron.job` has no such job |
| OPS-06 | Internal support notes ("only Zella Voice admins can see these") can be read by the business's members through the API. | Code, and production grants (members have SELECT on `support_tickets.metadata`) |
| OPS-04 | Monitoring, incidents, retry and the bell work only for Zella Voice owners and super admins, though the pages are shown to other roles. | Code, and the browser crawl (read only admin gets NOT_ALLOWED) |
| OPS-03 | Opening, resolving and publishing an incident leaves no audit record. | Code |
| OPS-05 | The Platform operations Retry can replay a failed event that already reached a provider (a message could repeat). | Code |
| OPS-01, OPS-02 | The public status page says "Everything is working" when nothing is actually monitored (checks and jobs are off). | Code, and production `cron.job` |
| OPS-07, COM-01 | Integrations and AI agents read "connected" and "Live" from a table nothing fills, so they will show every business as not connected. | Code, and production (`integrations` has 0 rows) |
| UI-02 | Overview, AI agents, Voice and Integrations give four different answers about which receptionists are live and connected. | Browser screenshots side by side |
| CFG-01 | Switching a module off for an industry switches it off at once for every business in it; the page says the opposite. | Code |
| CFG-14 | Plans shows the old shared plan catalog, not the per business plans that are live. | Code and MEMORY |
| PLT-07 | Most scheduled jobs are off in production; several admin numbers depend on them. | Production `cron.job` |

## Root causes, and a suggested order of work

1. **Two permission models.** The edge function and the `zella_admin_*` functions use the role matrix; older functions
   (incidents, health, retry, alerts bell, offers, business size, the `/welcome` redirect) use `is_platform_admin()`,
   which allows only Zella Voice owner and super admin. One migration that moves them onto `zella_admin_require` and
   `zella_admin_audit` closes OPS-03, OPS-04, OPS-14, CFG-23, BIZ-08, ACC-04, ACC-05, ACC-06 and ACC-09 together. OPS-05 also needs the
   replay safety check (`zella_admin_run_retry_check`) in the retry itself: permissions and audit alone don't stop a retry repeating a message.
   Today production has only two admins, both Zella Voice owners, so this bites as soon as a restricted role is added.
2. **Sign in and access.** ACC-01 (two step sign in for every admin), ACC-18 (sign out a removed admin everywhere),
   ACC-19 (fresh code for owner grants), ACC-17 (least privilege default), PLT-01 (leaked password protection).
3. **Owner invitations and lifecycle.** BIZ-01, BIZ-02, BIZ-03, BIZ-06, BIZ-07, BIZ-21, then BIZ-13 and BIZ-14.
4. **Honest health.** Count and status values that hide "unknown": OPS-01, OPS-02, OPS-08, OPS-10, OPS-13, OPS-29,
   COM-16, PLT-07.
5. **One source of truth per fact.** Readiness exists three times (BIZ-11, BIZ-12, COM-01 to COM-03); billing exists
   twice (CFG-14 to CFG-17, CFG-26, BIZ-16); alert kinds, audit actions and permissions drift (PLT-08).
6. **Audit trail you can trust.** ACC-07 to ACC-15, BIZ-17, BIZ-22, CFG-06, CFG-24, OPS-31.
7. **Paging.** Lists that silently stop at 1,000 rows: BIZ-15, CFG-11, OPS-23, OPS-27, BIZ-20, COM-06.
8. **Hide what a role can't use.** BIZ-23, CFG-09, CFG-19, COM-05, ACC-02, ACC-03, OPS-28.
9. **Copy and accessibility.** Hyphens, jargon, raw keys, tabs without panels: the P3 CHANGE rows.

Most fixes need a production migration or a deploy of `owner-provision-business`, so each batch needs the owner's
approval before it goes live. All of them can be built and tested on the isolated database first.

## Correction to what was said earlier

<!-- coderabbit-ai-generated:v1 -->

<!-- coderabbit-ai-generated-section:v1:27e45ecb942b47f681c115ec67f4a86246728211c6db3fc1feb07317e663a06c -->

Current code checks `ZELLA_APP_URL` with `appUrlUsable`: `invitationResend` rejects an unusable URL with 503 before resetting status or sending, and the setup-finish send plan in `finishSetupWith` rejects it before claiming the invitation, sending or activating the business (BIZ-01). Already sent or accepted setup plans need no new invitation. Production deployment and the live `ZELLA_APP_URL` value remain unresolved verification items; current source alone does not establish production behavior.

<!-- /coderabbit-ai-generated:v1 -->

## Checked and closed

- **Restricted roles can be created** (the reviewers' ACC-37): production's `zella_platform_admin_trigger` is the fixed
  version that accepts all seven roles (read 16 Nov 2026).
- **owner-provision-business behind `main`** (OPS-35, ACC-38): deployed from `main` as v18 on 16 Nov 2026.
- **`calls_view` security definer** (advisor ERROR): intentional and safe; see PLT-03.
- **Live switches** (`sms_live`, `email_live`, `calls_live`): shown with their true values, not editable from the app,
  writable only by the server, and audited when changed directly.
- **Every admin page is reachable** and every nav item renders a page; no admin page file is unused.

## Items that are the same problem seen from two pages

OPS-04 = ACC-04 (and CFG-23, BIZ-08 for offers and business size); OPS-14 = ACC-05; OPS-03 is part of ACC-09;
OPS-07 = COM-01; ACC-08 = BIZ-25; OPS-25 and ACC-12 both ask for filters; COM-30 and BIZ-32 are both PRODUCT.md
updates. Fix each once.

## How to read the rest

1. **Page by page**: every page and tab with what to build, fix, change, remove and verify on it.
2. **The inventory**: every item in full, grouped by area.
3. **Build checklist** (at the end): every new thing to build, page by page, as a checklist.

## Page by page

Every admin page and tab, in menu order, with what it is for and every item that touches it. The IDs point to the full
rows in the inventory further down (evidence, what to do, done when, approval). **Build** means new things on that
page; **Fix** means broken or wrong; **Change** means rework, wording or layout; **Remove** means take away;
**Verify** means it needs a live, staging or provider check.

### Shell: sign in, menu, header, alerts bell (every page)
For: getting in safely and finding pages.
- **Build:** two step sign in required for every admin, set up at first sign in (ACC-01); sign out everywhere when access is removed (ACC-18); fresh code for owner grants and role changes (ACC-19); record refused admin calls (ACC-15).
- **Fix:** restricted roles land on "This page isn't available" (ACC-03); invited admins land in the business app (ACC-06); bell "Got it" fails for most roles and isn't audited (OPS-14, ACC-05).
- **Change:** menu items hidden under the footer at 1440 by 900 (UI-01); sidebar items aren't links (ACC-35); bell "Open monitoring" goes to a page with no alert list (OPS-15); a 401 or 403 doesn't recheck access, no "session ended" message (ACC-33); sign in copy says "owner" for every role, hyphens (ACC-31); leaked password protection off (PLT-01).
- **Remove:** the unreachable admin "choose a password" step (ACC-32).
- **Verify:** an enrolled admin with a one step session sees a connection error instead of the code prompt (ACC-34).

### Overview (`/`)
For: what needs attention across all businesses.
- **Fix:** "Owner invitations" counts include staff invitations (BIZ-05); activity rows and admin emails shown to roles without audit.view (BIZ-04); opening the page applies due cancellations as a side effect (BIZ-03); "AI receptionists live 78" disagrees with AI agents "Live 0" (UI-02).
- **Change:** recent activity is mostly "privileged insert, Unknown user" (ACC-07); no platform health or alerts summary although PRODUCT says so (BIZ-32); totals stop at 1,000 rows (BIZ-15); write buttons shown to read only roles (BIZ-23).

### Businesses (`/businesses`)
For: find any business and act on it.
- **Change:** one long unpaged list, no sort or filters, no health or last call columns, "Edit setup" as the main action for live businesses (UI-03, BIZ-15); "Plan" shows the subscription status, not the business plan (BIZ-16); stage labels out of date (BIZ-27); a suspended live business shows "Continue setup" (BIZ-24); write buttons for read only roles (BIZ-23).
- **Remove:** the marketing banner (UI-04); unused members data in the response (BIZ-29).

### Business detail (`/businesses/<id>`)
For: everything about one business, for support and operations.
- **Overview tab.** Build: plan, numbers, usage and alerts cards and the server readiness ladder (BIZ-11); the go live checklist for admins (BIZ-12); balances and "grant a pack" (CFG-22); audit and masking of support access (BIZ-22). Change: "None" markers (BIZ-28); Verification "Review" opens the wizard (BIZ-31); Business size control and its permission (UI-05, BIZ-08); suspend and cancel audits lack before values (BIZ-17).
- **Configuration tab.** Fix: switching modules is allowed without the modules they need (CFG-02). Change: modules hyphens in labels come from test data only (production is clean).
- **People tab.** Build: support actions for a locked out owner, last sign in, two step status (UI-06); cancel an owner invitation, resend cooldown (BIZ-21). <!-- coderabbit-ai-generated:v1 --> <!-- coderabbit-ai-generated-section:v1:ffcd1c73547d212269ab23548b90fcd1dfe722202ad627da6383cef817bc05c8 --> Verify: existing-account acceptance after sign-in on the deployed revision (BIZ-02), production deployment and live app address configuration (BIZ-01). <!-- /coderabbit-ai-generated:v1 -->
- **AI receptionist tab.** Build: transfer and fallback numbers, served version, last delivery, how to test (UI-07, COM-03). Verify: an admin "Edit setup" on a live business may go live with no version (COM-04).
- **Phone and integrations tab.** Build: the business's numbers, fallback number and Vapi link, with "Assign a number" (UI-08).
- **Automations tab.** Fix: automations turned on after go live stay paused (BIZ-07). Change: lowercase names, "None" columns, no action or link (UI-09); "Off" vs "Archived" words (OPS-22).
- **Calls tab.** Build: open a call, see all calls (UI-10, BIZ-30). Change: full caller numbers shown with no audit (BIZ-22).
- **Activity tab.** Change: raw "privileged insert, Unknown user" rows (ACC-07, BIZ-25); no "see all" in Audit logs (BIZ-30).
- **All tabs.** Change: tabs lack panels and arrow keys and aren't in the address (BIZ-30); on a phone the tab row scrolls with no cue (UI-34).

### Create business wizard (`/businesses/new`, `/businesses/<id>/setup`)
For: setting up a new business, ten steps.
- **Build:** a creation key and duplicate warning so a retry can't create two businesses (BIZ-14).
- <!-- coderabbit-ai-generated:v1 --> <!-- coderabbit-ai-generated-section:v1:a54d666c73cd90a0e3cc549d4a3e8d68dda322517ba0914853d72369fe231fb9 --> **Verify:** production deployment and live app address configuration (BIZ-01); existing-account acceptance after sign-in on the deployed revision and Resend wording if still inaccurate (BIZ-02). **Fix:** finishing a suspended business marks it active (BIZ-06); "Mark verified" has no confirmation and allows self verification (BIZ-09). <!-- /coderabbit-ai-generated:v1 -->
- **Change:** the phone step is "optional" but the fallback number is required (BIZ-10); the plan step needs billing.manage, so most creators can't finish alone (BIZ-33); step bar cut off at 1440 px, Back on step 1, Kolkata example (UI-30); jargon and hyphens (BIZ-26); raw statuses on the result screen (BIZ-28).
- **Verify:** document "View" may be blocked as a popup in Safari (BIZ-19).

### Verification (`/verification`)
For: proving each business and owner are real.
- **Build:** a "Missing documents" list with "Request documents" (UI-11); a retention rule and cleanup for owner IDs (BIZ-18).
- **Change:** capped at 200 with no paging, inexact totals, rejecting a verified document has no effect (BIZ-20); copy mentions a SQL file (BIZ-26).
- **Verify:** "View" in Safari (BIZ-19).

### Industry configuration (`/industries`)
For: what each industry starts with.
- **Build:** per industry sensitive flag, booking model and default automations as data (CFG-05); deactivate an industry (CFG-08).
- **Fix:** switching a module off removes it from every existing business, contrary to the page's text (CFG-01); first "Save record types" changes the industry key and existing businesses' automations (CFG-04); a renamed new field loses its "In list" tick (CFG-10).
- **Change:** receptionist default fields that nothing reads (CFG-03); audit doesn't say which module changed (CFG-06); save isn't one transaction (CFG-07); editors shown to read only roles (CFG-09).
- **Verify:** Pet care sensitivity and the industry count (CFG-32).

### Modules and features (`/modules`)
For: which modules exist and who uses them.
- **Fix:** "Businesses using it" counts modules that are really off and stops at 1,000 rows (CFG-11); "All industries" label counts inactive industries (CFG-13).
- **Verify:** production's row cap (CFG-12).

### Plans and subscriptions (`/plans`)
For: the plans businesses are on.
- **Build:** the page around per business plans (tier, version, price, allowances, balances) (CFG-14), with "grant a pack" (CFG-22).
- **Fix:** "Pricing not configured" and "prices haven't been decided" are wrong (CFG-15); a plan can be renamed to another plan's name (CFG-20).
- **Change:** shared plan limits change live businesses mid period (CFG-16); decimal amounts in five currencies (CFG-17); "Available for new businesses" does nothing (CFG-18); two permissions for one action, editors for view only roles (CFG-19); duplicate unbounded subscriptions table (CFG-21); raw "languages: 2" limits (UI-12).

### Offers and promotions (`/offers`)
For: discounts and deals.
- **Fix:** every call fails for billing admins (CFG-23); admin claim actions aren't audited and the apply note is optional (CFG-24); discount value and eligibility read the old billing model (CFG-26).
- **Change:** "waits for the next payment" implies payments exist (CFG-25); loose currency, "billing connected" set by one test event (CFG-27); window.prompt dialogs (CFG-28); opening the page writes data (CFG-29); hyphens and a Kolkata time zone (CFG-30); unbounded redemptions, PRODUCT claim (CFG-31); "Growth" vs "Configuration" (UI-13).

### AI agents (`/agents`)
For: every receptionist, whether it's set up and answering.
- **Build:** last delivery outcome, not ready count and served version per receptionist (COM-03).
- **Fix:** Phone, Voice and "Live" read a table nothing fills (COM-01, UI-02); Knowledge and Hours read setup answers instead of what the receptionist uses (COM-02).
- **Change:** "Edit setup" for roles that can't save (COM-05); unpaged, call counts stop at 10,000 (COM-06); three names for one page, tooltip only states (COM-07).
- **Verify:** whether admin edits on live businesses bypass versions (COM-04).

### Voice and numbers (`/voice/<tab>`)
For: numbers, calls, routing and provider costs.
- **Overview.** Build: refused Vapi requests counter and alert (COM-09); switches panel (COM-13); tiles that open the list, a missed call alert (UI-14). Fix: "Needs attention" filters alert kinds nothing raises (COM-08). Change: setting keys as words (UI-21).
- **Numbers.** Change: assign rules differ client and server, no reason, closed businesses allowed (COM-11); any Vapi ID can be attached to any number (COM-12). Verify: calls don't record their number (UI-15).
- **Calls.** Change: unlabelled column, mixed length format, "None" (UI-16, COM-14).
- **Call routing.** Change: fallback number can be cleared or loop (COM-10); picker of every business, no "missing routing" list (UI-17).
- **Providers and costs.** Remove: repeated provider summary (COM-15). Change: unpaged usage table, repeated checks (UI-18). Build: buying numbers and provider error logs (BUILD checklist).

### Messaging (`/messaging/<tab>`)
For: texts, emails, templates, platform emails and consent.
- **Overview.** Fix: held platform emails missing from Needs attention, every alert links to Texts (COM-17); the follow up backlog isn't raised (UI-19). Change: "Sent" counts test mode rows (COM-16); lowercase tiles and hyphens (COM-28).
- **Texts and Emails.** Change: inbound customer email addresses unmasked (COM-26); filter rows wrap (UI-26).
- **Templates.** Build: create and retire templates (UI-20). Fix: script check is case sensitive (COM-27).
- **Emails to businesses.** Build: release or discard a held email, with preview (COM-18); business filter and email drawer (COM-22). Fix: with no key the outbox never marks test mode and the job calls every minute (COM-19). Change: notification says "sent" when only queued (COM-20); out of date copy and a file path (COM-21). Verify: one real email end to end on staging (COM-32).
- **Senders and providers.** Change: sender saves need a confirmation and reason (COM-23); sending state shown twice (COM-24). Verify: one platform sender vs each business's own number and 10DLC (COM-25).
- **Consent and opt outs.** Build: look up why one number or address gets no messages (COM-29).

### Platform operations (`/operations`)
For: is the platform healthy, and what needs fixing.
- **Build:** incident updates and paging (OPS-12).
- **Fix:** panels fail for every role except owner and super admin (OPS-04); incident actions aren't audited (OPS-03); Retry can replay a message (OPS-05); provider rows say OK however old the check (OPS-08); green "No issues found" while go live items are missing (UI-22).
- **Change:** n8n row reflects the wrong setting (OPS-09); missing counts become 0 (OPS-10); public incident title and window.prompt (OPS-11, UI-25); jargon and a contradiction (OPS-33); failed events capped at 50 (OPS-34); "Review" link to a page the role can't open (OPS-28); one go live checklist instead of three (UI-23); two app address settings (UI-24).

### Automations (`/automations/<tab>`)
For: every business's automations, runs, failures and the scheduler.
- **Build:** the n8n response per workflow (OPS-17); "Resume all" for a business (OPS-20).
- **Fix:** template "businesses using it" matched by name only (OPS-19).
- **Change:** refresh clears data, two error messages (OPS-18); copy and casing (OPS-21); default automations missing from Templates (UI-28); business filters are long dropdowns (UI-26).
- **Remove:** duplicate n8n card and dead letter number (OPS-16); duplicate scheduled jobs table and file paths (UI-27).

### Integrations (`/integrations`)
For: what each business asked for and what is connected.
- **Fix:** "Connected" reads a table only the store connection fills (OPS-07, UI-02).
- **Change:** unbounded lists, no filters (OPS-23); raw values, disconnected tone (OPS-24).

### Support (`/support`)
For: tickets from businesses.
- **Build:** reply to the business, alerts for urgent and cancellation tickets, age and first response with an overdue filter (OPS-25).
- **Fix:** internal notes readable by the business through the API (OPS-06); the note cap drops the newest note (OPS-26).
- **Change:** 500 ticket cap, no search, raw categories, assignees without support.manage (OPS-27).

### Security and abuse (`/security-abuse`)
For: spam and abuse across all businesses.
- **Change:** a failed read shows 0 or Off (OPS-29); rule removal and switch off need a reason, expired rules shown, capped counts (OPS-31); hyphens, mouse only rows (OPS-32); layout of cards and tabs (UI-29).
- **Verify:** block rules keep only the last 10 digits of a number (OPS-30).

### Users and access (`/users`)
For: who can use the admin panel.
- **Build:** sign out everywhere on removal (ACC-18); fresh code and optional second owner for owner grants (ACC-19).
- **Fix:** "Try again with Refresh" but no Refresh button (ACC-16).
- **Change:** new admins default to Super admin (ACC-17); two step status and last action only in Settings (ACC-20); lookup stops at 20,000 accounts (ACC-21).

### Audit logs (`/audit-logs`)
For: who did what, when.
- **Build:** filters by person, date and record, and an audited export (ACC-12).
- **Fix:** incidents, alerts and offers write no audit row (ACC-09); deleting a business would delete its audit rows (ACC-10).
- **Change:** up to three rows per change, unattributed (ACC-07); 25+ actions unlabelled (ACC-08); every member of a business can read staff IP addresses (ACC-11); paging can skip rows (ACC-13); raw JSON details and copy (ACC-14).

### Settings (`/settings/<category>/<page>`, 74 pages)
For: platform configuration.
- **Fix:** every category shown to every role (ACC-02); read errors say "The change could not be saved" (PLT-04).
- **Remove:** about 25 pages that repeat a main page (UI-31); `ai.configure` that guards nothing (ACC-23).
- **Change:** six pages that are only a "not built" note (ACC-25, listed in the build checklist); usage enforcement copy out of date (ACC-26); template copy out of date (UI-33); raw setting keys as labels (UI-32); Settings loads its own role copy (ACC-28); who may edit which setting (ACC-29); Read only admin can be given write permissions (ACC-22); "last admin action" wrong (ACC-24); the businesses table scrolls sideways (PLT-05).
- **Build:** audit entries for admin account security changes (ACC-30).
- **Verify:** the Webhooks row about the billing webhook (ACC-27).

### Public status page (`/status`, managed from Operations)
For: telling businesses whether Zella Voice is working.
- **Fix:** says "Everything is working" when nothing is monitored (OPS-01); automations show Working with the scheduler off (OPS-02).
- **Change:** one failed fetch shows an outage (OPS-13).

## The inventory

Each section lists the pages and files covered, then every item. "Approval" says whether the owner must approve a
production migration, a deploy, a live switch, a destructive action or a decision before it goes live.

Approval values: "deploy" means an `owner-provision-business` (or other edge function) deploy; "yes (migration)" a production migration; "live switch", "destructive", "owner decision" and "legal" as written; "no" means no migration or function deploy is needed; publishing the web app to production still needs the owner's approval, like every deploy.

## Businesses (Overview, Businesses list, Business detail, Verification, Create Business wizard, lifecycle)

Pages: / (OwnerOverview.jsx; overview_data), /businesses (inline in OwnerDashboard.jsx:424-679; dashboard_data), /businesses/<id> (BusinessDetails.jsx, BusinessAdminControls.jsx, settings/VoicePanel.jsx, AutomationOverview.jsx; business_detail, lifecycle actions, invitation_resend, setup_save_modules, business_records_*, zella_set_business_size, zella_business_voice_*; BusinessControls.jsx is CRM only), /verification (VerificationQueue.jsx; documents_queue, document_view, document_review; private business-documents bucket), wizard /businesses/new and /businesses/<id>/setup (CreateBusinessWizard.jsx, PlanStep.jsx, onboardingConfig.js, wizardProgress.js; setup_* and setup_finish in owner-provision-business index.ts, onboarding.ts, owner_invite.ts, ownerInvitation.ts; zella_admin_plan_*, zella_setup_plan_saved, zella_business_readiness).

| ID | Page | Type | Sev | Item | Evidence | What to do | Done when | Approval |
|---|---|---|---|---|---|---|---|---|
| BIZ-01 | Wizard, detail (owner invitation) | FIX | P1 | <!-- coderabbit-ai-generated:v1 --> <!-- coderabbit-ai-generated-section:v1:5ac49c3839d2b48210cbd4f9847d02bf9d325666f62f45bc341732bf07c42af8 --> Current code rejects an unusable ZELLA_APP_URL with 503: invitationResend checks before resetting status or sending; the setup-finish send plan checks before claiming, sending or activating. Production deployment and live ZELLA_APP_URL remain unverified. <!-- /coderabbit-ai-generated:v1 --> | <!-- coderabbit-ai-generated:v1 --> <!-- coderabbit-ai-generated-section:v1:f10a34c416a80736952f6a4936912a600372b605ac8e8658cea165a33381db28 --> owner_invite.ts:37-41 (appUrlUsable), 97-100 (finishSetupWith); index.ts:1087-1089, 2758-2759 (invitationResend) <!-- /coderabbit-ai-generated:v1 --> | <!-- coderabbit-ai-generated:v1 --> <!-- coderabbit-ai-generated-section:v1:e4e1babf741cf1fe9a5a2ba622b4ca827559ac745abc5f6da11bd29af3d36a4c --> Verify production deployment and live ZELLA_APP_URL configuration; confirm refusal before state changes or email on the deployed revision. <!-- /coderabbit-ai-generated:v1 --> | With it unset, Resend, and a Finish that would send the owner's invitation, return 503, leave the status unchanged and send nothing; a Finish with an invitation already sent or accepted still completes. | deploy |
| BIZ-02 | Wizard, detail (owner invitation) | FIX | P1 | <!-- coderabbit-ai-generated:v1 --> <!-- coderabbit-ai-generated-section:v1:e8f58deaee99c7a1f0bb071cbb2b1b11692ff122b6a4481f033623c5df5e3f7e --> Existing-account owner linking is implemented: sendOwnerEmail sends a sign-in link; finishSetup.recordSent and invitationResend record auth_user_id and create an invited owner business_members row when absent. Current Resend wording describes the sign-in link; acceptance after sign-in on the deployed revision remains unverified. <!-- /coderabbit-ai-generated:v1 --> | <!-- coderabbit-ai-generated:v1 --> <!-- coderabbit-ai-generated-section:v1:34e201e003b3b42a7384e5dc7e678e1722ffa7453312d33fc35b7665c91266ba --> index.ts:254-274 (sendOwnerEmail), 1095-1106 (finishSetup.recordSent), 2776-2809 (invitationResend); owner_invite.ts:108-119 (finishSetupWith); zella_invitation_hardening.sql:149 (zella_accept_my_invitations); BusinessDetails.jsx:276 <!-- /coderabbit-ai-generated:v1 --> | <!-- coderabbit-ai-generated:v1 --> <!-- coderabbit-ai-generated-section:v1:fe5075e77706bb90e49b60a4e49c3832152e5e03f4e4a05b869e16c5b3edef92 --> Verify post-sign-in acceptance on the deployed revision; correct the Resend message only if its wording there is still inaccurate. <!-- /coderabbit-ai-generated:v1 --> | An existing user invited as owner sees the business after signing in. | deploy |
| BIZ-03 | Lifecycle (cancel) | FIX | P1 | Scheduled cancellations only take effect when an admin opens Overview or Businesses: zella_process_cancellations has no cron or n8n caller, so a business past cancel_at keeps its receptionist and automations running. Read actions (incl read only roles) perform these writes. | index.ts:2532-2535,3049-3050,1347-1348; 05_functions_3.sql:2200-2237 | Schedule it (pg_cron) and remove the calls from dashboard_data and overview_data. | A due cancellation applies on schedule; reads write nothing. | yes (migration, live job) |
| BIZ-04 | Overview, detail activity | FIX | P2 | overview_data and business_detail need only businesses.view but return audit_logs rows with admin emails; roles without audit.view see them; the Overview Audit logs button shows for every role. | index.ts:1370-1373,1428,1477-1481,1516-1520,1564; settings.ts:25-26,34; OwnerOverview.jsx:165-191 | Return activity only with audit.view; hide the panel otherwise. | A role without audit.view gets no activity rows (server test). | deploy |
| BIZ-05 | Overview | FIX | P2 | "Owner invitations" counts and Needs attention include staff invitations (no role='owner' filter, unlike dashboard_data). | index.ts:1360-1361,1395-1412,1439-1440; ownerInvitation.ts:1-2 | Filter role owner; exclude cancelled businesses from attention. | Counts match the Businesses page. | deploy |
| BIZ-06 | Wizard, lifecycle | FIX | P2 | Re finishing setup on a suspended business sets is_active=true while it stays suspended (finish refuses only cancelled). | owner_invite.ts:75; index.ts:1091-1095; BusinessDetails.jsx:307-311; 05_functions_4.sql:2903-2906 | Refuse setup_finish while suspended (409 "Reactivate first") or skip activate(). | Finishing a suspended business leaves is_active false. | deploy |
| BIZ-07 | Wizard, detail (automations after go live) | FIX | P2 | An automation turned on after the business is live stays paused forever (only zella_request_activation activates, once); the page says paused ones start at go live, which already happened. | index.ts:961-965; 05_functions_3.sql:3844-3845; BusinessDetails.jsx:726 | Save as active when onboarding_status is active and not suspended or cancelled; fix copy. | Turning one on for a live business makes it run (test). | deploy |
| BIZ-08 | Detail (business size) | FIX | P2 | Size calls zella_set_business_size directly; it checks is_platform_admin() not businesses.manage, so restricted roles always fail; it skips the edge function's aal2 check; audit action business.size_changed has no label. | BusinessDetails.jsx:77-90; 05_functions_4.sql:1241-1256; 05_functions_1.sql:886-898; ownerFormat.js:3-32 | zella_admin_can('businesses.manage') or route through the function; add the label. | An ops role with businesses.manage can save; read only can't. | yes (migration) |
| BIZ-09 | Wizard (owner and verification) | FIX | P2 | "Mark verified" in the wizard is one click with no confirmation (the queue requires one); the uploader can verify their own upload seconds later. | CreateBusinessWizard.jsx:1363; VerificationQueue.jsx:38,238-264; onboarding.ts:275-287 | Reuse the confirm dialog; owner decides on a four eyes rule, enforced on the server. | Verifying needs confirmation everywhere; policy enforced. | owner decision |
| BIZ-10 | Wizard (phone step, review) | CHANGE | P2 | "Phone and integrations" is marked optional and its review row is always ok, but the fallback number is required by client and server finish checks; Review says Ready and finish is then refused. | CreateBusinessWizard.jsx:59,1744-1745,2012-2013; owner_invite.ts:47-48 | Drop optional; add a required Fallback number review row. | Review shows the fallback as missing before Finish. | no |
| BIZ-11 | Detail | ADD | P2 | REQ-ADM-02 wants readiness, numbers, usage and alerts on detail; the page has no plan (business_plans), numbers, usage, platform_alerts or server readiness; its "Setup progress" is computed in the browser and disagrees with zella_business_readiness. | BusinessDetails.jsx:411-436; ARCHITECTURE.md:1722,930; zella_readiness.sql:14-44 | Plan, Numbers, Usage, Alerts cards; render the server Readiness ladder (already in the wizard). | Detail shows these from server data. | no |
| BIZ-12 | Detail (go live) | ADD | P2 | Admins have no go live path and can't see the activation checklist (zella_request_activation and zella_activation_report are members only); nothing sets "ready" yet it is a stage label; checklist has no documents or plan check. | 05_functions_3.sql:3834-3850; 05_functions_1.sql:1146-1170; BusinessWork.jsx:614-626; ownerFormat.js:47 | Let businesses.manage admins read the report and show it; owner decides whether admins may go live and whether verified documents are required (REQ-LC-14); remove or wire "ready". | Admin sees the checklist; policy in ARCHITECTURE. | yes (migration, owner) |
| BIZ-13 | Lifecycle (delete, retention) | BUILD | P2 | No way to delete a mistaken draft, no expiry for abandoned drafts (D-30), zella_retention_due() shown nowhere; REQ-LC-20 requires deletion on schedule. | ARCHITECTURE.md:938,1767; zella_run_all.sql:1957-1962 | Audited "Delete draft" for never finished businesses; "Retention due" list with owner approved purge. | Drafts removable with audit; past retention listed. | yes (destructive) |
| BIZ-14 | Wizard (create draft) | ADD | P2 | No idempotency or duplicate guard: a retry after a timeout creates a second business; no duplicate name, phone or domain check. | 05_functions_2.sql:1375-1395; index.ts:504-516; CreateBusinessWizard.jsx:1887; REQ-LC-03/05 | Unique creation key; duplicate warning. | Repeat create with the same key returns the same business. | yes (migration) |
| BIZ-15 | Businesses, Overview | CHANGE | P2 | Unbounded lists: dashboard_data loads every business, owner invitation, subscription and member; API returns at most 1000 rows so totals undercount silently. | index.ts:3057-3083,1354-1361; settings.ts:100-103; OwnerDashboard.jsx:191-199 | Server paging and filters (tenants_search exists); exact counts or allRows. | Paged list; stats right above 1000 rows. | deploy |
| BIZ-16 | Businesses | CHANGE | P2 | "Plan" column shows raw subscriptions.status, not the business plan (business_plans); every business shows Not assigned. | OwnerDashboard.jsx:571,601-603; index.ts:3077-3079 | Return latest business_plans tier and version; humanise subscription status separately. | Shows "Pro, v2" or "No plan saved". | deploy |
| BIZ-17 | Lifecycle (audit) | CHANGE | P2 | Suspend, reactivate and all setup_save_* record only new_data (DB-13 requires before and after); a failed audit write is only logged and the change stands. | index.ts:1145-1215,1268-1280,1121-1130; ZELLA_VOICE_RULES.md:388 | Write old_data; raise a platform alert on audit failure. | Every lifecycle and setup audit row has old and new. | deploy |
| BIZ-18 | Verification (storage) | CHANGE | P2 | Owner photo IDs and registrations kept forever; replaced copies stay in the bucket; unconfirmed uploads leave orphans; nothing deletes documents after cancellation (PRV-4). | onboarding.ts:218-230,247-249; zella_onboarding.sql:7-8,47-48 | Retention period (legal review); remove replaced and orphan files; include in purge. | Policy documented; job removes them. | yes (legal, destructive) |
| BIZ-19 | Verification | VERIFY | P2 | "View" opens the 60 second link with window.open after an await, outside the click gesture; popup blockers (Safari) may block it; same in the wizard. | VerificationQueue.jsx:91-99; CreateBusinessWizard.jsx:1308-1316 | Browser run in Safari and Chrome; if blocked, open on click then set location. | Opens in Safari by default. | no |
| BIZ-20 | Verification | CHANGE | P3 | Queue capped at 200 with no paging; totals unbounded (1000 cap); rejecting an already verified document has no effect on the business. | platform.ts:234-236,249-252; VerificationQueue.jsx:197 | Paging; exact counts; decide on revocation. | Queue pages; totals exact. | deploy |
| BIZ-21 | Wizard, detail (invitation) | ADD | P3 | Owner invitations can't be revoked from the admin (REQ-LC-06); Resend has no cooldown and each click sends a real email. | BusinessDetails.jsx:270-277,556-562; index.ts:2729-2780; zella_cancel_invitation exists | Confirmed, audited Cancel invitation; resend cooldown (5 min). | Admin can revoke; repeat resends refused in the cooldown. | deploy |
| BIZ-22 | Detail (support access) | ADD | P2 | Opening a business shows callers' full numbers, members' emails and invitation errors with no audit of the access (REQ-LC-19). | index.ts:1512-1515; BusinessDetails.jsx:739-741; mask precedent platform.ts:39 | Audit business_detail reads; mask numbers unless a support reason is given. | Audit shows who opened which business; numbers masked by default. | deploy |
| BIZ-23 | Overview, Businesses, detail | CHANGE | P3 | Write buttons show regardless of role (Create business, Continue or Edit setup, Suspend, Cancel, size, modules, record types); the server refuses afterwards. | OwnerOverview.jsx:73-75; OwnerDashboard.jsx:435-441,616-624; BusinessDetails.jsx:307-311,450-487; BusinessAdminControls.jsx:75-79 | Gate on businesses.manage or businesses.lifecycle; pass me into BusinessDetails. | Read only role sees no write buttons. | no |
| BIZ-24 | Businesses | FIX | P3 | A suspended business that finished setup shows "Continue setup" (businessState returns done false when suspended). | ownerFormat.js:111-116; OwnerDashboard.jsx:622 | Compute done from onboarding_status. | Suspended live business shows "Edit setup". | no |
| BIZ-25 | Activity labels | CHANGE | P3 | Unlabelled actions fall back to raw lowercase keys (business.size_changed, business.document_*, business.operations_updated, business.team_updated, business.record_types_updated, spam.settings_updated, platform.setting_updated). | ownerFormat.js:3-36; onboarding.ts:336-341; platform.ts:473 | Add labels (see ACC-08 shared catalog). | Every action has a label. | no |
| BIZ-26 | All pages (copy) | CHANGE | P3 | Developer jargon and hyphens: "apply sql/zella_onboarding.sql", "Fetching records from your Supabase database", "handed to n8n", "billing.manage", raw RPC errors; "60-minute", "concierge-style", "1-hour arrival window". | BusinessDetails.jsx:260,401,726; VerificationQueue.jsx:143; CreateBusinessWizard.jsx:112,832,1281,1657,1736,1769; OwnerDashboard.jsx:559; PlanStep.jsx:95,192; onboardingConfig.js:284 | Plain words; extend the lint. | Lint flags none. | no |
| BIZ-27 | Businesses (stage labels) | CHANGE | P3 | Stage labels out of date with the step order ("Draft, terminology"; "AI receptionist" while the wizard resumes at Team). | ownerFormat.js:38-53; CreateBusinessWizard.jsx:53-79 | Derive from RESUME_STEP. | Label names the step it reopens at. | no |
| BIZ-28 | Wizard (result) | CHANGE | P3 | Invitation badge shows raw status words; readiness rows show "None" as a marker. | CreateBusinessWizard.jsx:2211,1789-1791; BusinessDetails.jsx:144 | Humanise; "Later" or an icon. | No raw keys. | no |
| BIZ-29 | Businesses (payload) | REMOVE | P3 | dashboard_data returns every business_members row plus totalMembers and totalSubscriptions, unused by the page. | index.ts:3081-3083,3133-3134,3144-3145 | Drop them. | No members array. | deploy |
| BIZ-30 | Detail (a11y, navigation) | CHANGE | P3 | Tabs lack aria-controls, tabpanel and arrow keys; selected tab not in the address; calls (10) and activity (30) have no "see all". | BusinessDetails.jsx:381-394,153-157; index.ts:1512-1520 | Tabpanels, arrow keys, /businesses/<id>/<tab>, links to filtered audit logs. | Tab survives reload. | no |
| BIZ-31 | Detail (verification card) | CHANGE | P3 | "Review" opens the setup wizard instead of the Verification page, even for cancelled businesses. | BusinessDetails.jsx:398-399,307 | Link to /verification filtered; hide when cancelled. | Review opens the queue. | no |
| BIZ-32 | PRODUCT.md | CHANGE | P3 | Wizard sequence omits the Plan and pricing step; Overview row claims platform health and alerts that the page doesn't show; Businesses row omits cancel, undo, resend. | PRODUCT.md:305-308; CreateBusinessWizard.jsx:53-64; OwnerOverview.jsx:95-118 | Update PRODUCT or add a status and alerts summary to Overview. | Claims match code. | no |
| BIZ-33 | Wizard (plan step permission) | VERIFY | P3 | Wizard needs businesses.manage but the plan step needs billing.manage, so most roles that create businesses can't finish alone; hand off undocumented. | OwnerDashboard.jsx:219; PlanStep.jsx:8-9,94-96; zella_billing_allowances.sql:320 | Live read of platform_role_permissions; document the hand off. | Role matrix confirmed and documented. | no |

Cross cutting: several admin writes skip the edge function and call RPCs from the browser (zella_set_business_size, zella_admin_plan_save, zella_business_voice_save), each with its own, inconsistent check; readiness exists three times with three definitions (detail page in the browser, zella_business_readiness, zella_activation_report); lifecycle operations without an admin path: draft delete, retention purge, invitation revoke, go live.

## Configuration (Industry configuration, Modules and features, Plans and subscriptions, Offers and promotions)

Pages: /industries (IndustryConfiguration.jsx, IndustryRecords.jsx; actions industries_list, industry_save, industry_create, industry_records_get, industry_records_save in index.ts:1638-1835 and platform.ts:20-176), /modules (ModulesPage.jsx; modules_overview index.ts:2463), /plans (PlansPage.jsx; plans_list, plan_save index.ts:2334-2405; shared plan prices and limits edited in Settings PlanEntitlements AdminPanels.jsx:530-576; real per business plans in business_plans, sql/zella_billing_allowances.sql), /offers (OffersPage.jsx; zella_offer_* RPCs in sql/zella_offers.sql). BillingPanels.jsx, UsageLive.jsx and billing.css are CRM or wizard only.

| ID | Page | Type | Sev | Item | Evidence | What to do | Done when | Approval |
|---|---|---|---|---|---|---|---|---|
| CFG-01 | Industries | FIX | P1 | Switching a module off for an industry turns it off at once for every existing business in that industry; the page says "businesses keep the modules they already have"; no confirmation. | IndustryConfiguration.jsx:337-339,414; zella_module_on needs im.is_active (zella_navigation.sql:33-46; 05_functions_3.sql:45-57; nav :73-77) | Correct the copy and confirm with "N businesses lose X", or keep it on for existing businesses. | Copy matches zella_module_on; switching off shows the count first. | copy no; SQL yes |
| CFG-02 | Industries | FIX | P2 | Module dependencies not checked at industry level: switch off calls or calendar, then setup lets a business turn on ai-receptionist or ai-appointments without them. | index.ts:120-126,679-681,1729-1760 | Refuse switching off a needed module; treat a missing dependency as an error in saveModules. | ai-receptionist on with calls off is refused. | deploy |
| CFG-03 | Industries | CHANGE | P2 | "AI receptionist defaults" (caller role, staff role, booking word, main service) are saved but nothing reads them; only greeting is used (wizard starting greeting). | IndustryConfiguration.jsx:18-23,401-406; index.ts:1617-1618; CreateBusinessWizard.jsx:273; zella_brain.sql:357-359 | Wire into zella_brain_prompt or remove and relabel the greeting. | Every field changes something a caller hears, or is gone. | yes if prompt SQL |
| CFG-04 | Industries, records | FIX | P2 | First "Save record types" on an industry using the general set changes the industry key from other to a new key; its businesses then see only general automation presets and the receptionist industry branch changes. Not mentioned on the page. | IndustryRecords.jsx:100; platform.ts:168-175; zella_industry_rule_list.sql:10-18,34-35; index.ts:328-333; zella_brain.sql:336 | Warn, or keep key other until presets exist for the new key. | Existing businesses' rule lists unchanged, or the admin confirmed. | deploy |
| CFG-05 | Industries | ADD | P2 | A new industry gets only words and modules: no automation presets (hardcoded by name, so BASE), no receptionist safety and focus rules, no booking model, no sensitive flag (sensitivity is a hardcoded slug list, so a new medical industry would show transcripts to staff). | industryAutomations.js:81-102; zella_brain.sql:380-388; zella_call_content_privacy.sql:17-21; PRODUCT.md:97-100,136-139; MEMORY BIZ-10 | Data driven sensitive flag, booking model and automation defaults per industry; point zella_sensitive_industry and automationDefaultsFor at it. | A new industry can be marked sensitive and the server uses it. | yes (migration) |
| CFG-06 | Industries | CHANGE | P2 | industry_save audit records only terminology and module counts, not which modules were switched or renamed or description changes. | index.ts:1214-1225,1762-1768 | Audit each module's before and after and the description. | Audit log shows "module X switched off". | deploy |
| CFG-07 | Industries | CHANGE | P3 | Save is several writes with no transaction; failure leaves a half save; no concurrent edit check. | index.ts:1708-1760; IndustryConfiguration.jsx:164-169 | One RPC with a version check. | Partial failure changes nothing; stale save refused. | yes (migration) |
| CFG-08 | Industries | ADD | P3 | Industries can't be renamed, deactivated or deleted; inactive ones show with no marker. | index.ts:1640 vs 3063-3067; IndustryConfiguration.jsx:240-253 | Inactive pill and deactivate (careful: presets match on name). | Inactive labelled; wrong industry retirable. | deploy |
| CFG-09 | Industries | CHANGE | P3 | Page gets no permissions; businesses.view admins see Save, New industry, Save record types and get 403. | OwnerDashboard.jsx:67,395; settings.ts:34; platform.ts:22 | Pass me; disable editors without platform.configure. | Read only admin sees a read only page. | no |
| CFG-10 | Industries, records | FIX | P3 | Ticking "In list" for a new field saves a key from the label; editing the label afterwards silently drops the column. | IndustryRecords.jsx:139-140; platform.ts:133 | Rebuild columns from current keys on label change. | Renaming keeps the tick. | no |
| CFG-11 | Modules | FIX | P2 | "Businesses using it" counts enabled business_modules rows incl modules off at industry level; read is unbounded and hits PostgREST max_rows 1000; industriesList counts the same way. | index.ts:2464-2467,2475-2480,1645; config.toml:18 | Count in SQL joined with im.is_active, or page. | Counts match zella_module_on. | deploy |
| CFG-12 | Modules | VERIFY | P2 | Production API max rows value decides whether CFG-11 and CFG-21 truncate today. | config.toml:18 (local only) | Read the production setting. | Value recorded in SCHEMA_STATUS. | no |
| CFG-13 | Modules | FIX | P3 | "All industries" compares offering industries incl inactive with the active count. | ModulesPage.jsx:58; index.ts:2483-2484,2503 | Count only active industries. | Label right with an inactive offering industry. | deploy |
| CFG-14 | Plans | CHANGE | P1 | /plans shows the old shared plans catalog, not the live model (business_plans per business, Base or Pro, versioned, applied 14 Nov). No business_plans, versions, prices, allowances or balances; Subscriptions shows "Unknown plan" because subscriptions.plan_id is empty for business plans. | MEMORY.md:142-146; PRODUCT.md:388; zella_billing_allowances.sql:19,1007; index.ts:2357-2358; PlansPage.jsx:161-164 | Rebuild /plans around business_plans (tier, version, price, interval, allowances, link to PlanStep); demote or hide the shared catalog. | Every business with a plan appears with its version; no "Unknown plan". | deploy |
| CFG-15 | Plans | FIX | P2 | Cards always say "Pricing not configured" and the banner says prices "haven't been decided"; in fact shared prices can be set in Settings and pricing is decided per business, Stripe at step 4. | PlansPage.jsx:82-83,128; index.ts:2337; AdminPanels.jsx:559-561; settings.ts:433-444 | Banner: prices set per business in Create Business; payments aren't connected so nothing is charged. | Copy matches MEMORY and stored data. | no |
| CFG-16 | Plans | CHANGE | P2 | Shared plan limits are the fallback for businesses with no business_plans row; editing them changes live limits immediately, unversioned, breaking "a plan change applies from the period it starts in". | zella_billing_allowances.sql:370-391; settings.ts:441-445; MEMORY.md:190 | Read only, version them, or retire the fallback. | Editing a shared plan can't change a live business mid period. | yes (migration) |
| CFG-17 | Plans | CHANGE | P2 | Shared plan prices in major units (2 dp) and five currencies; billing elsewhere is USD cents only; offer discount maths uses these prices x 100. | settings.ts:433-440; AdminPanels.jsx:561; zella_billing_allowances.sql:63-65; zella_offers.sql:745-748 | Minor units, USD only, or drop shared prices. | No decimal or non USD admin control. | yes (migration) |
| CFG-18 | Plans | CHANGE | P2 | "Available for new businesses" has no effect on new businesses; plans.is_active is read only by the (off) billing webhook to match a slug, so hiding a plan would make plan_changed events unknown_plan. | PlansPage.jsx:97-101; PlanStep.jsx:19-40; zella_billing_hardening.sql:178-179 | Relabel ("Accepted from the payment provider") or remove; show the slug. | Label matches server behaviour. | no |
| CFG-19 | Plans | CHANGE | P2 | plan_save needs plans.manage; the real zella_admin_plan_save needs billing.manage (REQ-BIL-10); no UI gating, billing.view users see New plan and Edit and get 403. | settings.ts:36,43; zella_billing_allowances.sql:320; PlansPage.jsx:75-77,138-144 | One permission; pass me and hide editors. | Same permission both paths; editors hidden for view only. | deploy |
| CFG-20 | Plans | FIX | P3 | Editing can rename a plan to another plan's name (duplicate check only on create); comment says prices never reach the browser but plans_list sends them. | index.ts:2374-2390,2324-2326,2337 | Check duplicates on update; fix comment or strip prices. | Renaming to an existing name refused. | deploy |
| CFG-21 | Plans | CHANGE | P3 | Subscriptions table unbounded and duplicates the paged Settings subscriptions list. | index.ts:2339; AdminPanels.jsx:581-601 | Link to Settings or page via subscriptions_list. | One paged list. | deploy |
| CFG-22 | Plans | ADD | P2 | No admin screen grants packs or adjustments (REQ-BIL-10) or shows a business's balances; zella_admin_pack_grant and zella_billing_overview exist with no admin caller. | zella_billing_allowances.sql:891-916,943 | Balances plus "grant pack, with reason" on business detail or /plans, gated by billing.manage. | Admin grants a pack with a reason and it is audited. | no |
| CFG-23 | Offers | FIX | P2 | Every offer RPC checks is_platform_admin() (zella_owner, super_admin only); nav and PRODUCT give the page to billing.view, so billing_admin sees it and every call fails. REQ-BIL-10 wants billing.manage. | OwnerDashboard.jsx:70; PRODUCT.md:312; 05_functions_1.sql:886-898; zella_offers.sql:391,459,704,713,877; zella_settings_system.sql:62 | zella_admin_can('billing.view') for reads, 'billing.manage' for changes. | billing_admin can use /offers; read_only_admin can't change it. | yes (migration) |
| CFG-24 | Offers | FIX | P2 | Admin applies, claim cancels and reversals aren't in audit_logs (zella_offer_log skips kinds starting with "claim"); the apply note is optional though REQ-BIL-10 requires a reason. | zella_offers.sql:222,579,721,700-706; OffersPage.jsx:794-799 | Audit admin claim actions; require a note. | Apply or reversal appears in Audit logs with reason. | yes (migration) |
| CFG-25 | Offers | CHANGE | P2 | "Applied. It waits for the business's next payment." implies payments exist; Stripe isn't built, so every claim (incl negotiated deals) sits pending and is silently released after the 14 day hold. | OffersPage.jsx:668; zella_offers.sql:577; MEMORY.md:146 | Say plainly payments aren't connected and when the claim is released; consider pausing the release rule until step 4. | No copy implies a charge; negotiated deals don't lapse unnoticed. | no |
| CFG-26 | Offers | FIX | P2 | Discount value and eligibility facts use the old model (plans.price_* via subscriptions.plan_id, empty for business plans), so "Discount given" is always unknown and interval, trial and status rules ignore business_plans; "Annual plan promotion" can never match. | zella_offers.sql:745-748,307-326; zella_billing_allowances.sql:19; OffersPage.jsx:1127 | Use zella_billing_plan_current (price_cents, billing_interval, trial). | Yearly business plan matches a yearly rule; discounts computed. | yes (migration) |
| CFG-27 | Offers | CHANGE | P3 | Currency loose: editor hardcodes usd, server accepts any code, reports sum any currency as USD; "Billing connected" turns true after any processed billing_events row (one test event unlocks intro pricing). | OffersPage.jsx:301,362,117-118; zella_offers.sql:39,1061-1062,156-160 | USD only; key on a real Stripe connection setting. | Non USD refused; capability not set by a test event. | yes (migration) |
| CFG-28 | Offers | CHANGE | P3 | Cancel and "Mark reversed" use window.prompt; "Mark reversed" relabels a paid claim without a refund. | OffersPage.jsx:681-694,821; zella_offers.sql:757-763 | Inline confirm panel with note; explain no money moves. | No window.prompt on admin pages. | no |
| CFG-29 | Offers | CHANGE | P3 | Lookups load through dashboard_data: every business with members and invitations, needs businesses.view, and runs zella_process_cancellations as a side effect of opening the page; inactive industries show as "an industry". | OffersPage.jsx:171-176; index.ts:3049-3050,2532-2535,3063-3067 | Light lookup action with no side effects. | Opening /offers writes nothing. | deploy |
| CFG-30 | Offers | CHANGE | P3 | Hyphens ("Claim-to-paid", "view-to-claim"); "Standard plan prices never change" refers to prices that don't exist; time zones include Asia/Kolkata though launch is US only (D-14). | OffersPage.jsx:1125,1131,454,77 | Reword; "the business's plan price"; trim zones. | Copy passes the writing rule. | no |
| CFG-31 | Offers | CHANGE | P3 | Offer detail loads all redemptions unbounded (events capped at 100); PRODUCT marks offers "Built" without saying claims can't confirm before payments. | zella_offers.sql:906,911-914; PRODUCT.md:401 | Page redemptions; qualify PRODUCT. | Status claim matches behaviour. | yes (migration) |
| CFG-32 | Industries | VERIFY | P3 | PRODUCT says Pet Care and Veterinary is not regulated but zella_sensitive_industry treats it as sensitive; confirm the live count is 28. | PRODUCT.md:112,309; zella_call_content_privacy.sql:19 | Owner decides; read live industries. | Doc and function agree. | no |

Cross cutting: two billing models (admin pages show the old shared plans; live is business_plans in USD cents); payments not built but copy implies pending configuration; permission checks differ by path and neither page hides edit controls; industry behaviour keyed on names and slugs.

## AI and communications (AI agents, Voice and numbers, Messaging, emails to businesses)

Pages: /agents (AIAgents.jsx; agents_list in owner-provision-business index.ts:1844), /voice/<overview|numbers|calls|routing|providers> (admin/VoiceNumbersPage.jsx; embeds TelephonyProviders, VoiceUsage, VoiceCosts from settings/AdminPanels.jsx; sql/zella_admin_ops.sql; number_assign, number_set_status in settings.ts:484; voice-rules), /messaging/<overview|sms|email|templates|business-emails|providers|compliance> (admin/MessagingPage.jsx, admin/BusinessEmails.jsx, emails/businessEmails.js re-exporting _shared/businessEmails.js; sql/zella_platform_emails.sql, sql/zella_email_delivery.sql, platform-emails).

Confirmed sound: sms_live, email_live and calls_live are read from the real values (zella_admin_ops.sql:94, 328-332; settings.ts:533), are deliberately not in EDITABLE_SETTINGS (index.ts:2808), platform_settings is writable only by service_role (10_table_grants.sql:1149), and direct changes are audited by zella_audit_privileged_trg. Every zella_admin_* read checks businesses.view; changes check telephony.manage or comms.manage, need a reason and write an audit row.

| ID | Page | Type | Sev | Item | Evidence | What to do | Done when | Approval |
|---|---|---|---|---|---|---|---|---|
| COM-01 | AI agents | FIX | P1 | Phone and Voice checks (and "Live") come from integrations rows with provider telnyx or vapi, which nothing writes (only shopify, zella_store_orders.sql:39); Voice and numbers uses business_phone_numbers and vapi_phone_number_id. Every receptionist likely shows Not connected, Live 0, and "Ready to connect" counts every set up agent. | index.ts:1871-1874,1900-1901; AIAgents.jsx:27; VoiceNumbersPage.jsx:116 | Derive phone from an active business_phone_numbers row and voice from vapi_phone_number_id plus a recent served assistant_deliveries row; same rule in zella_readiness. Confirm with a live read. | An active linked number shows Phone and Voice yes; Live matches Voice and numbers. | deploy |
| COM-02 | AI agents | FIX | P2 | Knowledge and Hours checks read setup JSON; the receptionist answers from knowledge_items and business_hours. CRM added knowledge isn't counted; never applied setup answers count as ready. | index.ts:1889-1898; zella_config_migration.sql:82-86; zella_admin_ops.sql:229 | Count ready knowledge_items, business_hours rows and services. | Checks match what the receptionist can use. | deploy |
| COM-03 | AI agents | ADD | P2 | No way to see whether a receptionist is really answering: assistant_deliveries (served, not_ready, unknown_number; REQ-VOX-01) and the served config version are never shown. | AIAgents.jsx:113-180; BACKEND_SCHEMA.md:1878; ARCHITECTURE.md:983; PRODUCT.md:313 | Columns for last delivery outcome and time, not_ready count (7 days), live version; drawer with recent deliveries. | An admin sees that a business's calls get not_ready, and why. | yes (migration) |
| COM-04 | AI agents | VERIFY | P2 | "Edit setup" opens the wizard even for live businesses; setup_save_receptionist overwrites ai_agent_configs directly with no draft or version, while PRODUCT 7.2 describes versioned publishing. | AIAgents.jsx:162; OwnerDashboard.jsx:399; index.ts:778-826; AdminPanels.jsx:770 | Check whether zella_assistant_for_call reads ai_agent_configs or agent_config_versions; route post setup edits through the versioned editor. | A browser run shows a version created and the next call serving it. | no |
| COM-05 | AI agents | CHANGE | P3 | "Edit setup" shown to every admin (page never gets me); a businesses.view role gets a server refusal on save. | AIAgents.jsx:48,162; OwnerDashboard.jsx:397-400; settings.ts:29 | Pass me and hide without businesses.manage. | View only role sees no Edit setup. | no |
| COM-06 | AI agents | CHANGE | P3 | List not paged; calls capped at 10000 platform wide so counts undercount; server stats.live counts status only and disagrees with the UI; Settings agent registry shows raw status. | index.ts:1856-1860,1928; AdminPanels.jsx:759 | Count calls per business on the server; fix stats.live; page past about 100. | Counts right above 10k calls; one Live definition. | deploy |
| COM-07 | AI agents | CHANGE | P3 | Name inconsistency (nav "AI Agents", heading "AI receptionists", column "AI calls (30 d)"); filter buttons role=tab with no tabpanel; check state only in title tooltip and colour. | OwnerDashboard.jsx:71; AIAgents.jsx:68,90-101,121,145 | One name; "Last 30 days"; aria-pressed; visible or screen reader state. | Passes a11y check. | no |
| COM-08 | Voice, overview | FIX | P2 | "Needs attention" filters alert kinds nothing raises (transfer_failures, stuck_calls, call_verification, vapi_webhook, calls_unverified); real ones (repeated_transfer_failures, ai_call_failure, agent_failures, agent_sync_failed, call_not_summarized) never show. Same in production. | zella_admin_ops.sql:299; zella_run_all.sql:1599; 05_functions_1.sql:2247,4666 | Correct the kind list in zella_admin_voice_alerts. | Raised voice alerts appear. | yes (migration) |
| COM-09 | Voice, overview and providers | ADD | P2 | The open Vapi call authentication 401 problem is invisible: voice-rules only logs refused requests to the console; nothing raises vapi_webhook; vapi_auth_mode not shown. | voice-rules/index.ts:78-83; zella_admin_ops.sql:299; MEMORY.md:96,102 | Hourly count of refused requests by message type (no payload) with an alert above 0; show auth mode and last refusal. | After a test call, refused status updates and end of call reports are visible. | yes (deploy, migration) |
| COM-10 | Voice, call routing | CHANGE | P2 | Routing edits escalation_rules.fallback_number, which REQ-BIL-34 makes required and usage enforcement forwards to at 100%; the form allows clearing it and has no check against the forwarded line (setup refuses that because calls loop). | VoiceNumbersPage.jsx:299; zella_admin_ops.sql:245-251; zella_usage_enforcement.sql:3,68; index.ts:917 | Refuse empty and same as forwarded line in zella_admin_routing_save; relabel. | Clearing or looping the fallback is refused clearly. | yes (migration) |
| COM-11 | Voice, numbers | CHANGE | P3 | Client accepts 7 to 15 digits, server 8 to 15; server doesn't require a reason for assign or reassign, doesn't refuse cancelled or suspended businesses; reassign has no in progress call check. | VoiceNumbersPage.jsx:168,178; settings.ts:487,504 | One rule; server reason (3+ chars); refuse closed businesses; warn on a call in the last 24 h. | Server refuses no reason or closed business. | deploy |
| COM-12 | Voice, numbers | CHANGE | P2 | Assign takes any Vapi phone number ID with no check it belongs to the number typed: how the open "number and ID match two businesses" problem can be created. | VoiceNumbersPage.jsx:181; settings.ts:488; MEMORY.md:109 | Owner decision on zella_business_for_number pending; meanwhile warn in the dialog. | Owner decided; guard or warning shipped. | owner decision |
| COM-13 | Voice, overview | ADD | P3 | Only a banner when calls are off; usage_enforcement.calls and timed jobs (stuck call sweep, reconcile) not shown. | VoiceNumbersPage.jsx:61; zella_admin_ops.sql:94; MEMORY.md:93-96 | Read only Switches panel: calls_live, enforcement for calls, vapi_auth_mode. | All three show true value. | yes (migration) |
| COM-14 | Voice, calls and routing | CHANGE | P3 | Copy "{status} to {error}", lowercase "on call rota"; call drawer drops failure_context returned by the server. | VoiceNumbersPage.jsx:243,306; zella_admin_ops.sql:198 | "Failed: ..."; "On call rota"; show failure context. | Copy review passes. | no |
| COM-15 | Voice, providers | REMOVE | P3 | Embedded TelephonyProviders repeats the calls switch and key state; its number count comes from numbers_list capped at 500. | VoiceNumbersPage.jsx:337; AdminPanels.jsx:798-807; settings.ts:479 | One provider summary using zella_admin_voice_overview. | One source per fact. | no |
| COM-16 | Messaging, overview | CHANGE | P2 | "Sent" tiles count every outbound row incl test mode, blocked, queued, failed: non zero while sending is off. | zella_admin_ops.sql:312,317; MessagingPage.jsx:68,77 | Label "Recorded" or count only sent and delivered. | Sent is 0 while sms_live and email_live are off. | relabel no, SQL yes |
| COM-17 | Messaging, overview | FIX | P2 | Needs attention omits platform_email_held; every platform alert links to the Texts tab, including email ones. | zella_admin_ops.sql:586-587; zella_email_delivery.sql:145 | Add platform_email_held linked to business emails; route email kinds to Emails. | A held email appears with a working Open. | yes (migration) |
| COM-18 | Messaging, emails to businesses | ADD | P2 | A held email has no action although the alert says check it before sending again; no release, resend or discard. A failed send goes back to queued or held, never failed, so the Failed filter is always empty. | zella_platform_emails.sql:98-103,124-129; BusinessEmails.jsx:9-10,93-97 | zella_admin_platform_email_release and _discard (comms.manage, reason, audit) plus a drawer with preview; fix or drop the Failed filter. | Admin can release or discard; audit shows it. | yes (migration) |
| COM-19 | Messaging, emails to businesses | FIX | P3 | With the Resend key or sender missing, the function returns before any claim, so queued rows never become test mode and the dispatcher calls every minute once triggers and job are on; contradicts the page copy. | platform-emails/logic.ts:118; zella_email_delivery.sql:175-179; BusinessEmails.jsx:84 | Still claim when email_live is off, or dispatcher skips when email_live is off. | No key and email_live off: rows test mode, no repeated calls. | deploy |
| COM-20 | Messaging, emails to businesses | CHANGE | P2 | The notification is marked "sent" once queued, even when the outbox then marks it test mode or suppressed. History says emailed when nothing left. | platform-emails/logic.ts:114; zella_email_delivery.sql:148-149 | Record "queued", set final result from the outbox. | With email_live off, history shows not sent. | yes (migration, deploy) |
| COM-21 | Messaging, emails to businesses | CHANGE | P2 | Hardcoded and outdated copy ("once it is installed", "No sender is connected yet"; applied and deployed 15 Nov); shows a file path; members who left show as "Switched off by the person". | BusinessEmails.jsx:9-10,30,84; zella_email_delivery.sql:138 | Drive copy from live state; remove path; "No longer a member" label. | Text matches live state. | no |
| COM-22 | Messaging, emails to businesses | ADD | P3 | No business filter (RPC supports p_business); clicking a row leaves the page instead of showing the email. | BusinessEmails.jsx:81,93; zella_platform_emails.sql:136 | Business select and email drawer. | Filter and drawer work. | no |
| COM-23 | Messaging, providers | CHANGE | P2 | Sender address and sender number (go live steps needing approval) save with a plain Save bar: no confirmation, reason or warning (it is audited). | MessagingPage.jsx:279-281; AdminPanels.jsx:740-747,934,954; index.ts:1142 | Confirm dialog with before and after, reason, warning. | Saving a sender needs confirmation and a reason. | deploy |
| COM-24 | Messaging, providers | REMOVE | P3 | Sending state shown twice from two sources (zella_admin_messaging_overview and embedded SmsConfig/EmailConfig via comms_overview). | MessagingPage.jsx:268-282; AdminPanels.jsx:928,949 | Keep one. | One sending state per channel. | no |
| COM-25 | Messaging, providers | VERIFY | P2 | Texts go from one platform wide sms_from_number; REQ-LC-10 and REQ-COM-ISO-02 say each business's own number; REQ-BIL-13 says no customer texts before that business's 10DLC is approved; no page shows 10DLC state. | zella_sms_sender.sql:37; ARCHITECTURE.md:405,932,1529,1793; MessagingPage.jsx:271 | Owner decides if the single sender is intended for now; otherwise per business sender plus 10DLC status. | Decision recorded in MEMORY. | owner, provider |
| COM-26 | Messaging, texts and emails | CHANGE | P2 | Email lists and detail return from_email unmasked (for inbound, the customer's address) to any businesses.view admin; texts mask both ends; email detail returns all metadata. | zella_admin_ops.sql:378,443,446,432 | Mask inbound from_email; strip body like metadata keys. | Inbound address column masked. | yes (migration) |
| COM-27 | Messaging, templates | FIX | P3 | Script guard is case sensitive (~ not ~*) so <SCRIPT and JavaScript: pass; variable chip appends at end, not at cursor; no version history. | zella_admin_ops.sql:521; MessagingPage.jsx:228 | ~*; insert at cursor; versions list. | Uppercase variant refused. | yes (migration) |
| COM-28 | Messaging, drawer and overview | CHANGE | P3 | Dashes and brand: "follow-up", "opt-outs", lowercase "follow ups due now", server reason "Only messages Zella sent can be retried." (missed by writing cleanup); repo zella_admin_ops.sql still has dashed wording production replaced. | MessagingPage.jsx:87-89,181; zella_admin_ops.sql:396,412,423 | Fix copy; add :396 to cleanup; align repo source with production. | No dashes; says "Zella Voice". | yes (server text) |
| COM-29 | Messaging, consent | ADD | P2 | Counts only: no lookup of why one number or address gets no messages (consent, opt out, do not contact, spam block), the usual NN-8 support question. | MessagingPage.jsx:287-310; zella_admin_ops.sql:540-553 | Business scoped lookup (4+ digits) showing consent and last block reason, audited. | Admin finds why a customer's texts are blocked. | yes (migration) |
| COM-30 | PRODUCT.md | CHANGE | P3 | PRODUCT says email delivery is "Built, not applied or deployed" (applied and deployed 15 Nov) and "92 emails" (catalogue has 93). | PRODUCT.md:438,440; MEMORY.md:78,121 | Update PRODUCT.md. | Docs match. | no |
| COM-31 | Voice and Messaging | CHANGE | P3 | Tabs use role=tablist/tab without tabpanel, aria-controls or arrow keys; Providers refetches overview on each tab change. | adminOps.jsx:97-107; VoiceNumbersPage.jsx:328; MessagingPage.jsx:264 | Finish ARIA tabs or use links with aria-current. | Passes a11y check. | no |
| COM-32 | Emails (platform-emails) | VERIFY | P2 | Delivery path untested end to end: platform_emails_url empty, triggers and job off, no Resend key. | zella_email_delivery.sql:39-40,192-193,210,224; platform-emails/index.ts:27 | Staging: set URL and sender, one demo business with a test inbox, email_live on there, send one N1. | One email arrives with a provider id; a second run doesn't resend. | live switch, provider |

Cross cutting: three readiness signals disagree (AI agents uses integrations and setup JSON; Voice uses business_phone_numbers; the receptionist uses knowledge_items, business_hours and assistant_deliveries); alert kinds consumers filter on don't match the kinds producers raise (a shared constant or a cross check test would stop this); the Vapi 401 problem can't be watched from the admin.

## Operations (Platform operations, Automations, Integrations, Support, Security and abuse, alerts bell, status page)

Pages: /operations (PlatformOperations.jsx, PlatformMonitoring.jsx, admin/loadState.jsx, admin/loadStatus.js), /automations/<tab> (admin/AutomationsPage.jsx, adminOps.jsx, AutomationOverview.jsx, automationCatalog.js), /integrations (IntegrationsPage.jsx), /support (SupportTickets.jsx), /security-abuse (SecurityAbuse.jsx; SpamPage.jsx is CRM only, BusinessApp.jsx:405), AdminAlertsBell.jsx + liveAlerts.js, StatusPage.jsx. SQL citations are sql/baseline unless a sql/*.sql file is named.

| ID | Page | Type | Sev | Item | Evidence | What to do | Done when | Approval |
|---|---|---|---|---|---|---|---|---|
| OPS-01 | Status page | FIX | P1 | Overall line treats "unknown" as healthy: with every check unknown (provider checks off in production) the public page still says "Everything is working". | sql/zella_status.sql:42,73-75; StatusPage.jsx:14-18,43; MEMORY.md:93-96 | Rank unknown above operational; add an overall "not fully monitored" state. | All unknown never shows "Everything is working". | yes (migration) |
| OPS-02 | Status page | FIX | P1 | "Reminders and follow ups" shows Working whenever the n8n address is set and dispatch switch on, even with the zella_dispatch job inactive (true in production); the heartbeat that would downgrade it runs in a job that is also off. | sql/zella_status.sql:54-57,84-106; 05_functions_1.sql:2100-2117 | Also require the dispatch cron job active and recently succeeded, else unknown. | With the job off, automations read unknown or not running. | yes (migration) |
| OPS-03 | Operations, incidents | FIX | P1 | Opening, resolving and publishing an incident writes no audit row, though it notifies every owner and changes a public page. | 05_functions_3.sql:1519-1536,4139-4155; 05_functions_4.sql:1315-1331; 07_triggers.sql | Audit all three RPCs (title, public before/after, component, note). | Each action leaves an audit row naming the admin. | yes (migration) |
| OPS-04 | Operations, bell | FIX | P1 | Incidents, provider health, failed event retry and bell acknowledge require is_platform_admin() (zella_owner or super_admin only). A platform operations role that sees the page via businesses.view gets NOT_ALLOWED on every panel; incident RLS also uses is_platform_admin. PRODUCT.md:316 says businesses.view. | 05_functions_1.sql:886-899; 09_policies.sql:189; PlatformMonitoring.jsx:41,85,141; OwnerDashboard.jsx:74 | Move to zella_admin_require('<perm>') with named permissions; show a role message instead of a raw error. | Ops role with the grant can use every panel; without it sees a clear message. | yes (migration) |
| OPS-05 | Operations, failed events | FIX | P1 | Ops "Retry" resets attempts and requeues with no replay safety check, while the Automations retry refuses when a step succeeded or a provider was called (could repeat a message). Different permission, no confirmation, no reason. | PlatformMonitoring.jsx:82-89,111; 05_functions_3.sql:4318-4331 vs 05_functions_1.sql:2007-2050 | Route through zella_admin_run_retry_check or remove and link to /automations/failed; require a reason. | Ops retry refused when a provider already acted; reason recorded. | yes (migration) |
| OPS-06 | Support | FIX | P1 | Internal admin notes live in support_tickets.metadata.notes; business members have SELECT on the whole table, so an owner can read the notes and author ids through the API although the UI says only Zella Voice admins see them. | owner-provision-business/index.ts:2306-2311; 09_policies.sql:222; 10_table_grants.sql:758; SupportTickets.jsx:222 | Move notes to an admin only table, or revoke the column and read through an RPC. | A business member selecting metadata gets no admin notes. | yes (migration) |
| OPS-07 | Integrations | FIX | P1 | "Connected" for phone, voice, calendar, email and leads reads only the integrations table, which only the store connection writes; numbers, calendars and Meta live in other tables, so most columns likely show not connected and "Waiting to connect" is inflated. Same source feeds Ops "Integration problems". | index.ts:2133-2165,2418; sql/zella_store_orders.sql:39 | Compute from phone_numbers, ai_agents, calendar_connections, meta_connections, email connections; confirm with a live provider count read. | A business with a number, assistant or calendar shows connected. | deploy |
| OPS-08 | Operations, health | FIX | P2 | Provider rows show OK regardless of checked_at age; the status page treats >6 h as unknown. Same gap in adminOps ProviderHealth. | PlatformMonitoring.jsx:64-68; adminOps.jsx:338; sql/zella_status.sql:47 | Show "Stale, last checked X" after 6 h. | Old checks never read OK. | no |
| OPS-09 | Operations, services | CHANGE | P2 | "n8n (automations and emails)" reflects N8N_WEBHOOK_URL, used only by lifecycle emails; the dispatcher uses n8n_base_url and a Vault secret, not shown; N8N_WEBHOOK_SECRET not listed. | index.ts:2447,2589-2592; 05_functions_2.sql:2108-2116; PlatformOperations.jsx:17-23 | Relabel; add dispatcher address, secret, job on/off (zella_admin_scheduler_health). | Services card matches what the dispatcher needs. | no |
| OPS-10 | Operations | CHANGE | P3 | Missing counts coerced to 0 on the server (defeats client "Unknown"); page calls automation_overview (reads up to 10000 executions) for one flag; that action ignores its query errors. | index.ts:2428; PlatformOperations.jsx:11,20; settings.ts:543-562 | Return null for missing counts; read the flag directly; throw on errors. | Unread counts show Unknown; one light call. | no |
| OPS-11 | Operations, incidents | CHANGE | P2 | Owner facing incident title is shown publicly; publish prompt is prefilled with the owner detail; uses window.prompt unlike ReasonDialog elsewhere. | PlatformMonitoring.jsx:150-164; sql/zella_status.sql:68 | Separate public title; proper dialog with empty default and counter. | Nothing reaches /status unless typed for the public. **Fixed on branch `claude/lane-a-incidents`:** dialogs instead of browser prompts, and the public status text is never prefilled; a separate public title is not built. | yes (migration) |
| OPS-12 | Operations, incidents | ADD | P2 | No incident updates or timeline, no edit after opening, list capped at 20 with no paging, no duplicate guard. | PlatformMonitoring.jsx:120-127,137-147; 05_functions_3.sql:1519 | Add update posts, paging, similar open incident warning. | Admins can post progress and see older incidents. **Fixed on branch `claude/lane-a-incidents`:** timeline of updates (internal unless Tell affected businesses), edit, Load more, similar open incident warning (sql/zella_incident_updates.sql, built, not applied); public updates on /status not built yet. | yes (migration) |
| OPS-13 | Status page | CHANGE | P2 | One failed fetch (even the visitor's network) replaces the page with an outage style "We can't reach Zella Voice" and drops the last good data. | StatusPage.jsx:23-26,34,43-46 | Keep last result with a "couldn't refresh" note; outage text only after repeated failures. | A single dropped request doesn't declare an outage. | no |
| OPS-14 | Bell | FIX | P2 | Two acknowledge paths: bell RPC (owner and super admin only) writes no audit; Settings alerts (alert_set, support.manage) is audited. Bell shows raw errors like NOT_ALLOWED. | AdminAlertsBell.jsx:66-72; 05_functions_1.sql:1244-1255; settings.ts:600-607,729 | Bell uses alert_set; map errors through friendlyError. | Bell acknowledges are audited and permission checked. | maybe |
| OPS-15 | Bell | CHANGE | P2 | "Open monitoring" goes to Platform operations, which has only alert counts; the actionable list is in Settings. Bell rows have no business name or link. | AdminAlertsBell.jsx:6-7,109; OwnerDashboard.jsx:320; PlatformMonitoring.jsx:60-61; settings/AdminPanels.jsx:1251-1252 | Link to the alerts list or add an open alerts panel with acknowledge and resolve on /operations; show business. | The bell link lands where alerts can be handled. | no |
| OPS-16 | Automations, infrastructure | REMOVE | P2 | Embedded N8nConfig duplicates the dispatcher state and switch on the same tab, and its "Dead letters" counts all while Overview counts unresolved: two different numbers on one page. | AutomationsPage.jsx:314-321; settings/AdminPanels.jsx:1059-1069; settings.ts:545 | Drop the duplicate card or filter to unresolved. | One dead letter number. | no |
| OPS-17 | Automations | ADD | P2 | Dispatcher never reads the n8n HTTP response, so an unpublished workflow (404) or wrong secret (401) still shows "Last handed over". | 05_functions_2.sql:2183-2187; AutomationsPage.jsx:314-316 | Record last HTTP status from net._http_response per workflow and show it. | Infrastructure shows n8n response per workflow. | yes (migration) |
| OPS-18 | Automations | CHANGE | P2 | useLoad clears data on every reload (Refresh flashes Loading, failed refresh loses data); DataTable and ErrorNote show two error messages. | adminOps.jsx:57-69,207; AutomationsPage.jsx:59,79,109-110 | Base on useRefreshable with stale state; one error message. | Failed refresh keeps last data labelled stale. | no |
| OPS-19 | Automations, templates | FIX | P3 | "Businesses using it" matches automations to presets by name only; same names across industries cross count, renamed copies drop out. | 05_functions_1.sql:1351-1368 | Store preset id at setup or match name plus industry. | Counts match per industry preset. | yes (migration) |
| OPS-20 | Automations | ADD | P3 | "Pause all for this business" has no "Resume all". | AutomationsPage.jsx:106,120-125; 05_functions_1.sql:1400-1413 | Add business wide resume with reason and audit. | One action resumes what pause all paused. | yes (migration) |
| OPS-21 | Automations | CHANGE | P3 | Copy: "follow-ups" hyphen, lowercase starts, "In-database", "Paused to <reason>", jargon (Dead letters, Correlation id, dispatches). | AutomationsPage.jsx:46,71,155,231,309; automationCatalog.js:9 | Fix casing and hyphens; "Reason: ..."; rename dead letters to "Failures needing review". | No hyphens; labels capitalised. | SQL string: yes |
| OPS-22 | Automations, business tab | CHANGE | P3 | Archived reads "Off" on the business tab but "Archived" on /automations; Paused tone differs. | AutomationOverview.jsx:34; AutomationsPage.jsx:14-15 | One shared status label and tone map. | Same word and colour on both. | no |
| OPS-23 | Integrations | CHANGE | P2 | Both queries unbounded (all integrations, all businesses with setup_data); PostgREST row cap cuts silently past 1000; no paging or filters. | index.ts:2120-2125; IntegrationsPage.jsx:73,110 | Server paging and filters (problem, waiting, provider). | Lists paged and filterable. | deploy |
| OPS-24 | Integrations | CHANGE | P3 | Raw integration_type and provider values shown; disconnected is grey yet counted as a Problem. | IntegrationsPage.jsx:58,113-115 | Humanise values; warning tone for disconnected. | Labels readable, tones match counts. | no |
| OPS-25 | Support | ADD | P2 | Admins can only add internal notes: no reply to the business (REQ-CRM-26), no alert for urgent or cancellation tickets, no age or first response tracking for the 4 business hour target (REQ-BIL-47). | SupportTickets.jsx:211-227; 05_functions_1.sql:4269-4290; ARCHITECTURE.md:1611,1695 | Business visible reply thread; platform alert on urgent, cancellation, plan change; age and first response column with overdue filter. | Admins reply; urgent tickets alert and show overdue. **Fixed on branch `claude/lane-a-support`:** replies the business sees and answers, first response and age in business hours, Waiting too long filter, alerts for cancellation, plan change and urgent (sql/zella_support_replies.sql, built, not applied). | yes (migration) |
| OPS-26 | Support | FIX | P3 | Note cap keeps slice(0,199) then appends, so after 200 notes each new note replaces the previous newest; read modify write loses notes on concurrent saves. | index.ts:50-52,2306-2311 | slice(-199) or a notes table (with OPS-06). | No note lost at cap or concurrently. | deploy |
| OPS-27 | Support | CHANGE | P2 | Only newest 500 tickets, filtered in the browser, no paging, search or truncation notice; raw category keys; any active admin assignable even without support.manage. | index.ts:2191-2196; SupportTickets.jsx:45-47,120,206 | Server filter and paging, search, humanised categories, assignees limited to support.manage. | Ticket 501 reachable; labels readable. **Partly fixed on branch `claude/lane-a-support`:** status and business filters on the server, assignees limited to people who may work tickets; paging stays at the newest 500. | deploy |
| OPS-28 | Operations | CHANGE | P3 | Urgent ticket "Review" link goes to Support, which needs support.manage: dead end for admins without it. | PlatformOperations.jsx:56,104; OwnerDashboard.jsx:77 | Show only with the target page's permission. | No dead end links. | no |
| OPS-29 | Security and abuse | CHANGE | P2 | Missing totals show 0; spamAutomation ignores read errors so a failed read shows the workflow Off and n8n Not connected. | SecurityAbuse.jsx:115,592; platform.ts:310-316 | Return null on errors and render "Not available". | A failed read never shows 0 or Off. | deploy |
| OPS-30 | Security and abuse | VERIFY | P2 | Global block rules keep only the last 10 digits of a phone, so international numbers lose the country code and could match another country's number. | platform.ts:422 | Check zella_spam_* normalisation; test +44 and +1 numbers sharing last 10 digits. | Rule blocks only the intended number, or rules store E.164. | maybe |
| OPS-31 | Security and abuse | CHANGE | P3 | Rule removal takes no reason and its audit omits value and original reason; switching Spam Response or AI off has no confirmation; expired rules show as active; counts capped at 20000 silently. | SecurityAbuse.jsx:452-465,576,581; platform.ts:264,312,446,472 | Reason on remove and switch off; filter expired; exact counts. | Every global change carries a reason. | deploy |
| OPS-32 | Security and abuse | CHANGE | P3 | Hyphens in copy ("false-positive", "Zella Voice - Spam Response", "repeat-offender", "high-risk"); incident rows mouse only; raw lowercase risk level. | SecurityAbuse.jsx:150,250,254,567-569,579,627 | Fix copy; keyboard operable rows. | No hyphens; rows open from keyboard. | no |
| OPS-33 | Operations | CHANGE | P3 | Jargon ("once provider_checks_live is on") and a contradiction (scope banner says providers aren't tested; panel lists provider checks). | PlatformMonitoring.jsx:70; PlatformOperations.jsx:14 | Plain wording. | No internal keys, no contradiction. | no |
| OPS-34 | Operations, failed events | CHANGE | P3 | Failed events capped at 50, no paging or filters, no link to Automations failed runs; its own useAsync. | PlatformMonitoring.jsx:26-38,76 | Top 10 plus "See all in Automations". | Older failures reachable. | no |

Cross cutting: two server permission models (zella_admin_* with named permissions and audit, vs older monitoring RPCs on is_platform_admin with no audit); honesty about health solved on the client but undone on the server (counts to 0, errors swallowed, unknown ranked operational); provider checks and timed jobs off in production make /status and uptime alerts the most misleading surfaces; three loading patterns side by side. Note: the reviewer's OPS-35 (owner-provision-business behind main) is resolved: v18 deployed 16 Nov 2026.

## Access, settings and the admin shell (Users and access, Audit logs, Settings, sign in, routing)

Pages: /users (UsersAccess.jsx; admins_list, admin_invite, admin_update index.ts:1939-2117), /audit-logs (AuditLogs.jsx, ownerFormat.js; audit_logs action index.ts:1567-1609), /settings/<cat>/<page> (SettingsPage.jsx, settings/SettingsWorkspace.jsx, AdminPanels.jsx, PersonalPanels.jsx, AppearancePanel.jsx; settings.ts), shell (App.jsx, mfa.js, authErrors.js, OwnerDashboard.jsx NAVIGATION and routing, router.js, adminPermissions.js, AdminAlertsBell.jsx, BrokenLink.jsx; me_admin and permission maps index.ts:2975-3047). Reachability: all 18 nav items render a page (OwnerDashboard.jsx:381-424); no admin file is unreachable; ReviewsPage, ScorecardsPage and SpamPage are CRM pages by design.

| ID | Page | Type | Sev | Item | Evidence | What to do | Done when | Approval |
|---|---|---|---|---|---|---|---|---|
| ACC-01 | Sign in, account security | FIX | P1 | Two step sign in is enforced only for admins who set it up: a password only platform admin gets full access, and any admin can remove their own factor. Breaks REQ-LC-04 and ARCHITECTURE 1643 ("MFA required for platform staff"). | index.ts:3000-3008 (aal2 only if hasMfa); App.jsx:90-94,318; AdminPanels.jsx:488; PersonalPanels.jsx:156,179-181; ARCHITECTURE.md:926,1643 | Require a verified factor and aal2 for every active platform admin in the function and in zella_admin_role/zella_admin_can; force set up at first sign in; block removing the last factor. | A password only admin gets MFA_REQUIRED on every action and is walked through set up. | yes (deploy, migration) |
| ACC-02 | Settings | FIX | P2 | No permission gating per category: every admin role sees all 17 categories; restricted roles get pages of 403s; PRODUCT says per category and Users says a role with no permissions sees only Settings. | OwnerDashboard.jsx:81; SettingsPage.jsx:26-138; SettingsWorkspace.jsx:61-105; PRODUCT.md:319; UsersAccess.jsx:26 | perm on each category and item; filter by me.permissions; denied state for direct links. | A read only admin with no grants sees only their profile. | no |
| ACC-03 | Shell routing | CHANGE | P2 | Landing page / needs businesses.view, so a restricted role without it always lands on "This page isn't available"; REQ-ADM-01 says Overview is for any role. | OwnerDashboard.jsx:64,218-220,356-360; ARCHITECTURE.md:1721 | Redirect to the first allowed page, or load Overview per permission. | Support or billing only admins land on a usable page. | no |
| ACC-04 | Platform roles end to end | FIX | P2 | Pages shown to restricted roles call functions that allow only zella_owner and super_admin (is_platform_admin): Offers (every zella_offer_*), Platform operations monitoring (health, incidents, retry), the bell "Got it", Settings AI provider health and automation readiness. | OwnerDashboard.jsx:70,74,320; 05_functions_1.sql:886-898,1251; 05_functions_3.sql:1228,1527,4325; PlatformMonitoring.jsx:41,85,141,157,169; AdminPanels.jsx:713,1030,1496; AdminAlertsBell.jsx:69 | zella_admin_require('<perm>') matching the nav permission, or hide for other roles. Same root cause as OPS-04 and CFG-23. | Each page offered to a role works for it. | yes (migration) |
| ACC-05 | Bell | FIX | P3 | "Got it" offered to every businesses.view admin; restricted roles see raw NOT_ALLOWED. | AdminAlertsBell.jsx:69-71,101 | Hide without permission; friendlyError. | No raw codes. | no |
| ACC-06 | Invite and password reset landing | FIX | P2 | After choosing a password at /welcome, the redirect uses is_platform_admin, so restricted role admins go to the CRM /app with no workspace; on the app host / redirects to /app; admin invites use ZELLA_APP_URL/welcome. | BusinessAuth.jsx:354-357; BusinessApp.jsx:536-539; App.jsx:31-33; index.ts:245-247,2025-2028 | Detect admins with zella_admin_role() and send them to the admin address. | A newly invited support admin lands on the admin dashboard. | deploy |
| ACC-07 | Audit logs | CHANGE | P2 | One admin change writes up to three rows (admin.updated from the function plus platform_admin_* and privileged_update from triggers); trigger rows have no actor ("Unknown user") because the function uses the server key. Suspend and cancel produce the same unattributed rows. | index.ts:2102-2106,1238-1244; 05_functions_3.sql:1690-1705; 05_functions_1.sql:3483-3510; 07_triggers.sql:26,71; AuditLogs.jsx:96 | Pass the acting admin to the triggers (set_config) or skip trigger rows when the function audits; label them. | One change gives one attributed, labelled entry. | yes (migration) |
| ACC-08 | Audit logs | CHANGE | P2 | Action filter and labels cover 28 actions; 25+ the server writes are missing (platform.roles_updated, profile, maintenance, setting, plan.entitlements_updated, billing.voice_pricing_added, telephony.*, platform.alert_*, legal.*, platform.spam_*, spam.settings_updated, business.document_*, team, operations, record types, privileged_*, platform_admin_*). | ownerFormat.js:3-32; AuditLogs.jsx:63-66; settings.ts:721-731 | One shared catalog of action names and labels; free text search. | Every written action is labelled and filterable. | no |
| ACC-09 | Audit logs | FIX | P2 | PRODUCT says every admin action is audited, but incidents (open, resolve), alert acknowledge and offer save and move write no audit_logs row; audit write failures are swallowed. | 05_functions_3.sql:952-1021,1113-1183,1519-1538,4139-4157; 05_functions_1.sql:1244-1256; index.ts:1121-1129; PRODUCT.md:301 | zella_admin_audit in those functions; alert or fail on audit failure. | Each of those changes appears in Audit logs. | yes (migration) |
| ACC-10 | Audit logs | FIX | P2 | audit_logs.business_id is ON DELETE CASCADE, so deleting a business erases its audit history; REQ-PRV-01 keeps audit 7 years after deletion. Latent until deletion exists (BIZ-13). | 04_foreign_keys.sql:22; BACKEND_SCHEMA.md:385; ARCHITECTURE.md:1826 | ON DELETE SET NULL, keeping the business name. | Deleting a test business keeps its audit rows. | yes (migration) |
| ACC-11 | Audit logs (exposure) | CHANGE | P2 | Any member of a business (incl staff and viewer) can read every audit row for it, including Zella Voice staff IP addresses, user agents and before and after data. | 09_policies.sql:22; 10_table_grants.sql:594; 11_column_grants.sql | Limit to owner and admin; hide platform actors' ip_address and user_agent. | A viewer can't read staff IPs. | yes (migration) |
| ACC-12 | Audit logs | ADD | P2 | No filter by actor, date range or record; no export; user agent and record id not shown (REQ-ADM-14). | AuditLogs.jsx:53-68,116-119; index.ts:1567-1585 | Server filters and an audited CSV export. | "What did X change last week" answerable and exportable. **Fixed on branch `claude/lane-a-audit-export`:** person, date, action and record filters, a (created_at, id) cursor and an audited CSV export (owner or super admin). | no |
| ACC-13 | Audit logs | CHANGE | P3 | Paging uses only created_at <, so same timestamp rows can be skipped; every first page loads every business for the dropdown. | index.ts:1583-1584,1597-1602 | Page by (created_at, id); business search. | No skipped rows; bounded payload. | deploy |
| ACC-14 | Audit logs | CHANGE | P3 | Copy says "on client businesses" but platform rows appear; "Deleted business" label can never appear; details are raw JSON; toggle lacks aria-expanded. | AuditLogs.jsx:46,92,99-114 | Fix copy; readable diff; aria-expanded. | Copy matches data. | no |
| ACC-15 | Audit logs | ADD | P3 | Refused admin calls (non admin, NOT_PERMITTED, MFA_REQUIRED) aren't recorded. | index.ts:2994-2996,3006-3008,3045-3047 | Rate limited security event for refusals. | Refusals visible to security.view. **Fixed on branch `claude/lane-a-refusals`:** recorded at the three refusal points, capped at 5 per 10 minutes, listed on Users & access. | deploy |
| ACC-16 | Users and access | FIX | P3 | Load error says "Try again with Refresh" but there's no Refresh button. | UsersAccess.jsx:236,96-110 | Add Refresh. | Retry without reload. | no |
| ACC-17 | Users and access | CHANGE | P2 | New admins default to Super admin (everything except admins and roles); the option text understates it. | UsersAccess.jsx:38,92,134,21; index.ts:2003 | No default or least privilege on both sides; fix text. | Inviting without a role is refused or least privilege. | deploy |
| ACC-18 | Users and access | ADD | P2 | Removing access or changing role doesn't revoke sessions (REQ-LC-04). | index.ts:2102-2106; ARCHITECTURE.md:926 | End the removed admin's sessions on the server: a service role only database function deletes their rows in `auth.sessions` (which also invalidates their refresh tokens), called by `admin_update` on removal or role change and audited. An access token they still hold is already refused on their next admin call, because every action reads `platform_admins` again. (Supabase's `auth.admin.signOut` needs the person's own access token, which the server doesn't have, so it isn't the tool here.) Test on the isolated database with two sessions. | A removed admin's other devices are signed out. **Fixed on branch `claude/lane-a-sessions`:** `zella_end_user_sessions` from admin_update, count shown in Users & access. | <!-- coderabbit-ai-generated:v1 --> <!-- coderabbit-ai-generated-section:v1:32f8cfedec3c2b8ab3301e7caa87bb4ad2ceaece112ebaf5d9097fd72da41f00 --> yes (migration), deploy <!-- /coderabbit-ai-generated:v1 --> |
| ACC-19 | Users and access, roles | ADD | P2 | Granting Zella Voice owner, role changes and role matrix edits need no fresh aal2 step and no second owner. | index.ts:1952-1956,2086-2100; settings.ts:179-190; PRODUCT.md:278 | aal2 for admins.manage and roles.manage; optional second owner approval for a new zella_owner. | A password only session can't create an owner. **Fixed on branch `claude/lane-a-fresh-code`** for admin_invite and admin_update (fresh code only, 5 minutes); roles_save follows once the polish changes to AdminPanels.jsx merge. | deploy |
| ACC-20 | Users and access | CHANGE | P3 | Two admin lists: /users lacks two step status and last action; Settings Platform administrators has them but no actions. | UsersAccess.jsx:168; AdminPanels.jsx:408-425 | Add the columns to /users; Settings page becomes a link. | One place to manage admins. | no |
| ACC-21 | Users and access | CHANGE | P3 | Existing account lookup scans at most 20000 accounts; past that the invite fails with a provider error. | index.ts:1958-1967 | Server side lookup by email. | Works at any size. | deploy |
| ACC-22 | Settings, platform roles | CHANGE | P3 | An owner can tick write permissions for Read only admin; roles_save deletes then inserts (not atomic); saves one role at a time. | settings.ts:179-190; AdminPanels.jsx:453-457 | View only permissions for read_only_admin; one transaction. | Matrix saves all or nothing. | deploy |
| ACC-23 | Settings, permissions | REMOVE | P3 | ai.configure is listed but checks nothing; PRODUCT lists growth.manage, which doesn't exist; REQ-ADM-17 says industry config needs ai.configure but the server uses platform.configure. | settings.ts:59,33; PRODUCT.md:325; ARCHITECTURE.md:1737 | Wire or remove ai.configure; align docs. | Every listed permission guards something. | no |
| ACC-24 | Settings, administrators | FIX | P3 | "Last admin action" counts only rows with no business among the newest 100 platform wide. | settings.ts:192-203 | distinct on (user_id), no business filter. | Real last action shown. | deploy |
| ACC-25 | Settings | CHANGE | P3 | Pages with nothing but an "isn't built" note: Invoices, AI testing and evaluation, OAuth applications, Alert rules, Reporting configuration, API management. | AdminPanels.jsx:673-675,781-783,1009-1011,1233-1235,1292-1294,1391-1393; SettingsPage.jsx:65,74,92,106,117,126 | Mark "Not built" in the tree or hide. | No nav item opens an empty page. | no |
| ACC-26 | Settings, entitlement and usage limits | CHANGE | P2 | Copy says cutting off at the limit "isn't enforced yet / isn't wired"; usage enforcement was applied 15 Nov with voice-rules v8 forwarding at the limit (switch off); copy says "payment provider" though Stripe is decided. | AdminPanels.jsx:615-628,906-918; MEMORY.md section 4 | "Built, off (usage_enforcement)"; name Stripe. | Copy matches MEMORY. | no |
| ACC-27 | Settings, webhooks | VERIFY | P3 | Table says billing-webhook verifies Stripe signature, 5 minute window, one event once; MEMORY says the deployed version doesn't follow the Stripe design and is off. | AdminPanels.jsx:1102; MEMORY.md section 4 | Compare with deployed v5 source; correct the row. | Row true for what is deployed. | no |
| ACC-28 | Settings | CHANGE | P3 | Settings loads me_admin separately and never refreshes it; a failure shows an error with no retry. | SettingsPage.jsx:143-162; adminPermissions.js:63-65 | Pass the shell's access.me. | Role changes apply without reload. | no |
| ACC-29 | Settings, general and AI | CHANGE | P3 | Edit rules inconsistent: platform_setting_save requires zella_owner in code though mapped to platform.configure; profile and branding honour platform.configure; maintenance allows super admin; platform_profile_get always returns canEdit true. | index.ts:2896; settings.ts:37,207,247-248; AdminPanels.jsx:130,397,742,1460 | One rule: the permission check plus an explicit owner only list. | UI and server agree. | deploy |
| ACC-30 | Settings, account security | ADD | P2 | For platform admins, setting up or removing two step sign in, changing the password and signing out other devices leave no audit entry. | PersonalPanels.jsx:121-125,172,179-181,219-224 | Record these events for admins. | They appear in Audit logs. **Sign out other devices fixed on branch `claude/lane-a-sessions`** (`zella_revoke_my_other_sessions`, audited `session.revoked_others`); the authenticator and password parts follow. **Authenticator and password parts fixed on branch `claude/lane-a-self-service`** (me_mfa_added, me_mfa_remove, me_password_change; audited; fresh code for remove and password). | yes (migration) |
| ACC-31 | Sign in copy | CHANGE | P3 | "Owner access", "Zella Voice Owner Admin", "Only authorized owner accounts" though there are seven roles; hyphens "6-digit", "sign-in"; footer "Privacy, Security" is plain text. | App.jsx:274,329,426,434,553-556,564; mfa.js:28,57; PersonalPanels.jsx:163 | "admin", "six digit code"; link or remove footer. | No hyphens; fits every role. | no |
| ACC-32 | Sign in | REMOVE | P3 | Admin "choose a password" step is unreachable (links go to /welcome in the business app); dead code with divergent copy. | App.jsx:25-27,59-60,68-74,200-201,215-254; index.ts:245-247 | Remove or route admin links to it. | One password flow. | no |
| ACC-33 | Session expiry | CHANGE | P3 | Shell rechecks access only on tab focus or sign in events; a 401 or 403 from an action leaves it "authorized"; no "session ended" message after expiry. | adminPermissions.js:53-65; App.jsx:171-173; CreateBusinessWizard.jsx:30-42 | Recheck access on 401/403; show a session ended message. | Revoking a role mid session switches the shell on the next action. | no |
| ACC-34 | Shell, two step sign in | VERIFY | P3 | For an enrolled admin with an aal1 token, zella_pre_request may refuse zella_admin_role itself, so the function answers 500 "Could not verify" before MFA_REQUIRED, and the dashboard says check your connection. | index.ts:2983-2996,3006-3008; ARCHITECTURE.md:2373; adminPermissions.js:12-13 | Call with an aal1 token for an enrolled test admin (isolated); map to MFA_REQUIRED. | Dashboard asks for the code. | no |
| ACC-35 | Admin sidebar | CHANGE | P3 | Sidebar items are buttons with no address; can't open in a new tab (Settings tree uses links). | OwnerDashboard.jsx:264-274; SettingsWorkspace.jsx:96-97 | a href with the same click handling. | Middle click opens a new tab. | no |
| ACC-36 | Admin nav | BUILD | P3 | Growth page in REQ-ADM-18 (prospects, demos, growth.manage) has no nav item, page or permission. | ARCHITECTURE.md:1738; OwnerDashboard.jsx:63-82; settings.ts:54-72 | Build, or mark REQ-ADM-18 later in ARCHITECTURE and PRODUCT. | Docs and nav agree. | no |

Cross cutting: the role model splits in two (permission matrix in the function and zella_admin_* RPCs; is_platform_admin in older RPCs, the bell, offers, incidents and the /welcome redirect); Settings has no gating and owner only rules differ between saves; the audit trail is not yet trustworthy (duplicate unattributed rows, missing labels, functions that write nothing, cascade delete, tenants reading staff IPs). The reviewer's ACC-38 (owner-provision-business behind main) is resolved: v18 deployed 16 Nov 2026.

## Platform wide (production read only checks and the browser crawl)

| ID | Page | Type | Sev | Item | Evidence | What to do | Done when | Approval |
|---|---|---|---|---|---|---|---|---|
| PLT-01 | Sign in (Supabase Auth) | CHANGE | P2 | Leaked password protection is off in production (security advisor), so admins and owners can choose a password known from breaches. Pairs with ACC-01. | Supabase security advisor `auth_leaked_password_protection`, read 16 Nov 2026 | Turn it on in the Supabase dashboard (Auth, password security). | The advisor no longer lists it. | yes (live auth setting) |
| PLT-02 | Database | REMOVE | P3 | Three leftover backup tables from 4 Nov (backup_20261104_presets, _records, _types) are still in production with row security on and no policies. | Security advisor `rls_enabled_no_policy` (20 tables, the rest are server only by design) | Confirm nothing reads them, export if wanted, then drop them in a guarded migration with a rollback that restores them. | The tables are gone and the advisor list shrinks by three. | yes (destructive) |
| PLT-03 | Database (calls_view) | VERIFY | P3 | The advisor's one ERROR, calls_view as a security definer view, is intentional: it returns only rows where is_business_member, zella_module_on(calls) and zella_mfa_satisfied hold, and hides recording and transcript unless zella_can_read_call_content. | pg_get_viewdef read 16 Nov 2026 | Record it as an accepted advisor exception in SCHEMA_STATUS, with the reason. | Documented; no change. | no |
| PLT-04 | Settings, developer (environment, system) | CHANGE | P3 | When a read action fails, the page shows "The change could not be saved. Please try again." although nothing was being saved. (The failure itself came from the local test stand in, which lacks a JSON select; production was not affected.) | Browser crawl: /settings/developer/environment and /system, both personas; function log `dev_overview failed ... unsupported select` | Use a read wording ("This couldn't be loaded. Try again.") for read actions. Add the select shape to tests/browser/local-backend.mjs so the page can be crawled. | Reads and saves have their own error wording; the crawl passes these pages. | no |
| PLT-05 | Settings, tenants | CHANGE | P3 | The all businesses table scrolls sideways by 39 px on a desktop width. | Browser crawl: /settings/tenants/all, both personas | Let the widest column wrap or hide a low value column at that width. | No sideways scroll at 1280 px. | no |
| PLT-06 | All admin pages | VERIFY | P2 | No automated accessibility scan ran: axe-core is not installed in this checkout, so the crawl's axe column is empty. The reviewers found tab and keyboard problems by reading code (COM-07, COM-31, BIZ-30, OPS-32, ACC-14). | Crawl results `axe: null` | Add axe-core as a dev dependency and rerun the crawl (desktop, phone, dark). | The crawl reports serious and critical issues per page. **Fixed on branch `claude/lane-a-axe`:** axe-core 4.14.0 pinned in tests/browser/package.json; the crawls stop when it is missing; admin crawl on 16 Nov 2026: 0 serious or critical findings (desktop 95 pages, dark 95, phone 26). | no |
| PLT-07 | Scheduled jobs | VERIFY | P1 | In production only zella_usage_thresholds and zella_billing_reconcile are on; zella_dispatch, the every 5, 15 minute, hourly, daily and weekly jobs, the spam hourly job, cron cleanup and platform emails are off. Several admin pages present numbers that depend on these jobs (status page, stalled alerts, uptime, provider checks, cancellations; see OPS-01, OPS-02, BIZ-03). | cron.job read 16 Nov 2026 | Before launch, decide each job's switch with the owner and make the admin pages show each job's on or off state (OPS-09, COM-13). | Every job's state is visible in Operations and each one is on or deliberately off. | yes (live switches) |
| PLT-08 | Tests | ADD | P2 | Producers and consumers of alert kinds, audit action names and permission names drift apart (COM-08, COM-17, ACC-08, ACC-23, BIZ-25). | Reviewer cross cutting notes | One shared list for each (alert kinds, audit actions with labels, permissions) and a test that fails when SQL or the function writes a name that isn't in it. | The test runs in CI and catches a new unlabelled action. **Part 1 fixed in PR #93:** the list (`web/supabase/functions/_shared/catalog.json`) and the drift test run in `npm run lint` (no CI yet, owner's choice); the UI labels swap follows after the Businesses list job. | no |

## What the pages look like (visual pass)

Found by opening each admin page and tab in the browser (1440 px desktop and a phone) on the isolated test app and
looking at it, not only at the code. Test data is made up, so counts are only used where two pages disagree with
each other.

| ID | Page | Type | Sev | Item | Evidence | What to do | Done when | Approval |
|---|---|---|---|---|---|---|---|---|
| UI-01 | Shell (sidebar) | CHANGE | P2 | At 1440 by 900 the sidebar shows the menu only down to Automations; Integrations, Support, Security and abuse, Users and access, Audit logs and Settings sit hidden under the "Platform status" footer, with no cue that the menu scrolls. | Screenshots of every page at 1440 by 900 | Make the menu's scroll area obvious (fade and scrollbar) or let groups collapse, and keep the footer from covering items. | Every menu item is reachable and visibly so at 1440 by 900 and 1280 by 720. Fixed in PR #87. | no |
| UI-02 | Overview, AI agents, Voice, Integrations | FIX | P1 | Four pages give four answers about the same thing: Overview says "78 AI receptionists live, answering calls"; AI agents says "Live 0" and every receptionist "Not connected"; Voice says "58 active numbers, linked"; Integrations says "1 connection". | Screenshots: overview, agents, voice_numbers, integrations | One server definition of "connected" and "live" (numbers, Vapi link, recent served delivery) used by all four pages. Same root cause as COM-01 and OPS-07. | The four pages agree for the same business. | deploy |
| UI-03 | Businesses | CHANGE | P2 | All 92 businesses on one page; "Plan" reads "Not assigned" for all; the owner column repeats "Not invited / None"; the main action on a live business is "Edit setup"; no sort, no filters beyond one dropdown, no column for calls, health or last activity. | Screenshot: businesses | In page search; filters (industry, stage, plan, has a problem); sort; columns for last call and open problems; "View" as the main action for live businesses (with BIZ-15, BIZ-16). | An admin finds a business with a problem in two clicks. | deploy |
| UI-04 | Businesses | REMOVE | P3 | A marketing style banner ("One platform. Separate business workspaces.") takes the top of an operational page. | Screenshot: businesses | Remove it. | Gone. | no |
| UI-05 | Business detail, overview | CHANGE | P3 | "Business size" is an unstyled native select with a grey "Save size" button, unlike every other form control. | Screenshot: detail_overview | Use the design system select and the page's save pattern. | Matches DESIGN_SYSTEM. | no |
| UI-06 | Business detail, People | ADD | P2 | An admin can only look: no resend, no role change, no remove, no last sign in, no two step sign in status. Support can't help an owner who is locked out. | Screenshot: detail_people | Add support actions behind businesses.manage, each with a reason and an audit row (resend invitation, reset two step sign in after identity check, deactivate), plus last sign in and two step status. Owner decides which actions support may take. | Support can unlock an owner with an audited reason. | yes (owner decision, deploy) |
| UI-07 | Business detail, AI receptionist | ADD | P2 | Read only except Voice; the transfer target says "Business owner" with no number; no fallback number; no way to hear a voice or know how to make a test call; no served version or last delivery (COM-03). | Screenshot: detail_ai_receptionist | Show transfer and fallback numbers, the served version and last delivery result, and a "how to test" line with the business's number. | Admin can tell what a caller hears and where they're put through. | deploy |
| UI-08 | Business detail, Phone and integrations | ADD | P2 | Says "Nothing connected yet" and lists no numbers, even for businesses that have numbers on Voice; no fallback number; no link to assign one. | Screenshot: detail_phone_integrations; voice_numbers | List the business's numbers (from business_phone_numbers), the fallback number and the Vapi link, with "Assign a number" opening Voice prefilled. | The tab matches Voice for the same business. | deploy |
| UI-09 | Business detail, Automations | CHANGE | P2 | Names start lowercase ("visit reminders", "no show follow up"); every row "Not set up" with "None" in two columns; no action to turn one on or pause it and no link to the Automations page. | Screenshot: detail_automations | Capitalise names, replace "None" with words, add a link to /automations filtered to the business and the turn on or pause action (with BIZ-07). | No raw "None"; one click to manage. | no |
| UI-10 | Business detail, Calls | ADD | P2 | "To" is "None" on every row; rows can't be opened; only the latest 10. | Screenshot: detail_calls | Call drawer (summary, outcome, transfer, content rules apply) and "See all" to Voice, Calls filtered (with BIZ-30). | Any call opens; older calls reachable. | no |
| UI-11 | Verification | ADD | P2 | Only lists documents that were uploaded. With 92 live businesses and nothing uploaded the page reads "0 waiting", so nobody knows whom to chase. | Screenshot: verification_all | Add a "Missing documents" view of businesses with no registration or owner ID, with a "Request documents" action (uses the S4 email when email is live). | Businesses missing documents are listed. | no |
| UI-12 | Plans | CHANGE | P2 | Limits show raw keys ("languages: 2") and only languages; minutes, texts and other allowances aren't shown. | Screenshot: plans | Human labels and every allowance (with CFG-14). | Cards list every allowance in words. Screen part fixed in PR #89: every allowance the page receives, in words; the per business plans (CFG-14) still need server work. | no |
| UI-13 | Offers | CHANGE | P3 | Page eyebrow says "Growth" while the menu puts it under Configuration. | Screenshot: offers | Use one group name. | Same name in both places. Fixed in PR #89 (Plans said "Billing" for the same group and now says "Configuration" too). | no |
| UI-14 | Voice, overview | ADD | P3 | Tiles such as "Missed 121" can't be clicked; "Needs attention" says nothing while 121 calls were missed and checks are off. | Screenshot: voice_overview | Make tiles open the filtered call list; raise a missed call rate alert (with COM-08). | Clicking Missed shows those calls. | yes if a new alert |
| UI-15 | Voice, numbers and calls | VERIFY | P2 | Every number shows "Calls (30 days) 0" and "Last call None" while 477 inbound calls exist, and the Calls tab shows Number "None" on every call: calls may not record which number they came in on. | Screenshots: voice_numbers, voice_calls | With a real or staging call, check calls.to_number (or the number link) is filled by voice-rules and n8n. If not, fill it on arrival. | A test call shows on its number's row. | maybe (staging call) |
| UI-16 | Voice, calls | CHANGE | P3 | The last column has pills ("Needs a person") but no header; Length mixes "Not available" and "1 min 0 s"; Outcome is "None". | Screenshot: voice_calls | Header the column; one length format; words instead of "None". | Copy review passes. Fixed in PR #88. | no |
| UI-17 | Voice, call routing | CHANGE | P2 | The business picker is a plain list of every business, and nothing shows which businesses have no transfer or fallback number. | Screenshot: voice_routing | Searchable picker (UI-26) and a "Missing routing" list. | Businesses without routing are listed. | no |
| UI-18 | Voice, providers | CHANGE | P3 | AI voice usage lists every business unpaged; connection checks repeat the Overview tab; the period select stretches full width. | Screenshot: voice_providers | Page the table (top 20 plus "See all"), remove the repeated checks, normal width select. | Table paged; one copy of checks. Fixed in PR #88. | no |
| UI-19 | Messaging, overview | FIX | P2 | "1,028 follow ups due now" is shown in orange but Needs attention only raises the 2 late reminders; the follow up backlog has no alert here (Automations does show it). | Screenshot: messaging_overview vs automations_overview | Raise and show the follow up backlog the same way on both pages. | The backlog appears in Needs attention. | yes (migration) |
| UI-20 | Messaging, templates | ADD | P3 | Templates can be edited but not created or retired from the admin. | Screenshot: messaging_templates; MessagingPage.jsx:210-255 | Add create and retire, each audited and versioned (with COM-27). | An admin can add a new platform template. | yes (migration) |
| UI-21 | Voice, Messaging, Operations, Automations | CHANGE | P3 | Setting keys shown to admins as words: "sms_live is off", "The calls_live switch", "(sms live off)", "Off (calls_live)", "provider_checks_live". | Screenshots | Plain words ("Texts are in test mode") with the key in a tooltip if needed. | No setting keys in visible text. Fixed in PR #88 for Voice, Messaging and Automations; Platform operations (PlatformMonitoring.jsx) is left for its own change. | no |
| UI-22 | Platform operations | FIX | P2 | Green "No issues found" banner and "Open problems 0" while 6 of 8 required server settings are Not set and provider checks are off. | Screenshot: operations | Count missing go live settings and off checks as problems, or show a neutral "Not ready for go live" banner. | The banner is never green while go live items are missing. | no |
| UI-23 | Operations, Automations, Messaging | CHANGE | P2 | Three partial go live checklists: Operations "Services" (secrets), Automations "Go live checklist" (settings and switches), Messaging "Sending switches". Each misses items the others list (Resend key, platform_emails_url, email sender, n8n secret, jobs). | Screenshots: operations, automations_infrastructure, messaging_providers | One go live checklist (secrets, settings, scheduled jobs, live switches, owner approvals) shown in one place and linked from the others. | One list, every go live item on it. | no |
| UI-24 | Operations and Automations | CHANGE | P2 | Two different "app address" settings: the ZELLA_APP_URL secret (invitation links, shown on Operations) and the app_base_url platform setting (customer links, shown on Automations). On 16 Nov 2026 the `app_base_url` setting was empty in production (read only database read), and the owner's `supabase secrets list` didn't include `ZELLA_APP_URL` (the secret's value can't be read from here); neither page mentions the other. | Screenshots; production database read and the owner's secrets list, 16 Nov 2026 | Explain both on the go live checklist, or derive one from the other. | An admin knows both must be set. | no |
| UI-25 | Platform operations, incidents | CHANGE | P3 | The inline incident form clips its placeholders ("Text messages d", "(optior"). | Screenshot: operations | Use a dialog (with OPS-11). | Placeholders readable. | no |
| UI-26 | Every list with a business filter | CHANGE | P2 | Filters are native dropdowns of every business (Automations, Messaging, Voice, Call routing, Audit logs); unusable past about 100 businesses. | Screenshots; automations_runs text | One searchable business picker component, server backed. | Picker finds a business by typing. | no |
| UI-27 | Automations, scheduler | REMOVE | P3 | The same scheduled jobs appear in two tables ("Scheduled jobs" and "Scheduled database jobs"); file paths shown (n8n/GO-LIVE.md, n8n/README.md). | Screenshot: automations_infrastructure | Keep one table; replace paths with words. | One table; no paths. Fixed in PR #88. | no |
| UI-28 | Automations, templates | CHANGE | P2 | Lists only the 15 industry record templates; the automations every business gets (reminders, confirmations, no show follow up) aren't listed because they live in the browser code (CFG-05); industry names differ from the industry list ("Cleaning" vs "Cleaning Services"). | automations_templates text | List every default automation from data, with industry names from the industries table. | Every default automation is listed. | yes (migration) |
| UI-29 | Security and abuse | CHANGE | P3 | Six stat cards in a five column grid leave one alone on a second row; the tabs sit under the stats, unlike every other tabbed page. | Screenshot: security_abuse | Tabs first, then a grid that fits the count. | Same layout as other tabbed pages. Fixed in PR #87. | no |
| UI-30 | Create business wizard | CHANGE | P3 | The step bar overflows at 1440 px (step 10, Review, is cut off with no scroll cue); "Back" is enabled on step 1; the time zone hint says "like Kolkata" for a US launch. | Screenshot: wizard_new | Wrap or compress the steps; disable Back on step 1; US example. | All ten steps visible at 1440 px. Fixed in PR #89. | no |
| UI-31 | Settings (whole) | REMOVE | P2 | About 25 of the 74 Settings pages repeat a main page: All businesses (Businesses), AI agent registry (AI agents), Phone number management (Voice numbers, 178 rows unpaged), Voice usage (Voice providers), Incidents and System logs (Platform operations), four Offers pages (Offers), Plans pages (Plans), n8n configuration and Webhooks (Automations scheduler), Integration registry (Integrations), Platform administrators (Users). Copies drift apart (COM-15, COM-24, OPS-16). | Settings text dump of all 74 pages | Settings keeps configuration only; each repeat becomes a short link to the real page. | No list or report exists twice. | no |
| UI-32 | Settings, operational rules | CHANGE | P3 | Field labels are raw setting keys (call_intel_monthly_limit, response_sample_rate, missed_call_max_seconds, knowledge_repeat_threshold). | settings_general_operations text | Human labels with the key as help text. | No raw keys as labels. Fixed in PR #87. | no |
| UI-33 | Settings, communication templates | CHANGE | P3 | Says "Editing platform templates here isn't built" while Messaging, Templates edits them. | settings_comms_templates text | Link to Messaging, Templates instead. | Copy is true. Fixed in PR #87. | no |
| UI-34 | Business detail (phone) | CHANGE | P3 | On a phone the tab row scrolls sideways with no cue ("AI reception" cut off). | Phone screenshot: businesses_id | Fade at the edge or a select on small screens. | Tabs visibly scroll on a phone. | no |
| UI-35 | Tests | ADD | P2 | The local test database's reference data differs from production (8 modules per industry instead of 10, no platform message templates, older settings), so local pages and crawls don't show what production shows. | Production reads 16 Nov 2026 vs crawl database | Load reference configuration rows (industries, modules, presets, templates, settings keys; no customer data) read only from production into the fixtures, as tests/browser/README.md describes. | A crawl shows production's modules and templates. | no |

## Build checklist: everything that has to be built, page by page

New things only (BUILD and ADD rows, plus the features the pages themselves say "aren't built"). Fixes and changes to
what already exists are in the page by page section and the inventory. "Needs approval" means a production migration,
deploy, live switch, provider setup or owner decision before it can go live; all of it can be built and tested on the
isolated database first.

### Shell and access
- [ ] Two step sign in required for every admin, with set up at first sign in and no removing the last factor (ACC-01) · needs approval
- [ ] Sign out everywhere when an admin is removed or their role changes (ACC-18) · needs approval (built on `claude/lane-a-sessions`, not applied)
- [ ] A fresh code (and optionally a second owner) before granting Zella Voice owner or changing roles (ACC-19) · needs approval (built on `claude/lane-a-fresh-code`, not deployed)
- [ ] Record refused admin calls as security events (ACC-15) · needs approval (built on `claude/lane-a-refusals`, not deployed)
- [ ] Audit entries for admins' own password, two step and sign out changes (ACC-30) · needs approval (built on `claude/lane-a-sessions` and `claude/lane-a-self-service`, not deployed)

### Business detail
- [ ] Plan, numbers, usage and alerts cards, and the server readiness ladder (BIZ-11)
- [ ] Go live checklist visible to admins; owner decides whether admins can go live and whether documents are required (BIZ-12) · needs approval
- [ ] Balances and "grant a pack, with reason" (CFG-22)
- [ ] Audited support access, with caller numbers masked unless a reason is given (BIZ-22) · needs approval
- [ ] Support actions on People: resend, reset two step after identity check, deactivate; last sign in and two step status (UI-06) · needs approval
- [ ] Cancel an owner invitation, and a resend cooldown (BIZ-21) · needs approval
- [ ] AI receptionist tab: transfer and fallback numbers, served version, last delivery, how to test (UI-07) · needs approval
- [ ] Phone and integrations tab: the business's numbers, fallback number, Vapi link, "Assign a number" (UI-08) · needs approval
- [ ] Calls tab: open a call, "see all" (UI-10)

### Businesses lifecycle
- [ ] Delete a draft that was never finished, audited (BIZ-13) · needs approval
- [ ] "Retention due" list and an owner approved purge of cancelled businesses (BIZ-13) · needs approval
- [ ] Whole business export and deletion jobs (Settings, Data lifecycle says they aren't built) · needs approval
- [ ] Automatic retry of failed setup steps (Settings, Business onboarding) · needs approval

### Create business wizard
- [ ] Creation key and duplicate warning, so a retry never creates two businesses (BIZ-14) · needs approval

### Verification
- [ ] "Missing documents" list with "Request documents" (UI-11)
- [ ] Document retention rule and cleanup of replaced and orphan files (BIZ-18) · needs approval (legal)

### Industry configuration
- [ ] Per industry sensitive flag, booking model and default automations stored as data (CFG-05) · needs approval
- [ ] Deactivate an industry, with an Inactive label (CFG-08) · needs approval

### Plans and subscriptions
- [ ] Rebuild the page around per business plans: tier, version, price, allowances, balances (CFG-14) · needs approval
- [ ] Invoices (Settings, Invoices: need the provider's invoice events and an invoices table) · after Stripe
- [ ] Refund requests and approvals (Settings, Refunds) · after Stripe
- [ ] Charging for extra usage (Settings, Usage limits) · after Stripe
- [ ] Billing emails to businesses that don't need Stripe (owner, 16 Nov: build now, held until Stripe and email are live)
- [ ] Billing emails that need Stripe (owner, 16 Nov: build now, held until Stripe and email are live)

### AI agents
- [ ] Last delivery outcome, not ready count and served version per receptionist, with a deliveries drawer (COM-03) · needs approval
- [ ] A global default prompt that rolls out to businesses without overwriting their own (Settings, AI agent configuration) · later (owner, 16 Nov 2026)
- [ ] AI testing and evaluation view with a pass rule (Settings, AI testing) · needs approval

### Voice and numbers
- [ ] Counter and alert for refused Vapi requests, with auth mode and last refusal shown (COM-09) · needs approval
- [ ] Read only switches panel: calls live, usage enforcement for calls, Vapi auth mode (COM-13) · needs approval
- [ ] Tiles that open the filtered call list, and a missed call rate alert (UI-14) · needs approval for the alert
- [ ] Buying numbers and provider error logs through Telnyx and Vapi server actions (Providers says they aren't built) · needs approval (provider)
- [ ] "Missing routing" list of businesses without a transfer or fallback number (UI-17)

### Messaging
- [ ] Release or discard a held platform email, with a preview drawer (COM-18) · needs approval
- [ ] Business filter and email drawer on Emails to businesses (COM-22)
- [ ] Create and retire platform templates, audited and versioned (UI-20) · needs approval
- [ ] Look up why one number or address gets no messages (COM-29) · needs approval

### Platform operations
- [ ] Incident updates, paging and a duplicate warning (OPS-12) · needs approval (built on `claude/lane-a-incidents`, not applied)
- [ ] One go live checklist for secrets, settings, jobs and live switches, linked from Automations and Messaging (UI-23)

### Automations
- [ ] Store and show n8n's response per workflow (OPS-17) · needs approval
- [ ] "Resume all" for a business (OPS-20) · needs approval
- [ ] Read n8n's own workflow activation and execution status with a server side key (Scheduler page says it isn't built) · needs approval
- [ ] Webhook delivery logs (Settings, Webhooks) · needs approval. Outbound webhooks for businesses are not planned (owner, 16 Nov 2026; architecture §36)

### Support
- [ ] Reply to the business, alerts for urgent, cancellation and plan change tickets, age and first response with an overdue filter (OPS-25) · needs approval (built on `claude/lane-a-support`, not applied)

### Audit logs
- [ ] Filters by person, date range and record, and an audited export (ACC-12) (built on `claude/lane-a-audit-export`, not deployed)

### Settings
- [ ] Editable alert rules (condition, severity, destination, frequency, quiet window) (Settings, Alert rules) · needs approval
- [ ] Scheduled reports and report permissions (Settings, Reporting configuration) · needs approval
- Not planned (owner, 16 Nov 2026; architecture §36): public API keys (Settings, API management)
- [ ] OAuth application checks (Google client set or not) in the server configuration check (Settings, OAuth applications) · needs approval
- [ ] A per business recording on or off policy (Settings, Policy configuration) · needs approval
- [ ] Separate retention for recordings, transcripts and audit logs (Settings, Data retention) · needs approval

### New pages
- [x] Growth page (prospects, demos, growth.manage), or mark REQ-ADM-18 as later (ACC-36): later (owner, 16 Nov 2026), marked in ARCHITECTURE and PRODUCT

### Tests and tooling
- [ ] One shared list of alert kinds, audit actions and permissions, with a test that catches drift (PLT-08) (list and test in PR #93; UI labels next)
- [ ] Reference configuration from production in the test fixtures, no customer data (UI-35): allowed by the owner on 16 Nov 2026, read only, through an allowlist
- [ ] axe-core in the crawl for an accessibility scan of every page (PLT-06)

## Add on task: owner onboarding journey (after the admin dashboard work)

Asked for by the owner on 16 Nov 2026, to be built **after** the admin dashboard items above. Once a business is
created and its owner invited, the owner opens the link and goes through these screens in order. Progress is saved,
so they can stop and come back where they left off.

| # | Screen | What the owner does | Build or reuse |
|---|---|---|---|
| 1 | Welcome | Opens the invitation link; sees their business name and the steps ahead | Extend `/welcome` |
| 2 | Password and two step sign in | Chooses a password and adds an authenticator | Password exists; add the authenticator step |
| 3 | Check your details | Reviews what the admin filled in (business, hours and services, team, AI receptionist and phone), one step at a time, with "Looks right" or "Change" | New, reusing the CRM's form parts |
| 4 | Verify your identity | Verifies their ID (and the business) with an identity provider; sees Checking, Verified or Try again | New |
| 5 | Your plan | Sees the plan, price, minutes, texts and what's included, as the admin set it | New, reading the saved business plan |
| 6 | Pay or start a trial | Uses Stripe's page to pay or save a card for a free trial, depending on the owner's decision; "Payment received" is shown only when payment is confirmed | New; needs Stripe (step 4 of billing); flow pending the owner's decision |
| 7 | You're all set | Sees what happens next (test call, go live) and opens their CRM | New |
| All | Progress bar and "Finish later" | Leaves and resumes at the same step | New |

Plus, on the admin side: each business shows which onboarding step its owner has reached (with BIZ-12).

Rules: the owner can't pass verification until it succeeds or an admin approves it in Verification; Stripe Checkout
opens only after verification. The receptionist goes live only after verification and the go live checks (REQ-LC-14).
If the owner chooses payment before go live, payment must also be confirmed first; if they choose a free trial, the
saved-card trial setup must be confirmed instead. The emails for each stage already exist (S3 Finish setting up,
S4 Documents needed, S5 Business verified, S6 Your AI receptionist is live) and are sent only once email is live.

Open decisions for the owner:
- [ ] Identity provider: Persona (owner ID and business registration), Stripe Identity (owner ID only, same vendor as payments), or manual upload for now. Recommended: Persona, keeping manual upload as the fallback.
- [ ] Plan screen: accept the plan the admin set, or let the owner switch between Base and Pro. Recommended: accept only.
- [x] First payment: pay before going live, or a free trial with a saved card. Recommended: pay before going live. Owner, 16 Nov 2026: pay before going live, once Stripe is live; until then the go live gate doesn't wait for payment.
- [ ] Failed check: retry then manual review, or stop and contact support. Recommended: retry then manual review.

Build checklist (each needs the owner's approval before anything goes live; provider accounts and keys are the owner's):
- [ ] <!-- coderabbit-ai-generated:v1 --> <!-- coderabbit-ai-generated-section:v1:45f9e623d129dbb0dc5ee8d415c4fef76dbccad3d0bd9b2c4c81b6ece0e0575e --> Prerequisites: BIZ-01 production deployment and live public `ZELLA_APP_URL` verified; BIZ-02 post-sign-in acceptance verified on the deployed revision and Resend wording corrected if still inaccurate; two step sign in in onboarding <!-- /coderabbit-ai-generated:v1 -->
- [ ] Onboarding progress stored per business (which step, when), shown to admins
- [ ] Screens 1, 2, 3, 5 and 7, with progress bar and Finish later, tested on the isolated database
- [ ] Screen 4 with the identity provider's sandbox, plus a server function that receives the result (signed, one event once) and the manual fallback in Verification
- [ ] Screen 6 once the owner decides the first payment rule and Stripe Checkout and the payment webhook are built
- [ ] Go live only after verification and the activation checklist pass, plus confirmed payment or saved-card trial setup according to the owner's decision
