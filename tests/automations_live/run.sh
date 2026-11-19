#!/usr/bin/env bash
# BIZ-07 (owner-provision-business live.ts) on an ISOLATED copy of the production schema (zprod3; never production).
# Test data only. The database paths the new save rule relies on:
#   1. an automation saved paused with paused_by_suspension while its business is suspended is restarted when the
#      business is reactivated (by the lifecycle trigger, not by zella_reactivate_business's suspended_state list);
#   2. zella_suspend_business pauses the running automations itself (listed in setup_data.suspended_state, not
#      flagged), before the trigger fires; reactivating resumes those from the list;
#   3. industry rules saved paused during testing are activated when the business goes live (zella_request_activation
#      activates every paused automation of the business), as the standard ones are.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zle_automations_live}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
# this suite drops and recreates DB: only a database named for this suite, and never the template
[[ "$DB" =~ ^z[a-z0-9_]*automations_live$ ]] && [ "$DB" != "$TEMPLATE" ] || { echo "REFUSED: DB must be this suite's own database (z..._automations_live), not '$DB'" >&2; exit 1; }
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
OWNER=e8000000-0000-0000-0000-0000000000b1; LIVE=e8000000-0000-0000-0000-00000000b001; TEST=e8000000-0000-0000-0000-00000000b002
q "insert into auth.users (id, email, email_confirmed_at) values ('$OWNER', 'owner@live.test', now());
   insert into public.businesses (id, name, industry_id, timezone, onboarding_status, is_active)
     select v.id, v.n, i.id, 'America/New_York', v.s, v.a from (values ('$LIVE'::uuid, 'Live Test', 'active', true), ('$TEST'::uuid, 'Testing Test', 'testing', true)) v(id, n, s, a),
       (select id from public.industries order by name limit 1) i;
   insert into public.business_members (business_id, user_id, role, status) values ('$LIVE', '$OWNER', 'owner', 'active'), ('$TEST', '$OWNER', 'owner', 'active');" > /dev/null \
  || { echo "FAIL fixtures"; exit 1; }

# 1 and 2: suspend, save one automation as the switch on rule would (paused, flagged), reactivate.
q "insert into public.automations (business_id, name, trigger_type, status) values ('$LIVE', 'Running', 'appointment_reminder', 'active')" > /dev/null
q "set role service_role; select public.zella_suspend_business('$LIVE', 'test')" > /dev/null || bad "suspend"
v=$(q "select a.status || ':' || a.paused_by_suspension || ':' || (b.setup_data #> '{suspended_state,automations}' ? a.id::text) from public.automations a
  join public.businesses b on b.id = a.business_id where a.business_id = '$LIVE' and a.name = 'Running'")
[ "$v" = "paused:false:true" ] && ok "suspending pauses the running automation itself and lists it in suspended_state, unflagged ($v)" || bad "suspend: $v"
q "insert into public.automations (business_id, name, trigger_type, status, paused_by_suspension) values ('$LIVE', 'Turned on while suspended', 'missed_call_follow_up', 'paused', true),
     ('$LIVE', 'Saved paused, not flagged', 'quote_follow_up', 'paused', false)" > /dev/null
q "set role service_role; select public.zella_reactivate_business('$LIVE')" > /dev/null || bad "reactivate"
v=$(q "select string_agg(name || '=' || status, ', ' order by name) from public.automations where business_id = '$LIVE'")
[[ "$v" == *"Turned on while suspended=active"* && "$v" == *"Running=active"* ]] && ok "reactivating restarts every flagged automation, including one saved while suspended" || bad "reactivate: $v"
[[ "$v" == *"Saved paused, not flagged=paused"* ]] && ok "an automation saved paused without the flag stays paused (today's behaviour, the reason for the flag)" || bad "unflagged: $v"

# 3: a testing business with a paused standard automation and a paused industry rule goes live.
q "insert into public.automations (business_id, name, trigger_type, status) values ('$TEST', 'Standard', 'appointment_reminder', 'paused'), ('$TEST', 'Industry rule', 'record_due_reminder', 'paused');
   insert into public.integrations (business_id, provider, integration_type, status) values ('$TEST', 'telnyx', 'phone', 'active'), ('$TEST', 'vapi', 'voice', 'active');
   insert into public.ai_agents (business_id, name, agent_type, is_default, status) values ('$TEST', 'Ava', 'receptionist', true, 'active');
   insert into public.ai_agent_configs (agent_id, business_id, system_prompt, escalation_rules)
     select id, '$TEST', 'You answer calls for the test business politely.', '{\"transfer_to\": {\"type\": \"owner\"}}' from public.ai_agents where business_id = '$TEST';
   insert into public.knowledge_items (business_id, kind, title, answer, status) values ('$TEST', 'faq', 'Hours', 'Nine to five', 'ready');
   insert into public.activation_tests (business_id, ok) values ('$TEST', true);" > /dev/null || bad "activation fixtures"
v=$(q "do \$\$ declare v text; begin perform set_config('request.jwt.claims', json_build_object('sub', '$OWNER', 'role', 'authenticated', 'aal', 'aal2')::text, true);
  set local role authenticated; begin v := public.zella_request_activation('$TEST')::text; exception when others then v := 'ERR:' || sqlerrm; end; reset role; raise notice 'V=%', v; end \$\$" 2>&1 | sed -n 's/.*V=//p')
[[ "$v" != ERR* ]] && ok "the test business goes live" || bad "go live: $v"
v=$(q "select string_agg(name || '=' || status, ', ' order by name) from public.automations where business_id = '$TEST'")
[ "$v" = "Industry rule=active, Standard=active" ] && ok "going live activates industry rules saved paused during testing, and standard ones ($v)" || bad "after go live: $v"

"${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null
[ $fails -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
