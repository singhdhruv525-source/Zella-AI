#!/usr/bin/env bash
# Checks sql/zella_rollback_security.sql (CodeRabbit review #44, finding 1) on an ISOLATED copy of the production state: version
# guard, two runs, tests/rollback_security/check.sql, the rollback restoring everything exactly, and a reapply. Then
# the rollback-runner and data-boundary checks. Never point this at production.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zrbsecurity}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
read -r -a PENDING <<< "$(sed -n '/^PENDING=(/,/)/p' "$REPO/tests/deploy/run_all.sh" | tr -d '()' | sed 's/^PENDING=//' | tr '\n' ' ')"
for m in "${PENDING[@]}"; do [[ "$m" =~ ^zella_[a-z0-9_]+$ ]] || { echo "FAIL unexpected pending entry: $m"; exit 1; }; done
"$REPO/tests/lib/build_full.sh" "$DB" "$REPO/tests/channel/fixture.sql" || exit 1
for m in "${PENDING[@]}" zella_batch1_security zella_batch3_pagination; do
  [ -f "$REPO/sql/$m.sql" ] || { echo "FAIL missing migration: $REPO/sql/$m.sql" >&2; exit 1; }
  out=$("${P[@]}" -d "$DB" -f "$REPO/sql/$m.sql" 2>&1) || { echo "FAIL apply $m: $(echo "$out" | grep -m1 ERROR)"; exit 1; }
done
SNAP="select md5(concat_ws('|',
  (select string_agg(p.oid::regprocedure::text || pg_get_functiondef(p.oid) || coalesce(array_to_string(array(select x::text from unnest(p.proacl) x order by 1), ','), ''), '' order by 1) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('zella_receive_inbound_email', 'zella_call_content')),
  pg_get_viewdef('public.calls_view'::regclass), (select string_agg(x::text, ',' order by x::text) from pg_class, unnest(relacl) x where oid = 'public.calls_view'::regclass),
  (select string_agg(x::text, ',' order by x::text) from pg_class, unnest(relacl) x where oid = 'public.calls'::regclass),
  (select string_agg(attname || ':' || x::text, ',' order by attname, x::text) from pg_attribute, unnest(attacl) x where attrelid = 'public.calls'::regclass and attnum > 0),
  (select pg_get_expr(d.adbin, d.adrelid) from pg_attrdef d join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum where d.adrelid = 'public.businesses'::regclass and a.attname = 'inbound_email_token')))"
fails=0; ok(){ echo "PASS $1"; }; bad(){ echo "FAIL $1"; fails=$((fails+1)); }
before=$("${P[@]}" -d "$DB" -c "$SNAP")
orig=$("${P[@]}" -d "$DB" -c "select pg_get_functiondef('public.zella_receive_inbound_email(text,jsonb)'::regprocedure)")
"${P[@]}" -d "$DB" -c "alter function public.zella_receive_inbound_email(text,jsonb) stable" >/dev/null
drift=$("${P[@]}" -d "$DB" -c "$SNAP")
if out=$("${P[@]}" -d "$DB" -f "$REPO/sql/zella_rollback_security.sql" 2>&1); then bad "version guard accepted drift"
elif [[ "$out" == *VERSION_MISMATCH* && "$("${P[@]}" -d "$DB" -c "$SNAP")" = "$drift" ]]; then ok "version guard refuses drift and changes nothing"
else bad "version guard: $out"; fi
"${P[@]}" -d "$DB" -c "$orig" >/dev/null
for i in 1 2; do out=$("${P[@]}" -d "$DB" -f "$REPO/sql/zella_rollback_security.sql" 2>&1) && ok "migration run $i" || { bad "migration run $i: $(echo "$out" | grep -m1 ERROR)"; exit 1; }; done
out=$("${P[@]}" -d "$DB" -f "$HERE/check.sql" 2>&1) && ok "check.sql: new tokens, address matching, call content stays private" || bad "check.sql: $(echo "$out" | grep -m2 -E 'ERROR|assert')"
out=$("${P[@]}" -d "$DB" -f "$REPO/sql/rollback/zella_rollback_security_rollback.sql" 2>&1) || bad "rollback: $(echo "$out" | grep -m1 ERROR)"
[ "$("${P[@]}" -d "$DB" -c "$SNAP")" = "$before" ] && ok "rollback restores the function and the default exactly; calls untouched" || bad "rollback differs"
out=$("${P[@]}" -d "$DB" -f "$REPO/sql/zella_rollback_security.sql" 2>&1) && ok "applies again after the rollback" || bad "reapply: $(echo "$out" | grep -m1 ERROR)"
out=$(python3 "$HERE/runner_checks.py" 2>&1) && ok "rollback runner rejects fragments" || bad "runner_checks.py: $(echo "$out" | tail -3)"
out=$(python3 "$HERE/data_checks.py" 2>&1) && ok "rollback data boundaries (tenant, conflicts, archives)" || bad "data_checks.py: $(echo "$out" | tail -3)"
echo; [ "$fails" = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
