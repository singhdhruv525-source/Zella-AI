# Ongoing CRM updates: do knowledge, rules and settings changes reach the receptionist? (5 Nov 2026)

Question: after setup, when an owner adds, edits or removes knowledge, rules or settings in the CRM, does the live
receptionist behave differently, and when?

Two delivery paths exist, and they behave very differently:

1. **Read on every call (no cache):** whatever the server reads during a tool call (knowledge search, availability,
   booking rules, booking abilities, transfer decisions, the transfer number, capabilities, opening hours, holidays) is
   read from the database at that moment. A committed change applies from the next tool call. Nothing needs
   invalidating.
2. **Baked into the voice assistant at the provider (Vapi):** the instructions text, greeting, first message,
   languages, voice and tool list. These only change when `zella_assistant_config(business)` is sent to Vapi.
   - Publishing a receptionist version marks it `sync_status = pending`, but **nothing consumes that queue**:
     `zella_claim_agent_syncs` has no caller in the repository, and no n8n workflow is active (n8n, read 5 Nov:
     all 30 Zella workflows inactive).
   - `docs/GO_LIVE.md` says this is manual ("send `zella_assistant_config(business_id)` to Vapi for each business
     (not automated yet)").
   - **K3, open:** wording changes in the CRM never reach the phone line by themselves. The CRM used to say
     "goes live once it has synced"; it now says rules apply from the next call and wording changes wait for the
     assistant update.

## By setting

| Change in the CRM | Path | Reaches calls | Evidence |
| --- | --- | --- | --- |
| Knowledge: add, edit, roll back, send a draft | 1 | next call (with `zella_knowledge_live.sql`); **before: never** (K1) | tests/crm_updates |
| Knowledge: remove (archive) | 1 | next call | tests/crm_updates |
| Knowledge: a bad edit (empty or too long) | — | refused with the reason; the live answer stays | tests/crm_updates |
| Opening hours (Settings) | 1 | next call | tests/crm_updates (16 → 6 times offered) |
| Booking abilities, length, notice, horizon, gap | 1 | next call | tests/setup, tests/booking, tests/crm_updates |
| Handover reasons, transfer number | 1 | next call | tests/escalation |
| Setup FAQs and policies via a published version | 1 | next call (the knowledge trigger) | tests/crm_updates, tests/setup |
| Owner's rules, booking notes, instructions, personality, tone | 2 | **only after a manual assistant update (K3)** | `zella_brain_prompt` changes at once (tests/escalation); delivery to Vapi not automated |
| Languages and greeting (Settings > Languages) | 2 | **only after a manual assistant update (K3)** | `zella_assistant_config` output changes at once |
| Automation settings (reminders, follow-ups) | DB | waiting messages are re-planned (M4, applied 5 Nov); "AI call" is held (`zella_channel_review.sql`) | tests/messaging, tests/channel |

## Findings

- **K1:** knowledge never went live. Added and edited answers waited in "processing" for the Zella - Knowledge
  workflow (inactive). Its only check is: title present, answer present, at most 4,000 characters. Production has 0
  knowledge items today (read only), so no one has been affected yet.
  **Fix:** `sql/zella_knowledge_live.sql` runs the same check in the database at save time. A passing item is ready
  at once; a failing one is refused and the previous version stays. The workflow can take over again with the platform
  setting `knowledge_check = "external"`.
- **K2:** editing a live answer took it out of use until checked. Fixed by the same file: the new answer replaces the
  old one in the same save, with a version history entry.
- **K3 (open; needs a decision and the provider):** nothing delivers the assistant configuration to Vapi. Two options:
  1. answer Vapi's per-call `assistant-request` from voice-rules with `zella_assistant_config`, so every call uses the
     current settings and nothing is cached;
  2. a sync worker that consumes `zella_claim_agent_syncs` and calls Vapi's assistant API.

  Either needs a Vapi key and a real test call; neither was built or tested here.

## Tests

`tests/crm_updates/run.sh`: 7 checks on an isolated copy of the production state, writing as the signed-in owner the
way the CRM pages do. They cover:
- an addition, edit, refused edit, rollback, removal and draft publication in Knowledge;
- an opening-hours change;
- a published receptionist version (booking switched off, a setup FAQ added).

With the fix all pass. Without it, the first fails: an added answer is left in "processing".

Not tested: the Vapi side (assistant contents at the provider, its caching, a real call).
