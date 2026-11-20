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
q "update public.zz_stub set v = 'not_configured' where k = 'status'" > /dev/null
[ "$(js action "$(gate)")" = answer ] && ok "before: an unknown allowance keeps the AI answering (the gap)" || bad "before unknown"

out=$(apply "$REPO/sql/zella_call_limits.sql") && ok "applies" || { bad "applies: $out"; finish; }
out=$(apply "$REPO/sql/zella_call_limits.sql") && ok "applies again" || bad "second apply: $out"
[ "$(fp)" = "03ee44c36607ca56782820a30bffee82,6afc3f110b731620a5ffc5fc9cab0dca" ] && ok "new fingerprints are the recorded ones" || bad "fingerprints $(fp)"

for s in not_configured error exhausted inactive; do
  q "update public.zz_stub set v = '$s' where k = 'status'" > /dev/null
  [ "$(js action "$(gate)")" = closed ] || bad "$s: $(gate)"; done; ok "used up, inactive, not set up or unreadable: closed when there is no number"
q "update public.zz_stub set v = 'active' where k = 'status'" > /dev/null; [ "$(js action "$(gate)")" = answer ] && ok "minutes left: answer" || bad "active"
q "update public.zz_stub set v = 'exhausted' where k = 'status'" > /dev/null
q "update public.ai_agent_configs set escalation_rules = '{\"fallback_number\": \"+15125550100\"}' where agent_id = '$AG'" > /dev/null
r=$(gate); [ "$(js action "$r")$(js number "$r")" = "forward+15125550100" ] && ok "used up with a valid number: forward" || bad "forward: $r"
q "update public.ai_agent_configs set escalation_rules = '{\"fallback_number\": \"+15550009999\"}' where agent_id = '$AG'" > /dev/null
[ "$(js action "$(gate)")" = closed ] && ok "a forward number that rings back into Zella Voice is not used" || bad "loop"
q "update public.ai_agent_configs set escalation_rules = '{}' where agent_id = '$AG'" > /dev/null
# auto reload and pay as you go, with the payments switch, the subscription and the plan in force stubbed here
q "insert into public.zz_stub values ('payments', 'false'), ('overage', '0'), ('mode', 'stop')" > /dev/null
q "create or replace function public.zella_payments_live() returns boolean language sql stable as \$f\$ select (select v from public.zz_stub where k = 'payments')::boolean \$f\$" > /dev/null
q "create or replace function public.zella_billing_plan_at(p_business_id uuid, p_at timestamptz) returns public.business_plans language sql stable as \$f\$ select jsonb_populate_record(null::public.business_plans, jsonb_build_object('overage_cents_per_minute', (select v from public.zz_stub where k = 'overage')::int)) \$f\$" > /dev/null
q "insert into public.subscriptions (business_id, status) values ('$BIZ', 'active')" > /dev/null 2>&1 || q "insert into public.subscriptions (business_id, status, plan_id) select '$BIZ', 'active', id from public.plans limit 1" > /dev/null
mode() { q "insert into public.business_usage_preferences (business_id, overage_mode) values ('$BIZ', '$1') on conflict (business_id) do update set overage_mode = excluded.overage_mode" > /dev/null; }
q "insert into public.auto_reload_settings (business_id, resource, enabled, threshold, pack_code, monthly_cap_cents) values ('$BIZ', 'minutes', true, 10, 'minutes_100', 5000)" > /dev/null
r=$(gate); [ "$(js action "$r")$(js usage_reason "$r")" = "closedauto_reload_unavailable" ] && ok "auto reload on while payments are off: counts as a failed reload" || bad "reload off: $r"
q "update public.zz_stub set v = 'true' where k = 'payments'" > /dev/null
r=$(gate); [ "$(js action "$r")$(js usage_reason "$r")" = "answerauto_reload" ] && ok "auto reload on, payments live, within the cap: keep answering" || bad "reload on: $r"
# a reload bought earlier this month (the period's own rows aren't needed for this check: inserted with triggers and
# foreign keys off, in this test copy only)
q "set session_replication_role = replica; insert into public.pack_purchases (business_id, pack_code, resource, quantity, price_cents, status, source, reason, period_id, idempotency_key) values ('$BIZ', 'minutes_100', 'minutes', 100, 2900, 'granted', 'auto_reload', 'test reload one', gen_random_uuid(), 'reload-test-0001')" > /dev/null
if [ "$(q "select count(*) from public.pack_purchases where business_id = '$BIZ'")" = 1 ]; then
  r=$(gate); [ "$(js action "$r")" = closed ] && ok "the month's reloads plus one more pack over the owner's cap: no reload, closed" || bad "cap: $r"
else bad "reload cap setup: a pack purchase could not be inserted in this copy"; fi
# a reload stuck pending counts for 30 minutes, then no longer
q "update public.auto_reload_settings set monthly_cap_cents = 100000; set session_replication_role = replica; insert into public.pack_purchases (business_id, pack_code, resource, quantity, price_cents, status, source, reason, period_id, idempotency_key, purchased_at) values ('$BIZ', 'minutes_100', 'minutes', 100, 2900, 'pending', 'auto_reload', 'test reload stuck', gen_random_uuid(), 'reload-test-0002', now() - interval '31 minutes')" > /dev/null
q "update public.billing_pack_catalog set active = false where code = 'minutes_100'" > /dev/null
r=$(gate); [ "$(js action "$r")" = closed ] && ok "a reload stuck pending over 30 minutes no longer keeps calls open" || bad "stuck pending: $r"
q "update public.pack_purchases set purchased_at = now() where idempotency_key = 'reload-test-0002'" > /dev/null
r=$(gate); [ "$(js usage_reason "$r")" = auto_reload ] && ok "a reload in flight (under 30 minutes) keeps answering" || bad "in flight: $r"
q "update public.billing_pack_catalog set active = true where code = 'minutes_100'" > /dev/null
q "update public.zz_stub set v = 'false' where k = 'payments'; delete from public.auto_reload_settings" > /dev/null
mode auto_top_up; q "update public.zz_stub set v = '5' where k = 'overage'" > /dev/null
r=$(gate); [ "$(js action "$r")" = closed ] && ok "auto top up is a reload, not pay as you go: closed while reloads can't run" || bad "auto top up: $r"
mode pay_as_you_go
r=$(gate); [ "$(js action "$r")$(js usage_reason "$r")" = "answerpay_as_you_go" ] && ok "pay as you go with an overage price on the plan in force: keep answering" || bad "payg: $r"
q "update public.zz_stub set v = '0' where k = 'overage'" > /dev/null
r=$(gate); [ "$(js action "$r")" = closed ] && ok "pay as you go without an overage price: closed" || bad "payg no price: $r"
mode stop
q "update public.platform_settings set value = '{\"calls\": false, \"messages\": false}' where key = 'usage_enforcement'" > /dev/null
r=$(gate); [ "$(js action "$r")$(js would_close "$r")" = "answerTrue" ] && ok "enforcement off: callers unchanged, the gate reports would_close" || bad "off: $r"
q "update public.platform_settings set value = '{\"calls\": true, \"messages\": false}' where key = 'usage_enforcement'" > /dev/null

r=$(afc call-a); [ "$(js outcome "$r")" = closed ] && ok "the call is answered with the closed outcome" || bad "afc closed: $r"
afc call-b > /dev/null
[ "$(q "select count(*) from public.staff_notifications where business_id = '$BIZ' and kind = 'minutes_used_up'")" = 1 ] && ok "owners are reminded once in 6 hours (not once per call)" || bad "reminders: $(q "select count(*) from public.staff_notifications where business_id = '$BIZ' and kind = 'minutes_used_up'")"
q "update public.zz_stub set v = 'not_configured' where k = 'status'" > /dev/null; afc call-c > /dev/null; afc call-d > /dev/null
[ "$(q "select occurrences from public.platform_alerts where business_id = '$BIZ' and kind = 'usage_allowance_unknown'")" = 2 ] && ok "an unknown allowance raises one platform alert a day" || bad "alert"
[ "$(q "select count(*) from public.assistant_deliveries where business_id = '$BIZ' and outcome = 'closed_usage'")" = 4 ] && ok "each closed call is recorded" || bad "deliveries"
q "update public.zz_stub set v = 'inactive' where k = 'status'; delete from public.staff_notifications where business_id = '$BIZ' and kind = 'minutes_used_up'" > /dev/null; afc call-e > /dev/null
[ "$(q "select count(*) from public.staff_notifications where business_id = '$BIZ' and kind = 'minutes_used_up'")" = 0 ] && [ "$(q "select occurrences from public.platform_alerts where business_id = '$BIZ' and kind = 'usage_allowance_unknown'")" = 3 ] && ok "a subscription that isn't active alerts Zella Voice, not a buy minutes reminder" || bad "inactive"

# calls at the same time
q "update public.zz_stub set v = 'active' where k = 'status'; update public.platform_settings set value = '2' where key = 'voice_max_concurrent_calls'" > /dev/null
[ "$(js outcome "$(afc live-1)")$(js outcome "$(afc live-2)")" = servedserved ] && ok "two calls at once are served (limit 2)" || bad "under cap"
r=$(afc live-3); [ "$(js outcome "$r")$(js reason "$r")" = closedover_call_limit ] && ok "the third at the same time hears the closed message" || bad "over cap: $r"
q "insert into public.calls (business_id, direction, status, external_call_id, ended_at, from_number, ai_handled, duration_seconds) values ('$BIZ', 'inbound', 'answered', 'live-1', now(), '+15125550111', true, 60)" > /dev/null
[ "$(js outcome "$(afc live-4)")" = served ] && ok "once a call ends, the next one is served" || bad "after end"
q "update public.businesses set voice_max_concurrent_calls = 5 where id = '$BIZ'" > /dev/null
[ "$(js outcome "$(afc live-5)")" = served ] && ok "a business's own limit wins over the platform's" || bad "override"
[ "$(js outcome "$(afc live-5)")" = served ] && ok "the same call asking again isn't counted against itself" || bad "same call"
q "update public.businesses set voice_max_concurrent_calls = 1 where id = '$BIZ'" > /dev/null
q "update public.assistant_deliveries set created_at = now() - interval '11 minutes' where business_id = '$BIZ' and outcome = 'served' and provider_call_id <> 'live-5'" > /dev/null
q "update public.assistant_deliveries set created_at = now() - interval '11 minutes' where business_id = '$BIZ' and provider_call_id = 'live-5'" > /dev/null
[ "$(js outcome "$(afc live-6)")" = served ] && ok "a call whose report never arrived frees its place after 10 minutes" || bad "lost report"
q "update public.zz_stub set v = 'exhausted' where k = 'status'; update public.ai_agent_configs set escalation_rules = '{\"fallback_number\": \"+15125550100\"}' where agent_id = '$AG'" > /dev/null
r=$(afc live-7); [ "$(js outcome "$r")$(js forward_number "$r")" = "forward+15125550100" ] && ok "at the limit and out of minutes with a number: forwarded, not closed" || bad "cap forward: $r"
q "update public.zz_stub set v = 'active' where k = 'status'" > /dev/null
out=$(apply "$REPO/sql/rollback/zella_call_limits_rollback.sql"); [[ "$out" == *OVERRIDES_SET* ]] && ok "the rollback refuses while a business has its own limit saved" || bad "overrides: $out"
q "update public.businesses set voice_max_concurrent_calls = null" > /dev/null

apply "$REPO/sql/rollback/zella_call_limits_rollback.sql" > /dev/null && apply "$REPO/sql/rollback/zella_call_limits_rollback.sql" > /dev/null && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "$before" ] && ok "rollback restores both functions exactly" || bad "after rollback"
[ "$(q "select count(*) from public.assistant_deliveries where outcome = 'over_call_limit'")" = 1 ] && [ "$(q "select convalidated from pg_constraint where conname = 'assistant_deliveries_outcome_check'")" = f ] && ok "rollback keeps the call history (check put back as not valid)" || bad "history"
[ "$(q "select count(*) from information_schema.columns where table_name = 'businesses' and column_name = 'voice_max_concurrent_calls'")" = 0 ] && ok "rollback drops the column" || bad "column"
[ "$(q "select count(*) from public.platform_settings where key = 'voice_max_concurrent_calls'")" = 0 ] && ok "and removes only the setting it added" || bad "setting left"
apply "$REPO/sql/zella_call_limits.sql" > /dev/null
q "create or replace function public.zella_call_gate(p_business_id uuid) returns jsonb language sql stable as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
out=$(apply "$REPO/sql/rollback/zella_call_limits_rollback.sql"); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "the rollback refuses a changed function" || bad "rollback drift: $out"
q "delete from public.zella_function_archive where migration = 'zella_call_limits'" > /dev/null
out=$(apply "$REPO/sql/zella_call_limits.sql"); [[ "$out" == *VERSION_MISMATCH* ]] && ok "an unknown version stops the file" || bad "drift: $out"
finish
