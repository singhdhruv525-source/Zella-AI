#!/usr/bin/env bash
# Checks sql/zella_review_sql_fixes.sql on an ISOLATED copy of the production state: tests/lib/build_full.sh plus every
# file applied since (tests/deploy/run_all.sh's pending list, Batch 1, Batch 3, the 9 Nov brand-name patch), then the migration twice,
# tests/review_sql/test.sql, the rollback (every function and grant back exactly), and a second apply after it.
# Never point this at production.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zreviewsql}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
read -r -a PENDING <<< "$(sed -n '/^PENDING=(/,/)/p' "$REPO/tests/deploy/run_all.sh" | tr -d '()' | sed 's/^PENDING=//' | tr '\n' ' ')"
for m in "${PENDING[@]}"; do [[ "$m" =~ ^zella_[a-z0-9_]+$ ]] || { echo "FAIL unexpected pending entry: $m"; exit 1; }; done
"$REPO/tests/lib/build_full.sh" "$DB" "$REPO/tests/channel/fixture.sql" || exit 1
for m in "${PENDING[@]}" zella_batch1_security zella_batch3_pagination zella_brand_name; do
  [ -f "$REPO/sql/$m.sql" ] || { echo "FAIL missing migration: $REPO/sql/$m.sql" >&2; exit 1; }
  out=$("${P[@]}" -d "$DB" -f "$REPO/sql/$m.sql" 2>&1) || { echo "FAIL apply $m: $(echo "$out" | grep -m1 ERROR)"; exit 1; }
done
# the platform wording rows (#8 changes the dental ones); the baseline is schema only
out=$("${P[@]}" -d "$DB" -f "$REPO/sql/zella_industry_templates.sql" 2>&1) || { echo "FAIL templates: $(echo "$out" | grep -m1 ERROR)"; exit 1; }
SNAP="select md5(string_agg(p.oid::regprocedure::text || pg_get_functiondef(p.oid) || coalesce((select string_agg(x::text, ',' order by x::text) from unnest(p.proacl) x), ''), '' order by p.oid::regprocedure::text)) from pg_proc p where p.pronamespace = 'public'::regnamespace"
TRG="select count(*) from pg_trigger where tgname = 'zella_audit_privileged_trg'"
before=$("${P[@]}" -d "$DB" -c "$SNAP"); t0=$("${P[@]}" -d "$DB" -c "$TRG"); fails=0
# A definition attribute drift must fail before any migration changes.
original=$("${P[@]}" -d "$DB" -c "select pg_get_functiondef('public.zella_claim_events(integer)'::regprocedure)")
"${P[@]}" -d "$DB" -c "alter function public.zella_claim_events(integer) stable" || exit 1
drift=$("${P[@]}" -d "$DB" -c "$SNAP")
if out=$("${P[@]}" -d "$DB" -f "$REPO/sql/zella_review_sql_fixes.sql" 2>&1); then
  echo 'FAIL version guard accepted drift'; exit 1
fi
[[ "$out" == *VERSION_MISMATCH* && "$("${P[@]}" -d "$DB" -c "$SNAP")" = "$drift" ]] || { echo 'FAIL version guard changed SNAP or missed VERSION_MISMATCH'; exit 1; }
"${P[@]}" -d "$DB" -c "$original" || exit 1
echo 'PASS version guard rejects attribute drift without changing SNAP'
for i in 1 2; do out=$("${P[@]}" -d "$DB" -f "$REPO/sql/zella_review_sql_fixes.sql" 2>&1) && echo "PASS migration run $i" || { echo "FAIL migration run $i: $(echo "$out" | grep -m1 ERROR)"; exit 1; }; done
out=$("${P[@]}" -d "$DB" -f "$HERE/test.sql" 2>&1); code=$?
echo "$out" | grep -oE 'PASS .*'
[ $code -ne 0 ] && { echo "FAIL test.sql: $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"; fails=$((fails + 1)); }
out=$("$REPO/sql/rollback/run.sh" "$REPO/sql/rollback/zella_review_sql_fixes_rollback.sql" -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -d "$DB" -q 2>&1) || { echo "FAIL rollback: $(echo "$out" | grep -m1 ERROR)"; fails=$((fails + 1)); }
[ "$("${P[@]}" -d "$DB" -c "$SNAP")" = "$before" ] && echo "PASS rollback restores every function and grant exactly" || { echo "FAIL rollback differs"; fails=$((fails + 1)); }
[ "$("${P[@]}" -d "$DB" -c "$TRG")" = "$t0" ] && echo "PASS rollback removes the platform_admins audit trigger" || { echo "FAIL trigger left"; fails=$((fails + 1)); }
out=$("${P[@]}" -d "$DB" -f "$REPO/sql/zella_review_sql_fixes.sql" 2>&1) && echo "PASS applies again after the rollback" || { echo "FAIL re-apply: $(echo "$out" | grep -m1 ERROR)"; fails=$((fails + 1)); }
echo; [ $fails = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
