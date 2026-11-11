#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}
DB=zorderguards
. tests/lib/isolated_guard.sh
zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB"
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -d "$DB" -qtAX -v ON_ERROR_STOP=1)
bash tests/lib/build_full.sh "$DB" sql/zella_order_lookup_v2.sql sql/zella_order_lookup_reservations.sql
"${P[@]}" -f sql/zella_order_lookup_reservations.sql
"${P[@]}" -f tests/orders/reservations_test.sql
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
# Independent database sessions race for the same call; exactly one may reserve.
for i in {1..8}; do
  "${P[@]}" -c "select zella_store_lookup_begin('v2call-3', 'e9000000-0000-0000-0000-000000000002', 'ref-race')->>'ok'" > "$scratch/$i" &
done
wait
[ "$(cat "$scratch"/* | rg -c '^true$')" = 1 ]
[ "$(cat "$scratch"/* | rg -c '^false$')" = 7 ]
"${P[@]}" -f sql/rollback/zella_order_lookup_reservations_rollback.sql
"${P[@]}" -f sql/zella_order_lookup_reservations.sql
[ "$("${P[@]}" -c "select zella_store_lookup_begin('v2call-2', 'e9000000-0000-0000-0000-000000000002', 'ref')->>'status'")" = limited ]
echo 'PASS concurrency: one reservation, seven refusals; rollback/reapply preserves unresolved lock'

# Different calls must share capacity, including committed failures and in-flight work.
for bucket in number order business; do
  "${P[@]}" -c "delete from store_lookup_guards; delete from ai_tool_calls;
    update calls set from_number = '+1512555' || lpad(substring(external_call_id from 8)::text, 4, '0')
      where external_call_id like 'v2call-%';" >/dev/null
  case "$bucket" in
    number)
      "${P[@]}" -c "update calls set from_number = '+15125550001' where external_call_id like 'v2call-%'" >/dev/null
      failures=4; ref_expr="'ref-' || g" ;;
    order) failures=3; ref_expr="'shared-ref'" ;;
    business) failures=28; ref_expr="'ref-' || g" ;;
  esac
  "${P[@]}" -c "insert into ai_tool_calls (business_id, provider_call_id, tool, status, result_status, lookup_ref)
    select 'e9000000-0000-0000-0000-000000000002', 'v2call-40', 'lookup_order', 'done', 'not_found', $ref_expr
    from generate_series(1, $failures) g" >/dev/null
  pids=()
  for i in {1..8}; do
    ref="ref-$i"
    if [ "$bucket" = order ]; then ref=shared-ref; fi
    "${P[@]}" -c "begin; select zella_store_lookup_begin('v2call-$i', 'e9000000-0000-0000-0000-000000000002', '$ref')->>'ok'; select pg_sleep(0.05); commit;" > "$scratch/$i" &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
  [ "$(cat "$scratch"/* | rg -c '^true$')" = 2 ]
  [ "$(cat "$scratch"/* | rg -c '^false$')" = 6 ]
  echo "PASS shared $bucket limit: two remaining slots, six refusals"
done
