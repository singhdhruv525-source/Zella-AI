Messaging: masked, audited contact lookup for one business (COM-29)
base: claude/lane-b-templates

## What and why

**COM-29.** Messaging, Consent & opt outs showed totals only, so nobody could find out why one customer's texts are blocked.

New migration `sql/zella_admin_contact_lookup.sql` adds `zella_admin_contact_lookup(p_business, p_query, p_reason)`. It replaces nothing.
- **Inputs:** needs comms.manage. A business is required (`BUSINESS_REQUIRED`), the query must be at least 4 digits or a full email address (`QUERY_TOO_SHORT`, so a name or a partial address is refused), and a reason is required (`zella_admin_reason`).
- **What it reads, for that business only:**
  - customers matched by the last digits of the phone or the exact email, with their do not contact, text, call and email flags and email suppression;
  - the latest consent per channel and purpose (`contact_consents`);
  - the business's own block and allow entries plus platform wide blocks, including an email domain block;
  - the last blocked text or email and its reason.
- **What it returns:** masked results only: the last 4 digits, and an email as its first letter and domain. Never names, full numbers, full addresses or message bodies.
- **Audit:** every lookup is audited as `comms.contact_lookup`, with the masked query, the reason and the counts (NN-8).

Web: `web/src/admin/ContactLookup.jsx` is a form (business, phone or email, reason) with a facts list of the answer, on Consent & opt outs. The form check is in `web/src/contactLookup.js`. MessagingPage.jsx passes the business list in.

## Defaults taken (owner can change)
The privacy defaults are the owner_decisions COM-29 recommendation: comms.manage, a business required, at least 4 digits or a full email, a reason required, the last 4 digits only, and every lookup audited.

## Deploy order (each step needs the owner's approval)
1. SQL: `sql/zella_admin_contact_lookup.sql`.
2. Web app.

## Coordination
Stacked on `claude/lane-b-templates`. MessagingPage.jsx is also on the open polish PR #88 (3 small hunks here: an import, the Compliance props and one render line). **Merge after #88**, merging origin/main in first.

## Tests
- **Automated local, isolated DB** (`tests/admin_contact_lookup/run.sh`, on template zprod3, and on zprod3 plus every merged, not applied migration): 18 checks, all passing. They cover:
  - before the migration, the function doesn't exist;
  - apply, and apply again;
  - by the last 4 digits: the masked customer with do not text, the latest consent only (opted out by keyword), this business's block entry and not the other business's, and the last blocked text with its reason;
  - no full number, first or last name, message body or address comes back;
  - by full email (any case): the email suppression and the platform wide domain block, masked;
  - the other business sees only its own records;
  - 3 digits, a name, a missing business and a blank reason are refused;
  - three lookups give three audit rows, each with only the masked query;
  - read_only_admin, a business owner and anonymous are refused;
  - rollback twice, reapply, and VERSION_MISMATCH and ROLLBACK_DRIFT on drift.
- **Web unit** (`web/tests/contactLookup.test.mjs`). `node --test web/tests/*.test.mjs`: 101 passed. `npm run lint` (0 dashes) and `npx vite build` pass.
- **Local browser** (isolated DB; 1440x900 and 390x844, deviceScaleFactor 1): 14 checks, all passing, no page errors. They cover:
  - it asks for a business, then for 4 digits;
  - the result shows …7788, Do not text and the block reason, with no full number;
  - the lookup is audited;
  - no sideways scroll.
  Screenshots: `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-b/shots/b12-lookup-1440.png`, `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-b/shots/b12-lookup-390.png`.

## Migration fingerprints
New function (this file's version): `zella_admin_contact_lookup(uuid,text,text)` `70a1b603668c9ba0dd47290f9be3d97b`. Production md5s to be confirmed by the supervisor before apply.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
