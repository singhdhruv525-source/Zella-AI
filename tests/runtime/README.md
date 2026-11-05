# Edge functions in the Supabase edge runtime

`start.sh` serves every function in `web/supabase/functions` from Supabase's own edge runtime image
(`public.ecr.aws/supabase/edge-runtime`, default `v1.78.0`, the newest on 5 Nov 2026). Each function runs in its own
worker with memory and CPU limits, as on the hosted platform (`edge-main/index.ts` routes `/<function>` to its folder).
Calls go through the local Supabase stand-in, so sign-in, row security, grants and RPCs are the real ones from the
isolated database. Test-only keys; nothing is sent.

    setsid dockerd &                                  # if Docker isn't running
    docker pull public.ecr.aws/supabase/edge-runtime:v1.78.0
    tests/runtime/start.sh
    node tests/runtime/edge_functions.mjs             # google-lead, website-lead, reschedule-appointment, staff-invite,
                                                      # continue-plan, billing-webhook, voice-rules (30 checks)
    node tests/browser/record-files-e2e.mjs           # record-files (23 checks)
    node tests/browser/wizard-journey.cjs             # owner-provision-business in a browser (23 checks; needs the app
                                                      # preview on :5199, see tests/browser/README.md)

Results on 5 Nov 2026 (v1.78.0): all passed.

On the older v1.69.6 image, the five functions with a `deno.lock` (continue-plan, owner-provision-business,
reschedule-appointment, staff-invite, voice-rules) fail to start: "Unsupported lockfile version". Those lockfiles are
version 5 (written by Deno 2.3 or later, committed 28 Oct). Deploy with a current Supabase CLI. The other four
functions ran on both versions.

Not covered here: Supabase's hosted gateway (verify_jwt, request size limits, regional routing), real provider
accounts (Google, Stripe, Vapi, Telnyx), and secrets as set on the hosted project.
