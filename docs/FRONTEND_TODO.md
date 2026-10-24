# Front-end work to do after all automations are finished

Order agreed: finish automations -> industry automations -> front-end pass.

## Screens for the engine already built
- Notifications and escalation acknowledgement; staff handover and offboarding
- Business reports and KPIs; platform metrics for admin
- Customer message settings and sent-message log
- Contact preferences, data export and erase
- Callback controls and digests
- Website form keys and embed code
- Billing: plan, usage limits, renewal status
- Approvals queue
- Integrations: status, "test now" results, reconnect buttons

## From the handwritten notes ("Create business fixes")
- Email and phone validation errors under the box (including country-code mismatch)
- Automation step lists every automation, industry ones first, marked "Preferred for this business"
- Integrations list shows every integration, including Outlook / Microsoft calendar
- Per-automation notification choice: text, email or both
- Same automation list in Admin -> Dashboard -> Automation tab and on a customer's CRM page

## Small-business mode
- Simple "today" screen
- Phone-first app (PWA) with push; owner alerts by text or email

- Calls: read through `calls_view` instead of `calls` (BusinessCalls, Inbox, More, Profile), then run `select zella_lock_call_columns()` so recordings and transcripts stay manager-only.
- Erase customer: handle the `APPROVAL_REQUIRED` error by asking for a second owner/admin approval.
- Failed work screen for managers using `zella_failed_work` and `zella_retry_failed`; message results screen using `zella_workflow_effectiveness`.
- Customers: a data-rights requests list (zella_log_data_rights_request, zella_fulfil_data_rights_request, zella_reject_data_rights_request; table data_rights_requests is readable by managers and above).
- Customer page: timeline from zella_customer_timeline; add customer via zella_staff_add_customer; duplicate review list uses zella_resolve_duplicate (merge / keep_separate / dismiss).

- Monitoring: show `zella_integration_summary` on the settings/health page; a reply-speed card from `zella_response_time_report`; platform admin screens for `zella_platform_health_summary`, failed events (`zella_retry_event`) and incidents (`zella_open_incident`/`zella_resolve_incident`, list from `platform_incidents`).
- Reconnect: show `zella_connections_to_reconnect(business)` as banner/buttons on home and settings.
- Lifecycle: home banner for paused/cancelled accounts (read-only mode), cancel-and-keep-plan button before cancel_at.
- Audit: show `privileged_*` rows from audit_logs in a Security log screen for owners/admins.
- Team: invite form (email, name, role), pending invitations list with Cancel/Resend; call zella_accept_staff_invitations() after every sign-in. Approvals screen from zella_pending_approvals + zella_decide_approval.
- Industry rules: Automations screen lists rules per business (pause/edit), with an 'Add rule' form calling zella_save_industry_rule (pick type, record type, status, message, task, alert). Record forms should expose due_at, and for jobs a priority field with 'emergency'.
