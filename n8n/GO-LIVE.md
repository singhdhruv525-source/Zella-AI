# Zella go-live checklist (kept up to date as automations are built)

Nothing below has been done yet on purpose: all n8n workflows are unpublished and the timers are paused until testing.

## Database (Supabase)
1. Re-run `sql/zella_dispatcher.sql` once (adds the outbound-calls and knowledge lanes and the stuck-call sweep, and restarts the timers).
2. Store the n8n secret in Vault (`zella_n8n_secret`), as described at the end of the dispatcher file.
3. Store the Resend webhook key: `select vault.create_secret('<long random value>', 'zella_resend_webhook_key');`
4. Set `app_base_url` (your web address) so reschedule and waitlist links appear in messages.
5. Switch live flags only when each provider is ready: `sms_live`, `email_live`, `calls_live`, `knowledge_ai_live`.
6. Run `sql/zella_security_hardening.sql` if not done; turn on leaked-password protection.

## Web app and functions
7. Deploy the edge function `reschedule-appointment` and the web app (pages `/r/<code>` and `/w/<code>`); redeploy `owner-provision-business`.

## Providers (keys go on the n8n boxes by hand, never in chat)
8. Telnyx: account, number, 10DLC registration (can take days), key on the "Send via Telnyx" box.
9. Resend: verify the sending domain, key on the "Send via Resend" boxes, add the webhook `https://<n8n>/webhook/zella/resend?key=<value>` (delivered, bounced, complained).
10. Vapi: account, assistant, phone number; ids into `vapi_assistant_id` and `vapi_phone_number_id`; key on the "Start Vapi call" box.
    - Server URLs (with header `X-Zella-Secret`): end-of-call reports to `/webhook/zella/vapi` (end-of-call-report only); tools to `/webhook/zella/vapi-tools` (`report_unanswered_question`) and `/webhook/zella/vapi-booking` (`check_availability`, `book_appointment`, `find_my_appointments`, `reschedule_appointment`, `cancel_appointment`).
    - Each call must carry the business id until the phone-number-to-business link is built.
11. Anthropic key on the "Ask AI" box in the Knowledge workflow.

## n8n
12. Publish the workflows (gateway, router, the sender and worker workflows, Call Results, Knowledge, Assistant Tools, Appointment Booking, Email Events), then test everything together.

## Not built yet
- Phone number to business link for inbound calls
- Invitation reminder emails (needs the sign-up link and domain)
- Unsubscribe link and page for marketing emails (reactivation emails stay skipped until then)
- Choosing a specific staff member and per-service lengths in phone booking
- 5-minute batching setting, document or website upload into knowledge
