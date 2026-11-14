#!/usr/bin/env bash
# sql/zella_unsubscribe_limit.sql on an ISOLATED copy of the production state (never production): both functions
# match production before; applied twice; the lookup says "busy" past its limit; the save never refuses a first
# opt-out (NN-8) and writes nothing more past its limit; anonymous visitors can still use the link; the rollback
# restores production's definitions exactly; it applies again.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zunsublimit
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
LIVE=(zella_platform_roles_fix zella_booking_buffers zella_channel_review zella_escalation_rules zella_knowledge_live zella_order_lookup_v2 zella_config_migration
  zella_report_schedules zella_knowledge_learning zella_assistant_delivery zella_plan_languages
  zella_holiday_availability zella_delivery_evidence zella_arrival_windows zella_tables zella_relationships zella_scheduling zella_slots_resource_blocks zella_record_workflows
  zella_batch1_security zella_batch3_pagination zella_brand_name zella_rollback_security zella_n8n_webhook_auth zella_record_files_purge_retry zella_replace_business_hours
  zella_order_lookup_reservations zella_review_sql_fixes zella_seating_handoff)
LIVE_FILES=(); for m in "${LIVE[@]}"; do LIVE_FILES+=("$REPO/sql/$m.sql"); done
"$REPO/tests/lib/build_full.sh" "$DB" "$REPO/tests/channel/fixture.sql" "${LIVE_FILES[@]}" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
HASHES="select string_agg(proname || '=' || md5(pg_get_functiondef(oid)), ',' order by proname) from pg_proc where pronamespace = 'public'::regnamespace and proname in ('zella_unsubscribe_email', 'zella_unsubscribe_lookup')"
LIVE_HASHES="zella_unsubscribe_email=2b0cbe3cdba9216fa630cf447a0153a8,zella_unsubscribe_lookup=6b71e36b82cc134696fdc3d57bd71fb2"
NEW_HASHES="zella_unsubscribe_email=90e424307e1e33acfe9b83c478531325,zella_unsubscribe_lookup=24d10fcf5dbfad0ee6f87c22acdfef05"
[ "$(q "$HASHES")" = "$LIVE_HASHES" ] && ok "both functions match production's versions (read 13 Nov 2026)" || bad "build differs from production: $(q "$HASHES")"

for i in 1 2; do out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_unsubscribe_limit.sql" 2>&1) || { bad "apply (run $i): $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"; exit 1; }; done
[ "$(q "$HASHES")" = "$NEW_HASHES" ] && ok "applies twice" || bad "after apply: $(q "$HASHES")"
[ "$(q "select bool_and(has_function_privilege('anon', oid, 'execute')) from pg_proc where proname in ('zella_unsubscribe_email', 'zella_unsubscribe_lookup')")" = t ] \
  && ok "anonymous visitors can still use the link" || bad "the link no longer works for anonymous visitors"

out=$("${P[@]}" -d $DB 2>&1 <<'SQL'
-- two people at one business, each with their own link (test data only)
insert into customers (id, business_id, first_name, email) select 'cc000000-0000-4000-8000-000000000001', id, 'Test A', 'a@example.test' from businesses order by id limit 1;
insert into customers (id, business_id, first_name, email) select 'cc000000-0000-4000-8000-000000000002', id, 'Test B', 'b@example.test' from businesses order by id limit 1;
insert into email_unsubscribe_tokens (token, business_id, customer_id)
  select repeat('a', 32), business_id, id from customers where id = 'cc000000-0000-4000-8000-000000000001'
  union all select repeat('b', 32), business_id, id from customers where id = 'cc000000-0000-4000-8000-000000000002';
set role anon;
do $$ declare r jsonb; i int; n int; begin
  -- lookup: a valid link answers with the business; a wrong one doesn't; past 30 per 10 minutes it asks to wait
  assert public.zella_unsubscribe_lookup(repeat('a', 32)) ->> 'ok' = 'true', 'lookup of a valid link';
  assert public.zella_unsubscribe_lookup(repeat('c', 32)) ->> 'ok' = 'false', 'lookup of an unknown link';
  for i in 1..40 loop perform public.zella_unsubscribe_lookup(repeat('c', 32)); end loop;
  assert public.zella_unsubscribe_lookup(repeat('c', 32)) = '{"ok": false}'::jsonb, 'an unknown link is never "busy"';
  assert public.zella_unsubscribe_lookup('not-a-link') = '{"ok": false}'::jsonb, 'lookup of a malformed link';
  for i in 2..30 loop perform public.zella_unsubscribe_lookup(repeat('a', 32)); end loop;
  r := public.zella_unsubscribe_lookup(repeat('a', 32));
  assert r = '{"ok": false, "reason": "busy"}'::jsonb, 'lookup over the limit: ' || r::text;
  assert public.zella_unsubscribe_lookup(repeat('b', 32)) ->> 'ok' = 'true', 'a busy link must not slow down another link';
  raise notice 'PASS the lookup answers a valid link, refuses a wrong one, and asks to wait past 30 calls per link';
end $$;
reset role;
do $$ begin
  assert not exists (select 1 from rate_limits where key = 'unsub:view:' || repeat('c', 32)), 'an unknown link created a rate-limit row';
  raise notice 'PASS an unknown link is answered before counting: no rate-limit row';
end $$;
SQL
) && echo "$out" | grep -o 'PASS .*' || bad "lookup: $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"

out=$("${P[@]}" -d $DB 2>&1 <<'SQL'
-- save, link A: the first call records the opt-out; past 10 calls nothing more is written and the answer stays "done"
set role anon;
do $$ declare i int; r jsonb; begin
  for i in 1..25 loop r := public.zella_unsubscribe_email(repeat('a', 32)); assert r ->> 'ok' = 'true', 'save ' || i || ': ' || r::text; end loop;
end $$;
reset role;
do $$ begin
  assert (select count(*) from contact_consents where customer_id = 'cc000000-0000-4000-8000-000000000001' and status = 'opted_out') = 1, 'link A wrote more than one opt-out';
end $$;
-- save, link B: the limit is already used up before the person's first click; the opt-out is still recorded (NN-8)
insert into rate_limits (key, window_start, hits)
  select 'unsub:save:' || repeat('b', 32), to_timestamp(floor(extract(epoch from now()) / 600) * 600), 1000;
set role anon;
do $$ declare r jsonb; begin
  r := public.zella_unsubscribe_email(repeat('b', 32));
  assert r ->> 'ok' = 'true', 'first opt-out over the limit: ' || r::text;
end $$;
reset role;
do $$ begin
  assert (select count(*) from contact_consents where customer_id = 'cc000000-0000-4000-8000-000000000002' and status = 'opted_out'
            and channel = 'email' and purpose = 'marketing') = 1, 'the first opt-out was refused by the limit';
  assert (select count(*) from contact_consents where customer_id not in ('cc000000-0000-4000-8000-000000000001', 'cc000000-0000-4000-8000-000000000002')) = 0, 'another person was touched';
  raise notice 'PASS the save records one opt-out for 25 clicks, and records a first opt-out even when the limit is used up (opt-out always wins)';
end $$;
-- link A again, past the one-minute guard: the opt-out is older than a minute and the save limit is used up, so the
-- rate limit (not the one-minute guard) is what stops another write
update contact_consents set recorded_at = now() - interval '5 minutes' where customer_id = 'cc000000-0000-4000-8000-000000000001';
set role anon;
do $$ declare r jsonb; begin
  r := public.zella_unsubscribe_email(repeat('a', 32));
  assert r ->> 'ok' = 'true', 'over the limit, already opted out: ' || r::text;
end $$;
reset role;
do $$ begin
  assert (select count(*) from contact_consents where customer_id = 'cc000000-0000-4000-8000-000000000001' and status = 'opted_out') = 1,
    'over the limit, a person already opted out got another consent row';
  raise notice 'PASS past the one-minute guard, the save limit alone stops more writes for a person already opted out';
end $$;
-- link A, opted back in since: the latest choice is "opted in", so even over the limit the opt-out is recorded (NN-8)
insert into contact_consents (business_id, customer_id, email_lower, channel, purpose, status, source, evidence, recorded_at)
  select business_id, id, 'a@example.test', 'email', 'marketing', 'opted_in', 'web_form', '{"test": true}'::jsonb, now() - interval '2 minutes'
    from customers where id = 'cc000000-0000-4000-8000-000000000001';
set role anon;
do $$ declare r jsonb; begin
  r := public.zella_unsubscribe_email(repeat('a', 32));
  assert r ->> 'ok' = 'true', 'over the limit, opted back in: ' || r::text;
end $$;
reset role;
do $$ begin
  assert (select status from contact_consents where customer_id = 'cc000000-0000-4000-8000-000000000001' order by recorded_at desc limit 1) = 'opted_out',
    'over the limit, a person who had opted back in was not opted out';
  raise notice 'PASS over the limit, a person whose latest choice is "opted in" is still opted out (opt-out always wins)';
end $$;
-- link B, within the limit and within a minute: opted out 40 s ago, opted back in 20 s ago, unsubscribes again: the
-- one-minute double-click guard must not swallow it
delete from rate_limits where key = 'unsub:save:' || repeat('b', 32);
update contact_consents set recorded_at = now() - interval '40 seconds' where customer_id = 'cc000000-0000-4000-8000-000000000002';
insert into contact_consents (business_id, customer_id, email_lower, channel, purpose, status, source, evidence, recorded_at)
  select business_id, id, 'b@example.test', 'email', 'marketing', 'opted_in', 'web_form', '{"test": true}'::jsonb, now() - interval '20 seconds'
    from customers where id = 'cc000000-0000-4000-8000-000000000002';
set role anon;
do $$ begin perform public.zella_unsubscribe_email(repeat('b', 32)); end $$;
reset role;
do $$ begin
  assert (select status from contact_consents where customer_id = 'cc000000-0000-4000-8000-000000000002' order by recorded_at desc limit 1) = 'opted_out',
    'an opt-out within a minute of an earlier opt-out and a later opt-in was not recorded';
  raise notice 'PASS opt-out, opt-in, opt-out within one minute: the last opt-out is recorded';
end $$;
SQL
) && echo "$out" | grep -o 'PASS .*' || bad "save: $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"

for i in 1 2; do out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_unsubscribe_limit_rollback.sql" 2>&1) || { bad "rollback (run $i): $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"; exit 1; }; done
[ "$(q "$HASHES")" = "$LIVE_HASHES" ] && ok "the rollback (run twice) restores production's definitions exactly" || bad "after rollback: $(q "$HASHES")"
[ "$(q "select bool_and(has_function_privilege('anon', oid, 'execute')) from pg_proc where proname in ('zella_unsubscribe_email', 'zella_unsubscribe_lookup')")" = t ] \
  && ok "after the rollback anonymous visitors can still use the link" || bad "grants lost in the rollback"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_unsubscribe_limit.sql" 2>&1) && [ "$(q "$HASHES")" = "$NEW_HASHES" ] && ok "applies again after the rollback" || bad "re-apply: $(echo "$out" | grep -m2 ERROR | tr '\n' ' ')"
q "create or replace function public.zella_unsubscribe_lookup(p_token text) returns jsonb language sql security definer set search_path = public as \$\$ select '{}'::jsonb \$\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_unsubscribe_limit_rollback.sql" 2>&1) && bad "the rollback overwrote a function changed after the migration" || {
  echo "$out" | grep -q VERSION_MISMATCH && ok "the rollback refuses a function changed after the migration" || bad "rollback failed for another reason: $(echo "$out" | grep -m1 ERROR)"; }
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_unsubscribe_limit.sql" 2>&1) && bad "the migration overwrote a function it doesn't know" || {
  echo "$out" | grep -q VERSION_MISMATCH && ok "the migration refuses a function it wasn't written against" || bad "apply failed for another reason: $(echo "$out" | grep -m1 ERROR)"; }

"${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null
[ $fails = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
