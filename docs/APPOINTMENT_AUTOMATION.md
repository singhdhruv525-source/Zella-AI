# Appointment automation: status and go-live (2026-10-26)

Checked against the live project (read-only) and the repository. The lifecycle is built in the database and in n8n;
it is **switched off** until providers are connected. Nothing sends today, and the app says so.

## What exists (live database + n8n, unpublished)

| Step | Where it lives |
|---|---|
| Confirmation and reminders | `zella_replace_reminders` (on booking/change) -> `appointment_reminders` -> SMS Sender / Email Sender workflows |
| Old reminders cancelled on change | `zella_replace_reminders` marks pending ones `cancelled: replaced` |
| Customer confirm / cancel / reschedule by reply | `zella_reminder_response`, `zella_inbound_replies.sql`, reschedule links (`zella_reschedule_*`) |
| No-show follow-up with rebooking offer | `zella_queue_no_show_followup` trigger -> `followup_tasks` -> AI call (Outbound Calls) or Follow-up Texts / Emails. With `zella_no_show_rebook.sql`: the text/email carries a private link to pick a new time; picking one moves the booking back to scheduled, rebuilds reminders, tells staff and cancels the pending follow-up. A reply still reaches staff as a callback |
| Follow-up after completed visits | `post_appointment_follow_up` automation -> `followup_tasks` |
| Staff notifications | `staff_notifications`, Staff Texts workflow, Owner Emails |
| Safe retries, no duplicates | one send record per reminder/task; `zella_retry_failed` resets only `failed` rows (owner/admin/manager) |
| Consent, quiet hours, opt-out, timezone | checked in the database prepare functions before each send |
| Industry and per-business control | each business's own `automations` rows (active / paused / disabled), seeded per industry |

## Live state found

- `sms_live`, `email_live`, `calls_live`: **false**; `sms_from_number`, `email_from_address`: empty.
- Database jobs `zella_dispatch`, `zella_jobs_*`: **inactive**. Vault secret `zella_n8n_secret`: **missing**.
- All 27 Zella n8n workflows: **unpublished**.
- Real reminder rows already record honest outcomes (`dry_run: no text was sent`, `cannot_contact`).

## What this change adds

- Booking side panel, **Messages**: every confirmation, reminder and follow-up for the booking with its real recorded
  outcome (sent, due, not sent and why, failed, replaced), a note when texting/email/automatic sending is not
  connected, and **Retry** for failed ones (owner/admin/manager only, via `zella_retry_failed`).
- `sql/zella_messaging_status.sql` (not applied): `zella_messaging_status(business)` returns on/off flags only (texts,
  emails, calls, scheduler, this business's appointment automations). Members only. No keys or numbers.
  Until it is applied, the panel still lists the messages, without the connection note.

## To go live (your decision and your keys; nothing here was switched on)

1. Back up, then apply `sql/zella_messaging_status.sql` and `sql/zella_no_show_rebook.sql` (and the other pending files listed in `SCHEMA_STATUS.md`).
2. Store the n8n secret: `select vault.create_secret('<secret>', 'zella_n8n_secret');`
3. Connect providers in n8n: Telnyx (texts, with 10DLC approved) and Resend (email, verified domain); set
   `sms_from_number` / `email_from_address`.
3b. Set the platform setting `app_base_url` (https) so customer links (reschedule, rebook) are included.
4. Publish the workflows, turn on the `zella_dispatch` and `zella_jobs_*` jobs, then set `sms_live` / `email_live`
   to true. Test with your own number and address first.
5. Per business: switch on its appointment automations in Automations. A business that doesn't take appointments
   (retail, some restaurants) simply leaves them off; nothing is sent for it.

Admin Settings > Integrations > n8n shows a go-live checklist (each step ready / not yet) once `zella_messaging_status.sql` is applied.
