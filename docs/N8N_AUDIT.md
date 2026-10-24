# n8n audit (2026-10-25)

Checked all 25 workflows in `n8n/workflows/` against the live n8n Cloud copies and the dispatcher lanes.

## Fixed live
- **Per-call time limits**: the repo files had 30s / 60s / 15s / 10s limits on every HTTP call, but the live copies did not. Now applied to every HTTP node in all 25 live workflows.
- **Database sign-in**: the repo files name the credential "Zella Supabase service role" but with an empty id. Live, at least one node ("Claim follow-ups") had no credential attached. The credential (id ZR3dB5RmNP0xAceV) is now attached to every database call in all 25 workflows.
- **Two workflows were never created live**: "Zella - Receptionist Brain Tools" (`zella/vapi-brain`) and "Zella - Call Intelligence" (`zella/run/call-intel`). Both are created now, unpublished, from the repo definitions. Call Intelligence "Ask AI" has no Anthropic key attached on purpose.

## Added after the first pass
- **Failure alert workflow** "Zella - Failure Alert" created live (not published). It raises one deduped platform alert per workflow and step, without customer data. Tested: a repeat failure updates the same alert. Hooking the 25 workflows up to it needs it published first, so it is a go-live step (docs/GO_LIVE.md).
- **Resend signature check** (Svix HMAC, 5 minute window) built, applied live and tested for good, wrong, tampered, old and missing signatures. Email Events and Inbound Email now keep the raw body and call the signed functions. Off until the signing secret is put in Vault. Meta already verified its signature.

## Still open (needs your hands)
- Publish the alert workflow, then set it as the error workflow on all 25.
- Put the Resend signing secret in Vault.
- Telnyx, Resend, Anthropic and Vapi keys on n8n.
- Publish the workflows, then run `sql/zella_dispatcher.sql` last.
- No retry on outside-service calls; the database retries failed tasks (15 min, 30 on a 429), so this is low risk.
- Live Code nodes were not diffed line by line against the repo; only HTTP node settings were.
