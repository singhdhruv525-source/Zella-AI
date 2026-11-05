# Defect inventory (5 Nov 2026)

One ID per issue, with an explicit status. Status values:
- **applied**: in production since 5 Nov;
- **pending**: fixed and tested in the repository, not applied or deployed. Update, 5 Nov evening: every database file marked pending below is now applied (docs/PRODUCTION_APPLY_2026-11-05.md); the edge-function and web parts are still pending;
- **partly applied**: the database part is live and the edge-function or web part is not deployed;
- **decision**: needs the owner's choice;
- **open**: not fixed.

Evidence labels (item 9):
- **[config]**: production configuration read on 5 Nov; says nothing about earlier states.
- **[history]**: production records within what is retained (audit log since 22 Oct, reminders since 23 Oct, calls
  and tool calls since the first ones). Deleted rows can't be seen.
- **[local]**: isolated database copies of the production state.
- **[runtime-local]**: the real edge function served locally against such a copy.
- **[provider]**: a real Vapi, Shopify, SMS, email or Google call. **No finding below has provider evidence.**

## Reconciling "eight gaps, six fixes, three decisions"

The setup trace listed D1–D8 and treated the buffer as **D3b**, part of D3. The earlier summary counted eight gaps
(D1–D8, with D3b inside D3), but then listed D3b separately among the "three decisions" (D3b, D5, D7). That is why
6 + 3 = 9 doesn't equal 8. With D3b given its own ID there are **nine setup issues**. All nine are now fixed: six
earlier, and D3b, D5 and D7 since (as B1, D5 and D7). Some of the fixes are not yet applied, as the table shows.

## Setup → live receptionist

| ID | Issue | Status | Where | Evidence |
| --- | --- | --- | --- | --- |
| D1 | booking / reschedule / cancel switched off in setup were ignored | applied | zella_setup_enforcement.sql | [local] [runtime-local]; [config] hawkye cafe has can_book false |
| D2 | setup FAQs, policies, about, area, details never reached the AI | applied for new saves; **pending** for existing businesses (CM1) | zella_setup_enforcement.sql; zella_config_migration.sql | [local]; [config] 0 setup knowledge items |
| D3 | default length, minimum notice, horizon ignored | applied | zella_setup_enforcement.sql | [local] [runtime-local] |
| D3b = B1 | gap between appointments ignored | pending | zella_booking_buffers.sql | [local] |
| D4 | setup transfer number (integrations step, owner phone) never used | partly applied: the logic is in owner-provision-business (not deployed); existing businesses via CM1 (pending) | setup_sync.ts; zella_config_migration.sql | [local] unit tests; [config] 2 businesses have a setup number and no live one |
| D5 | handover reasons saved, never enforced | pending | zella_escalation_rules.sql | [local]; [config] 2 businesses saved reasons |
| D6 | setup language and greeting not used live | partly applied: function live; called only by owner-provision-business (not deployed) and CM1 (pending) | zella_setup_enforcement.sql | [local]; [config] test saloon chose en+es, no live language row |
| D7 | restrictions and booking notes never reached the AI | pending (prompt) + K3 (delivery to Vapi) | zella_escalation_rules.sql | [local] |
| D8 | saving the receptionist step wiped admin call routing | pending (owner-provision-business not deployed) | owner-provision-business/index.ts | [local] code review; no production overwrite seen [config] |

## Booking

| ID | Issue | Status | Where | Evidence |
| --- | --- | --- | --- | --- |
| B2 | CRM booking and reschedule skipped the lock and overlap checks: concurrent double booking possible | pending | zella_booking_buffers.sql + BusinessForms.jsx | [local], including a two-connection race; [history] 5 appointments, no overlap check run |
| R1 | an unassigned booking in a business with staff claims no one | decision | | [local] |

## Messaging

| ID | Issue | Status | Where | Evidence |
| --- | --- | --- | --- | --- |
| M1 | quote follow-ups ignored saved timing and tries | applied | zella_message_settings_fix.sql | [local]; [history] 0 quote follow-ups ever |
| M2 | "Email" never used for quote and post-visit follow-ups | applied | same | [local]; [history] 0 such follow-ups |
| M3 | reminders saved as AI call never sent | applied, then **superseded by C1** (M3 sent them as texts silently) | same; zella_channel_review.sql | [history] all 5 reminders ever were texts; 0 audit mentions of a call channel |
| M4 | settings changes didn't reach queued reminders | applied | same | [local] |
| C1 = M5 | AI-call reminders, confirmations and waitlist offers silently substituted with texts | pending: held for the owner, consent confirmed and audited | zella_channel_review.sql; automationOptions.js; BusinessControls.jsx | [local]; [config] 0 affected automations |
| W1 | the wizard offered email for waitlist offers, which were saved as text | pending (web + owner-provision-business) | CreateBusinessWizard.jsx; index.ts | code review |

## Order lookup (no store is connected in production; voice-rules with lookup is not deployed)

| ID | Issue | Status | Where | Evidence |
| --- | --- | --- | --- | --- |
| O1 | phone match on the last 10 digits matched numbers abroad | pending (voice-rules) | orders.ts | [local] unit |
| O2 | lookup log didn't say on what grounds a status was given | DB applied; code pending; levels revised by O4 | zella_order_lookup_assurance.sql | [local] |
| O3 | no limit on guessing in a call or from a number | DB applied; code pending | same | [local] |
| O4 | caller ID or email alone treated as enough to give date, payment, carrier and tracking digits | pending | orders.ts; zella_order_lookup_v2.sql | [local] unit tests against the old code; [config] no store, 0 lookups ever [history] |
| O5 | no limit per order number or per business | pending | zella_order_lookup_v2.sql | [local] |
| O6 | the tool description didn't say tracking is never read out | pending | same | [local] |
| O7 | delivery status ("delivered") not verified against Shopify's schema | open | | shopify.dev not reachable from this session |

## Ongoing CRM updates

| ID | Issue | Status | Where | Evidence |
| --- | --- | --- | --- | --- |
| K1 | owners' knowledge never went live (the checking workflow is inactive) | pending | zella_knowledge_live.sql | [local]; [config] workflow inactive, 0 items |
| K2 | editing a live answer took it offline until checked | pending | same | [local] |
| K3 | assistant wording, languages, greeting and tool list are never delivered to Vapi (manual per GO_LIVE.md) | open (needs a decision and a Vapi key) | | [config] no consumer of the sync queue, all n8n workflows inactive |
| CM1 | existing businesses stay on stale setup settings | pending | zella_config_migration.sql | [config] 2 stale businesses |

## Other

| ID | Issue | Status | Where | Evidence |
| --- | --- | --- | --- | --- |
| E1 | emergencies must not depend on handover ticks | decision taken: they follow the emergency setting | zella_escalation_rules.sql | [local] |
| A1 | advisor: mutable search_path on two functions; a trigger function callable by anon | pending | zella_booking_buffers.sql | [config] advisor |
| P1 | restricted platform roles refused by an old trigger | pending (earlier session) | zella_platform_roles_fix.sql | [config] trigger differs from the fix |
