# 28-industry launch matrix (5 Nov 2026)

Scope: all 28 industries, as you set it. For each one: what Zella promises at launch, the workflows that promise needs,
the integrations it depends on, what has been tested, and what still blocks launch. Nothing here is deployed.
The 15 migrations and the new functions are waiting for your approval (see `docs/DEPLOYMENT_REVIEW_2026-11-05.md`).

## How it was tested

`tests/workflows/industry_matrix.mjs` runs on an isolated copy of the staging database. That copy has one active
business per industry, each with an owner, admin, manager, staff member and viewer, synthetic customers, bookings, calls,
and every preset record type filled. The checks are driven by each business's own configuration (its capabilities, record
types and message policy), so each industry is tested against what it actually offers. **Result: 1,383 checks, all passed**
(per-industry results in `tests/workflows/out/matrix.json`).

| Stage | What is checked for every industry |
|---|---|
| Intake | the AI receptionist saves a new caller as a lead and links the live call |
| Scheduling (if the business takes bookings) | real free times; read-back required; booked; the same time refused for someone else; the caller finds, reschedules and cancels it; reminders withdrawn on cancellation |
| Scheduling (if it doesn't: e-commerce) | the AI offers no times and can't book, and the booking tools are left out of its list; the database refuses new bookings |
| Records (every preset type, switched on as a new business gets them) | owner switches the type on; staff create one and move it on; an unknown status is refused; a duplicate unique value (VIN, policy number, matter reference …) is refused; the viewer reads but can't write; another business can neither read nor write |
| Private values (access codes) | managers see the value; the viewer and other businesses never do, not even inside the record's data |
| Today | staff and viewer see it; another business can't |
| Money | staff raise an invoice; staff can't record a payment or refund; a manager records the payment; a repeated payment isn't counted twice; the viewer and other businesses can't raise one |
| Messages | a completed visit queues the feedback request, or holds it back with the reason, exactly as the industry's policy says |
| Recovery | a provider failure is retried, then stops; it shows under "Sending failed"; staff, viewer and other businesses can't retry; the owner can; it is then sent |

Alongside the matrix, these also pass:
- the salon end-to-end workflow (`tests/workflows/salon_launch.mjs`);
- the database security suite (`tests/security/run.sh`), which covers private fields for every industry, linked bookings, files, Google leads and the message policy;
- the staging rehearsal with rollback (`tests/staging/run.sh`);
- the edge-function unit tests;
- every edge function served by Supabase's own edge runtime (v1.78.0), called through the local stack (`tests/runtime/`): 76 checks.

**Defect found by the matrix and fixed:** a business that doesn't take bookings (e-commerce) still had the AI offer times;
the database then refused the booking mid-call. Fixed in `sql/zella_ai_caller_fixes.sql` (part 6), not yet applied.

**What the matrix does not cover:**
- real phone calls, real texts or emails, or real provider accounts (none are connected, and sending is off);
- the browser for every industry: the app is checked by the earlier browser sweeps plus the salon, linked-booking and files screens;
- load testing;
- external integrations listed below that aren't built yet.

## Integrations every industry depends on

| Integration | Promised where | State | Needs from you |
|---|---|---|---|
| Phone + AI voice (Vapi) | everywhere | built; live assistants unchanged | approval to update assistants after deploy (`calls_live`) |
| SMS (Telnyx) | confirmations, reminders, follow-ups | built; `sms_live` off; dry runs recorded | A2P 10DLC registration; approval to switch `sms_live` on |
| Email sending | email channel, invitations | built; `email_live` off | sending domain verification; approval |
| Google Calendar sync | wizard "Calendar for bookings" | sync built (n8n); **the owner's own connect step was missing, built 5 Nov** (`calendar-connect`, Settings > Calendar connections); `calendar_sync_live` off | Google OAuth client (Google Cloud project, consent screen verification for the calendar.events scope); approval |
| Outlook Calendar sync | wizard offers it | **built 5 Nov**: connect step plus Microsoft Graph sync both ways (n8n); not deployed | Microsoft app registration (Entra ID, Calendars.ReadWrite, offline_access) |
| **Gmail / Outlook mailbox** | wizard "Email" | **only the choice is stored; nothing uses it** | decide: keep (build mailbox send/receive) or remove from the wizard |
| Meta lead ads | wizard lead sources | built | Meta app review |
| Google lead forms | wizard lead sources | built 5 Nov; not deployed | approval |
| Website form | wizard lead sources | built | none |
| Card payments | deposits, invoices | **not built by design**: Zella records payments; it never takes card details | separate approval and provider choice (e.g. Stripe) |

## Per industry

"Tested" counts the matrix checks; the universal checks above apply to all. "Blockers" are what stands between today and
the launch promise. ⚙ = needs an external account or credentials. ⚖ = needs your business decision.

| # | Industry | Launch promise | Essential workflows | Industry integrations | Tested | Blockers for the promise |
|---|---|---|---|---|---|---|
| 1 | Automotive | answer, book drop-offs, track vehicles and repair orders, approvals and declined work | vehicles, repair orders, loaners, check-ins, estimate → approval → invoice | workshop / DMS system | 44 | ⚖⚙ workshop-system provider; additional-work approval as an explicit authorization record; parts-delay status |
| 2 | Beauty & Salon | book clients with their stylist, remember preferences and colour formulas, deposits and no-shows | bookings, colour cards, memberships, deposits, no-show fees, waitlist | booking-site import (optional) | 43 + salon workflow 48 | multi-service bookings with processing gaps; chair / stylist utilization |
| 3 | Childcare | enquiries, tours, enrolments, incident records, never confirm a child to a caller | enrolments, children (private details), incident reports | none required at launch | 44 | guardians as separate contacts; consents and medication authorizations; secure pickup changes ⚖ |
| 4 | Cleaning Services | book and dispatch visits to properties with secure access details | properties (private access), visits, plans | none required | 53 | ⚙ none; recurring visit generation; checklist completion per visit; dispatch board |
| 5 | Dental | new patients, recalls, treatment plans and coverage, discreet messaging | recalls, treatment plans, coverage (private member ID), forms | practice-management system | 57 | ⚖⚙ practice-management provider; ⚖ BAA with voice / SMS providers before real patient calls |
| 6 | E-commerce | answer order questions without inventing status, record returns and cases | orders, returns, support cases; no bookings | **store (Shopify / WooCommerce)** | 39 | Shopify connection and AI order lookup **built 5 Nov** (status and tracking only, caller verified by number or order email); ⚙ each store creates a read-only custom app; WooCommerce if needed ⚖ |
| 7 | Education | applications, courses, sessions with places and waitlist | applications, courses, sessions, session bookings | none required | 51 | guardians as separate contacts; tuition instalments |
| 8 | Electrical | jobs at sites with access, permits and inspections | jobs, sites (private access), permits, plans | field-service / accounting (optional) | 56 | dispatch board; certificates ⚖ |
| 9 | Financial Services | appointments, service requests, reviews, no advice by AI | opportunities, service requests, reviews; transcripts never to staff | none required | 43 | identity-verification status; ⚖ compliance review of call recording |
| 10 | Fitness | trials, memberships, class booking with waitlist, freezes and cancellations | memberships, trials, classes, bookings, freeze requests | access control (optional) | 57 | automatic waitlist promotion; failed-payment card |
| 11 | Healthcare | referrals, refills, prior auths, results callbacks, never clinical advice | referrals, refill requests, prior auths, results callbacks, coverage | EHR (optional at launch) | 64 | **⚖⚙ BAA with Vapi, Telnyx, Supabase and email provider before real patient calls**; EHR provider ⚖ |
| 12 | Home Services | book jobs at properties with access and skills | properties (private access), jobs, plans | field-service (optional) | 47 | dispatch board; equipment on properties |
| 13 | Hospitality | stays, guest requests, group enquiries, quote only listed room types | stays, guest requests, groups, room types, lost and found | **PMS for live availability** | 57 | **⚖⚙ PMS provider; without it the AI can't confirm rooms** (it takes requests only) |
| 14 | HVAC | jobs, equipment history, service agreements, seasonal reminders | equipment, jobs, agreements, properties | field-service (optional) | 51 | dispatch board; warranty claims |
| 15 | Insurance | policies, claims from first notice, quotes, renewals, never binds | policies, claims, quotes, policy requests | agency-management system | 61 | ⚖⚙ agency-system provider; ⚖ licensing review of what the AI may say |
| 16 | Landscaping | jobs at properties, weather delays, seasonal plans | jobs, plans, properties | none required | 44 | routes; materials |
| 17 | Legal | consultations, matters, deadlines, never confirm who is a client | matters (parties, dates), document requests, deadlines | practice-management (optional) | 44 | conflict search across parties ⚖; ⚖ privilege / recording review |
| 18 | Other | generic enquiries and records | enquiries, records | none | 36 | none |
| 19 | Pest Control | inspections, treatments with application records, bonds | jobs, plans, properties, application records | none required | 50 | consent before treatment; re-treatment records |
| 20 | Pet Care & Vet | appointments for the right pet, vaccines, boarding | pets, reminders, boarding; bookings linked to the pet (built 5 Nov) | practice-management (optional) | 43 | boarding capacity; separate service modes |
| 21 | Photography & Events | enquiries, bookings with contracts and balances, galleries | bookings, galleries, deposits | none required | 37 | availability check against booked dates |
| 22 | Plumbing | emergency triage, jobs at properties, permits and warranties | jobs, properties (private access), plans | field-service (optional) | 47 | dispatch board; return visits |
| 23 | Professional Services | enquiries, proposals, projects | opportunities, projects | accounting (optional) | 36 | time tracking; milestones |
| 24 | Property Management | maintenance requests with emergencies, units, leases, vendors | requests, leases, units (private keys), vendors, applications | property-management system | 57 | ⚖⚙ PM-system provider; emergency fallback chain; fair-housing review ⚖ |
| 25 | Real Estate | buyer and seller leads, viewings, deals, open houses | requirements, properties, viewings, deals, open houses, seller leads | MLS / listing feed | 63 | ⚖⚙ MLS access (board membership required); open-house sign-ins to leads |
| 26 | Restaurant | reservations, waitlist, special requests, events and catering, no allergen guarantees | reservations, tables, waitlist, special requests, events, catering | reservation / POS system | 55 | ⚖⚙ reservation-system provider; table combinations and durations |
| 27 | Spa & Wellness | bookings, packages, memberships, private intake | packages, memberships, intake forms (private) | none required | 43 | rooms and equipment with buffers; package balances per visit |
| 28 | Travel | trips, supplier bookings, traveler documents with expiry | trips, bookings, documents (private passport numbers) | GDS / supplier systems | 44 | ⚖⚙ supplier / GDS access; groups of travelers |

## Decisions and credentials needed (collected)

1. **Approve the deployment** of the 15 migrations and 3 new functions (deployment review).
2. **Sending:** 10DLC registration, a verified email domain, then `sms_live` / `email_live`; the messaging policy (D1–D5).
3. **Health data:** BAAs with Vapi, Telnyx, Supabase and the email provider before healthcare or dental go live with real patients.
4. **Calendars and mailboxes:** a Google OAuth client and a Microsoft app registration. Decide whether the wizard's Gmail / Outlook mailbox option stays.
5. **Industry systems** (each one needs a provider choice, an account, and approval before connecting):
   - store: Shopify built (each store's own custom-app token); WooCommerce or others on request;
   - hotel PMS;
   - restaurant reservations / POS;
   - property-management system;
   - MLS;
   - agency-management system;
   - practice management / EHR;
   - GDS / supplier systems;
   - workshop / DMS.
6. **Payments:** if Zella should take deposits or invoices by card, choose a provider. That needs separate approval, and Zella never handles card details itself.
