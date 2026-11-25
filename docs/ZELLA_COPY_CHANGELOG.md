# Zella Voice: copy changelog

## 25 November 2026: phone navigation (both apps)

New words on phones only (under 768 wide); tablets and desktops show nothing new. Approved by the owner on 25 Nov
2026 (`docs/ARCHITECTURE.md` §23.1d). Sources: `web/src/navigation/` and the phone parts of the pages named below.

| Where | Text | Why |
|---|---|---|
| Bottom bar, CRM | Today, Calendar, Tables, Check ins, Dispatch, Orders (the record type's name), Leads, the industry's customers (Guests, Clients, Patients, Customers), Inbox, More | The tab rule; "Calendar" for every industry (owner decision 3) |
| Bottom bar, admin | Overview, Businesses, Support, Operations, More (Verification and Audit logs when a role can't open Support or Operations) | Owner decision 4 |
| Tab names for screen readers | "Inbox, 2 waiting", "More, 1 to review", "Support, 5 open", "Operations, 1 open alert" | The count is part of the tab's name |
| Side panel | Menu (its name), Close menu, Switch, My profile, Password and security, Appearance and theme, Sign out, Zella Voice Platform | Same words as the desktop menus |
| Top bar | Search (and the page's own "Search ..." words), Show more, Show less (the sheet handle), Close | Plain names for icon buttons |
| Sticky action | New reservation (the industry's word for a booking), Add lead, New task, Seat a walk in (restaurants) or Add a walk in, Create business, Quick actions | One main action per page |
| Quick actions sheet | Quick actions; Seat a walk in, Add lead, New task, Tell callers | Today's round button |
| Business switcher sheet | Switch business or open its settings; Switch business; Business profile; Modules and industry; Team members; Plan and billing | Same as the desktop switcher |
| Live strip, CRM | "2 callers want a person", "Tom Becker, waiting 4 min", "Waiting 9 min", "Your AI receptionist handed them over", Open | Callers waiting only (owner decision 6) |
| Live strip, admin | The incident's title, "Incident open for 18 min", "2 open incidents", View | Open incidents only |
| Needs you now (Today) | Needs you now; "2 callers want a person"; "Tom Becker asked about ..."; "Task for Maya Chen, due 1 hr ago"; "3 overdue tasks"; "The oldest: ..."; Overdue; "1 call to review in Spam protection"; "Blocked as likely spam, check it was right" | P14 |
| Tasks | "Swipe a task left to call back or mark it done", Call back, Done, "Mark ... done", "More for ...", Mark done, "Call back ...", "Open ...", Dismiss, "Task marked done", Undo, "Couldn't mark it done, so it's back on the list." | Swipe rows with visible buttons, Undo |
| Callbacks | "Swipe a callback left to call or mark it called", Call, Called, "Mark ... called", Overdue | Swipe rows; Called opens the existing "how did it go" form |
| Admin Support | "Swipe a ticket left to assign it to you or resolve it", Assign, Resolve, Open ticket, Assign to me, "Open ...", "Ticket resolved", "Ticket assigned to you", "Couldn't save that change, so it's back as it was.", No reply yet, "Couldn't load this list. Pull down to try again, or reload the page." | Swipe rows, Undo |
| Admin business sheet | Plan, Stage, Last call, Open, Continue setup, Call owner, Activity, Needs attention, Setup; "Plumbing, owner Dana Reyes" | P12 |
| Pull to refresh | Pull to refresh, Let go to refresh, Refreshing | P17 |
| Placeholders (screen readers) | Loading the page, Loading tasks, Loading callbacks, Loading tickets, Checking your access | P18 |

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
