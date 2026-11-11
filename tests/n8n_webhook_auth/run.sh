#!/usr/bin/env bash
# Checks sql/zella_n8n_webhook_auth.sql on an ISOLATED copy of the production state (tests/lib/build_full.sh plus the
# pending list, Batch 1 and Batch 3): version guard, two runs, Resend key and signature checks, grants, the rollback
# restoring both replaced functions exactly, and a second apply after it. Never point this at production.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zn8nwebhookauth}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
read -r -a PENDING <<< "$(sed -n '/^PENDING=(/,/)/p' "$REPO/tests/deploy/run_all.sh" | tr -d '()' | sed 's/^PENDING=//' | tr '\n' ' ')"
for m in "${PENDING[@]}"; do [[ "$m" =~ ^zella_[a-z0-9_]+$ ]] || { echo "FAIL unexpected pending entry: $m"; exit 1; }; done
"$REPO/tests/lib/build_full.sh" "$DB" "$REPO/tests/channel/fixture.sql" || exit 1
for m in "${PENDING[@]}" zella_batch1_security zella_batch3_pagination; do
  [ -f "$REPO/sql/$m.sql" ] || { echo "FAIL missing migration: $REPO/sql/$m.sql" >&2; exit 1; }
  out=$("${P[@]}" -d "$DB" -f "$REPO/sql/$m.sql" 2>&1) || { echo "FAIL apply $m: $(echo "$out" | grep -m1 ERROR)"; exit 1; }
done
SNAP="select md5(string_agg(p.oid::regprocedure::text || pg_get_functiondef(p.oid) || coalesce(array_to_string(p.proacl, ','), ''), '' order by p.oid::regprocedure::text)) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('zella_record_email_event_signed', 'zella_receive_inbound_email_signed', 'zella_n8n_resend_auth')"
fails=0; ok(){ echo "PASS $1"; }; bad(){ echo "FAIL $1"; fails=$((fails+1)); }
before=$("${P[@]}" -d "$DB" -c "$SNAP")
# 1. the version guard refuses a definition it was not written against, and changes nothing
orig=$("${P[@]}" -d "$DB" -c "select pg_get_functiondef('public.zella_record_email_event_signed(text,jsonb,text,jsonb)'::regprocedure)")
"${P[@]}" -d "$DB" -c "alter function public.zella_record_email_event_signed(text,jsonb,text,jsonb) stable" >/dev/null
drift=$("${P[@]}" -d "$DB" -c "$SNAP")
if out=$("${P[@]}" -d "$DB" -f "$REPO/sql/zella_n8n_webhook_auth.sql" 2>&1); then bad "version guard accepted drift"
elif [[ "$out" == *VERSION_MISMATCH* && "$("${P[@]}" -d "$DB" -c "$SNAP")" = "$drift" ]]; then ok "version guard refuses drift and changes nothing"
else bad "version guard: $out"; fi
"${P[@]}" -d "$DB" -c "$orig" >/dev/null
# 2. applies twice
for i in 1 2; do out=$("${P[@]}" -d "$DB" -f "$REPO/sql/zella_n8n_webhook_auth.sql" 2>&1) && ok "migration run $i" || { bad "migration run $i: $(echo "$out" | grep -m1 ERROR)"; exit 1; }; done
# 3. behaviour, with throwaway test secrets in this isolated copy only
out=$("${P[@]}" -d "$DB" -f "$HERE/test.sql" 2>&1); echo "$out" | grep -oE '(PASS|FAIL) .*'; echo "$out" | grep -q -E 'FAIL|ERROR' && { echo "$out" | grep -m3 ERROR; fails=$((fails+1)); }
# 4. the rollback restores both replaced functions and their grants exactly, then the migration applies again
out=$("${P[@]}" -d "$DB" -f "$REPO/sql/rollback/zella_n8n_webhook_auth_rollback.sql" 2>&1) || bad "rollback: $(echo "$out" | grep -m1 ERROR)"
[ "$("${P[@]}" -d "$DB" -c "$SNAP")" = "$before" ] && ok "rollback restores both functions and grants exactly" || bad "rollback differs"
out=$("${P[@]}" -d "$DB" -f "$REPO/sql/zella_n8n_webhook_auth.sql" 2>&1) && ok "applies again after the rollback" || bad "reapply: $(echo "$out" | grep -m1 ERROR)"
echo; [ "$fails" = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
