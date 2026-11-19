#!/usr/bin/env bash
# sql/zella_document_orphans.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Checks: before, nothing lists unconfirmed uploads (the gap); applies, and applies again; objects older than 24 hours
# with no document row are listed; confirmed, rejected and replaced copies, fresh uploads and other buckets are not;
# the limit holds; a cleanup run is audited, and an empty one writes nothing; only the server may call either; the
# rollback (twice) drops both; applies again; a changed function stops the file (VERSION_MISMATCH) and the rollback.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zlb_document_orphans}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
MIG="$REPO/sql/zella_document_orphans.sql"; RB="$REPO/sql/rollback/zella_document_orphans_rollback.sql"
U=d1000000-0000-0000-0000-000000000001
B=$(q "insert into auth.users (id, email) values ('$U', 'owner@zella.test'); insert into public.businesses (name) values ('Orphan Test Studio') returning id" | tail -1)
q "insert into storage.buckets (id, name) values ('business-documents', 'business-documents'), ('record-files', 'record-files') on conflict do nothing" > /dev/null
obj() { q "insert into storage.objects (bucket_id, name, created_at) values ('$1', '$2', now() - interval '$3')" > /dev/null; }
row() { q "insert into public.business_verification_documents (business_id, kind, file_path, file_name, mime_type, size_bytes, status, uploaded_by) values ('$B', 'owner_identity', '$1', 'a.pdf', 'application/pdf', 10, '$2', '$U')" > /dev/null; }
obj business-documents "$B/owner_identity/orphan-old.pdf" "3 days"
obj business-documents "$B/owner_identity/orphan-fresh.pdf" "2 hours"
obj business-documents "$B/owner_identity/confirmed.pdf" "3 days"; row "$B/owner_identity/confirmed.pdf" pending_review
obj business-documents "$B/owner_identity/rejected.pdf" "3 days"; row "$B/owner_identity/rejected.pdf" rejected
obj business-documents "$B/owner_identity/replaced.pdf" "3 days"; row "$B/owner_identity/replaced.pdf" replaced
obj business-documents "$B/business_registration/orphan-two.png" "30 hours"
obj record-files "$B/x/other-bucket.pdf" "3 days"

[ -z "$(q "select to_regprocedure('public.zella_document_orphans(integer)')")" ] && ok "before: nothing lists unconfirmed uploads (the gap)" || bad "before"
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$MIG" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"
l=$(q "select string_agg(p, ',' order by p) from jsonb_array_elements_text(public.zella_document_orphans(500)) p")
[ "$l" = "$B/business_registration/orphan-two.png,$B/owner_identity/orphan-old.pdf" ] && ok "only objects over 24 hours old with no document row are listed" || bad "listed: $l"
[ "$(q "select jsonb_array_length(public.zella_document_orphans(1))")" = "1" ] && ok "the limit holds" || bad "limit"
l2=$(q "select string_agg(p, ',' order by p) from jsonb_array_elements_text(public.zella_document_orphans(500)) p")
[ "$l2" = "$l" ] && ok "claimed paths whose removal wasn't recorded are listed again (a failed audit loses nothing)" || bad "relisted: $l2"
out=$(q "insert into public.business_verification_documents (business_id, kind, file_path, file_name, mime_type, status) values ('$B', 'owner_identity', '$B/owner_identity/orphan-old.pdf', 'late.pdf', 'application/pdf', 'pending_review')" 2>&1)
[[ "$out" == *FILE_REMOVED* ]] && ok "a late confirmation of a claimed path is refused (upload it again)" || bad "late confirm: $out"
# a confirmation in progress (it holds the path's lock): the claim skips that path
obj business-documents "$B/owner_identity/confirming.pdf" "3 days"
PGAPPNAME=zlb_confirming "${P[@]}" -d $DB -c "begin; select pg_advisory_xact_lock(hashtext('business-document:$B/owner_identity/confirming.pdf')); select pg_sleep(3); commit;" > /dev/null 2>&1 & bgp=$!
for i in $(seq 1 100); do [ "$(q "select count(*) from pg_stat_activity where application_name = 'zlb_confirming' and wait_event = 'PgSleep'")" = "1" ] && break; sleep 0.1; done
l3=$(q "select public.zella_document_orphans(500)::text")
[[ "$l3" != *confirming.pdf* ]] && ok "a path being confirmed right now is never claimed" || bad "claimed while confirming: $l3"
wait $bgp
q "select public.zella_document_orphans_removed(array['$B/owner_identity/orphan-old.pdf', '$B/business_registration/orphan-two.png'])" > /dev/null
[ "$(q "select count(*) filter (where removed_at is not null) || ',' || count(*) filter (where removed_at is null) from public.business_document_cleanup")" = "2,0" ] && ok "a recorded removal closes those claims" || bad "claims: $(q "select path || removed_at from public.business_document_cleanup")"
a=$(q "select (new_data ->> 'count') || ',' || jsonb_array_length(new_data -> 'paths') from public.audit_logs where action = 'platform.document_orphans_removed'")
[ "$a" = "2,2" ] && ok "a cleanup run is audited with the count and paths" || bad "audit: $a"
q "select public.zella_document_orphans_removed('{}')" > /dev/null
[ "$(q "select count(*) from public.audit_logs where action = 'platform.document_orphans_removed'")" = "1" ] && ok "an empty run writes nothing" || bad "empty run audited"
g=$(q "select has_function_privilege('authenticated', 'public.zella_document_orphans(integer)', 'execute')::text || has_function_privilege('anon', 'public.zella_document_orphans_removed(text[])', 'execute')::text || has_function_privilege('service_role', 'public.zella_document_orphans(integer)', 'execute')::text")
[ "$g" = "falsefalsetrue" ] && ok "only the server may call them" || bad "grants: $g"
"$REPO/sql/rollback/run.sh" "$RB" -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -d $DB -q > /dev/null 2>&1 && "$REPO/sql/rollback/run.sh" "$RB" -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -d $DB -q > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
E="${DB}_empty"; "${P[@]}" -d postgres -c "drop database if exists $E" -c "create database $E template $TEMPLATE" > /dev/null
"${P[@]}" -d $E -f "$MIG" > /dev/null 2>&1; RBE=("$REPO/sql/rollback/run.sh" "$RB" -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -d $E -q)
"${RBE[@]}" > /dev/null 2>&1 && "${RBE[@]}" > /dev/null 2>&1 && [ -z "$("${P[@]}" -d $E -c "select to_regclass('public.business_document_cleanup')")" ] && ok "with no claims, the rollback drops the table and runs again" || bad "empty rollback twice"
"${P[@]}" -d postgres -c "drop database if exists $E" > /dev/null
[ "$(q "select count(*) from pg_proc where proname in ('zella_document_orphans', 'zella_document_orphans_removed', 'zella_document_cleanup_guard')")" = "0" ] && ok "rollback drops the functions and the guard" || bad "after rollback"
[ "$(q "select count(*) from public.business_document_cleanup")" = "2" ] && ok "and keeps the cleanup claims (they aren't deleted)" || bad "claims after rollback"
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_document_orphans(p_limit integer default 500) returns jsonb language sql as \$f\$ select '[]'::jsonb \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$MIG" 2>&1); [[ "$out" == *VERSION_MISMATCH* ]] && ok "a changed function stops the file" || bad "drift not caught: $out"
out=$("${P[@]}" -d $DB -f "$RB" 2>&1); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "and stops the rollback" || bad "rollback drift not caught: $out"
echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
