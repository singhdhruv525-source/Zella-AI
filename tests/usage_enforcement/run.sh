#!/usr/bin/env bash
# sql/zella_usage_enforcement.sql on an ISOLATED copy of the production schema (never production), after the billing
# migrations it needs: applied twice; server only; with both switches OFF nothing changes (calls answered, messages
# prepared) but the gate reports what it would do; with a switch ON, a call at 100% is forwarded to the business's own
# number (pay as you go keeps answering; no valid number keeps answering), routine messages stop at 100% while
# appointment messages use the reserve; the rollback (run twice) restores the three functions exactly.
# The allowance lookups are replaced by test stand ins so each state can be set directly; their own logic is tested
# in tests/billing.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zusageenforce
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template zdocs" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
NEEDS=(zella_fk_indexes zella_model_defaults zella_unsubscribe_limit zella_tenant_business_id zella_billing_allowances)
for f in "${NEEDS[@]}"; do "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { bad "prerequisite $f"; exit 1; }; done
before_call=$(q "select md5(pg_get_functiondef('public.zella_assistant_for_call(text,text,text)'::regprocedure))")
before_sms=$(q "select md5(pg_get_functiondef('public.zella_prepare_sms(uuid,uuid,text,jsonb,text)'::regprocedure))")
before_email=$(q "select md5(pg_get_functiondef('public.zella_prepare_email(uuid,uuid,text,jsonb,text)'::regprocedure))")

for i in 1 2; do out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_usage_enforcement.sql" 2>&1) || { bad "apply (run $i): $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"; exit 1; }; done
ok "applies twice (each patch guarded)"
[ "$(q "select bool_or(has_function_privilege(r, 'public.zella_call_gate(uuid)', 'execute') or has_function_privilege(r, 'public.zella_message_gate(uuid,text,text)', 'execute')) from unnest(array['anon','authenticated']) r")" = f ] \
  && ok "server only" || bad "gates callable from the browser"
[ "$(q "select value from platform_settings where key = 'usage_enforcement'")" = '{"calls": false, "messages": false}' ] && ok "both switches start off" || bad "switches not off"

out=$("${P[@]}" -d $DB 2>&1 <<'SQL'
-- test data only
insert into businesses (id, name, phone) values ('b0000000-0000-4000-8000-0000000000f1', 'Test Studio', '(555) 010-2040'),
                                                ('b0000000-0000-4000-8000-0000000000f2', 'Test No Number', '(555) 010-2041');
-- the fallback number lives in the receptionist's rules (set at Create Business); the second business has none, and its
-- own phone must never be used instead
insert into ai_agents (id, business_id, name, agent_type, is_default) values
  ('a6000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-0000000000f1', 'Receptionist', 'receptionist', true),
  ('a6000000-0000-4000-8000-000000000002', 'b0000000-0000-4000-8000-0000000000f2', 'Receptionist', 'receptionist', true);
insert into ai_agent_configs (agent_id, business_id, escalation_rules) values
  ('a6000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-0000000000f1', '{"fallback_number": "+15550103000"}'),
  ('a6000000-0000-4000-8000-000000000002', 'b0000000-0000-4000-8000-0000000000f2', '{}');
create table test_state (business_id uuid primary key, call_status text, msg_exhausted boolean, buffer_left boolean);
insert into test_state values ('b0000000-0000-4000-8000-0000000000f1', 'active', false, true), ('b0000000-0000-4000-8000-0000000000f2', 'active', false, true);
-- stand ins: the allowance lookups read test_state; the number lookup finds the first business
create or replace function public.zella_call_entitlement_check(p_business_id uuid) returns jsonb language sql stable as
  $f$ select jsonb_build_object('status', call_status, 'reason', case call_status when 'exhausted' then 'allowance_used' when 'inactive' then 'subscription_past_due' else 'within_allowance' end)
        from test_state where business_id = p_business_id $f$;
create or replace function public.zella_message_allowance(p_business_id uuid, p_channel text, p_kind text) returns jsonb language sql stable as
  $f$ select jsonb_build_object('would_permit', not msg_exhausted or (p_kind = 'appointment' and buffer_left),
                               'reason', case when not msg_exhausted then 'within_allowance' when p_kind = 'appointment' and buffer_left then 'buffer' else 'allowance_used' end)
        from test_state where business_id = p_business_id $f$;
create or replace function public.zella_business_for_number(p_called_number text, p_vapi_phone_number_id text default null, p_fallback uuid default null) returns uuid language sql stable as
  $f$ select case when p_called_number = '+15550000001' then 'b0000000-0000-4000-8000-0000000000f1'::uuid end $f$;   -- +15550000001 is a Zella Voice line
SQL
) || { bad "seed: $(echo "$out" | grep -m1 ERROR)"; exit 1; }

out=$("${P[@]}" -d $DB 2>&1 <<'SQL'
do $$ declare g jsonb; r jsonb; begin
  -- within allowance: answer, nothing would change
  g := public.zella_call_gate('b0000000-0000-4000-8000-0000000000f1');
  assert g ->> 'action' = 'answer' and not (g ->> 'would_forward')::boolean, 'within allowance: ' || g;
  -- minutes used up, switch OFF: still answered; reports it would forward to the business's own number
  update test_state set call_status = 'exhausted' where business_id = 'b0000000-0000-4000-8000-0000000000f1';
  g := public.zella_call_gate('b0000000-0000-4000-8000-0000000000f1');
  assert g ->> 'action' = 'answer' and (g ->> 'would_forward')::boolean and g ->> 'number' = '+15550103000' and not (g ->> 'enforced')::boolean, 'off: ' || g;
  r := public.zella_assistant_for_call('+15550000001', null, 'call_off');
  assert r ->> 'outcome' is distinct from 'forward', 'switch off forwarded a call';
  -- switch ON: forwarded and recorded
  update platform_settings set value = '{"calls": true, "messages": false}' where key = 'usage_enforcement';
  r := public.zella_assistant_for_call('+15550000001', null, 'call_on');
  assert r ->> 'outcome' = 'forward' and r ->> 'forward_number' = '+15550103000' and r ->> 'reason' = 'allowance_used', 'on: ' || r;
  assert exists (select 1 from assistant_deliveries where provider_call_id = 'call_on' and outcome = 'forwarded_usage'), 'forward recorded';
  -- a paused or unpaid business is forwarded the same way
  update test_state set call_status = 'inactive' where business_id = 'b0000000-0000-4000-8000-0000000000f1';
  assert public.zella_call_gate('b0000000-0000-4000-8000-0000000000f1') ->> 'action' = 'forward', 'inactive forwarded';
  -- no valid number to forward to: answered as before, never dropped
  update test_state set call_status = 'exhausted' where business_id = 'b0000000-0000-4000-8000-0000000000f2';
  g := public.zella_call_gate('b0000000-0000-4000-8000-0000000000f2');
  assert g ->> 'action' = 'answer' and g ->> 'reason' = 'no_number_to_forward_to', 'no number: ' || g;
  -- pay as you go with a per minute rate keeps answering (needs a plan with a rate)
  update test_state set call_status = 'exhausted' where business_id = 'b0000000-0000-4000-8000-0000000000f1';
  insert into business_usage_preferences (business_id, overage_mode) values ('b0000000-0000-4000-8000-0000000000f1', 'pay_as_you_go');
  g := public.zella_call_gate('b0000000-0000-4000-8000-0000000000f1');
  assert g ->> 'action' = 'forward', 'pay as you go without a rate on the plan must not answer for free: ' || g;
  -- a number written with + that isn't valid E.164 is no number: answered, never forwarded to a number voice-rules would refuse
  update ai_agent_configs set escalation_rules = '{"fallback_number": "+0123456789"}' where agent_id = 'a6000000-0000-4000-8000-000000000002';
  update test_state set call_status = 'exhausted' where business_id = 'b0000000-0000-4000-8000-0000000000f2';
  g := public.zella_call_gate('b0000000-0000-4000-8000-0000000000f2');
  assert g ->> 'action' = 'answer' and g ->> 'number' is null, 'invalid + number: ' || g;
  -- a fallback that rings back into Zella Voice would loop: a Zella Voice line, or the business line that forwards here
  update test_state set call_status = 'exhausted' where business_id = 'b0000000-0000-4000-8000-0000000000f1';
  delete from business_usage_preferences where business_id = 'b0000000-0000-4000-8000-0000000000f1';
  update ai_agent_configs set escalation_rules = '{"fallback_number": "+15550000001"}' where agent_id = 'a6000000-0000-4000-8000-000000000001';
  g := public.zella_call_gate('b0000000-0000-4000-8000-0000000000f1');
  assert g ->> 'action' = 'answer' and g ->> 'number' is null, 'zella line as fallback: ' || g;
  update ai_agent_configs set escalation_rules = '{"fallback_number": "+15550104000"}' where agent_id = 'a6000000-0000-4000-8000-000000000001';
  update businesses set setup_data = '{"integrations": {"phone": {"forward_from": "(555) 010-4000"}}}' where id = 'b0000000-0000-4000-8000-0000000000f1';
  g := public.zella_call_gate('b0000000-0000-4000-8000-0000000000f1');
  assert g ->> 'action' = 'answer' and g ->> 'number' is null, 'forwarding line as fallback: ' || g;
  -- the same line written two ways (spaces in the setup answer, compact in call routing) is still the same line
  update ai_agent_configs set escalation_rules = '{"fallback_number": "+442079460000"}' where agent_id = 'a6000000-0000-4000-8000-000000000001';
  update businesses set setup_data = '{"integrations": {"phone": {"forward_from": "+44 20 7946 0000"}}}' where id = 'b0000000-0000-4000-8000-0000000000f1';
  g := public.zella_call_gate('b0000000-0000-4000-8000-0000000000f1');
  assert g ->> 'action' = 'answer' and g ->> 'number' is null, 'formatted international forwarding line: ' || g;
  assert public.zella_strict_e164('+44 20 7946 0000') = '+442079460000' and public.zella_strict_e164('(555) 210-3000') = '+15552103000'
     and public.zella_strict_e164('+0123456789') is null and public.zella_strict_e164('0123456789') is null, 'strict e164';
  raise notice 'PASS calls: answered while the switch is off (with what it would do); at 100%% with the switch on, forwarded to the business''s fallback number and recorded; never its own phone; paused businesses too; never dropped without a number; never forwarded back into Zella Voice; pay as you go needs a rate';
end $$;
SQL
) && echo "$out" | grep -o 'PASS .*' || bad "calls: $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"

out=$("${P[@]}" -d $DB 2>&1 <<'SQL'
do $$ declare r jsonb; begin
  update test_state set msg_exhausted = true where business_id = 'b0000000-0000-4000-8000-0000000000f1';
  -- switch OFF: prepared as before (the unknown customer is the next check, so it answers unknown_customer)
  r := public.zella_prepare_sms('b0000000-0000-4000-8000-0000000000f1', gen_random_uuid(), 'lead_acknowledgement');
  assert r ->> 'reason' = 'unknown_customer', 'off blocked a text: ' || r;
  assert (public.zella_message_gate('b0000000-0000-4000-8000-0000000000f1', 'sms', 'lead_acknowledgement') ->> 'would_block')::boolean, 'reports would block';
  -- switch ON: routine stops, appointment messages use the reserve, then stop when it is gone too
  update platform_settings set value = '{"calls": false, "messages": true}' where key = 'usage_enforcement';
  r := public.zella_prepare_sms('b0000000-0000-4000-8000-0000000000f1', gen_random_uuid(), 'lead_acknowledgement');
  assert r ->> 'reason' = 'allowance_used' and not (r ->> 'allowed')::boolean, 'routine text not stopped: ' || r;
  r := public.zella_prepare_email('b0000000-0000-4000-8000-0000000000f1', gen_random_uuid(), 'no_show_follow_up');
  assert r ->> 'reason' = 'allowance_used', 'routine email not stopped: ' || r;
  r := public.zella_prepare_sms('b0000000-0000-4000-8000-0000000000f1', gen_random_uuid(), 'appointment_reminder');
  assert r ->> 'reason' = 'unknown_customer', 'reminder stopped while the reserve is left: ' || r;
  update test_state set buffer_left = false where business_id = 'b0000000-0000-4000-8000-0000000000f1';
  r := public.zella_prepare_sms('b0000000-0000-4000-8000-0000000000f1', gen_random_uuid(), 'appointment_reminder');
  assert r ->> 'reason' = 'allowance_used', 'reminder sent after the reserve: ' || r;
  -- another business within its allowance is untouched
  r := public.zella_prepare_sms('b0000000-0000-4000-8000-0000000000f2', gen_random_uuid(), 'lead_acknowledgement');
  assert r ->> 'reason' = 'unknown_customer', 'other business blocked: ' || r;
  raise notice 'PASS messages: prepared as before while the switch is off; with it on, routine texts and emails stop at 100%%, appointment messages use the reserve and then stop; other businesses untouched';
end $$;
SQL
) && echo "$out" | grep -o 'PASS .*' || bad "messages: $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"

q "delete from assistant_deliveries where outcome = 'forwarded_usage'" > /dev/null
for i in 1 2; do out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_usage_enforcement_rollback.sql" 2>&1) || bad "rollback (run $i): $(echo "$out" | grep -m2 ERROR)"; done
[ "$(q "select md5(pg_get_functiondef('public.zella_assistant_for_call(text,text,text)'::regprocedure))")" = "$before_call" ] \
  && [ "$(q "select md5(pg_get_functiondef('public.zella_prepare_sms(uuid,uuid,text,jsonb,text)'::regprocedure))")" = "$before_sms" ] \
  && [ "$(q "select md5(pg_get_functiondef('public.zella_prepare_email(uuid,uuid,text,jsonb,text)'::regprocedure))")" = "$before_email" ] \
  && [ "$(q "select to_regprocedure('public.zella_call_gate(uuid)') is null and not exists (select 1 from platform_settings where key = 'usage_enforcement')")" = t ] \
  && ok "the rollback (run twice) restores all three functions exactly" || bad "rollback left a difference"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_usage_enforcement.sql" 2>&1) && ok "applies again after the rollback" || bad "re-apply: $(echo "$out" | grep -m1 ERROR)"

[ -n "${KEEP_DB:-}" ] || "${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null
[ $fails = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
