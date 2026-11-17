#!/usr/bin/env bash
# sql/zella_support_replies.sql on an ISOLATED copy of the production schema (never production), after
# sql/zella_support_notes.sql (merged, not applied). Test people and businesses only.
# Checks: the gap before; applies, and applies again; a Zella Voice reply reaches the business (members read it,
# another business sees nothing, internal notes stay hidden), sets first_response_at once and notifies the opener in
# the app only; only the server may write a Zella Voice reply; owners, admins and managers may answer, staff,
# another business and anonymous may not, and nobody writes the table directly; an answer reopens a resolved ticket;
# alerts for cancellation, plan change and urgent requests, none for feedback; the business hours setting; the
# rollback refuses while replies exist, then runs twice; reapply; a changed function stops the file and the rollback.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zla_support}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
MIG="$REPO/sql/zella_support_replies.sql"; RB="$REPO/sql/rollback/zella_support_replies_rollback.sql"
if [ -z "$(q "select to_regclass('public.support_ticket_notes')")" ]; then
  "${P[@]}" -d $DB -f "$REPO/sql/zella_support_notes.sql" > /dev/null 2>&1 || { echo "could not load sql/zella_support_notes.sql"; exit 1; }
fi
as() {   # as <role> <sub> <sql>: prints R=<result or error>
  local claims; claims=$(printf '{"role":"%s"%s}' "$1" "${2:+,\"sub\":\"$2\"}")
  q "do \$\$ declare r text; begin perform set_config('request.jwt.claims', '$claims', true); execute 'set local role $1';
     begin execute '$3' into r; raise notice 'R=%', r; exception when others then raise notice 'R=%', sqlerrm; end; reset role; end \$\$" 2>&1 | sed -n 's/.*R=//p'
}
B1=f4000000-0000-0000-0000-0000000000b1; B2=f4000000-0000-0000-0000-0000000000b2
O1=f4000000-0000-0000-0000-000000000001; M1=f4000000-0000-0000-0000-000000000002; S1=f4000000-0000-0000-0000-000000000003
V1=f4000000-0000-0000-0000-000000000004; O2=f4000000-0000-0000-0000-000000000005; ZA=f4000000-0000-0000-0000-000000000009
T1=f4100000-0000-0000-0000-000000000001; T2=f4100000-0000-0000-0000-000000000002
q "insert into auth.users (id, email, email_confirmed_at) select u, 'sr' || right(u::text, 2) || '@support.test', now() from unnest(array['$O1','$M1','$S1','$V1','$O2','$ZA']::uuid[]) u" > /dev/null || exit 1
q "insert into public.profiles (id) select u from unnest(array['$O1','$M1','$S1','$V1','$O2','$ZA']::uuid[]) u on conflict do nothing" > /dev/null || exit 1
q "insert into public.businesses (id, name) values ('$B1', 'Support Test One'), ('$B2', 'Support Test Two')" > /dev/null || exit 1
q "insert into public.business_members (business_id, user_id, role) values ('$B1','$O1','owner'), ('$B1','$M1','manager'), ('$B1','$S1','staff'), ('$B1','$V1','viewer'), ('$B2','$O2','owner')" > /dev/null || exit 1
q "insert into public.platform_admins (user_id, role, is_active) values ('$ZA', 'support_admin', true)" > /dev/null || exit 1
q "insert into public.support_tickets (id, business_id, created_by, subject) values ('$T1', '$B1', '$O1', 'Calls drop'), ('$T2', '$B2', '$O2', 'Other business')" > /dev/null || exit 1
q "insert into public.support_ticket_notes (ticket_id, author_id, body) values ('$T1', '$ZA', 'internal only')" > /dev/null || exit 1

[ -z "$(q "select to_regclass('public.support_ticket_messages')")" ] && ok "before: there is nowhere for a reply the business can read (the gap)" || bad "before: messages table exists"
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$MIG" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"

r=$(as authenticated "$ZA" "select public.zella_admin_ticket_reply(''$T1'', ''$ZA'', ''x'')::text")
[[ "$r" == *"permission denied"* ]] && ok "a signed in person (even an admin) can't write a Zella Voice reply directly" || bad "authenticated admin reply: $r"
r=$(as service_role "" "select (public.zella_admin_ticket_reply(''$T1'', ''$ZA'', ''We are on it''))->>''business_id''")
[ "$r" = "$B1" ] && ok "the server adds a Zella Voice reply" || bad "server reply: $r"
first=$(q "select first_response_at from public.support_tickets where id = '$T1'")
[ -n "$first" ] && [ "$(q "select status from public.support_tickets where id = '$T1'")" = "in_progress" ] && ok "first_response_at is set and an open ticket moves to in progress" || bad "first response: $first"
sleep 1; as service_role "" "select public.zella_admin_ticket_reply(''$T1'', ''$ZA'', ''Second'')::text" > /dev/null
[ "$(q "select first_response_at from public.support_tickets where id = '$T1'")" = "$first" ] && ok "a second reply doesn't move first_response_at" || bad "first response moved"
n=$(q "select count(*) || ':' || min(delivery_status) || ':' || min(sms_status) || ':' || min(user_id::text) from public.staff_notifications where kind = 'support_reply' and entity_id = '$T1'")
[ "$n" = "2:skipped:skipped:$O1" ] && ok "the opener is told in the app, never by email or text ($n)" || bad "notifications: $n"
r=$(as service_role "" "select public.zella_admin_ticket_reply(''$T1'', ''$ZA'', ''   '')::text")
[[ "$r" == *"BAD_INPUT"* ]] && ok "an empty reply is refused" || bad "empty: $r"

for who in "$O1:owner" "$S1:staff" "$V1:viewer"; do
  r=$(as authenticated "${who%%:*}" "select count(*)::text from public.support_ticket_messages where ticket_id = ''$T1''")
  [ "$r" = "2" ] && ok "a ${who##*:} of the business reads the replies" || bad "${who##*:} reads $r"
done
r=$(as authenticated "$O2" "select count(*)::text from public.support_ticket_messages")
[ "$r" = "0" ] && ok "another business sees none of them" || bad "other business sees $r"
r=$(as authenticated "$O1" "select count(*)::text from public.support_ticket_notes")
[[ "$r" == *"permission denied"* || "$r" = "0" ]] && ok "internal notes stay hidden from the business ($r)" || bad "notes visible: $r"
r=$(as anon "" "select count(*)::text from public.support_ticket_messages")
[[ "$r" == *"permission denied"* ]] && ok "anonymous reads nothing" || bad "anon: $r"

r=$(as authenticated "$O1" "select (public.zella_business_ticket_reply(''$T1'', ''Thanks''))->>''message_id''")
[[ "$r" =~ ^[0-9a-f-]{36}$ ]] && ok "the owner answers" || bad "owner answer: $r"
r=$(as authenticated "$M1" "select (public.zella_business_ticket_reply(''$T1'', ''Manager here''))->>''message_id''")
[[ "$r" =~ ^[0-9a-f-]{36}$ ]] && ok "a manager answers" || bad "manager: $r"
r=$(as authenticated "$S1" "select public.zella_business_ticket_reply(''$T1'', ''Staff'')::text")
[[ "$r" == *"NOT_ALLOWED"* ]] && ok "staff can't answer" || bad "staff: $r"
r=$(as authenticated "$O2" "select public.zella_business_ticket_reply(''$T1'', ''Not mine'')::text")
[[ "$r" == *"NOT_ALLOWED"* ]] && ok "another business's owner can't answer this ticket" || bad "other owner: $r"
r=$(as anon "" "select public.zella_business_ticket_reply(''$T1'', ''x'')::text")
[[ "$r" == *"permission denied"* ]] && ok "anonymous can't answer" || bad "anon answer: $r"
r=$(as authenticated "$O1" "insert into public.support_ticket_messages (ticket_id, business_id, author_side, body) values (''$T1'', ''$B1'', ''zella'', ''fake'') returning id::text")
[[ "$r" == *"permission denied"* ]] && ok "nobody writes the table directly (no fake Zella Voice replies)" || bad "direct insert: $r"
[ "$(q "select string_agg(author_side, ',' order by created_at) from public.support_ticket_messages where ticket_id = '$T1'")" = "zella,zella,business,business" ] && ok "the thread is in order with who wrote each" || bad "thread"
q "update public.support_tickets set status = 'resolved', resolved_at = now() where id = '$T1'" > /dev/null
as authenticated "$O1" "select public.zella_business_ticket_reply(''$T1'', ''Still broken'')::text" > /dev/null
[ "$(q "select status || ':' || coalesce(resolved_at::text, 'none') from public.support_tickets where id = '$T1'")" = "open:none" ] && ok "an answer reopens a resolved ticket" || bad "reopen"

alert() { q "select count(*) from public.platform_alerts where kind = '$1' and business_id = '$B1'"; }
for kind in cancellation plan_change feedback; do as authenticated "$O1" "select public.zella_business_request(''$B1'', ''$kind'', ''Request $kind'', ''details'', ''{}''::jsonb)::text" > /dev/null; done
as authenticated "$O1" "select public.zella_business_request(''$B1'', ''issue'', ''Phones down'', ''details'', ''{\"urgent\": \"true\"}''::jsonb)::text" > /dev/null
as authenticated "$O1" "select public.zella_business_request(''$B1'', ''issue'', ''Small thing'', ''details'', ''{}''::jsonb)::text" > /dev/null
[ "$(alert support_cancellation_request):$(alert support_plan_change_request):$(alert support_urgent_ticket)" = "1:1:1" ] && ok "alerts for a cancellation, a plan change and an urgent issue" || bad "alerts: $(alert support_cancellation_request):$(alert support_plan_change_request):$(alert support_urgent_ticket)"
[ "$(q "select count(*) from public.platform_alerts where business_id = '$B1' and kind like 'support_%'")" = "3" ] && ok "and none for feedback or an ordinary issue" || bad "extra alerts"
[ "$(q "select value ->> 'timezone' from public.platform_settings where key = 'support_business_hours'")" = "America/New_York" ] && ok "business hours setting: Monday to Friday 9 to 5, New York" || bad "setting"

out=$("${P[@]}" -d $DB -f "$RB" 2>&1)
[[ "$out" == *"DRIFT"* ]] && [ -n "$(q "select to_regclass('public.support_ticket_messages')")" ] && ok "the rollback refuses while replies exist" || bad "rollback with replies: $out"
o1=$(PGOPTIONS="-c zella.drop_support_messages=yes" "${P[@]}" -d $DB -f "$RB" 2>&1); e1=$?; o2=$("${P[@]}" -d $DB -f "$RB" 2>&1); e2=$?
[ $e1 -eq 0 ] && [ $e2 -eq 0 ] && ok "with the flag, the rollback runs, and again without it once nothing is left" || bad "rollback: $o1 $o2"
left=$(q "select coalesce(to_regclass('public.support_ticket_messages')::text, '') || coalesce(to_regprocedure('public.zella_business_ticket_reply(uuid,text)')::text, '') || (select count(*) from information_schema.columns where table_name = 'support_tickets' and column_name = 'first_response_at')::text || (select count(*) from pg_trigger where tgname = 'zella_support_ticket_alert')::text || (select count(*) from public.platform_settings where key = 'support_business_hours')::text")
[ "$left" = "000" ] && ok "rollback removes the table, functions, column, trigger and setting" || bad "left: $left"
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_business_ticket_reply(p_ticket uuid, p_body text) returns jsonb language sql security definer set search_path = '' as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$MIG" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"* ]] && ok "a changed function stops the file (VERSION_MISMATCH)" || bad "drift not caught: $out"
out=$(PGOPTIONS="-c zella.drop_support_messages=yes" "${P[@]}" -d $DB -f "$RB" 2>&1)
[[ "$out" == *"DRIFT"* ]] && ok "and the rollback (DRIFT)" || bad "rollback drift: $out"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
