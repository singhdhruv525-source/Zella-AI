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
| `/u/<code>` Unsubscribe | Stop emails from that one business. If the link was opened very often in a few minutes, the page can't show the business name for a while, but the Unsubscribe button still works (opt-out always wins). |
| `/status` | The Zella Voice service status and public incidents. It says "Everything is working" only when every part is checked and working; while any part isn't checked it says "Not every part is checked right now", and reminders and follow ups read Working only while the dispatch job is on and running (`sql/zella_status_honest.sql`, built, not applied). |
| `/continue-plan` | An owner who scheduled a cancellation keeps their plan, from the email link. |
| `/welcome` | Accepting an invitation and finishing sign-in from an email link. A business owner invited by the Zella Voice team goes on to the onboarding journey (below) when the server has one waiting; everyone else keeps the plain password page. |
| `/welcome/setup` | The owner onboarding journey (§8.8). Needs the owner's own sign in. |

A malformed private link shows a "this link isn't valid" page, never the admin sign-in. Any other address that matches no
page (for example `/pricing`) shows a plain "Page not found" page with a link to the home page to someone who isn't
signed in (`NotFound.jsx`, decided in `publicRoute.js`); a signed in person keeps the admin dashboard, which has its own
"Page not found", and the admin dashboard's own addresses (`/businesses`, `/settings`, ...) still open its sign in.

`/continue-plan` and the calendar and store connections are rate limited per person (or visitor address) and per
business; past the limit the page says "Too many attempts. Wait a minute and try again." (`SEC-12`, conformance G-6).

**Owner onboarding journey** (from the `/welcome` link; contract `docs/OWNER_ONBOARDING_CONTRACT.md`). The server side
is **built, not applied** (`sql/zella_owner_onboarding.sql`, the `owner-onboarding` and `identity-webhook` edge
functions; nothing deployed); the screens are being built separately. Progress is saved per business after every
step, and "Finish later" brings the owner back to the same step.

| # | Step | What the server does now | Status |
|---|---|---|---|
| 1 | Welcome | Shows the business name and the steps | Built, not applied |
| 2 | Password and two step sign in | Done only when the account has a password and a verified authenticator and the session was verified with a code, read from the auth records | Built, not applied |
| 3 | Check your details | Business, hours and services, team, AI receptionist and phone, each "Looks right" or "Change" with a note. A note reaches Zella Voice as an admin alert; once the change is made the owner checks that section again. A section that changed after "Looks right" asks again | Built, not applied |
| 4 | Verify your identity | Manual upload: the owner uploads their ID and business registration; Zella Voice checks them in Verification. Shows Documents needed, Checking, Verified, Try again (a rejected document, upload a new copy) or In review (after 2 failed checks Zella Voice reviews it by hand). The owner can't pass until it is verified. A provider (Persona) can be connected later; its receiver is built and off | Partial: manual path built, not applied; provider not connected |
| 5 | Your plan | Shows the plan Zella Voice saved for the business (price, minutes, texts, emails, seats, numbers); the owner accepts it. No switching | Built, not applied |
| 6 | Pay or start a trial | Shows "waiting": payments aren't connected (Stripe Checkout isn't built). Opens only after identity is verified | Partial: waiting only |
| 7 | You're all set | Records the end of the journey; the CRM's go live checks follow | Built, not applied |

Going live now also needs the owner's identity verified and a confirmed first payment, in both the CRM's checklist and
the server's own go live check (built, not applied). Admins see each business's step through
`zella_admin_onboarding_overview()` and `zella_admin_onboarding_progress(id)`; the business page doesn't show it yet.

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

Each industry's booking model, whether it is sensitive and its default automations are stored with the industry
(`industries.booking_model`, `industries.sensitive`, `industry_configurations.automation_defaults`; CFG-05, built, not applied)
and edited on Industry configuration. The receptionist's industry safety lines are stored there too
(`industry_configurations.safety_rules`), read by the receptionist once `sql/zella_brain_safety_rules.sql` is applied.

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
| Speaks the business's language and voice | Each business picks from approved voices; its languages are the ones its plan allows (English, Spanish or both), set only by the Zella Voice team. Only voices that speak the business's languages are offered and accepted (a multilingual voice always is); if a saved voice stops fitting, for example after Spanish is removed, calls use the Zella Voice default voice and the assistant configuration notes it (built, not applied: `sql/zella_admin_languages.sql`). The approved voices come from three providers, all through Vapi: Vapi's own voices, ElevenLabs, and Cartesia (Katie, Kiefer, Jacqueline and Blake in English; Daniela and Pedro in Spanish). The picker (Settings > Voice and the admin wizard) is a carousel of voice cards: the Zella Voice default first, then Cartesia, ElevenLabs and Vapi voices, those in the business's languages first, with All and per provider filter chips above. The centred card is the choice: swiping, the arrow buttons, the dots (a "4 of 21" counter past nine voices) or the arrow keys move it, and the card shows the name, a provider badge, language and gender. A Cartesia or ElevenLabs card has a play button for a short sample in that voice ("Hi, thanks for calling. I'm your Zella Voice receptionist. How can I help you today?", or the same line in Spanish for a Spanish voice); one plays at a time and pressing it never changes the choice. Samples come from the `voice-sample` edge function, which makes each one once with the provider and keeps it in the private `voice-samples` bucket; new samples are made only while the setting `voice_samples_live` is on (off until the owner switches it on, with approval). Samples already stored still play while it is off; a voice with no stored sample says "Sample not available yet" until the switch is on and the provider key is added. Vapi voices have no sample, and neither have Vapi's preset ElevenLabs names (Burt, Marissa and the like), which ElevenLabs' own API doesn't take; ElevenLabs voices listed by their ElevenLabs id do. Without permission to change the voice, the card shows the chosen voice only. A Cartesia voice is used whatever Zella Voice's default voice provider is, with the Cartesia model set in `voice_cartesia_model` and the business's language; ElevenLabs and Vapi voices are used only while their provider is the default. On calls, Vapi uses the Cartesia key the owner saves in the Vapi dashboard, and Zella Voice stores no key for calls. Voice samples are separate: the `voice-sample` function calls Cartesia and ElevenLabs itself with its own edge function secrets (`CARTESIA_API_KEY`, `ELEVENLABS_API_KEY`). | Built; Cartesia built, not applied (`sql/zella_cartesia_voices.sql`); samples built, not deployed (`sql/zella_voice_samples.sql`, `voice-sample`, the provider keys, `voice_samples_live` off) |
| Ends a silent call politely | If the caller says nothing, the receptionist asks once "Are you still there?" after 30 seconds and, after a minute of silence, says "It seems we've been disconnected. Thanks for calling {business name}, goodbye." and ends the call (in Spanish for a Spanish speaking business: "¿Sigue ahí?" and "Parece que se cortó la llamada. Gracias por llamar a {business name}, adiós."). Never sooner than a minute. The minute is the platform setting `voice_silence_timeout_seconds` (60, from 60 to 1000) (owner, 25 Nov 2026: REQ-VOX-13, `AI-24`). | Built, not applied (`sql/zella_silence_timeout.sql`) |
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
| Checks who is calling before sharing or changing a booking | Appointment details only after the caller gives the name on the booking and the date, from the number it was made with. Cancelling or moving needs the booking's 6 character confirmation code, which is in every confirmation and reminder and on the booking in the CRM. Three failed checks in a call and it takes a message instead. A new email or phone for a known caller waits on the customer's page for the team to approve. | Built, not live (`sql/zella_caller_verification.sql` not applied) |
| Screens spam | Risky callers are scored and screened before tools run. | Built |
| Records the call | Status updates in order, then an end-of-call report with outcome and summary. | Built |

The receptionist's tools (one server-checked gateway, `zella_ai_tool`, makes every decision): `search_knowledge`,
`check_open_hours`, `lookup_caller`, `update_caller`, `check_availability`, `book_appointment`,
`find_my_appointments`, `reschedule_appointment`, `cancel_appointment`, `take_message`, `report_emergency`,
`transfer_to_human`, `request_follow_up`, `report_unanswered_question`, `lookup_order`.

### 7.2 What the owner controls

Greeting and name, voice, call handling rules (when to transfer, when to take a message), escalation
triggers, things the receptionist must never do, industry safety lines, after-hours behaviour, on-call rota,
knowledge, and which tools are switched off. Owners, admins and managers change these in Settings > AI receptionist;
Zella Voice staff can change them from the admin. **Languages are the exception:** only the Zella Voice team changes
them, within the business's plan (at Create Business, then on the admin business page's AI receptionist tab). Settings >
Languages shows them read only with "Your receptionist's languages are set by Zella Voice and come with your plan. To
add Spanish, contact Zella Voice support." and a link to Help and support (built, not applied:
`sql/zella_admin_languages.sql`).

### 7.3 Quality and safety

| Feature | Status |
|---|---|
| Every tool call logged with arguments, answer and an idempotency key (a call delivered twice runs once) | Built |
| Replayed or unsigned Vapi requests refused | Built |
| Staff can report a wrong answer and give the right one | Built |
| Calls sampled for quality review | Built |
| Evaluation cases per industry (`ai_eval_cases`) | Built |
| Configuration versions: what each call actually received | Built |
| Call recording | **Off** until legal review (D-13). Built, not deployed: a recording on or off policy per business (Settings, Legal, policy and documents > Policy configuration). The policy is off by default and refused on until a Zella Voice owner records legal approval and the caller disclosure line (both empty: pending legal review); withdrawing approval turns the policy off for every business; audited. The policy doesn't change live calls yet: the phone assistant doesn't read it, so Vapi's own settings still decide whether a call is recorded until a separately approved call path change |
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
| **Today** | What needs doing now: calls needing attention, callbacks, today's bookings, follow-ups, alerts, a calls-this-week chart. Cards come from the industry. Titled "Today" with the date under it and the business name on a quieter line below (another day shows that date as the title); on a phone the bookings table folds its columns under the name (owner, 25 Nov 2026). | Built |
| **Calendar** | Day, week and staff views of bookings; book, move, cancel, confirm requested bookings; blocked times. | Built |
| **Tables** (restaurants) | The floor plan: table states (free, seated, needs clearing), blocks, combinations, walk-ins. Restaurants book real tables, not just a seat limit, and the same drawn floor plan shows as a Table layout card on Today (owner, 6 Nov 2026). | Built |
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

Counts and names read as words (owner, 25 Nov 2026): a list's count uses each record kind's own plural ("4 events and
catering"), report counts agree with their number ("1 arrival", "1 no show"), the Spam protection chart shows days as
"Nov 23", and Settings, Industry profile lists real module names ("AI receptionist, Automations, Calendar, Calls").

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
| **Delete this account** (owner, Settings > Privacy) | The owner asks with the business name typed; a Zella Voice admin confirms under Data retention; the account is frozen at once (calls not answered, automations paused) and deleted 30 days later unless the owner cancels; the copies at Vapi are queued for deletion; audit history is kept without the business | Built, not applied (`sql/zella_account_deletion.sql`); the purge waits for the purge switch and lane B's audit SET NULL |
| **Privacy policy and terms** | Public pages /privacy and /terms, linked from both sign in pages; drafts for owner and legal review until published; the owner accepts both during onboarding (recorded on the server) | Drafts built, not applied (`sql/zella_privacy_retention.sql`); legal review pending |
| **AI Receptionist > Voice and setup** | Voice, languages, greeting, rules, readiness. Callers always hear that they are speaking with an AI receptionist (added in their language if a custom greeting leaves it out) and, only while recording is on for the business, that the call is recorded; Vapi recording follows the same setting (off) | Built; the disclosure is built, not applied (`sql/zella_call_disclosure.sql`) |
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
| **Settings** | Business profile, team and access, AI receptionist, phone system, billing and subscription, calendar and appointments, CRM and customers, industry and workflows, automations, integrations, SMS/email/messages, notifications, security and privacy, reports and preferences, help and support, personal profile, appearance (the look; a built in default background or the person's own picture; the owner's rule, 28 Oct 2026, is that the whole look takes on the picture's colours except the Zella Voice logo, which keeps its own; built in the Glass look only so far; and the Notification sound switch). Unsaved changes are guarded. | Built |

### 8.7 Business roles

| Role | Can | Cannot |
|---|---|---|
| Owner | Everything, including billing, ownership transfer, deletion, data export | — |
| Admin | Settings, team (not owners or other admins unless the owner allows), automations, integrations, receptionist | Billing, ownership, deletion |
| Manager | Daily operations, money records, approvals, transcripts (unless the industry forbids), reports | Settings, team, integrations |
| Staff | Assigned and team work: calls, callbacks, bookings, messages, records | Money settings, other staff's private data, transcripts unless the owner allows |
| Viewer | Read only; no amounts; no transcripts | Any change |

Multi-factor sign-in is enforced on the server for the roles that require it. Every Zella Voice admin must use two step sign in (an authenticator app): an admin without one is walked through setting it up at sign in, can't use any page until then, and can't remove their only authenticator (built, not live: needs the web app, `owner-provision-business` and `sql/zella_admin_mfa.sql`, in that order).

### 8.8 Owner onboarding journey

What a business owner sees after opening their invitation, at `/welcome/setup` (`web/src/onboarding/`). The server
side is described in `docs/OWNER_ONBOARDING_CONTRACT.md` (built on its own branch, not applied or deployed); the
screens call only what it lists and the database decides every rule. Every screen has a progress bar (step n of 7),
Finish later (the owner comes back to the same step, from the email link or from a "Finish setting up" banner in the
CRM), loading, error, empty and "This step isn't ready yet" states, a phone first layout, the Classic and Glass looks,
and focus moving to each new step's heading. The CRM banner shows nothing if it fails to load. If the password saves but
reading the next step fails, trying again (or Carry on now after Finish later) reads the step again without saving the
password a second time.

| # | Screen | What the owner does | Status |
|---|---|---|---|
| 1 | Welcome | Sees their business name and the steps ahead | Screens built (not deployed); need the onboarding database functions |
| 2 | Password and two step sign in | Chooses a password, then adds an authenticator app (the same set up calls as the admin sign in, through the shared `AuthenticatorSetup` component) | Screens built (not deployed) |
| 3 | Check your details | Reviews business, hours and services, team, and AI receptionist and phone, one part at a time, with Looks right or Change; Change sends a note to the Zella Voice team, who make the change and send it back to check | Screens built (not deployed) |
| 4 | Verify your identity | Uploads their photo ID and business registration (manual upload, checked by Zella Voice in Verification); sees Documents needed, Checking, Verified, Try again or In review | Screens built (not deployed); needs the `owner-onboarding` edge function for uploads. No identity provider is chosen (owner decision open); the screen has one place reserved for a provider's widget |
| 5 | Your plan | Sees the plan, price and allowances exactly as the admin saved them, and accepts it (no switching) | Screens built (not deployed) |
| 6 | Pay | Sees "Payment opens here soon": payments aren't connected. "Payment received" shows only when the server confirms a payment | Waiting state built; paying needs Stripe Checkout (step 4 of billing) |
| 7 | You're all set | Sees what happens next (test call, go live checks from the server) and opens their CRM | Screens built (not deployed) |

Tested locally only: unit tests of the step rules (`web/tests/ownerOnboarding.test.mjs`) and a browser walk through
every screen against a stand in that follows the contract (`tests/browser/owner-onboarding-journey.cjs`). The stand in
(`web/src/onboarding/fakeApi.js`) is built in only with `VITE_ONBOARDING_FAKE=1` and never ships.

---

## 9. Platform admin (Zella Voice staff)

Each page needs a named permission, the same one the server checks for its data. An admin with a restricted role sees
only the pages they can use. Every admin action is written to the audit log.

| Group | Page | What it does | Permission |
|---|---|---|---|
| — | **Overview** | Platform health, businesses, calls, alerts at a glance | `businesses.view` |
| Businesses | **Businesses** | Every business, paged on the server (25 a page) with exact totals: search by name, owner, email or phone; filter by industry, stage, saved plan and "has a problem"; sort by newest, oldest, name or most problems. Each row shows the owner and their invitation, the saved plan ("Pro, v2" or "No plan saved") with the subscription status beside it, the stage (a draft names the step setup reopens at), the last call and open problems (warning or urgent platform alerts, a failed or expired owner invitation, a broken integration, failed setup). "Need attention" lists the businesses with a problem in one click. View is the main action once setup is done; create and setup buttons show only with `businesses.manage`, and suspend, reactivate and cancel on the business only with `businesses.lifecycle` (the server checks both again). Reads `businesses_list`; against an older server it falls back to the old unpaged list and says so. | `businesses.view` |
| Businesses | **Verification** | Business and owner verification documents (private storage). A **Missing documents** tab lists every business that hasn't sent its business registration or owner's photo ID, including ones already live (Live without documents), with Request documents: audited, at most once a day per business, and the Documents needed email (S4) is queued for the owner when the platform outbox is installed; nothing is sent until email sending is live, and the page says so (UI-11; built, needs the owner-provision-business deploy). Uploads never confirmed are deleted after 24 hours by the record-files function's server only documents cleanup, audited (BIZ-18a; built, needs `sql/zella_document_orphans.sql` and the record-files deploy; not scheduled until the owner switches it on) | `businesses.manage` |
| Businesses | **Create Business wizard** | Business → Owner & verification → Hours & services → Team → AI receptionist → Phone & integrations (spam protection) → Automations → CRM setup → Plan & pricing → Review. The ten steps show in two rows of five (numbers that wrap on a phone), Back is hidden on the first step, and the time zone search suggests a US zone. Adapts its fields to the industry, saves drafts, guards unsaved changes, and invites the owner only once setup finishes. Before the draft is made it warns about businesses that may be the same one (same name, phone number or website, cancelled ones left out) and offers Change details or Create anyway; one creation key per wizard session means a retry after a timeout returns the business the first try made, never a second one (BIZ-14; built, needs `sql/zella_business_creation_key.sql` and the owner-provision-business deploy). The AI receptionist step's Identity & voice section has a **Voice** carousel, the same as Settings > Voice (provider filter chips, voices in the chosen language first, the Zella Voice default unless changed, a play button for a sample on Cartesia and ElevenLabs voices). Review marks optional steps with nothing set with a small hollow ring instead of a word. Saving the step makes the choice the business's voice (`zella_setup_voice_apply`, server only, an admin with `businesses.manage`, audited), only when the wizard's choice changed, so the owner's later choice in Settings stays; Review shows it on the AI receptionist row (built, needs `sql/zella_cartesia_voices.sql` and the owner-provision-business deploy). The step's **Language** (English, Spanish, or both) is saved first and must fit the business's plan once one is set ("This plan includes 1 language. Move the business to a plan with Spanish first."); the voice list then shows only voices in the saved languages, and reloads once a new language is saved, so a Spanish voice can be picked after Spanish is saved (built, needs `sql/zella_admin_languages.sql` and the owner-provision-business deploy). | `businesses.manage` |
| Configuration | **Industry configuration** | The 28 industries' configurations: words, receptionist wording, modules. Switching a module off removes it at once from every business in the industry that has it on; the page shows "N businesses lose X" and asks for a reason first (audited). An industry can be deactivated and reactivated (audited, marked Inactive): it is then not offered for new businesses, and the businesses already in it keep working. Each industry also stores whether it is sensitive (staff never see call transcripts; a new industry starts sensitive; only a Zella Voice owner changes it, with a reason and a typed confirmation to turn it off, audited), its booking model, and the automations a new business starts with (CFG-05, `sql/zella_industry_data.sql`, built, not applied). When the list fails to load, or the server answers with nothing, the page shows one message, "Industries didn't load.", with a Try again button | `businesses.view`; changes `platform.configure` |
| Configuration | **Modules & features** | Modules per industry and business | `businesses.view` |
| Configuration | **Plans & subscriptions** | Every business with its own plan (business_plans), a page at a time: tier and version in short ("Pro v3"), price and interval, allowances, subscription status, and one action per row (Details, or Set up plan when the business has none); on phones each business is a card. A details drawer (eyebrow Plan, the business name as title) with every allowance ("Version 3 of 3"), this period's balances, the saved versions as a small table, and Open business in its footer. Payments aren't connected, so nothing is charged. The shared plans are shown as Fallback limits (used only for a business with no plan of its own); each card lists every allowance in words ("AI voice minutes per period: No limit", "Languages the receptionist speaks: 2"), from `web/src/copy/planAllowances.js`; their editors show only with `plans.manage` | `billing.view` |
| Configuration | **Offers & promotions** | Offers, rules, redemptions | `billing.view` |
| AI & communications | **AI agents** | Receptionist agents and configurations; Live and Answering per receptionist from the one definition (§9.1), with what is missing before it can be live; Setup reads "3 of 5 set" and what is missing, in words (the table fits at 1440 without sliding); what calls actually got in the last 7 days (served, not ready, unknown number, over its limit), the version served and the published one, and a drawer of recent calls with their problems. An AI testing tab runs each business's test questions against its knowledge (knowledge retrieval only, not live calls; nothing sent or charged), stores every run, and shows Passes (at least 3 questions, all passing) or a Warning; a failing run never blocks going live (AI-TESTING, `sql/zella_ai_eval_admin.sql`, built, not applied; running needs `businesses.manage`) | `businesses.view` |
| AI & communications | **Voice & numbers** | Assign and release phone numbers, voice usage, alerts; Call routing lists "Missing routing" (businesses with a receptionist but no transfer or no fallback number; a row opens that business's form) (including a missed call alert: 5 or more inbound calls in 24 hours with 25% or more missed, and refused Vapi requests in the last hour). The overview groups its nine tiles under Calls and Numbers. The overview tiles open the Calls tab filtered (inbound, outbound, completed, missed, failed, for the same period), the missed call alert opens that business's missed inbound calls, and a read only Switches panel lists outbound AI calls, plan limits for calls, how Vapi requests are checked and the call jobs (setting keys only as tooltips). The overview and Providers count refused Vapi requests (24 hours, last one) and show the Vapi auth mode; nothing about a refused request but its type, reason and header names is kept. Provider connection checks are on Overview only; Providers & costs shows keys, buying and releasing numbers through Telnyx and Vapi (an admin with `telephony.manage` asks with a reason and types BUY or RELEASE; a Zella Voice owner who didn't ask approves by typing the number; only then is the provider called, once; every step audited; **off** until `TELNYX_API_KEY` and `VAPI_API_KEY` are added and an owner sets `number_orders_enabled`, built, not deployed), the providers' error logs (read on request, caller numbers shortened), AI voice usage (the 20 businesses with most calls, then "See all") and pricing. Call lengths read "45 s", "1 min", "2 min 5 s" | `businesses.view` |
| AI & communications | **Messaging** | Messages across businesses, templates, compliance, retries. Live switches read in words ("Texts and emails are in test mode"), with the setting key only in a tooltip. On Templates, an admin with `comms.manage` can add an industry or Spanish version of a platform template (a Spanish version is kept but not sent yet: every sender asks for English today; how a send picks its language is waiting on the owner) and retire such a version (senders fall back to the platform version; the English platform version can't be retired), each with a reason and audited; variables go in at the cursor, and script tags are refused in any case (UI-20, COM-27; built, needs `sql/zella_admin_templates_manage.sql`). On Consent & opt outs, an admin with `comms.manage` can look up why one number or address of one business gets no messages (at least 4 digits or a full email, and a reason): masked results (last 4 digits), consent, do not contact flags, block lists and the last blocked message, every lookup audited (COM-29; built, needs `sql/zella_admin_contact_lookup.sql`) | `businesses.view` |
| Operations | **Platform operations** | Scheduler health, dispatcher, provider health, failed work; every scheduled job with its real state beside its intended state ("Deliberately off until go live") and what it drives, and a "job off" note on figures that need a job. Recording an intent needs `platform.configure`, is audited and never switches a job. Sending a failed event back needs `integrations.manage` and a reason, and is refused (with the reason in words) when a run of it is running or succeeded, had a step succeed or reached a provider, so a retry never repeats a message (`sql/zella_retry_event_safe.sql`, built, not applied). **The one go live checklist** (UI-23): every server secret (set or not set, never a value; including the Resend key and the Google and Microsoft calendar app keys), the settings (app, n8n and email function addresses, senders, the n8n secret in the vault), and every live switch and email trigger, in collapsible groups ("Server secrets, 7 of 14 ready" with a small meter) under four summary tiles. Only items that are not ready show until "Show ready" is chosen; secret and setting names sit in a Technical details disclosure. Scheduled jobs are counted in a tile and listed only in their own table (one source per item); the separate Services card is gone. One Refresh in the page header reloads everything. Automations, Messaging and Settings (n8n) link to it; it switches nothing on Incidents: opening, publishing and resolving ask in a dialog (the public status text starts empty, never copied from internal details); a second incident for a problem already open shows the open one first (Open anyway is still possible); open incidents can be edited (nobody is notified) and have a timeline of updates, internal unless Tell all active businesses is ticked (incidents don't record which businesses they affect, so the notice goes to every active business); older incidents load 20 at a time. Updates and edits need `sql/zella_incident_updates.sql` (built, not applied; the public status page doesn't show updates yet) | `businesses.view` (changes: `support.manage`) |
| Operations | **Automations** | Automations and runs across businesses, retry, pause. "Pause all" and "Resume all" for one business (Resume all brings back exactly what Pause all paused and nobody changed since; never the business's own, suspended or earlier pauses). Scheduler & n8n lists the scheduled jobs once (each with its intended state, as on Platform operations), the queue with n8n's answer to the last hand over of each workflow (accepted, wrong secret, workflow not published, no answer, or waiting), then the go live checklist in words (setting keys in tooltips), and n8n's own status per Zella Voice workflow (active in n8n or not, last run) read on the server with an n8n API key; it says "Not connected yet" until the owner sets `N8N_API_KEY` and `N8N_API_URL` | `businesses.view` |
| Operations | **Integrations** | What each business asked for in setup against what is connected (numbers, Vapi link, calendar, lead sources from §9.1; email reads Not tracked), plus store and other integration records. Each request is plain text with a small dot: green connected, grey not yet | `businesses.view` |
| Operations | **Support** | Support tickets: a conversation with the business (replies it sees in Settings > Help and support > Support requests, where owners, admins and managers answer) kept apart from internal notes; age and first reply in business hours (Monday to Friday 9 to 5 New York by default, `support_business_hours`); Waiting too long filter (no reply after 4 business hours); alerts for cancellation, plan change and urgent requests; assignees limited to people who may work tickets. Replies need `sql/zella_support_replies.sql` (built, not applied); the business is told in the app only | `support.manage` |
| Operations | **Security & abuse** | Spam and abuse across the platform: the tabs first, then (on Overview) the period's six totals, three a row | `security.view` |
| Administration | **Users & access** | Platform admins and their roles | `security.view` |
| Administration | **Audit logs** | Every privileged action; append-only. Filters by business, action (every action in the shared list), person, dates and record; Details list what changed in words (each field, before and after), with the raw record under "Show raw record", and the record id, address and browser. Export CSV (at most 10,000 entries, cells that could run as spreadsheet formulas defused) for a Zella Voice owner or super admin; each export is audited | `audit.view` (export: also owner or super admin) |
| Administration | **Settings** | 17 categories: general, tenants, users, plans, offers, billing, AI providers, voice and usage, communications, integrations, security, alerts, support, analytics, legal, developer, administrator profile. Platform settings are labelled in words, with the setting key as small help text; Communication templates previews the templates and links to Messaging, Templates, where they are edited. Alert rules: every alert kind the platform raises, grouped by area (AI receptionist, billing, calendar, messaging, offers, platform) with a search and an "only changed rules" switch, with its rule (on or off, severity, bell only or email to admins holding a permission, how often it may open again, quiet hours for email); saving needs `platform.configure` and a reason and is audited; urgent alerts are never switched off, lowered or delayed | per category |
| Administration | **Settings, Business onboarding** | Every business still in setup with what it has in place and when it last changed. Every setup save records its step in provisioning_steps (pending, then done or failed; a refused input puts the step back), so Failed steps and Provisioning errors show real failures, and a failed owner invitation email is its own step (SET-ONB-RETRY part 1; built, needs the owner-provision-business deploy). A failed internal step (modules, AI receptionist, automations) has **Retry step**, which only adds what is missing and is audited; a failed invitation email has Send owner invite; anything else is finished with Continue setup. A timed retry of the internal steps (at most 3 tries each) exists but is off until the owner switches it on (SET-ONB-RETRY part 2; built, needs `sql/zella_provisioning_retry.sql`). A draft with no change for 30 days (Operational rules, `draft_abandon_days`) shows as **Abandoned** and raises one alert; nothing is deleted automatically (BIZ-13b; built, needs the owner-provision-business deploy). A Zella Voice owner or super admin can **Delete draft** for a business that never finished setup: they type its name and give a reason; the database refuses a business that is live, active, in testing or ready, cancelled, has an accepted owner, team members, calls, phone numbers, billing, a delivered receptionist or offer history. Its uploaded documents are removed; its audit history stays (audit rows are never deleted with a business: ACC-10, the owner's decision), and the deletion's own audit record keeps its id and name (BIZ-13a, ACC-10; built, needs `sql/zella_draft_delete.sql` and the owner-provision-business deploy) | `businesses.manage` and the zella_owner or super_admin role to delete |
| Administration | **Settings, Data lifecycle** | How long a canceled business's records are kept (`retention_days`; labelled Pending legal review, since the architecture says 30 days and the database falls back to 90), every canceled business with its retention date and state, and a **Past their retention date** list. Read only: nothing is deleted automatically; a purge waits for the owner and legal (BIZ-13c; built, needs the owner-provision-business deploy) Whole business export: an admin requests it, a Zella Voice owner other than the requester approves, and it is downloadable for 7 days through signed links that end with it, for the person who asked or an owner; the Whole business export card lists exports with their state and progress. The business-export worker writes one JSON file per table plus the business's stored files and a manifest, resumes after an interruption, and leaves out secret tables and columns, recording links and sensitive industries' transcripts (SET-DL-EXPORT; built, needs `sql/zella_business_export.sql`, the business-export and owner-provision-business deploys; nothing runs until the owner turns the worker's timed call on) | `security.view` |

When the window is too short for the whole menu, its bottom fades and says "More below" above the Platform status
footer, until the list is scrolled to the end.

Platform roles use named permissions (`businesses.view/manage`, `telephony.manage`, `comms.manage`, `ai.configure`,
`integrations.manage`, `billing.view/manage`, `plans.manage`, `support.manage`, `security.view/manage`, `audit.view`,
`analytics.view`, `reports.view`). Only the Zella Voice owner manages platform admins. An admin alerts bell shows
platform alerts live. The Growth page (prospects and demos, REQ-ADM-18) and its `growth.manage` permission come
later, not before launch (owner, 16 Nov 2026).

**Weekly platform report** (Settings, Analytics and reporting, Reporting configuration; `reports.view`, which the
Zella Voice owner and super admins have; a restricted role only when the owner grants it): one summary of the whole
platform for each week, Monday to Sunday in UTC: new businesses, live businesses, calls, missed calls, texts sent and
received, open platform alerts, support tickets and failed automations, each with its definition, plus earlier weeks.
When a report is made every admin gets an alert in the bell that it is ready (no figures in it); the same alert goes in
the admin email digest once email is live. **Built, not applied** (`sql/zella_weekly_platform_report.sql`); it runs
only once the weekly job `zella_jobs_weekly` is switched on (the owner's switch, off in production). When the server
sends no answer the panel shows "Couldn't load this: The server didn't answer." with Try again; no report list reads as
"No weekly report yet".

When an owner removes an admin or changes their role, that person is signed out on every device, and Users & access
says how many devices were signed out (needs `sql/zella_admin_sessions.sql`, built, not applied). The change is saved
even if signing the devices out fails: the page then shows a warning that their devices could not be signed out, no
device count, and a Sign out everywhere button that tries again. Anyone can sign out
their other devices, and that is recorded in the audit log as "Signed out other devices" (through `zella_revoke_my_other_sessions`; before that function is applied, Supabase Auth signs the other devices out without an audit entry). Adding an admin and changing an admin's
role or access need an authenticator code entered in the last 5 minutes: Users & access asks for a new code and then
makes the change (only a fresh code, no second owner's approval). Changing what a restricted role may do (Platform
roles in Settings) gets the same check once that page's open changes have merged. An admin's own security changes in
Administrator profile > Account security go through the server and are audited: adding an authenticator ("Admin
added an authenticator app"), removing one ("Admin removed an authenticator app", with a new code, and never the last
one) and changing the password (with a new code; the password itself is never recorded). Business owners and staff
keep the same screens as before. Refused calls to the admin server (not an admin, two step sign in
missing, or a role without that permission) are recorded as "Refused admin request" with the address and browser, at
most 5 times per person and reason in 10 minutes, and listed on Users & access for the last 24 hours.

### 9.1 One business's page (`/businesses/<id>`)

Opened from Businesses. Each tab has its own address (`/businesses/<id>/people`, `/receptionist`, `/phone`,
`/automations`, `/calls`, `/activity`, `/configuration`; Overview is the plain address), so a reload or a link keeps
it. The tabs work with the keyboard (arrow keys, Home, End; one tab stop) and their edges fade on a phone when the row
scrolls (BIZ-30, UI-34). What each tab shows and what an admin can do there:

- **Header:** "Continue setup" is off while a suspended business's setup isn't finished; "Edit setup" on a live
  business asks first, because what is saved applies from its next call (BIZ-06, COM-04). A change whose audit row
  failed says so in the notice (BIZ-17).
- **Activity:** each row shows what changed, before and after; the tab is hidden without `audit.view`; a separate
  Support access list shows who opened the business or revealed contacts.
- **Activity (labels):** admin and system changes to this business, each with a readable label from the shared catalog
  (`web/supabase/functions/_shared/catalog.json`, read by `web/src/copy/auditActions.js`, BIZ-25). Changes the
  database records on its own name the table, for example "Changed business (system record)".
  Only admins with `audit.view` get it: the server leaves the list and who did each action out for anyone else
  (BIZ-04).
- **Overview cards:** the server's readiness ladder, the go live checklist (read only, `businesses.manage`), plan
  (price with `billing.view`), usage this period, phone numbers and open alerts (with a link to Platform operations)
  (BIZ-11, BIZ-12 phase 1). **People:** last sign in and two step columns with `businesses.manage` (UI-06).
  **AI receptionist:** call routing as the Voice page shows it, and what callers get: the settings the last call got
  against the next call's (UI-07, COM-03), and a **Languages** card: the business's plan and what it allows ("This plan
  includes 1 language. Move the business to a plan with Spanish first."), and with `businesses.manage` the main
  language, the other languages and the greeting, saved within the plan and audited (`receptionist.languages_changed`);
  the voice list below reloads after a save (built, not applied: `sql/zella_admin_languages.sql`). **Phone & integrations:** the numbers card with "Assign a number" for
  `telephony.manage`, the fallback number as the card's last row ("Fallback number: Not set" when empty), and honest
  wording for the connection records (UI-08).
- **Calls:** calls from the last 365 days (the tab says so), 25 a page, from the same masked list as Voice & numbers (`zella_admin_calls`), with no
  search box (a digit search could confirm a caller's number); the number column shows the business's own number
  when the called number wasn't recorded; "See all in Voice & numbers" (UI-10).
- **Actions on the page** (each in a dialog with a reason, each recorded): Show contact details (People), Cancel the
  owner's invitation and Resend (greyed for 5 minutes after one went out), Deactivate or Reactivate a member, Reset
  two step (with the identity check box), Pause and Resume an automation (`integrations.manage`; Resume only for a
  live business), Set up for an automation not set up yet, and Grant a pack (`billing.manage`, Overview). Most need
  the owner's approval before their server half is deployed.
- **Contact details:** caller numbers on Calls, people's emails, and the account email and error text of Live
  connections are masked the way the Voice page masks them (`…0123`, `a…@example.com`; `mask.ts`, the
  `zella_admin_mask` rule). A member's own phone number is not read. Showing them needs a reason (10 to 300
  characters) and `businesses.manage`, is recorded before anything is shown, and lasts for that response only. Each
  open of the page is recorded once per admin in 30 minutes; both appear under Support access, not Activity (BIZ-22;
  built, needs the owner's approval to deploy).
- **Setup while suspended:** finishing setup is refused for a suspended business before the owner's invitation is
  claimed or sent ("Reactivate it on the business page before finishing setup"); a suspension that lands while the
  invitation is going out wins, the workspace stays off and the finish says so (BIZ-06).
- **Modules:** the server refuses a module whose dependency is switched off for the business or isn't offered by its
  industry at all ("AI receptionist needs Calls, which this industry doesn't offer"); the list of dependencies lives
  in `module_deps.ts` and is sent with each module as `requires` (CFG-02).
- **Owner invitation:** Resend is refused for 5 minutes after an invitation actually went out ("It can be sent again
  in N minutes"), and two clicks at once send one email; a failed send can be retried at once. Cancel needs a reason:
  the link stops working, the invited seat is removed (so the same person can be invited again) and the audit row
  keeps the before and after status. If the email went out but the owner's seat couldn't be created, Resend says so
  and records it on the invitation (BIZ-21, BIZ-02; built, needs the owner's approval to deploy).
- **Member access:** an admin with `businesses.manage` can deactivate or reactivate one member's access to the
  business, with a reason; the business's only active owner can't be deactivated; the audit row keeps the status
  before and after (UI-06; built, needs the owner's approval to deploy).
- **Two step reset:** an admin with `businesses.manage` can remove a member's two step sign in after the identity
  check in `docs/ARCHITECTURE.md` (REQ-LC-19), with a reason; recorded first, never a Zella Voice admin's (UI-06;
  built, needs the owner's approval to deploy).
- **Packs:** an admin with `billing.manage` can grant one add on pack with a reason (not charged), as themselves, so
  the database checks their permission and records `billing.pack_granted`; a business with no current billing period
  is refused, never worked around (CFG-22; built, needs the owner's approval to deploy, and each real grant needs it
  too).
- **Business size:** Small, Medium, Large or not set, saved through the admin function (`business_size_save`,
  `businesses.manage`, two step sign in checked) with the before and after in the audit log; a change made by someone
  else meanwhile is refused (BIZ-08).
- **Automations:** every standard automation and industry rule, with one status language shared with the Automations
  page: Active, Paused, Turned off (`AUTOMATION_STATUS` in `web/src/automationCatalog.js`, OPS-22). Names always start
  with a capital (UI-09).
  One rule for when an automation runs (BIZ-07, `live.ts`): a business is live when it went live and is neither
  suspended nor cancelled. Once the owner turns on `ZELLA_AUTOMATIONS_START_ON_SAVE`, an automation turned on for a live
  business starts at once; one turned on while it is suspended starts again when it is reactivated; before go live it
  waits and starts at go live. Until the switch is on, saving behaves as before (built, off).

---

### 9.1 Connected, answering and live (one definition)

Overview, AI agents, Integrations and the operations health count all read the same definition, from the database
(`zella_business_connections` and `zella_connection_counts`, `sql/zella_connection_state.sql`, built, not applied). Before it,
each page worked it out from the integrations table, which only the store connection writes, so the four pages gave
four answers about the same business (COM-01, OPS-07, UI-02).

| State | Means |
|---|---|
| Phone | The business has an active phone number (`business_phone_numbers`) |
| Voice linked | An active number has its Vapi number id |
| Answering | Zella Voice served the receptionist for a call to this business in the last 7 days (`assistant_deliveries`, outcome served). Shown on its own, never folded into Live: it can honestly be 0 until the numbers send their calls through voice-rules (a provider change that needs the owner's approval) |
| Calendar | An active Google or Outlook calendar connection |
| Leads | An enabled website form, a connected Meta account or an enabled Google lead key |
| Email | Not tracked: there is no mailbox connection to check, so no page says connected or not connected |
| Needs attention | Integrations in error or disconnected, calendars in error or disconnected, Meta accounts that need reconnecting |
| Live | The business is active (setup finished, switched on, not suspended or cancelled), its receptionist is switched on, and it has an active number linked to Vapi |

**Defaults taken (owner can change):** the 7 day answering window (`ANSWERING_DAYS` in the SQL); Live needs the
receptionist switched on and a number linked to Vapi, but not a recent answered call; a suspended or cancelled business
is never live. The real values in production still need an owner approved read only count.

## 10. Messaging and follow-ups

Every outbound message passes the same path: consent check, template, safe content, log, duplicate protection, the
live switch, then the provider. Off means dry run: the message is logged as "would have sent" and nothing leaves.

| Feature | Status |
|---|---|
| Appointment confirmations and reminders by text (Telnyx) | Built, off (`sms_live`) |
| Appointment confirmations and reminders by email (Resend) | Built, off (`email_live`) |
| Follow-ups: no-show, thank-you, quote follow-up, reactivation (opted-in only), callback fallback, missed-call text, lead acknowledgement | Built, off |
| Text ↔ email switching when one channel can't reach the person | Built |
| "You might also need": after a service is completed, suggest a related service some days later (rules per business in Settings; marketing, so only to customers who opted in; one per appointment, the same rule at most once per customer every 90 days; `sql/zella_cross_sell.sql`). Chosen by the owner on 28 Oct 2026 | Built, off |
| Owner emails: daily summary, weekly review, warnings and urgent alerts, every kind on by default (there is no notification preferences page, owner, 28 Oct 2026) | Built, off |
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
| Plans, prices and allowances | **Database applied to production on 14 Nov 2026** with the owner's approval; screens and enforcement still to come (`sql/zella_billing_allowances.sql`, step 2 of the billing build; policy: 12 Nov 2026, D-34, D-41): each business's own plan (`business_plans`), versioned, set only by a billing admin (`billing.manage`) with an audit record: the label (**Base** or **Pro**), price, setup fee, minutes, texts, emails, seats, numbers, locations, languages and trial; no preset prices or values. Monthly balances (`allowance_buckets`) with the 5-day trial (20 minutes, 5 texts, 5 emails), unused minutes rolled over for one month, capped at 20% of the plan's minutes and 20% of each minutes pack's size (D-42), a 5% buffer for appointment messages (D-43), and yearly plans reset monthly (D-46). Seats, numbers and languages are checked against the business's own plan. Tested on the isolated database, then checked in production by read only fingerprints. |
| Add-on packs | **Prices in the database, not applied** (`billing_pack_catalog`); a billing admin can grant a pack with a reason (audited, not charged); buying one needs payments (step 4): minutes $29/100, $89/250, $149/500, $269/1,000; texts $18/500, $34/1,000, $80/2,500, $150/5,000; emails $25/10,000, $59/25,000, $115/50,000; extra location $30/month; extra user $10/month |
| Billing & Subscription page for owners (plan, usage, packs, auto-reload, invoices, cancel, refund request with server-side eligibility) | **Plan, usage, balances, packs and auto-reload built on the branch (not deployed)**: Settings > Billing and subscription > Current plan (price, allowances, usage bars for minutes, texts and emails with the reminder buffer, days left), Balances and packs (each balance with its expiry, the rollover rule, pack prices and how much of each could roll over), Auto-reload (owner only; saved, not active until payments; a minutes, texts or emails line with no packs on offer shows a short note instead of the form). Owner only, enforced by the database; staff see "Billing is for the business owner". Invoices, payment method, buying packs, cancel and refunds need payments (step 4) (architecture §17, REQ-BIL-05, REQ-BIL-45) |
| Plan page safeguards in Create Business: profit warning with estimated cost and margin, sensible-limit warnings (e.g. over 10,000 minutes, $0 price), review screen with audit before the invite | Database checks built, not applied (`zella_plan_evaluate`, `zella_admin_plan_save`: a warning needs a written reason; unit costs for texts, emails, numbers and registration are a platform setting the owner fills in, and are reported as missing until then); the **Plan & pricing** step of Create Business is built on the branch (not deployed): every value typed by hand, a live profit check from the database, red warnings, a review dialog that needs a reason for each warning, saved versions; finishing setup is refused by the server until a plan is saved (architecture §17.1a, REQ-BIL-55–57) |
| Stripe checkout, trial auto-charge, auto-reload, pay as you go and refunds | Checkout, the saved card trial, renewals, failed payment notices, the 5 day pause, packs and auto reload (server side), refund requests approved by the Zella Voice owner (server side), cancel and continue synced to Stripe, invoices recorded and shown to admins on Plans & subscriptions (Payments: invoices, refunds, disputes), chargebacks that suspend the account while open, billing emails queued in the platform outbox (held while email_live is off), daily reconciliation with Stripe, upgrades (owner confirms Stripe's prorated amount) and downgrades at the period end built switched off (lane F); pay as you go charging is not built: until payments are switched on the Pay step says payment opens soon and the owner can continue, and going live doesn't wait for a payment (owner, 16 Nov 2026); once on, the owner onboarding Pay screen opens Stripe Checkout for the accepted plan and shows Payment received only after a verified, bound payment. Otherwise not built; needs the owner's approval to take real payments, and the Stripe account check in D-51. Integration reference written from Stripe's documentation (`docs/PAYMENTS_ARCHITECTURE.md` §16): Stripe charges the saved card for auto-reload and adds pay as you go to the renewal invoice |
| Usage ledger: one append-only entry per finalised call; our failures are never billable | Built |
| Usage limits that act (REQ-BIL-22, D-43): at 100% a new call is forwarded to the business's own number (pay as you go with a rate keeps answering; a call in progress is never cut; never dropped without a number) and routine texts and emails stop while appointment messages use the 5% reserve. Two switches, both off until the owner approves | Built and applied 15 Nov 2026 (`sql/zella_usage_enforcement.sql`; voice-rules v8 deployed); both switches off until a staging call on a demo business proves the forward |
| Minutes run out, owner decisions of 18 Nov 2026 (security audit M12): with the calls switch on, auto reload (or auto top up) keeps answering only while a reload can still happen (payments live, an active subscription, the pack sold, the month's reload spend within the owner's cap); pay as you go keeps answering with an overage price on the plan in force; otherwise, and when the allowance is unknown, the call is forwarded to the business's own number, or the caller hears "Sorry, we can't take your call right now. Please try again later." and the call ends. Owners get a reminder to buy minutes or turn on auto reload at most every 6 hours (in app; email once email is live); an unknown allowance alerts Zella Voice. Each business also has a limit on calls at the same time (10 unless set per business), whatever the switch | Built, not applied (`sql/zella_call_limits.sql`, voice-rules closed message). Turn the calls switch on only once every live business has an allowance set up: an unknown allowance now closes calls |
| Fallback number at Create Business (REQ-BIL-34): required on Phone & integrations, saved in E.164, copied into the receptionist's rules (`escalation_rules.fallback_number`; an admin's number from call routing is never replaced), and Finish setup is refused without it. Usage limits forward to it, never to the business's own phone, which may be the number that forwards to Zella Voice | Built (needs the owner-provision-business deploy and the usage limits migration) |
| Live usage on Today for owners: rings for minutes, texts and emails, refreshed every minute, on focus and as soon as an 80% or 100% notice arrives, with banners in the notification style. The owner's rule (14 Nov 2026, REQ-BIL-05) is that usage updates within seconds of a call ending or a message being sent | Built; the within seconds update is not built yet (it refreshes every minute) |
| Usage counting and alerts | Calls (whole minutes, under 15 seconds and spam not counted), texts (by part) and emails (one each) are subtracted once from the balances, with alerts at **80% and 100%** for minutes, texts and emails: built, not applied. A live call is never cut. **Not switched on** (live changes needing the owner's approval): calls going to the fallback number at 100%, stopping routine texts and emails at 100%, and the 20-minute call cap (the live setting is 10 minutes today) |
| Voice cost estimates per business | Built |
| Payment provider webhook: signed, applied once and in order, never moves a subscription backwards | Built, off until the webhook secret is set |
| Scheduled cancellation and "Continue my plan" link | Built. When the date passes, the business is fully cancelled (AI receptionist and automations off, subscription cancelled, audited) by the hourly and daily jobs once `sql/zella_cancellations_scheduled.sql` is applied and the timed jobs are on (both pending the owner); until then it happens when an admin opens Overview or Businesses (BIZ-03) |
| Offers and promotions | Built |
| Card data | Never stored (`NN-9`) |

---

## 14. Calendar and integrations

| Integration | What it does | Status |
|---|---|---|
| Google Calendar, Outlook | Two-way: busy times block booking; Zella Voice bookings appear in the calendar. The sign in is single use, valid 5 minutes, and finished in the app by the person who started it (`sql/zella_oauth_states.sql`, not applied) | Built, off (`calendar_sync_live`) |
| Shopify | Order status for the receptionist, read-only scopes | Built |
| Google Ads lead forms | Leads into the CRM | Built |
| Meta (Facebook, Instagram, WhatsApp) | Leads and messages | Built, off |
| Website crawler | Reads the business's website for knowledge suggestions. Pages are read by the `website-fetch` edge function, which resolves the name and refuses private, loopback, link local, metadata and CGNAT addresses before it connects; wildcard DNS names such as nip.io are refused | Built, off (`website_crawl_live`); the new reader is not deployed |
| Vapi | Voice calls | Built; real-call authentication open |
| Telnyx | Texts and phone numbers | Built, off |
| Resend | Email | Built, off |
| Payment provider webhook (Stripe signatures) | Billing | Built, off. The provider is **Stripe** (D-34, Zella Voice is a Wyoming LLC). Rebuilt to the design (lane F, not deployed): `billing-webhook` checks the signature and the key's mode and only stores the event; `billing-worker` fetches each object from Stripe and the database applies it after the binding check, quarantining anything it can't bind. Off until the owner adds the keys and turns `payments_live` on (`docs/PAYMENTS_ARCHITECTURE.md` §16.7) |

Every provider request sits behind an explicit setting. Tokens and keys live in Supabase Vault or edge function
secrets, never in tables, code, logs or chat (`NN-2`).

---

## 15. Notifications

| Feature | Status |
|---|---|
| In-app notifications with plain wording and icons | Built |
| Live pop-ups for urgent events | Built |
| No notification preferences page (owner, 28 Oct 2026): pop ups, desktop notifications and urgent texts are built and on by default; the one personal switch is Notification sound (Settings, Appearance). Urgent texts are always on for team members: a member can't switch them off, only the business owner changes who receives them (owner, 25 Nov 2026) | Built; the owner's choice of who receives urgent texts is not built yet |
| Celebrations for milestones (first call answered, first booking) | Built |
| On-call and scorecard nudges | Built |
| Business moments: a record day for bookings, a surge in calls, and gaps in the coming weekend's on call cover | Built and applied 15 Nov 2026 (`sql/zella_business_moments.sql`) |
| Five notification tones with a short label (Record, New lead, Still answering, On call, Urgent), worded in each industry's terms, no emoji | Built |
| Admin alerts bell | Built |
| Push notifications for the installed web app | Planned (D-40) |
| Emails from Zella Voice to businesses: 92 emails (account and setup, sign in, summaries, alerts, usage, service, billing) in one catalogue and layout, with an admin preview (Admin, Messaging, Emails to businesses). The outbox there filters by business, status and email; a row opens the email itself (sandboxed preview and plain text, each view audited), and an email held after 5 failed tries can be released (back in the queue, tries reset) or discarded (shown as Discarded) with a reason, under `comms.manage`, which also closes its held alert (COM-18, COM-22) | Built; sending not connected (`docs/BUSINESS_EMAILS.md`); release, discard and the drawer need `sql/zella_platform_email_actions.sql` (built, not applied) |
| Platform outbox for those emails: sent once per key, test mode while email sending is off, retries then held for a person | Built and applied 15 Nov 2026 (`sql/zella_platform_emails.sql`); empty until delivery is set up, email sending off |
| Email delivery for notifications (summaries, warnings, urgent alerts): written from the catalogue, queued once per person, sent through Resend by the `platform-emails` edge function, which the database wakes only when there is work; replaces the n8n Owner Emails path | Built, not applied or deployed (`sql/zella_email_delivery.sql`, `platform-emails`); sending also needs `email_live`, a sender address and the Resend key |

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
| Retention: recordings and transcripts 90 days, deleted automatically (owner, 18 Nov 2026; `sql/zella_privacy_retention.sql`, built, not applied: the daily job does nothing until the purge switch is on and the period is legally approved, and the copies at Vapi are queued for deletion, sent only once `vapi_deletion_live` is on), earlier proposal recordings 30 days, transcripts 90 days, message bodies 2 years, audit and security logs 7 years, cancelled business 30 days (D-27, pending legal review) | Partial: built, not deployed: each period stored separately (also replaced verification copies 30 days, owner identity files 90 days after verification, a cancelled business's documents 30 days), each "pending legal review" until a Zella Voice owner records otherwise; legal holds (security.manage places, only an owner releases); a dry run per kind lists what is past its period without deleting anything (Settings, Security and privacy > Data retention). The purge switch `retention_purge_enabled` is off and no job is scheduled. Purge runs (built, not deployed): security.manage asks for a run of exactly the rows the dry run lists (at most 1000), two different people approve it (one a Zella Voice owner), and one of them runs it with "PURGE <rows>" typed, only while the switch is on and the period is legally approved; recordings and message words are removed from their rows, transcripts are replaced by "Removed under the retention policy.", old audit rows are deleted, verification files are removed from storage and recorded; every step audited |
| Public status page and uptime alerts | Built |
| Consent capture per lead source for AI calls and automated texts | Decision open with counsel (D-04) |

---

## 17. Not built yet, or waiting on a decision

| Item | Waiting on |
|---|---|
| Self-service sign-up | Later phase (D-06) |
| Owner onboarding: Stripe Checkout and the payment webhook (step 6), the identity provider's live connection (step 4) | Build after the owner sets up the Stripe and Persona accounts; the gates and the receiver are built (`sql/zella_owner_onboarding.sql`) |
| Billing build (plans in the database, usage rules, Billing & Subscription page, Stripe) | Build, in steps (architecture §17); open billing decisions D-45 to D-51 |
| Two-way AI messaging | Build (architecture §14.3) |
| Voicemails page, AI agents beyond the receptionist, marketing campaigns | Build; hidden from the sidebar until they exist |
| Meta channels in launch scope | Owner and counsel (D-39) |
| Calendar providers at launch | Owner (D-08) |
| Push notification provider | Owner (D-40) |
| Self check-in | Later (D-15) |
| Call recording | Legal review (D-13) |
| Automatic deletion at end of retention | Built, not deployed, off: nothing is automatic. Purge runs approved by two people (Data retention), including a whole canceled business past its retention date (after a recorded final export offer at least 14 days old, refused while it has billing records, offer history or phone numbers, or while deleting would erase its audit history). Waits for legal review |

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
8. CodeRabbit has reviewed it, and the owner merged it or told Claude to merge it once the review was clean and the
   tests passed (`NN-5`).
