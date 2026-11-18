#!/usr/bin/env bash
# M12: sql/zella_call_limits.sql. The minutes check (zella_call_entitlement_check), the number lookup and the assistant
# builder are replaced by stubs in this copy so each case can be set; the two changed functions are the real ones.
# Checks: before, used up with no forward number and an unknown allowance both keep answering (the gap); after, with
# enforcement on: used up and unknown play the closed message (no forward number) or forward (valid number); auto
# reload counts only once reloads can run; pay as you go keeps answering; enforcement off changes nothing for callers
# but reports would_close; owners are reminded at most once every 6 hours; unknown raises a platform alert; the call
# limit refuses the next call at the cap, counts only calls not ended, and a business override wins; applies twice;
# rollback twice restores both functions exactly; drift stops the file and the rollback.
. "$(dirname "$0")/lib.sh"; fresh_db call_limits
SIGS="'public.zella_call_gate(uuid)','public.zella_assistant_for_call(text,text,text)'"
fp() { q "select string_agg(md5(pg_get_functiondef(s::regprocedure)), ',' order by s) from unnest(array[$SIGS]) s"; }; before=$(fp)
BIZ=$(q "insert into public.businesses (name, industry_id, is_active) select 'Limits Test', id, true from public.industries limit 1 returning id" | head -1)
q "create table public.zz_stub (k text primary key, v text)" > /dev/null
q "insert into public.zz_stub values ('status', 'exhausted')" > /dev/null
q "create or replace function public.zella_call_entitlement_check(p_business_id uuid) returns jsonb language sql stable as \$f\$ select jsonb_build_object('status', (select v from public.zz_stub where k = 'status'), 'reason', 'stub') \$f\$" > /dev/null
q "create or replace function public.zella_business_for_number(p_called_number text, p_vapi_phone_number_id text default null, p_fallback uuid default null) returns uuid language sql stable as \$f\$ select case when p_called_number = '+15550009999' then '$BIZ'::uuid end \$f\$" > /dev/null
q "create or replace function public.zella_assistant_config(p_business_id uuid) returns jsonb language sql stable as \$f\$ select '{\"ready_to_send\": true, \"assistant\": {\"name\": \"stub\"}}'::jsonb \$f\$" > /dev/null
AG=$(q "insert into public.ai_agents (business_id, name, is_default, agent_type) values ('$BIZ', 'R', true, 'receptionist') returning id" | head -1)
q "insert into public.ai_agent_configs (agent_id) values ('$AG')" > /dev/null 2>&1 || q "insert into public.ai_agent_configs (agent_id, business_id) values ('$AG', '$BIZ')" > /dev/null
gate() { q "select public.zella_call_gate('$BIZ')"; }
afc() { q "select public.zella_assistant_for_call('+15550009999', null, '$1')"; }
js() { python3 -I -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('$1'))" "$2"; }
q "update public.platform_settings set value = '{\"calls\": true, \"messages\": false}' where key = 'usage_enforcement'" > /dev/null
[ "$(js action "$(gate)")" = answer ] && ok "before: used up with no forward number keeps the AI answering (the gap)" || bad "before exhausted: $(gate)"
q "update public.zz_stub set v = 'not_configured'" > /dev/null
[ "$(js action "$(gate)")" = answer ] && ok "before: an unknown allowance keeps the AI answering (the gap)" || bad "before unknown"

out=$(apply "$REPO/sql/zella_call_limits.sql") && ok "applies" || { bad "applies: $out"; finish; }
out=$(apply "$REPO/sql/zella_call_limits.sql") && ok "applies again" || bad "second apply: $out"
[ "$(fp)" = "6d554bec9fbc05b8c97e53f565100c04,09a18d90f1138a04e5b284048f4210d1" ] && ok "new fingerprints are the recorded ones" || bad "fingerprints $(fp)"

for s in not_configured error exhausted inactive; do
  q "update public.zz_stub set v = '$s'" > /dev/null
  [ "$(js action "$(gate)")" = closed ] || bad "$s: $(gate)"; done; ok "used up, inactive, not set up or unreadable: closed when there is no number"
q "update public.zz_stub set v = 'active'" > /dev/null; [ "$(js action "$(gate)")" = answer ] && ok "minutes left: answer" || bad "active"
q "update public.zz_stub set v = 'exhausted'" > /dev/null
q "update public.ai_agent_configs set escalation_rules = '{\"fallback_number\": \"+15125550100\"}' where agent_id = '$AG'" > /dev/null
r=$(gate); [ "$(js action "$r")$(js number "$r")" = "forward+15125550100" ] && ok "used up with a valid number: forward" || bad "forward: $r"
q "update public.ai_agent_configs set escalation_rules = '{\"fallback_number\": \"+15550009999\"}' where agent_id = '$AG'" > /dev/null
[ "$(js action "$(gate)")" = closed ] && ok "a forward number that rings back into Zella Voice is not used" || bad "loop"
q "update public.ai_agent_configs set escalation_rules = '{}' where agent_id = '$AG'" > /dev/null
q "insert into public.auto_reload_settings (business_id, resource, enabled, threshold, pack_code, monthly_cap_cents) select '$BIZ', 'minutes', true, 10, code, 5000 from public.billing_pack_catalog limit 1" > /dev/null 2>&1
if [ "$(q "select count(*) from public.auto_reload_settings where business_id = '$BIZ'")" = 1 ]; then
  r=$(gate); [ "$(js action "$r")$(js usage_reason "$r")" = "closedauto_reload_unavailable" ] && ok "auto reload on while reloads can't run: counts as a failed reload" || bad "reload off: $r"
  q "update public.platform_settings set value = 'true' where key = 'auto_reload_live'" > /dev/null
  r=$(gate); [ "$(js action "$r")$(js usage_reason "$r")" = "answerauto_reload" ] && ok "auto reload on and reloads running: keep answering" || bad "reload on: $r"
  q "update public.platform_settings set value = 'false' where key = 'auto_reload_live'; delete from public.auto_reload_settings" > /dev/null
else bad "could not set up auto reload in this copy"; fi
q "update public.platform_settings set value = '{\"calls\": false, \"messages\": false}' where key = 'usage_enforcement'" > /dev/null
r=$(gate); [ "$(js action "$r")$(js would_close "$r")" = "answerTrue" ] && ok "enforcement off: callers unchanged, the gate reports would_close" || bad "off: $r"
q "update public.platform_settings set value = '{\"calls\": true, \"messages\": false}' where key = 'usage_enforcement'" > /dev/null

r=$(afc call-a); [ "$(js outcome "$r")" = closed ] && ok "the call is answered with the closed outcome" || bad "afc closed: $r"
afc call-b > /dev/null
[ "$(q "select count(*) from public.staff_notifications where business_id = '$BIZ' and kind = 'minutes_used_up'")" = 1 ] && ok "owners are reminded once in 6 hours (not once per call)" || bad "reminders: $(q "select count(*) from public.staff_notifications where business_id = '$BIZ' and kind = 'minutes_used_up'")"
q "update public.zz_stub set v = 'not_configured'" > /dev/null; afc call-c > /dev/null; afc call-d > /dev/null
[ "$(q "select occurrences from public.platform_alerts where business_id = '$BIZ' and kind = 'usage_allowance_unknown'")" = 2 ] && ok "an unknown allowance raises one platform alert a day" || bad "alert"
[ "$(q "select count(*) from public.assistant_deliveries where business_id = '$BIZ' and outcome = 'closed_usage'")" = 4 ] && ok "each closed call is recorded" || bad "deliveries"

# calls at the same time
q "update public.zz_stub set v = 'active'; update public.platform_settings set value = '2' where key = 'voice_max_concurrent_calls'" > /dev/null
[ "$(js outcome "$(afc live-1)")$(js outcome "$(afc live-2)")" = servedserved ] && ok "two calls at once are served (limit 2)" || bad "under cap"
r=$(afc live-3); [ "$(js outcome "$r")$(js reason "$r")" = closedover_call_limit ] && ok "the third at the same time hears the closed message" || bad "over cap: $r"
q "insert into public.calls (business_id, direction, status, external_call_id, ended_at, from_number, ai_handled, duration_seconds) values ('$BIZ', 'inbound', 'answered', 'live-1', now(), '+15125550111', true, 60)" > /dev/null
[ "$(js outcome "$(afc live-4)")" = served ] && ok "once a call ends, the next one is served" || bad "after end"
q "update public.businesses set voice_max_concurrent_calls = 5 where id = '$BIZ'" > /dev/null
[ "$(js outcome "$(afc live-5)")" = served ] && ok "a business's own limit wins over the platform's" || bad "override"
[ "$(js outcome "$(afc live-5)")" = served ] && ok "the same call asking again isn't counted against itself" || bad "same call"

apply "$REPO/sql/rollback/zella_call_limits_rollback.sql" > /dev/null && apply "$REPO/sql/rollback/zella_call_limits_rollback.sql" > /dev/null && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "$before" ] && ok "rollback restores both functions exactly" || bad "after rollback"
[ "$(q "select count(*) from public.assistant_deliveries where outcome = 'over_call_limit'")" = 1 ] && [ "$(q "select convalidated from pg_constraint where conname = 'assistant_deliveries_outcome_check'")" = f ] && ok "rollback keeps the call history (check put back as not valid)" || bad "history"
[ "$(q "select count(*) from information_schema.columns where table_name = 'businesses' and column_name = 'voice_max_concurrent_calls'")" = 0 ] && ok "rollback drops the column" || bad "column"
apply "$REPO/sql/zella_call_limits.sql" > /dev/null
q "create or replace function public.zella_call_gate(p_business_id uuid) returns jsonb language sql stable as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
out=$(apply "$REPO/sql/rollback/zella_call_limits_rollback.sql"); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "the rollback refuses a changed function" || bad "rollback drift: $out"
q "delete from public.zella_function_archive where migration = 'zella_call_limits'" > /dev/null
out=$(apply "$REPO/sql/zella_call_limits.sql"); [[ "$out" == *VERSION_MISMATCH* ]] && ok "an unknown version stops the file" || bad "drift: $out"
finish
