#!/usr/bin/env bash
# sql/zella_retry_event_safe.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Checks: before, a retry resets an event whose earlier run already sent a message; applies, and applies again; after,
# a reason is required; an event whose run sent a message, reached a provider, succeeded or is running is refused
# with the reason in words and left as it was; a clean failed event goes back to the queue, audited with the reason;
# an admin with integrations.manage may retry and one without may not; the rollback (twice) restores the original
# function and its grants exactly; applies again; a drifted version stops the file. A run of an event starts only
# while the event is claimed (a lapsed worker is refused after a retry) and holds a lock on it; reapplying over a
# changed new function stops the file; the rollback refuses (and changes nothing) when either function has changed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zretryevent; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
fp() { q "select md5(pg_get_functiondef('public.zella_retry_event(uuid)'::regprocedure)) || (select string_agg(grantee || privilege_type, ',' order by grantee) from information_schema.routine_privileges where routine_name = 'zella_retry_event') || md5(pg_get_functiondef('public.zella_start_execution(text,uuid,uuid,text,uuid)'::regprocedure))"; }
before=$(fp)
OWNER=f5000000-0000-0000-0000-000000000001; OPS=f5000000-0000-0000-0000-000000000002; SUP=f5000000-0000-0000-0000-000000000003
q "insert into public.platform_role_permissions (role, permission) values ('platform_operations','integrations.manage'),('support_admin','support.manage') on conflict do nothing;
   insert into auth.users (id, email, email_confirmed_at) values ('$OWNER','o@retry.test',now()),('$OPS','ops@retry.test',now()),('$SUP','sup@retry.test',now());
   insert into public.platform_admins (user_id, role) values ('$OWNER','zella_owner'),('$OPS','platform_operations'),('$SUP','support_admin')" > /dev/null || exit 1
BIZ=$(q "insert into public.businesses (name, industry_id) select 'Retry Test', id from public.industries limit 1 returning id" | head -1)
ev() { q "insert into public.automation_events (business_id, event_type, source, idempotency_key, status, attempts) values ('$BIZ', 'test.$1', 'system', gen_random_uuid()::text, 'failed', 5) returning id" | head -1; }
run() { q "insert into public.workflow_executions (workflow_key, event_id, business_id, status, steps, provider_refs) values ('wf', '$1', '$BIZ', '$2', '$3'::jsonb, '$4'::jsonb)" > /dev/null; }
as() { q "do \$\$ declare v text; begin perform set_config('request.jwt.claims', json_build_object('sub', '$1', 'role', 'authenticated', 'aal', 'aal2')::text, true);
  set local role authenticated; begin execute \$q\$$2\$q\$ into v; exception when others then v := 'ERR:' || sqlerrm; end; reset role; raise notice 'V=%', v; end \$\$" 2>&1 | sed -n 's/.*V=//p'; }
status() { q "select status || ':' || attempts from public.automation_events where id = '$1'"; }

SENT=$(ev sent_before); run "$SENT" failed '[{"status":"sent"},{"status":"failed"}]' '{}'
v=$(as $OWNER "select public.zella_retry_event('$SENT')")
[ "$v" = "queued" ] && [ "$(status "$SENT")" = "received:0" ] && ok "before: a retry resets an event whose earlier run already sent a message (the bug)" || bad "before: $v $(status "$SENT")"

"${P[@]}" -d $DB -f "$REPO/sql/zella_retry_event_safe.sql" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$REPO/sql/zella_retry_event_safe.sql" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$REPO/sql/zella_retry_event_safe.sql" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"

A=$(ev sent); run "$A" failed '[{"status":"sent"}]' '{}'
B=$(ev provider); run "$B" failed '[]' '{"telnyx":"msg_1"}'
C=$(ev succeeded); run "$C" succeeded '[]' '{}'
D=$(ev running); run "$D" running '[]' '{}'
E=$(ev clean); run "$E" failed '[{"status":"failed"}]' '{}'
v=$(as $OWNER "select public.zella_retry_event('$E')")
[[ "$v" == *REASON_REQUIRED* ]] && ok "a reason is required" || bad "no reason: $v"
for x in "$A:already succeeded" "$B:provider already received" "$C:already ran or is running" "$D:already ran or is running"; do
  id=${x%%:*}; want=${x#*:}
  v=$(as $OWNER "select public.zella_retry_event('$id', 'customer called')")
  [[ "$v" == *NOT_RETRYABLE* && "$v" == *"$want"* && "$(status "$id")" = "failed:5" ]] && ok "refused and left as it was: ${want}" || bad "$want: $v $(status "$id")"
done
v=$(as $SUP "select public.zella_retry_event('$E', 'customer called')")
[[ "$v" == *NOT_ALLOWED* ]] && ok "an admin without integrations.manage can't retry" || bad "support admin: $v"
v=$(as $OPS "select public.zella_retry_event('$E', 'customer called')")
[ "$v" = "queued" ] && [ "$(status "$E")" = "received:0" ] && ok "a clean failed event goes back to the queue (platform operations, integrations.manage)" || bad "clean: $v $(status "$E")"
a=$(q "select user_id || ':' || (new_data ->> 'reason') from public.audit_logs where entity_id = '$E' and action = 'event_retried'")
[ "$a" = "$OPS:customer called" ] && ok "audited with the admin and the reason" || bad "audit: $a"
v=$(as $OPS "select public.zella_retry_event('$E', 'again')")
[[ "$v" == *NOT_RETRYABLE* ]] && ok "an event already back in the queue can't be sent twice" || bad "twice: $v"

# a worker whose claim lapsed (the event was sent back above) can't start a run of it any more
v=$(q "do \$\$ begin perform public.zella_start_execution('event_router', '$BIZ', '$E'); raise notice 'V=started'; exception when others then raise notice 'V=%', sqlerrm; end \$\$" 2>&1 | sed -n 's/.*V=//p')
[ "$v" = "EVENT_NOT_CLAIMED" ] && ok "a worker whose claim lapsed can't start a run after the retry (EVENT_NOT_CLAIMED)" || bad "stale start: $v"
n=$(q "select count(*) from public.workflow_executions where event_id = '$E'"); [ "$n" = "1" ] && ok "and no run was recorded" || bad "runs: $n"
q "update public.automation_events set status = 'processing', claimed_at = now() where id = '$E'" > /dev/null
v=$(q "select public.zella_start_execution('event_router', '$BIZ', '$E') is not null"); [ "$v" = "t" ] && ok "a claimed event starts as before" || bad "claimed start: $v"
v=$(q "select public.zella_start_execution('other', '$BIZ') is not null"); [ "$v" = "t" ] && ok "a run with no event starts as before" || bad "no event start: $v"
( "${P[@]}" -d $DB -c "begin; select public.zella_start_execution('event_router', '$BIZ', '$E'); select pg_sleep(2); commit;" > /dev/null 2>&1 ) &
sleep 0.7
v=$(q "select id from public.automation_events where id = '$E' for update nowait" 2>&1); wait
[[ "$v" == *"could not obtain lock"* ]] && ok "a start in progress holds the event, so a retry waits for it and then sees its run" || bad "lock: $v"
# reapplying over a changed new function stops the file
q "create or replace function public.zella_retry_event(p_event_id uuid, p_reason text default null) returns text language sql as \$f\$ select 'x' \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_retry_event_safe.sql" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"* ]] && ok "reapplying over a changed new function stops the file" || bad "reapply drift: $out"
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_retry_event_safe_rollback.sql" 2>&1)
[[ "$out" == *"ROLLBACK_DRIFT"* ]] && [ "$(q "select count(*) from public.zella_function_archive where migration = 'zella_retry_event_safe'")" = "2" ] && ok "the rollback refuses a changed function and changes nothing" || bad "rollback drift: $out"
"${P[@]}" -d $DB -c "drop function public.zella_retry_event(uuid, text)" > /dev/null
"${P[@]}" -d $DB -f <(sed -n '/^create or replace function public.zella_retry_event/,/^grant execute/p' "$REPO/sql/zella_retry_event_safe.sql") > /dev/null || bad "restore the new function"
"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_retry_event_safe_rollback.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_retry_event_safe_rollback.sql" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "$before" ] && ok "rollback restores the original function and its grants exactly" || bad "after rollback: $(fp)"
[ "$(q "select to_regprocedure('public.zella_retry_event(uuid,text)') is null")" = "t" ] && ok "and removes the new one" || bad "new one left"
"${P[@]}" -d $DB -f "$REPO/sql/zella_retry_event_safe.sql" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_retry_event_safe_rollback.sql" > /dev/null 2>&1
q "create or replace function public.zella_retry_event(p_event_id uuid) returns text language sql as \$f\$ select 'x' \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_retry_event_safe.sql" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"* ]] && ok "a version that isn't production's stops the file" || bad "drift: $out"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
