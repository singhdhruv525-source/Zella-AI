# Booking gaps, double booking, handover and the owner's rules (5 Nov 2026)

Covers `sql/zella_booking_buffers.sql` (B1, B2) and `sql/zella_escalation_rules.sql` (D5, D7). Neither is applied.
Both were tested only on isolated copies of the production state (`tests/lib/build_full.sh`); no real calls were made.

## Rules the backend enforces vs information the assistant passes on

| Setting (where it is edited) | Kind | Enforced by |
| --- | --- | --- |
| Booking switched on/off, reschedule, cancel (setup; CRM receptionist editor) | rule | tool list + `zella_ai_tool` (D1) |
| Usual length, minimum notice, how far ahead (setup; CRM editor "Booking rules") | rule | `zella_ai_booking`, `zella_ai_manage_booking` (D3) |
| Gap between bookings (setup; CRM editor) | rule | `zella_available_slots` and the table guard (B1, B2) |
| No two bookings for the same person at once | rule | table guard under the booking lock (B2) |
| When to pass a call to a person (setup; CRM editor) | rule | `zella_ai_voice` transfer + `zella_transfer_destination` (D5) |
| Emergency handling (CRM editor) | rule | `zella_ai_voice` emergency (unchanged; not governed by the handover reasons) |
| Things it must never say or do (setup; CRM editor) | instruction | the assistant only (prompt section "THE OWNER'S RULES") |
| Booking notes (setup; CRM editor) | information | the assistant only (prompt section "BOOKING NOTES", which states that the tools decide times) |

Nothing that must be enforced is left to a note or a restriction: the CRM editor places the enforced booking rules in
their own section ("Zella enforces these"), with the notes and restrictions marked as instructions.

## B1 / B2: gaps and double booking

- **Before:** the gap was saved and never read. CRM bookings and reschedules wrote the table directly, without the
  booking lock or any overlap check, so a team member and the AI could book the same time at once.
- **After:**
  - Availability keeps the gap on both sides of every booking that holds a time. That covers offers, AI booking,
    holds, reschedules, confirming a request, staff-unavailable offers and the customer's reschedule link.
  - A table guard takes the same lock and refuses any overlapping booking, gap included, from any writer with
    `SLOT_TAKEN`.
  - Staff can deliberately "Book it anyway" or "Move it anyway". That is recorded in `conflict_note`, and server code
    can't use it.
- **Staff and resource rules:**
  - with staff, the gap and overlap are per staff member, and an unassigned booking claims no one;
  - without staff, the business has one calendar;
  - requested bookings and expired holds hold no time;
  - status-only changes are never refused, and old overlaps are left alone.
- **Open decision:** whether an unassigned booking in a business with staff should block a time. Today it doesn't,
  matching the availability rule that existed before.
- **Tests:** `tests/booking/run.sh`, 7 checks. They include a real two-connection race: a booking-function write and a
  direct table write for overlapping times at the same moment; one is kept and the other refused. Without the fix, the
  race keeps both, and the first check fails.

## D5: handover reasons

- **Before:** the saved reasons were never read; the prompt always transferred on request, upset or "can't help".
- **After, once a business has saved reasons:**
  - `transfer_to_human` carries a reason, and the server refuses reasons the business didn't tick.
  - The phone system only receives the transfer number for a call whose transfer the server approved, or an
    emergency. The assistant can't skip the check by calling the transfer directly.
  - The instructions list only the ticked reasons.
- **Unchanged:**
  - Businesses that never saved reasons keep today's behaviour.
  - Emergencies follow the emergency setting, so a missing tick never stops one.
- The CRM editor saves reasons explicitly. The first save of an older business saves the three reasons it behaved by
  before (asks for a person, can't answer, upset), so behaviour doesn't change until the owner changes the ticks.

## D7: the owner's rules and booking notes

They reach the assistant's instructions, labelled, and leave them when removed. They are instructions: no server check
can guarantee the assistant follows "never give medical advice". The tests prove the instructions change; they cannot
prove the assistant obeys them.

## Proof that a CRM edit changes behaviour, not only text

`tests/escalation/run.sh` edits the settings through the CRM's own path: save a draft, check it, publish it, as the
signed-in owner. It then reads behaviour through the functions the call handler (voice-rules) calls:
- unticking "upset" makes `transfer_to_human` refuse an upset caller, and the phone system get no number;
- asking for a person still connects to the published number;
- ticking it again restores it at once;
- with nothing ticked, no call is passed to a person, but an emergency still is;
- a booking note does not change the booked length, while the enforced usual length does.

These take effect on the next tool call, because the server reads the published settings each time. The prompt text
reaches the live assistant only after the provider sync that publishing starts ("goes live once it has synced"). Until
then, the assistant may still offer a transfer that the server will refuse.

Without the fix, the first post-publish check fails: the upset caller is transferred.

**Not tested:** a real call through Vapi. The runtime path is covered locally by the contrast matrix
(`tests/calls/run.sh`); the provider itself (speech, the transferCall tool, the sync) was not exercised.

## Evidence note (added 5 Nov, evening)

Statements here about production are one of:
- **current configuration** read on 5 Nov;
- **retained history**: the audit log since 22 Oct and reminders since 23 Oct, which show every reminder ever queued
  was a text and no automation change mentioned an AI-call channel;
- **local tests** on isolated copies.

None comes from a provider test: no real Vapi call, Shopify store, SMS, email or Google request was made. "Changes no
existing row" or "no customer affected" means within that configuration and history, not a proof about earlier
states that left no record. Per-issue labels and statuses: `docs/DEFECT_INVENTORY_2026-11-05.md`.
