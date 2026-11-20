#!/usr/bin/env bash
# sql/zella_dispatch_response.sql on an ISOLATED copy of the production schema (never production), with the local
# pg_net stub (net.http_post records the request; a test writes net._http_response the way pg_net fills it later).
# Test data only; nothing is sent. Checks: before, the request id is thrown away and nothing stores n8n's answer (the
# gap); applies, and applies again; dispatching works exactly as before (same result, same requests, same counters,
# same skip answers); the request id is kept; on the next run 200, 401 and 404 are recorded; 401 raises one urgent
# alert for all workflows, 404 a warning for that workflow, and a later 200 resolves both; a request with no answer
# yet is shown as waiting and never waited for; pg_net's error and time out columns are read when present; the admin
# reader needs businesses.view (a business member and anonymous are refused); the rollback (twice) restores the
# function exactly and drops the columns; it refuses a changed function; applies again; another version stops the file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zld_dispatchresp}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "set client_min_messages = warning" -c "$1"; }
# production's functions: the writing cleanup, then the merged migrations not applied yet (docs/SCHEMA_STATUS.md)
for f in zella_writing_cleanup zella_cancellations_scheduled zella_admin_permissions zella_admin_mfa zella_support_notes zella_status_honest; do
  "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { bad "$f"; exit 1; }
done
OWNER=e2000000-0000-0000-0000-000000000001; MEMBER=e2000000-0000-0000-0000-000000000002
BIZ=$(q "select id from public.businesses order by id limit 1")
q "insert into auth.users (id, email, email_confirmed_at) values ('$OWNER', 'owner@dispatch.test', now()), ('$MEMBER', 'member@dispatch.test', now());
   insert into public.platform_admins (user_id, role) values ('$OWNER', 'zella_owner');
   insert into public.platform_settings (key, value) values ('n8n_base_url', '\"https://n8n.example.test\"'), ('n8n_dispatch_enabled', 'true')
     on conflict (key) do update set value = excluded.value;
   insert into vault.secrets (name, secret) values ('zella_n8n_secret', 'test-secret-not-real');
   delete from public.n8n_dispatch_state; delete from public.platform_alerts; delete from net.http_requests;
   insert into public.automation_events (business_id, event_type, source, idempotency_key) values ('$BIZ', 'test.event', 'system', 'dispatch-test-1')" > /dev/null || exit 1
# a second workflow with due work: a pending follow up text
v=$(q "select count(*) from public.followup_tasks where status = 'pending' and channel = 'sms' and due_at <= now()")
[ "$v" -gt 0 ] || q "insert into public.followup_tasks (business_id, kind, channel, due_at) values ('$BIZ', 'lead_follow_up', 'sms', now() - interval '1 minute')" > /dev/null || exit 1
as() { local role=authenticated; [ -z "$1" ] && role=anon
  "${P[@]}" -d $DB -c "set role $role" -c "select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"$role\"}', false)" -c "$2" 2>&1 | sed -n 2p; }
fp() { q "select md5(pg_get_functiondef('public.zella_dispatch_n8n()'::regprocedure)) || (select string_agg(grantee || privilege_type, ',' order by grantee) from information_schema.routine_privileges where routine_name = 'zella_dispatch_n8n')"; }
dispatch() { q "update public.n8n_dispatch_state set last_triggered_at = now() - interval '1 minute'" > /dev/null; q "select public.zella_dispatch_n8n()"; }
sent() { q "select string_agg(url || ' ' || (headers ->> 'X-Zella-Secret') || ' ' || body::text, ';' order by id) from net.http_requests"; }
counters() { q "select string_agg(workflow || ':' || last_count || ':' || consecutive_same || ':' || triggers_total, ',' order by workflow) from public.n8n_dispatch_state"; }
answer() { q "select '$1:' || coalesce(last_status_code::text, '-') || ':' || coalesce(last_error, '-') from public.n8n_dispatch_state where workflow = '$1'"; }
respond() { # pg_net writing its answer to the last request for a workflow
  q "insert into net._http_response (id, status_code, content) select last_request_id, $2, 'not stored' from public.n8n_dispatch_state where workflow = '$1'" > /dev/null; }
before=$(fp)

r1=$(dispatch); s1=$(sent); c1=$(counters)
v=$(q "select count(*) from information_schema.columns where table_name = 'n8n_dispatch_state' and column_name like 'last_status%'")
[[ "$r1" == *'"event-router": 1'* && "$v" = "0" ]] && ok "before: work is handed over but n8n's answer is never kept (the gap)" || bad "before: $r1 $v"
off_before=$(q "update public.platform_settings set value = 'false' where key = 'n8n_dispatch_enabled'; select public.zella_dispatch_n8n()")
q "update public.platform_settings set value = 'true' where key = 'n8n_dispatch_enabled'" > /dev/null

"${P[@]}" -d $DB -f "$REPO/sql/zella_dispatch_response.sql" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$REPO/sql/zella_dispatch_response.sql" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$REPO/sql/zella_dispatch_response.sql" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"

# the same state as before the first run, so the second run can be compared with it
q "delete from net.http_requests; delete from public.n8n_dispatch_state" > /dev/null
r2=$(dispatch); s2=$(sent); c2=$(counters)
[ "$r2" = "$r1" ] && [ "$s2" = "$s1" ] && [ "$c2" = "$c1" ] && ok "dispatching is unchanged: same result, same requests, same counters" || bad "changed: $r1 / $r2 | $s1 / $s2 | $c1 / $c2"
v=$(q "update public.platform_settings set value = 'false' where key = 'n8n_dispatch_enabled'; select public.zella_dispatch_n8n()")
q "update public.platform_settings set value = 'true' where key = 'n8n_dispatch_enabled'" > /dev/null
[ "$v" = "$off_before" ] && ok "switched off answers exactly as before" || bad "off: $v"
v=$(q "select count(*) from public.n8n_dispatch_state s join net.http_requests r on r.id = s.last_request_id where s.workflow in ('event-router', 'followup-texts')")
[ "$v" = "2" ] && ok "each workflow keeps its request id" || bad "request ids: $v"
v=$(as $OWNER "select x ->> 'waiting' from jsonb_array_elements(public.zella_admin_dispatch_responses()) x where x ->> 'workflow' = 'event-router'")
[ "$v" = "true" ] && ok "a request with no answer yet shows as waiting" || bad "waiting: $v"
dispatch > /dev/null
[ "$(answer event-router)" = "event-router:-:-" ] && ok "a run before pg_net answers records nothing and doesn't wait" || bad "no answer: $(answer event-router)"

respond event-router 200; respond followup-texts 404; dispatch > /dev/null
[ "$(answer event-router)" = "event-router:200:-" ] && ok "200 is recorded on the next run" || bad "200: $(answer event-router)"
[ "$(answer followup-texts)" = "followup-texts:404:-" ] && ok "404 is recorded" || bad "404: $(answer followup-texts)"
v=$(q "select severity || ':' || dedupe_key from public.platform_alerts where kind = 'n8n_dispatch_refused' and status <> 'resolved'")
[ "$v" = "warning:followup-texts" ] && ok "404 raises a warning for that workflow" || bad "404 alert: $v"
respond event-router 401; respond followup-texts 401; dispatch > /dev/null
[ "$(answer event-router)" = "event-router:401:-" ] && ok "401 is recorded" || bad "401: $(answer event-router)"
v=$(q "select severity || ':' || occurrences from public.platform_alerts where kind = 'n8n_dispatch_refused' and dedupe_key = 'n8n_secret' and status <> 'resolved'")
[ "$v" = "urgent:2" ] && ok "401 raises one urgent alert for every workflow" || bad "401 alert: $v"
n=$(q "select count(*) from public.platform_alerts where kind = 'n8n_dispatch_refused'"); dispatch > /dev/null
[ "$(q "select count(*) from public.platform_alerts where kind = 'n8n_dispatch_refused'")" = "$n" ] && [ "$(q "select occurrences from public.platform_alerts where dedupe_key = 'n8n_secret'")" = "2" ] && ok "an answer is read once, not again on every run" || bad "read twice"
respond event-router 200; dispatch > /dev/null
v=$(q "select string_agg(dedupe_key || ':' || status, ',' order by dedupe_key) from public.platform_alerts where kind = 'n8n_dispatch_refused'")
[ "$v" = "followup-texts:open,n8n_secret:open" ] && ok "one workflow's 200 doesn't resolve the shared secret alert while another's latest answer is still 401" || bad "resolve: $v"
respond followup-texts 200; dispatch > /dev/null
[ "$(q "select count(*) from public.platform_alerts where kind = 'n8n_dispatch_refused' and status <> 'resolved'")" = "0" ] && ok "once every workflow's latest answer is a success, the secret alert and the 404 alert are resolved" || bad "404 not resolved"
# pg_net's real table also has error_msg and timed_out
q "alter table net._http_response add column if not exists error_msg text, add column if not exists timed_out boolean" > /dev/null
q "insert into net._http_response (id, status_code, error_msg, timed_out) select last_request_id, null, 'Couldn''t resolve host', false from public.n8n_dispatch_state where workflow = 'event-router'" > /dev/null
dispatch > /dev/null
[ "$(answer event-router)" = "event-router:-:Couldn't resolve host" ] && ok "pg_net's error message is kept when there is no status" || bad "error: $(answer event-router)"
v=$(as $OWNER "select x ->> 'status_code' from jsonb_array_elements(public.zella_admin_dispatch_responses()) x where x ->> 'workflow' = 'followup-texts'")
[ "$v" = "200" ] && ok "an admin with businesses.view reads the answers" || bad "reader: $v"
[[ "$(as $MEMBER "select public.zella_admin_dispatch_responses()")" == *NOT_ALLOWED* ]] && ok "a business member is refused" || bad "member reads"
[[ "$(as "" "select public.zella_admin_dispatch_responses()")" == *"permission denied"* ]] && ok "anonymous is refused" || bad "anon reads"
v=$(q "select count(*) from information_schema.columns where table_name = 'n8n_dispatch_state' and column_name in ('content', 'body', 'payload')")
[ "$v" = "0" ] && ok "no answer body is stored" || bad "body stored"
# a run sends a new request before the previous one's answer exists: the older one is still read when it comes
q "delete from net._http_response; update public.platform_alerts set status = 'resolved' where kind = 'n8n_dispatch_refused'" > /dev/null
dispatch > /dev/null; old=$(q "select last_request_id from public.n8n_dispatch_state where workflow = 'event-router'")
dispatch > /dev/null; new=$(q "select last_request_id from public.n8n_dispatch_state where workflow = 'event-router'")
[ "$old" != "$new" ] && [ "$(q "select '$old' = any (pending_request_ids::text[]) and '$new' = any (pending_request_ids::text[]) from public.n8n_dispatch_state where workflow = 'event-router'")" = t ] \
  && ok "both requests wait for their answers (the older id is kept)" || bad "pending ids: $old $new"
q "insert into net._http_response (id, status_code, content) values ($old, 403, 'not stored')" > /dev/null; dispatch > /dev/null
[ "$(q "select count(*) from public.platform_alerts where kind = 'n8n_dispatch_refused' and dedupe_key = 'n8n_secret' and status <> 'resolved'")" = 1 ] \
  && [ "$(q "select not ('$old' = any (pending_request_ids::text[])) from public.n8n_dispatch_state where workflow = 'event-router'")" = t ] \
  && ok "the older request's late 403 is read and raises the secret alert" || bad "late answer"
# the newer request answers 200, then an even older one answers: it never overwrites the newer answer
q "insert into net._http_response (id, status_code, content) values ($new, 200, 'not stored')" > /dev/null; dispatch > /dev/null
[ "$(answer event-router)" = "event-router:200:-" ] && [ "$(q "select count(*) from public.platform_alerts where dedupe_key = 'n8n_secret' and status <> 'resolved'")" = 0 ] \
  && ok "a later success resolves the secret alert" || bad "later success: $(answer event-router)"
q "update public.n8n_dispatch_state set pending_request_ids = array_prepend(1::bigint, pending_request_ids) where workflow = 'event-router';
   insert into net._http_response (id, status_code, content) values (1, 401, 'not stored')" > /dev/null; dispatch > /dev/null
[ "$(answer event-router)" = "event-router:200:-" ] && [ "$(q "select count(*) from public.platform_alerts where dedupe_key = 'n8n_secret' and status <> 'resolved'")" = 0 ] \
  && [ "$(q "select not (1 = any (pending_request_ids)) from public.n8n_dispatch_state where workflow = 'event-router'")" = t ] \
  && ok "an older answer arriving late only leaves the queue: no overwrite, no alert" || bad "older answer: $(answer event-router)"
# a 200 recorded before a refusal doesn't resolve it: a success has to come after the refusal
q "update public.n8n_dispatch_state set last_status_code = 200, response_request_id = 1 where workflow = 'followup-texts'" > /dev/null
dispatch > /dev/null; r3=$(q "select last_request_id from public.n8n_dispatch_state where workflow = 'event-router'")
q "insert into net._http_response (id, status_code, content) values ($r3, 401, 'not stored')" > /dev/null; dispatch > /dev/null
r4=$(q "select last_request_id from public.n8n_dispatch_state where workflow = 'event-router'")
q "insert into net._http_response (id, status_code, content) values ($r4, 500, 'not stored')" > /dev/null; dispatch > /dev/null
[ "$(q "select count(*) from public.platform_alerts where dedupe_key = 'n8n_secret' and status <> 'resolved'")" = 1 ] \
  && ok "a 500 after a 401 doesn't resolve the secret alert, even with an earlier 200 elsewhere" || bad "resolved without a later success"

"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_dispatch_response_rollback.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_dispatch_response_rollback.sql" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "$before" ] && ok "rollback restores the function and its grants exactly" || bad "after rollback: $(fp)"
v=$(q "select count(*) from information_schema.columns where table_name = 'n8n_dispatch_state' and column_name in ('last_request_id', 'response_request_id', 'last_status_code', 'last_response_at', 'last_error')")
[ "$v" = "0" ] && [ "$(q "select to_regprocedure('public.zella_admin_dispatch_responses()') is null")" = "t" ] && ok "rollback drops the columns and the reader" || bad "leftovers: $v"
[[ "$(dispatch)" == *'"event-router"'* ]] && ok "the restored dispatcher still runs" || bad "restored run"
"${P[@]}" -d $DB -f "$REPO/sql/zella_dispatch_response.sql" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_dispatch_n8n() returns jsonb language sql as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_dispatch_response_rollback.sql" 2>&1)
[[ "$out" == *"ROLLBACK_DRIFT"* ]] && ok "the rollback refuses a changed function" || bad "rollback drift: $out"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_dispatch_response.sql" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"* ]] && ok "a version that isn't production's stops the file" || bad "drift: $out"
# the 4 Nov copy in sql/baseline (before the 15 Nov email delivery patch) is not production's version and is refused
awk '/FUNCTION public.zella_dispatch_n8n\(\)/{f=1} f{print} f&&/^end \$function\$/{exit}' "$REPO/sql/baseline/05_functions_2.sql" | "${P[@]}" -d $DB > /dev/null 2>&1
v=$(q "select md5(pg_get_functiondef('public.zella_dispatch_n8n()'::regprocedure)) <> '4333da07a5c57d91aa8f018e75368345'")
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_dispatch_response.sql" 2>&1)
[ "$v" = "t" ] && [[ "$out" == *"VERSION_MISMATCH"* ]] && ok "the sql/baseline copy (4 Nov) is not production's version and is refused" || bad "baseline: $v $out"
echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
