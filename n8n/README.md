# Zella n8n workflows

Seven workflows. All are shared by every business and every industry. Nothing business-specific lives in n8n: the database holds the rules, n8n moves the work.

**Nothing in n8n runs on a timer.** n8n Cloud's Starter plan allows 2,500 runs a month, and a workflow that wakes every minute uses about 43,000. So a Supabase job (`zella_dispatch_n8n`, see "The dispatcher" below) is called straight away whenever something urgent is saved (a new event, follow-up, alert or reminder), and once a minute as a safety net for work that becomes due later and calls the matching workflow only then. The timed database jobs run inside Supabase too.

| File | What it does |
|---|---|
| `workflows/zella-event-gateway.json` | Receives events at `POST /webhook/zella/events`, checks them, stores them once (`zella_ingest_event`), replies quickly. Repeats are recognised and stored only once. |
| `workflows/zella-sms-sender.json` | Takes due appointment reminders and confirmations, checks consent and the template in the database, logs the message, and sends it through Telnyx **only when live**. In dry-run (the default) nothing is sent. |
| `workflows/zella-followup-texts.json` | Takes due follow-up **text** tasks (no-show, post-visit thank-you, quote follow-up, reactivation, and the fallback text after a callback runs out of tries) and runs them through the same consent check, logging and dry-run switch as the reminders. Call tasks are never picked up. |
| `workflows/zella-email-sender.json` | Takes due appointment confirmations and reminders whose channel is **email** and runs them through the same pipeline as the text sender: consent, template, safe HTML, logging, duplicate protection, dry-run switch. Sends through Resend **only when live**. |
| `workflows/zella-followup-emails.json` | Takes due follow-up tasks whose channel is **email** (same kinds as the follow-up texts) through the same consent check, logging and dry-run switch. A task moves to email when the customer cannot be texted but can be emailed. |
| `workflows/zella-owner-emails.json` | Emails owner notifications (daily summary, weekly review, any warning or urgent alert) to the right people, honouring each person's email preferences. Same dry-run switch and Resend box as the email sender. |
| `workflows/zella-spam-response.json` | Follow-up for spam incidents the database already detected, scored and screened: routes each by severity, checks repeat offenders, asks the AI only about ambiguous texts/emails (optional), and posts a weekly summary. Every result goes back through `zella_spam_finish_work`, which re-checks it and applies only the approved policy. See "Spam Response" below. |
| `workflows/zella-event-router.json` | Takes up to 20 stored events (`zella_claim_events`), runs the right handler, writes an execution record, and reports the result (`zella_complete_event`). Temporary failures are retried by the database with a growing delay. Permanent ones go to the dead-letter list. |

## What the router handles today

| Event | What happens |
|---|---|
| `message.received` (sms) | STOP, START and HELP keywords are applied through the consent record |
| `customer.opted_out` | Opt-out recorded and the customer's do-not flag switched on |
| `integration.disconnected` | An urgent platform alert is raised (repeats are grouped) |
| `integration.reconnected` | The alert is resolved |
| Anything else | **Not silently ignored.** It is sent to the dead-letter list as "no handler yet" so the gap is visible |

Handlers for reminders, callbacks, SMS sending, email, Meta and the website are not built yet.

## The dispatcher and the timed jobs (Supabase, not n8n)

Run `sql/zella_dispatcher.sql` **last**, after every other Zella SQL file, then do its one-time secret step. It turns on `pg_cron` and `pg_net` and sets up:

- **Timed jobs inside Supabase** (UTC): every 5 minutes (overdue leads, expire held slots, expire waitlist offers, transfer failures), every 15 minutes (quote follow-ups), every hour (daily summaries: a business is posted once, at its own local 8am), daily 04:00 (lead reactivation up to 200, setup incomplete, trials, payment policy), Monday 08:00 (weekly reviews). A job that fails raises one grouped platform alert. These cost no n8n runs.
- **The dispatcher, on urgent saves plus a once-a-minute safety net.** It counts what is due for each worker workflow (events, text reminders, email reminders, follow-up texts, follow-up emails, owner emails) and calls that workflow's webhook (`/webhook/zella/run/<name>`) only if the count is above zero. It counts only the kinds the workflow really handles, so unhandled work can never make it call n8n forever.
- **A stuck-item guard.** If the same amount is still waiting after 5 calls in a row, it slows to once every 15 minutes.
- **A master switch:** set the platform setting `n8n_dispatch_enabled` to `false` to stop all calls.
- **The secret.** The dispatcher sends the same secret as the n8n credential "Zella gateway secret". Store it once, yourself, in the Supabase SQL editor: `select vault.create_secret('<your secret>', 'zella_n8n_secret');`. Without it the dispatcher does nothing.

Not scheduled, on purpose: `zella_calls_to_callbacks` and `zella_queue_no_show_followup` are database triggers and fire by themselves; `zella_check_invitations` needs invitation reminder emails (not built); `zella_retention_due` only lists businesses and nothing deletes yet.

Check it works: `select jobname, schedule, active from cron.job where jobname like 'zella%';` and `select * from public.n8n_dispatch_state;` (shows how often each workflow was called).

## Text sender: dry-run and going live

Run `sql/zella_sms_sender.sql` in the Supabase SQL editor first. It adds four functions and two platform settings.

- **Dry-run (default).** `sms_live` is `false`. The workflow checks consent, fills the template, logs the message as `dry_run` and marks the reminder skipped ("dry_run: no text was sent"). No text leaves.
- **Safety checks in the database:** no consent or do-not-text, no valid phone number, unfilled template placeholders, a suspended or cancelled business. Each skips the reminder with that reason and does not retry.
- **No double texts.** Each reminder has one message record. A repeat is suppressed. A failed try may be retried; the database retries twice, then tells staff.
- **To go live (later, all of these):** a Telnyx number and approved 10DLC registration, a Header Auth credential named `Zella Telnyx` (name `Authorization`, value `Bearer <Telnyx key>`) selected by hand on the "Send via Telnyx" box (it ships with no credential on purpose; on import n8n may offer another Header Auth credential, such as the gateway secret, so check which one is chosen), `sms_from_number` set, then `sms_live` set to `true`. Test with one number you own first.
- **Two flows use this pipeline:** reminders and confirmations (SMS Sender), and follow-up texts (Follow-up Texts). The text sender claims text reminders only; email reminders go to the Email Sender. Other channels are skipped with `channel_not_supported_yet:<channel>`.
- **Follow-up texts:** run `sql/zella_followup_texts.sql` first (3 templates, a text-only claim, a skip function), then `sql/zella_callback_sms.sql` (adds the callback reason to the claim). A callback that runs out of tries leaves a `callback_sms` task: a missed call gets the missed-call text, a new lead gets the lead acknowledgement. Reactivation is marketing, so it is only sent to people who opted in. Waitlist offers are not included yet (they need reply handling). Callbacks and missed-call texts are not wired yet.
- **Not covered:** inbound delivery receipts (Telnyx status webhooks) and per-business sender numbers.

## Email sender: dry-run and going live

Run `sql/zella_email_sender.sql` in the Supabase SQL editor (after `zella_sms_sender.sql`). It adds two starter email templates (confirmation, reminder), the email prepare / log / update functions, two platform settings, and makes `zella_claim_reminders` take a channel (default `sms`, so the text sender keeps working without changes).

- **Dry-run (default).** `email_live` is `false`. Emails are checked, filled in, logged as `dry_run`, and the reminder is marked skipped ("dry_run: no email was sent"). Nothing leaves.
- **Safety checks in the database:** do-not-email or opt-out, no valid address, missing template or unfilled placeholder, a suspended or cancelled business. Customer names cannot add email headers, and the HTML copy escapes every special character.
- **Marketing email is refused** (`marketing_email_not_ready`) until unsubscribe links exist.
- **To go live (later, all of these):** a Resend account with a verified sending domain, a Header Auth credential (name `Authorization`, value `Bearer <Resend key>`) selected by hand on the "Send via Resend" box (it ships with no credential on purpose), `email_from_address` set to an address on that domain, then `email_live` set to `true`. Test with one address you own first.
- **Not covered yet:** follow-up emails (only appointment emails so far), inbound email, bounce and complaint handling, unsubscribe.

## Follow-up emails and text/email switching

Run `sql/zella_followup_emails.sql` after `zella_email_sender.sql`, `zella_followup_texts.sql` and `zella_callback_sms.sql`.

- **Six email templates** (no-show, thank-you, quote follow-up, lead acknowledgement, missed-call, callback acknowledgement). They tell the person to contact the business rather than "reply here", because inbound email is not built yet.
- **Every client still gets a message.** If a text cannot go (no phone number, or texts switched off) but an email can, the reminder or follow-up moves to email, and the other way round. A person who cannot be reached either way, or who opted out, is skipped with a visible reason. Opt-outs are still checked when the message is prepared.
- **The text workflows do not need re-importing.** The change is in the database claim functions.
- **Reactivation is marketing:** it is skipped for email (`marketing_email_not_ready`) until unsubscribe links exist.
- **Reported as** `email_sent` on the follow-up task.

## Customer text replies

Run `sql/zella_inbound_replies.sql` after `zella_followup_emails.sql`. The router workflow does **not** need re-importing (the change is inside the database function it already calls). The Follow-up Texts workflow **does** (it now also sends the quick replies).

- **Every incoming text is saved** and matched to the customer when the number is known.
- **STOP / START / HELP** work as before. HELP now queues a reply (`reply_help`).
- **C and R are not special.** Customers never have to reply to anything: they change a time with the Reschedule link (next section). (YES still means START for someone who opted out.)
- **Anything else** shows a "New text from ..." notice in the app.
- Replies to a customer's own message go out straight away (no calling-hours delay) and are never moved to email.
- **Not covered yet:** letting the customer pick a new time by text, a staff reply screen, and replies to emails.

## Waitlist offers

Run `sql/zella_waitlist_offers.sql` (after `zella_reschedule.sql`). The Follow-up Texts workflow handles the new `waitlist_offer` kind (its Plan step and claim list changed, so re-import it or update those two nodes). Deploy the `reschedule-appointment` function again (it has three new actions) and the web app (new `/w/<code>` page).

- When an appointment is cancelled and the business has the waitlist automation on, the database already offers the freed time to the next person who fits and queues a text. Nothing is reserved.
- The text now carries a private **Book it here** link (or "Contact us to take it" until `app_base_url` is set). The page shows the time and two buttons: **Book this time** and **No thanks**.
- Yes books it (the calendar re-checks the time, so a taken time is never double-booked). No passes the time to the next person. An offer nobody answers expires and moves on (existing 5-minute job).
- The text goes out straight away, is never moved to email, and is never sent if the offer is no longer open.

## Overdue callback alerts

Run `sql/zella_callback_alerts.sql` (and re-run `zella_dispatcher.sql` at go-live so the timer picks it up). No new n8n workflow: it is a timed database job (every 5 minutes) and the Owner Emails workflow emails the alerts.

- A callback that is due but still open raises **one warning** after a short wait: 10 minutes for urgent callbacks, 30 for others, 60 when Zella is meant to place the call itself (it gets time to try first). If the callback is assigned, the warning goes to that person; otherwise to the owners and admins.
- If it is still open **3 hours** after it was due, owners get **one urgent alert**.
- Warnings and urgent alerts are emailed (see "Who is emailed" below). A callback moved to a later time can warn again when it is late again. Closed, cancelled and completed callbacks never alert.

## Outbound calls (dry-run)

Run `sql/zella_outbound_calls.sql` (needs `zella_followups.sql` and the callbacks file). Import `workflows/zella-outbound-calls.json`.

- Two things are called: **callbacks Zella may place itself** (missed call, new lead; the business switched auto-call on) and **follow-up tasks set to "call"** (no-show, after a visit, a quote).
- The workflow claims what is due, and only when `calls_live` is true **and** `vapi_assistant_id` and `vapi_phone_number_id` are set does it ask Vapi to place the call. Otherwise nothing is dialled: the item is put back (no attempt used) and comes up again in 12 hours.
- Calling hours, do-not-contact and attempt limits apply as before. A person who cannot be called (opted out, no number) moves to a text, then an email.
- A bad phone number is recorded as a failed attempt. A refused Vapi request counts as a failed attempt, so the normal retry rules apply.
- The Vapi box ships with **no credential**; add the Vapi key by hand when going live.
- The result of a call is handled by **Call Results** (`workflows/zella-call-results.json`, webhook `/webhook/zella/vapi`, protected by the same `X-Zella-Secret`). It runs only when a call ends. In Vapi, point the assistant's server URL there and set its server messages to **end-of-call-report** only, so nothing else wakes it.
- It reads `zella_source` and `zella_id` from the call's metadata and records the outcome (answered, no answer, busy, voicemail, bad number, failed). A callback that connects is marked contacted. A follow-up task where the customer spoke goes to "wants a callback" for staff unless the assistant returns a clear outcome (rescheduled, declined). A report received twice is ignored.
- **Stuck-call sweep:** a call placed but with no report after 45 minutes is freed and counted as a failed attempt (`zella_sweep_stuck_calls`, runs every 5 minutes in Supabase, no n8n runs). The 13 timed jobs now include it.
- Needs a real Vapi account to test end to end.

## The Reschedule button

Run `sql/zella_reschedule.sql` after `zella_email_sender.sql`.

- Booking confirmations and reminders (text and email) go out on their own. Nobody has to reply. The only thing a customer can do is tap **Reschedule** and pick a new time.
- The "please confirm" reminder is no longer created (any still waiting is cancelled). STOP still works.
- Each message carries a private link `<app_base_url>/r/<code>`. The code is for one appointment, only its hash is stored, and it stops working once the appointment has passed or been cancelled.
- The public page (`web/src/Reschedule.jsx`) calls the `reschedule-appointment` function, which offers the free times for the same length of visit and the same staff member, and moves the **same** appointment. The calendar rules decide whether a time is free, the reminders are rebuilt, and the business is told.
- Until `app_base_url` is set (in `platform_settings`, for example `"https://app.yourdomain.com"`), messages go out with no link.
- **Re-import the SMS Sender and Email Sender** (their Plan step now passes the link). The claim function was changed in the database.

## Owner summaries and owner emails

Run `sql/zella_owner_emails.sql` after `zella_email_sender.sql`.

- **Daily summary:** every hour the scheduler checks each business; at 8am its local time it posts "Your day with Zella" (calls, missed, bookings, new customers, today's appointments, what needs attention). Once a day, and only when there is something to say. It appears in the app's notifications either way.
- **Who is emailed:** a daily summary, a weekly review, or any warning or urgent alert. Notifications for the whole business go to active owners and admins; notifications for one person go to that person. A person can switch email off (or on) for any kind in `notification_preferences`. Anything else is marked `skipped / not_emailed` and stays in-app only.
- **Same safety as the other senders:** dry-run until `email_live` is true, one email per notification and address, a sent email is never downgraded by a later failure, and a notification stuck in `sending` for 30 minutes is picked up again.
- **Not covered yet:** a settings screen for the preferences, staff invitation emails (`zella_check_invitations`), SMS alerts for staff.

## Setup (once)

1. In n8n, create two credentials:
   - **Zella Supabase service role**: type *Custom Auth*. JSON: `{"headers": {"apikey": "<service role key>", "Authorization": "Bearer <service role key>"}}`. Use the service role key from Supabase, Settings, API. It stays in n8n only. Never put it in the website or in a workflow file.
   - **Zella gateway secret**: type *Header Auth*. Name `X-Zella-Secret`, value a long random string. Every system that posts events must send this header.
2. Import all seven files (Workflows, Import from file). Open each node that shows a missing credential and select the credential above. The six worker workflows each start from a protected webhook ("Run now") that uses the **Zella gateway secret** credential.
3. Publish all seven (they import as inactive). Nothing runs until the dispatcher calls it.
4. In Supabase, run `sql/zella_dispatcher.sql` and store the secret (see "The dispatcher").

## Sending an event

```
POST {n8n-url}/webhook/zella/events
X-Zella-Secret: <your secret>
Content-Type: application/json

{
  "business_id": "<business UUID>",
  "event_type": "message.received",
  "source": "telnyx",
  "idempotency_key": "telnyx-<provider message id>",
  "payload": { "channel": "sms", "from": "+14155550123", "body": "STOP" }
}
```

Replies: `200 {ok, id, duplicate}`, `400` bad request, `401/403` wrong secret, `422` unknown or unavailable business, `502` could not store.

## Security notes

- Only systems that hold the secret can post. Provider adapters (Telnyx, Vapi, Meta, website forms) must work out the business on the server side and must not pass on a business ID a visitor typed.
- Provider signatures (Telnyx, Meta) get checked in their own adapter workflows, before an event is posted here.
- The gateway has no rate limit of its own. Put a limit in front of n8n (reverse proxy or Cloudflare).
- Error text is shortened and secret-looking strings are removed before it is stored.

## Tests

`node n8n/test.mjs` runs 220 checks: the exact Code-node logic that ships, plus structure checks on all seven files (connections, node references, no pasted keys).

**Not verified:** the files have not been imported into a running n8n. The workspace could not install n8n. Import them into your n8n and report anything that does not open cleanly. Node versions used: Webhook 2, Code 2, HTTP Request 4.2, IF 2, Schedule Trigger 1.2, Respond to Webhook 1.1.

The database calls these workflows make were tested against the real database (rolled back afterwards).

## Changing the workflows

Edit the Code files in `src/`, then run `node n8n/src/build.mjs` and `node n8n/test.mjs`. Do not hand-edit the JSON.

## Knowledge (FAQs and unanswered questions)

Run `sql/zella_knowledge_automation.sql` (needs `zella_knowledge.sql`). Import `workflows/zella-knowledge.json` (webhook `/webhook/zella/run/knowledge-sync`, started by the dispatcher only when something is waiting).

- **Publish:** when an owner adds or changes an FAQ, service, policy or hours item it waits as "processing". The workflow checks it (title and answer present, answer under 4000 characters) and marks it **ready** or **failed** with a reason the owner can read. The assistant only uses ready items, read from the database at call time (`zella_ready_knowledge`), so nothing is uploaded anywhere. An item changed again meanwhile is ignored (version check).
- **Suggest:** when the assistant could not answer a question, an AI drafts an answer using **only that business's own ready knowledge**. It is a draft: the owner still checks and submits it before it is used. If the knowledge does not cover the question, no draft is made. Three tries per question.
- The drafting is **off** until setting `knowledge_ai_live` is true. The AI box ships with **no credential**; add the Anthropic key by hand (header `x-api-key`) when going live. Model is the `knowledge_ai_model` setting. While off, the database claims nothing and the dispatcher does not count questions, so no runs are used.
- Not built: uploading documents or a website into knowledge, and pushing knowledge into a separate Vapi knowledge base (the assistant reads it from the database instead).

## Assistant tools (the "couldn't answer" report)

Run the third section of `sql/zella_knowledge_automation.sql` (it is in the same file). Import `workflows/zella-assistant-tools.json` (webhook `/webhook/zella/vapi-tools`, same `X-Zella-Secret`). It runs only when the phone assistant calls it during a call.

- In Vapi, add a **server tool** named `report_unanswered_question` with one text parameter `question`, pointing at that webhook. Tell the assistant to use it when it does not know an answer, and then to say the team will get back to the caller.
- The workflow logs the question for the owner (`zella_report_unanswered`). The business comes from the call when Zella already knows the call, otherwise from `business_id` in the call's metadata or assistant variables. A call with no business is rejected. At most 5 questions per call; the same question is one review item that counts up.
- It always answers Vapi with the same short line, so the assistant keeps talking naturally whether or not the question could be saved.
- The Knowledge workflow then drafts an answer (when `knowledge_ai_live` is on), and the owner approves it on the Knowledge page.
- **Still needed for inbound calls:** Zella must know which business a call is for (the phone number to business link is not built yet). Until then, set `business_id` as an assistant variable per business.

## Appointment booking by the phone assistant

Run `sql/zella_ai_booking.sql` (needs `zella_run_all.sql`). Import `workflows/zella-appointment-booking.json` (webhook `/webhook/zella/vapi-booking`, same `X-Zella-Secret`). It runs only when the assistant uses one of its two tools during a call.

- In Vapi add two **server tools** pointing at that webhook: `check_availability` (optional: `date` as YYYY-MM-DD, `days`, `duration_minutes`) and `book_appointment` (`start` exactly as returned by check_availability, `first_name`, `last_name`, `phone`, optional `email`, `title`, `notes`, `duration_minutes`).
- **The database decides everything** (`zella_ai_booking`): the calendar's working hours, breaks, time off and existing bookings are respected. Times are up to 5 openings, in the business's own time zone.
- If the time was just taken, the caller is offered other times. A booking is only confirmed after the calendar accepts it. If Zella cannot tell who the caller is for sure, or anything unexpected happens, a **request** is saved for staff and the assistant is told not to say it is booked.
- The same caller asking twice for the same time is booked once. Reminders and the confirmation message come from the normal booking rules.
- The business comes from the call (when Zella knows it) or from `business_id` in the call metadata or assistant variables, the same as the "couldn't answer" tool.
- **Changing an existing booking by phone** (same workflow, three more Vapi server tools): `find_my_appointments`, `reschedule_appointment` (`appointment_id` from find, `start` from check_availability) and `cancel_appointment` (`appointment_id`). The caller is recognised **only by the number they are calling from** (taken from Vapi's call, never from what is said). Only an exact match to one customer can see or change that customer's own upcoming bookings. If the caller cannot be matched, nothing is shown or changed and a callback is created for staff. A move that fails leaves the original booking unchanged and offers other times. Cancelling frees the time (waitlist offers and staff notices follow the normal rules).
- Not built: choosing a specific staff member, and services with different lengths per service.

## Email bounces and spam complaints

Run `sql/zella_email_events.sql` (needs `zella_email_sender.sql`). Import `workflows/zella-email-events.json` (webhook `/webhook/zella/resend`). It runs only when Resend reports something.

- **Permanent bounce** (the address does not work): that address is never emailed again, for every business; the message is marked failed; the business gets a notice to check the address with the customer. **Temporary bounce:** recorded only. **Spam complaint:** that person is never emailed again by that business, and the business is warned. **Delivered:** the message is marked delivered. Texts and calls are not affected. Repeated events are ignored.
- **Setup at go-live:** run once in the SQL editor `select vault.create_secret('<a long random value>', 'zella_resend_webhook_key');`. In Resend add a webhook to `https://<n8n>/webhook/zella/resend?key=<the same value>` for the events delivered, bounced and complained. Resend cannot send a custom header, so the key is in the address; the database checks it, and a wrong key changes nothing (answered 401). Do not paste the value anywhere else.
- Staff who clear "do not email" on a customer are trusted to know the address is fixed.
- Not built: the unsubscribe link and page for marketing emails (reactivation emails stay skipped until it exists), and complaint handling for texts.

## Engine health watch

Run `sql/zella_engine_health.sql`, then `sql/zella_dispatcher.sql` (it adds the check to the 5-minute group). It runs entirely in Supabase, so it uses **no n8n runs** and needs no workflow.

- **Stuck work is freed:** a follow-up text or email, a reminder or an owner notification that was picked up but never finished for 30 to 60 minutes goes back to the queue. Repeating a send is safe because every message has a duplicate guard. A notice is raised when this happens. Calls are handled by the stuck-call sweep.
- **Pile-ups raise one alert per queue** (reminders waiting over 30 minutes, follow-ups over 60, events over 15, owner notifications over 60) and clear themselves when the queue is empty. A pile-up usually means the engine is switched off or a provider is down. The alerts reach you through the normal platform alert delivery.

## Google Calendar sync
Workflow `Zella - Calendar Sync` (webhook `zella/run/calendar-sync`). Zella's database stays the source of truth for free times and bookings; Google is a copy plus a source of busy times.
- **Booking to Google:** when a confirmed booking is created or changed (or cancelled), a trigger puts a row in `calendar_sync_queue` (only for businesses with an active connection). The workflow creates, updates or deletes the Google event and saves its id on the appointment. Failures retry up to 5 times (5, 10, 15 ... minutes), then raise a platform alert.
- **Google to Zella:** the workflow lists the next 60 days of events and replaces the imported `blocked_times` (cancelled, "free" and Zella-made events are ignored; all-day events block the day in UTC). Refreshed when a connection is made, and hourly by `zella_schedule_calendar_pulls`. A lost-access error pauses the link and alerts.
- Nothing runs until `calendar_sync_live` is true. The refresh token is kept in Vault (`zella_gcal_<business id>`); it passes through the workflow run data when talking to Google. The Google client id/secret are pasted on the two token boxes by hand.
- Known limits: first 250 events only; if an owner deletes a Zella event in Google, later edits to it fail (retry then alert); one calendar per business.

## Phone number to business link
Table `business_phone_numbers` (number in +1... form, optional Vapi phone number id, active or paused). `zella_register_phone_number(business, number, vapi_id, label)` adds one (service role only; a number cannot belong to two businesses). In the two Vapi tool workflows (Assistant Tools and Appointment Booking) a "Find business" step calls `zella_business_for_number` with the called number and Vapi number id before the database call:
- A registered, active number always wins over anything in the call settings.
- A paused number, or one belonging to a stopped business, never falls back (the tool then refuses to act).
- An unregistered number uses the business id from the call settings only if that business is active.
Businesses can read their own numbers; nobody can write from the browser.

## Work assignment (leads and callbacks)
All in the database; no n8n runs. `assignment_rules` (per business): `off`, `round_robin` (default; whoever was given work longest ago) or `least_busy` (fewest open leads, callbacks and tasks), the roles that can receive work, and how long unowned work may wait before an alert (default 10 minutes). Members can be marked away (`zella_set_member_away`) or not accept work.
- A trigger gives every new lead (`lead_stage` set) and new callback an owner and notifies that person.
- Every 5 minutes `zella_rebalance_assignments` moves work from people who are away, not accepting work or no longer active, and gives owners to any leftover unowned work.
- Every 5 minutes `zella_check_unassigned_work` sends owners and admins one alert (at most every 6 hours per business) when work has waited with nobody available.
There is no screen for these settings yet.

## Complaints, corrections and privacy requests
Database only. `zella_log_customer_request` (service role) records a complaint, data correction, data access or data deletion request once (repeats within 24 hours are not duplicated), gives it a due time (complaint 24 hours or 4 if urgent, correction 3 days, privacy 30 days) and routes it: complaints and corrections to the next available person (same sharing rules as leads), privacy requests to an owner or admin. Privacy requests start as `waiting_verification`: Zella never releases or deletes data by itself; a person checks who is asking and does the work. Staff close a request with `zella_update_customer_request` (a note is required; only owners/admins can resolve privacy requests). Hourly, `zella_check_customer_requests` alerts owners and admins once about overdue requests. The phone assistant logs them through the `log_customer_request` tool in the Assistant Tools workflow (it is told to promise nothing and read out no personal details). Not wired yet: a web form and a screen for staff.

## Customer messages (welcome, feedback, cancellation, status updates, service due, no reply)

Run `sql/zella_customer_touches.sql` (after `zella_followup_emails.sql` and `zella_inbound_replies.sql`). It adds `followup_tasks.vars`, wraps both claim functions so they return `vars`, adds 12 platform templates (text and email), and queues tasks from database triggers: a new person (not imports) gets a welcome, a completed appointment gets a feedback request 3 hours later, a cancelled one gets a confirmation. Record-status messages and service-due reminders are off until a business adds an automation (`record_status_update` with `trigger_config {"type_key":..., "messages":{"<status>":"<line>"}}`, or `service_due` with `{"days":180,"service":"cleaning"}`). A platform setting `customer_touches` (`{"welcome_new_customer":false}`) switches a kind off. The daily job `zella_queue_customer_touches` also queues the no-reply nudge. The file also fixes a bug where the text claim failed for any kind except waitlist offers. The Follow-up Texts and Emails workflows were updated in n8n (Plan and claim list).

## Reports, metrics and KPI alerts

Run `sql/zella_metrics.sql`. `zella_business_metrics(business, from, to, assigned_to)` returns calls, callbacks, appointments, leads, messages, follow-ups, knowledge gaps, requests and integrations for any dates (and optionally one team member); members can call it, so report screens can use it directly. `zella_platform_metrics` is for the operator. The daily job `zella_check_kpis` warns a business when missed calls, failed messages or no-shows jump against its usual week, and raises a platform alert when many automation runs fail. Report screens in the web app are not built yet.

## Staff operations and reliability

Run `sql/zella_staff_ops.sql`. Adds `zella_rate_limit` (for public forms and webhooks), escalation acknowledgement (`zella_acknowledge_escalation`, plus a 5-minute check that warns the team about a call nobody picked up), shift handover (`zella_create_handover`), offboarding (`zella_offboard_member`, never removes the last owner, writes an audit entry), recovery of stuck follow-ups and work held by inactive people (every 15 minutes), and `zella_validate_business_config` (what is missing for a business to work). All database; nothing here needs n8n.

## Website lead capture (forms, quotes, appointment and callback requests, chat, newsletter)

Run `sql/zella_lead_capture.sql`, then deploy the `website-lead` edge function (`web/supabase/functions/website-lead`, JWT check off, because visitors have no login). This one is **not on n8n**: it answers the visitor at once and the database does the rest. A business admin makes a form key with `zella_create_website_form(business, name, allowed_websites)`; the website posts JSON `{key, kind, name, phone, email, message, source:{utm_source,...}, marketing_consent, website_url (hidden spam field)}` to `<project>/functions/v1/website-lead`. `zella_capture_web_lead` checks the allowed websites, rate limits (5 a minute per visitor, 60 per form), spam (hidden field, link-stuffed text), phone and email, matches an existing person by phone or email, records first and last touch (campaign, source), records consent for newsletter signups, and creates a callback (phone) or an in-app notice (email only), which the existing assignment and acknowledgement rules then pick up. Urgent words raise priority. Failures are saved and raise a platform alert. `zella_lead_source_report` shows leads and wins by source and campaign. Embed code for a website and the dashboard screen for form keys are not built yet.

## Billing events, renewals and plan limits

Run `sql/zella_billing_events.sql`, then deploy the `billing-webhook` edge function (JWT check off; the provider's signature is the proof). It is written for Stripe-style events and answers 503 until the secret `STRIPE_WEBHOOK_SECRET` is set. It turns invoice paid/failed, subscription renewed/cancelled and refund/dispute events into plain types for `zella_process_billing_event`, which handles each provider event once (a repeat is ignored; a failure removes the row, raises an alert and answers 500 so the provider retries). Failed payments move the subscription to past due and tell the owners; paid ones bring it back to active and record the new period. The daily `zella_check_renewals` warns owners three days before a period ends and marks a period with no payment past due. `zella_entitlements(business)` and `zella_within_plan_limit(business, key, current)` read what the plan allows from `plans.limits` and `plans.features`. Not on n8n. Changing plans from the provider is not mapped yet (it needs a price-to-plan table), and the payment provider has not been chosen, so check the event shapes when it is.

## Callback controls, preferences, data rights, approvals

Run `sql/zella_ops_extras.sql`. All database. Callbacks can be reassigned, rescheduled (moved into calling hours) and cancelled. An hourly job posts a "Callbacks for today" digest to owners at 8 am business time, once a day. `zella_set_contact_preferences` changes a person's preferred channel and opt-outs (opt-outs are also written to the consent record). `zella_export_customer_data` returns everything held about one person and `zella_erase_customer` removes the personal details and message text while keeping the record skeleton and an audit entry (owners and admins only). `zella_get_call_recording` is an audited way for managers and above to open a recording or transcript; note it does not yet hide those columns from other team members' direct reads, which needs a web-app change. `zella_tenant_leak_check` lists business tables with no row-level security (currently none). `zella_request_approval` / `zella_decide_approval` give two-person approval for sensitive actions (a different owner or admin must decide); nothing calls it yet.

## Connection tests

`zella-connection-tests` (webhook `zella/run/connection-tests`) checks that Telnyx, Vapi and Resend keys still work. Supabase (`sql/zella_connection_health.sql`) decides which provider is due (`zella_claim_provider_checks`) and records the result (`zella_record_provider_check`); a failure raises a platform alert. Only the status number is kept, never the response body. It stays idle until the setting `provider_checks_live` is on. At go-live, put each provider key on its own "Check ..." box. Calendar token expiry is watched inside Supabase by `zella_check_connections`.

## Voice rules

`zella-voice-rules` (webhook `zella/vapi-voice`, workflow id GtH5oIq3xSHoKj8B) is the one tool the phone assistant uses during a call: `call_rules` with `action` = `rules` (open or closed, holiday), `message` (take a message), `emergency`, or `transfer`. Supabase decides everything (`sql/zella_voice_rules.sql`, function `zella_ai_voice`):
- Hours live in `business_hours` (several rows per day allowed) and holidays in `business_closures`. A business with no hours set is never treated as closed.
- Messages go to `call_messages` and create a callback; emergencies flag the call, alert the owners (urgent) and create an urgent callback; a transfer with nobody available becomes a callback.
- Settings come from the agent's `escalation_rules`: `transfer_number` (or the older `transfer_to.phone`), `fallback_number`, `transfer_enabled`, `transfer_open_hours_only`, `emergency_enabled` (or an `emergency` trigger), `emergency_keywords`, `after_hours_mode` (`take_message`, `book_only`, `info_only`).

## Inbound email, reply sorting and delivery receipts

- `zella-inbound-email` (webhook `zella/inbound-email?key=...`, workflow id aQhmKPDKYGDsfgGu): Resend posts an `email.received` event; the workflow fetches the email from Resend and hands it to Supabase (`zella_receive_inbound_email`, in `sql/zella_email_inbound.sql`). The database checks the secret key (same Vault secret as the email-events webhook), finds the business from the address, links the customer by exact email match, threads it into the inbox, sorts it (auto-reply, unsubscribe, complaint, cancel, reschedule, confirm, question, other) and tells the team. An unsubscribe reply stops marketing email at once.
- Each business gets its own inbound address `<token>@<inbound_email_domain>` (platform setting `inbound_email_domain`). Outgoing Zella emails use it as Reply-To once the domain is set; until then the business email is used as before.
- Text delivery receipts: the router now handles `message.delivered` and `message.delivery_failed` (`zella_record_sms_receipt`). Failed texts tell the business.
- Welcome email: when a business first goes live its owners get a welcome message through the normal owner email lane.

## Facebook, Instagram and WhatsApp (Meta)

All of it lives in `sql/zella_meta.sql` (already applied to the live database) and four workflows:
- `zella-meta-webhook` (`zella/meta`, id rSjRKz9IRNI85UmA): Meta cannot send our secret header, so this webhook is open and every event is checked by its signature. The raw bytes go to `zella_meta_receive`, which verifies `X-Hub-Signature-256` with the app secret in Vault (`zella_meta_app_secret`), saves each event once, and answers 403 on a wrong signature. The GET side answers Meta's set-up check using Vault `zella_meta_verify_token`.
- `zella-meta-leads` (lane `meta-leads`, id XVM1vpSwQ7ASEHS5): fetches each lead form entry from Meta, then `zella_meta_capture_lead` saves it as a website-style lead (customer matched by phone/email, so a person coming from several channels is one customer), records the campaign, and starts the normal new-lead callback chain. A call is only made with consent (form consent or the owner's confirmed lead-form consent), inside calling hours, and stops on booking, reply or opt-out; retries follow the business's settings.
- `zella-meta-sender` (lane `meta-sender`, id I92yWMNMrRSFpHsj): sends queued replies. Messenger/Instagram free text only within 24 hours of the customer's last message; WhatsApp needs a template outside that window. Failures retry with back-off; a rejected token marks the page "needs reconnect" and alerts the owners.
- `zella-meta-health` (lane `meta-health`, id ydBUMg7eXr9kc8hJ): every 6 hours checks each connection and syncs WhatsApp templates.
- Messages and comments: stored in the inbox as conversations (channels messenger, instagram, whatsapp). First contact gets an acknowledgement (if the business leaves it on); staff reply with `zella_meta_staff_reply`, which also takes the conversation over from the AI. Comments containing a business keyword get a private reply. No AI auto-replies on social.
- Page tokens are kept in Vault (`meta_token_<page_id>`), written only by `zella_meta_store_connection` (service role). Set these workflows to not save successful executions because the token passes through them.

## Website knowledge crawler

`sql/zella_website_crawler.sql` (applied to the live database) + workflow `zella-website-crawler` (lane `website-crawl`, id 6zSkOfG8EeRU7HcY).
- The owner adds their site (`zella_website_add_source`) and approves it (`zella_website_approve_source`: confirms it is their website). Only approved sites and approved pages are ever read. Pages found later (sitemap, links on approved pages) wait as "pending" until the owner approves them (`zella_website_set_page`), unless the owner turned on auto-approve for new pages of that site.
- Safety: addresses must be http/https, no login in the address, no numeric/internal hostnames, ports 80/443 only, and the same site as the one approved. This is checked in the database and again in n8n before each fetch; redirects are not followed automatically (a redirect to the same site is recorded as "moved", anything else is a failure). Honest limit: n8n cannot check where a hostname resolves to, so a site owner who points their own DNS name at an internal address is not stopped by name rules alone.
- Reading: sitemap (`/sitemap.xml`, one level of sitemap index) + approved pages, every 7 days by default (6 hours to 30 days), up to 25 pages per site (max 100). Weekly cost is about 1 run per week per business when nothing changed.
- What it finds (heuristics, no AI needed): questions with answers (FAQ), policies (cancellation, refund, deposit...), services/prices, opening hours. Everything becomes a DRAFT knowledge item with a link to its page; the owner reviews it like any other draft before the assistant can use it.
- Changes: a page whose words changed flags the knowledge made from it ("needs a check") and creates a new draft beside the old answer (linked as a conflict). A removed page (404/410 twice) or an unreadable page (3 failures) tells the owner. Opening hours that differ from hours the owner wrote by hand are linked as a conflict. Website answers not confirmed for three crawl periods are flagged as stale.
- Version history of every knowledge item is kept in `knowledge_versions`.
- Stopping a site (`zella_website_remove_source`) pauses it and ignores its pages; nothing is deleted.

## Ops automation and staff texts
Run `sql/zella_staff_sms.sql` and `sql/zella_ops_automation.sql` (both safe to repeat), then re-run `sql/zella_dispatcher.sql`.
- Settings rollback, a plain change list, knowledge rollback, 1-in-N spot checks of AI answers, wrong-answer reports, a daily team summary and a daily reconciliation run from Supabase. No n8n box is involved.
- **Zella - Staff Texts** (`staff-sms` lane, workflow `1MWk3sY3c5d1oYEx`, unpublished) sends urgent alerts by text to team members who turned it on for themselves (`zella_set_my_sms_alerts`, needs a phone number on their profile). Max 5 per business per hour. Nothing is claimed until `sms_live` is true and `sms_from_number` is set. Put the Telnyx key on the "Send via Telnyx" box only.

## Social booking chat
Run `sql/zella_social_flow.sql` after `zella_meta.sql` (safe to repeat). Off by default; an owner turns it on per page with `zella_meta_set_flow(business, page_id, true)`.
When someone on Messenger, Instagram or WhatsApp asks to book or for a price, the chat asks for a phone or email (creating the lead), asks what they need (marks the lead qualified), offers up to 3 real open times, and books the one they reply with. It steps aside the moment a person replies, the customer asks for a person or complains, or the answer is anything it does not expect. Assignment to a team member is the existing round-robin. It uses the same Meta sender, so nothing sends until the Meta workflows are published.

## Retention
Run `sql/zella_retention.sql` (safe to repeat), then re-run `zella_dispatcher.sql`. Once a day, regular customers (3+ completed visits) who are overdue by half again their usual gap, and at least 30 days since the last visit, get a staff task ("Regular customer is overdue"), at most once per 90 days. It never messages the customer. `zella_retention_summary(business)` gives the dashboard numbers (regulars, drifting, returning).

## More message types
Run `sql/zella_message_types.sql` (safe to repeat; needs `zella_customer_touches.sql`), then re-run `zella_dispatcher.sql`. Email and text versions of: reschedule confirmation (a minute after an appointment moves), booking follow-up (an hour after a booking made 2+ days ahead), service completed (a job record marked completed, unless the owner wrote their own wording), and a lead sequence: day 1 `lead_follow_up`, day 3 `no_response_follow_up`, day 7 `lead_final_follow_up` (leads with no appointment only). The Follow-up Emails and Follow-up Texts workflows already know the new kinds (updated in n8n). Any kind can be turned off in `platform_settings` `customer_touches`.

## Messaging extras
Run `sql/zella_messaging_extras.sql` (safe to repeat; after `zella_message_types.sql`), then re-run `zella_dispatcher.sql`.
- **Unsubscribe:** marketing email now sends when `app_base_url` is set and the person opted in. Every one ends with a link to `/u/<code>` (page: `web/src/Unsubscribe.jsx`) and carries a `List-Unsubscribe` header. Unsubscribing stops marketing email only; booking messages still reach them.
- **Preferred channel:** `zella_set_customer_channel(business, customer, 'sms'|'email')`; all customer messages use it when that channel works.
- **Failed texts:** a text that failed for good goes by email once (hourly job), and 5+ failed texts in an hour raise a platform alert.
- **Reactivation by email:** set the lead-reactivation automation's channel to `email` (needs marketing opt-in).
- **Reports:** `zella_preview_template`, `zella_message_summary`, `zella_campaign_report` (leads, qualified, booked, won by source and campaign).

## Social reply window and WhatsApp templates
Run `sql/zella_meta_window.sql` (safe to repeat; after `zella_meta.sql`). When an automatic reply is dropped because the 24-hour window closed, the team now gets a notification instead of silence. On WhatsApp a team member can send an approved template that has no fill-in values with `zella_meta_staff_template(conversation, template_name)`. The Meta Sender workflow (updated in n8n) sends it. Writing new templates is still done in Meta Business Manager; the Meta Health workflow syncs their approval status.

## Knowledge extras
Run `sql/zella_knowledge_extras.sql` (safe to repeat), then re-run `zella_dispatcher.sql`. The website reader now suggests `price` ("Haircut - $45") and `product` answers as drafts, like every other suggestion (Website Crawler workflow updated in n8n). A daily check finds two approved answers that disagree (same kind and title, or two sets of opening hours), flags the newer one and tells the owner once.

## Staff extras
Run `sql/zella_staff_extras.sql` (safe to repeat), then re-run `zella_dispatcher.sql`. Time off: `zella_request_time_off` (any member) and `zella_decide_time_off` (managers); approval blocks the calendar and flags existing appointments for rebooking. Hourly: an open task past its due time (grace `task_overdue_grace_minutes`, default 60) tells the person it belongs to, or the owners if unassigned, once; after `task_escalate_hours` (default 24) it becomes urgent and the owners are told.

## Security and operations extras
Run `sql/zella_security_extras.sql`. All database.
- Erasing a customer now needs a second owner or admin to approve it (`zella_request_approval` / `zella_decide_approval`, action `erase_customer`, used once within two days). A business with only one owner/admin is not blocked; the erase is still logged.
- `calls_view` returns calls with recording and transcript empty below manager. `zella_lock_call_columns()` then stops direct reads of those two columns; run it only after the web app reads calls through the view (see `docs/FRONTEND_TODO.md`).
- `zella_tenant_leak_check` now also finds open policies and anonymous read access; `zella_run_tenant_check` (daily) raises a critical platform alert if anything shows.
- `zella_notify_message_failures` (daily) tells owners how many messages failed in the last day.
- `zella_failed_work` / `zella_retry_failed` (managers and above) list failed follow-ups, reminders and social replies and send one back to try again; each retry is logged.
- `zella_remind_integrations` (weekly) reminds active businesses without a phone number or calendar.
- `zella_workflow_effectiveness` shows, per kind of automatic message, how many were sent, failed, skipped and followed by a booking within 7 days.

## Data-rights requests
Run `sql/zella_data_rights.sql`. All database. `zella_log_data_rights_request` records a customer asking to see, correct, stop the use of, or erase their information (30 day deadline, owners told). Owners/admins finish it with `zella_fulfil_data_rights_request` (export returns the data; erase runs the erase, which needs a second approval where there are two owners/admins) or `zella_reject_data_rights_request` (reason required). A daily job reminds owners when a request is due within a week or late. Correct and stop-use requests are handled by hand and then marked done.

## Inbound call wrap-up
Run `sql/zella_inbound_calls.sql`. The **Call Results** workflow now also handles calls customers make to the business (Vapi call type inbound): it passes the end-of-call report to `zella_record_inbound_call`. That function keeps the summary, length, recording and transcript, links the call to the customer (exact phone match; an unknown caller who left a message, needs a callback or booked becomes a lead), works out the outcome when nobody set one (booked, left message, callback needed, handled, hung up), and creates a callback if the caller asked for one and nothing was saved during the call. In the Vapi assistant's analysis plan, an optional structured field `callback_requested` (true/false) makes this more reliable; without it the summary text is searched. At the start of a call the assistant's `rules` answer carries a `caller` block (known or not, first name, repeat caller, whether there is an upcoming appointment or open callback) so it can greet people by name without reading out details. Every 5 minutes `zella_remind_upcoming_callbacks` tells the person looking after a callback (or the owners) 15 minutes before it is due. The new HTTP box needs the Supabase credential assigned by hand, like the others.

## Time limits and rate limits
Every workflow stops a run after 300 seconds (already set on the live workflows), and every HTTP box in the repo's workflow files has its own time limit (30 s, 60 s for the AI box). The live boxes created earlier keep the default per-box limit, so re-import from `n8n/workflows/` if you want the per-box limits too. A 429 ("too many requests") from the text or email provider is not a final failure: the follow-up is retried after 30 minutes (15 for other errors), within the task's normal attempt limit. Reminders and Meta replies already retry through their own queues.

## Text replies that act
Run `sql/zella_reply_actions.sql` (after `zella_reschedule.sql` and `zella_inbound_replies.sql`). It replaces the incoming-text handler the router already calls, so no workflow changes. On top of STOP / START / HELP: a known customer replying CONFIRM / YES / Y / OK with an appointment in the next 7 days gets it marked confirmed and a thank-you text; RESCHEDULE / CHANGE / MOVE (or "need a new time", "can't make it") creates a high-priority callback, queues the "we have let the business know" text and warns staff; words like urgent / emergency / asap raise the staff notice to a warning. Single letters C and R are deliberately not special. Everything else is saved and shown to staff as before.

## Industry wording
Run `sql/zella_industry_templates.sql`. Reminder texts and emails for dental (arrive early), fitness (class spot), healthcare (administrative only: no service name, no health details, "do not reply with health details") and beauty salons, plus a salon waitlist-offer text. The reminder and waitlist machinery is shared by all industries; a business-level template still wins over these.

## No marketing texts
Run `sql/zella_sms_no_marketing.sql`. Telnyx 10DLC is being registered as customer care, so any text marked marketing (such as lead reactivation) is refused with reason `sms_marketing_off` unless the platform setting `sms_marketing_allowed` is set to true. The same message can still go by email.

## Unanswered-question insights
Run `sql/zella_knowledge_insights.sql`. All database. A question asked 3 or more times (`knowledge_repeat_threshold`) is flagged to owners once (hourly job). `zella_knowledge_gap_report` returns the top open questions and counts, and a weekly job nudges owners who have open questions. When the assistant reports two or more unanswered questions on one call (`ai_low_confidence_questions`), the call is flagged for a person (`escalation_reason` low_confidence) and a callback is created. Knowledge tables are already isolated per business by row security; the daily tenant check watches that.

## Customer records
Run `sql/zella_customer_records.sql`. All database. `zella_staff_add_customer` adds a person through the same duplicate check as the assistant (an exact match returns the existing person; a likely match goes to duplicate review). Changes to name, phone, email, do-not-contact choices, preferred channel and status are written to the audit log as field names only, and a changed phone or email that now matches another customer opens a duplicate review. A daily scan finds people who share a phone number or email. `zella_resolve_duplicate` now merges such pairs with `zella_merge_customers` (owners, admins and managers): calls, texts, appointments and the other records move to the kept person, blanks are filled, do-not-contact choices are combined, and the other record is archived with its phone and email removed. `zella_customer_timeline` returns calls, texts, emails, appointments, callbacks, tasks and record changes in one newest-first list.

## Appointment flow
Run `sql/zella_appointment_flow.sql` (and re-run `zella_reply_actions.sql`). All database. A new appointment (or an appointment request to confirm) notifies the assigned person, or the owners when nobody is assigned. A person who is not an owner or admin is also told when their appointment is moved or cancelled. A customer can text HERE or ARRIVED from 30 minutes before to an hour after the start; they are marked arrived and the assigned person is told. Hourly, an appointment that ended over 2 hours ago with nothing recorded gets one task ("Did X come in? Mark completed or no-show"); nothing is marked completed or no-show automatically. The booking confirmation to the customer already existed.

## Monitoring (checklist 90, 268, 269, 309) - `sql/zella_monitoring.sql`
- Every 15 minutes `zella_check_response_times()` tells owners once when texts (60+ min) or emails (4 hours) are waiting for a reply during open hours. Setting: `response_time_minutes`.
- `zella_response_time_report(business, days)` gives median/average first reply time (owner/admin/manager).
- `zella_integration_summary(business)` lists phone, calendar, social and message failures; `zella_platform_health_summary()` is the platform admin view.
- `zella_retry_event(id)` (platform admin) sends a failed event back; businesses use `zella_retry_failed`.
- `zella_open_incident(title, detail)` / `zella_resolve_incident(id, note)` notify every active business owner.

## Reconnection (checklist 258) - `sql/zella_reconnect.sql`
A calendar that loses access now tells the owners at once (run after `zella_calendar_sync.sql`). Daily `zella_remind_reconnects()` nags owners about a calendar or Facebook/Instagram connection broken for over a day. `zella_connections_to_reconnect(business)` feeds the Reconnect buttons. Doing the sign-in itself needs the Google and Meta apps.

## Lifecycle (checklist 301, 305, 308) - `sql/zella_lifecycle.sql`
Owners are told when the account is paused, switched back on or cancelled. A cancellation scheduled for a date (`cancel_at`) takes effect daily via `zella_apply_scheduled_cancellations()` (3-day reminder first); cancelling stops automations, callbacks, follow-ups and reminders but keeps every record until `retention_until`. Hourly `zella_recover_provisioning()` marks setup steps stuck for 30+ minutes as failed so an admin sees and retries them.

## Audit and permission checks (checklist 313, 314, 326) - `sql/zella_audit_permissions.sql`
Changes to team roles, the AI agent, automations, platform settings and suspension/cancellation are written to `audit_logs` as `privileged_*` (only which fields changed - never values - except roles/status). Daily `zella_run_permission_check()` raises an urgent platform alert if a signed-out visitor can call a function that is not on the short public list, or a table policy lets everyone in. Tenant isolation is checked daily by `zella_run_tenant_check` (already built).

## Staff invitations and approvals (checklist 184, 162) - `sql/zella_staff_invites_approvals.sql`
Owners/admins call `zella_invite_staff(business, email, name, role)` (only owners can invite admins); the person signs up with that email and the app calls `zella_accept_staff_invitations()` after sign-in, which adds them and tells the inviter. Cancel/resend with `zella_cancel_invitation` / `zella_resend_invitation`. Invitation reminders reuse the existing `zella_check_invitations` path (the Owner Emails workflow wording says owner - adjust the template for staff). Approvals: hourly `zella_sweep_approvals()` expires old requests and nudges approvers after a day; the requester is told the decision; `zella_pending_approvals(business)` feeds the Approvals screen.

## Industry automations (checklist 196-254, 235) - `sql/zella_industry_engine.sql` + `sql/zella_industry_presets.sql`
One engine, many industries. A rule is a row in `automations` with one of these `trigger_type`s: `record_status_action` (when a record is created in / moves to a status), `record_due_reminder` (before/after the record's due date), `record_stale` (stuck in a status), `appointment_followup` (N days after a completed visit), `seasonal_reminder` (once per season), `service_due`. Each rule can queue a customer message (sent only when sms_live/email_live and consent allow), create a staff task, and/or alert the owners. Hourly `zella_run_industry_timers()` handles the timed ones (each fires once per record; `industry_automation_runs` remembers). When a business's industry is set, `zella_apply_industry_automations` copies that industry's presets (68 rules across 18 industries, built on the record types in `industry_crm_presets`); owners can pause/edit them or add their own with `zella_save_industry_rule` (blocks prices and promotional wording). For hospitality, set a stay's `due_at` to the arrival date, then to the checkout date at check-in. For emergency intake (electrical, plumbing), a job created with `data.priority = 'emergency'` alerts the owners and creates an urgent task.
Items 200 (stylist bookings: the assigned stylist is notified of new bookings) and 246 (restaurant waitlists: waitlist offers) use machinery that already existed.

## Call integrity (checklist 2, 4, 6, 13, 180, 188) - `sql/zella_call_integrity.sql`
- A trigger on `calls` turns an instant hang-up (<= `missed_call_max_seconds`, default 6, nothing said) into a missed call, so the existing missed-call callback fires. If `ended_reason` shows the assistant or phone system errored, the call is marked needs-human (urgent callback via the existing rule) and an hourly-deduped platform alert is raised.
- Every 5 minutes `zella_sweep_open_calls()` closes inbound calls that never reported an end (2 hours). Hourly `zella_verify_calls()` flags finished AI calls with no summary (the call-result workflow may be failing).
- Hourly `zella_recover_knowledge()` retries knowledge updates the assistant never confirmed (3 tries), then marks them failed and tells the owners.
- When staff move an appointment, the customer gets a 'moved' message (skipped if the business already re-sends appointment confirmations, and for customer/AI-requested changes).
- Items 2 (call logic), 17 and 18 (callback creation and scheduling) were already working through the call-result plan, the voice rules and `zella_create_callback` (which moves a requested time into calling hours); they are now covered by tests and marked built.

## Receptionist brain - `sql/zella_brain.sql` + `workflows/zella-brain-tools.json`
The language model chooses words and tools; the database decides what is true and what was done.
- **One webhook for every tool** (`/webhook/zella/vapi-brain`, same `X-Zella-Secret`): 14 tools - search_knowledge, check_open_hours, lookup_caller, update_caller, check_availability, book_appointment, find_my_appointments, reschedule_appointment, cancel_appointment, take_message, report_emergency, transfer_to_human, request_follow_up, report_unanswered_question. The older three workflows still work; new setups should use this one.
- **`zella_ai_tool`** is the only door: it finds the business (from the call or the called number), refuses unknown tools or tools the owner switched off (`business_context.disabled_tools`), requires the caller's yes (`confirmed=true`) before book/move/cancel, makes a repeated call a no-op (tool-call id), checks the result is really in the calendar before saying booked/moved/cancelled (otherwise a high-priority task is created and the assistant is told not to say it is done), and writes `ai_tool_calls` (tool, result, verified; never the arguments).
- **Knowledge** is searched per business with built-in text search over ready items only (`zella_brain_search`): result says `confirmed`, `partial` or none, with source item and version. Nothing found logs the question for the owner and tells the assistant not to guess. No vector database is needed at this size; swap the function later if knowledge grows large.
- **The prompt** (`zella_brain_prompt`) is built from that business only (hours, wording, closures, the owner's own instructions, topics it can answer) plus safety rules by industry (no diagnosis for dental/health, no promised arrival times for trades, no legal or financial advice). `zella_assistant_config` returns the full Vapi assistant (model, prompt, tools). Nothing is sent to Vapi from here.
- **Accuracy checks:** add rows to `ai_eval_cases` (question, words the answer must contain, or expect_none) and run `zella_brain_run_evals(business)`.
- Not built: sending texts or emails directly from a call (use request_follow_up; messages go through the normal follow-up rules), uploading documents (the website crawler and Knowledge page already feed knowledge), pushing the config into Vapi.

## Call intelligence - `sql/zella_call_intelligence.sql` + `workflows/zella-call-intelligence.json`
After a call ends with a real transcript it waits in `call_insights`. When `call_intel_live` is true the dispatcher starts the workflow (webhook `/webhook/zella/run/call-intel`), which asks an AI to read the transcript and returns: intent, mood, urgency, a 2-sentence summary, details the caller gave, and what is still unresolved.
- **The AI only suggests.** The database checks every field (fixed lists for intent/mood/urgency, email and phone must look real, lengths capped, unknown fields dropped). Automatic effects are only: a team task per unresolved item (once per call; a callback the call wrap-up already made is not doubled; complaints and urgent calls are high priority), an urgent owner alert if the call sounded like an emergency, and the call's summary when it had none. **Customer records are never changed by the AI**: staff accept a suggestion (fills blank name/email only) or dismiss it (`zella_review_call_insight`).
- Transcript text is treated as data: the prompt says to ignore instructions inside it, and nothing in the answer can run anything.
- Safety: off by default; no AI key in the workflow (add it by hand in the "Ask AI" box at go-live, header `x-api-key`); 3 tries per call; monthly limit per business (`call_intel_monthly_limit`, default 300, then skipped); calls of suspended/cancelled businesses are skipped.
- Not built: a screen to show suggestions (staff can read them with `zella_call_insights_list`; the Calls page needs a panel - see `docs/FRONTEND_TODO.md`), summaries for calls with no transcript, and mood trends.

## Admin alerts (Zella - Admin Alerts)
Run `sql/zella_admin_alerts.sql`. Webhook `zella/run/admin-alerts`, started by the dispatcher when open platform alerts have not been emailed and email is live. `zella_claim_admin_alert_email` hands out up to 25 alerts (urgent first) with the active admins' addresses; the workflow sends one plain-text digest through Resend and reports back with `zella_finish_admin_alert_email` (a failed send is retried up to 3 times; the alert itself stays open in the dashboard either way). Offers & Promotions raise alerts for: ending soon, limit nearly reached, limit reached, unusual claims, could not go live, ended (summary), and a failed schedule job.

## Spam Response (`spam-response` lane, workflow `a7Nfsi9mkQbBmc0L`, unpublished)

**What never waits for n8n:** spam detection and scoring, call screening, booking holds, block lists, rate limits, who may see what, and saving the incident. All of that happens in the database (and the `voice-rules` edge function for calls) before this workflow is even called. If n8n is slow or down, a blocked caller is still screened and every incident is still recorded.

Flow: Run now -> Claim work (`zella_spam_claim_work`) -> Evaluate severity -> log / alert / investigate -> Check repeat offender -> (Ask AI) -> Apply approved policy (`zella_spam_finish_work`); weekly reports go Build report -> Save report (`zella_spam_save_report`).

- **Off by default** (`spam_workflow_live`). Off: incidents are handled in the database exactly as before (high-risk alerts written straight away). On: medium and high incidents are queued; low risk never costs a run.
- **The database decides.** The workflow suggests a route; `zella_spam_finish_work` re-reads the facts, decides severity itself, notifies once per incident within the business's hourly cap, and applies only one consequential action: a 24-hour, channel-only restriction when the business has auto-restrict on and its team already confirmed this sender as spam twice (never after a "not spam"). A sender confirmed at 3+ businesses raises one platform alert; admins decide on a global rule.
- **AI is advisory.** Only medium-risk texts and emails, only when `spam_ai_live` is on and the business opted in, within `spam_ai_monthly_limit` per business, once per incident. Names, numbers, emails and link paths are removed before anything is sent. The label is shown to the team as a suggestion; it never blocks or changes an incident. AI down or nonsense: the incident is processed without it.
- **Retries and duplicates.** Each claim has a token; a replayed or late result is refused. A failed step is retried with a growing delay (5, 20, 45 minutes), then marked failed. A run that never reports back is picked up again after 10 minutes. Weekly reports are posted once per business per week.
- **Fallback.** If the workflow hasn't handled a high-risk incident within 15 minutes (off, n8n down, gave up), `zella_spam_hourly` sends the notification from the database, once.
- **Tenant data.** The workflow gets one business's incident, its policy and counts about the sender elsewhere (never another business's name or messages).
