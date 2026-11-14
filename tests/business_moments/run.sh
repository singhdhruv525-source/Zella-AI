#!/usr/bin/env bash
# sql/zella_business_moments.sql on an ISOLATED copy of the production schema (never production): applied twice; the
# hourly group runs it; a record day, a call surge and an on call gap each raise one notification, once; quiet days,
# a covered weekend and a switched off rota raise nothing; the rollback takes it out of the hourly group.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zbizmoments
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template zdocs" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }

for i in 1 2; do out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_business_moments.sql" 2>&1) || { bad "apply (run $i): $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"; exit 1; }; done
ok "applies twice"
[ "$(q "select count(*) from regexp_matches(pg_get_functiondef('public.zella_run_schedule_group(text)'::regprocedure), 'zella_check_business_moments', 'g')")" = 1 ] \
  && ok "runs hourly (added to the hourly group once)" || bad "not in the hourly group exactly once"
[ "$(q "select has_function_privilege('authenticated', 'public.zella_check_business_moments(timestamptz)', 'execute')")" = f ] && ok "server only" || bad "callable by signed in users"

# test data only: two businesses in New York
out=$("${P[@]}" -d $DB 2>&1 <<'SQL'
insert into businesses (id, name, timezone) values ('b0000000-0000-4000-8000-0000000000a1', 'Test Salon', 'America/New_York'),
                                                   ('b0000000-0000-4000-8000-0000000000a2', 'Test Quiet', 'America/New_York');
insert into staff_members (id, business_id, name, phone, is_active) values ('5a000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-0000000000a1', 'Sam', '+15550102040', true);
SQL
) || { bad "seed: $(echo "$out" | grep -m1 ERROR)"; exit 1; }

# a fixed "now": Thursday 13 Nov 2026, 14:00 in New York
NOW="'2026-11-13 14:00 America/New_York'::timestamptz"
out=$("${P[@]}" -d $DB 2>&1 <<SQL
-- 90 quiet days with 3 AI bookings each, then 12 yesterday (a record)
insert into appointments (business_id, title, status, start_time, end_time, metadata, created_at)
  select 'b0000000-0000-4000-8000-0000000000a1', 'Test booking', 'scheduled', $NOW + make_interval(days => 100, hours => d * 3 + k), $NOW + make_interval(days => 100, hours => d * 3 + k, mins => 30), '{"source": "ai"}', $NOW - make_interval(days => d) - interval '1 hour'
    from generate_series(2, 90) d, generate_series(1, 3) k;
insert into appointments (business_id, title, status, start_time, end_time, metadata, created_at)
  select 'b0000000-0000-4000-8000-0000000000a1', 'Test booking', 'scheduled', $NOW + make_interval(days => 10, hours => g), $NOW + make_interval(days => 10, hours => g, mins => 30), '{"source": "ai"}', $NOW - interval '1 day'
    from generate_series(1, 12) g;
-- staff bookings never count
insert into appointments (business_id, title, status, start_time, end_time, metadata, created_at)
  select 'b0000000-0000-4000-8000-0000000000a2', 'Test booking', 'scheduled', $NOW + make_interval(days => 10, hours => g), $NOW + make_interval(days => 10, hours => g, mins => 30), '{"source": "staff"}', $NOW - interval '1 day'
    from generate_series(1, 40) g;
-- calls: 4 a day for 28 days, then 25 today (6 times a usual day)
insert into calls (business_id, direction, status, created_at)
  select 'b0000000-0000-4000-8000-0000000000a1', 'inbound', 'completed', $NOW - make_interval(days => d) from generate_series(1, 28) d, generate_series(1, 4);
insert into calls (business_id, direction, status, created_at)
  select 'b0000000-0000-4000-8000-0000000000a1', 'inbound', 'completed', $NOW - make_interval(mins => m) from generate_series(1, 25) m;
-- on call switched on, Sam covers only Saturday 9:00 to 17:00
insert into on_call_settings (business_id, enabled) values ('b0000000-0000-4000-8000-0000000000a1', true);
insert into on_call_shifts (business_id, staff_id, kind, weekday, starts, ends) values ('b0000000-0000-4000-8000-0000000000a1', '5a000000-0000-4000-8000-000000000001', 'weekly', 6, '09:00', '17:00');
do \$\$ declare n int; begin
  n := public.zella_check_business_moments($NOW);
  assert n = 3, 'expected 3 moments, got ' || n;
  assert (select count(*) from staff_notifications where business_id = 'b0000000-0000-4000-8000-0000000000a1' and kind = 'best_day') = 1, 'record day';
  assert (select body from staff_notifications where kind = 'best_day') like 'Your AI receptionist booked 12 appointments yesterday%', 'record day body';
  assert (select count(*) from staff_notifications where kind = 'call_surge') = 1, 'call surge';
  assert (select body from staff_notifications where kind = 'call_surge') like '25 calls so far today, about 6.3 times a usual day.%', 'surge body: ' || (select body from staff_notifications where kind = 'call_surge');
  assert (select title from staff_notifications where kind = 'on_call_gap') = 'Gaps in this weekend''s on call cover', 'partial gap';
  assert (select severity from staff_notifications where kind = 'on_call_gap') = 'warning', 'gap severity';
  assert not exists (select 1 from staff_notifications where business_id = 'b0000000-0000-4000-8000-0000000000a2' and kind in ('best_day', 'call_surge', 'on_call_gap')), 'the quiet business got nothing (staff bookings never count)';
  -- an hour later: nothing new (once per day or weekend)
  assert public.zella_check_business_moments($NOW + interval '1 hour') = 0, 'repeated';
  raise notice 'PASS a record day, a call surge and a partial on call gap each raise one notification, once; staff bookings never count';
end \$\$;
SQL
) && echo "$out" | grep -o 'PASS .*' || bad "moments: $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"

out=$("${P[@]}" -d $DB 2>&1 <<SQL
-- the next weekend with nobody on call at all
delete from on_call_shifts;
do \$\$ begin
  assert public.zella_check_business_moments($NOW + interval '7 days') >= 1, 'a whole weekend without cover';
  assert (select title from staff_notifications where kind = 'on_call_gap' order by created_at desc limit 1) = 'No one is on call this weekend', 'no cover title';
  -- on call switched off: never a gap notice
  update on_call_settings set enabled = false;
  assert public.zella_check_business_moments($NOW + interval '14 days') = 0, 'switched off raised something';
  assert (select count(*) from staff_notifications where kind = 'on_call_gap') = 2, 'no notice while on call is switched off';
  -- a weekend fully covered: no notice
  update on_call_settings set enabled = true;
  -- cover from Saturday 5 Dec 00:00 to Monday 7 Dec 00:00, the weekend after "now + 21 days"
  insert into on_call_shifts (business_id, staff_id, kind, starts_at, ends_at)
    values ('b0000000-0000-4000-8000-0000000000a1', '5a000000-0000-4000-8000-000000000001', 'cover',
            '2026-12-05 00:00 America/New_York', '2026-12-07 00:00 America/New_York');
  perform public.zella_check_business_moments($NOW + interval '21 days');
  assert (select count(*) from staff_notifications where kind = 'on_call_gap') = 2, 'a covered weekend raised a notice';
  raise notice 'PASS no cover at all says so; a switched off rota and a fully covered weekend raise nothing';
end \$\$;
SQL
) && echo "$out" | grep -o 'PASS .*' || bad "on call: $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"

for i in 1 2; do out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_business_moments_rollback.sql" 2>&1) || { bad "rollback (run $i): $(echo "$out" | grep -m2 ERROR)"; exit 1; }; done
[ "$(q "select position('zella_check_business_moments' in pg_get_functiondef('public.zella_run_schedule_group(text)'::regprocedure))")" = 0 ] \
  && [ "$(q "select to_regprocedure('public.zella_check_business_moments(timestamptz)') is null")" = t ] && ok "the rollback (run twice) removes it from the hourly group" || bad "rollback left something"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_business_moments.sql" 2>&1) && ok "applies again after the rollback" || bad "re-apply: $(echo "$out" | grep -m1 ERROR)"

[ -n "${KEEP_DB:-}" ] || "${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null
[ $fails = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
