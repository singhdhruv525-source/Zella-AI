# Zella Voice: product voice and microcopy conventions

How Zella Voice talks inside the product: the business app (CRM, `/app`), the Zella admin dashboard (`/`) and the
public pages (reschedule, waitlist, status, unsubscribe). Marketing copy is out of scope.

## Voice

Zella sounds like a calm, capable office manager who has done this for years:

- **Clear before clever.** The shortest wording that is fully correct wins.
- **Plain English.** "Text message", not "SMS payload". "Couldn't reach Zella", not "Network error".
- **Honest about state.** Never say something happened unless the system knows it happened ("Sent" is not
  "Delivered"; "Queued" is not "Sent"; a retry is "queued", not "sent").
- **Calm with problems.** Say what happened, what it means and what to do next. No blame, no alarm, no "Oops".
- **Warm, not cute.** Friendly sentences are welcome in notifications and empty states (see `src/zellaVoice.js`).
  Operational screens stay plain.

Avoid: robotic phrasing ("Operation completed successfully"), exclamation marks on operational screens, hype
("supercharge", "seamless"), vague verbs ("Submit", "Process", "Handle"), internal names (table, function or
provider error codes).

## Grammar and spelling

- American English: color, customize, license, canceled/canceling (but "cancellation"), program, recognize,
  summarize, anymore (= no longer), driver's license.
- Contractions are fine and preferred in sentences ("can't", "isn't", "you'll").
- The serial comma is not used in UI text (existing convention): "calls, texts and emails".
- Numbers: digits for counts and times ("3 missed calls", "7 days"). Phone numbers in E.164 with an example
  ("+15551234567").
- Time words: "in the last 7 days", "2 h ago", "Due tomorrow 9:00 AM". Times use the business's time zone.

## Capitalization

- **Sentence case** for navigation, page titles, section headings, buttons, tabs, filters, column headers, badges
  and labels: "Calls & messages", "Sending failed", "Retry sending", "Needs a person".
- **Proper nouns keep their capitals:** Zella Voice, Google Calendar, Vapi, Telnyx, Resend, Stripe, ElevenLabs.
- **Feature names:** "AI Receptionist" is the name of the module in navigation; in running text it is "your AI
  receptionist".
- Acronyms stay in capitals inside labels: AI, SMS, CRM, ID, URL, MFA.
- Badges (`.ba-pill`) are no longer force-capitalized by CSS; the text is written in sentence case.

## Terminology (business app)

| Concept | Use | Don't use |
|---|---|---|
| A person who contacts the business | the industry's word (`term("customers")`: Clients, Patients, Guests, Customers) | contact record, entity |
| Booked time | the industry's word (`term("appointment")`: Booking, Appointment, Reservation, Service call) | slot, event |
| Creating one | "New booking" / "New appointment" (`New ${term("appointment")}`) | "Book booking" |
| SMS | "text" / "text message" | SMS (except settings that name the provider channel) |
| A call the receptionist couldn't resolve | "Needs a person" | needs a human, human handover, escalation |
| A call result | Answered, Missed, Didn't connect, In progress | Answered (for anything not missed) |
| A message that failed | "Sending failed" (a send attempt failed) | Didn't send |
| AI involvement | "Handled by AI", "AI answered", "Suggested by AI" | AI handled, automated (when a person approved it) |
| Messages waiting for approval | "Suggested messages" | drafts (in navigation) |

Industry words come from the business's terminology (`makeTerm`, `crm_record_types`, `industry_modules`).
Navigation stays the same for every industry; only the words for people, bookings, staff and operations change.

## Microcopy patterns

**Buttons** name the action and, when not obvious, the object: "Save changes", "Retry sending", "Schedule callback",
"Mark followed up", "Connect Google Calendar". Destructive actions say what is lost ("Remove from workspace").

**Success messages** state the confirmed result in past tense, only after the server confirmed it: "Callback
scheduled.", "Outcome saved.", "Queued to send again. It goes out on the next sending run." A change the server
refused is reported as a refusal (`changed()` in `BusinessShared.jsx`), never as saved.

**Errors** answer three questions: what happened, whether anything was saved, what to do next.
- Known server codes map to sentences (`CODES` in `BusinessShared.jsx`, `ERRORS` in `admin/adminOps.jsx`).
- Network failures: "Couldn't reach Zella. Check your internet connection and try again."
- An unknown code is never shown alone: "That didn't work (code X). Try again, or contact Zella support if it keeps
  happening."
- Never show SQL, stack traces, provider credentials or internal IDs to business users.

**Empty states** say what is empty and what happens next, without implying a problem: "No calls yet. Calls appear
here once your phone line is live." Filtered views: "No calls match. Try another filter."

**Loading**: "Loading…" (with the ellipsis character).

**Statuses**: one label per internal value, defined in `src/copy/labels.js` and documented in
`docs/ZELLA_STATUS_LANGUAGE_GUIDE.md`. Screens that need a context-specific label (for example a reminder's outcome)
choose it locally and must stay consistent with the guide.

## Where copy lives

- `src/copy/labels.js`: labels for internal values (`humanize`) and call results (`callResult`, `isAnswered`).
- `src/navigation/navConfig.js`: business navigation labels.
- `src/BusinessShared.jsx` `CODES` / `friendly`; `src/admin/adminOps.jsx` `ERRORS` / `friendlyError`: error wording.
- `src/zellaVoice.js`: warm notification and celebration lines, by industry.
- `src/onboardingConfig.js`: industry onboarding fields and hints.
- Page copy stays inside each page component (no translation framework; English only).
