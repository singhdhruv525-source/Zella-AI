# Zella AI: remediation checklist

From the end-to-end audit of 29 October 2026 (`docs/ZELLA_END_TO_END_AUDIT.md`). Ticked items are done and verified.

## Done in this audit (applied to production and re-tested)

- [x] H-1: links to another business's customer, staff member or user are refused (`sql/zella_tenant_links.sql`)
- [x] H-2: no direct browser writes to calls, texts, emails, conversations, notifications, support tickets,
      integrations or automations (`sql/zella_write_lockdown.sql`)
- [x] M-1: "Test it yourself" test questions readable again
- [x] M-2: the business app no longer says "saved" when the database refused the change
- [x] L-6: search path pinned on `zella_usage_billable_seconds`

## Needs you (manual: accounts, money, or a decision)

Before real customers:
- [ ] **Host the app and set its address.** Buy the domain, deploy `web/` (for example to Vercel), then set:
  - `app_base_url` in platform settings;
  - `ZELLA_APP_URL` in the Supabase edge-function secrets.

  Invitations, reschedule links and waitlist links depend on this (M-5).
- [ ] **Clean up test businesses** in Admin > Businesses > lifecycle: "ftyuyguygiug", "hawkye cafe" and "Roohani Cafe"
      are unfinished test setups; "test saloon" holds test data. Deleting is permanent, so this is left to you.
- [ ] **Decide on restricted admin roles (M-3).** If support, billing or read-only admins should exist, the
      `platform_admins` role check must be widened. Say the word and it can be done.
- [ ] **Decide who may read call transcripts and recordings (M-4).** Staff can read them on the Calls page today,
      while the recording button is owner/admin only. Pick one rule.
- [ ] Confirm members of a **suspended** business should keep access to their data (L-5).
- [ ] Delete the two leftover edge functions `smart-action` and `zella-admin-check-v2` (Supabase dashboard > Edge
      Functions) (L-1).
- [ ] Optional: upgrade to Supabase Pro to turn on leaked-password protection (L-3).

Connecting providers, in this order (each needs your account and keys, entered in Supabase secrets or platform
settings, never in chat):
- [ ] Vapi: assign each business's number (Admin > Voice & numbers > Assign a number) and check the assistant.
- [ ] Telnyx: set `sms_from_number`, then test with one number before switching `sms_live` on.
- [ ] Resend: set `email_from_address` (verified domain), then test before switching `email_live` on.
- [ ] n8n: store the `zella_n8n_secret` vault secret, publish the workflows, then switch the `zella_dispatch` job on
      (n8n/GO-LIVE.md).
- [ ] Stripe: set the billing webhook secret so `billing-webhook` stops answering "not configured".
- [ ] Provider health checks: switch them on, so the admin pages show real connection status instead of
      "checks off".

## Small follow-ups (can be done any time)

- [ ] `staff-invite`: check the caller's sign-in before the configuration (L-2).
- [ ] Hide `businesses.inbound_email_token` from view-only members (L-4).
- [ ] After hosting, re-run the browser tests against the live address and the SQL suites (`tests/features/run.sh`,
      `tests/voice-reliability/run_all.sh`).
