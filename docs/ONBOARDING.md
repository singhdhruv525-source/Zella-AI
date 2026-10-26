# Create Business wizard (admin dashboard)

`web/src/CreateBusinessWizard.jsx`, server: `web/supabase/functions/owner-provision-business` (`index.ts` setup actions,
`onboarding.ts` for operations, team and documents), industry questions: `web/src/onboardingConfig.js`.

## Steps (essentials first, optional fine-tuning last)

| # | Step | Saves to | Required to continue |
|---|---|---|---|
| 1 | Business | `businesses` (draft via `zella_create_business_draft`: modules on, AI receptionist created disabled) | name, industry, timezone; valid email/phone/website |
| 2 | Owner & verification | `business_invitations`, `setup_data.owner`; documents in `business_verification_documents` + private bucket | owner name and email |
| 3 | Hours & services | `business_hours` (bookings, open/closed checks, after-hours), `businesses.description`, `setup_data.operations`, AI knowledge base, `appointment_rules` | hours for at least one day; valid times; the industry's required questions |
| 4 | Team (optional) | `staff_members` (new members work the opening hours; removed ones are switched off, not deleted) | a name for every row |
| 5 | AI receptionist | `ai_agents`, `ai_agent_configs` (merged: never wipes hours/services) | answered FAQs; valid transfer number |
| 6 | Phone & integrations (optional) | `setup_data.integrations` (choices only; nothing shown as connected) | forwarding number when forwarding |
| 7 | Automations | `automations` (paused until go-live) | - |
| 8 | CRM setup (optional) | `business_modules`, `businesses.terminology_overrides` | - |
| 9 | Review | finish: workspace active, owner invited | owner, both required documents uploaded and not rejected |

Back navigation keeps answers; every step saves on "Save & continue"; "Save & exit" keeps a draft that reopens at
the step after the last one completed (`RESUME_STEP`).

## Industry-specific questions

`onboardingConfig.js` groups the 28 industries (plus Hotels) into kinds: dining, lodging, clinic, vet, field
services, beauty, fitness, property, property management, advisory, education, childcare, automotive, events,
e-commerce, travel, and a general fallback. Each kind sets its own questions (for example seats and largest party
for restaurants, check-in/out for hotels, area served and 24/7 call-outs for trades, returns window for shops),
whether booking preferences apply (not for e-commerce), whether a team is recommended, the usual booking length,
the AI's default abilities and suggested FAQ questions (questions only; the answers are always the admin's).

## Verification documents

Required: business registration and the owner's photo ID. Optional: tax registration, professional licence.
PDF or image, 10 MB. Files go to the private bucket `business-documents` through a one-time upload link; admins
open them through a 60-second link; viewing, uploading and reviewing are written to the audit log. Admins mark
each document verified or rejected (a reason is required). A business's owner and admins can see their documents'
status, never the files or paths; nobody else sees anything.

## Deployment

1. Back up, then apply `sql/zella_onboarding.sql` (documents table and bucket; opening hours used for bookings;
   whole-hour slot steps fixed).
2. Deploy the admin function: `supabase functions deploy owner-provision-business` (adds `onboarding.ts`).
3. Deploy the web app.

Until step 1 the wizard works without documents and says storage isn't set up; until step 2 the new steps'
saves are refused by the server as unknown actions.
