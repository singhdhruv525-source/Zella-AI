# Release 3: industry workflow completion (7 Nov 2026)

Third release of the 28-industry backlog: "estimates, approvals, inspections, contracts, service packages, project
milestones, renewals, and exception handling". Branch `claude/release3-workflows`. **Nothing is applied to the live
database yet.**

## Why
Every industry's record types already name the steps (a repair order goes "estimate sent → approved", a dental
treatment plan "presented → accepted", a lease "renewal due", a spa package "used up"). But a step was only a status
someone picked by hand: nothing recorded who approved what, for how much, how and when; whether the person approving
was allowed to; what was checked and what failed; what is holding a job up; when a renewal or a deadline is due; or how
many sessions a package has left.

Built on what exists, nothing recreated: industry records (`crm_records`), their types, statuses and history; estimates
and payments (`customer_charges`: approving an estimate approval accepts the estimate, exactly as "accept" does on the
Money page); record files; Release 1's authorized relationships (the "approve" permission); staff; the audit log.

## What it adds

| Piece | What it does |
|---|---|
| **Approvals** (`record_approvals`) | Ask for approval on any record: an estimate or quote (optionally the estimate itself, whose amount it takes), additional work, a change order, a cost, a contract or agreement, an engagement, a treatment plan, a policy change, a refund. Then record the answer: **approved or declined, by whom, how** (in person, phone, email, text, signed form) **and when**. Only the record's own person, or someone with a verified, in-force Release 1 relationship with the **approve** permission, can be recorded as approving; strangers, contacts who may only discuss, revoked relationships and other businesses' people are refused. A **refund** is the business's own decision, taken by a manager or above. An answer-by date: once it passes, the request can't be decided (withdraw and ask again). A decision from an out-of-date screen changes nothing. The main approvals move the record to the step its industry names (a repair order to "approved", a dental plan to "accepted"); extra work and change orders don't send a job in progress back. Amounts are for staff and above, like estimates and invoices; viewers don't see them. |
| **Dates** (`record_milestones`) | Milestones, deadlines, renewals, payment-due dates, deliveries and follow-ups on any record, with who is on it. "Due in 3 days", "2 days overdue". A **renewal**, when done, rolls forward (a year on by default) exactly once. |
| **Checklists and inspections** (`record_inspections`) | The industry's checklist (an HVAC service checklist, a vehicle inspection, a pest site inspection, a unit inspection, a loaner check-out, a boarding check-in...) with pass / fail / N/A per item and a note for a failure. Save part-way; finishing needs every item answered; a finished one is a record of what was found. **A failed item fails it and flags a problem** naming what failed. |
| **Problems and holdups** (`record_exceptions`) | Waiting on parts or materials, on the customer, on a supplier or third party; delayed; weather; damaged; disputed; delivery problem; warranty or comeback; safety concern; inspection failed. An expected date ("late" once it passes), resolved with how it was sorted. One open problem of each kind per record. |
| **Credits** (`record_credits`) | A ledger for packages, memberships, care plans and retainers ("5 sessions left"): managers add and expire credits, staff use them and give back only what was used (giving back can't create credits). Never below zero, even when two people use the last one at the same moment (tested); one visit uses a package once; using the last one marks a package "used up". |
| **Follow-through page** | Across every kind of record: approvals you're waiting on (expired ones flagged), dates coming up in the next 7 to 90 days, and problems holding work up. Viewers see it without amounts and are told it's read-only. |
| **Industry defaults** | Each of the 28 industry presets' record types gets the workflow that fits (which approvals, which checklist, whether it counts credits, which steps approval moves it to): see `record_workflow_presets` in the migration. New record types get theirs automatically. A business can change its own in **Customize records → Edit**; **a business's own setting is never overwritten** by the defaults. |
| **Access** | All new tables: members read through the record (whoever can see the record sees its workflow; approvals are staff and above), signed-in users and anon have no insert, update or delete grant (writes go through the functions), MFA rule like every other table, anon reads nothing. Every change needs staff or above (managers for refunds, adding credits and the type's setting) and a business that isn't paused. Every change is in the record's history and the audit log (no amounts or notes in the history line). |

### Industry coverage (defaults)

| Industry preset | Approvals | Checklist | Credits | Approval moves the record |
|---|---|---|---|---|
| Automotive | repair orders: estimate, additional work | vehicle inspection; loaner check-out | | estimate sent → approved |
| Beauty salon | memberships: contract | | memberships (visits) | |
| Childcare | enrolments: contract | | | → enrolled |
| Cleaning | plans: contract, change order | visit quality check | | |
| Dental | treatment plans: treatment plan, estimate | | | presented → accepted / declined |
| E-commerce | returns, cases: refund (manager) | | | |
| Education | applications: contract | | | → enrolled |
| Electrical | jobs: estimate, change order; plans: contract | safety test | | estimate → approved |
| Financial services | opportunities: engagement | | | |
| Fitness | memberships: contract | | memberships (classes) | |
| Healthcare | (dates and problems: prior auths, referrals, coverage) | | | |
| Home services | jobs: estimate, change order; plans: contract | completion checklist | plans (visits) | estimate → scheduled |
| Hospitality | groups: estimate, contract | | | quoted → confirmed |
| HVAC | jobs: estimate, additional work; agreements: contract | service checklist | agreements (visits) | |
| Insurance | policies: policy change; quotes: estimate | | | quoted → accepted / declined |
| Landscaping | jobs: estimate, change order; plans: contract | job completion | plans (visits) | quoted → approved |
| Legal | matters: engagement | | | → accepted |
| Other | records: estimate, other | | | |
| Pest control | jobs: estimate, treatment plan; plans: contract | site inspection | plans (treatments) | quoted → approved |
| Pet care | boarding: contract | boarding check-in | | |
| Photography & events | bookings: estimate, contract | | | quoted → booked |
| Plumbing | jobs: estimate, additional work; plans: contract | completion check | plans (visits) | quote sent → approved |
| Professional services | opportunities: estimate, contract; projects: change order | | projects (hours) | proposal → contract |
| Property management | requests: cost; leases: contract | unit inspection | | |
| Real estate | deals: contract | | | |
| Restaurant | events: estimate, contract; catering: estimate | | | quoted → confirmed / declined |
| Spa & wellness | memberships: contract | | packages (sessions, → used up); memberships | |
| Travel | trips: estimate, change order | | | quoted → booked |

Every record type of every industry also has dates (milestones, deadlines, renewals...) and problems.

## Tests

| Command | Kind | Result |
|---|---|---|
| `tests/workflows/run.sh` | isolated Postgres at production state (Releases 1 and 2 and the slot-search fix included) plus this migration, applied twice | **6 database sections + 6 structural: all passed**. Defaults for all 28 presets, new types get theirs, a business's own setting kept. Approvals: amount from the estimate; only the person or an authorized approver (stranger, discuss-only contact, revoked, other business, nobody: all refused); who/how/when stored; estimate accepted; record moved; extra work doesn't move it back; stale and expired decisions refused, and so is approving an estimate voided meanwhile; refunds a manager's internal decision; viewers and other businesses see and change nothing; history and audit. Dates: a person from this business only; renewal rolls forward once to a later date; done ones are history. Checklists: every item before finishing; stale screen refused; a failure fails it and flags a problem naming it; finished ones are history. Problems: one open of a kind, resolved once. Credits: roles, never below zero, giving back capped at what was used, one use per visit, stale screen refused, used up, refund. Settings cleaned and statuses checked; follow-through with no amounts for viewers; paused businesses change nothing; anon nothing. Structural: **every one of the 1,991 existing functions is byte-for-byte unchanged**; **two people using the last credit at the same moment: one succeeds, the balance never goes below zero**; exactly the 20 new functions (18 with the owner's rights, all with a fixed search path), anon can run none, signed-in users can't call the internal helpers; the rollback removes the functions and trigger and keeps every row (tables renamed, the setting kept), with every existing function as before; a fresh apply after the rollback passes everything again. Deliberately broken rules make the suite fail: the record lock removed (the race test catches the balance going to -1), the approver check removed, the balance check removed, viewers allowed to read amounts. |
| `tests/deploy/run_all.sh` | the full pending sequence with Releases 1, 2, the slot-search fix and this release, every suite on one database, the call handlers, the full rollback | **all passed**: 391 / 391 and 335 / 335 call checks across the 28 industries with this release in place; every suite including Releases 1 and 2, the slot-search fix and this one (6 sections); voice-rules 39 / 39, owner-provision 13 / 13; the full rollback, newest first, leaves every function's definition and every column identical to before (except the columns kept on purpose: the three Release 2 columns and `crm_record_types.workflow`) and the same triggers and policies (by name). |
| `node tests/browser/workflows.cjs` | Chromium, **real local backend** (stand-in on an isolated copy at production state), Test HVAC in America/Chicago | **31 / 31, in each of 3 runs** (30 before the review fixes; the new check: saving the workflow keeps the editor open). A job shows approvals, dates, its service checklist and problems (no credits); asking for an estimate's approval with an amount (stored in cents); the customer's approval by phone (who, how, when; in the history); the checklist can't finish until every item is answered; a failed item fails it and flags a problem naming it; a problem flagged with an expected date and resolved; a renewal shows "Due in 3 days", is done and rolls forward a year; a care plan counts visits (add 2, use 1); the follow-through page lists the approval still waiting and the problem; the owner turns off "additional work" for jobs and it's saved as the business's own. Viewer: no approvals (amounts), reads problems and checklists, no buttons, follow-through read-only. 390 px: no sideways scrolling. No page errors. |
| `node tests/browser/scheduling.cjs`, `node tests/browser/people-consent.cjs` | Releases 2 and 1, same backend | all passed |
| `cd web && node --test tests/*.test.mjs` | unit | **51 / 51** (6 new: approval, problem, date and method kinds are read from the migration's own constraints; every history entry the server writes has words; credits, checklist progress, due dates, the renewal date (29 Feb); which parts a type shows; plain-language refusals; all 28 presets' defaults are valid) |
| `npm run build`, `npx oxlint src` | build, lint | ok; 0 errors, 204 warnings, the same as `main` |

**Not verified:** production; Safari and Firefox; screen readers beyond labels and roles.

## Not in this release (needs your decision or a later release)
- **No messages.** Asking for approval records what you're waiting for; nothing is sent. Sending an estimate or a
  renewal reminder by text or email needs the messaging switches and your approval.
- **No customer-facing approval link or e-signature.** The team records the customer's answer. A self-service link
  or a signature provider is an integration (Release 5).
- **The AI receptionist doesn't read or record approvals yet** (for example "has my estimate been approved?").
  Changing live assistant behaviour needs your approval.
- **No automatic renewal dates from record fields** (for example a lease's end date). Renewals are added by hand and
  roll forward when done. Today-screen cards for these belong to Release 4 (dashboards).

## Deployment (each step needs your approval)
1. **Database:** `sql/zella_record_workflows.sql` (six new tables, one new column with each industry's defaults filled
   in where a type has none, one trigger on new record types, new functions; changes no existing function and no
   existing record). Needs `sql/zella_scheduling.sql` (live) first. Undo: `sql/rollback/zella_record_workflows_rollback.sql`
   (keeps every row).
2. **Web app:** merge to `main`. Until the database has the tables, a record says "Approvals, dates and checklists:
   ..." with the app's "needs updating" message and the Follow-through page says the same; nothing else is affected.
No edge-function change and no configuration change.
