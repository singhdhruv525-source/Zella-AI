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
