<!-- coderabbit-ai-generated:v1 -->

<!-- coderabbit-ai-generated-section:v1:cab06d0c0ce77aa772626f232a48e4f717fa47c0e6cb6283d9e6557b67838fc1 -->

# Release 2: scheduling, capacity and dispatch (7 Nov 2026)

Second release of the 28-industry backlog (shared P0 "resource scheduling", P1 "dispatch management" and "recurring
work"). Branch `claude/release2-scheduling`. **Nothing is applied to the live database yet.**

## Why
Staff and restaurant tables could not be double-booked (the conflict guard on appointments), but nothing knew about
rooms, chairs, service bays, equipment, boarding spaces or vehicles, so a salon chair, a dental chair, a treatment
room or a kennel could be given to two bookings at once. Field-service businesses (cleaning, HVAC, plumbing,
electrical, landscaping, pest control, home services, property management) had the "dispatch" capability switched on
but no dispatch screen, no crew, no job progress and no return visits. Repeat work (fortnightly cleans, quarterly
services) had no plans that book the visits.

Built on what exists, nothing recreated: appointments and their booking lock, the staff conflict guard (unchanged),
staff_members, blocked_times, arrival windows (`zella_arrival_window`), the `dispatch` capability and its
per-industry defaults.

## What it adds

| Piece | What it does |
|---|---|
| `resources` | A room, chair or station, service bay, equipment, shared space or vehicle. **Capacity** (1 for a chair; more for a boarding area or class room, counted per person), a **gap after each booking** (turnover), in use or out of use. Owners, admins and managers set them up; staff read them. |
| `appointments.resource_ids` | The resources a booking uses. A trigger (`zella_resource_guard`) refuses a booking or a move that would put a resource over its capacity, inside its gap, during a block (`blocked_times.resource_id`: maintenance, cleaning) or while it is out of use. It takes the same booking lock as every other booking path, so it holds for the app, the AI receptionist and imports alike. "Book it anyway" (the team's override for staff overlaps) does not override a resource: the screen names the resource instead. Past visits never clash. |
| `resource_needs` | "A colour needs a chair", "a boarding stay needs a kennel". A booking whose title or type mentions the service and names no resource gets free ones picked automatically, or is refused (`SLOT_TAKEN`) when none is free. Other services are unaffected. |
| Crews | `appointments.crew_staff_ids`: people besides the lead. Nobody can lead or crew two overlapping jobs; the lead is never also crew; people from another business are refused. |
| Dispatch (`job_dispatch`) | Assigned → on the way → on site (pause) → completed or needs a return visit, with the time of each step. A step carries the state the screen showed: if the job moved on meanwhile nothing changes (`CHANGED`); steps out of order are refused (`BAD_STEP`). A completion **checklist** whose required items must be ticked before completing. A finished job is a completed appointment, exactly as when it is marked completed on the calendar. **Return visits** are booked from the job and linked to it (checked like any booking). |
| Dispatch board | `zella_dispatch_board`: each technician's day (lead and crew), the unassigned jobs, arrival windows ("Arrive 9:00 AM - 11:00 AM" when the business uses them), time off, checklist progress, planned visits. |
| Recurring plans | Every N weeks on a weekday, or every N months on a day (1-28), at a time, with an optional customer, record, person and resources, from a start date to an optional end. **Book the next 4 weeks** generates the visits: each date once (`recurring_visits`, safe to repeat), never forced. A date that clashes (the person, a resource, a holiday or special hours) is recorded as **skipped with the reason**. Generated visits are **planned** (held, `tentative` with no expiry): they hold the time, **queue no customer message**, and show as "Planned" until the team confirms them. Nothing runs on a schedule: visits are booked when someone asks. |
| Screens | **Dispatch** (field-service businesses): the board by day, assign with crew, step buttons, checklist, return visits; viewers see it read-only and are told why. **Resources**: list, add/edit, "what services need", and who uses what on a day. **Recurring visits**: plans described in words ("Every 2 weeks on Tuesday at 9:00 AM"), upcoming and skipped dates with reasons, book the next 4 weeks. **New booking** form: "Uses" (resources). Calendar and booking panel: planned visits read "Planned" with **Confirm visit**. |
| Access | All five tables: members read; signed-in users and anon have no insert, update or delete grant (writes go through the functions); MFA rule like every other table; anon reads nothing. `service_role` (the server key) has full table privileges, as on every Zella table. Every new function with the owner's rights has a fixed search path; anon can run none. Paused or cancelled businesses can't change anything. |
| Audit | Resources added and changed, needs saved, jobs assigned, each step, return visits, plans added and changed, each generation (booked and skipped counts). |

## Tests

| Command | Kind | Result |
|---|---|---|
| `tests/scheduling/run.sh` | isolated Postgres at production state (Release 1 included) plus this migration, applied twice | **8 database checks + 5 structural: all passed**. Who may set up resources; one booking per resource at a time; its gap; cancelling frees it; moves checked; duplicates folded; past visits never clash; shared capacity per person; blocks; out of use; another business's resource refused on bookings and blocks; services that need a chair get a free one (never the same twice) or are refused; crews (lead and crew, the lead not also crew, foreign people refused); dispatch board, assignment refused when the person or crew is busy, steps (`CHANGED`, `BAD_STEP`), required checklist, completion, return visit linked, viewers and other businesses change nothing; recurring dates (every 2 weeks from the first matching day, every 3 months, end dates), generation booking each date once, skipping a clash with its reason, planned visits with no customer message queued, managers only; anon nothing; every kind of change audited. Structural: the baseline is captured before the first scheduling apply; the existing booking guard and booking function are byte-for-byte unchanged; slot search changes only to exclude resource-only blocks from staff time off (this filter is retained after rollback); exactly the 21 new functions exist (19 with the owner's rights, all with a fixed search path) and anon can run none; the rollback removes the functions and triggers and keeps every row (tables renamed, the new columns and a resource block kept), with the booking functions as before apart from that retained block filter; a fresh apply after the rollback passes everything again. Deliberately broken rules make the suite fail: capacity ignored, crew check removed, checklist ignored, recurring "each date once" removed (also stopped by a unique index), stale step check removed, the resource role check removed. |
| `tests/deploy/run_all.sh` | the full pending sequence plus Release 1 and this release, every suite on one database, the call handlers, the full rollback | **all passed**: 391 / 391 and 335 / 335 call checks across the 28 industries with the new booking trigger in place; every suite including Release 1's and this one; the full rollback leaves every function, column (except the three Release 2 columns kept on purpose), trigger and policy identical to before in the original release run. The review repair intentionally retains the resource-only block filter after rollback; that historical full-deploy result does not validate this revised patch. |
| `node tests/browser/scheduling.cjs` | Chromium, **real local backend** (stand-in on an isolated copy at production state; real sign-in, row security, functions and booking guards), Test HVAC in America/Chicago | **22 / 22, in each of 3 runs**. The sidebar offers Dispatch, Resources and Recurring visits; a manager adds two bays; a booking uses Bay 1; the same bay at the same time is refused with its name and no "Book it anyway"; the job shows unassigned; assigned to a lead with a crew member (both columns); on the way, arrived; completing with a required checklist item open is refused in plain words; then it completes (appointment completed, times kept); a step from an out-of-date screen is refused and the board shows the job as it is; a weekly plan is described before saving; booking it creates 4-5 planned visits held for the technician and queues no customer message; booking again adds nothing; planned visits show as Planned on the board. Viewer: sees the board and resources, told why it is read-only, no job buttons (the same check finds them for the owner). Dispatch and Recurring at 390 px: no sideways scrolling. No page errors. |
| `node tests/browser/people-consent.cjs` | Release 1, same backend | 31 / 31 |
| `cd web && node --test tests/*.test.mjs` | unit | **44 / 44** (5 new: resource kinds and job states are read from the migration's own constraints; the step buttons match the server's step list; arrival windows; checklist progress; plan wording; plain-language refusals) |
| `npm run build`, `npx oxlint src` | build, lint | ok; 0 errors, 204 warnings, the same as `main` |

**Not verified:** production; Safari and Firefox; screen readers beyond labels and roles.

## Review repair validation

The unit command above checks JavaScript helpers; it does not establish whether applying SQL changed existing booking functions. The SQL runner captures its baseline before the first scheduling application. Its comparison now permits only the authorized resource-only block filter in slot search. Rollback retains that filter because it retains resource block rows. Planned confirmation uses an authorized server transition, checks the current tentative/open state, sets both confirmation fields, and suppresses its message queue without affecting ordinary bookings.

## Not in this release (needs your decision or a later release)
- **Slot search and the AI receptionist offer times without looking at resources yet.** A booking that would take a
  chair or room that's full is still refused when it is written (the trigger), so nothing is double-booked, but the
  receptionist could offer a time and then hear it's taken. Making `zella_available_slots` resource-aware changes live
  assistant behaviour, so it needs your approval.
- **No "on my way" texts** to customers when a technician sets off: sending messages needs your approval and the
  messaging switches.
- **No automatic weekly generation.** Booking the next weeks is a button; running it on a schedule needs a scheduler,
  which needs your approval.
- Routing and travel time between jobs, parts and materials, and weather rescheduling are later work (Release 3 and 5).

## Deployment (each step needs your approval)
1. **Database:** `sql/zella_scheduling.sql` (new tables, three new nullable columns, the new triggers and functions;
   touches no existing data; patches slot search to ignore resource-only staff blocks and the messaging trigger to suppress queues only during the explicit planned-visit confirmation; safe to run twice). Undo:
   `sql/rollback/zella_scheduling_rollback.sql` (keeps every row).
2. **Web app:** merge to `main`. Until the database has the tables, the new pages say "This isn't available on this
   workspace yet" and the booking form shows no "Uses" choice; nothing else is affected.
No edge-function change and no configuration change.


<!-- /coderabbit-ai-generated:v1 -->