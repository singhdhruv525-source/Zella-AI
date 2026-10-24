# Zella go-live list

Nothing below is published or running until you do it. Everything is built; these are the steps that need your accounts or a decision.

## 1. Supabase (project pffqxlumqhjdbzvvoszm)
1. Turn on backups / point-in-time recovery and set up an outside health ping.
2. Run the SQL files in order (the "Needs" line at the top of `sql/zella_dispatcher.sql` lists them). New since the last list: `zella_monitoring`, `zella_reconnect`, `zella_lifecycle`, `zella_audit_permissions`, `zella_staff_invites_approvals`, `zella_industry_engine`, `zella_industry_presets`, `zella_call_integrity`. They are already applied to the live project and saved in the repo.
3. Re-run `sql/zella_dispatcher.sql` last (starts the schedule).
4. Vault secrets: `zella_n8n_secret`, `zella_resend_webhook_key`, `app_base_url`, `zella_meta_app_secret`, `zella_meta_verify_token`.
5. Platform settings: `inbound_email_domain`, `sms_from_number`; edge function secret `STRIPE_WEBHOOK_SECRET` (or your payment provider's).
6. Live switches (all off until you flip them): `sms_live`, `email_live`, `calls_live`, `knowledge_ai_live`, `calendar_sync_live`, `provider_checks_live`, `website_crawl_live`.
7. After the front end reads calls through `calls_view`, run `zella_lock_call_columns()`.

## 2. n8n (dhruvsingh.app.n8n.cloud)
1. Assign the Supabase credential "Zella Supabase service role" on the new HTTP nodes (e.g. "Record inbound call").
2. Add provider keys: Telnyx on the Send-via-Telnyx boxes and Connection Tests; Resend on the email boxes; Anthropic on the Knowledge AI box.
3. Publish the workflows. Don't save successful executions on the Meta workflows.
4. Re-import the workflow JSON from `n8n/workflows/` if you want the per-node HTTP timeouts to apply to the live boxes.

## 3. Accounts only you can do
- Telnyx: register the 10DLC brand and a Customer Care campaign (no marketing). Needs live privacy and terms pages. Ask whether a platform registers once for all businesses. Point the messaging-profile webhook at the Event Gateway with the `X-Zella-Secret` header.
- Vapi: connect the phone numbers and add the server tools (`X-Zella-Secret`).
- Resend: verify your sending domain and the inbound email domain.
- Google Cloud project for Calendar sign-in (items 41, 50).
- Meta app review and WhatsApp template approval (items 125, 258 sign-in, 263 signature on raw body).
- Microsoft app registration (calendar, optional).
- A payment provider (Stripe-style events are supported).

## 4. Still partly built (need the accounts above)
41 calendar sync, 50 booking failure recovery, 125 WhatsApp templates, 263 webhook signature checks. The database sides are done.

## 5. Front end
`docs/FRONTEND_TODO.md` lists every screen the automations expect.
