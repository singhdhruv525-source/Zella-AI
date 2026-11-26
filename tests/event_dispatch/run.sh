#!/usr/bin/env bash
# sql/zella_event_dispatch.sql on an ISOLATED copy of the production schema (never production), with the local pg_net
# stub (net.http_post only records the request in net.http_requests; nothing is sent). Test data only.
# The copy's dispatcher is brought to production's version first (md5 48ebbf41..., sql/zella_dispatch_response.sql,
# read only from production on 26 Nov 2026) and the test stops if it isn't.
# Checks: before, saving a row wakes nothing (the gap); applies, and applies again; the triggers are created switched
# off and nothing else changes (no cron job, setting, secret or row); switched off, a save calls nothing; once switched
# on, a second apply leaves them on; a save into each of the eight tables still succeeds and kicks the dispatcher; a
# follow up due later doesn't kick; the 2 second debounce (across transactions, and one kick per transaction); with
# n8n_dispatch_enabled false, with no secret or with no base address nothing is called; a dispatch error, a held kick
# row and a held dispatcher lock never block or fail the save; a save that rolls back calls nothing; a role without
# EXECUTE on the function still fires it, and anon and authenticated can't call it; a mismatched dispatcher, a missing
# table, a foreign zella_kick_dispatch function or trigger are refused with VERSION_MISMATCH and change nothing; the
# rollback (twice, through sql/rollback/run.sh) restores the previous state exactly; it refuses a changed function;
# the file applies again after it; section 5's own text never kicks for a table without due_at (why it is nested).
#   tests/event_dispatch/run.sh      (env ZPG_HOST ZPG_PORT DB TEMPLATE; TEMPLATE defaults to zprod3, else zbase)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zld_eventdispatch}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "${DB}_x" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
MIG="$REPO/sql/zella_event_dispatch.sql"; RB="$REPO/sql/rollback/zella_event_dispatch_rollback.sql"
PROD_MD5=48ebbf41429852c7f5a04a35bd09ff4f; KICK_MD5=a1ac376f047ba05dee027c34d05f6aa1
TABLES=(automation_events followup_tasks staff_notifications appointment_reminders meta_events meta_outbox website_pages website_sources)
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }

# the template: zprod3 (the isolated copy of production) when there is one, else the schema baseline (sql/baseline)
TEMPLATE=${TEMPLATE:-zprod3}
if [ "$("${P[@]}" -d postgres -c "select count(*) from pg_database where datname = '$TEMPLATE'")" != 1 ]; then
  TEMPLATE=zbase
  [ "$("${P[@]}" -d postgres -c "select count(*) from pg_database where datname = 'zbase'")" = 1 ] \
    || "$REPO/sql/baseline/restore.sh" zbase > /dev/null 2>&1 || { echo "could not restore sql/baseline into zbase"; exit 1; }
fi
zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$TEMPLATE" || exit 1
mkdb() { "${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $1" -c "create database $1 template $TEMPLATE" > /dev/null || exit 1
  # production's dispatcher: sql/zella_dispatch_response.sql (its columns and its zella_dispatch_n8n)
  local db=$1 h; h=$("${P[@]}" -d "$db" -c "select md5(pg_get_functiondef('public.zella_dispatch_n8n()'::regprocedure))")
  if [ "$h" = 4333da07a5c57d91aa8f018e75368345 ]; then "${P[@]}" -d "$db" -f "$REPO/sql/zella_dispatch_response.sql" > /dev/null 2>&1
  elif [ "$h" != "$PROD_MD5" ]; then
    { echo "alter table public.n8n_dispatch_state add column if not exists last_request_id bigint, add column if not exists response_request_id bigint,
            add column if not exists last_status_code integer, add column if not exists last_response_at timestamptz,
            add column if not exists last_error text, add column if not exists pending_request_ids bigint[] not null default '{}';"
      awk '/CREATE OR REPLACE FUNCTION public.zella_dispatch_n8n\(\)/{f=1} f{print} f&&/^end \$function\$/{print ";"; exit}' "$REPO/sql/zella_dispatch_response.sql"
    } | "${P[@]}" -d "$db" > /dev/null
  fi
  [ "$("${P[@]}" -d "$db" -c "select md5(pg_get_functiondef('public.zella_dispatch_n8n()'::regprocedure))")" = "$PROD_MD5" ] \
    || { echo "FAIL the copy's dispatcher is not production's version"; exit 1; }
}
mkdb "$DB"
q() { "${P[@]}" -d "$DB" -c "set client_min_messages = warning" -c "$1"; }
apply() { "${P[@]}" -d "${2:-$DB}" -c "set client_min_messages = warning" -f "$1" 2>&1; }

# test data only: one business, a customer, an appointment, a website source; a fake secret and address
BIZ=e3000000-0000-0000-0000-000000000001; APPT=e3000000-0000-0000-0000-000000000002; SRC=e3000000-0000-0000-0000-000000000003
q "insert into public.businesses (id, name) values ('$BIZ', 'Event dispatch test business') on conflict do nothing;
   insert into public.appointments (id, business_id, title, start_time, end_time) values ('$APPT', '$BIZ', 'Test visit', now() + interval '1 day', now() + interval '1 day 1 hour');
   insert into public.website_sources (id, business_id, root_url, host) values ('$SRC', '$BIZ', 'https://site.example.test', 'site.example.test');
   insert into public.platform_settings (key, value) values ('n8n_base_url', '\"https://n8n.example.test\"'), ('n8n_dispatch_enabled', 'true')
     on conflict (key) do update set value = excluded.value;
   delete from vault.secrets where name = 'zella_n8n_secret'; insert into vault.secrets (name, secret) values ('zella_n8n_secret', 'test-secret-not-real');
   delete from public.n8n_dispatch_state; delete from net.http_requests;" > /dev/null || exit 1
n=0; ins() { # one row into a table; prints nothing, fails loudly
  n=$((n + 1)); local k="evd-$n-$RANDOM"
  case $1 in
    automation_events) q "insert into public.automation_events (business_id, event_type, source, idempotency_key) values ('$BIZ', 'test.event', 'system', 'event-$k')" ;;
    followup_tasks) q "insert into public.followup_tasks (business_id, kind, channel, due_at) values ('$BIZ', 'lead_follow_up', 'sms', ${2:-now()})" ;;
    staff_notifications) q "insert into public.staff_notifications (business_id, kind, title) values ('$BIZ', 'test', 'Test notice $k')" ;;
    appointment_reminders) q "insert into public.appointment_reminders (business_id, appointment_id, kind, due_at) values ('$BIZ', '$APPT', 'reminder', now() + interval '1 hour')" ;;
    meta_events) q "insert into public.meta_events (business_id, event_key, kind) values ('$BIZ', 'meta-$k', 'message')" ;;
    meta_outbox) q "insert into public.meta_outbox (business_id, page_id, channel, recipient, text_body) values ('$BIZ', 'page-test', 'messenger', 'recipient-test', 'Test')" ;;
    website_pages) q "insert into public.website_pages (business_id, source_id, url) values ('$BIZ', '$SRC', 'https://site.example.test/$k')" ;;
    website_sources) q "insert into public.website_sources (business_id, root_url, host) values ('$BIZ', 'https://s$n.example.test', 's$n.example.test')" ;;
  esac > /dev/null
}
reqs() { q "select count(*) from net.http_requests"; }
fresh() { # forget every earlier kick and hand over, so the next save is a first one
  q "delete from net.http_requests; update public.n8n_dispatch_state set last_triggered_at = now() - interval '1 hour', last_count = 0, consecutive_same = 0" > /dev/null; }
kick_at() { q "select coalesce(last_triggered_at::text, '-') from public.n8n_dispatch_state where workflow = '_kick'"; }
triggers() { q "select coalesce(string_agg(tgrelid::regclass::text || ':' || tgenabled::text, ',' order by tgrelid::regclass::text), '') from pg_trigger where tgname = 'zella_kick_dispatch'"; }
switch_on() { for t in "${TABLES[@]}"; do q "alter table public.$t enable trigger zella_kick_dispatch" > /dev/null; done; }
state() { # everything the migration could touch: functions, triggers, grants, dispatch state, settings, secrets, jobs
  q "select md5(concat_ws('|',
     (select string_agg(p.oid::regprocedure::text || md5(pg_get_functiondef(p.oid)) || coalesce(array_to_string(p.proacl, ','), ''), ',' order by 1)
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'),
     (select string_agg(tgrelid::regclass::text || tgname || tgenabled::text || pg_get_triggerdef(oid), ',' order by 1) from pg_trigger where not tgisinternal),
     (select string_agg(column_name || data_type || coalesce(column_default, ''), ',' order by column_name) from information_schema.columns where table_name = 'n8n_dispatch_state'),
     (select string_agg(to_jsonb(s)::text, ',' order by workflow) from public.n8n_dispatch_state s),
     (select string_agg(key || value::text, ',' order by key) from public.platform_settings),
     (select string_agg(name || secret, ',' order by name) from vault.secrets),
     (select string_agg(jobname || schedule || command || active, ',' order by jobname) from cron.job)))"; }

# before: the gap
v=$(q "select to_regprocedure('public.zella_kick_dispatch()') is null and not exists (select 1 from pg_trigger where tgname = 'zella_kick_dispatch')")
ins automation_events
[ "$v" = t ] && [ "$(reqs)" = 0 ] && ok "before: no zella_kick_dispatch, and a saved event wakes nothing (the gap)" || bad "before: $v $(reqs)"
q "delete from net.http_requests" > /dev/null
before=$(state); [ -n "$before" ] || { bad "state snapshot"; exit 1; }; jobs_before=$(q "select count(*) || ':' || count(*) filter (where active) from cron.job")

# apply, twice
out=$(apply "$MIG") && ok "applies to a database whose dispatcher is production's" || { bad "apply: $out"; exit 1; }
out=$(apply "$MIG") && ok "applies again (idempotent)" || bad "second apply: $out"
[ "$(q "select md5(pg_get_functiondef('public.zella_kick_dispatch()'::regprocedure))")" = "$KICK_MD5" ] && ok "zella_kick_dispatch is the file's version ($KICK_MD5)" || bad "kick md5"
want=$(printf '%s:D,' $(printf '%s\n' "${TABLES[@]}" | sort)); want=${want%,}
[ "$(triggers)" = "$want" ] && ok "8 triggers created, all switched off" || bad "triggers: $(triggers)"
v=$(q "select count(*) from pg_trigger where tgname = 'zella_kick_dispatch' and tgtype = 5 and tgfoid = 'public.zella_kick_dispatch()'::regprocedure")
[ "$v" = 8 ] && ok "each is AFTER INSERT FOR EACH ROW and calls zella_kick_dispatch()" || bad "trigger shape: $v"
[ "$(q "select string_agg(r || has_function_privilege(r, 'public.zella_kick_dispatch()', 'EXECUTE')::text, ',') from unnest(array['anon', 'authenticated']) r")" = "anonfalse,authenticatedfalse" ] \
  && ok "anon and authenticated can't execute it" || bad "grants"
[ "$(q "select count(*) || ':' || count(*) filter (where active) from cron.job")" = "$jobs_before" ] && [ "$(q "select md5(pg_get_functiondef('public.zella_dispatch_n8n()'::regprocedure))")" = "$PROD_MD5" ] \
  && [ "$(q "select count(*) from public.platform_settings where key = 'n8n_dispatch_enabled' and value = 'true'")" = 1 ] \
  && ok "no cron job scheduled or switched on, the dispatcher and the settings unchanged" || bad "side effects"

# switched off (as created): a save calls nothing
fresh; ins automation_events
[ "$(reqs)" = 0 ] && [ "$(kick_at)" = "" ] && ok "triggers off: a save calls nothing" || bad "off: $(reqs) $(kick_at)"

# the owner's switch on; a second apply leaves it on
switch_on; out=$(apply "$MIG") || bad "apply with triggers on: $out"
[ "$(triggers)" = "${want//:D/:O}" ] && ok "a second apply leaves switched on triggers on" || bad "after reapply: $(triggers)"

# each table: the save succeeds and kicks the dispatcher (a due event is waiting, so event-router is called)
for t in "${TABLES[@]}"; do
  fresh; c=$(q "select count(*) from public.$t"); ins "$t"
  [ "$(q "select count(*) from public.$t")" = $((c + 1)) ] && [ "$(q "select count(*) from net.http_requests where url = 'https://n8n.example.test/webhook/zella/run/event-router'")" = 1 ] \
    && ok "$t: the row is saved and the dispatcher hands the waiting work to n8n" || bad "$t: rows $c -> $(q "select count(*) from public.$t"), requests $(reqs)"
done
v=$(q "select headers ->> 'X-Zella-Secret' = 'test-secret-not-real' and body = '{}'::jsonb from net.http_requests limit 1")
[ "$v" = t ] && ok "the call carries the secret header and an empty body (no business data)" || bad "request shape: $v"
fresh; ins followup_tasks "now() + interval '1 hour'"
[ "$(reqs)" = 0 ] && ok "a follow up due in an hour doesn't kick" || bad "future follow up: $(reqs)"
fresh; ins followup_tasks "now()"
[ "$(reqs)" -ge 1 ] && ok "a follow up due now kicks" || bad "due follow up: $(reqs)"

# the 2 second debounce
fresh; ins automation_events; first=$(kick_at)
q "delete from net.http_requests; update public.n8n_dispatch_state set last_triggered_at = now() - interval '1 hour' where workflow <> '_kick'" > /dev/null
ins staff_notifications
[ "$(reqs)" = 0 ] && [ "$(kick_at)" = "$first" ] && ok "a second save within 2 seconds doesn't kick again" || bad "debounce: $(reqs) $first $(kick_at)"
q "update public.n8n_dispatch_state set last_triggered_at = now() - interval '2.5 seconds' where workflow = '_kick'" > /dev/null
ins staff_notifications
[ "$(reqs)" -ge 1 ] && [ "$(kick_at)" != "$first" ] && ok "a save more than 2 seconds after the last kick kicks again" || bad "after 2s: $(reqs)"
fresh; q "update public.n8n_dispatch_state set last_triggered_at = null where workflow = '_kick'" > /dev/null
q "insert into public.staff_notifications (business_id, kind, title) select '$BIZ', 'test', 'Bulk ' || g from generate_series(1, 5) g" > /dev/null
v=$(q "select count(*) || ':' || count(distinct url) from net.http_requests")
[ "${v%%:*}" -ge 1 ] && [ "${v%%:*}" = "${v##*:}" ] && ok "five rows in one statement kick once (each waiting workflow called once)" || bad "bulk: $v"

# the master switch and the secret
fresh; q "update public.platform_settings set value = 'false' where key = 'n8n_dispatch_enabled'" > /dev/null; ins automation_events
[ "$(reqs)" = 0 ] && ok "n8n_dispatch_enabled false: nothing is called" || bad "switch off: $(reqs)"
q "update public.platform_settings set value = 'true' where key = 'n8n_dispatch_enabled'" > /dev/null
fresh; q "update vault.secrets set name = 'zella_n8n_secret_parked' where name = 'zella_n8n_secret'" > /dev/null; ins automation_events
[ "$(reqs)" = 0 ] && ok "no secret: nothing is called" || bad "no secret: $(reqs)"
q "update vault.secrets set name = 'zella_n8n_secret' where name = 'zella_n8n_secret_parked'" > /dev/null
fresh; q "update public.platform_settings set value = '\"\"' where key = 'n8n_base_url'" > /dev/null; ins automation_events
[ "$(reqs)" = 0 ] && ok "no base address: nothing is called" || bad "no address: $(reqs)"
q "update public.platform_settings set value = '\"https://n8n.example.test\"' where key = 'n8n_base_url'" > /dev/null

# a dispatch error never blocks the save
fresh; c=$(q "select count(*) from public.automation_events"); st=$(q "select string_agg(workflow || coalesce(last_triggered_at::text, ''), ',' order by workflow) from public.n8n_dispatch_state")
q "alter table net.http_requests rename to http_requests_parked" > /dev/null
out=$("${P[@]}" -d "$DB" -c "insert into public.automation_events (business_id, event_type, source, idempotency_key) values ('$BIZ', 'test.event', 'system', 'event-error-1')" 2>&1); code=$?
q "alter table net.http_requests_parked rename to http_requests" > /dev/null
[ $code = 0 ] && [ "$(q "select count(*) from public.automation_events")" = $((c + 1)) ] && [[ "$out" == *"WARNING:  zella_kick_dispatch: 42P01"* ]] \
  && ok "the dispatcher failing (pg_net unavailable) doesn't block the save; a warning with the SQLSTATE only" || bad "error: $code $out"
[ "$(q "select string_agg(workflow || coalesce(last_triggered_at::text, ''), ',' order by workflow) from public.n8n_dispatch_state")" = "$st" ] \
  && ok "the failed kick leaves no half written dispatch state" || bad "partial state"
fresh; q "update public.n8n_dispatch_state set last_triggered_at = null where workflow = '_kick'" > /dev/null
q "begin; insert into public.automation_events (business_id, event_type, source, idempotency_key) values ('$BIZ', 'test.event', 'system', 'event-rolled-back'); rollback;" > /dev/null
[ "$(reqs)" = 0 ] && [ "$(q "select count(*) from public.automation_events where idempotency_key = 'event-rolled-back'")" = 0 ] && ok "a save that rolls back calls nothing" || bad "rolled back: $(reqs)"

# locks: another transaction holding the kick row, or a dispatcher row, never holds up the save
fresh; q "update public.n8n_dispatch_state set last_triggered_at = null where workflow = '_kick'" > /dev/null
"${P[@]}" -d "$DB" -c "begin; select 1 from public.n8n_dispatch_state where workflow = '_kick' for update; select pg_sleep(6); commit;" > /dev/null 2>&1 &
held=$!; sleep 1; s=$(date +%s%N); ins staff_notifications; ms=$(( ($(date +%s%N) - s) / 1000000 ))
[ "$ms" -lt 1500 ] && [ "$(reqs)" = 0 ] && ok "kick row held by another transaction: the save takes ${ms} ms, skips the kick, doesn't wait" || bad "held kick row: ${ms} ms, $(reqs)"
wait $held
fresh; q "update public.n8n_dispatch_state set last_triggered_at = null where workflow = '_kick'" > /dev/null
"${P[@]}" -d "$DB" -c "begin; select 1 from public.n8n_dispatch_state where workflow = 'event-router' for update; select pg_sleep(8); commit;" > /dev/null 2>&1 &
held=$!; sleep 1; c=$(q "select count(*) from public.staff_notifications"); s=$(date +%s%N); ins staff_notifications; ms=$(( ($(date +%s%N) - s) / 1000000 ))
[ "$ms" -lt 4000 ] && [ "$(q "select count(*) from public.staff_notifications")" = $((c + 1)) ] && [ "$(reqs)" = 0 ] \
  && ok "dispatcher row held by another transaction: the kick gives up after its 2 second lock timeout and the row is saved (${ms} ms)" || bad "held dispatcher row: ${ms} ms, $(reqs)"
wait $held

# a role without EXECUTE on the function still fires it (the trigger runs as its owner)
fresh; q "update public.n8n_dispatch_state set last_triggered_at = null where workflow = '_kick'" > /dev/null
v=$(q "select has_function_privilege('service_role', 'public.zella_kick_dispatch()', 'EXECUTE')")
"${P[@]}" -d "$DB" -c "set role service_role" -c "insert into public.automation_events (business_id, event_type, source, idempotency_key) values ('$BIZ', 'test.event', 'system', 'event-service-role')" > /dev/null 2>&1
[ "$v" = f ] && [ "$(reqs)" -ge 1 ] && ok "a role without EXECUTE on zella_kick_dispatch still saves and kicks" || bad "service role: $v $(reqs)"
out=$("${P[@]}" -d "$DB" -c "set role authenticated" -c "select public.zella_kick_dispatch()" 2>&1)
[[ "$out" == *"permission denied"* ]] && ok "authenticated can't call it directly" || bad "direct call: $out"

# rollback, twice, through the repo's rollback runner: the state before the migration, exactly
rb() { "$REPO/sql/rollback/run.sh" "$RB" -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -d "${1:-$DB}" -q 2>&1; }
out=$(rb) && out2=$(rb) && ok "rollback runs twice" || bad "rollback: $out $out2"
q "delete from net.http_requests; delete from public.n8n_dispatch_state where workflow <> '_kick'" > /dev/null
after=$(state); [ -n "$after" ] && [ "$after" = "$before" ] && ok "rollback restores the previous state exactly (functions, triggers, grants, dispatch state, settings, secrets, jobs)" || bad "state after rollback differs"
fresh; ins automation_events
[ "$(reqs)" = 0 ] && ok "after the rollback a save wakes nothing again" || bad "after rollback: $(reqs)"
out=$(apply "$MIG") && ok "applies again after the rollback" || bad "reapply: $out"
q "create or replace function public.zella_kick_dispatch() returns trigger language plpgsql as \$f\$ begin return new; end \$f\$" > /dev/null
out=$(rb); [[ "$out" == *"ROLLBACK_DRIFT"* ]] && [ "$(q "select count(*) from pg_trigger where tgname = 'zella_kick_dispatch'")" = 8 ] \
  && ok "the rollback refuses a changed function and changes nothing" || bad "rollback drift: $out"
out=$(apply "$MIG"); [[ "$out" == *"VERSION_MISMATCH"* ]] && ok "a zella_kick_dispatch that isn't this file's stops the migration" || bad "foreign kick: $out"

# mismatched databases are refused and left unchanged
X=${DB}_x
mkdb "$X"; xq() { "${P[@]}" -d "$X" -c "set client_min_messages = warning" -c "$1"; }
awk '/^create or replace function public.zella_dispatch_n8n\(\)/{f=1} f{print} f&&/^end \$\$;/{exit}' "$REPO/sql/zella_dispatcher.sql" | "${P[@]}" -d "$X" > /dev/null
xb=$(xq "select md5(pg_get_functiondef('public.zella_dispatch_n8n()'::regprocedure))")
out=$(apply "$MIG" "$X")
[ "$xb" != "$PROD_MD5" ] && [[ "$out" == *"VERSION_MISMATCH"*"zella_dispatch_n8n"* ]] && [ "$(xq "select to_regprocedure('public.zella_kick_dispatch()') is null and not exists (select 1 from pg_trigger where tgname = 'zella_kick_dispatch')")" = t ] \
  && ok "a dispatcher that isn't production's (sql/zella_dispatcher.sql's own) is refused, nothing created" || bad "mismatch: $xb $out"
mkdb "$X"; xq "alter table public.meta_outbox rename to meta_outbox_parked" > /dev/null
out=$(apply "$MIG" "$X")
[[ "$out" == *"VERSION_MISMATCH: table public.meta_outbox is missing"* ]] && [ "$(xq "select count(*) from pg_trigger where tgname = 'zella_kick_dispatch'")" = 0 ] \
  && ok "a missing table is refused, nothing created" || bad "missing table: $out"
mkdb "$X"; xq "create function public.zella_other_kick() returns trigger language plpgsql as \$f\$ begin return new; end \$f\$;
  create trigger zella_kick_dispatch after insert on public.meta_events for each row execute function public.zella_other_kick()" > /dev/null
out=$(apply "$MIG" "$X")
[[ "$out" == *"VERSION_MISMATCH: trigger zella_kick_dispatch on meta_events"* ]] && [ "$(xq "select to_regprocedure('public.zella_kick_dispatch()') is null")" = t ] \
  && ok "a foreign zella_kick_dispatch trigger is refused, nothing created" || bad "foreign trigger: $out"
# why the due_at test is nested: section 5's own text (sql/zella_dispatcher.sql), installed as written, never kicks for
# a table without due_at (the error is swallowed), while a followup task does kick
mkdb "$X"
{ echo "set client_min_messages = warning;"; awk '/^-- 5. Act at once/{f=1} f{print}' "$REPO/sql/zella_dispatcher.sql"; } | "${P[@]}" -d "$X" > /dev/null
xq "insert into public.businesses (id, name) values ('$BIZ', 'Event dispatch test business');
  insert into public.platform_settings (key, value) values ('n8n_base_url', '\"https://n8n.example.test\"'), ('n8n_dispatch_enabled', 'true') on conflict (key) do update set value = excluded.value;
  insert into vault.secrets (name, secret) values ('zella_n8n_secret', 'test-secret-not-real');
  delete from net.http_requests; delete from public.n8n_dispatch_state;
  insert into public.automation_events (business_id, event_type, source, idempotency_key) values ('$BIZ', 'test.event', 'system', 'event-section-5')" > /dev/null
a=$(xq "select count(*) from net.http_requests")
xq "insert into public.followup_tasks (business_id, kind, channel, due_at) values ('$BIZ', 'lead_follow_up', 'sms', now())" > /dev/null
b=$(xq "select count(*) from net.http_requests")
[ "$a" = 0 ] && [ "$b" -ge 1 ] && ok "section 5 as written: an automation event never kicks (42703 swallowed), a follow up does; this file kicks both" || bad "section 5: $a $b"
"${P[@]}" -d postgres -c "drop database if exists $X" > /dev/null

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
