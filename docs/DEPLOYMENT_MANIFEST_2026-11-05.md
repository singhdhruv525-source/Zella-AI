# Deployment review and manifest (5 Nov 2026, evening)

This is the single deployment review for everything still pending from both sessions. It supersedes the pending list
in `docs/DEPLOYMENT_REVIEW_2026-11-05.md`: those 17 migrations and today's 3 fixes are applied
(`docs/PRODUCTION_APPLY_2026-11-05.md`).

**Database #1–#7 were applied on 5 Nov evening (docs/PRODUCTION_APPLY_2026-11-05.md, second apply); production matches staging for all 764 functions. Edge functions and web are not deployed. Sending is not enabled.**

## Production today (read only, 5 Nov)

- **Database:** baseline, plus the live fix files, plus the 20 migrations applied today. Staging
  (`tests/lib/build_full.sh`) is identical to production for all 745 functions, compared with comments and spacing
  ignored.
- **Edge functions:** unchanged since before today (voice-rules v4, owner-provision-business v13, ...).
- **Web:** unchanged. The build is not published.
- **n8n:** all 30 Zella workflows inactive. No pg_cron jobs.
- **Data:** 4 businesses, 5 appointments, 4 calls, 0 transfers, 0 knowledge items, 0 stores, 0 published receptionist
  versions.

## Database manifest, in order

The version is the first 12 characters of the md5 of the file text without its final newline. Each file is safe to
run twice and has a rollback in `sql/rollback/<name>_rollback.sql`. Roll back in **reverse** order. How to run one safely
(SQL Editor, or psql through `sql/rollback/run.sh`): `sql/rollback/README.md`.

| # | File | Version | Class | Depends on | Fixes |
| --- | --- | --- | --- | --- | --- |
| 1 | zella_platform_roles_fix | 1269fe0daafc | P | — | P1 |
| 2 | zella_booking_buffers | 53f55d010a3b | V | setup_enforcement (applied) | B1/D3b, B2, A1 |
| 3 | zella_channel_review | 1b4b30d2dce3 | M | message_settings_fix (applied) | C1/M5; supersedes M3 |
| 4 | zella_escalation_rules | bcbee4474fb1 | V | industry_rules, store_orders (applied) | D5, D7, E1 |
| 5 | zella_knowledge_live | 659c9ebec09e | V | — | K1, K2 |
| 6 | zella_order_lookup_v2 | 4bb97245c12f | V | order_lookup_assurance (applied) | O4, O5, O6 |
| 7 | zella_config_migration | b11f5a76296e | V | setup_enforcement (applied); reads channel_review if present | CM1, with D2/D4/D6 for existing businesses |

Sending these through `apply_migration`: wrap each in the md5 guard used on 5 Nov (the text in `$zq$...$zq$`, run only
if the server's md5 matches the file's). After running the files, run step 7's preview, and then the per-business
apply. That is a separate approval (`docs/CONFIG_MIGRATION_PREVIEW_2026-11-05.md`).

## Overlaps and superseded definitions

Several files patch the same function. Each patch anchors on text the others leave in place. The full sequence was
tested in manifest order, each file twice, and rolled back in reverse order to an exact match.

| Function | Patched by | Order constraint |
| --- | --- | --- |
| zella_claim_reminders | message_settings_fix (applied), channel_review | channel_review inserts before message_settings_fix's block: roll back channel_review first |
| zella_replace_reminders, zella_resync_reminders | message_settings_fix (applied), channel_review | the same |
| zella_brain_tool_defs | store_orders (applied), order_lookup_v2, escalation_rules | independent anchors |
| zella_brain_prompt_base | receptionist_industry_rules (applied), escalation_rules | escalation_rules anchors on industry_rules' text |
| zella_ai_tool, zella_brain_context | caller_fixes, store_orders, setup_enforcement (all applied) | — |
| zella_available_slots | booking_buffers | — |
| zella_order_lookup_report | order_lookup_assurance (applied) **replaced** by order_lookup_v2 | v2's rollback restores the v1 report |
| zella_store_lookup_context / _log | v1 (applied) + v2 **new overloads** | the old ones stay for the deployed function |

Superseded behaviour and text:
- **M3** in message_settings_fix (AI-call reminders sent as texts) is superseded by channel_review. The data update
  M3 made changed 0 rows in production [config, history].
- The "one-time catch-up" comment in setup_enforcement is superseded by config_migration. The applied file was left
  unedited, so the repository matches what ran.
- The first order-lookup assessment is superseded by the revised `docs/ORDER_LOOKUP_ASSURANCE_2026-11-05.md`.
- `tests/messaging` M3 now checks the channel-review behaviour when that file is present.

## Edge functions and web

| Piece | Change | Needs first | Compatible with |
| --- | --- | --- | --- |
| voice-rules | order lookup v2 (levels, limits, no tracking) | manifest #6 | new DB ✓ (matrix 335/335). The old voice-rules with the new DB also passes 335/335 ✓. New voice-rules with an old DB: lookups say "can't check" (no p_order_ref overload) |
| owner-provision-business | D4, D6 calls, D8, reminder and waitlist saved as text, W1 | — (missing DB functions are tolerated) | 13 tests ✓ |
| web: BusinessForms (Book or Move anyway) | | manifest #2 for the SLOT_TAKEN message | without #2 the flag is harmless |
| web: BusinessControls (channel review panel) | | manifest #3 | without #3 the panel shows nothing |
| web: BusinessReceptionist (handover reasons, owner's rules, booking rules and notes) | | manifest #4 to enforce reasons | without #4 the reasons are saved, not enforced |
| web: BusinessKnowledge ("uses it from the next call") | | **manifest #5 (required)** | without #5 the wording is false |
| web: wizard (waitlist by text) | | owner-provision-business | |

Order: database #1–#7 → voice-rules and owner-provision-business → web → per-business config migration → (later)
sending.

## Tests (all on isolated copies of the production state; none against providers)

| Suite | With the fix | Without the fix |
| --- | --- | --- |
| tests/deploy/run_all.sh (everything together) | ALL PASSED: 7 files ×2; 9 suites' checks on one DB; matrix 335/335 through the current and the older voice-rules; voice-rules 36 tests; owner-provision 13 tests; deno checks; web build; exact full rollback; re-apply | — |
| tests/booking | 8 pass (incl. a two-connection race) | fails: 10:30 offered inside the gap; race keeps both bookings |
| tests/channel | 4 pass | fails (no review; AI-call reminder queued as text, waitlist offer texted) |
| tests/escalation | 6 pass (edits via the CRM publish path) | fails: upset caller transferred after the owner unticked it |
| tests/orders/run_v2 + voice-rules unit (17) | 4 + 17 pass | fails; the old code disclosed date, payment, carrier and last 4 tracking digits on caller ID alone |
| tests/crm_updates | 7 pass | fails: added answer stuck in processing |
| tests/config_migration | 3 pass (preview, apply, exact restore) | — (new functions) |
| tests/setup, messaging, orders (v1) | 9, 6, 5 pass | as before |

## Unresolved blockers

1. **K3:** nothing delivers the assistant configuration to Vapi, so wording, language and tool-description changes
   don't reach live calls automatically. Needs a decision (per-call `assistant-request`, or a sync worker) and a Vapi
   key. Until then, a person sends `zella_assistant_config` after each change.
2. **No provider test.** No real Vapi call, Shopify store (O7: the delivery-status field was unverified; shopify.dev
   isn't reachable from this session), SMS, email or Google request was made. Before going live with each: one real
   call, one development-store lookup, one text and one email to a test number or address.
3. **Sending is off.** The trusted channel for tracking is the team for now, and the 2 pending reminders in production
   would go out when texting is switched on.
4. **Decisions:** R1 (unassigned bookings in staffed businesses), and the owner-facing wording of the channel review.
5. **The knowledge workflow** stays inactive. With #5 it isn't needed; turning it on later needs
   `knowledge_check = "external"`.

## Approvals needed (none given for this list)

1. Apply database #1–#7 (with the md5 guard).
2. Deploy voice-rules and owner-provision-business.
3. Publish the web build.
4. Run the config migration for the 2 stale businesses (preview first).
5. K3 decision and Vapi key.
6. Later: sending.

## Addendum (5 Nov, late): Zella Voice requirements, still pending

**#8–#11 were applied on 5 Nov, late (docs/PRODUCTION_APPLY_2026-11-05.md, third apply). The edge functions and web are not deployed or published.** These four come next, in this order;
each is safe to run twice and has a rollback (roll back newest first).

| # | File | Version | Fixes | Notes |
| --- | --- | --- | --- | --- |
| 8 | zella_report_schedules | 572c1c714e74 | R6-1 | replaces the fixed 8 AM daily report; businesses get one only after a time is chosen (production has 0 active businesses) |
| 9 | zella_knowledge_learning | 550799e26546 | K4 | |
| 10 | zella_assistant_delivery | f91528483f42 | K3 | harmless until a Vapi number is switched to assistant-request |
| 11 | zella_plan_languages | 2d254aeed7c3 | P2 | no effect until plans exist (production: 0 plans, 0 subscriptions) |

Edge functions and web, after #8–#11:
- **voice-rules:** assistant-request handling, on top of the order lookup v2 changes listed above.
- **owner-provision-business:** daily report save and load; W2.
- **web:**
  - the wizard's Daily report card and W2;
  - Settings > Reporting preferences;
  - receptionist version states;
  - the language plan message.

**Switching calls to per-call delivery (K3) is a separate provider change and needs approval.** In this order:
1. Register each live number in `business_phone_numbers`, with its Vapi phone number id. Production has 0 today (PR1).
   Without this, every call is refused.
2. Optionally set `assistant_fallback_id` to the assistant the numbers use today, as a standby.
3. On one test number: remove the fixed assistant, set the server URL to voice-rules, and make one real call.
4. Only then switch the other numbers.

To undo: put the fixed assistant back on each number, then roll back #10.

Full sequence: `tests/deploy/run_all.sh` passed, run on an isolated copy and never against production:
- all 11 pending files applied twice;
- 12 suites;
- 28 industries × 2 businesses through the current voice-rules: 391/391, including 56 assistant-requests;
- the deployed-era voice-rules: 335/335;
- unit tests: voice-rules 38 and owner-provision-business 13;
- deno checks and the web build;
- an exact rollback of all 11 files, newest first;
- a re-apply after the rollback.
