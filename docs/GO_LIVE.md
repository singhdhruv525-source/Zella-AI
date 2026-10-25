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

## Industry rule list (setup wizard)
- Run `sql/zella_industry_rule_list.sql` (already applied live). It adds three general rules anyone can switch on and the list/set functions.
- Deploy the `owner-provision-business` edge function: the wizard's automation step now shows standard + industry-made + general rules with on/off and "tell the owner by".

## Receptionist brain
- Run `sql/zella_brain.sql` (already applied live). Import `n8n/workflows/zella-brain-tools.json` (webhook `/webhook/zella/vapi-brain`).
- Set platform setting `brain_tools_url` to that webhook URL, check `voice_llm_provider` / `voice_llm_model` against what Vapi supports, then send `zella_assistant_config(business_id)` to Vapi for each business (not automated yet).
- Add real knowledge (services, prices, policies) per business and a few `ai_eval_cases`; run `zella_brain_run_evals`. Without knowledge the assistant will correctly say it does not know.
- Say-so rule: confirm what Vapi's model name is at go-live; the default is a placeholder setting.

## Call intelligence
- Run `sql/zella_call_intelligence.sql` (already applied live). Import `n8n/workflows/zella-call-intelligence.json`, assign the Supabase credential and the gateway secret, and add the Anthropic key by hand in "Ask AI".
- Decide the privacy wording (transcripts go to the AI provider), then set `call_intel_live` to true. Check `call_intel_model` and `call_intel_monthly_limit`.

## Added with the industry and alert work
- Run, in order: `zella_industry_rule_list.sql`, `zella_more_industries.sql`, `zella_industry_presets_more.sql`, `zella_notify_via.sql` (all already applied to the live database), then `zella_dispatcher.sql` last.
- Deploy the `owner-provision-business` edge function so the wizard can list and save every rule.
- Texts to staff need a working SMS provider; until then "text" alerts stay queued.
- Check the new Calls suggestions panel and the "Write your own rule" screen in a real browser build (only compile-checked so far).

## n8n: alerts, signatures and keys (added 2026-10-25)
1. **Failure alerts.** Publish "Zella - Failure Alert" first (it only raises a platform alert in the database, nothing else). Then, in each of the other 25 workflows, open Settings > Error workflow and pick "Zella - Failure Alert". n8n will not accept it until it is published, so this could not be done while everything is switched off.
2. **Resend signature check.** `sql/zella_resend_signature.sql` is applied live and tested. After you create the Resend webhooks, run once: `select vault.create_secret('whsec_...', 'zella_resend_signing_secret');` (the signing secret shown by Resend). Until then only the key in the webhook address protects them. Then use Resend's "send test event" and confirm it is accepted; a wrong or old signature is answered 401. Meta webhooks already verify their signature.
3. **Keys, by hand on n8n only:** Telnyx, Resend, Anthropic, Vapi. Never in chat.
4. Publish the other workflows, then run `sql/zella_dispatcher.sql` last.

## Call recordings and transcripts
The app now reads calls through `calls_view`. Once this version of the app is deployed, run `select zella_lock_call_columns();` in the Supabase SQL editor. After that, staff below manager cannot read recordings or transcripts at all. Do not run it before the new app is live, or the old app's call pages will fail.

## New automations (industry completion)
- SQL, already applied live and saved in `sql/`: `zella_automation_completion.sql`, `zella_industry_presets_final.sql`, `zella_after_hours_reply.sql`, `zella_team_screens.sql`. Run them in that order on any fresh database.
- Shared automations (visit feedback, six-month check-in, review request) now reach every business except healthcare, dental, legal, financial services and childcare.
- Review requests send nothing until the owner saves a review link in Settings.
- Childcare, healthcare, legal and financial follow-ups are drafts: they wait in "Suggested messages" and nothing is sent until a person presses Send.
- "Tell callers" (full tonight, closing early) works through the AI receptionist's prompt. It does not block the booking tools themselves.
- After-hours text replies: the "Zella - Follow-up Texts" workflow was updated live (still unpublished) with the new `reply_after_hours` kind. Publish it with the others.
- Not built: rating-based review routing (low ratings to the owner first). Replies to the review text go to the inbox like any other reply.
- Not built: AI-written drafts. Drafts use the saved wording; an AI-written version needs the Anthropic key and a new n8n workflow.

## Sign-in, invitations and password reset (added 2026-10-25)
Set these in the Supabase dashboard. Do them now for localhost, and again with the real address once the app is hosted.
1. **Authentication > URL Configuration**
   - Site URL: the app address (`http://localhost:3000` while testing, later `https://<your domain>`).
   - Redirect URLs: add `http://localhost:3000/**` and later `https://<your domain>/**`.
2. **Edge Functions > Secrets**: `ZELLA_APP_URL` = the same app address. Admin invitations refuse to send without it.
3. **Authentication > Emails > Templates.** Mail scanners (Gmail, Outlook) open links before people do, which uses up one-time links ("Email link is invalid or has expired"). Change the links so the app asks the person to press Continue first:
   - Invite user: `<a href="{{ .RedirectTo }}?token_hash={{ .TokenHash }}&type=invite">Accept your invitation</a>`
   - Reset password: `<a href="{{ .RedirectTo }}?token_hash={{ .TokenHash }}&type=recovery">Choose a new password</a>`
   The app handles both these links and the old ones, so this can be done at any time.
4. **Custom email sender (SMTP)**: Supabase's built-in sender allows only a few emails an hour. Before real customers, set Authentication > Emails > SMTP to Resend once the domain is verified.
5. Redeploy `owner-provision-business` after any change to it: `npx supabase functions deploy owner-provision-business --project-ref pffqxlumqhjdbzvvoszm --no-verify-jwt`.
6. Test with two different browsers (or a private window) for two different people. Both apps share one sign-in per browser, so opening someone else's invite in your own browser signs you out of your account.
