# Zella Voice: copy changelog

## 25 November 2026: CRM Today page polish

Owner approved, 25 Nov 2026 (architecture §23.1d). Frontend wording only.

| Where | Before | After | Change |
|---|---|---|---|
| Today, title | "Good morning, Rosa!" (a greeting with the first name) | "Today" (another day: its date, for example "Thursday, November 26") | 1 |
| Today, lines under the title | "Here's what's happening at The Olive Table today." | "Wednesday, November 25", then "The Olive Table" on a second, quieter line (another day: the business name only) | 2 |
| Today, walk in button | "walk in" | "Walk in" | 3 |
| Sidebar | "check ins" | "Check ins" | 3 |
| Today, card | "Tasks & follow ups" | "Tasks and follow ups" | 4 |
| Today, card | "Reviews & feedback" | "Reviews and feedback" | 4 |
| Header search, placeholder | "Search guests (press Enter)" | "Search guests" (the industry's word) | 5 |
| Today, bookings table, empty Table or staff cell | "None" | "Not set" | 6 |
| Today, bookings table, empty Guests cell | "None" | left blank | 6 |
| Sidebar section names | "WORKSPACE", "CRM", "RESTAURANT OPERATIONS" (spaced capitals by style) | "Workspace", "CRM", "Restaurant operations" (sentence case) | 19 |

Change 2 was revised by the owner on 25 Nov 2026, before merge: the first version read "Wednesday, November 25 · The
Olive Table" on one line. A meta line joined with a middle dot ("A · B") reads as a generic template tell, so the date
and the business name now sit on two lines, the name quieter.

## 25 November 2026: wording bugs found by the page audits

Approved by the owner on 25 Nov 2026 (A41, C33, C36, C39, C45). Details: the admin and CRM page audits.

| Where | Before | After | Item |
|---|---|---|---|
| Record lists, count under the table | "4 event or catering enquirys" | each kind's own plural word, as stored in its setup: "4 events and catering" for the restaurant preset (customer lists too) | C33 |
| Spam protection, incidents per day chart | "11-23" | "Nov 23" | C36 |
| Reports, Checked in | "1 arrivals" | "1 arrival" (and "1 no show" under No show rate) | C39 |
| Settings, Industry profile, Modules switched on | "Ai-receptionist, Automations, Calendar, Calls" | "AI receptionist, Automations, Calendar, Calls" | C45 |
| Admin, Industry configuration, failed or empty load | "Cannot read properties of undefined (reading '0')", "Couldn't load the industries. Reload the page to try again." and "Industries didn't load." | "Industries didn't load." with a Try again button | A41 (A40 wording) |
| Admin Settings, Reporting configuration, empty answer | the page crashed | "Couldn't load this: The server didn't answer." with Try again | S62 |
| Settings, Billing, Auto reload, a resource with no packs | the page crashed when the list was missing | "No packs of texts are on offer right now, so there is nothing to reload with. Ask Zella Voice support." (per resource) | CRM audit, section 4 |

## 25 November 2026: admin pages polish

Admin dashboard only (owner approved, `docs/DESIGN_SYSTEM.md` "Admin pages polish").

| Where | Before | After | Why |
|---|---|---|---|
| Admin buttons (Refresh, New ticket, New offer, Add admin, Back, Close, wizard Back and Continue, ticks) | "↻ Refresh", "＋ New ticket", "← Businesses", "×", "✓", "Save & continue →" | Same words with real icons | Typed symbols replaced by the icon set |
| Business, Phone & integrations | "Fallback number, where calls go when the AI receptionist can't take them: not set." under the card | "Fallback number: Not set" as the Phone numbers card's last row, with "Where calls go when the AI receptionist can't take them" under it | One place for the numbers |
| Audit logs, an opened entry | The raw before and after records | What changed, in words (field, before, after; "No field changed in this entry." when nothing did), the raw record under "Show raw record" | Readable first |
| Integrations, requests table | "✓ Website" | "Website" with a green dot | No typed ticks |

## 25 November 2026: admin dashboard polish

Admin dashboard only (owner approved, `docs/DESIGN_SYSTEM.md` "Admin polish"). No words added or removed.

| Where | Before | After | Why |
|---|---|---|---|
| Admin sidebar group labels | BUSINESSES, CONFIGURATION, AI & COMMUNICATIONS, OPERATIONS, ADMINISTRATION (spaced capitals) | Businesses, Configuration, AI & communications, Operations, Administration | Sentence case, as written |
| Line above the page title | PLATFORM CONTROL CENTER (and every admin page's eyebrow) | Platform control center | Sentence case |
| Admin sidebar scroll cue | MORE BELOW | More below | Sentence case |
| Overview panel captions | "Problems that block a client from going live." and the four others | No full stop at the end | A caption is a label, not a sentence; empty state sentences keep theirs |
| Top bar search hint | "Search businesses..." | "Search businesses" | No trailing dots |
| Overview counts | 3182, 2847 handled by AI | 3,182, 2,847 handled by AI | Thousands separator |
| Overview buttons | "↻ Refresh", "＋ Create business", "＋ Create your first business" | Same words with real icons | Typed symbols replaced by the icon set |

## 30 October 2026: product language pass

Frontend wording only (`web/src`). Internal values, routes, permissions and backend behavior are unchanged, except
where a label and its calculation disagreed (call results; see below). Details and evidence:
`docs/ZELLA_UX_COPY_AUDIT.md`.

### Calls and messages

| Where | Before | After | Why |
|---|---|---|---|
| Call result (Calls, call details, Inbox, profile, leads, booking panel, Today) | "Answered" for every call that wasn't missed | Answered / Missed / Didn't connect / In progress | Failed and ringing calls were shown as answered |
| Calls filter | "Answered" (included failed calls) | "Answered" (answered or completed only) | The filter matches its name |
| Reports | answered count included failed and in-progress calls | answered or completed only | The metric matches its label |
| Sidebar, page | "Didn't send" / "Messages that didn't send" | "Sending failed" | Matches the backend state: a send attempt failed |
| Sending failed, button | "Try again" | "Retry sending" | Names the action |
| Sending failed, empty | "Nothing has failed. Messages and reminders are going out as expected." | "No failed messages. Nothing failed to send in the last 7 days." | The page can't confirm that sending works |
| Sending failed, toast | "Queued to send again." | "…It goes out on the next sending run." | Says what happens next |
| Retry refused | "This can't be retried any more." | Gives the reason (already retried, or appointment passed) | Actionable |
| Test-mode reasons | "Dry run no provider" | "Not sent (test mode: no provider connected)" | No internal codes |
| Sidebar | "Conversations" (page titled "Unified inbox") | "Inbox" (page "Inbox") | One name for one page |
| Messages | "Sms", "sms conversation", raw "open" | "Text message", "Open" | No internal values |
| Escalations | "Needs a human", "Human handover" | "Needs a person" | One term |
| Calls filter | "AI handled" | "Handled by AI" | Reads naturally |

### Navigation

- Sentence case: Calls & messages, Tasks & follow-ups, Reports & analytics, Team & staff, Business growth,
  AI & automation (sidebar and breadcrumbs).
- Breadcrumbs now match the sidebar:
  - Calls & messages / Calls;
  - AI Receptionist / Transcripts;
  - AI & automation / Knowledge base;
  - CRM / Leads (and the industry's customers);
  - Calls & messages / Inbox.
- "Customise records" → "Customize records".

### Industry wording

- Header button and booking dialog: "Book booking" (salons) → "New booking". Generally it is now
  `New <appointment word>`: New appointment, New reservation, New service call.

### Statuses everywhere

- New `web/src/copy/labels.js`:
  - `humanize()` gives one label per internal value, covering every status in the database;
  - `callResult()` and `isAnswered()` cover call results.
- Replaced 7 duplicate `words()` helpers and 13 inline `.replace(/_/g, " ")` conversions.
- Examples:
  - `pending_review` → Awaiting review;
  - `false_positive` → Not spam;
  - `needs_reconnect` → Needs reconnecting;
  - `dry_run` → Not sent (test mode);
  - `no_show` → No-show;
  - `ai_setup` → AI setup;
  - `cancelled` → Canceled;
  - `11labs` → ElevenLabs.
- Raw status badges are now humanized in:
  - admin Automations and Voice & numbers;
  - Integrations;
  - profile callbacks.
- Badges are no longer force-capitalized by CSS (`.ba-pill`), so they read in sentence case.

### Errors

- About 25 screens showed raw server text (`err.message`). They now go through:
  - `friendly()` in the business app;
  - `friendlyError()` in the admin dashboard.
- The page loader (`useLoad`) and the plan-continue banner use `friendly()` too.
- New rules:
  - network failures → "Couldn't reach Zella. Check your internet connection and try again.";
  - unknown codes → "That didn't work (code X). Try again, or contact Zella support if it keeps happening.".

### Spelling (US English)

About 70 user-facing strings changed:
- color, customize, customized, license, driver's license;
- programs, recognized, summarizes;
- canceled, canceling, anymore.

Internal values such as `cancelled`, field names and code identifiers were left unchanged.

### Not changed on purpose

- **Admin dashboard navigation labels** ("Industry Configuration", "Audit Logs", …) stay in Title Case. They double
  as routing keys, so renaming them is a code change, not a copy change. Tracked as R-2 in the audit.
- **"AI Receptionist"** stays capitalized as the module name in navigation; in sentences it is "your AI
  receptionist".
- **Database status values, API fields and audit action names** are unchanged.
