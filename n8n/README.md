# Zella n8n workflows

Three workflows so far. Both are shared by every business and every industry. Nothing business-specific lives in n8n: the database holds the rules, n8n moves the work.

| File | What it does |
|---|---|
| `workflows/zella-event-gateway.json` | Receives events at `POST /webhook/zella/events`, checks them, stores them once (`zella_ingest_event`), replies quickly. Repeats are recognised and stored only once. |
| `workflows/zella-schedulers.json` | Runs 10 timed database checks (see below). A failed check raises one grouped alert in the platform alerts list. |
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
| day, 04:00 (n8n time zone) | lead reactivation (up to 200), setup incomplete, trials, payment policy |
| Monday, 08:00 (n8n time zone) | weekly reviews |

Not in this workflow, on purpose: `zella_calls_to_callbacks` and `zella_queue_no_show_followup` are database triggers and fire by themselves; `zella_check_invitations` needs the email sender; `zella_retention_due` only lists businesses and nothing deletes yet.

Each job returns a count. With no businesses yet, every count is 0, so the behaviour with real data is untested. Alerts for a failing job stay open until someone resolves them.

## Setup (once)

1. In n8n, create two credentials:
   - **Zella Supabase service role**: type *Custom Auth*. JSON: `{"headers": {"apikey": "<service role key>", "Authorization": "Bearer <service role key>"}}`. Use the service role key from Supabase, Settings, API. It stays in n8n only. Never put it in the website or in a workflow file.
   - **Zella gateway secret**: type *Header Auth*. Name `X-Zella-Secret`, value a long random string. Every system that posts events must send this header.
2. Import all three files (Workflows, Import from file). Open each node that shows a missing credential and select the credential above.
3. Switch the gateway on first, then the router, then the schedulers. All import as inactive.

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

`node n8n/test.mjs` runs 78 checks: the exact Code-node logic that ships, plus structure checks on all three files (connections, node references, no pasted keys).

**Not verified:** the files have not been imported into a running n8n. The workspace could not install n8n. Import them into your n8n and report anything that does not open cleanly. Node versions used: Webhook 2, Code 2, HTTP Request 4.2, IF 2, Schedule Trigger 1.2, Respond to Webhook 1.1.

The database calls these workflows make were tested against the real database (rolled back afterwards).

## Changing the workflows

Edit the Code files in `src/`, then run `node n8n/src/build.mjs` and `node n8n/test.mjs`. Do not hand-edit the JSON.
