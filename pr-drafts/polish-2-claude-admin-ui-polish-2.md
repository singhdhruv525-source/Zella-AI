Admin polish: Voice, Messaging and Automations copy and layout
base: main

<!-- Already open as PR #88 (https://github.com/singhdhruv525-source/Zella-AI/pull/88). Pushed head e5e42d2 has CodeRabbit success and 0 unresolved threads. A local merge of origin/main (commit bee6e98, PRODUCT.md conflict resolved keeping both rows) is in /home/user/singhdhruv525-source/wt-ui2 and is NOT pushed. -->

Screen only fixes from the admin audit's visual pass (`docs/ADMIN_AUDIT_2026-11-16.md`) on Voice, Messaging and Automations. No server, SQL or permission change; every page uses only the data it already received. `PlatformMonitoring.jsx` is not touched.

## What and why

**UI-16: Voice, Calls.** The last column of pills ("Needs a person", "Error", "Transfer failed") is now headed "Attention". Lengths use one format everywhere (`duration()` in `adminOps.jsx`): "45 s", "1 min", "2 min 5 s", "1 h 2 min" instead of "1 min 0 s", and a missing length, number or outcome says "Not recorded" instead of "Not available" or "None". The call drawer uses the same words.

**UI-18: Voice, Providers & costs.** The "Connection checks" panel repeated the Overview tab, so it's gone from this tab; Overview keeps the checks and now carries the "Provider checks are off" note and a one line description (its button reads "Keys and costs"). AI voice usage lists the 20 businesses with the most calls (sorted by calls, then minutes) with "Top 20 of N businesses, by calls" and a "See all N" button (`aria-expanded`, toggles back to "Show top 20"). The period select is as wide as its options: a new `fit` option on the Settings `Field` (`.zs-field.fit`). The same component is the Settings Voice usage page, which gets the same paging.

**UI-21: setting keys in words (Voice, Messaging, Automations).** A small map, `web/src/copy/liveSwitches.js`, says what each switch means. Shown text no longer contains `sms_live`, `email_live`, `calls_live` or `provider_checks_live`:
- Voice: "The calls_live switch is off" becomes "Zella Voice places no outbound calls until they are switched on at go live"; Providers "Off (calls_live)" becomes "Off until go live".
- Messaging: "Texts (sms_live is off) and Emails (email_live is off): ..." becomes "Texts and emails are in test mode. ..."; "Test mode (sms_live off)" pills become "Test mode, nothing is sent"; "Off (sms_live)" and "Off (email_live)" become "Off: test mode, nothing is sent"; "(platform_settings)" is gone.
- Automations: "The zella_dispatch job is off" becomes "The dispatcher job is off"; the go live checklist explains each step in words ("The number texts are sent from", "Off means test mode: nothing is sent").
The key stays available as a tooltip (`title`, or the new `tip` prop on `NotAvailable`).

**UI-27: Automations, Scheduler & n8n.** The jobs showed twice ("Scheduled jobs" and the embedded "Scheduled database jobs"). The page keeps its own, fuller table; the embedded go live checklist hides its copy there (`<N8nConfig showJobs={false} />`; the Settings n8n page still shows it). File paths and table names in text are replaced by words: `n8n/GO-LIVE.md` becomes "the n8n go live guide", `n8n/README.md` becomes "the n8n setup guide", `sql/zella_messaging_status.sql` and `sql/zella_dispatcher.sql` become "the messaging status update" and "the dispatcher database update", and `workflow_executions`, `automation_events` and `industry_automation_presets` are described in words.

**Same pages, found while there:**
- Lowercase labels: "follow ups due now", "follow ups failed (7 days)", "follow ups overdue" (an alert and a card) now start with a capital.
- Hyphens the dash check misses inside template strings: "follow-ups" (Automations queue note), "follow-up" (Messaging retry dialog), "5-minute window" (webhooks table).
- "None" in tables replaced by words: Numbers (Label "No label", Receptionist "No receptionist", Last call "No calls yet"), Messages (Address "Not recorded", Subject "No subject", Last event "No events yet", Error "No error"), Templates (Business copies "Not applicable" on a business's own copy), Automations (Industry "No industry", Last run "Never", run Error "No error", a step with no status "No status", queue "Nothing waiting"), Scheduler (Last success and Last handed over "Never"), provider checks (Last check and Last healthy "Never"), Dispatcher state ("Not recorded"), call routing review ("Not set"); `when()` takes an optional empty word for this.
- "rate Not available" notes: "No answer rate yet" (Voice) and "No delivery rate yet" (Messaging).
- " to " joins that read wrongly before an error or reason ("Failed to timeout"): now "Failed: timeout" and ". Reason: ...".
- "on call rota" now starts with a capital; the dispatcher table's unlabelled flag column is headed "Attention".
- On a phone, Automations, Scheduler & n8n scrolled the whole page sideways by 70 px (the embedded Settings cards widened their grid): `.ao-embed` now has a `minmax(0, 1fr)` column.

## Review fix

- CodeRabbit: with texts live and emails off, the Messaging notice said every message was recorded as not sent. Now, with one channel off, the title names it ("Texts are in test mode"), the body says only that channel's messages are recorded as "Test mode (not sent)" and that the other channel is live; with both off it reads as before (e5e42d2, checked against the isolated database with each switch on in turn).

## How it was tested

Local browser check against the stand in backend (`tests/browser/local-backend.mjs` with the real `owner-provision-business` code under Deno) over an isolated test database made from template `zcrawl` (`zui_polish`), signed in through the real sign in page as `admin@zella.test`, and as `glass-admin@zella.test` for the dark Glass theme. A few platform settings rows (live switches off) were added to that test database only. Nothing was sent and nothing touched production.

- Every tab of Voice (5), Messaging (7) and Automations (6), at 1440 by 900 and 390 wide, device scale 1, before and after: no page errors, no failed requests, no sideways page scroll (before: Automations, Scheduler & n8n overflowed 70 px on a phone; after: 0).
- "See all 63" shows all 64 rows (63 plus the header) and switches to "Show top 20"; the default view has 20.
- `npm run lint`: 0 dashes; 220 warnings, the same as `main` (none new in files touched).
- `npx vite build`: builds.
- `node --test web/tests/*.test.mjs`: 102 of 102 pass, including the new `liveSwitches.test.mjs`.

## Before and after

- Calls: before, an unheaded pill column, "Not available" beside "1 min 0 s", "None" in Number and Outcome; after, "Attention", "1 min", "Not recorded".
- Providers & costs: before, connection checks (repeated from Overview), an unpaged list of every business and a full width select; after, keys, the top 20 with "See all", a select as wide as its options.
- Messaging overview: before, "Texts (sms_live is off) and Emails (email_live is off): ..."; after, "Texts and emails are in test mode. ..."
- Scheduler & n8n: before, two job tables and `n8n/GO-LIVE.md`, `n8n/README.md` in text; after, one table and words.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
