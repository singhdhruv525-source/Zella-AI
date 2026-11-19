#!/usr/bin/env bash
# sql/zella_business_export.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Checks: before, a whole business can't be exported (the gap); applies, and applies again; the bucket is private and
# the jobs table is server only; an admin requests, a second open request is refused; the requester can't approve
# their own request, a super admin can't approve, a Zella Voice owner can (or reject with a reason); a claim takes the
# approved export; rows come without secret tables or columns, without recording links, and without transcripts in a
# sensitive industry (with them otherwise); files list both buckets for that business only; a stale claim can't write;
# a failure goes back to approved and resumes from its progress; three stops end it failed; a finish makes it ready for
# 7 days; ready exports past 7 days expire; each step is audited; only the server may call the functions; the
# business's own row is exported; pages are read by key; a pause isn't a try; the rollback refuses while an export is
# ready, then (twice) removes the functions and bucket and keeps the export records; applies again; drift stops the file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zlb_business_export}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
MIG="$REPO/sql/zella_business_export.sql"; RB="$REPO/sql/rollback/zella_business_export_rollback.sql"
ADM=e6000000-0000-0000-0000-000000000001; OWN=e6000000-0000-0000-0000-000000000002; SUP=e6000000-0000-0000-0000-000000000003; OUT=e6000000-0000-0000-0000-000000000004
q "insert into auth.users (id, email) values ('$ADM', 'support@zella.test'), ('$OWN', 'owner@zella.test'), ('$SUP', 'super@zella.test'), ('$OUT', 'someone@else.test');
   insert into public.platform_admins (user_id, role, is_active) values ('$ADM', 'support_admin', true), ('$OWN', 'zella_owner', true), ('$SUP', 'super_admin', true);
   insert into storage.buckets (id, name) values ('business-documents', 'business-documents'), ('record-files', 'record-files') on conflict do nothing" > /dev/null || exit 1
PLAIN=$(q "select id from public.industries where slug not in ('dental','healthcare','pet-care-veterinary','legal','financial-services','insurance','childcare') order by name limit 1")
SENS=$(q "select id from public.industries where slug = 'dental' limit 1")
B=$(q "insert into public.businesses (name, industry_id) values ('Export Test Studio', '$PLAIN') returning id" | head -1)
D=$(q "insert into public.businesses (name, industry_id) values ('Export Dental Studio', '$SENS') returning id" | head -1)
O=$(q "insert into public.businesses (name, industry_id) values ('Other Studio', '$PLAIN') returning id" | head -1)
for x in $B $D; do q "insert into public.calls (business_id, direction, transcript, summary, recording_url) values ('$x', 'inbound', 'Caller said hello', 'A greeting', 'https://rec.example/1')" > /dev/null; done
q "insert into public.integrations (business_id, provider, integration_type, credentials) values ('$B', 'test', 'calendar', '{\"k\": \"secret-value\"}'::jsonb)" > /dev/null 2>&1 || { echo "FAIL fixture: integrations"; exit 1; }
q "insert into storage.objects (bucket_id, name) values ('business-documents', '$B/owner_identity/a.pdf'), ('record-files', '$B/r/b.png'), ('business-documents', '$O/owner_identity/c.pdf')" > /dev/null

[ -z "$(q "select to_regclass('public.business_export_jobs')")" ] && ok "before: a whole business can't be exported (the gap)" || bad "before"
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$MIG" 2>&1 | grep -v NOTICE | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"
[ "$(q "select public::text from storage.buckets where id = 'business-exports'")" = "false" ] && [ "$(q "select has_table_privilege('authenticated', 'public.business_export_jobs', 'select')::text || has_table_privilege('anon', 'public.business_export_jobs', 'select')::text")" = "falsefalse" ] && ok "the bucket is private and the jobs are server only" || bad "privacy"
out=$(q "select public.zella_export_request('$B', '$OUT', 'test reason')" 2>&1); [[ "$out" == *NOT_ALLOWED* ]] && ok "someone who isn't an admin can't request" || bad "outsider: $out"
J=$(q "select public.zella_export_request('$B', '$ADM', 'Owner asked for a copy')")
out=$(q "select public.zella_export_request('$B', '$OWN', 'again please')" 2>&1); [[ "$out" == *EXPORT_OPEN* ]] && ok "an admin requests, and a second open request is refused" || bad "second: $out"
out=$(q "select public.zella_export_decide('$J', '$SUP', true, null)" 2>&1); [[ "$out" == *NOT_ALLOWED* ]] && ok "a super admin can't approve" || bad "super: $out"
J2=$(q "select public.zella_export_request('$D', '$OWN', 'Dental export')")
out=$(q "select public.zella_export_decide('$J2', '$OWN', true, null)" 2>&1); [[ "$out" == *OWN_REQUEST* ]] && ok "the requester can't approve their own request" || bad "own: $out"
out=$(q "select public.zella_export_decide('$J', '$OWN', false, ' ')" 2>&1); [[ "$out" == *REASON_REQUIRED* ]] && ok "a rejection needs a reason" || bad "reject reason: $out"
[ "$(q "select public.zella_export_decide('$J', '$OWN', true, null)")" = "approved" ] && ok "a Zella Voice owner approves" || bad "approve"
q "update public.platform_admins set role = 'zella_owner' where user_id = '$SUP'" > /dev/null
[ "$(q "select public.zella_export_decide('$J2', '$SUP', true, null)")" = "approved" ] && ok "another owner approves the owner's own request" || bad "approve 2"
c=$(q "select public.zella_export_claim()"); T=$(q "select '$c'::jsonb ->> 'token'"); CJ=$(q "select '$c'::jsonb ->> 'id'")
[ "$CJ" = "$J" ] && [ "$(q "select status from public.business_export_jobs where id = '$J'")" = "running" ] && ok "a claim takes the oldest approved export" || bad "claim: $c"
tabs=$(q "select array_to_string(public.zella_export_tables(), ',')")
[[ ",$tabs," != *",integration_secrets,"* && ",$tabs," != *",crm_record_secrets,"* && ",$tabs," != *",business_export_jobs,"* && ",$tabs," == *",calls,"* ]] && ok "secret tables are never exported" || bad "tables"
rows() { q "select (public.zella_export_rows('$1', '$2', '$3', null, 100) -> 'rows')::text"; }
r=$(rows $J $T calls)
[[ "$r" == *"Caller said hello"* && "$r" != *recording_url* && "$r" != *rec.example* ]] && ok "calls come with transcripts in a plain industry, never with recording links" || bad "calls: $r"
r=$(rows $J $T integrations); [[ "$r" == *'"provider": "test"'* && "$r" != *secret-value* && "$r" != *credentials* ]] && ok "secret columns are left out (the row itself is there)" || bad "integrations: $r"
out=$(q "select public.zella_export_rows('$J', '$T', 'integration_secrets', null, 10)" 2>&1); [[ "$out" == *NOT_EXPORTED* ]] && ok "a secret table can't be asked for" || bad "secret table: $out"
r=$(rows $J $T businesses); [[ "$r" == *"Export Test Studio"* && "$r" != *"Other Studio"* && "$r" != *"Export Dental Studio"* ]] && ok "the business's own row is exported, and no other business's" || bad "businesses: $r"
[[ ",$tabs," == *",businesses,"* ]] && ok "businesses is among the exported tables" || bad "tables: $tabs"
# each table is read from one copy taken for the export the first time it is read: rows changed, added or removed after
# it (read or not yet read) never shift, skip or mix into the pages, across calls and resumed runs
for i in 1 2 3 4 5 6; do q "insert into public.customers (business_id, first_name) values ('$B', 'Copy $i')" > /dev/null; done
p1=$(q "select public.zella_export_rows('$J', '$T', 'customers', null, 3)"); next=$(q "select '$p1'::jsonb ->> 'next'")
q "delete from public.customers where id = (select ('$p1'::jsonb #>> '{rows,0,id}')::uuid)" > /dev/null
q "delete from public.customers where business_id = '$B' and first_name = 'Copy 6'" > /dev/null
q "insert into public.customers (business_id, first_name) values ('$B', 'Added after the copy')" > /dev/null
q "update public.customers set first_name = 'Changed after the copy' where business_id = '$B' and first_name = 'Copy 4'" > /dev/null
p2=$(q "select public.zella_export_rows('$J', '$T', 'customers', '$next', 3)"); n2=$(q "select '$p2'::jsonb ->> 'next'")
p3=$(q "select public.zella_export_rows('$J', '$T', 'customers', '$n2', 3)")
all=$(q "select string_agg(r ->> 'first_name', '|' order by r ->> 'first_name') from (select jsonb_array_elements('$p1'::jsonb -> 'rows') r union all select jsonb_array_elements('$p2'::jsonb -> 'rows') union all select jsonb_array_elements('$p3'::jsonb -> 'rows')) x")
[ "$all" = "Copy 1|Copy 2|Copy 3|Copy 4|Copy 5|Copy 6" ] && [ "$(q "select jsonb_array_length('$p3'::jsonb -> 'rows')::text || coalesce('$p3'::jsonb ->> 'next', 'end')")" = "0end" ] \
  && [ "$(q "select row_count from public.business_export_tables where job_id = '$J' and table_name = 'customers'")" = "6" ] && ok "pages read the export's own copy: later deletes, additions and changes never shift or mix in" || bad "copy: $all"
f=$(q "select public.zella_export_files('$J', '$T')"); [[ "$f" == *"$B/owner_identity/a.pdf"* && "$f" == *"$B/r/b.png"* && "$f" != *"$O/"* ]] && ok "files from both buckets, that business only" || bad "files: $f"
out=$(q "select public.zella_export_rows('$J', gen_random_uuid(), 'calls', null, 10)" 2>&1); [[ "$out" == *NOT_THIS_CLAIM* ]] && [ "$(q "select public.zella_export_progress('$J', gen_random_uuid(), '{}')")" = "f" ] && ok "a stale claim can't read or write" || bad "stale"
q "select public.zella_export_progress('$J', '$T', '{\"tables_done\": [\"calls\"]}')" > /dev/null
# out of time: a pause hands the job back with its progress and gives the try back
[ "$(q "select public.zella_export_pause('$J', '$T', '{\"tables_done\": [\"calls\"], \"cursor\": {\"table\": \"customers\", \"after\": \"x\", \"part\": 1}}')")" = "t" ] \
  && [ "$(q "select status || ',' || attempts || ',' || (progress #>> '{cursor,table}') from public.business_export_jobs where id = '$J'")" = "approved,0,customers" ] && ok "a pause hands the job back with its progress and isn't counted as a try" || bad "pause: $(q "select status || attempts from public.business_export_jobs where id = '$J'")"
for i in 1 2 3 4; do c=$(q "select public.zella_export_claim()"); T=$(q "select '$c'::jsonb ->> 'token'"); q "select public.zella_export_pause('$J', '$T', null)" > /dev/null; done
[ "$(q "select status || ',' || attempts from public.business_export_jobs where id = '$J'")" = "approved,0" ] && ok "four pauses in a row never end it failed" || bad "pauses: $(q "select status || attempts from public.business_export_jobs where id = '$J'")"
c=$(q "select public.zella_export_claim()"); T=$(q "select '$c'::jsonb ->> 'token'")
[ "$(q "select public.zella_export_finish('$J', '$T', false, null, 'storage timeout')")" = "approved" ] && ok "a failure goes back to approved" || bad "retry"
c=$(q "select public.zella_export_claim()"); [ "$(q "select '$c'::jsonb #>> '{progress,tables_done,0}'")" = "calls" ] && ok "and the next claim resumes from its progress" || bad "resume: $c"
T=$(q "select '$c'::jsonb ->> 'token'")
[ "$(q "select count(*) from public.business_export_tables where job_id = '$J'")" -ge 1 ] || bad "no copies before finish"
[ "$(q "select public.zella_export_finish('$J', '$T', true, '$J/manifest.json', null)")" = "ready" ] && [ "$(q "select count(*) from public.business_export_rows where job_id = '$J'")" = "0" ] && [ "$(q "select (expires_at between now() + interval '6 days 23 hours' and now() + interval '7 days 1 minute')::text from public.business_export_jobs where id = '$J'")" = "true" ] && ok "a finish makes it ready for 7 days" || bad "ready"
c=$(q "select public.zella_export_claim()"); T2=$(q "select '$c'::jsonb ->> 'token'")
r=$(rows $J2 $T2 calls); [[ "$r" == *'"direction": "inbound"'* ]] || bad "dental rows missing: $r"; [[ "$r" != *"Caller said hello"* && "$r" != *"A greeting"* ]] && ok "a sensitive industry's transcripts and summaries are left out" || bad "dental: $r"
q "update public.business_export_jobs set claimed_at = now() - interval '1 hour' where id = '$J2'" > /dev/null
q "select public.zella_export_claim()" > /dev/null; q "update public.business_export_jobs set claimed_at = now() - interval '1 hour' where id = '$J2'" > /dev/null; q "select public.zella_export_claim()" > /dev/null
q "update public.business_export_jobs set claimed_at = now() - interval '1 hour' where id = '$J2'" > /dev/null; q "select public.zella_export_claim()" > /dev/null
[ "$(q "select status from public.business_export_jobs where id = '$J2'")" = "failed" ] && ok "an export that stops three times ends failed" || bad "stopped: $(q "select status || attempts from public.business_export_jobs where id = '$J2'")"
a=$(q "select string_agg(action, ',' order by created_at) from public.audit_logs where entity_id = '$J'")
[ "$a" = "export.requested,export.approved,export.ready" ] && ok "each step is audited" || bad "audit: $a"
g=$(q "select bool_or(has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))::text from pg_proc p where proname in ('zella_export_request', 'zella_export_decide', 'zella_export_claim', 'zella_export_progress', 'zella_export_finish', 'zella_export_tables', 'zella_export_rows', 'zella_export_files')")
[ "$g" = "false" ] && ok "only the server may call the export functions" || bad "grants: $g"
out=$("${P[@]}" -d $DB -f "$RB" 2>&1); [[ "$out" == *EXPORTS_EXIST* ]] && ok "the rollback refuses while an export is ready" || bad "rollback guard: $out"
q "update public.business_export_jobs set expires_at = now() - interval '1 minute' where id = '$J'" > /dev/null; q "select public.zella_export_claim()" > /dev/null
[ "$(q "select status from public.business_export_jobs where id = '$J'")" = "expired" ] && ok "a ready export past 7 days expires" || bad "expire"
# an approved export (it would resume from saved progress) when the rollback runs: it is ended, its request kept
JA=$(q "select public.zella_export_request('$O', '$ADM', 'Approved before the rollback')"); q "select public.zella_export_decide('$JA', '$OWN', true, null)" > /dev/null
q "update public.business_export_jobs set progress = '{\"tables_done\": [\"calls\"], \"parts\": [\"x\"]}' where id = '$JA'" > /dev/null
out=$("$REPO/sql/rollback/run.sh" "$RB" -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -d $DB -q 2>&1) && "$REPO/sql/rollback/run.sh" "$RB" -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -d $DB -q > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback: $(echo "$out" | grep ERROR)"
[ "$(q "select status || ',' || progress::text || ',' || request_reason from public.business_export_jobs where id = '$JA'")" = "failed,{},Approved before the rollback" ] && ok "a resumable export is ended by the rollback (no stale progress), its request kept" || bad "retired: $(q "select status || progress::text from public.business_export_jobs where id = '$JA'")"
# with no exports at all, the rollback drops the table, and runs again
E="${DB}_empty"; "${P[@]}" -d postgres -c "drop database if exists $E" -c "create database $E template $TEMPLATE" > /dev/null
"${P[@]}" -d $E -f "$MIG" > /dev/null 2>&1; RBE=("$REPO/sql/rollback/run.sh" "$RB" -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -d $E -q)
"${RBE[@]}" > /dev/null 2>&1 && "${RBE[@]}" > /dev/null 2>&1 && [ -z "$("${P[@]}" -d $E -c "select to_regclass('public.business_export_jobs')")" ] && ok "with no exports, the rollback drops the table and runs again" || bad "empty rollback twice"
"${P[@]}" -d postgres -c "drop database if exists $E" > /dev/null
[ "$(q "select count(*) from pg_proc where proname in ('zella_export_request', 'zella_export_decide', 'zella_export_claim', 'zella_export_progress', 'zella_export_pause', 'zella_export_finish', 'zella_export_tables', 'zella_export_rows', 'zella_export_files')")$(q "select count(*) from storage.buckets where id = 'business-exports'")" = "00" ] && ok "rollback removes the functions and the bucket" || bad "after rollback"
[ "$(q "select count(*) || ',' || count(*) filter (where request_reason = 'Owner asked for a copy') from public.business_export_jobs")" = "3,1" ] && ok "and keeps every export record, with who asked and why" || bad "records: $(q "select count(*) from public.business_export_jobs")"
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_export_claim() returns jsonb language sql as \$f\$ select null::jsonb \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$MIG" 2>&1); [[ "$out" == *VERSION_MISMATCH* ]] && ok "a changed function stops the file" || bad "drift: $out"
out=$("${P[@]}" -d $DB -f "$RB" 2>&1); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "and stops the rollback" || bad "rollback drift: $out"
echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
