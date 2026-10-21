# Knowledge update and knowledge gap — n8n + Vapi setup

Run `zella_knowledge.sql` after `zella_crm_details.sql`.

Rule: the AI receptionist may only use knowledge with status **ready**. Any edit by the business puts that answer back to **processing** (new version) until the steps below confirm it. Old text can never be marked ready: if the text changed again meanwhile, the confirmation is ignored (`stale`).

## 1. Knowledge update (n8n, every 2 minutes)
1. POST `{SUPABASE_URL}/rest/v1/rpc/zella_claim_knowledge_updates` (service role key). Returns items in `processing`.
2. For each item: send the business's FULL ready+processing set to its Vapi assistant (knowledge file / prompt section) — build it from `zella_ready_knowledge(business_id)` plus this item.
3. Verify readiness: ask Vapi to confirm the update is applied (read the assistant back and check the version text is present).
4. POST `zella_complete_knowledge_update` with `p_item_id`, `p_version` (the version you were given), `p_ok` true/false, `p_error` when false.
   - `ready` → the business sees "Ready".
   - `failed` → the business sees "Needs attention" with your error and can edit or press Try again.

## 2. Knowledge gap
1. In the Vapi assistant prompt: if the answer is not in the approved knowledge, say you will have someone follow up, never guess, and call the `log_unanswered_question` tool.
2. That tool hits an n8n webhook → POST `zella_log_knowledge_gap` with `p_business_id`, `p_question`, optional `p_call_id`, `p_customer_id`. Same question asked again just raises "asked N times" (no duplicates).
3. Notify the owner (email/SMS via n8n) with a link to CRM → Knowledge. Mark nothing as answered yourself.
4. The owner writes the answer in the CRM → it goes to "processing" → flow 1 makes it ready.

## 3. Zella drafts the answer (so the owner only checks and submits)
n8n, every 2 minutes:
1. POST `zella_claim_gaps_for_suggestion` (service role) → open questions without a draft (3 tries max each).
2. For each: gather ONLY this business's own information — its ready knowledge (`zella_ready_knowledge`), its website pages / services / policies if connected. Never use general internet knowledge as a business fact (prices, insurance accepted, opening hours, guarantees must come from the business).
3. Ask the model to write a short, customer-ready answer from that material, naming the source (e.g. "your website /services"). Use confidence:
   - `high` — the material states the answer directly
   - `low` — partly inferred; the CRM shows "Check the facts"
   - `none` — not in the material; send no answer (the CRM says Zella couldn't find it and the owner writes it)
4. POST `zella_set_gap_suggestion` with `p_gap_id`, `p_answer`, `p_title`, `p_kind`, `p_source`, `p_confidence`.

The draft is only a suggestion. It is never used by the AI until the owner presses Submit; then flow 1 checks and publishes it.
