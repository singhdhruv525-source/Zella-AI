# Zella Voice requirements: status, requirement by requirement (5 Nov 2026)

Scope: the nine sections of the requirements message. Status words:
- **built**: code and tests are in the repository, nothing is live;
- **existing**: it already worked before this round;
- **partial**: some of the requirement is met;
- **not built**: none of it is;
- **blocked**: it needs a decision or access from you.

Evidence types:
- **[det]** deterministic database or unit tests on an isolated copy of production;
- **[runtime]** the running voice-rules function against that copy;
- **[config]** a read-only production read;
- **[mock]** test platform settings or test plan rows.

No provider test was run: there was no real Vapi call, SMS, email, Shopify or Google request. No model-driven tests ran
either: the assistant's speech was not tested, only the instructions and tools it receives. **Nothing in this round is
applied to production, deployed or published.**

## 1. Booking models by industry

| Requirement | Status | Evidence |
| --- | --- | --- |
| Time-slot appointments: hours, length, notice, horizon, gaps, staff, no double booking | existing; gaps and race guard applied 5 Nov | [det] tests/booking (7, including a two-connection race) |
| Request-only booking (owner confirms) | existing (`requested` status, `zella_confirm_requested_appointment`) | [runtime] matrix: "booked or requested, never invented" |
| Industries that take no bookings refuse them | existing | [runtime] matrix, 28 industries |
| Restaurant table capacity or party size | **not built**: `appointments.party_size` is stored, but availability ignores it | — |
| Trades arrival windows | **not built** | — |
| Classes with capacity and attendance | **not built** (the capability is a label; no session or capacity tables) | — |

Each of these needs a booking-model decision per industry, for example tables and covers, window length, or class
capacity. Until then the receptionist can't honour them.

## 2. Follow-up by call, SMS and email

| Requirement | Status | Evidence |
| --- | --- | --- |
| No silent substitution of channels | built: AI-call reminders, confirmations and waitlist offers are held for the owner (applied). **W2** (staff-unavailable "email" saved as text) is fixed in the wizard and server | [det] tests/channel; code review |
| Consent, quiet hours, opt-out, duplicate prevention, settings re-planned on change | existing (applied 5 Nov) | [det] tests/messaging; docs/MESSAGING_POLICY_2026-11-05.md |
| Retries, and eligibility re-checked before sending | existing for texts and reminders | docs/MESSAGING_EXECUTION_AUDIT_2026-11-05.md |
| Actually sending | **off**: all n8n workflows inactive, no SMS or email provider test | [config] |

## 3. Business rules, CRM editing and automatic sync

| Requirement | Status | Evidence |
| --- | --- | --- |
| Server-checked rules (booking, handover reasons, transfer number, knowledge, hours) apply from the next tool call | existing; applied 5 Nov | [det] tests/escalation, tests/crm_updates |
| Draft → checked → published, with versions and restore | existing | — |
| **Automatic delivery to the receptionist, with no Vapi editing (K3)** | **built**: Vapi asks voice-rules for the assistant at the start of each call (`assistant-request`). The answer is built from the current published settings, so there is no sync to fall behind. The version shows "live on calls", or "calls can't use it" with the reason. Unknown or suspended numbers get nothing | [det] tests/assistant (5); [runtime] 56 assistant-requests; [mock] platform settings in tests |
| Free text can't bypass rules | instructions and notes are labelled as instructions; enforced rules are separate | docs/BOOKING_RULES_2026-11-05.md |

Prerequisites for K3 in production:
- **PR1:** register every number. Production has 0 in `business_phone_numbers`, so every call would be refused.
- Switch the Vapi numbers. This is a provider change and needs approval.
- Make one real test call.

The assistant settings themselves are sendable for all 4 businesses [config].

## 4. Plan entitlements

| Requirement | Status | Evidence |
| --- | --- | --- |
| Languages limited by plan, on the server (CRM and API saves, setup, call time after a downgrade) | **built** (P2), using `plans.limits.languages` | [det] [mock] tests/plans (4), with test-only plan rows |
| Other features by plan | **blocked**: production has **0 plans and 0 subscriptions**, and no plan definitions exist in the repository. I created no plans, prices or tiers | [config] |
| No subscription means no limit | existing behaviour, kept (matches `zella_entitlement_allows`) | **decision for you** |

## 5. Knowledge improves from calls

| Requirement | Status | Evidence |
| --- | --- | --- |
| Unanswered questions are logged once per call; owners are told | existing | phase 4 tests |
| Caller claims and model suggestions never reach callers unapproved | verified | [det] tests/knowledge |
| Trusted owner path: an approved answer is used on the next call, recorded as approved by that person | built (K1/K2 applied) | [det] tests/knowledge, tests/crm_updates |
| Corrections replace the answer; removals stop it being given; failures are refused with the reason | verified | [det] |
| No crossing between businesses | verified (answers and approvals) | [det] |
| **K4:** a viewer could publish or dismiss answers | **fixed** (pending) | [det] fails without the fix; [config] production has 2 open questions |

## 6. Automations follow business setup (daily report)

| Requirement | Status | Evidence |
| --- | --- | --- |
| The time is chosen at business creation; nothing is assumed (it was a fixed 8 AM) | built | [det] tests/reports |
| Time zone and daylight saving, recipients by role, period (previous day or last 24 h) | built | [det] including the day daylight saving ends |
| CRM changes apply from the next day; staff can't change it; changes audited | built | [det] |
| Once per local day; a missed run is recorded, not sent late; failures recorded; next and last run shown | built | [det] |
| The same traceability for other automations | existing for reminders and follow-ups (re-planned on change, applied) | tests/messaging |
| Actually running on a schedule | **off**: no pg_cron jobs, and the dispatcher workflow is inactive | [config] |

## 7. Leads

| Requirement | Status | Evidence |
| --- | --- | --- |
| Website forms | existing, reviewed in code: per-form public key, rate limits, honeypot spam check, 10-minute duplicate check, consent stored with evidence, failures recorded | code review; not re-tested over HTTP this round |
| Google Ads lead forms | existing: hashed key, replay protection by lead id, rate limit, invalid and failed recorded | tests/security/google_leads_test.sql |
| Meta | existing (`zella_meta_capture_lead`); workflow inactive | — |
| **Google Forms** | **blocked**: no integration exists. It needs a choice between an Apps Script webhook and the Forms API with OAuth, plus credentials | — |
| Leads stop follow-ups when they reply or book | not re-verified this round | — |

## 8. Traceability and the 28 industries

| Test | Type | Result |
| --- | --- | --- |
| 28 industries × 2 contrasting businesses through the running voice-rules: FAQs, booking rules, transfer, greeting and languages, tool lists, assistant-request | [runtime] [mock settings] | 391/391 |
| The same through the deployed-era voice-rules | [runtime] | 335/335 |
| 12 database suites in one database | [det] | all pass |
| voice-rules (38) and owner-provision-business (13) unit tests | [det] | pass |
| Exact rollback of all 11 pending files, then re-apply | [det] | pass |
| Speech, real calls, SMS, email, Shopify, Google | provider | **not run** |

The 28-industry matrix does not yet cover these per industry; they are tested once each in their own suites:
- daily reports;
- knowledge learning;
- leads over HTTP;
- plan limits.

## 9. Deliverables

- **Defects and fixes:** docs/DEFECT_INVENTORY_2026-11-05.md. The "Update" section adds R6-1, K3, K4, W2, P2 and PR1.
- **Migration order, recovery and the single deployment review:** docs/DEPLOYMENT_MANIFEST_2026-11-05.md. The
  addendum lists #8–#11 and the K3 switch-over steps.
- **Pushing to main** triggers no workflow or deployment (checked earlier: no GitHub workflows, no deployments,
  no status checks).

### What needs you

1. **Approval** to apply #8–#11, deploy voice-rules and owner-provision-business, and publish the web build.
2. **K3 switch-over:** register numbers (PR1), choose a standby assistant (optional), then make one real test call.
3. **Plan definitions** (names, limits, features) if plans should limit anything beyond languages. Also decide
   whether a business with no subscription should get no limits.
4. **Google Forms:** the method, and credentials.
5. **Booking models:** restaurant capacity, trades windows and classes (Section 1).
6. **Earlier decisions still open:** R1 (unassigned bookings in staffed businesses); running the config migration for
   the 2 stale businesses; switching sending on.
