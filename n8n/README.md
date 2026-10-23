# Zella n8n workflows

Seven workflows. All are shared by every business and every industry. Nothing business-specific lives in n8n: the database holds the rules, n8n moves the work.

**Nothing in n8n runs on a timer.** n8n Cloud's Starter plan allows 2,500 runs a month, and a workflow that wakes every minute uses about 43,000. So a Supabase job (`zella_dispatch_n8n`, see "The dispatcher" below) checks every minute whether anything is due and calls the matching workflow only then. The timed database jobs run inside Supabase too.

| File | What it does |
|---|---|
| `workflows/zella-event-gateway.json` | Receives events at `POST /webhook/zella/events`, checks them, stores them once (`zella_ingest_event`), replies quickly. Repeats are recognised and stored only once. |
| `workflows/zella-sms-sender.json` | Takes due appointment reminders and confirmations, checks consent and the template in the database, logs the message, and sends it through Telnyx **only when live**. In dry-run (the default) nothing is sent. |
| `workflows/zella-followup-texts.json` | Takes due follow-up **text** tasks (no-show, post-visit thank-you, quote follow-up, reactivation, and the fallback text after a callback runs out of tries) and runs them through the same consent check, logging and dry-run switch as the reminders. Call tasks are never picked up. |
| `workflows/zella-email-sender.json` | Takes due appointment confirmations and reminders whose channel is **email** and runs them through the same pipeline as the text sender: consent, template, safe HTML, logging, duplicate protection, dry-run switch. Sends through Resend **only when live**. |
| `workflows/zella-followup-emails.json` | Takes due follow-up tasks whose channel is **email** (same kinds as the follow-up texts) through the same consent check, logging and dry-run switch. A task moves to email when the customer cannot be texted but can be emailed. |
| `workflows/zella-owner-emails.json` | Emails owner notifications (daily summary, weekly review, any warning or urgent alert) to the right people, honouring each person's email preferences. Same dry-run switch and Resend box as the email sender. |
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
- **The dispatcher, every minute.** It counts what is due for each worker workflow (events, text reminders, email reminders, follow-up texts, follow-up emails, owner emails) and calls that workflow's webhook (`/webhook/zella/run/<name>`) only if the count is above zero. It counts only the kinds the workflow really handles, so unhandled work can never make it call n8n forever.
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
