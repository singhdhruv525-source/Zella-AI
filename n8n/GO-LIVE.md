# Zella go-live checklist (kept up to date as automations are built)

Nothing below has been done yet on purpose: all n8n workflows are unpublished and the timers are paused until testing.

## Database (Supabase)
1. Run `sql/zella_engine_health.sql` and `sql/zella_calendar_sync.sql`, `sql/zella_phone_numbers.sql` and `sql/zella_assignment.sql` and `sql/zella_customer_requests.sql` (already applied), then re-run `sql/zella_dispatcher.sql` once (adds the outbound-calls and knowledge lanes, the stuck-call sweep and the engine health check, and restarts the timers).
2. Store the n8n secret in Vault (`zella_n8n_secret`), as described at the end of the dispatcher file.
3. Store the Resend webhook key: `select vault.create_secret('<long random value>', 'zella_resend_webhook_key');`
4. Set `app_base_url` (your web address) so reschedule and waitlist links appear in messages.
5. Switch live flags only when each provider is ready: `sms_live`, `email_live`, `calls_live`, `knowledge_ai_live`, `calendar_sync_live`.
6. Run `sql/zella_security_hardening.sql` if not done; turn on leaked-password protection.

## Web app and functions
7. Deploy the edge function `reschedule-appointment` and the web app (pages `/r/<code>` and `/w/<code>`); redeploy `owner-provision-business`.

## Providers (keys go on the n8n boxes by hand, never in chat)
8. Telnyx: account, number, 10DLC registration (can take days), key on the "Send via Telnyx" box.
9. Resend: verify the sending domain, key on the "Send via Resend" boxes, add the webhook `https://<n8n>/webhook/zella/resend?key=<value>` (delivered, bounced, complained).
10. Vapi: account, assistant, phone number; ids into `vapi_assistant_id` and `vapi_phone_number_id`; key on the "Start Vapi call" box.
    - Server URLs (with header `X-Zella-Secret`): end-of-call reports to `/webhook/zella/vapi` (end-of-call-report only); tools to `/webhook/zella/vapi-tools` (`report_unanswered_question` with `question`; `log_customer_request` with `kind` = complaint, correction, data_access or data_deletion, and `summary`) and `/webhook/zella/vapi-booking` (`check_availability`, `book_appointment`, `find_my_appointments`, `reschedule_appointment`, `cancel_appointment`; add the boolean `confirmed` to book, reschedule and cancel, which are refused until the caller has said yes).
    - Register each business's number so tools find the business: `select zella_register_phone_number('<business id>', '+1XXXXXXXXXX', '<Vapi phone number id>', 'Main line');` (service role; the number must belong to only one business). Without a registered number a call must carry the business id in its settings.
11. Anthropic key on the "Ask AI" box in the Knowledge workflow.
12. Google Calendar: create a Google Cloud project, turn on the Calendar API, set up the consent screen (calendar scope), create an OAuth client. Paste its client id and secret by hand into the two token boxes ("Get Google token", "Get pull token") in the Calendar Sync workflow. Each business is then connected with `zella_calendar_connect(...)` (a "Connect Google Calendar" button in the app is not built yet).

## n8n
13. Publish the workflows (gateway, router, the sender and worker workflows, Call Results, Knowledge, Assistant Tools, Appointment Booking, Email Events, Calendar Sync), then test everything together.

## Not built yet
- "Connect Google Calendar" button and Google sign-in function in the app; Google change notifications (hourly refresh covers it); Outlook calendar
- Invitation reminder emails (needs the sign-up link and domain)
- Unsubscribe link and page for marketing emails (reactivation emails stay skipped until then)
- Choosing a specific staff member and per-service lengths in phone booking
- 5-minute batching setting, document or website upload into knowledge

## Connection tests
- Run `sql/zella_connection_health.sql` before `sql/zella_dispatcher.sql`.
- Add the Telnyx, Vapi and Resend keys on the three "Check ..." boxes in the Connection Tests workflow.
- Turn on `provider_checks_live`, then publish the workflow.

## Voice rules
- Run `sql/zella_voice_rules.sql` (already applied to the live database).
- In Vapi add the tool `call_rules` (arguments: action, message, name, phone, summary, reason) pointing at `https://dhruvsingh.app.n8n.cloud/webhook/zella/vapi-voice` with the header `X-Zella-Secret`.
- Add a transfer tool in Vapi that uses the `transfer_number` the tool returns, and tell the assistant to call `call_rules` with action `rules` at the start of every call.
- Each business sets its opening hours, holidays and transfer number (front-end screen still to build).
- Publish the workflow.

## Inbound email and receipts
- Run `sql/zella_email_inbound.sql` (already applied to the live database).
- Choose a receiving domain, set the platform setting `inbound_email_domain` (for example `"mail.yourdomain.com"`), and add Resend inbound for it.
- In Resend add a webhook for `email.received` pointing at `https://dhruvsingh.app.n8n.cloud/webhook/zella/inbound-email?key=<the zella_resend_webhook_key value>`.
- Put the Resend key on the "Fetch email" box of the Inbound Email workflow, then publish it.
- Telnyx delivery receipts: send them to the gateway as `message.delivered` / `message.delivery_failed` with `external_id`.

## Facebook, Instagram and WhatsApp
- Run `sql/zella_meta.sql` (already applied to the live database), then re-run `sql/zella_dispatcher.sql` (adds the meta lanes and triggers).
- Create a Meta app (Business type). Request App Review for: `pages_messaging`, `pages_show_list`, `leads_retrieval`, `pages_manage_metadata`, `pages_read_engagement` (plus Instagram and WhatsApp permissions if used). Without review only app admins/testers work.
- Vault secrets: `zella_meta_app_secret` (the app secret) and `zella_meta_verify_token` (any long random word).
- In the Meta app, webhook callback URL `https://dhruvsingh.app.n8n.cloud/webhook/zella/meta` with that verify token; subscribe to `leadgen`, `feed`, `messages` (and Instagram/WhatsApp equivalents). Check Meta's webhook test succeeds, since the signature depends on n8n handing over the raw bytes.
- Connect flow (front-end screen still to build) must call `zella_meta_store_connection` with the page id and long-lived page token. Owner confirms lead-form consent through `zella_meta_settings` (`call_consent_confirmed`) before leads are auto-called.
- WhatsApp: create and get approved message templates; WhatsApp may need a system-user token.
- In n8n set the four Meta workflows to not save successful executions, put the Supabase credential on their boxes, then publish them.

## Website knowledge crawler
- Run `sql/zella_website_crawler.sql` (already applied to the live database) before re-running `sql/zella_dispatcher.sql`.
- Turn on `website_crawl_live`, then publish the "Zella - Website Crawler" workflow. No keys are needed.
- Front-end still to build: add website, approve it, page approval list, review of drafts (with "website changed" / "conflict" badges), version history.

## Spam protection and the Spam Response workflow
- Back up, then run `sql/zella_spam_protection.sql` (not applied yet; safe to re-run), then re-run `sql/zella_dispatcher.sql` (adds the `spam-response` lane).
- Deploy the edge functions `owner-provision-business` and `reschedule-appointment`. Deploy `voice-rules` only as part of the voice reliability steps below (it now needs `sql/zella_vapi_auth.sql` and a Vapi credential; it no longer uses `ZELLA_VAPI_SECRET`).
- "Zella - Spam Response" (workflow `a7Nfsi9mkQbBmc0L`, unpublished) already has the Supabase and gateway credentials. Publish it, then turn it on in Admin > Security & Abuse > Automation (or set `spam_workflow_live` to `true`).
- Optional AI second opinion: put the Anthropic key on its "Ask AI" box, then switch on AI in the same Automation tab (`spam_ai_live`). Each business must also opt in under Spam protection > Settings.
- Turn on the `zella_spam_hourly` job (fallback alerts, reminders, retention): `update cron.job set active = true where jobname = 'zella_spam_hourly';`
- Re-import "Zella - Voice Rules" from the repo if it stays in use (its reply now passes the screening instruction on).

## Voice reliability and calling usage. In this order, each step needs approval
Applied to production on 2026-10-28 (after a backup of every function and setting they touch): steps 1, 3 and 6, plus
`sql/zella_call_usage.sql`. `zella_dispatcher.sql` was NOT re-run as a whole (its `cron.schedule` lines would switch the
disabled timers back on): only its three functions were updated. Status: reliability 12/12, assistant 7/7, usage 6/6;
every function body matches the repo. `voice-rules` answers 401 to unsigned requests. Next: steps 4, 5, 8 (needs a
voice id), 9 and 10.
1. Back up the database (Supabase dashboard > Database > Backups, or `pg_dump`). Check there are no duplicate call ids: `select external_call_id from calls where external_call_id is not null group by 1 having count(*) > 1;` (must be empty).
2. Spam protection first if it is going live too (section above). Both orders were tested; this one is the one documented.
3. Run `sql/zella_voice_reliability.sql` (after the files it patches), then `sql/zella_vapi_auth.sql`, then `sql/zella_voice_assistant.sql`, then re-run `sql/zella_dispatcher.sql`. Check `select zella_voice_reliability_status();` (12 true) and `select zella_voice_assistant_status();` (7 true).
4. Create the secret (a random 32+ character value, never in git or chat): `select vault.create_secret('<value>', 'zella_vapi_hmac_secret');`. Until it exists every Vapi request is refused.
5. In Vapi, create a credential of type **HMAC** with the same value: algorithm `sha256`, signature header `x-signature`, timestamp header `x-timestamp`, include timestamp on, payload format `{timestamp}.{body}`, encoding `hex`, no prefix, secret not base64. Note its credential id.
6. Deploy `voice-rules` with `--no-verify-jwt` (secrets `SUPABASE_URL`, `ZELLA_SERVER_SECRET_KEY` already exist). Remove the unused `ZELLA_VAPI_SECRET` function secret if it was ever set.
7. Done 2026-10-28: Receptionist Brain Tools, Call Results, Voice Rules, Assistant Tools and Appointment Booking were brought in line with the repo in place (same workflow and webhook ids; each checks the signature first and answers every tool call under its own id), and Call Reconciliation was created (unpublished). Each was tested in n8n with pinned data, including an unsigned request being refused. Still by hand: put the Vapi API key on Call Reconciliation's "Fetch Vapi call" box (Bearer header).
8. Set `vapi_server_url`, `vapi_credential_id` and a `voice_llm_model` Vapi lists (decision needed: `claude-sonnet-5-5` is not offered). `select zella_assistant_config('<business id>')` must say `ready_to_send: true`; its `assistant` object is the whole Vapi assistant (server, credential, server messages, tools, transfer tool). Otherwise, by hand on a TEST assistant first (not the live one): server URL `https://pffqxlumqhjdbzvvoszm.supabase.co/functions/v1/voice-rules` with the credential from step 5; server messages `tool-calls`, `transfer-destination-request`, `status-update`, `end-of-call-report`; tool `call_rules` and the 14 brain tools with no own server (they use the assistant's, i.e. `voice-rules`) or, per tool, server URL `.../functions/v1/voice-rules` with the credential from step 5 (phase 3; switch read-only tools first, see `docs/VOICE_RELIABILITY.md`). Rollback for a tool: its server URL back to `<n8n>/webhook/zella/vapi-brain` (credential plus `X-Zella-Secret` header); `zella_assistant_config` does not add the credential yet (phase 4), so don't send its output to Vapi unchanged; every tool synchronous (`async` off); a transfer tool with no destinations; book, reschedule and cancel with the boolean `confirmed`. Leave retries off (`backoffPlan` unset).
9. Test calls on the test assistant (section "What still needs a real call" in `docs/VOICE_RELIABILITY.md`), checking `calls`, `ai_tool_calls` and the edge function logs. Only then point the live assistant and phone numbers at the same settings.
10. Set `call_reconcile_live` to `true` once real calls are coming in.

## Features added 2026-10-28 (built and tested on staging; not applied to production yet)
Apply after a backup, each file twice is safe, in this order (with the files still missing from production: onboarding,
calendar, messaging status, navigation, no-show rebook, spam protection):
1. `sql/zella_on_call.sql` - on-call rota. Patches `zella_ai_voice` and replaces `zella_transfer_destination`; check
   `select zella_on_call_status();` (3 true). Also stops refusing an emergency transfer the assistant already promised.
2. `sql/zella_languages.sql` - languages per business. Patches `zella_assistant_config`; check `select zella_languages_status();`.
   Before a business uses a non-English language: set `voice_stt_model_multilingual` to a Deepgram model that supports it
   (no default, nothing is guessed), then test-call each language on the TEST assistant.
3. `sql/zella_reviews.sql` - review replies. Switches `reviews_live` and `review_ai_live` stay false until approved.
4. `sql/zella_cross_sell.sql` - "You might also need". Marketing: also needs `sms_marketing_allowed` for texts.
5. `sql/zella_scorecards.sql` - read-only.
6. `sql/zella_status.sql` - public status page `/status` and the uptime check.
6b. `sql/zella_notification_extras.sql` - celebrations (milestones, record week), on-call reminders, the Monday team check-in and
   acknowledging alerts from the admin bell. Patches `zella_mark_staff_sms` (one line: the on-call person's own reminder can be texted when they opted in).
7. Re-run ONLY the function sections of `sql/zella_dispatcher.sql` (review-replies lane, cross_sell kind, zella_check_uptime,
   zella_check_milestones, zella_on_call_reminders, zella_team_scorecard_nudge),
   not its `cron.schedule` lines, then confirm every job except zella_usage_thresholds is still inactive.
n8n (done 2026-10-28, all unpublished): Follow-up Texts and Follow-up Emails send `cross_sell`; "Zella - Review Replies"
(`CrWVtn3AHmVYtPox`) created and tested with pinned data. By hand before publishing it: a Google OAuth2 credential
(scope `business.manage`, the Google account added as a manager of each business's profile) on "Get Google reviews" and
"Post reply on Google", and the Anthropic key on "Ask AI". Google's v4 review endpoints are untested against the real API.
Tests: `tests/features/run.sh` (staging only, 67 checks).
