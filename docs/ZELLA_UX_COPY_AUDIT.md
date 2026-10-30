# Zella Voice: UX copy audit

Date: 30 October 2026. Branch `voice-reliability`. Scope: the React app in `web/src` (business app, Zella admin
dashboard, public pages). Frontend copy and copy helpers only: no database, permission, routing, billing, AI tool
or phone changes.

## How the audit was done

- **Inventory:**
  - read the navigation config (`navigation/navConfig.js`, `OwnerDashboard.jsx` NAVIGATION) and every page crumb;
  - read the Calls & messages pages line by line: Inbox, Messages, Calls, Callbacks, Sending failed, Suggested
    messages and Spam;
  - searched all 26,000 lines of `web/src` for status rendering (`words()`, `.replace(/_/g, " ")`, raw `{x.status}`
    badges), raw error display (`err.message`), British spellings, Title Case labels, generic button and error words,
    and placeholder-only instructions.
- **Backend meaning checked before relabeling:**
  - every status value from the live database's `CHECK` constraints;
  - the bodies of `zella_failed_work` and `zella_retry_failed`, read before renaming "Didn't send".
- **Not read line by line** (searched by pattern only):
  - the admin settings registry (`settings/AdminPanels.jsx`, 1,500 lines);
  - the create-business wizard (`CreateBusinessWizard.jsx`, 2,000 lines);
  - offers, onboarding hints, the knowledge base, automations detail and the legal pages.

  A sentence-by-sentence pass of those remains open (R-1).

Severity: **High**, can make someone misunderstand what happened (a call, a message, a save). **Medium**, unclear
or inconsistent, costs time or support. **Low**, polish.

## Findings

| # | Sev | Screen / component | Existing wording | Problem | Change | Kind | Depends on backend | Status |
|---|---|---|---|---|---|---|---|---|
| 1 | High | Calls table, call details, Inbox, profile timeline, lead and booking panels, Today feed (`BusinessCalls`, `BusinessInbox`, `BusinessProfile`, `BusinessLeads`, `BookingPanel`, `BusinessToday`) | "Answered" / "AI answered" for every call that wasn't `missed` | Misleading status: calls that failed to connect or are still ringing were shown as answered | `callResult()`: Answered (`answered`, `completed`), Missed, Didn't connect (`failed`), In progress (`initiated`, `ringing`) | Understanding | Yes: `calls.status` values | Done, browser-checked |
| 2 | High | Calls filter "Answered" | Included `failed`, `initiated`, `ringing` | Filter didn't match its name | Only answered or completed calls | Understanding | Yes | Done, browser-checked |
| 3 | High | Reports, "answered" metric (`BusinessMore`) | Counted every non-missed call | Metric label and calculation disagreed | Counts answered or completed calls only; failed or in-progress calls no longer inflate it | Understanding | Yes | Done (build only) |
| 4 | High | Sidebar and page "Didn't send" (`navConfig`, `FailedWorkPage`) | "Didn't send" / "Messages that didn't send" | Vague, and the page also lists follow-ups and reminders. The backend status is `failed` = a send attempt failed | "Sending failed", plus a description listing what appears and that it covers 7 days | Understanding | Yes: `status = 'failed'` in `zella_failed_work` | Done, browser-checked |
| 5 | Medium | Sending failed, action | "Try again" | Unspecific | "Retry sending" | Clarity | No | Done |
| 6 | High | Sending failed, empty state | "Nothing has failed. Messages and reminders are going out as expected." | Claims sending works, but the page only knows there are no failures. Nothing is sent while live sending is off | "No failed messages. Nothing failed to send in the last 7 days." | Understanding | Yes | Done |
| 7 | Medium | Sending failed, toast after retry | "Queued to send again." | Doesn't say when | "Queued to send again. It goes out on the next sending run." | Clarity | Yes: retry resets to pending | Done |
| 8 | Medium | Retry refused (`NOT_RETRYABLE`) | "This can't be retried any more." | No reason given | Says why: already retried, or the appointment has passed | Clarity | Yes: `zella_retry_failed` rules | Done |
| 9 | Medium | Sending failed, reasons; reminder lines | "Dry run no provider" | Internal code | "Not sent (test mode: no provider connected)" | Understanding | Yes: `dry_run` reasons | Done, browser-checked |
| 10 | Medium | Sidebar "Conversations" vs page title "Unified inbox" | Two names for one page | Label didn't match its destination | Both "Inbox" | Navigation | No | Done, browser-checked |
| 11 | Medium | Messages page badges | raw `open` / `pending` | Lowercase internal values | Humanized ("Open", "Pending") | Polish | No | Done |
| 12 | Medium | Messages channel filter; conversation fallback | "Sms", "sms conversation" | Internal value | "Text message" | Polish | No | Done |
| 13 | Medium | Breadcrumbs: Calls, Transcripts, Knowledge base, Leads and customers | "Communications / Calls", "AI & Intelligence / Transcripts", "AI Receptionist / Knowledge base", "Core / Leads" | Didn't match the sidebar | "Calls & messages / Calls", "AI Receptionist / Transcripts", "AI & automation / Knowledge base", "CRM / Leads" | Navigation | No | Done, browser-checked |
| 14 | Low | Sidebar and crumbs | "Calls & Messages", "Tasks & Follow-ups", "Reports & Analytics", "Team & Staff", "Business Growth", "AI & Automation" | Mixed Title and sentence case | Sentence case across the business app | Consistency | No | Done, browser-checked |
| 15 | Medium | Escalation badges and filters | "Needs a human", "Human handover", "Needs a person" | Three names for one state | "Needs a person" everywhere | Consistency | No | Done |
| 16 | Low | Calls filter | "AI handled" | Awkward | "Handled by AI" | Polish | No | Done |
| 17 | High | Header button and booking dialog (salons) | "Book booking" | Broken industry wording (`Book ${term}`) | `New ${term}`: "New booking", "New appointment", "New reservation" | Understanding | Industry terminology | Done, browser-checked |
| 18 | Medium | 7 duplicate `words()` helpers, 13 inline `.replace(/_/g, " ")` | e.g. "Pending review", "Dry run", "False positive", "Needs reconnect", "Ai setup" | Internal values leaked into the UI, with inconsistent capitalization | One `humanize()` (`copy/labels.js`) with curated labels for every status in the database, plus a readable fallback | Understanding | Yes: values from `CHECK` constraints | Done, unit-tested (13 cases) |
| 19 | Medium | Raw status badges: admin Automations and Voice & numbers, Integrations, profile callbacks | `{r.status}` | Raw values | Humanized | Polish | No | Done |
| 20 | Low | Badge style (`.ba-pill`) | CSS `text-transform: capitalize` | Forced Title Case ("Didn't Connect", "Missed, Followed Up") | Removed; badge text is written in sentence case | Consistency | No | Done, browser-checked |
| 21 | High | ~25 screens using `setError(err.message)`; page loader (`useLoad`); plan-continue banner | Raw server text, such as `NOT_ALLOWED`, `Failed to fetch` or PostgREST messages | Exposed internal codes; no next step | Business app: `friendly()`. Admin: `friendlyError()`. Network → "Couldn't reach Zella…". Unknown code → "That didn't work (code X). Try again, or contact Zella support…" | Understanding | No | Done (build only) |
| 22 | Low | US market spelling, ~70 strings | colour, customise, licence, programmes, cancelled, recognised, summarises, any more, driving licence | British spelling | color, customize, license, programs, canceled, recognized, summarizes, anymore, driver's license | Polish | No (internal values like `cancelled` untouched) | Done |
| 23 | Low | Appointment status label | "Cancelled" | Spelling | "Canceled" | Polish | No | Done |
| 24 | Medium | Admin dashboard navigation | "Industry Configuration", "Platform Operations", "Audit Logs", "Plans & Subscriptions", … | Title Case, unlike the business app | **Not changed**: these labels are also the page keys used for routing (`activePage === "Audit Logs"`, `onNavigate("…")`). Renaming needs separate keys first | Consistency | Code structure | Open (R-2) |
| 25 | Medium | Text and email statuses for business users | — | `sent` vs `delivered` is visible only to admins; owners can't see delivery per message | Documented in the status guide; showing delivery to owners needs a screen | Understanding | Yes | Open (R-3) |
| 26 | Medium | Status `blocked` (texts and emails) | "Blocked" | Doesn't say why | Needs the blocking reasons from the sender code | Understanding | Yes | Open (R-4) |
| 27 | Medium | Integration status `error` | "Error" | Doesn't say what to do | Needs a stored reason per provider | Understanding | Yes | Open (R-5) |
| 28 | Low | "AI Receptionist" (navigation) vs "AI receptionist" (sentences) | — | Two capitalizations | Kept on purpose: module name vs common noun (voice guide) | Consistency | No | Decided |
| 29 | Low | Code-only spellings (`isCancelled`, `pictureColours`, comments) | — | Not user-facing | Left unchanged | — | — | Not needed |

Count: **29 findings** (7 high, 15 medium, 7 low). **23 implemented**, 1 decided as is, 1 not needed, 4 open.

## Industry terminology

Checked with a salon test business (Clients, Booking, Stylists, "Salon operations"). Issue 17 was the only broken
phrase found by pattern search (`Book ${term}`).

The Today page already says "Book one with New booking"; it now matches the button.

**Review (R-6):** other templates that put an industry word after a verb, such as "Add …" and "Cancel …", should be
checked against every industry's terms. Watch for plural/singular and for terms that are already verbs or
gerunds (Booking).

## Testing evidence

| Check | Result |
|---|---|
| `npm run build` (Vite production build) | Passes |
| `npx oxlint src` | 0 errors; 176 warnings (was 174). The 2 new warnings are the same dev-only "fast refresh" note already raised 20+ times on `BusinessShared.jsx`, for the re-exported `callResult` / `isAnswered` |
| `humanize()` unit cases (scratch test, 13 cases: canceled, no-show, dry run, AI setup, dotted audit actions, providers, empty and null) | 13 of 13 pass |
| Browser, Playwright, stubbed data (no real backend), salon business, 1400 px and 390 px | Sidebar labels; Calls crumb, results ("Answered", "Missed", "Didn't connect", "In progress") and filters; "Answered" filter shows only answered calls; Sending failed title, description, rows, "Retry sending" and test-mode reason; Inbox title, crumb and call lines; no page errors. Text fits on mobile (390 px Sending failed checked) |
| Not browser-checked | Admin dashboard pages, Reports metric, profile timeline, lead and booking panels, Today feed (build-checked only), error mappings (no failing server used) |

No database, RLS, auth, billing, AI tool, phone routing or provider setting was changed. No messages or calls were
sent.

## Open items

- **R-1:** sentence-by-sentence pass of the admin settings registry, the create-business wizard, offers, onboarding
  hints and the legal pages.
- **R-2:** give admin navigation items stable keys, then switch their labels to sentence case.
- **R-3:** show text and email delivery (`sent` vs `delivered`) to owners where a message is listed.
- **R-4:** store and show why a message was `blocked`.
- **R-5:** store a provider error reason with integration `error` states.
- **R-6:** test the industry-word templates across all industries.
- **R-7:** engineering to confirm the two **Review** items in the status guide: whether `completed` can be set for an
  unanswered call, and the `blocked` reasons.
