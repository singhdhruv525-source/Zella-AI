#!/usr/bin/env bash
# sql/zella_number_orders.sql on an ISOLATED copy of the production schema (never production). Test people only; no
# provider is called (the provider calls live in owner-provision-business/providers.ts and are tested against local
# fakes in providers_test.ts). Checks: before, there is nowhere to record an order (the gap); applies, and applies again;
# number orders start switched off; a request needs telephony.manage, a reason and a key, and the same key gives back
# the same order; a number Zella Voice has, or one with an open order, is refused; only a Zella Voice owner who did not
# ask may decide; only the approver may place it, once; every step is audited with the admin's id in the same
# transaction; signed in people and anonymous can't call the functions or read the table; the rollback (twice) removes
# everything, refuses while an order is in flight, a changed function or the switch on; applies again; a changed
# function stops the file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zlg_number_orders}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "set client_min_messages = warning" -c "$1"; }
# production's functions: the writing cleanup, then the merged migrations not applied yet (docs/SCHEMA_STATUS.md)
for f in zella_writing_cleanup zella_cancellations_scheduled zella_admin_permissions zella_admin_mfa zella_support_notes zella_status_honest zella_retry_event_safe; do
  "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { bad "$f"; exit 1; }
done
OWNER=e2000000-0000-0000-0000-000000000001; OWNER2=e2000000-0000-0000-0000-000000000002; OPS=e2000000-0000-0000-0000-000000000003
RO=e2000000-0000-0000-0000-000000000004; MEMBER=e2000000-0000-0000-0000-000000000005; SUPER=e2000000-0000-0000-0000-000000000006
BIZ=e2000000-0000-0000-0000-0000000000b1
q "insert into auth.users (id, email, email_confirmed_at) values ('$OWNER', 'owner@orders.test', now()), ('$OWNER2', 'owner2@orders.test', now()),
     ('$OPS', 'ops@orders.test', now()), ('$RO', 'readonly@orders.test', now()), ('$MEMBER', 'member@orders.test', now()), ('$SUPER', 'super@orders.test', now());
   insert into public.platform_admins (user_id, role) values ('$OWNER', 'zella_owner'), ('$OWNER2', 'zella_owner'), ('$OPS', 'platform_operations'),
     ('$RO', 'read_only_admin'), ('$SUPER', 'super_admin');
   insert into public.platform_role_permissions (role, permission) values ('platform_operations', 'telephony.manage'), ('platform_operations', 'businesses.view'),
     ('read_only_admin', 'businesses.view') on conflict do nothing;
   insert into public.businesses (id, name) values ('$BIZ', 'Orders Test Business');
   insert into public.business_phone_numbers (business_id, e164) values ('$BIZ', '+15550100001')" > /dev/null || exit 1
# one statement as the server (service role): the first line of output, or the error
srv() { "${P[@]}" -d $DB -c "set client_min_messages = warning" -c "set role service_role" -c "$1" 2>&1 | head -1; }
# one statement as a signed in person (or anonymous with an empty id)
as() { local role=authenticated; [ -z "$1" ] && role=anon
  "${P[@]}" -d $DB -c "set role $role" -c "select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"$role\"}', false)" -c "$2" 2>&1 | sed -n 2p; }
K1=f2000000-0000-0000-0000-000000000001; K2=f2000000-0000-0000-0000-000000000002; K3=f2000000-0000-0000-0000-000000000003; K4=f2000000-0000-0000-0000-000000000004
req() { srv "select public.zella_number_order_request('$1', '$2', '$3', ${4:-null}, null, '$5', '$6') ->> '${7:-status}'"; }
audits() { q "select count(*) from public.audit_logs where action like 'telephony.number_order_%'"; }

v=$(q "select to_regclass('public.number_orders') is null and to_regprocedure('public.zella_number_order_request(uuid,text,text,uuid,text,text,uuid)') is null")
[ "$v" = "t" ] && ok "before: there is nowhere to record who asked for a number or who approved the spend (the gap)" || bad "before: $v"

"${P[@]}" -d $DB -f "$REPO/sql/zella_number_orders.sql" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$REPO/sql/zella_number_orders.sql" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$REPO/sql/zella_number_orders.sql" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"
[ "$(q "select value::text from public.platform_settings where key = 'number_orders_enabled'")" = "false" ] && ok "number orders start switched off" || bad "switch"

# request
[[ "$(req $RO purchase +15550100002 "'$BIZ'" "Needs a line" $K1)" == *NOT_ALLOWED* ]] && ok "a role without telephony.manage can't ask for a number" || bad "read only requested"
[[ "$(req $MEMBER purchase +15550100002 "'$BIZ'" "Needs a line" $K1)" == *NOT_ALLOWED* ]] && ok "someone who isn't an admin can't ask for a number" || bad "member requested"
[[ "$(req $OPS purchase +15550100002 "'$BIZ'" "x" $K1)" == *REASON_REQUIRED* ]] && ok "a reason is required" || bad "no reason"
[[ "$(srv "select public.zella_number_order_request('$OPS', 'purchase', '+15550100002', null, null, 'Needs a line', null)")" == *KEY_REQUIRED* ]] && ok "an idempotency key is required" || bad "no key"
[[ "$(req $OPS purchase +15550100002 "'e2000000-0000-0000-0000-0000000000ff'" "Needs a line" $K1)" == *BUSINESS_NOT_FOUND* ]] && ok "an unknown business is refused" || bad "unknown business"
[[ "$(req $OPS purchase 12345 "'$BIZ'" "Needs a line" $K1)" == *INVALID_NUMBER* ]] && ok "a number without its country code is refused" || bad "bad number"
[[ "$(req $OPS purchase +15550100001 "'$BIZ'" "Needs a line" $K1)" == *ALREADY_OURS* ]] && ok "buying a number Zella Voice already has is refused" || bad "already ours"
[[ "$(req $OPS release +15550100001 null "Not needed" $K1)" == *RELEASE_IN_USE* ]] && ok "releasing a number still assigned in Zella Voice is refused" || bad "release in use"
[ "$(audits)" = "0" ] && ok "nothing refused was recorded as a step" || bad "audit after refusals: $(audits)"
[ "$(req $OPS purchase "+1 (555) 010-0002" "'$BIZ'" "  New line for the front desk  " $K1)" = "requested" ] && ok "telephony.manage asks for a number, with a reason" || bad "request"
[ "$(req $OPS purchase +15550100002 "'$BIZ'" "New line for the front desk" $K1 repeated)" = "true" ] && ok "the same key gives back the same order (a retried click is not a second order)" || bad "repeat"
[ "$(q "select count(*) from public.number_orders")" = "1" ] && ok "and only one order exists" || bad "orders: $(q "select count(*) from public.number_orders")"
[[ "$(req $OWNER purchase +15550100002 "'$BIZ'" "New line" $K1)" == *KEY_REUSED* ]] && ok "someone else can't reuse a key" || bad "key reuse"
[[ "$(req $SUPER purchase +15550100002 "'$BIZ'" "Another" $K2)" == *ORDER_OPEN* ]] && ok "one open order per number" || bad "two open orders"
ID=$(q "select id from public.number_orders where idempotency_key = '$K1'")
v=$(q "select user_id || '|' || (new_data ->> 'e164') || '|' || (new_data ->> 'reason') from public.audit_logs where action = 'telephony.number_order_requested'")
[ "$v" = "$OPS|+15550100002|New line for the front desk" ] && ok "the request is audited with the admin's id, the number and the reason" || bad "request audit: $v"

# decide
dec() { srv "select public.zella_number_order_decide('$1', '$2', $3, '$4') ->> 'status'"; }
[[ "$(dec $OPS $ID true "Approved")" == *OWNER_REQUIRED* ]] && ok "telephony.manage alone can't approve the spend" || bad "ops approved"
[[ "$(dec $SUPER $ID true "Approved")" == *OWNER_REQUIRED* ]] && ok "a super admin can't approve the spend" || bad "super approved"
[[ "$(dec $OWNER $ID true "x")" == *REASON_REQUIRED* ]] && ok "the decision needs a reason" || bad "decide no reason"
[[ "$(srv "select public.zella_number_order_claim('$OWNER', '$ID')")" == *NOT_APPROVED* ]] && ok "an order can't be placed before it is approved" || bad "claim before approval"
[ "$(req $OWNER purchase +15550100003 null "Owner wants a spare" $K3)" = "requested" ] && ok "an owner may ask too" || bad "owner request"
ID3=$(q "select id from public.number_orders where idempotency_key = '$K3'")
[[ "$(dec $OWNER $ID3 true "Approving my own")" == *SECOND_PERSON_REQUIRED* ]] && ok "an owner can't approve their own order (two people for every order)" || bad "self approval"
[ "$(dec $OWNER2 $ID3 false "Not this month")" = "rejected" ] && ok "another owner rejects it" || bad "reject"
[[ "$(dec $OWNER $ID3 true "Changed my mind")" == *NOT_PENDING* ]] && ok "a rejected order stays rejected" || bad "re-decide"
[ "$(dec $OWNER $ID true "Approved for the launch")" = "approved" ] && ok "a Zella Voice owner who didn't ask approves" || bad "approve"
[[ "$(srv "select public.zella_number_order_cancel('$OPS', '$ID', 'Too late')")" == *NOT_PENDING* ]] && ok "an approved order can't be cancelled from here" || bad "cancel approved"

# claim and finish
[[ "$(srv "select public.zella_number_order_claim('$OWNER2', '$ID')")" == *NOT_APPROVED* ]] && ok "only the owner who approved may place it" || bad "other owner claimed"
[ "$(srv "select public.zella_number_order_claim('$OWNER', '$ID') ->> 'status'")" = "placing" ] && ok "the approver places it" || bad "claim"
[[ "$(srv "select public.zella_number_order_claim('$OWNER', '$ID')")" == *NOT_APPROVED* ]] && ok "a second claim is refused, so the provider is never asked twice" || bad "double claim"
[[ "$(srv "select public.zella_number_order_finish('$OWNER', '$ID', 'done', null, null, null, null)")" == *INVALID_OUTCOME* ]] && ok "only completed, failed or needs check are outcomes" || bad "outcome"
[[ "$(srv "select public.zella_number_order_finish('$OPS', '$ID', 'completed', 'ord_1', 'num_1', null, null)")" == *OWNER_REQUIRED* ]] && ok "only the owner's request can record the provider's answer" || bad "ops finished"
[ "$(srv "select public.zella_number_order_finish('$OWNER', '$ID', 'completed', 'ord_1', 'num_1', 'vapi_1', null) ->> 'provider_order_id'")" = "ord_1" ] && ok "the provider's answer is recorded" || bad "finish"
[[ "$(srv "select public.zella_number_order_finish('$OWNER', '$ID', 'failed', null, null, null, 'again')")" == *NOT_PLACING* ]] && ok "a finished order can't be finished again" || bad "double finish"
v=$(q "select string_agg(action || ':' || user_id, ',' order by created_at, action) from public.audit_logs where entity_id = '$ID'")
[ "$v" = "telephony.number_order_requested:$OPS,telephony.number_order_approved:$OWNER,telephony.number_order_placing:$OWNER,telephony.number_order_completed:$OWNER" ] \
  && ok "every step of the order is audited, in order, with who did it" || bad "steps: $v"

# cancel
[ "$(req $OPS purchase +15550100004 null "Spare line" $K4)" = "requested" ] || bad "request 4"
ID4=$(q "select id from public.number_orders where idempotency_key = '$K4'")
[[ "$(srv "select public.zella_number_order_cancel('$RO', '$ID4', 'Not mine')")" == *NOT_ALLOWED* ]] && ok "a role without telephony.manage can't cancel" || bad "ro cancel"
[ "$(srv "select public.zella_number_order_cancel('$OPS', '$ID4', 'Asked by mistake') ->> 'status'")" = "cancelled" ] && ok "the requester cancels before a decision" || bad "cancel"
v=$(srv "select jsonb_array_length(public.zella_number_orders_list('$RO', 50)) || '/' || (public.zella_number_orders_list('$RO', 50) -> 0 ->> 'requested_by_email')")
[ "$v" = "3/ops@orders.test" ] && ok "the list shows every order, newest first, with who asked" || bad "list: $v"
[[ "$(srv "select public.zella_number_orders_list('$MEMBER', 50)")" == *NOT_ALLOWED* ]] && ok "someone who isn't an admin can't list orders" || bad "member list"

# direct access
for fn in "zella_number_order_request('$OPS', 'purchase', '+15550100009', null, null, 'Direct', gen_random_uuid())" "zella_number_order_decide('$OWNER', '$ID4', true, 'Direct')" \
          "zella_number_order_claim('$OWNER', '$ID')" "zella_number_orders_list('$OWNER', 5)" "zella_actor_audit('$OWNER', 'x', null, null, null, null, null)"; do
  [[ "$(as $OWNER "select public.$fn")" == *"permission denied"* ]] || { bad "a signed in owner could call $fn directly"; continue; }
  [[ "$(as "" "select public.$fn")" == *"permission denied"* ]] || bad "anonymous could call $fn"
done && ok "signed in people (even an owner) and anonymous can't call the functions directly; only the server can"
[[ "$(as $OWNER "select count(*) from public.number_orders")" == *"permission denied"* ]] && ok "the table can't be read directly" || bad "table readable"

# a release, and an order that needs a check at the provider
K5=f2000000-0000-0000-0000-000000000005
[ "$(req $OPS release +15550100005 null "Line no longer used" $K5)" = "requested" ] || bad "release request"
ID5=$(q "select id from public.number_orders where idempotency_key = '$K5'")
[ "$(dec $OWNER $ID5 true "Release approved")" = "approved" ] || bad "release approve"
[[ "$(q "insert into public.business_phone_numbers (business_id, e164) values ('$BIZ', '+15550100005')" 2>&1)" == *NUMBER_RELEASE_OPEN* ]] && ok "a number can't be given to a business while its release is open" || bad "assign during release"
q "set session_replication_role = replica; insert into public.business_phone_numbers (business_id, e164) values ('$BIZ', '+15550100005')" > /dev/null
[[ "$(srv "select public.zella_number_order_claim('$OWNER', '$ID5')")" == *RELEASE_IN_USE* ]] && ok "a release is refused when it is placed if the number was given out after the request" || bad "claim release in use"
q "delete from public.business_phone_numbers where e164 = '+15550100005'" > /dev/null
[ "$(srv "select public.zella_number_order_claim('$OWNER', '$ID5') ->> 'status'")" = "placing" ] || bad "release claim"
[ "$(srv "select public.zella_number_order_finish('$OWNER', '$ID5', 'needs_check', null, null, null, 'No answer') ->> 'status'")" = "needs_check" ] || bad "needs check"
res() { srv "select public.zella_number_order_resolve('$1', '$ID5', '$2', '$3', null, null) ->> 'status'"; }
[[ "$(res $OPS completed "Checked at Telnyx")" == *OWNER_REQUIRED* ]] && ok "only a Zella Voice owner resolves an order that needs a check" || bad "ops resolved"
[[ "$(res $OWNER done "Checked at Telnyx")" == *INVALID_OUTCOME* ]] && ok "it resolves to completed or failed only" || bad "resolve outcome"
[[ "$(res $OWNER completed "x")" == *REASON_REQUIRED* ]] && ok "and needs a reason" || bad "resolve reason"
[ "$(res $OWNER completed "Checked at Telnyx: released")" = "completed" ] && ok "an owner records what the provider shows" || bad "resolve"
[[ "$(res $OWNER failed "Again")" == *NOT_NEEDS_CHECK* ]] && ok "a resolved order can't be resolved again" || bad "double resolve"
[ "$(q "select user_id || '|' || (new_data ->> 'status') || '|' || (old_data ->> 'error') from public.audit_logs where action = 'telephony.number_order_resolved' and entity_id = '$ID5'")" = "$OWNER|completed|No answer" ] && ok "the resolution is audited with the provider's earlier message" || bad "resolve audit"
[ "$(q "select error from public.number_orders where id = '$ID5'")" = "Recorded after a check: Checked at Telnyx: released" ] && ok "the order shows what the owner recorded, not the old provider message" || bad "resolve message"
q "insert into public.business_phone_numbers (business_id, e164) values ('$BIZ', '+15550100005')" > /dev/null && ok "once the release is finished the number can be given out again" || bad "assign after release"

# rollback
q "update public.number_orders set status = 'needs_check' where id = '$ID4'" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_number_orders_rollback.sql" 2>&1); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "the rollback refuses while an order needs a check at Telnyx" || bad "rollback in flight: $out"
q "update public.number_orders set status = 'cancelled' where id = '$ID4'; update public.platform_settings set value = 'true' where key = 'number_orders_enabled'" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_number_orders_rollback.sql" 2>&1); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "the rollback refuses while number orders are switched on" || bad "rollback switch on: $out"
q "update public.platform_settings set value = 'false' where key = 'number_orders_enabled'" > /dev/null
"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_number_orders_rollback.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_number_orders_rollback.sql" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
v=$(q "select to_regclass('public.number_orders') is not null and exists (select 1 from public.number_orders where id = '$ID4') and to_regprocedure('public.zella_actor_can(uuid,text)') is null and to_regprocedure('public.zella_number_order_resolve(uuid,uuid,text,text,text,text)') is null and not exists (select 1 from pg_trigger where tgname = 'zella_number_assign_guard') and not exists (select 1 from public.platform_settings where key = 'number_orders_enabled')")
[ "$v" = "t" ] && ok "rollback removes the functions, the guard and the setting, and keeps every order" || bad "leftovers"
"${P[@]}" -d $DB -f "$REPO/sql/zella_number_orders.sql" > /dev/null 2>&1 && [ "$(q "select status from public.number_orders where id = '$ID4'")" = "cancelled" ] && ok "applying the file again uses the kept orders" || bad "reapply after rollback"
[ "$(q "select count(*) from public.audit_logs where action like 'telephony.number_order_%'")" -ge 7 ] && ok "the audit trail of every order survives the rollback" || bad "audit lost"
"${P[@]}" -d $DB -f "$REPO/sql/zella_number_orders.sql" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_number_order_claim(p_actor uuid, p_id uuid) returns jsonb language sql as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_number_orders_rollback.sql" 2>&1); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "the rollback refuses a changed function" || bad "rollback drift: $out"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_number_orders.sql" 2>&1); [[ "$out" == *VERSION_MISMATCH* ]] && ok "a changed function stops the file" || bad "drift: $out"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
