# Zella AI: where things stand (handoff notes)

Kept up to date so work can continue in a new session without losing anything. No secrets are kept here:
keys and passwords live only in Supabase secrets/vault, Vapi, GoDaddy and Resend.

Last updated: 30 October 2026.

## Ground rules (always in force)

- Never print, commit or ask for secrets, service-role keys or provider keys in chat. The owner enters them
  in the provider dashboards.
- Back up before any destructive or production change. Never drop or recreate tables. Never disable RLS.
- Don't fabricate test results. No fake or seeded production data.
- Don't change the live Vapi assistants; use the test assistant (`tests/vapi/load-test-assistant.mjs`).
- Don't switch on `sms_live`, `email_live`, `calls_live`, schedulers, the `zella_dispatch` job or n8n workflows,
  and don't send real SMS/email or place calls, without the owner's approval.
- Don't create plans or prices. Don't invent voice IDs or model names.
- Work directly on `main` (owner, 3 Nov): no new branches, no other Codespaces. `voice-reliability` was merged into `main` on 3 Nov.

## Accounts and setup

- Supabase project `pffqxlumqhjdbzvvoszm`. Web app in `web/` (React/Vite): admin dashboard at `/`,
  business CRM at `/app`.
- Domains (GoDaddy, with GoDaddy email): **zellavoice.com** (main) and **zellaai.in** (spare; forward or leave).
  Keep DNS at GoDaddy; don't change nameservers or delete the email MX records.
  Status 30 Oct: zellavoice.com paid (domain, Full Domain Protection, Professional Email Pro Light) but still in
  GoDaddy's "fulfillment" (support chat confirmed; visible within a few hours). Until it shows in Domains >
  Portfolio, don't add DNS records by hand and don't buy it again. Once it shows, finish the Email setup (GoDaddy
  should add the email records itself), then hosting.

## Voice (Vapi)

- Vapi is connected through a custom credential using HMAC (headers `x-signature`, `x-timestamp`; secret in the
  Supabase vault as `zella_vapi_hmac_secret`). The self-test with a correct signature returns 200.
- Platform voice settings: ElevenLabs voice `burt` with model `eleven_v4_turbo`; Deepgram `nova-2-phonecall`
  (en-US); Claude Sonnet as the assistant's model (set in `platform_settings`).
- Each business can pick its own voice from 15 approved ElevenLabs voices (`voice_tts_choices`). Owners, admins,
  managers or a Zella admin can change it: business Settings > Receptionist, or Admin > business > AI receptionist
  (`sql/zella_business_voice.sql`, `web/src/settings/VoicePanel.jsx`).
- Test assistant "test saloon receptionist" loaded with the generated config; it answers.
- Auth switched 30 Oct from HMAC to a Bearer token: Vapi kept the HMAC credential and every tool linked to it, but
  sent no signature on real calls. Same credential id, now `authenticationPlan.type = bearer`
  (`tests/vapi/switch-credential-to-bearer.mjs`); token in vault `zella_vapi_bearer_token`; setting
  `vapi_auth_mode` = "bearer" (set it back to "hmac" to undo). Database check passes (right token ok, wrong refused,
  missing refused). A test call after that was still refused: Vapi sent no Authorization header at all, so it
  doesn't apply the linked credential. Fix: the loader now puts the token straight into each server's headers
  (`ZELLA_VAPI_TOKEN=... node tests/vapi/load-test-assistant.mjs <id>`); test assistant
  `edd2c398-deed-453f-8832-dc69517054a3` reloaded 30 Oct with the token on all 16 servers.
  **Next (owner, 31 Oct):** Talk to the test assistant, ask "Are you open tomorrow?" (don't book), then check
  voice-rules logs for 200s. If they pass, real assistants need the same headers: send them from the server side
  (token from vault) instead of the test loader.

## Knowledge base

- Knowledge items become ready only through the n8n "Zella - Knowledge" workflow (unpublished).
- AI drafting (`knowledge_ai_live`) stays off: it needs an Anthropic API key, skipped for now (no budget).

## Hosting (in progress, owner's steps)

Cloudflare Pages:
- project settings: root `web`, build `npm run build`, output `dist`, production branch `main`;
- env vars `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY` (both public);
- custom domains `app.zellavoice.com` (opens the CRM) and `admin.zellavoice.com`, via CNAME records in
  GoDaddy DNS to the `.pages.dev` address.

After it's live, set:
- `ZELLA_APP_URL` (edge secret) and `app_base_url` (setting) to `https://app.zellavoice.com`;
- `ZELLA_ALLOWED_ORIGINS`;
- the Supabase Auth Site URL and redirect URLs;
- then test the live site.

## Email (in progress)

Two kinds of email:
1. **People inboxes (GoDaddy Professional Email Pro Light, 3 mailboxes; DNS records added by GoDaddy and checked):**
   mailboxes `dhruv@zellavoice.com` and `abhishek@zellavoice.com` (both GoDaddy email admins), one mailbox free.
   Aliases (reply "From" the alias): `info@`, `support@` on abhishek@; `billing@`, `hello@` on dhruv@.
   Next: test each address from Gmail, then switch Dhruv's super-admin login from Gmail to `dhruv@zellavoice.com`
   (Supabase > Authentication > Users > change email; admin rights follow the user id). Zella's automatic emails
   will use reply-to `support@zellavoice.com`.
2. **Automatic emails (Resend):** workspace "zellavoice", signed up with dhruv@zellavoice.com. Domain
   `zellavoice.com` **verified** 30 Oct (us-east-1, auto-configured through GoDaddy): TXT `resend._domainkey`,
   CNAMEs `send` and `rsend` (to `*.forge.rmta.net`). Receiving OFF (root MX stays GoDaddy), click/open tracking
   OFF (would break sign-in links). GoDaddy's own email records unchanged.
   Next:
   - DONE 30 Oct: Supabase custom SMTP set to Resend (`smtp.resend.com`, 465, user `resend`, sender
     `Zella Voice <no-reply@zellavoice.com>` (renamed from Zella AI, owner to change in Supabase)); test magic link to the owner's Gmail arrived in the inbox.
   - Next: owner pastes the branded templates from `docs/EMAIL_TEMPLATES.md`; later set `email_from_address`
     and reply-to support@ for Zella's own emails.

   `email_live` stays off until approved.

## Security review 2026-11-04 (deployed except owner-provision-business)

Fixes for invitations, billing, currency, MFA, navigation and invitation errors are applied live (SQL, staff-invite,
billing-webhook). owner-provision-business deployed 2026-11-04 (version 11); the web app goes live with hosting. See `docs/SECURITY_REVIEW_2026-11-04.md` for the findings, test results and the order to apply them
(needs the owner's approval).

## Full review 2026-11-04 (second pass): fixes in the repo, approvals pending

`docs/REVIEW_2026-11-04_FULL.md` has the findings, the page-by-page coverage and the test results.

Fixed in the web app, which ships with hosting:

- five CRM pages crashing on live automation data;
- template and customer-search scoping across businesses;
- setup wizard: unsaved-changes guard, honest checkmarks, double-submit;
- appearance save status, retry and safe picture clean-up;
- contrast (Classic and Glass), icon-font fallback, Inter weights, accessibility labels, mobile overflow;
- status copy that claimed things it couldn't know.

**Waiting for approval (not applied):**

- ~~`sql/zella_platform_alerts_policy_fix.sql`~~: applied 2026-11-04 (admin alerts bell).
- `sql/zella_platform_roles_fix.sql`: the restricted platform roles are blocked by an old trigger.
- ~~Deploying `owner-provision-business`~~: deployed 2026-11-04 (version 11), with the owner invitation fixes, server-side finish checks, admin-invite email check and rebrand default name.

Browser tests can now run against a local real-schema backend: see `tests/browser/README.md`.

## Second admin/CRM pass 2026-11-04 (repo only, not deployed)

On top of the parallel review: setup completion claims the owner invitation before emailing and activates only after
the email went out (needs a new owner-provision-business deploy; live is version 11); honest wizard result; direct links
to admin pages a role lacks say so; customer links cut short never show the admin sign-in; failed loads no longer look
empty; header and tablet sidebar fit; lifecycle tests. Details: `docs/ADMIN_CRM_REVIEW_2026-11-04.md`.

## Waiting on the owner's answers

- What's missing in the app (they chose "something missing" without details).
- Call transcripts/recordings: owners and managers only, or all staff (M-4).
- Suspended businesses: keep read-only access (L-5)?
- Remove the never-used typo super admin abhidakshmurya@gmail.com?

## Still to do later

- Super admins: three `zella_owner` accounts. One (abhidakshmurya@…) has never signed in and looks like a typo
  of abhidakshmaurya@…; remove it only if the owner says yes.

- Assign phone numbers to businesses (Admin > Voice & numbers).
- n8n: vault secret `zella_n8n_secret`, publish workflows, `zella_dispatch` job on (see `n8n/GO-LIVE.md`).
- Telnyx SMS (`sms_from_number`), Stripe billing webhook secret, provider health checks.
- Anthropic key for knowledge AI drafting when budget allows.
- Trademark check for the name "Zella".
- Rebrand to "Zella Voice": done 30 Oct in the app (titles, logos, sign-in pages, status page), emails, SMTP sender
  and new receptionists' default name (`sql/zella_rebrand_voice.sql`). Left: the owner function's default
  platform name in `owner-provision-business/settings.ts` is changed in the repo but goes live with the next deploy
  of that function. The receptionist's own prompt never named Zella, so calls are unaffected.
- Audit follow-ups M-3, M-4, M-5, L-1 to L-5: see `docs/ZELLA_REMEDIATION_CHECKLIST.md`
  (full audit in `docs/ZELLA_END_TO_END_AUDIT.md`).
