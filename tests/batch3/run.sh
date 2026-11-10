#!/usr/bin/env bash
# Batch 3 database checks on an ISOLATED copy of the production state: tests/lib/build_full.sh (production as of 5 Nov),
# every file applied since (tests/deploy/run_all.sh's pending list, all live as of 6 Nov), sql/zella_batch1_security.sql,
# then sql/zella_batch3_pagination.sql twice, tests/batch3/test.sql, and the rollback. Never point this at production.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zbatch3}
P="psql -h $ZPG_HOST -p $ZPG_PORT -U postgres -qtAX -v ON_ERROR_STOP=1"
# Parse the complete assignment as data; never execute deployment-script text.
pending=$(python3 -I - "$REPO/tests/deploy/run_all.sh" <<'PY_PENDING'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
assignments = re.findall(r"^PENDING=", text, re.M)
match = re.search(r"^PENDING=\(([^)]*)\)[ \t]*$", text, re.M)
if len(assignments) != 1 or not match:
    sys.exit("FAIL: could not read the complete PENDING assignment")
entries = match[1].split()
if not entries or any(not re.fullmatch(r"zella_[a-z0-9_]+", entry) for entry in entries):
    sys.exit("FAIL: invalid or empty PENDING list")
print(" ".join(entries))
PY_PENDING
) || exit 1
read -r -a PENDING <<< "$pending"
for m in "${PENDING[@]}"; do
  [ -f "$REPO/sql/$m.sql" ] || { echo "FAIL: missing migration $m" >&2; exit 1; }
done
"$REPO/tests/lib/build_full.sh" "$DB" || exit 1
for m in "${PENDING[@]}" zella_batch1_security; do out=$($P -d "$DB" -f "$REPO/sql/$m.sql" 2>&1) || { echo "FAIL apply $m: $(echo "$out" | grep -m1 ERROR)"; exit 1; }; done
fails=0
for i in 1 2; do out=$($P -d "$DB" -f "$REPO/sql/zella_batch3_pagination.sql" 2>&1) || { echo "FAIL batch3 migration run $i: $(echo "$out" | grep -m1 ERROR)"; fails=1; }; done
[ $fails = 0 ] && echo "PASS sql/zella_batch3_pagination.sql applies twice"
out=$($P -d "$DB" -f "$HERE/test.sql" 2>&1); code=$?
echo "$out" | grep -oE '(PASS|FIXTURE|PERF) .*'
[ $code -ne 0 ] && { echo "FAIL batch3_test: $(echo "$out" | grep -m3 -E 'ERROR|CONTEXT' | tr '\n' ' ')"; fails=$((fails + 1)); }
out=$($P -d "$DB" -f "$REPO/sql/rollback/zella_batch3_pagination_rollback.sql" 2>&1) || { echo "FAIL rollback: $out"; fails=$((fails + 1)); }
left=$($P -d "$DB" -c "select count(*) from pg_proc where pronamespace = 'public'::regnamespace and (proname like 'zella_b3_%' or proname in ('zella_leads_page','zella_records_page','zella_calls_page','zella_inbox_page','zella_inbox_previews','zella_call_row','zella_lead_stage','zella_lead_source_group','zella_lead_column'))")
[ "$left" = "0" ] && echo "PASS rollback removes every Batch 3 function" || { echo "FAIL rollback left $left functions"; fails=$((fails + 1)); }
echo; [ $fails = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
