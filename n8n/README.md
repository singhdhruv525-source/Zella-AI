# Zella n8n workflows

Eight workflows so far. All are shared by every business and every industry. Nothing business-specific lives in n8n: the database holds the rules, n8n moves the work.

| File | What it does |
|---|---|
| `workflows/zella-event-gateway.json` | Receives events at `POST /webhook/zella/events`, checks them, stores them once (`zella_ingest_event`), replies quickly. Repeats are recognised and stored only once. |
| `workflows/zella-schedulers.json` | Runs 11 timed database checks (see below). A failed check raises one grouped alert in the platform alerts list. |
| `workflows/zella-sms-sender.json` | Every minute: takes due appointment reminders and confirmations, checks consent and the template in the database, logs the message, and sends it through Telnyx **only when live**. In dry-run (the default) nothing is sent. |
| `workflows/zella-followup-texts.json` | Every minute: takes due follow-up **text** tasks (no-show, post-visit thank-you, quote follow-up, reactivation, and the fallback text after a callback runs out of tries) and runs them through the same consent check, logging and dry-run switch as the reminders. Call tasks are never picked up. |
| `workflows/zella-email-sender.json` | Every minute: takes due appointment confirmations and reminders whose channel is **email** and runs them through the same pipeline as the text sender: consent, template, safe HTML, logging, duplicate protection, dry-run switch. Sends through Resend **only when live**. |
| `workflows/zella-followup-emails.json` | Every minute: takes due follow-up tasks whose channel is **email** (same kinds as the follow-up texts) through the same consent check, logging and dry-run switch. A task moves to email when the customer cannot be texted but can be emailed. |
| `workflows/zella-owner-emails.json` | Every 5 minutes: emails owner notifications (daily summary, weekly review, any warning or urgent alert) to the right people, honouring each person's email preferences. Same dry-run switch and Resend box as the email sender. |
| `workflows/zella-event-router.json` | Every minute: takes up to 20 stored events (`zella_claim_events`), runs the right handler, writes an execution record, and reports the result (`zella_complete_event`). Temporary failures are retried by the database with a growing delay. Permanent ones go to the dead-letter list. |

## What the router handles today

| Event | What happens |
|---|---|
| `message.received` (sms) | STOP, START and HELP keywords are applied through the consent record |
| `customer.opted_out` | Opt-out recorded and the customer's do-not flag switched on |
| `integration.disconnected` | An urgent platform alert is raised (repeats are grouped) |
| `integration.reconnected` | The alert is resolved |
| Anything else | **Not silently ignored.** It is sent to the dead-letter list as "no handler yet" so the gap is visible |

Handlers for reminders, callbacks, SMS sending, email, Meta and the website are not built yet.

## Timed jobs

| Every | Jobs |
|---|---|
| 5 minutes | overdue leads, expire held slots, expire waitlist offers, transfer failures |
| 15 minutes | quote follow-ups |
| hour | daily summaries (a business is posted once, when its own local time is 8am) |
| day, 04:00 (n8n time zone) | lead reactivation (up to 200), setup incomplete, trials, payment policy |
| Monday, 08:00 (n8n time zone) | weekly reviews |

Not in this workflow, on purpose: `zella_calls_to_callbacks` and `zella_queue_no_show_followup` are database triggers and fire by themselves; `zella_check_invitations` needs the email sender; `zella_retention_due` only lists businesses and nothing deletes yet.

Each job returns a count. With no businesses yet, every count is 0, so the behaviour with real data is untested. Alerts for a failing job stay open until someone resolves them.

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
- **C, CONFIRM, CONFIRMED, YES, Y** confirm the customer's next upcoming appointment, cancel the pending "please confirm" reminder, and queue a thank-you text. (YES still means START for someone who opted out.)
- **R, RESCHEDULE** mark the appointment as needing a new time, create a callback task in "reschedule requested" (it never auto-calls), alert the business owners (a warning, so it is also emailed), and queue an acknowledgement text.
- **Anything else** shows a "New text from ..." notice in the app.
- Replies to a customer's own message go out straight away (no calling-hours delay) and are never moved to email.
- **Not covered yet:** letting the customer pick a new time by text, a staff reply screen, and replies to emails.

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
2. Import all eight files (Workflows, Import from file). Open each node that shows a missing credential and select the credential above.
3. Switch the gateway on first, then the router, then the schedulers, then the SMS sender, the follow-up texts, the email sender, the follow-up emails and the owner emails. All import as inactive.

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

`node n8n/test.mjs` runs 231 checks: the exact Code-node logic that ships, plus structure checks on all eight files (connections, node references, no pasted keys).

**Not verified:** the files have not been imported into a running n8n. The workspace could not install n8n. Import them into your n8n and report anything that does not open cleanly. Node versions used: Webhook 2, Code 2, HTTP Request 4.2, IF 2, Schedule Trigger 1.2, Respond to Webhook 1.1.

The database calls these workflows make were tested against the real database (rolled back afterwards).

## Changing the workflows

Edit the Code files in `src/`, then run `node n8n/src/build.mjs` and `node n8n/test.mjs`. Do not hand-edit the JSON.
