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
# this suite drops and recreates DB: only a database named for this suite, and never the template
[[ "$DB" =~ ^z[a-z0-9_]*support[a-z0-9_]*$ ]] && [ "$DB" != "$TEMPLATE" ] || { echo "REFUSED: DB must be this suite's own database (z...support...), not '$DB'" >&2; exit 1; }
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
n=$(q "select count(*) || ':' || count(*) filter (where user_id = '$O1' and delivery_status = 'skipped' and sms_status = 'skipped') from public.staff_notifications where kind = 'support_reply' and entity_id = '$T1'")
[ "$n" = "2:2" ] && ok "the opener is told in the app, never by email or text ($n)" || bad "notifications: $n"
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
REF=f4200000-0000-0000-0000-000000000001
a1=$(as authenticated "$O1" "select (public.zella_business_ticket_reply(''$T1'', ''Sent twice'', ''$REF''))->>''message_id''")
a2=$(as authenticated "$O1" "select (public.zella_business_ticket_reply(''$T1'', ''Sent twice'', ''$REF''))->>''message_id''")
[ -n "$a1" ] && [ "$a1" = "$a2" ] && [ "$(q "select count(*) from public.support_ticket_messages where ticket_id = '$T1' and body = 'Sent twice'")" = "1" ] && ok "the same answer sent again (same ref) is saved once" || bad "retry saved twice: $a1 $a2"
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
[ "$(q "select string_agg(author_side, ',' order by created_at) from public.support_ticket_messages where ticket_id = '$T1'")" = "zella,zella,business,business,business" ] && ok "the thread is in order with who wrote each" || bad "thread"
q "update public.support_tickets set status = 'resolved', resolved_at = now() where id = '$T1'" > /dev/null
as authenticated "$O1" "select public.zella_business_ticket_reply(''$T1'', ''Still broken'')::text" > /dev/null
[ "$(q "select status || ':' || coalesce(resolved_at::text, 'none') from public.support_tickets where id = '$T1'")" = "open:none" ] && ok "an answer reopens a resolved ticket" || bad "reopen"

alert() { q "select count(*) from public.platform_alerts where kind = '$1' and business_id = '$B1'"; }
for kind in cancellation plan_change; do as authenticated "$O1" "select public.zella_business_request(''$B1'', ''$kind'', ''Request $kind'', ''details'', ''{}''::jsonb)::text" > /dev/null; done
as authenticated "$O1" "select public.zella_business_request(''$B1'', ''issue'', ''Phones down'', ''details'', ''{\"urgent\": \"true\"}''::jsonb)::text" > /dev/null
TF=$(as authenticated "$O1" "select public.zella_business_request(''$B1'', ''feedback'', ''Request feedback'', ''details'', ''{}''::jsonb)::text")
TI=$(as authenticated "$O1" "select public.zella_business_request(''$B1'', ''issue'', ''Small thing'', ''details'', ''{}''::jsonb)::text")
[[ "$TF" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] && [[ "$TI" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] && ok "feedback and an ordinary issue are created as tickets" || bad "feedback or issue not created: $TF $TI"
[ "$(alert support_cancellation_request):$(alert support_plan_change_request):$(alert support_urgent_ticket)" = "1:1:1" ] && ok "alerts for a cancellation, a plan change and an urgent issue" || bad "alerts: $(alert support_cancellation_request):$(alert support_plan_change_request):$(alert support_urgent_ticket)"
[ "$(q "select count(*) from public.platform_alerts where business_id = '$B1' and kind like 'support_%'")" = "3" ] && [ "$(q "select count(*) from public.platform_alerts where meta ->> 'ticket_id' in ('$TF', '$TI') or dedupe_key in ('$TF', '$TI')")" = "0" ] && ok "and none for feedback or an ordinary issue" || bad "extra alerts"
[ "$(q "select value ->> 'timezone' from public.platform_settings where key = 'support_business_hours'")" = "America/New_York" ] && ok "business hours setting: Monday to Friday 9 to 5, New York" || bad "setting"

out=$("${P[@]}" -d $DB -f "$RB" 2>&1)
[[ "$out" == *"DRIFT"* ]] && [ -n "$(q "select to_regclass('public.support_ticket_messages')")" ] && ok "the rollback refuses while replies exist" || bad "rollback with replies: $out"
out=$("${P[@]}" -d $DB -c "delete from public.support_ticket_messages" -f "$RB" 2>&1)
[[ "$out" == *"first response times"* ]] && ok "with first response times left, the rollback refuses too (it never deletes them)" || bad "rollback with first response times: $out"
# test data only: the rollback itself never deletes replies or response times
q "delete from public.support_ticket_messages; update public.support_tickets set first_response_at = null" > /dev/null
o1=$("${P[@]}" -d $DB -f "$RB" 2>&1); e1=$?; o2=$("${P[@]}" -d $DB -f "$RB" 2>&1); e2=$?
[ $e1 -eq 0 ] && [ $e2 -eq 0 ] && ok "once there are no replies, the rollback runs, and again once nothing is left" || bad "rollback: $o1 $o2"
left=$(q "select coalesce(to_regclass('public.support_ticket_messages')::text, '') || coalesce(to_regprocedure('public.zella_business_ticket_reply(uuid,text,uuid)')::text, '') || (select count(*) from information_schema.columns where table_name = 'support_tickets' and column_name = 'first_response_at')::text || (select count(*) from pg_trigger where tgname = 'zella_support_ticket_alert')::text")
[ "$left" = "00" ] && ok "rollback removes the table, functions, column and trigger" || bad "left: $left"
[ "$(q "select count(*) from public.platform_settings where key in ('support_business_hours', 'support_business_hours_origin')")" = "0" ] && ok "and the business hours setting this file added, still unchanged" || bad "setting left"
# a setting that was there before the file stays after its rollback
q "insert into public.platform_settings (key, value) values ('support_business_hours', '{\"days\": [1, 2, 3, 4, 5], \"start\": \"09:00\", \"end\": \"17:00\", \"timezone\": \"America/New_York\", \"first_response_hours\": 4}'::jsonb)" > /dev/null
oa=$("${P[@]}" -d $DB -f "$MIG" 2>&1); ea=$?; ob=$("${P[@]}" -d $DB -f "$RB" 2>&1); eb=$?
[ $ea -eq 0 ] && [ $eb -eq 0 ] || bad "apply or rollback failed with a setting already there: $oa $ob"
[ $ea -eq 0 ] && [ $eb -eq 0 ] && [ "$(q "select count(*) from public.platform_settings where key = 'support_business_hours'")" = "1" ] && [ "$(q "select count(*) from public.platform_settings where key = 'support_business_hours_origin'")" = "0" ] && ok "a business hours setting that was there before is kept by the rollback" || bad "pre-existing setting removed"
# a column that was there before the file stays after its rollback
q "alter table public.support_tickets add column first_response_at timestamptz" > /dev/null
oa=$("${P[@]}" -d $DB -f "$MIG" 2>&1); ea=$?; ob=$("${P[@]}" -d $DB -f "$RB" 2>&1); eb=$?
[ $ea -eq 0 ] && [ $eb -eq 0 ] || bad "apply or rollback failed with a column already there: $oa $ob"
[ $ea -eq 0 ] && [ $eb -eq 0 ] && [ "$(q "select count(*) from information_schema.columns where table_name = 'support_tickets' and column_name = 'first_response_at'")" = "1" ] && ok "a first_response_at column that was there before is kept by the rollback" || bad "pre-existing column dropped"
q "alter table public.support_tickets drop column first_response_at; delete from public.platform_settings where key = 'support_business_hours'" > /dev/null
# marked as the file's own, so it gets past the mark check and is stopped by the shape check
q "create table public.support_ticket_messages (id uuid primary key, ticket_id uuid, author_side text, created_at timestamptz);
   comment on table public.support_ticket_messages is 'zella_support_replies.sql'" > /dev/null
out=$("${P[@]}" -d $DB -f "$MIG" 2>&1)
[[ "$out" == *"a different support_ticket_messages table"* ]] && [ -z "$(q "select to_regprocedure('public.zella_business_ticket_reply(uuid,text,uuid)')")" ] && ok "a messages table of another shape stops the file before anything is installed" || bad "other table: $out"
q "drop table public.support_ticket_messages" > /dev/null
# the same columns and types, but not created by the file (no mark): the file stops, and the rollback never drops it
q "create table public.support_ticket_messages (id uuid primary key, ticket_id uuid, business_id uuid, author_id uuid, author_side text, body text, client_ref uuid, created_at timestamptz)" > /dev/null
out=$("${P[@]}" -d $DB -f "$MIG" 2>&1)
[[ "$out" == *"did not create"* ]] && ok "a look alike messages table the file didn't create stops the file" || bad "look alike: $out"
out=$("${P[@]}" -d $DB -f "$RB" 2>&1)
[[ "$out" == *"was not created by"* ]] && [ -n "$(q "select to_regclass('public.support_ticket_messages')")" ] && ok "and the rollback refuses to drop it" || bad "rollback dropped a look alike: $out"
q "drop table public.support_ticket_messages" > /dev/null
# a first_response_at of another type, or an origin row the file didn't write, stops it before anything is installed
q "alter table public.support_tickets add column first_response_at text" > /dev/null
out=$("${P[@]}" -d $DB -f "$MIG" 2>&1)
[[ "$out" == *"first_response_at already exists with another type"* ]] && [ -z "$(q "select to_regprocedure('public.zella_admin_ticket_reply(uuid,uuid,text)')")" ] && ok "a first_response_at of another type stops the file" || bad "text column: $out"
q "alter table public.support_tickets drop column first_response_at; insert into public.platform_settings (key, value) values ('support_business_hours_origin', '\"someone else\"'::jsonb)" > /dev/null
out=$("${P[@]}" -d $DB -f "$MIG" 2>&1)
[[ "$out" == *"support_business_hours_origin setting this file did not write"* ]] && [ "$(q "select count(*) from public.platform_settings where key = 'support_business_hours'")" = "0" ] && ok "an origin row the file didn't write stops it, before the default hours are added" || bad "foreign origin: $out"
out=$("${P[@]}" -d $DB -f "$RB" 2>&1)
[ "$(q "select value #>> '{}' from public.platform_settings where key = 'support_business_hours_origin'")" = "someone else" ] && ok "and the rollback leaves that row alone" || bad "foreign origin removed: $out"
q "delete from public.platform_settings where key = 'support_business_hours_origin'" > /dev/null
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
# an alert trigger changed after the file (here: given a condition) stops the file and its rollback, and stays as it was
q "drop trigger zella_support_ticket_alert on public.support_tickets;
   create trigger zella_support_ticket_alert after insert on public.support_tickets for each row when (new.priority = 'urgent') execute function public.zella_support_ticket_alert_trg()" > /dev/null
out=$("${P[@]}" -d $DB -f "$MIG" 2>&1)
[[ "$out" == *"zella_support_ticket_alert trigger already exists"* ]] && ok "a changed alert trigger stops the file (VERSION_MISMATCH)" || bad "trigger drift not caught by the file: $out"
out=$("${P[@]}" -d $DB -f "$RB" 2>&1)
[[ "$out" == *"zella_support_ticket_alert trigger changed"* ]] && [ "$(q "select count(*) from pg_trigger where tgname = 'zella_support_ticket_alert' and tgqual is not null")" = "1" ] && [ -n "$(q "select to_regclass('public.support_ticket_messages')")" ] && ok "and its rollback (DRIFT), changing nothing" || bad "trigger drift not caught by the rollback: $out"
q "drop trigger zella_support_ticket_alert on public.support_tickets;
   create trigger zella_support_ticket_alert after insert on public.support_tickets for each row execute function public.zella_support_ticket_alert_trg()" > /dev/null
q "create or replace function public.zella_business_ticket_reply(p_ticket uuid, p_body text, p_ref uuid default null) returns jsonb language sql security definer set search_path = '' as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$MIG" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"* ]] && ok "a changed function stops the file (VERSION_MISMATCH)" || bad "drift not caught: $out"
out=$("${P[@]}" -d $DB -f "$RB" 2>&1)
[[ "$out" == *"DRIFT"* ]] && ok "and the rollback (DRIFT)" || bad "rollback drift: $out"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
