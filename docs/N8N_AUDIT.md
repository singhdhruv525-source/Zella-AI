# n8n audit (2026-10-25)

Checked all 25 workflows in `n8n/workflows/` against the live n8n Cloud copies and the dispatcher lanes.

## Fixed live
- **Per-call time limits**: the repo files had 30s / 60s / 15s / 10s limits on every HTTP call, but the live copies did not. Now applied to every HTTP node in all 25 live workflows.
- **Database sign-in**: the repo files name the credential "Zella Supabase service role" but with an empty id. Live, at least one node ("Claim follow-ups") had no credential attached. The credential (id ZR3dB5RmNP0xAceV) is now attached to every database call in all 25 workflows.
- **Two workflows were never created live**: "Zella - Receptionist Brain Tools" (`zella/vapi-brain`) and "Zella - Call Intelligence" (`zella/run/call-intel`). Both are created now, unpublished, from the repo definitions. Call Intelligence "Ask AI" has no Anthropic key attached on purpose.

## Still open (needs a decision or your hands)
- All workflows are inactive by design. Publish at go-live, then run `sql/zella_dispatcher.sql` last.
- Add the Telnyx, Resend, Anthropic and Vapi keys by hand on the n8n box.
- No failure alerting yet: no `errorWorkflow` is set. Add one shared "Zella - Alert" workflow (Error Trigger -> email to you) and point all 25 at it.
- No retry on the outside-service calls. The database already retries failed tasks (15 min, 30 min on a 429), so this is low risk.
- Public webhooks with no n8n-side auth (resend, inbound-email, meta) depend on the database checking the key or signature. Resend (Svix) signatures are not verified yet.
- Live Code nodes were not diffed line by line against the repo; only HTTP node settings were compared.
