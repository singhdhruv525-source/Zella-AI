# Zella Voice: product requirements

What Zella Voice is, who it is for, and every feature it has, with an honest status for each. This is the product
view. The other source-of-truth documents cover the rest:

| Document | Answers |
|---|---|
| `docs/PRODUCT.md` (this) | What the product is and does, for whom, and what is built, off or still to come |
| `ZELLA_VOICE_RULES.md` | The rules every change must follow (non-negotiables `NN-1` to `NN-12`, security, privacy, honesty) |
| `docs/ARCHITECTURE.md` | The required design: how the parts fit and how every flow works (requirement IDs `REQ-*`) |
| `docs/DESIGN_SYSTEM.md` | Colours, typography, spacing and components |
| `docs/BACKEND_SCHEMA.md` | Every table, column, policy and function in the database (generated) |
| `docs/MEMORY.md` | Where things stand now: what is live, decisions, open items, lessons |

When this document and the code disagree, the code is checked first and this document is corrected in the same pull
request. A feature is described here only once it exists in the repository; plans are marked as such.

Last checked against the code and the production database (read-only): 12 November 2026.

---

## 1. The product in one paragraph

Zella Voice answers the phone for small businesses so no customer is missed. An AI receptionist answers every call,
day and night. It answers questions from the business's approved knowledge, books, moves and cancels real
appointments, takes messages, and hands over to a person when it should. Everything it does lands in a CRM built for
the business's industry, where the owner and team see every customer, call, message, booking and follow-up in one
place. Automations follow up within the owner's rules. Zella Voice staff run the platform from a separate admin.

**Brand:** always "Zella Voice", in full (`NN-12`). Never "Zella" alone, never "Zella AI".

## 2. Who it is for

| Person | Who they are | What they need from Zella Voice |
|---|---|---|
| **Business owner** | Runs a small business (salon, plumber, clinic, restaurant, ...), busy doing the work | Every call answered, real bookings, no embarrassing messages, control without effort |
| **Business team** | Admins, managers, staff and viewers in that business | A clear list of what to do today; only the information their role allows |
| **Their customers** | Callers, clients, patients, guests | A helpful answer, a real booking, the ability to stop messages and reach a person |
| **Zella Voice staff** | The Zella Voice owner and platform admins | Create and support businesses, numbers, plans, monitoring, security and audit |

**Launch market:** United States only (decision D-14). The platform stays ready for other countries, but none is
switched on until its calling and messaging rules are reviewed.

**Onboarding:** the Zella Voice team creates each business in the platform admin (D-06). Self-service sign-up is a
later phase. No demo or sample data is ever loaded into production.

## 3. The promises (every feature keeps one of these)

| # | To the business | To their customers |
|---|---|---|
| P1 | Every call is answered, day and night | You reach someone who helps you |
| P2 | We only say what is true about your business | Correct answers, or an honest "I'll have them call you" |
| P3 | Your data is yours and nobody else's | Your details stay private |
| P4 | No spam, no wrong messages, no messages at 3 a.m. | You hear from the business only when it is useful and wanted |
| P5 | You stay in control; nothing important happens without your rules | You can always stop messages and reach a person |
| P6 | It just works, and when it doesn't, we tell you first | Your booking is real |

## 4. The four surfaces

| Surface | Address | Who | Built from |
|---|---|---|---|
| **AI receptionist** | the business's phone number | callers | Vapi (voice), `voice-rules` edge function, database rules |
| **Business CRM** | `/app` (planned host `app.zellavoice.com`) | business members | `web/src/BusinessApp.jsx` and the `Business*.jsx` pages |
| **Platform admin** | `/` (planned host `admin.zellavoice.com`) | Zella Voice staff | `web/src/OwnerDashboard.jsx` and admin pages |
| **Public link pages** | `/r/<code>`, `/w/<code>`, `/u/<code>`, `/status`, `/continue-plan`, `/welcome` | customers and owners without signing in | `Reschedule.jsx`, `WaitlistOffer.jsx`, `Unsubscribe.jsx`, `StatusPage.jsx`, `ContinuePlan.jsx` |

The public link pages:

| Page | What the person can do |
|---|---|
| `/r/<code>` Reschedule | See their appointment, pick a free time and move it. The private code opens one appointment only. |
| `/w/<code>` Waitlist offer | Accept or decline a time that freed up. The calendar re-checks the time on accept. |
| `/u/<code>` Unsubscribe | Stop emails from that one business. |
| `/status` | The Zella Voice service status and public incidents. |
| `/continue-plan` | An owner who scheduled a cancellation keeps their plan, from the email link. |
| `/welcome` | Accepting an invitation and finishing sign-in from an email link. |

A malformed private link shows a "this link isn't valid" page, never the admin sign-in.

## 5. Status words used in this document

| Status | Meaning |
|---|---|
| **Built** | In the repository, tested, and in the production database or ready to ship with the web app |
| **Built, off** | Built and tested, but its live switch is off: it runs in dry run and nothing reaches the real world |
| **Partial** | Some of it works; the gap is named |
| **Planned** | Designed in `docs/ARCHITECTURE.md`, not built |

Live switches (all **off** in production on 12 Nov 2026, so nothing is sent or called): `calls_live`, `sms_live`,
`email_live`, `calendar_sync_live`, `reviews_live`, `review_ai_live`, `knowledge_ai_live`, `call_intel_live`,
`call_reconcile_live`, `spam_workflow_live`, `spam_ai_live`, `website_crawl_live`. Turning any on needs the owner's
explicit approval (`NN-3`). Current state is kept in `docs/MEMORY.md`.

---

## 6. Industries

One product serves 28 industries. Nothing in the code branches on the industry: each industry's configuration
decides the words, booking model, CRM modules, record types, automations, templates, receptionist focus and privacy
rules (`BIZ-4`, `BIZ-10`). A business customises within its industry's bounds, and its changes survive industry
upgrades.

| Industry | Words (customer / booking / staff) | Booking model | Regulated |
|---|---|---|---|
| Beauty & Salon | client / appointment / stylist | staff appointment | no |
| Spa & Wellness | client / appointment / therapist | staff appointment | no |
| Fitness | member / class / instructor | class | no |
| Restaurant | guest / reservation / host | table | no |
| Hospitality | guest / stay / front desk | stay | no |
| Travel | traveller / consultation / agent | consultation | no |
| Education | student / class / teacher | class | no |
| Childcare | parent / tour or session / staff | class | **yes** |
| Pet Care & Veterinary | pet owner / appointment / vet or groomer | staff appointment | no |
| Dental | patient / appointment / dentist | staff appointment | **yes** |
| Healthcare | patient / appointment / provider | staff appointment | **yes** |
| Legal | client / consultation / attorney | consultation | **yes** |
| Financial Services | client / consultation / advisor | consultation | **yes** |
| Insurance | policyholder / consultation / agent | consultation | **yes** |
| Professional Services | client / consultation / consultant | consultation | no |
| Real Estate | lead / viewing / agent | viewing | no |
| Property Management | tenant or owner / job / technician | field job | no |
| HVAC | customer / job / technician | field job | no |
| Plumbing | customer / job / plumber | field job | no |
| Electrical | customer / job / electrician | field job | no |
| Home Services | customer / job / technician | field job | no |
| Cleaning Services | customer / visit / cleaner | field job | no |
| Landscaping & Lawn Care | customer / visit / crew | field job | no |
| Pest Control | customer / treatment / technician | field job | no |
| Automotive | customer / service appointment / technician | staff appointment | no |
| Photography & Events | client / booking / photographer | staff appointment | no |
| E-commerce | customer / order / support | none (order lookup, never books) | no |
| Other | customer / appointment / staff | general | no |

The full per-industry defaults (modules, record types, automations, receptionist focus) are in
`docs/ARCHITECTURE.md` §22.4.

**Regulated industries** launch only after legal review, with stricter settings: suggested messages instead of
automatic follow-ups, call transcripts closed to staff, no advice of any kind, private fields for sensitive details.
Lower-risk industries launch first (D-20).

**Capabilities** are the kinds of work a business offers, each switched on or off per business, and refused by the
server when off: scheduling, check-ins, waitlist, dispatch, classes, orders, money, access vault, tables.

**Modules** are CRM areas available per industry and switched on per business: `ai-receptionist`, `ai-appointments`,
`ai-follow-up`, `ai-sales`, `ai-support`, `automations`, `calendar`, `calls`, `email`, `sms`.

---

## 7. The AI receptionist

**Status: built. Answering real calls is not yet proven end to end.** Vapi still sends some call messages without the
authentication Zella Voice requires (see `docs/MEMORY.md`). Live assistants are never changed without approval.

### 7.1 What it does on a call

| Ability | How it works | Status |
|---|---|---|
| Answers every call | Vapi asks Zella Voice for the assistant at the start of each call (`assistant-request`). It is built fresh from the business's current settings, so a CRM change reaches the next call with no sync. | Built |
| Speaks the business's language and voice | Each business picks from approved voices and the languages its plan allows (English, Spanish or both). | Built |
| Answers questions truthfully | Only from approved knowledge and tools. If it doesn't know, it says so and takes a message (`NN-7`). Unknown questions become knowledge gaps for the owner. | Built |
| Checks opening hours | Weekly hours with several ranges a day, holidays and part-day closures, in the business's time zone. | Built |
| Recognises the caller | Looks the caller up by the number the phone network gives (never by what is said). | Built |
| Books, finds, moves and cancels appointments | Real availability: staff, resources (rooms, chairs, bays), buffers between bookings, holds and locks so two callers can't take the same time. | Built |
| Restaurant reservations | Party size, table choice and seating preference, table combinations for larger parties. | Built |
| Takes messages | Stored as call messages for the team, marked after-hours when they are. | Built |
| Logs requests | Things the caller asked for become customer requests with an owner and due time. | Built |
| Reports emergencies | Industry safety lines and an emergency path to the on-call person. | Built |
| Transfers to a person | Only to numbers this business authorised, using the on-call rota after hours. A failed transfer becomes a callback. | Built |
| Requests a follow-up | Creates a callback or task instead of promising something it can't do. | Built |
| Looks up an order (E-commerce) | Shopify order status with assurance levels: what can be said depends on how sure we are the caller is the customer. Lookups are limited per call and caller. | Built |
| Screens spam | Risky callers are scored and screened before tools run. | Built |
| Records the call | Status updates in order, then an end-of-call report with outcome and summary. | Built |

The receptionist's tools (one server-checked gateway, `zella_ai_tool`, makes every decision): `search_knowledge`,
`check_open_hours`, `lookup_caller`, `update_caller`, `check_availability`, `book_appointment`,
`find_my_appointments`, `reschedule_appointment`, `cancel_appointment`, `take_message`, `report_emergency`,
`transfer_to_human`, `request_follow_up`, `report_unanswered_question`, `lookup_order`.

### 7.2 What the owner controls

Greeting and name, voice, languages, call handling rules (when to transfer, when to take a message), escalation
triggers, things the receptionist must never do, industry safety lines, after-hours behaviour, on-call rota,
knowledge, and which tools are switched off. Owners, admins and managers change these in Settings > AI receptionist;
Zella Voice staff can change them from the admin.

### 7.3 Quality and safety

| Feature | Status |
|---|---|
| Every tool call logged with arguments, answer and an idempotency key (a call delivered twice runs once) | Built |
| Replayed or unsigned Vapi requests refused | Built |
| Staff can report a wrong answer and give the right one | Built |
| Calls sampled for quality review | Built |
| Evaluation cases per industry (`ai_eval_cases`) | Built |
| Configuration versions: what each call actually received | Built |
| Call recording | **Off** until legal review (D-13) |
| AI call intelligence (topics, sentiment) | Built, off (`call_intel_live`) |

### 7.4 Outbound calls

| Feature | Status |
|---|---|
| AI calls new leads about a minute after they arrive, within contact hours; 2 attempts about 2–3 hours apart until plans set the number; one message after each missed attempt; then "unreachable" and a staff task (D-01, D-02) | Built, off (`calls_live`) |
| AI callbacks to missed callers 2–5 minutes after a missed call, after verification (D-12) | Built, off |
| Short professional voicemail where allowed (D-10) | Built, off |
| "Don't call me" honoured instantly for that business (`NN-8`) | Built |

---

## 8. Business CRM

The sidebar is configuration (`web/src/navigation/navConfig.js`). A business sees an item only when all three pass:
the module is available in its industry, the business has it on, and the person's role allows it. The server enforces
the same rules; hiding an item is never the protection.

### 8.1 Workspace

| Page | What it does | Status |
|---|---|---|
| **Today** | What needs doing now: calls needing attention, callbacks, today's bookings, follow-ups, alerts, a calls-this-week chart. Cards come from the industry. | Built |
| **Calendar** | Day, week and staff views of bookings; book, move, cancel, confirm requested bookings; blocked times. | Built |
| **Tables** (restaurants) | The floor plan: table states (free, seated, needs clearing), blocks, combinations, walk-ins. | Built |
| **Dispatch** (field work) | The board for jobs: assign, en route, on site, finished, checklists, return visits. | Built |
| **Resources** | Rooms, chairs, bays and equipment bookings need; which services need which. | Built |
| **Recurring visits** | Repeat work (every two weeks, monthly) that generates future visits. | Built |
| **Check-ins** | Staff mark arrivals, no-shows and attendance (staff-managed first, D-15). | Built |
| **Waitlist** | People waiting for a time; freed times are offered by private link. | Built |
| **Tasks & follow-ups** | Staff tasks and automatic follow-ups due, with owner and due time. | Built |
| **Follow-through** | Approvals waiting, dates coming up, and problems holding work up, across all records. | Built |

### 8.2 CRM

| Page | What it does | Status |
|---|---|---|
| **Leads** | Every new lead with source, stage, owner and qualification answers; Pipeline view; server-side paging. | Built |
| **Customers** (named by the industry) | One record per person with a timeline of every call, message, booking and note; duplicates flagged for review and merge; relationships (parent, guardian) with what each may do; consent and contact preferences; data export and erasure. | Built |
| **Money** | Charges and recorded payments, balances, quotes. Records only: no card number ever touches Zella Voice (`NN-9`). | Built |
| **Business operations** (named by the industry) | The industry's own records (pets, vehicles, matters, policies, jobs, ...) with private fields, files, approvals, milestones, inspections, exceptions and credits. "Customize records" lets leads add fields within the industry's bounds. | Built |

### 8.3 Communications

| Page | What it does | Status |
|---|---|---|
| **Needs attention** | Calls and messages someone must act on, with a live count. | Built |
| **Inbox** | Every conversation in one place, read state, notes, handover between staff, replies. | Built |
| **Messages** | Texts and emails sent, skipped or failed, and why. | Built |
| **Calls** | Every call with outcome and summary. Transcripts only for managers and above, staff only if the owner allows, never in sensitive industries. | Built |
| **Callbacks** | Calls the business owes, with attempts, owner and status. | Built |
| **Suggested messages** | Drafts waiting for staff approval (used instead of automatic messages in regulated industries). | Built |
| **Sending failed** | Messages that could not go, with retry. | Built |
| **Spam protection** | Detected spam calls, texts and form posts; block and allow lists; review queue. | Built |

### 8.4 AI and automation

| Page | What it does | Status |
|---|---|---|
| **AI Receptionist > Voice and setup** | Voice, languages, greeting, rules, readiness. | Built |
| **AI Receptionist > Transcripts** | Call transcripts for the roles allowed to see them. | Built |
| **Call handling rules** | When to transfer, take a message or escalate. | Built |
| **Knowledge base** | Approved answers, versions and rollback, knowledge gaps to answer, website sources. AI drafting of answers is built, off (`knowledge_ai_live`). | Built |
| **Automations** | The business's automations from its industry presets, on or off, with channel decisions and run history. | Built |

### 8.5 Business growth

| Page | What it does | Status |
|---|---|---|
| **Lead sources** | Website forms and chat widget (public form key, allowed websites, spam checks), Google Ads lead forms (key shown once), Facebook and Instagram leads, lead rules and questions. | Built (Meta channels: see §10) |
| **Reviews** | Google reviews and AI reply drafts the owner approves before anything is posted. | Built, off (`reviews_live`, `review_ai_live`) |
| **Reports & analytics** | Calls, bookings, response times, lead sources, campaigns, usage; scheduled reports. | Built |

### 8.6 Management

| Page | What it does | Status |
|---|---|---|
| **Team & staff** | The staff list (named by the industry), skills, time off, handovers. | Built |
| **Scorecards** | Per-staff results with nudges. | Built |
| **Team access** | Invite, change role, deactivate, resend invitations (owners and admins). | Built |
| **Approvals** | Two-person approval for risky actions (exports, erasure, role changes). | Built |
| **Security log** | Who did what in this business. | Built |
| **Integrations** | Calendar (Google, Outlook), Shopify, Google leads, Meta, website. | Built (each provider stays off until approved) |
| **Notifications** | History of in-app notifications and live pop-ups. | Built |
| **Settings** | Business profile, team and access, AI receptionist, phone system, billing and subscription, calendar and appointments, CRM and customers, industry and workflows, automations, integrations, SMS/email/messages, notifications, security and privacy, reports and preferences, help and support, personal profile, appearance (Classic or Glass, picture-based palette). Unsaved changes are guarded. | Built |

### 8.7 Business roles

| Role | Can | Cannot |
|---|---|---|
| Owner | Everything, including billing, ownership transfer, deletion, data export | — |
| Admin | Settings, team (not owners or other admins unless the owner allows), automations, integrations, receptionist | Billing, ownership, deletion |
| Manager | Daily operations, money records, approvals, transcripts (unless the industry forbids), reports | Settings, team, integrations |
| Staff | Assigned and team work: calls, callbacks, bookings, messages, records | Money settings, other staff's private data, transcripts unless the owner allows |
| Viewer | Read only; no amounts; no transcripts | Any change |

Multi-factor sign-in is enforced on the server for the roles that require it.

---

## 9. Platform admin (Zella Voice staff)

Each page needs a named permission, the same one the server checks for its data. An admin with a restricted role sees
only the pages they can use. Every admin action is written to the audit log.

| Group | Page | What it does | Permission |
|---|---|---|---|
| — | **Overview** | Platform health, businesses, calls, alerts at a glance | `businesses.view` |
| Businesses | **Businesses** | Every business; open one to see and support it; suspend, reactivate | `businesses.view` |
| Businesses | **Verification** | Business and owner verification documents (private storage) | `businesses.manage` |
| Businesses | **Create Business wizard** | Business → Owner & verification → Hours & services → Team → AI receptionist → Phone & integrations (spam protection) → Automations → CRM setup → Review. Adapts its fields to the industry, saves drafts, guards unsaved changes, and invites the owner only once setup finishes. | `businesses.manage` |
| Configuration | **Industry configuration** | The 28 industries' configurations | `businesses.view` |
| Configuration | **Modules & features** | Modules per industry and business | `businesses.view` |
| Configuration | **Plans & subscriptions** | Plans (none exist yet, D-34) | `billing.view` |
| Configuration | **Offers & promotions** | Offers, rules, redemptions | `billing.view` |
| AI & communications | **AI agents** | Receptionist agents and configurations | `businesses.view` |
| AI & communications | **Voice & numbers** | Assign and release phone numbers, voice usage, alerts | `businesses.view` |
| AI & communications | **Messaging** | Messages across businesses, templates, compliance, retries | `businesses.view` |
| Operations | **Platform operations** | Scheduler health, dispatcher, provider health, failed work | `businesses.view` |
| Operations | **Automations** | Automations and runs across businesses, retry, pause | `businesses.view` |
| Operations | **Integrations** | Provider connections and their state | `businesses.view` |
| Operations | **Support** | Support tickets | `support.manage` |
| Operations | **Security & abuse** | Spam and abuse across the platform | `security.view` |
| Administration | **Users & access** | Platform admins and their roles | `security.view` |
| Administration | **Audit logs** | Every privileged action; append-only | `audit.view` |
| Administration | **Settings** | 17 categories: general, tenants, users, plans, offers, billing, AI providers, voice and usage, communications, integrations, security, alerts, support, analytics, legal, developer, administrator profile | per category |

Platform roles use named permissions (`businesses.view/manage`, `telephony.manage`, `comms.manage`, `ai.configure`,
`integrations.manage`, `billing.view/manage`, `plans.manage`, `support.manage`, `security.view/manage`, `audit.view`,
`analytics.view`, `growth.manage`). Only the Zella Voice owner manages platform admins. An admin alerts bell shows
platform alerts live.

---

## 10. Messaging and follow-ups

Every outbound message passes the same path: consent check, template, safe content, log, duplicate protection, the
live switch, then the provider. Off means dry run: the message is logged as "would have sent" and nothing leaves.

| Feature | Status |
|---|---|
| Appointment confirmations and reminders by text (Telnyx) | Built, off (`sms_live`) |
| Appointment confirmations and reminders by email (Resend) | Built, off (`email_live`) |
| Follow-ups: no-show, thank-you, quote follow-up, reactivation (opted-in only), callback fallback, missed-call text, lead acknowledgement | Built, off |
| Text ↔ email switching when one channel can't reach the person | Built |
| Owner emails: daily summary, weekly review, warnings and urgent alerts, honouring each person's preferences | Built, off |
| STOP / START / HELP keywords | Built |
| Opt-out wins, instantly and for that business (`NN-8`) | Built |
| Contact hours: calls in business hours, replies immediately, reminders 07:00–21:00, other service messages and marketing 09:00–19:00, in the recipient's time zone when known (D-03) | Built |
| Frequency limits: one unprompted message a day, one check-in per visit, until plans set them (D-23) | Built |
| Templates fully editable except protected compliance content | Built |
| Marketing email, with a one-click unsubscribe link (`/u/<code>`) | Built, off: refused until the app address (`app_base_url`) is set, because the unsubscribe link needs it |
| Email delivery, bounce and complaint events | Built |
| Inbound email | Built, off |
| Two-way AI replies by text and email with staff takeover | Planned (§14.3 of the architecture) |
| Facebook, Instagram and WhatsApp (Meta) | Workers built; launch scope not decided (D-39) |
| Staff alerts by text for staff who don't sign in | Built, off |

---

## 11. Leads

| Feature | Status |
|---|---|
| Website forms and chat widget: allowed websites, spam checks, rate limits, duplicates, consent | Built |
| Google Ads lead forms with per-business keys; retries recognised | Built |
| Facebook and Instagram lead ads | Built, off |
| Lead rules: qualification questions, assignment, overdue alerts | Built |
| Speed-to-lead AI call | Built, off (`calls_live`) |
| Lead reactivation (opted-in only) | Built, off |

---

## 12. Spam protection

| Feature | Status |
|---|---|
| Calls, texts, emails and form posts scored when they arrive | Built |
| High-risk callers screened before any tool runs; medium risk goes to review, no callback | Built |
| Business block and allow lists | Built |
| Spam follow-up workflow (repeat offenders, weekly summary) | Built, off (`spam_workflow_live`) |
| AI opinion on ambiguous texts and emails | Built, off (`spam_ai_live`) |
| Platform view across businesses (admin Security & abuse) | Built |

---

## 13. Billing, plans and usage

| Feature | Status |
|---|---|
| Plans, prices and minute allowances | **None exist.** The Zella Voice owner sets them later (D-09, D-34). Nothing is invented. |
| Usage ledger: one append-only entry per finalised call; our failures are never billable | Built |
| Usage thresholds and warnings; owner chooses what happens near or over a limit; a live call is never cut | Built |
| Voice cost estimates per business | Built |
| Payment provider webhook: signed, applied once and in order, never moves a subscription backwards | Built, off until the webhook secret is set |
| Scheduled cancellation and "Continue my plan" link | Built |
| Offers and promotions | Built |
| Card data | Never stored (`NN-9`) |

---

## 14. Calendar and integrations

| Integration | What it does | Status |
|---|---|---|
| Google Calendar, Outlook | Two-way: busy times block booking; Zella Voice bookings appear in the calendar | Built, off (`calendar_sync_live`) |
| Shopify | Order status for the receptionist, read-only scopes | Built |
| Google Ads lead forms | Leads into the CRM | Built |
| Meta (Facebook, Instagram, WhatsApp) | Leads and messages | Built, off |
| Website crawler | Reads the business's website for knowledge suggestions | Built, off (`website_crawl_live`) |
| Vapi | Voice calls | Built; real-call authentication open |
| Telnyx | Texts and phone numbers | Built, off |
| Resend | Email | Built, off |
| Stripe-style payment provider | Billing | Built, off |

Every provider request sits behind an explicit setting. Tokens and keys live in Supabase Vault or edge function
secrets, never in tables, code, logs or chat (`NN-2`).

---

## 15. Notifications

| Feature | Status |
|---|---|
| In-app notifications with plain wording and icons | Built |
| Live pop-ups for urgent events | Built |
| Per-person preferences (what, and by which channel) | Built |
| Celebrations for milestones (first call answered, first booking) | Built |
| On-call and scorecard nudges | Built |
| Admin alerts bell | Built |
| Push notifications for the installed web app | Planned (D-40) |

---

## 16. Privacy, security and trust

| Feature | Status |
|---|---|
| No business ever sees another's data: row security on every table (163 of 163); business functions check the caller's membership and role; public-link functions (reschedule, waitlist offer, unsubscribe, continue plan) authorise by a private, hashed link code that opens one item only; public platform functions return platform-level facts only (`NN-1`) | Built and tested (cross-tenant suite) |
| Audit log of every privileged action, append-only | Built |
| Private fields (access codes, member IDs, children's details) kept apart and never read aloud | Built |
| Files on records checked after upload; refused files deleted | Built |
| Customer data export and erasure (consent and opt-out history is kept so opt-outs keep working; the retention basis is for counsel to confirm) | Built |
| Two-person approval for risky actions | Built |
| Retention: recordings 30 days, transcripts 90 days, message bodies 2 years, audit and security logs 7 years, cancelled business 30 days (D-27, pending legal review) | Partial: retention is listed; nothing deletes automatically yet |
| Public status page and uptime alerts | Built |
| Consent capture per lead source for AI calls and automated texts | Decision open with counsel (D-04) |

---

## 17. Not built yet, or waiting on a decision

| Item | Waiting on |
|---|---|
| Self-service sign-up | Later phase (D-06) |
| Plans and prices | The owner (D-34) |
| Two-way AI messaging | Build (architecture §14.3) |
| Voicemails page, AI agents beyond the receptionist, marketing campaigns | Build; hidden from the sidebar until they exist |
| Meta channels in launch scope | Owner and counsel (D-39) |
| Calendar providers at launch | Owner (D-08) |
| Caller verification for booking changes by phone | Owner (D-18) |
| Push notification provider | Owner (D-40) |
| Self check-in | Later (D-15) |
| Call recording | Legal review (D-13) |
| Automatic deletion at end of retention | Build, after legal review |

The full list of open decisions is in `docs/ARCHITECTURE.md` §23.2.

## 18. How a feature is "done"

A feature is done only when all of these hold (rulebook Part 21):

1. The database enforces its rules; the app only asks (`NN-6`).
2. It works for every industry through configuration, with no industry branch in code (`BIZ-10`).
3. Its live effects sit behind a switch that is off by default (`PRN-6`).
4. Tests pass in an isolated environment, including cross-tenant tests for anything that touches business data.
5. Migrations are version-guarded and have an exact rollback that deletes no data (`NN-10`).
6. The UI shows loading, error and unavailable states honestly; a failed load is never shown as zero or "all good".
7. This document, `docs/ARCHITECTURE.md`, `docs/BACKEND_SCHEMA.md` and `docs/MEMORY.md` are updated in the same
   pull request.
8. CodeRabbit has reviewed it, and it is merged by the owner or, with the owner's standing permission, by Claude
   once the review is clean and the tests pass.
