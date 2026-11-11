#!/usr/bin/env bash
# BM2 tables (sql/zella_tables.sql, after sql/zella_arrival_windows.sql) on an ISOLATED copy of production.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=ztables
P="psql -h $ZPG_HOST -p $ZPG_PORT -U postgres -qtAX -v ON_ERROR_STOP=1"
APPLIED=(zella_platform_roles_fix zella_booking_buffers zella_channel_review zella_escalation_rules zella_knowledge_live zella_order_lookup_v2 zella_config_migration
  zella_report_schedules zella_knowledge_learning zella_assistant_delivery zella_plan_languages zella_holiday_availability zella_delivery_evidence zella_arrival_windows)
FIX=("$REPO/sql/zella_tables.sql" "$REPO/sql/zella_tables.sql" "$REPO/sql/zella_seating_handoff.sql" "$REPO/sql/zella_seating_handoff.sql"); [ "${WITHOUT_FIX:-}" = 1 ] && FIX=()
"$REPO/tests/lib/build_full.sh" $DB $(for m in "${APPLIED[@]}"; do echo "$REPO/sql/$m.sql"; done) "${FIX[@]}" || exit 1
for f in tables_test.sql seating_test.sql; do
  out=$($P -d $DB -f "$HERE/$f" 2>&1); code=$?
  echo "$out" | grep -o 'PASS .*'; [ $code -ne 0 ] && { echo "FAIL $(echo "$out" | grep -m3 -E 'ERROR|CONTEXT')"; exit 1; }
done
# two callers at the same moment for the last table: one is booked, the other is refused (two real connections)
$P -d $DB -c "insert into businesses (id, name, industry_id, timezone, is_active, onboarding_status) select '5f000000-0000-0000-0000-0000000000d1', 'Race Cafe', id, 'UTC', true, 'active' from industries where slug = 'restaurant';
  insert into business_hours (business_id, weekday, opens, closes) select '5f000000-0000-0000-0000-0000000000d1', d, '00:00', '23:59' from generate_series(0, 6) d;
  insert into ai_agents (id, business_id, name, agent_type, status, is_default) values ('5f100000-0000-0000-0000-0000000000d1', '5f000000-0000-0000-0000-0000000000d1', 'Ava', 'receptionist', 'active', true);
  insert into ai_agent_configs (agent_id, system_prompt, escalation_rules, knowledge_base, appointment_rules) values ('5f100000-0000-0000-0000-0000000000d1', 'You are the host of Race Cafe.', '{}', '{}', '{\"default_minutes\": 60}');
  insert into restaurant_tables (business_id, name, max_party) values ('5f000000-0000-0000-0000-0000000000d1', 'Only', 4);" >/dev/null || exit 1
T=$($P -d $DB -c "select (date_trunc('day', now()) + interval '2 days 19 hours')::text")
for who in Ana Ben; do
  $P -d $DB -c "select public.zella_ai_booking(null, '5f000000-0000-0000-0000-0000000000d1', 'book', jsonb_build_object('start', '$T', 'party_size', 2, 'first_name', '$who', 'phone', '+1212555$((RANDOM % 9000 + 1000))', 'confirmed', true)) ->> 'status'" > "/tmp/race_$who.$$" &
done; wait
r=$(cat /tmp/race_Ana.$$ /tmp/race_Ben.$$ | sort | tr '\n' ' '); rm -f /tmp/race_*.$$
n=$($P -d $DB -c "select count(*) from appointments where business_id = '5f000000-0000-0000-0000-0000000000d1' and booking_state = 'confirmed'")
[ "$r" = "booked unavailable " ] && [ "$n" = 1 ] && echo "PASS two callers at once for the last table: one booked, the other refused ($r)" || { echo "FAIL race: $r ($n confirmed)"; exit 1; }
echo "ALL PASSED"
