#!/usr/bin/env bash
# sql/zella_admin_sessions.sql on an ISOLATED copy of the production schema (never production). Test people only.
# Checks: before, nothing can end another person's sessions (the gap); applies, and applies again; ending an admin's
# sessions removes all of theirs and nobody else's; only the server key may call it (signed in people and anonymous
# are refused); "sign out other devices" keeps the calling session, ends the rest, touches nobody else, writes
# session.revoked_others, and refuses a call without a session or without a person; the rollback (run twice) drops
# both; reapply works; a changed function stops the file (VERSION_MISMATCH) and the rollback (DRIFT).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zla_sessions}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
# this suite drops and recreates DB: only a database named for this suite, and never the template
[[ "$DB" =~ ^z[a-z0-9_]*sessions$ ]] && [ "$DB" != "$TEMPLATE" ] || { echo "REFUSED: DB must be this suite's own database (z..._sessions), not '$DB'" >&2; exit 1; }
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
RUN=$(mktemp -d) || exit 1; trap 'rm -rf "$RUN"' EXIT   # this run's own worker output
q() { "${P[@]}" -d $DB -c "$1"; }
MIG="$REPO/sql/zella_admin_sessions.sql"; RB="$REPO/sql/rollback/zella_admin_sessions_rollback.sql"
A=f3000000-0000-0000-0000-000000000001; B=f3000000-0000-0000-0000-000000000002
S1=f3100000-0000-0000-0000-000000000001; S2=f3100000-0000-0000-0000-000000000002; S3=f3100000-0000-0000-0000-000000000003; S4=f3100000-0000-0000-0000-000000000004
# as(role, sub, session_id, sql): runs sql as that role with those claims; prints R=<result or error>
as() {
  local claims; claims=$(printf '{"role":"%s"%s%s}' "$1" "${2:+,\"sub\":\"$2\"}" "${3:+,\"session_id\":\"$3\"}")
  q "do \$\$ declare r text; begin perform set_config('request.jwt.claims', '$claims', true); execute 'set local role $1';
     begin execute '$4' into r; raise notice 'R=%', r; exception when others then raise notice 'R=%', sqlerrm; end; reset role; end \$\$" 2>&1 | sed -n 's/.*R=//p'
}
sessions() { q "insert into auth.sessions (id, user_id, aal) values ('$S1', '$A', 'aal2'), ('$S2', '$A', 'aal1'), ('$S3', '$A', 'aal2'), ('$S4', '$B', 'aal1') on conflict (id) do nothing" > /dev/null; }
count() { q "select count(*) from auth.sessions where user_id = '$1'"; }

q "insert into auth.users (id, email, email_confirmed_at) values ('$A', 'sess-admin@sessions.test', now()), ('$B', 'sess-other@sessions.test', now())" > /dev/null || exit 1
q "insert into public.platform_admins (user_id, role, is_active) values ('$A', 'support_admin', true)" > /dev/null || exit 1
sessions

v=$(q "select to_regprocedure('public.zella_end_user_sessions(uuid)')") && [ -z "$v" ] && ok "before: there is no way to end another person's sessions (the gap)" || bad "before: the function already exists"

"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$MIG" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"

r=$(as authenticated "$A" "$S1" "select public.zella_end_user_sessions(''$B'')::text")
[[ "$r" == *"permission denied"* ]] && ok "a signed in person (even an admin) can't end someone's sessions" || bad "authenticated: $r"
r=$(as anon "" "" "select public.zella_end_user_sessions(''$A'')::text")
[[ "$r" == *"permission denied"* ]] && ok "anonymous can't either" || bad "anon: $r"
g=$(q "select string_agg(grantee, ',' order by grantee) from information_schema.routine_privileges where routine_schema = 'public' and routine_name = 'zella_end_user_sessions'")
[ "$g" = "postgres,service_role" ] && ok "only the server key holds it ($g)" || bad "grants: $g"

r=$(as service_role "" "" "select public.zella_end_user_sessions(''$A'')::text")
[ "$r" = "3" ] && ok "the server ends all 3 of the admin's sessions" || bad "service role returned $r"
[ "$(count $A)" = "0" ] && [ "$(count $B)" = "1" ] && ok "none of theirs is left, and another person's session is kept" || bad "left: A=$(count $A) B=$(count $B)"
r=$(as service_role "" "" "select public.zella_end_user_sessions(''$A'')::text")
[ "$r" = "0" ] && ok "a second call finds nothing to end" || bad "second call: $r"
r=$(as service_role "" "" "select public.zella_end_user_sessions(null)::text")
[[ "$r" == *"BAD_INPUT"* ]] && ok "no person given: refused" || bad "null: $r"

sessions
r=$(as authenticated "$A" "$S1" "select public.zella_revoke_my_other_sessions()::text")
[ "$r" = "2" ] && ok "sign out other devices ends the other 2" || bad "revoke others: $r"
[ "$(q "select string_agg(id::text, ',') from auth.sessions where user_id = '$A'")" = "$S1" ] && ok "and keeps the session that asked" || bad "kept: $(q "select string_agg(id::text, ',') from auth.sessions where user_id = '$A'")"
[ "$(count $B)" = "1" ] && ok "another person's session is untouched" || bad "B: $(count $B)"
a=$(q "select action || ':' || (new_data ->> 'ended') || ':' || (new_data ->> 'kept') from public.audit_logs where user_id = '$A' and action = 'session.revoked_others'")
[ "$a" = "session.revoked_others:2:$S1" ] && ok "audited as session.revoked_others with the count" || bad "audit: $a"
r=$(as authenticated "$A" "" "select public.zella_revoke_my_other_sessions()::text")
[[ "$r" == *"NO_SESSION"* ]] && ok "a token without a session id is refused (NO_SESSION), so it can't end every session" || bad "no session: $r"
sessions
r=$(as authenticated "$A" "f3100000-0000-0000-0000-0000000000ff" "select public.zella_revoke_my_other_sessions()::text")
[[ "$r" == *"NO_SESSION"* ]] && [ "$(count $A)" = "3" ] && ok "a session id that isn't one of theirs is refused (NO_SESSION) and nothing is ended" || bad "unknown session: $r, left $(count $A)"
r=$(as anon "" "" "select public.zella_revoke_my_other_sessions()::text")
[[ "$r" == *"permission denied"* ]] && ok "anonymous is refused" || bad "anon others: $r"

# zella_remove_mfa_factor: server only; never the last verified authenticator, never someone else's; one at a time
FA=f3200000-0000-0000-0000-000000000001; FB=f3200000-0000-0000-0000-000000000002; FC=f3200000-0000-0000-0000-000000000003
q "insert into auth.mfa_factors (id, user_id, factor_type, status, friendly_name, created_at, updated_at) values ('$FA', '$A', 'totp', 'verified', 'one', now(), now()), ('$FB', '$A', 'totp', 'verified', 'two', now(), now()), ('$FC', '$B', 'totp', 'verified', 'theirs', now(), now())" > /dev/null
r=$(as authenticated "$A" "$S1" "select public.zella_remove_mfa_factor(''$A'', ''$FA'')::text")
[[ "$r" == *"permission denied"* ]] && ok "a signed in person can't call the factor removal directly" || bad "authenticated remove: $r"
r=$(as service_role "" "" "select public.zella_remove_mfa_factor(''$A'', ''$FC'')::text")
[[ "$r" == *"NOT_FOUND"* ]] && ok "someone else's authenticator is NOT_FOUND" || bad "other's: $r"
# two removals at the same moment: the first holds the person's row; the second waits, then finds only one left
( "${P[@]}" -d $DB -c "begin; set local role service_role; select public.zella_remove_mfa_factor('$A', '$FA'); select pg_sleep(2); commit;" > /dev/null 2>&1 ) &
sleep 0.7
second=$( "${P[@]}" -d $DB -c "set role service_role; select public.zella_remove_mfa_factor('$A', '$FB')" 2>&1 )
wait
left=$(q "select count(*) from auth.mfa_factors where user_id = '$A' and status = 'verified'")
[[ "$second" == *"LAST_FACTOR"* ]] && [ "$left" = "1" ] && ok "two removals at once: one goes through, the other waits and is refused (LAST_FACTOR), one authenticator stays" || bad "concurrent removal: $second, left $left"

# the database keeps an active Zella Voice owner, also when two owners remove each other at the same moment
O1=f3300000-0000-0000-0000-000000000001; O2=f3300000-0000-0000-0000-000000000002
# the test owners first, so retiring the template's owners never removes the last active one
q "insert into auth.users (id, email, email_confirmed_at) values ('$O1', 'own1@sessions.test', now()), ('$O2', 'own2@sessions.test', now());
   insert into public.platform_admins (user_id, role, is_active) values ('$O1', 'zella_owner', true), ('$O2', 'zella_owner', true);
   update public.platform_admins set is_active = false where role = 'zella_owner' and user_id not in ('$O1', '$O2')" > /dev/null || { bad "owner setup failed"; exit 1; }
[ "$(q "select string_agg(user_id::text, ',' order by user_id) from public.platform_admins where role = 'zella_owner' and is_active")" = "$O1,$O2" ] || { bad "owner setup: the test owners aren't the only active ones"; exit 1; }
( "${P[@]}" -d $DB -c "begin; update public.platform_admins set role = 'super_admin' where user_id = '$O1'; select pg_sleep(2); commit;" > /dev/null 2>&1 ) &
sleep 0.7
second=$( "${P[@]}" -d $DB -c "update public.platform_admins set is_active = false where user_id = '$O2'" 2>&1 )
wait
owners=$(q "select count(*) from public.platform_admins where role = 'zella_owner' and is_active")
[[ "$second" == *"LAST_OWNER"* ]] && [ "$owners" = "1" ] && ok "two owners removed at once: the second waits and is refused (LAST_OWNER), one active owner stays" || bad "concurrent owner removal: $second, owners $owners"
r=$( "${P[@]}" -d $DB -c "delete from public.platform_admins where user_id = '$O2'" 2>&1 )
[[ "$r" == *"LAST_OWNER"* ]] && ok "deleting the last active owner is refused too" || bad "delete last owner: $r"
q "update public.platform_admins set role = 'zella_owner' where user_id = '$O1'" > /dev/null
r=$( "${P[@]}" -d $DB -c "update public.platform_admins set is_active = false where user_id = '$O2'" 2>&1 ) && ok "with another active owner, an owner can be removed" || bad "removal with two owners: $r"
# both changes lock their own row before the owner check runs (a test only trigger holds each there for a second):
# the turn taken before any row is locked makes one wait, so one is refused (LAST_OWNER) and neither deadlocks
q "update public.platform_admins set is_active = true, role = 'zella_owner' where user_id in ('$O1', '$O2');
   create function public.zq_slow_trg() returns trigger language plpgsql as \$f\$ begin perform pg_sleep(1); return new; end \$f\$;
   create trigger aaa_zq_slow before update on public.platform_admins for each row execute function public.zq_slow_trg()" > /dev/null
( "${P[@]}" -d $DB -c "update public.platform_admins set is_active = false where user_id = '$O1'" > "$RUN/o1.out" 2>&1 ) &
( "${P[@]}" -d $DB -c "update public.platform_admins set is_active = false where user_id = '$O2'" > "$RUN/o2.out" 2>&1 ) &
wait
both="$(cat "$RUN/o1.out" "$RUN/o2.out")"
q "drop trigger aaa_zq_slow on public.platform_admins; drop function public.zq_slow_trg()" > /dev/null
owners=$(q "select count(*) from public.platform_admins where role = 'zella_owner' and is_active")
[[ "$both" == *"LAST_OWNER"* ]] && [[ "$both" != *"deadlock"* ]] && [ "$owners" = "1" ] && ok "two owners removing each other with both rows already locked: one is refused (LAST_OWNER), no deadlock, one owner stays" || bad "simultaneous owner removal: $both, owners $owners"
# a trigger changed after the file (here: given a condition) stops the file and its rollback, and stays as it was
q "drop trigger zella_keep_an_owner on public.platform_admins;
   create trigger zella_keep_an_owner before update or delete on public.platform_admins for each row when (old.role = 'zella_owner') execute function public.zella_keep_an_owner_trg()" > /dev/null
out=$("${P[@]}" -d $DB -f "$MIG" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"* ]] && ok "a changed owner trigger stops the file (VERSION_MISMATCH)" || bad "trigger drift not caught by the file: $out"
out=$("${P[@]}" -d $DB -f "$RB" 2>&1)
[[ "$out" == *"DRIFT"* ]] && [ "$(q "select count(*) from pg_trigger where tgname = 'zella_keep_an_owner' and tgqual is not null")" = "1" ] && ok "and its rollback (DRIFT), leaving the trigger as it was" || bad "trigger drift not caught by the rollback: $out"
q "drop trigger zella_keep_an_owner on public.platform_admins;
   create trigger zella_keep_an_owner before update or delete on public.platform_admins for each row execute function public.zella_keep_an_owner_trg()" > /dev/null

# an active admin's authenticator is on record the moment it is verified (once), a business member's never
M1=f3400000-0000-0000-0000-000000000001; FM=f3400000-0000-0000-0000-0000000000f1; FN=f3400000-0000-0000-0000-0000000000f2
q "insert into auth.users (id, email, email_confirmed_at) values ('$M1', 'mfa-admin@sessions.test', now());
   insert into public.platform_admins (user_id, role, is_active) values ('$M1', 'support_admin', true);
   insert into auth.mfa_factors (id, user_id, factor_type, status, friendly_name, created_at, updated_at) values ('$FM', '$M1', 'totp', 'unverified', 'New phone', now(), now()), ('$FN', '$B', 'totp', 'unverified', 'Member phone', now(), now())" > /dev/null || bad "mfa fixture"
mfa_added() { q "select count(*) from public.audit_logs where action = 'admin.mfa_added' and entity_id = '$1'"; }
[ "$(mfa_added $FM)" = "0" ] && ok "setting an authenticator up writes nothing until it is verified" || bad "unverified recorded"
q "update auth.mfa_factors set status = 'verified' where id in ('$FM', '$FN')" > /dev/null
[ "$(mfa_added $FM)" = "1" ] && [ "$(q "select new_data ->> 'friendly_name' from public.audit_logs where action = 'admin.mfa_added' and entity_id = '$FM'")" = "New phone" ] && ok "an admin's verified authenticator is recorded (admin.mfa_added) in the same transaction" || bad "admin verify not recorded: $(mfa_added $FM)"
[ "$(mfa_added $FN)" = "0" ] && ok "a business member's isn't (not an admin)" || bad "member recorded"
q "update auth.mfa_factors set status = 'verified', friendly_name = 'Renamed' where id = '$FM'" > /dev/null
[ "$(mfa_added $FM)" = "1" ] && ok "and only once: a later change to it writes nothing more" || bad "recorded twice: $(mfa_added $FM)"
o1=$("${P[@]}" -d $DB -f "$RB" 2>&1) && o2=$("${P[@]}" -d $DB -f "$RB" 2>&1) && ok "rollback runs twice" || bad "rollback: $o1 $o2"
left=$(q "select (select count(*) from pg_trigger where tgname in ('zella_keep_an_owner', 'zella_keep_an_owner_turn', 'zella_admin_mfa_added'))::text || ':' ||
  (to_regprocedure('public.zella_keep_an_owner_trg()') is null and to_regprocedure('public.zella_keep_an_owner_turn_trg()') is null and to_regprocedure('public.zella_admin_mfa_added_trg()') is null)::text") \
  && [ "$left" = "0:true" ] && ok "rollback drops the three triggers and their functions" || bad "triggers left: $left"
v=$(q "select coalesce(to_regprocedure('public.zella_end_user_sessions(uuid)')::text, '') || coalesce(to_regprocedure('public.zella_revoke_my_other_sessions()')::text, '') || coalesce(to_regprocedure('public.zella_remove_mfa_factor(uuid,uuid)')::text, '')") && [ -z "$v" ] && ok "rollback drops all three functions" || bad "functions left"
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_end_user_sessions(p_user_id uuid) returns integer language sql security definer set search_path = '' as \$f\$ select 0 \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$MIG" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"* ]] && ok "a changed function stops the file (VERSION_MISMATCH)" || bad "drift not caught: $out"
defs() { q "select coalesce(md5(pg_get_functiondef('public.zella_end_user_sessions(uuid)'::regprocedure)), '-') || ':' || coalesce(md5(pg_get_functiondef('public.zella_revoke_my_other_sessions()'::regprocedure)), '-')"; }
before=$(defs)
out=$("${P[@]}" -d $DB -f "$RB" 2>&1)
after=$(defs)
[[ "$out" == *"DRIFT"* ]] && [ -n "$before" ] && [ "$before" = "$after" ] && ok "and the rollback refuses too (DRIFT), leaving both functions exactly as they were" || bad "rollback drift: $out ($before / $after)"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
