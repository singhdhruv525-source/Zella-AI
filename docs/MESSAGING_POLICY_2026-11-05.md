# Customer messaging policy around bookings and visits: for approval (5 Nov 2026)

Status: **proposed, not applied.** `sql/zella_message_courtesy.sql` implements it and has not been run on production. Texting
(`sms_live`) and email (`email_live`) stay off, so nothing here sends anything until you approve both the migration and
switching sending on. Nothing here is a statement of legal or regulatory compliance. Telecom, healthcare, legal and financial
rules on messaging need your own review.

## 1. The messages, and when each is timed from

| Message | Timed from | When | Who switches it on | Quiet hours |
|---|---|---|---|---|
| Booking confirmation | the **booking** being made | at once | the `appointment_confirmation` automation | **none** (answers the customer's own action) |
| Reminders | the **appointment start** | 24 h and 2 h before (the automation's settings) | `appointment_reminder` automation | **none today**: see decision D3 |
| Welcome text | the **customer record** being created (not imports, manual entries or bookings) | 10 min after | always, subject to this policy | 09:00–19:00 business time |
| "You are booked for …" follow-up | the **booking** | 1 h after; only for bookings more than 2 days ahead | always, subject to this policy | 09:00–19:00 |
| Reschedule confirmation | the **booking being moved** | 1 min after | always | 09:00–19:00 |
| Cancellation confirmation | the **booking being cancelled** (if it hadn't started) | 1 min after | always | 09:00–19:00 |
| Feedback request ("How did it go?") | the visit being **marked completed** | 3 h after | always, subject to this policy | 09:00–19:00 |
| Post-visit follow-up | the visit being **marked completed** | 2, 24 or 72 h after (the automation's setting) | `post_appointment_follow_up` automation | moved into 09:00–19:00 |
| Aftercare / "thanks for visiting" | the **appointment start**, if it was marked completed | 1 day after (preset), checked by the scheduler within a 2-day window | industry preset automation | 09:00–19:00 |
| Review request (day 2) | the **appointment start**, if it was marked completed | 2 days after (the "Review request" preset) | preset automation, **and only if the business has a review link** | 09:00–19:00 |
| Job-completed note | a job record moving to its completed status | 5 min after | industry record rules | 09:00–19:00 |

"Business time" is the business's own time zone (`businesses.timezone`; New York if unset). A follow-up that falls outside
09:00–19:00 is moved to the next 09:00, not dropped.

## 2. Rules that apply to every industry (unchanged by this proposal)

- **Consent and opt-out:** every text goes through `zella_prepare_sms` → `zella_can_contact`. Do-not-contact, do-not-text
  and do-not-email, and STOP replies, are honoured. A held-back text is recorded as skipped with the reason. Marketing
  texts (`lead_reactivation`, `cross_sell`) also need the platform's `sms_marketing_allowed` switch (off unless set).
- **Channel:** email if the customer prefers email and has a valid address; otherwise text if they have a number and
  haven't opted out; otherwise email. The AI receptionist now saves "text me" / "email me" (`zella_ai_caller_fixes.sql`).
- **Dry run while sending is off:** the exact text is recorded and nothing is sent.
- **Duplicates:** the same message isn't queued twice for the same customer and booking within its window (e.g. a feedback
  request once per visit, a welcome once in ten years).

## 3. What this proposal adds

1. **Policy per industry, owner-adjustable.** The defaults are in the table below, stored in `industry_message_policy`.
   An owner or admin can change their own business's settings (`zella_set_message_policy`), and every change is audited.
   Staff can't change them, and nobody can read another business's settings.
2. **One after-visit check-in** (where the policy says `one`): only one of feedback request, post-visit follow-up,
   job-completed note and "thanks for visiting" within 36 h. Review requests are not check-ins; their own setting governs them.
3. **No repeat booking text:** the "you are booked" follow-up is held back when the business sends booking confirmations.
4. **The confirmation replaces a pending welcome** (where the policy says `until_booked`).
5. **Cancellation and rescheduling:**
   - A cancelled or no-show booking withdraws its own pending booking follow-up, feedback request, post-visit follow-up and reschedule confirmation.
   - A moved booking withdraws the stale "you are booked for <old time>" follow-up; the reschedule confirmation carries the new time.
   - Reminders were already withdrawn on cancellation. The cancellation confirmation and no-show follow-up are untouched.
6. **Nothing is silently dropped.** A held-back message is stored as `skipped` with the reason ("The booking confirmation
   already says this.", "They already had an after-visit check-in.", "Review requests are off for this business.").
7. **Never held back by the policy:** replies to the customer, confirmations, reminders, reschedule and cancellation
   confirmations, and status updates on their records (e.g. "your repair is ready").

## 4. Proposed defaults by industry

Settings: welcome (`until_booked` / on / off), booking follow-up (`skip_if_confirmations` / on / off), feedback request,
review request, after-visit (`one` per 36 h / all).

| Industry | Welcome | Booking follow-up | Feedback | Review request | After-visit | Why |
|---|---|---|---|---|---|---|
| Beauty & Salon | until booked | skip if confirmations | on | on | one | the validated salon flow |
| Spa & Wellness, Fitness, Pet Care, Photography & Events, Hospitality, Travel, Education, Professional Services, Real Estate, Other | until booked | skip if confirmations | on | on | one | standard |
| Cleaning, HVAC, Plumbing, Electrical, Landscaping, Pest Control, Home Services, Automotive | until booked | skip if confirmations | on | on | one | the job-completed note counts as the check-in, so no second "how did it go?" |
| Restaurant | **off** | skip if confirmations | on | on | one | guests booking a table don't expect "we'll be in touch" |
| E-commerce | **off** | skip if confirmations | on | on | one | shoppers aren't booked; new bookings are refused for e-commerce |
| Property Management | until booked | skip if confirmations | on | **off** | one | tenants and owners are under contract; manager's choice |
| Childcare | until booked | skip if confirmations | on | **off** | one | messages go to parents about their children; owner's choice |
| Healthcare, Dental | **off** | skip if confirmations | **off** | **off** | one | a text can reveal that someone is a patient |
| Legal | **off** | skip if confirmations | **off** | **off** | one | a text can reveal that someone is a client |
| Financial Services, Insurance | **off** | skip if confirmations | **off** | **off** | one | a text can reveal a client relationship, policy or claim; review solicitation may be restricted |

Confirmations, reminders, reschedule and cancellation confirmations stay on in every industry. They are governed by each
business's own automations and the consent rules above.

## 5. Decisions needed from you

- **D1. Approve the defaults above**, or change any row.
- **D2. Review requests: transactional or marketing?** Today they're classed as transactional, so they need no
  marketing consent. Classing them as marketing would require the customer's marketing consent and the platform's
  marketing switch. Recommendation: get legal advice before sending review requests in any industry.
- **D3. Quiet hours for reminders.** Reminders have no quiet window: the 2-hour reminder for an 8:30 appointment goes at
  6:30. Options:
  - (a) keep as is;
  - (b) move reminders into 08:00–20:00 business time and send earlier rather than later;
  - (c) per-industry windows.

  Not implemented until you choose.
- **D4. Text content in sensitive industries.** Confirmations and reminders name the business and the service ("your
  Root canal with Smile Dental"). Healthcare, dental, legal, financial and insurance businesses may want templates that leave
  the service out. That's a template change, not yet made.
- **D5. Where owners change these settings.** The database function and permissions exist; there's no settings screen yet.

## 6. Evidence

- `tests/security/caller_and_courtesy_test.sql`:
  - salon: one check-in, the review request goes;
  - dental: nothing after a visit, all three held back with reasons, the cancellation confirmation still goes;
  - plumbing: the job note is the check-in;
  - moved and cancelled bookings withdraw their follow-ups;
  - only owners can change settings, invalid values are refused, changes are audited, staff and other businesses can't read or change them.
- `tests/workflows/salon_launch.mjs` (all passed): Maria gets the confirmation, two reminders and one check-in; the repeat
  booking text and the second check-in are on record as skipped with reasons.
- `tests/staging/run.sh` (all passed): applies to the 32 staging businesses. Rollback drops the defaults table, keeps owners'
  choices, and keeps held-back messages on record.
