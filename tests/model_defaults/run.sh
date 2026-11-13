#!/usr/bin/env bash
# sql/zella_model_defaults.sql on an ISOLATED copy of the production state (never production): the five functions
# match production before, the file applies twice, no model name is left as a fallback, a missing model setting
# claims no AI work and stops the assistant with a clear problem, the rollback restores production's definitions
# exactly, and the file applies again after it. No model name is written in this file: an accepted value is read
# from the function's own list at run time.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zmodeldefaults
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
# what production has (as in tests/billing/run.sh)
LIVE=(zella_platform_roles_fix zella_booking_buffers zella_channel_review zella_escalation_rules zella_knowledge_live zella_order_lookup_v2 zella_config_migration
  zella_report_schedules zella_knowledge_learning zella_assistant_delivery zella_plan_languages
  zella_holiday_availability zella_delivery_evidence zella_arrival_windows zella_tables zella_relationships zella_scheduling zella_slots_resource_blocks zella_record_workflows
  zella_batch1_security zella_batch3_pagination zella_brand_name zella_rollback_security zella_n8n_webhook_auth zella_record_files_purge_retry zella_replace_business_hours
  zella_order_lookup_reservations zella_review_sql_fixes zella_seating_handoff)
"$REPO/tests/lib/build_full.sh" $DB "$REPO/tests/channel/fixture.sql" $(for m in "${LIVE[@]}"; do echo "$REPO/sql/$m.sql"; done) > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
FNS="'zella_assistant_config','zella_claim_call_insights','zella_claim_gap_drafts','zella_review_claim_ai','zella_spam_claim_work'"
HASHES="select string_agg(proname || '=' || md5(pg_get_functiondef(oid)), ',' order by proname) from pg_proc where pronamespace = 'public'::regnamespace and proname in ($FNS)"
LIVE_HASHES="zella_assistant_config=1d02d9deec5b9692288e4406d2774468,zella_claim_call_insights=928d030adb92468da0c8a497f195c052,zella_claim_gap_drafts=bd7c24579496cc715917fafbd7cd0ef5,zella_review_claim_ai=1702cdf7489e0c7e74bc2fa93b956fc7,zella_spam_claim_work=7978836b1d63ea1f4c8460345464b5a2"
[ "$(q "$HASHES")" = "$LIVE_HASHES" ] && ok "the five functions match production's versions (read 13 Nov 2026)" || bad "build differs from production: $(q "$HASHES")"
FALLBACKS="select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in ($FNS)
  and prosrc ~ '(voice_llm|call_intel|knowledge_ai|review_ai|spam_ai)_model'', ''\"[^\"]+\"''::jsonb'"
[ "$(q "$FALLBACKS")" = 5 ] && ok "before: all five fall back to a model name in their body" || bad "before: expected 5 fallbacks, found $(q "$FALLBACKS")"

for i in 1 2; do out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_model_defaults.sql" 2>&1) || { bad "apply (run $i): $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"; exit 1; }; done
ok "applies twice"
[ "$(q "$FALLBACKS")" = 0 ] && ok "after: no model name is a fallback in any of the five" || bad "after: $(q "$FALLBACKS") still fall back"
[ "$(q "select count(*) from zella_function_archive where migration = 'zella_model_defaults'")" = 5 ] && ok "the five original definitions are archived once" || bad "archive rows: $(q "select count(*) from zella_function_archive")"
[ "$(q "select has_table_privilege('authenticated', 'zella_function_archive', 'select') or has_table_privilege('anon', 'zella_function_archive', 'select')")" = f ] \
  && ok "the archive is server only" || bad "the archive is readable by signed-in or anonymous users"

out=$("${P[@]}" -d $DB 2>&1 <<'SQL'
do $$ declare b uuid; r jsonb; v_ok text; begin
  select id into b from businesses order by id limit 1;
  -- a missing model setting: the assistant is not sent and says why
  delete from platform_settings where key = 'voice_llm_model';
  r := public.zella_assistant_config(b);
  assert r -> 'problems' ? 'voice_llm_model null is not in Vapi''s Anthropic model list' and r ->> 'ready_to_send' = 'false', 'missing model: ' || (r -> 'problems')::text;
  -- an accepted model (read from the function's own list, not written here): that problem is gone
  select (regexp_match(prosrc, 'v_vapi_models text\[\] := array\[''([^'']+)'''))[1] into v_ok from pg_proc where proname = 'zella_assistant_config';
  assert v_ok is not null, 'could not read the accepted model list';
  insert into platform_settings (key, value) values ('voice_llm_model', to_jsonb(v_ok)) on conflict (key) do update set value = excluded.value;
  r := public.zella_assistant_config(b);
  assert not exists (select 1 from jsonb_array_elements_text(r -> 'problems') x where x like 'voice_llm_model%'), 'set model: ' || (r -> 'problems')::text;
  -- the AI workers claim nothing without a model, even when switched on
  delete from platform_settings where key in ('call_intel_model', 'knowledge_ai_model', 'review_ai_model', 'spam_ai_model');
  insert into platform_settings (key, value) values ('call_intel_live', 'true'), ('knowledge_ai_live', 'true'), ('review_ai_live', 'true')
    on conflict (key) do update set value = excluded.value;
  assert public.zella_claim_call_insights(5) = '[]'::jsonb, 'call insights claimed without a model';
  assert public.zella_claim_gap_drafts(5) = '[]'::jsonb, 'knowledge drafts claimed without a model';
  -- a review waiting for an AI draft: without a model it stays unclaimed; with one it is claimed (positive control)
  insert into reviews (business_id, provider, external_id, rating, body, draft) values (b, 'google', 'test-model-defaults-1', 5, 'Great service', 'Thank you!');
  update reviews set status = 'drafted', ai_status = 'pending', ai_attempts = 0, ai_claimed_at = null where external_id = 'test-model-defaults-1';
  assert public.zella_review_claim_ai(5) = '[]'::jsonb, 'review replies claimed without a model';
  assert (select ai_attempts = 0 and ai_claimed_at is null from reviews where external_id = 'test-model-defaults-1'), 'the review was touched without a model';
  insert into platform_settings (key, value) values ('review_ai_model', '"test-model"') on conflict (key) do update set value = excluded.value;
  r := public.zella_review_claim_ai(5);
  assert jsonb_array_length(r) = 1 and r -> 0 ->> 'review_id' = (select id::text from reviews where external_id = 'test-model-defaults-1')
     and r -> 0 ->> 'model' = 'test-model', 'with a model the review is claimed: ' || r::text;
  raise notice 'PASS missing model: no assistant sent, with the reason; set model: accepted; AI workers claim nothing without a model; a seeded review is claimed only once a model is set';
end $$;
SQL
) && echo "$out" | grep -o 'PASS .*' || bad "behaviour: $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"
for f in zella_claim_call_insights zella_claim_gap_drafts; do
  [ "$(q "select prosrc like '%if not v_live or v_model is null then return v_res; end if;%' from pg_proc where proname = '$f'")" = t ] && ok "$f returns no work without a model" || bad "$f has no model check"
done
[ "$(q "select prosrc like '%if v_model is null or not coalesce(public.zella_setting(''review_ai_live''%' from pg_proc where proname = 'zella_review_claim_ai'")" = t ] \
  && ok "zella_review_claim_ai returns no work without a model" || bad "zella_review_claim_ai has no model check"
[ "$(q "select prosrc like '%if v_model is not null and nullif(trim(coalesce(v_text, ''''))%' from pg_proc where proname = 'zella_spam_claim_work'")" = t ] \
  && ok "zella_spam_claim_work skips only the AI opinion without a model" || bad "zella_spam_claim_work has no model check"

for i in 1 2; do out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_model_defaults_rollback.sql" 2>&1) || { bad "rollback (run $i): $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"; exit 1; }; done
[ "$(q "$HASHES")" = "$LIVE_HASHES" ] && ok "the rollback (run twice) restores production's definitions exactly" || bad "after rollback: $(q "$HASHES")"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_model_defaults.sql" 2>&1) && [ "$(q "$FALLBACKS")" = 0 ] && ok "applies again after the rollback" || bad "re-apply: $(echo "$out" | grep -m2 ERROR | tr '\n' ' ')"
# a function changed after the migration is never overwritten by the rollback
q "create or replace function public.zella_review_claim_ai(p_limit integer default 5) returns jsonb language sql security definer set search_path = public as \$\$ select '[]'::jsonb \$\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_model_defaults_rollback.sql" 2>&1) && bad "the rollback overwrote a function changed after the migration" || {
  echo "$out" | grep -q VERSION_MISMATCH && ok "the rollback refuses a function changed after the migration, and changes nothing" || bad "rollback failed for another reason: $(echo "$out" | grep -m1 ERROR)"; }
[ "$(q "select md5(pg_get_functiondef(oid)) from pg_proc where proname = 'zella_claim_call_insights'")" = 7bc295835cdc9d35fc6ae6d34cd7e57a ] \
  && ok "a refused rollback leaves the other functions as they were (one transaction)" || bad "a refused rollback changed other functions"

"${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null
[ $fails = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
