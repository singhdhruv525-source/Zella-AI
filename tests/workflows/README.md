# Launch workflow, end to end

`salon_launch.mjs` runs a beauty salon's workflow from the first call to the rebooking reminder. Production's first business is a salon in testing. The run is on an isolated copy of the staging database; build it first with `tests/staging/run.sh`.

It checks the full chain at every step: customer request → correct record → assigned owner → confirmed action → customer update → audit trail → failure recovery.

**How it runs**
- The AI receptionist's real tool calls are used: look up, save the caller, check times, book.
- Staff actions run as the actual roles, under row security: arrival, in service, completed, colour card, money.
- Both texting pipelines run with their shipped n8n Code-node logic (`n8n/src`):
  - first with texting off, the dry run production is in today;
  - then with a stand-in for the SMS provider that accepts or refuses.
- Nothing is sent.

At the end it prints the exact texts the client would receive.

```bash
node tests/workflows/salon_launch.mjs
```
