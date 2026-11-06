# Release 1: authorized relationships, verification and consent (6 Nov 2026)

First release of the 28-industry backlog (shared P0: "authorized relationships", "approvals and consent",
"sensitive information controls"). Branch `claude/release1-relationships`. **Nothing is applied or deployed yet.**

## Why
Nothing in the database linked a parent to a child, a proxy to a patient, a tenant or vendor to a unit, or an authorized
contact to a policy or matter. The childcare preset says "never share a child's details with anyone except a verified
parent or guardian", but nothing could check it. The only consent table (`contact_consents`) is about messaging
(texts and emails), not treatment, photos or pickup.

Checked first so nothing is duplicated: `contact_consents` (messaging consent; kept as is), `sensitive_approvals`
(staff-side approvals; untouched), preset fields (no guardian or authorized-contact fields exist). Children, pets,
units, policies and matters are **records**; the people around them are **customers**. So a relationship links a
person to either a person or a record.

## What it adds

| Piece | What it does |
|---|---|
| `customer_relationships` | A related person (a customer of the same business) for a subject: a person, or a record (child, pet, unit, policy, matter …). Kind: parent, legal guardian, proxy, representative, household, emergency contact, authorized contact, tenant, owner, vendor, other. Permissions: discuss, book, pick up, approve, receive updates, documents. Optional end date and note. Never deleted: a revoked link stays as history. One active link per person, subject and kind. |
| Verification | A link grants **nothing until verified**, and nothing once expired or revoked. The method is recorded (photo ID, document on file, known to the team, call-back on a known number, other). Staff verify; in sensitive industries (dental, healthcare, vet, legal, financial services, insurance, childcare) only owners, admins and managers. Changing the person or kind, or adding permissions, clears the verification; removing permissions keeps it. |
| `customer_consents` | Consent given or refused for a subject (treatment, medication, emergency care, photos, sharing information, call recording, pickup arrangements, terms, other), with scope, an optional expiry and evidence. It can only be given by the person themselves, a record's primary contact (`crm_records.customer_id`), or a verified link with "approve". A withdrawal is recorded, not deleted. |
| `zella_is_authorized(...)` | "May this person do X for that subject?" The person themselves and a record's primary contact: yes. Anyone else: only through a verified link in force with that permission. Members of the business and the server key only. Ready for the AI receptionist, which **does not use it yet** (see below). |
| Functions | `zella_relationship_save / _verify / _revoke`, `zella_consent_record / _revoke`, `zella_people_panel`. All SECURITY DEFINER with a fixed search path, checking membership and role themselves (row security doesn't protect them). Writes need staff or above and a business that isn't paused or cancelled. Viewers and other businesses get nothing. |
| Row security | Both tables: members read; no one writes directly (no insert/update/delete grant); MFA rule like every other table; anon nothing. |
| Audit | Every add, change, verification, revocation, consent and withdrawal goes to `audit_logs` (who, kind, permissions, method). Note text is not copied. |
| Screen | **People & consent**: a new tab on every person's profile, and a section in every existing record's window. It lists links with their state (Verified / Not verified: grants nothing yet / Expired / Revoked), Link a person (relationship suggested by record type, e.g. Parent first for a child, Tenant for a unit), Verify (method required), Edit, Revoke (with reason), revoked history, "this person is linked to …", and consent: Record consent (only eligible givers offered) and Withdrawn. Viewers see everything and are told why they can't change it. Errors are in plain words; loading, failed and stale states are shown. |

## Tests

| Command | Kind | Result |
|---|---|---|
| `tests/relationships/run.sh` | isolated Postgres, production state plus this migration (applied twice) | **10 checks + 4 structural: all passed**. Verification before authority; staff can't verify in a sensitive industry, managers can; method required; exact permissions; primary contact and self; narrowing keeps and widening clears verification; duplicates, past dates, same person, unknown kinds and permissions, and another business's people refused; expiry; revoke keeps history and is safe to repeat; "linked to"; consent givers (unverified relative and stranger refused, primary contact and verified approver accepted); refusals, expiry and withdrawal; viewer read-only (functions and direct insert); another business sees and changes nothing; paused business refused; anon nothing; non-sensitive industry staff verify; server key gets the same answer; audit without note text; every new definer function has a fixed search path; anon can run none; rollback keeps data (renamed tables) and removes the functions; a second apply after rollback works with fresh indexes. A deliberately broken rule (verification ignored) makes the suite fail. |
| `cd web && node --test tests/*.test.mjs` | unit | **39 / 39** (4 new) |
| `node tests/browser/people-consent.cjs` | Chromium, **real local backend** (stand-in on an isolated copy at production state with this migration; real sign-in, row security and functions) | **24 / 24, in each of 2 runs on the final code**. Owner on a childcare child record: link a grandparent as guardian with pickup, shown "Not verified"; database confirms no pickup; Verify needs a method; after verifying the database allows pickup but not approve; consent givers list only the primary contact; consent recorded with scope; revoke moves the link to history; four audit rows. Viewer: sees links, no change buttons (the same check finds them for the owner), told why. The grandparent's profile shows "linked to" the child at 1280 and 390 px with no sideways scrolling. No page errors. |
| stubbed browser suites | `admin-permissions` 49/49 (1 timing failure in 1 of 5 runs, then 3/3), `crm-batch1` 13/13, `admin-batch2` 79/79, `security-journeys` 22/23 | the one `security-journeys` failure ("Try again clears the banner after success") also fails on `main` (pre-existing) |
| `tests/security/run.sh`, `tests/security/batch1/run.sh` | isolated Postgres | all passed |
| `node tests/workflows/industry_matrix.mjs` | 28 industries, isolated staging copy | **1,383 / 1,383** |
| `tests/deploy/run_all.sh` | full sequence plus the 28-industry call matrix | **all passed**: 391 / 391 and 335 / 335 call checks. The first run on this branch failed one check ("fitness A: an offered time books", in both call handlers). It passed on `main` and on a rerun of this branch; this change doesn't touch bookings, calls or anything that suite applies. Time-dependent flake. |
| `npm run build`, `npx oxlint src` | build, lint | ok; 0 errors, 204 warnings, the same as `main` |

**Not verified:** production; Safari and Firefox; screen readers beyond labels and roles.

## Not in this release (needs your decision or a later release)
- **The AI receptionist doesn't use this yet.** Making voice-rules call `zella_is_authorized` before sharing a child's,
  patient's or client's details changes live assistant behavior, so it needs your approval and an edge-function
  deploy. It would also need caller verification (number on file, or a security question).
- No automatic expiry reminders (for example "photo consent ends in 30 days"). That belongs to Release 4 dashboards.
- Uploading a signed form directly to a consent (record files already exist; evidence is text for now).
- Legal and regulatory sign-off: these controls support but do not prove HIPAA, FERPA, childcare-licensing or similar
  compliance.

## Deployment (each step needs your approval)
1. **Database:** `sql/zella_relationships.sql` (new tables and functions only; touches no existing data; safe to
   run twice). Undo: `sql/rollback/zella_relationships_rollback.sql`.
2. **Web app:** merge to `main` after the database step. Until the database has the functions, the new tab and
   section show "People & consent isn't available on this workspace yet" and nothing else is affected.
No edge-function change and no configuration change.
