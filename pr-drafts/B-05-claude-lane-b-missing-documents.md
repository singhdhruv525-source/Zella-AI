Verification: Missing documents tab with Request documents (UI-11)
base: claude/lane-b-retention-due

## What and why

**UI-11.** Verification listed only documents that had been uploaded, so a business that never uploaded anything was invisible.

- `onboarding.ts` exports a shared `missingDocuments()` helper, and `documentsReady` uses it, so both agree on what is missing.
- `lifecycle.ts`. The new actions go in Lane B's one module, as the supervisor and critic asked, not in platform.ts. Both need businesses.manage, like `documents_queue`.
  - `documents_missing` lists every business that isn't cancelled and still misses a required kind (none uploaded, or only rejected copies). Live ones are flagged `live` and shown as **Live without documents**. Each row has its last request time, read from the newest `business.documents_requested` audit entry, so there is no new table. If the documents table is missing, it reports `available: false`.
  - `document_request` refuses an unknown or cancelled business (404), a business with every document (409), and a second request within `DOCUMENT_REQUEST_COOLDOWN_HOURS = 24` (429). It renders S4 (`_shared/businessEmails.js`, strict) for the owner: the newest owner invitation's email, or else the business email. It queues S4 through `zella_queue_platform_email` as mandatory, with a unique dedupe key.
  - Without the outbox (PGRST202 or a missing table), it records the request and answers `not_installed`. Without any address it answers `no_address`. Every request is audited with what was missing and what happened to the email.
- Web: Verification gets a **Missing documents** tab (`web/src/MissingDocuments.jsx`). It has a Request documents button that shows the cooldown, and a notice that says honestly what happened: "queued and goes out once email sending is live", or "Email isn't live yet, so tell the owner yourself". The helpers are in `web/src/businessLifecycle.js`.

Nothing is sent: the outbox only queues, and the sender sends nothing until email_live, the sender address and the provider key are set.

## Defaults taken (owner can change)
- Live businesses without documents are listed, as "Live without documents" (owner_decisions UI-11, recommended).
- At most one documents request per business per 24 hours (`DOCUMENT_REQUEST_COOLDOWN_HOURS`).
- The recipient is the newest owner invitation's address, or else the business email.

## Deploy order (each step needs the owner's approval)
1. `owner-provision-business`.
2. Web app.

There is no migration. S4 is queued only where `sql/zella_platform_emails.sql` is installed, and nothing is sent until email_live.

## Coordination
Stacked on `claude/lane-b-retention-due` (lifecycle.ts). VerificationQueue.jsx is not on any open branch. The owner onboarding job also uploads to business-documents. This list reads the same table, so documents uploaded that way count too.

## Tests
- **Deno** (`lifecycle_test.ts`, 3 new; the whole function 44 passed):
  - **documents_missing:** a complete business is left out, a live business with only a rejected copy and a draft with nothing are listed with what is missing and the last request, and a missing table reports `available: false`.
  - **document_request, queued:** S4 is queued to the owner's invitation address (lower case, mandatory, key `email:S4:<id>:…`, HTML with the business name), and the audit entry is correct.
  - **document_request, refused:** a request one hour after the last one gets 429 with no queue call, a complete business 409, a cancelled one 404, and a bad id is refused.
  - **document_request, no outbox or no address:** without the outbox it answers `not_installed`, and without an address `no_address`.
  - `deno check index.ts` is clean.
- **Web unit:** the cooldown hours and the three notices. `node --test web/tests/*.test.mjs`: 108 passed.
- `npm run lint` (0 dashes) and `npx vite build` pass.
- **Local browser** (isolated DB without the outbox, so the honest "not installed" path; 1440x900 and 390x844, deviceScaleFactor 1): 14 checks, all passing, no page errors. They cover:
  - a live business with no documents is listed as Live without documents, and a draft is listed too;
  - Request documents says email isn't live yet, is audited and then shows the cooldown;
  - through the real function, anonymous gets 401, read_only_admin gets 403, and asking again gets 429;
  - no sideways scroll.
  Screenshots: `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-b/shots/b4-missing-1440.png`, `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-b/shots/b4-missing-390.png`.
  The queued path is covered by Deno only, not in the browser.

No migration, so there are no md5s to confirm.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
