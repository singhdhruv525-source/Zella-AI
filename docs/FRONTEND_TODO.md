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

## From the handwritten notes ("Create business fixes") - DONE
- Email, phone and website errors show under the box (phone checks the country code; call transfer number and website added)
- One shared automation list (`automationCatalog.js`): every automation, industry-preferred first, marked "Preferred for this business" - in the wizard, the admin business page and the business app
- Integrations list shows every integration: Google and Outlook/Microsoft calendar, Gmail, Outlook email, WhatsApp, Google leads; admin overview has an Email column
- Per-automation "Tell the owner by" (text, email or both): saved in each automation's settings (`notify_via`). Delivery per automation is not wired yet: urgent alerts still follow each person's own text-alert switch.
- Deploy `owner-provision-business` after pulling (it now saves `notify_via`, returns industry rules, and reports email requests)

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
