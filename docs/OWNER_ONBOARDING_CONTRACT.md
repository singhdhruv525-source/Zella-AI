# Owner onboarding: the contract between the screens and the server

Status: **version 3, 17 Nov 2026.** Built on branch `claude/owner-onboarding-backend`; nothing is applied to
production or deployed. Changes to this contract are listed here, newest first, and are additive unless marked.

| Version | Date | Change |
|---|---|---|
| 3 | 17 Nov 2026 | Additive. (a) Each section carries `data_hash`, the fingerprint of the `data` shown; 5.4 takes it as `p_seen_hash`, and Looks right on details that changed since is refused with `DETAILS_CHANGED`. (b) A plan version saved after the owner accepted can be accepted from the plan screen (5.5) while the journey isn't finished; until it is, steps 6 and 7 answer `PLAN_CHANGED`. (c) `zella_activation_report` leaves out the `identity` and `payment` checks for team members other than the owner. (d) Step 6 and the payment check of the go live gate: the owner's rule and how it changes once Stripe is live (sections 2 and 3). |
| 2 | 16 Nov 2026 | Additive clarifications, no call or field removed or renamed. (a) `MFA_REQUIRED` can also come from the request check that runs before every database call: HTTP 403 with `code` `42501` and `message` `MFA_REQUIRED`. Always read the code from `message` (section 4). It applies to every owner call, reads included, whenever the owner has a verified authenticator and the session wasn't verified with a code. (b) Owner calls answer `NOT_ALLOWED` for a business that doesn't exist too, so nobody can probe for ids; `NOT_FOUND` comes only from the admin calls. (c) The state also carries `started` (false until the first write) and `resumed_at`. (d) Who can read the progress tables directly: the business's owner and Zella Voice admins with `businesses.view`; no other team member. (e) When the last allowed identity attempt fails, Zella Voice gets an admin alert to review it by hand. |
| 1 | 16 Nov 2026 | First version. |

The screens (branch `claude/owner-onboarding-screens`) call only what is listed here. Every rule is decided by the
database (`NN-6`); the screens never decide whether a step is done, they ask and show the answer.

## 1. Where the calls live, and why

| Kind | Name | Called with |
|---|---|---|
| Database functions (owner) | `zella_owner_onboarding_*` | `supabase.rpc(name, args)` with the owner's own session |
| Edge function (owner) | `owner-onboarding` | `supabase.functions.invoke("owner-onboarding", { body })` with the owner's own session |
| Database functions (Zella Voice admins) | `zella_admin_onboarding_*` | `supabase.rpc(name, args)` with the admin's session |
| Edge function (identity provider) | `identity-webhook` | the provider only; never the screens |

Owner actions never go through `owner-provision-business`: that function refuses anyone who is not a Zella Voice
admin. The owner's rules (which step comes next, what counts as done, who may act) are database functions, like
`zella_accept_my_invitations` and `zella_request_activation` today, so the database enforces them. Only the document
upload needs an edge function, because a file upload link for the private `business-documents` bucket needs the
server key.

**Who may call.** Every owner call checks, in the database, that the caller is signed in and is an **active owner**
(`business_members.role = 'owner'`, `status = 'active'`) of **that** business. An owner of another business, a team
member of any role, a Zella Voice admin and an anonymous caller are all refused with `NOT_ALLOWED` (or
`NOT_SIGNED_IN`). From step 3 on, every write also needs a session verified with the authenticator code (`aal2`),
otherwise `MFA_REQUIRED`.

**Before the first call.** The owner arrives on `/welcome` from the invitation email. After the link is confirmed
(`verifyOtp`), call the existing `zella_accept_my_invitations()` so the owner's membership becomes active, then
`zella_owner_onboarding_list()`. The welcome page already does both in its current flow (accept after the password);
the screens may move the accept earlier, before the password, because the session is proved by the email link.

## 2. Steps and sections

| # | `step` key | Screen | Done when (checked by the server) |
|---|---|---|---|
| 1 | `welcome` | Welcome | the owner presses Get started |
| 2 | `security` | Password and two step sign in | the account has a password, a verified authenticator, and this session was verified with a code (`aal2`) |
| 3 | `details` | Check your details | all four sections are `looks_right` and nothing changed since |
| 4 | `identity` | Verify your identity | identity `status` is `verified` (documents approved in Verification, or the provider approved) |
| 5 | `plan` | Your plan | the owner accepted the current plan version |
| 6 | `payment` | Pay or start a trial | a payment is confirmed (today always `waiting`: payments are not connected). The owner decided on 16 Nov 2026 that pay before going live applies only once Stripe is live (`docs/MEMORY.md`); the payments work (lane F, `sql/zella_stripe_payment_gate.sql`) makes this step and the go live payment check wait for a payment only while payments are live, and until then step 6 shows "Payment opens here soon" and can be passed. As built in this file alone, step 6 always waits, so no owner reaches step 7 before that change |
| 7 | `done` | You're all set | the owner pressed Open my CRM (records that the journey is finished) |

Steps are strictly in order. `current_step` is the first step that is not done. A step before it is `done`, the
current one is `current`, later ones are `locked`. Completing a step that is already done changes nothing and returns
`changed: false`. Completing a later step returns `STEP_LOCKED`.

| `section` key | What the owner checks |
|---|---|
| `business` | name, legal name, industry, phone, email, website, address, time zone, description |
| `hours_services` | opening hours, services, whether bookings are taken |
| `team` | team members (name, title, email, phone) |
| `receptionist_phone` | receptionist name, greeting, language, voice, where calls are transferred, fallback number, phone setup and numbers |

Section `status`: `to_review` (not answered yet), `looks_right`, `change_requested` (the owner sent a note; waiting for
Zella Voice), `updated` (the details changed after the owner said Looks right, or Zella Voice marked the change done:
check again). Only `looks_right` counts toward finishing step 3. Sections can be answered only while
`current_step` is `details`; afterwards the answer is `STEP_CLOSED` (changes then go through the CRM's own settings).

## 3. The rules in force (owner decisions taken as defaults)

The state carries them in `rules`, so the screens can show the right words. Each one is one server constant,
`public.zella_onboarding_rules()`.

| Key | Value now | Meaning |
|---|---|---|
| `identity_provider` | `"none"` | manual upload: the owner's documents are checked by Zella Voice in Verification. Later `"persona"`. |
| `plan_choice` | `"accept_only"` | the owner sees the plan Zella Voice set and accepts it; no switching |
| `first_payment` | `"pay_before_live"` | a confirmed payment is needed before the receptionist goes live. With the payment gate (lane F), it is `"not_until_payments_live"` while payments aren't live: no payment is needed then (the owner's decision of 16 Nov 2026). The other value, `"trial_with_card"`, is not built |
| `failed_check` | `"retry_then_review"` | after a failed check the owner can try again; after `identity_attempts` failures it goes to manual review |
| `identity_attempts` | `2` | failed checks allowed before manual review |
| `payments_connected` | `false` | Stripe Checkout is not built; step 6 shows waiting |

## 4. Error codes

Database functions raise the code as the error `message` (PostgREST answers `{ "code": "P0001", "message": "<CODE>",
"details": <text or null> }`). The edge function answers `{ "error": "<plain words>", "code": "<CODE>" }`. Show the
words from this table; never show the raw code or anything after it.

| Code | When | Words to show (no dashes) |
|---|---|---|
| `NOT_SIGNED_IN` | no session | "Please sign in again." |
| `NOT_ALLOWED` | not an active owner of this business | "Only the business owner can do this." |
| `NOT_FOUND` | no such business (or not yours) | "We couldn't find that business." |
| `MFA_REQUIRED` | step 3 or later without a code verified session | "Enter the code from your authenticator app to continue." |
| `BUSINESS_NOT_AVAILABLE` | the business is suspended or cancelled | "This workspace is paused. Contact Zella Voice support." |
| `INVALID_INPUT` | unknown step, section or decision, bad version | "That didn't work. Reload the page and try again." |
| `STEP_LOCKED` | an earlier step isn't done | "Finish the earlier steps first." |
| `STEP_CLOSED` | the section answer came after step 3 was done | "These details are already confirmed. You can change them in Settings." |
| `NOTE_REQUIRED` | Change without a note, or a note over 1000 characters (`details`: `too_long`) | "Tell us what should change." / "Keep the note under 1000 characters." |
| `SECURITY_INCOMPLETE` | step 2 not ready; `details` lists what is missing: `password`, `authenticator`, `code` | "Set a password and add an authenticator app first." |
| `SECTIONS_NOT_CONFIRMED` | step 3 with a section not `looks_right`; `details` lists them | "Check every section first." |
| `IDENTITY_NOT_VERIFIED` | step 4 before identity is `verified` | "We're still checking your identity." |
| `UPLOAD_NOT_ALLOWED` | an upload while identity is `checking`, `verified` or `in_review` | "We already have your documents." |
| `PLAN_MISSING` | no plan saved for the business | "Your plan isn't ready yet. Zella Voice will be in touch." |
| `PLAN_CHANGED` | the plan version accepted isn't the current one | "Your plan was just updated. Please review it again." |
| `DETAILS_CHANGED` | Looks right on details that changed since the owner saw them | "These details were just updated. Please check them again." |
| `PAYMENT_NOT_CONFIRMED` | step 6 before a payment is confirmed | "We haven't received a payment yet." |
| `rate_limited` | reserved | "Too many attempts. Wait a minute and try again." |

## 5. Owner calls

All dates are ISO 8601 UTC strings or `null`. Money is integer cents with `currency`.

### 5.1 `zella_owner_onboarding_list()`

Businesses the caller owns (active owner), for choosing one. No arguments.

```json
{ "businesses": [
  { "business_id": "6f1c0c1e-0000-4000-8000-000000000001", "business_name": "Glow Studio",
    "current_step": "details", "completed": false }
] }
```

An owner with no business gets `{ "businesses": [] }`. Errors: `NOT_SIGNED_IN`.

### 5.2 `zella_owner_onboarding_get(p_business_id uuid)`

Read only. The whole journey for one business, with what every screen needs. Errors: `NOT_SIGNED_IN`,
`NOT_ALLOWED`, `NOT_FOUND`.

```json
{
  "business_id": "6f1c0c1e-0000-4000-8000-000000000001",
  "business_name": "Glow Studio",
  "rules": { "identity_provider": "none", "plan_choice": "accept_only", "first_payment": "pay_before_live",
             "failed_check": "retry_then_review", "identity_attempts": 2, "payments_connected": false },
  "current_step": "details",
  "current_step_number": 3,
  "steps_total": 7,
  "started_at": "2026-11-16T15:00:00Z",
  "paused_at": null,
  "completed_at": null,
  "business_available": true,
  "steps": [
    { "key": "welcome",  "number": 1, "state": "done",    "reached_at": "2026-11-16T15:00:00Z", "completed_at": "2026-11-16T15:00:05Z" },
    { "key": "security", "number": 2, "state": "done",    "reached_at": "2026-11-16T15:00:05Z", "completed_at": "2026-11-16T15:02:00Z" },
    { "key": "details",  "number": 3, "state": "current", "reached_at": "2026-11-16T15:02:00Z", "completed_at": null },
    { "key": "identity", "number": 4, "state": "locked",  "reached_at": null, "completed_at": null },
    { "key": "plan",     "number": 5, "state": "locked",  "reached_at": null, "completed_at": null },
    { "key": "payment",  "number": 6, "state": "locked",  "reached_at": null, "completed_at": null },
    { "key": "done",     "number": 7, "state": "locked",  "reached_at": null, "completed_at": null }
  ],
  "security": { "password_set": true, "authenticator": true, "session_verified": true, "ready": true },
  "details": {
    "sections": [
      { "key": "business", "status": "looks_right", "note": null, "admin_note": null,
        "answered_at": "2026-11-16T15:03:00Z", "data_hash": "5d41402abc4b2a76b9719d911017c592",
        "data": { "name": "Glow Studio", "legal_name": "Glow Studio LLC", "industry": "Salon and spa",
                  "phone": "+15555550100", "email": "owner@example.com", "website": "https://glow.example",
                  "address": { "line_1": "1 Main Street", "line_2": null, "city": "Austin", "state": "TX",
                               "postal_code": "78701", "country": "US" },
                  "timezone": "America/Chicago", "description": "Hair and nails." } },
      { "key": "hours_services", "status": "to_review", "note": null, "admin_note": null, "answered_at": null,
        "data": { "hours": [ { "weekday": 1, "opens": "09:00", "closes": "17:00" } ],
                  "services": [ { "name": "Haircut", "duration": "45 min", "price": "$40" } ],
                  "takes_bookings": true } },
      { "key": "team", "status": "change_requested", "note": "Add Maya, she started this week.", "admin_note": null,
        "answered_at": "2026-11-16T15:04:00Z",
        "data": { "members": [ { "name": "Sam Lee", "title": "Stylist", "email": "sam@example.com", "phone": null } ] } },
      { "key": "receptionist_phone", "status": "updated", "note": null, "admin_note": "Greeting changed as asked.",
        "answered_at": "2026-11-16T15:05:00Z",
        "data": { "name": "Ava", "greeting": "Thanks for calling Glow Studio.", "language": "en-US", "voice_id": null,
                  "transfer_to": { "type": "owner", "name": "", "phone": "" },
                  "fallback_number": "+15555550101",
                  "phone_setup": { "mode": "call_forwarding", "forward_from": "+15555550100", "area_code": "" },
                  "numbers": [ { "e164": "+15555550102", "status": "active" } ] } }
    ],
    "all_looks_right": false
  },
  "identity": {
    "status": "checking",
    "attempts_used": 0,
    "attempts_allowed": 2,
    "can_upload": false,
    "upload_kinds": [],
    "documents": [
      { "kind": "owner_identity", "status": "pending_review", "review_note": null,
        "uploaded_at": "2026-11-15T10:00:00Z", "reviewed_at": null },
      { "kind": "business_registration", "status": "verified", "review_note": null,
        "uploaded_at": "2026-11-15T10:00:00Z", "reviewed_at": "2026-11-16T09:00:00Z" }
    ]
  },
  "plan": {
    "available": true,
    "accepted": false,
    "accepted_version": null,
    "accepted_at": null,
    "current": { "version": 1, "tier": "base", "billing_interval": "monthly", "price_cents": 9900,
                 "setup_fee_cents": 0, "currency": "USD", "minutes": 300, "texts": 200, "emails": 200,
                 "team_seats": 3, "phone_numbers": 1, "locations": 1, "languages": ["en"],
                 "trial_enabled": false, "overage_cents_per_minute": null }
  },
  "payment": { "status": "locked", "reason": "identity_first", "checkout_available": false, "confirmed_at": null },
  "go_live": { "ready": false, "live": false,
               "checks": [ { "key": "identity", "label": "Owner identity verified", "ok": false },
                           { "key": "payment", "label": "First payment confirmed", "ok": false } ] }
}
```

Notes:
- `details.sections[].data` is the server's snapshot of what Zella Voice entered. `null` values mean "not set".
  Team phone and email are shown to the owner of the business only.
- `identity.status`: `needed` (a required document is missing: upload it), `checking` (waiting for Zella Voice or
  the provider), `verified`, `try_again` (a document was rejected: `review_note` says why; upload a new copy),
  `in_review` (the allowed attempts are used up: Zella Voice reviews it by hand, no upload). Labels: Documents
  needed, Checking, Verified, Try again, In review.
- `identity.upload_kinds` lists the document kinds the owner may upload now (`owner_identity`,
  `business_registration`); empty unless `can_upload`.
- `plan.available` is false when no plan is saved (then `current` is `null`). `estimate` and margin warnings are never
  sent to the owner.
- `payment.status`: `locked` (reason `identity_first`: identity isn't verified yet, so checkout can't open),
  `waiting` (reason `payments_not_connected`), `confirmed`. `checkout_available` stays `false` until Stripe
  Checkout is built.
- `go_live` is the same checklist as the CRM's AI receptionist page (`zella_activation_report`), including the two
  new checks. Going live itself stays in the CRM (`zella_request_activation`).

### 5.3 `zella_owner_onboarding_complete_step(p_business_id uuid, p_step text)`

Finishes one step. Returns `{ "changed": true|false, "state": <the 5.2 object> }`.

| `p_step` | Extra checks | Extra errors |
|---|---|---|
| `welcome` | none | |
| `security` | password, verified authenticator, `aal2` session, read from the auth records | `SECURITY_INCOMPLETE` (`details`: comma list of `password`, `authenticator`, `code`) |
| `details` | every section `looks_right` and unchanged | `SECTIONS_NOT_CONFIRMED` (`details`: comma list of section keys) |
| `identity` | identity `verified` | `IDENTITY_NOT_VERIFIED` |
| `plan` | the current plan version accepted (normally done by 5.5 instead) | `PLAN_MISSING`, `PLAN_CHANGED` |
| `payment` | a confirmed payment (see step 6 in section 2), and the current plan version accepted | `PAYMENT_NOT_CONFIRMED`, `PLAN_CHANGED` |
| `done` | the current plan version accepted (records the end of the journey) | `PLAN_CHANGED` |

Always possible: `NOT_SIGNED_IN`, `NOT_ALLOWED`, `NOT_FOUND`, `BUSINESS_NOT_AVAILABLE`, `INVALID_INPUT`,
`STEP_LOCKED`, `MFA_REQUIRED` (from `details` on).

```json
{ "changed": true, "state": { "current_step": "security", "...": "as in 5.2" } }
```

### 5.4 `zella_owner_onboarding_section(p_business_id uuid, p_section text, p_decision text, p_note text default null, p_seen_hash text default null)`

`p_seen_hash`: the section's `data_hash` from the state the owner was shown. With `looks_right`, if the details changed
since, the answer is `DETAILS_CHANGED` and nothing is recorded: reload and show the new details.

`p_decision`: `looks_right` or `change`. A change needs a note (1 to 1000 characters); it reaches Zella Voice as an
alert on the admin dashboard and in the business's onboarding progress. Saying `looks_right` after asking for a change
withdraws the request. Sending the same answer again changes nothing (`changed: false`).

Returns `{ "changed": true|false, "state": <5.2> }`. Errors: as 5.3, plus `NOTE_REQUIRED`, `STEP_CLOSED`, `DETAILS_CHANGED`.

```json
{ "changed": true, "state": { "details": { "sections": [ { "key": "team", "status": "change_requested",
  "note": "Add Maya, she started this week.", "...": "..." } ], "all_looks_right": false }, "...": "..." } }
```

### 5.5 `zella_owner_onboarding_plan_accept(p_business_id uuid, p_plan_version integer)`

Accepts the plan shown (pass `state.plan.current.version`) and completes step 5. Accepting the same version again
changes nothing. If Zella Voice saves a new version after step 5 is done (`state.plan.accepted` is false again), the
owner accepts the new version here; the journey stays on its current step, and steps 6 and 7 answer `PLAN_CHANGED`
until then. Once the journey is finished the answer is `STEP_CLOSED`. Errors: as 5.3, plus `PLAN_MISSING`,
`PLAN_CHANGED` (reload and show the new plan).

### 5.6 `zella_owner_onboarding_identity_status(p_business_id uuid)` and `zella_owner_onboarding_payment_status(p_business_id uuid)`

Read only, for polling while a screen waits (every 15 seconds at most). They return just `state.identity` and
`state.payment` respectively.

```json
{ "status": "try_again", "attempts_used": 1, "attempts_allowed": 2, "can_upload": true,
  "upload_kinds": ["owner_identity"],
  "documents": [ { "kind": "owner_identity", "status": "rejected", "review_note": "The photo is blurred.",
                   "uploaded_at": "2026-11-15T10:00:00Z", "reviewed_at": "2026-11-16T09:00:00Z" } ] }
```

```json
{ "status": "waiting", "reason": "payments_not_connected", "checkout_available": false, "confirmed_at": null }
```

### 5.7 `zella_owner_onboarding_finish_later(p_business_id uuid)` and `zella_owner_onboarding_resume(p_business_id uuid)`

Finish later records `paused_at`; resume clears it and records the time. Progress is always saved after every step,
so the owner comes back to `current_step` whether or not these were called; they exist so admins can see "left at
step 3 on ...". Both return `{ "changed": true|false, "state": <5.2> }`. Errors: `NOT_SIGNED_IN`, `NOT_ALLOWED`,
`NOT_FOUND`.

### 5.8 Edge function `owner-onboarding`: uploading a new identity document

Only while `identity.can_upload` is true, for a kind in `identity.upload_kinds`. Two calls, then the upload itself:

1. `invoke("owner-onboarding", { body: { action: "identity_upload_url", businessId, kind, fileName, mimeType, size } })`
   → `{ "path": "<business id>/owner_identity/<random>.jpg", "token": "<upload token>" }`
2. `supabase.storage.from("business-documents").uploadToSignedUrl(path, token, file)`
3. `invoke("owner-onboarding", { body: { action: "identity_upload_confirm", businessId, kind, path, fileName, mimeType, size } })`
   → `{ "document": { "kind": "owner_identity", "status": "pending_review", "review_note": null,
        "uploaded_at": "2026-11-16T15:10:00Z", "reviewed_at": null }, "identity": <5.6 identity object> }`

Files: PDF, JPG, PNG, WEBP or HEIC, at most 10 MB. Errors (HTTP status, `code`): 401 `NOT_SIGNED_IN`; 403
`NOT_ALLOWED`, `MFA_REQUIRED`; 404 `NOT_FOUND`; 409 `UPLOAD_NOT_ALLOWED`, `STEP_LOCKED`, `BUSINESS_NOT_AVAILABLE`;
400 `INVALID_INPUT` (with plain words in `error`, for example "Upload a PDF, JPG, PNG, WEBP or HEIC file"); 413
request too large; 500 `SERVER_ERROR`.

## 6. Zella Voice admin calls (for the Businesses page and Verification)

Admins need the platform permission named; refused with `NOT_PERMITTED` otherwise.

| Function | Permission | Returns |
|---|---|---|
| `zella_admin_onboarding_overview()` | `businesses.view` | `{ "businesses": [ { "business_id", "business_name", "current_step", "current_step_number", "steps_total", "identity_status", "payment_status", "change_requests", "paused_at", "completed_at", "updated_at" } ] }`, one row per business whose owner has started |
| `zella_admin_onboarding_progress(p_business_id uuid)` | `businesses.view` | the 5.2 object for that business (no team phone or email), with `started: false` when the owner hasn't started |
| `zella_admin_onboarding_change_done(p_business_id uuid, p_section text, p_note text)` | `businesses.manage` | marks a requested change as made: the section goes to `updated` so the owner checks it again; the alert is resolved; audited. `{ "changed": true|false }` |

**For the business page (BIZ-12, owned by another job):** show `current_step_number` of `steps_total` and the
step's name from `zella_admin_onboarding_overview()` or `..._progress(id)`, plus `change_requests` (count) and
`paused_at`. A business whose owner hasn't opened the journey has no row in the overview (show "Not started").

## 7. Identity provider webhook (not called by the screens)

`POST /functions/v1/identity-webhook`. Off unless the server setting `IDENTITY_WEBHOOK_ENABLED` is `true`, a
secret `IDENTITY_WEBHOOK_SECRET` is set, and `zella_onboarding_rules().identity_provider` is not `none`; otherwise
503 `not_enabled`. Signed: header `X-Identity-Signature: t=<unix seconds>,v1=<hex HMAC SHA256 of "<t>.<raw body>">`
(the same scheme Persona uses; confirm the header name and payload against Persona's documentation before switching
it on), at most 5 minutes old, checked over the raw bytes before anything is parsed. Each event is processed once
(`identity_verification_events`, unique per provider and event id); a repeat answers 200 `duplicate`. An event for an
unknown reference is kept as unmapped with an admin alert, never guessed onto a business (`TEN-12`).

## 8. What is not built (so the screens show it honestly)

- Stripe Checkout and the payment webhook: step 6 always shows waiting; `checkout_available` is false.
- The identity provider (Persona) live connection: no inquiry is created; the manual upload path is the working one.
- Emails for each stage (S3 to S6) exist but are sent only once email is live.
