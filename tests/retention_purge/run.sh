#!/usr/bin/env bash
# sql/zella_retention_purge.sql on an ISOLATED copy of the production schema (never production). Test people and made up
# rows only. Checks: before, nothing can remove data past its period (the gap); applies (after the earlier lane G
# files), applies again, and rolls back twice before any run; a run can't be asked for while the period is pending
# legal review; every guard refuses in turn: a role without security.manage, the same person approving twice, two
# approvals without an owner, someone who didn't approve, the switch off, the wrong typed confirmation, legal approval
# withdrawn; rows that went on a legal hold or appeared later are left alone; the purge removes only the listed words,
# leaves the rows and sets off no callbacks, usage or insights; document files are handed over and recorded, the
# document rows stay; every step is audited; nothing is scheduled; signed in people and anonymous can't call it; the
# rollback refuses once a purge ran or a function changed; a changed function stops the file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zlg_retention_purge}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "set client_min_messages = warning" -c "$1"; }
# production's functions: the writing cleanup, then the merged migrations not applied yet (docs/SCHEMA_STATUS.md)
for f in zella_writing_cleanup zella_cancellations_scheduled zella_admin_permissions zella_admin_mfa zella_support_notes zella_status_honest zella_retry_event_safe; do
  "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { bad "$f"; exit 1; }
done
for f in zella_number_orders zella_recording_policy zella_data_retention; do "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { bad "$f"; exit 1; }; done
OWNER=e5000000-0000-0000-0000-000000000001; SEC=e5000000-0000-0000-0000-000000000002; RO=e5000000-0000-0000-0000-000000000003
MEMBER=e5000000-0000-0000-0000-000000000004; SUPER=e5000000-0000-0000-0000-000000000005; OWNER2=e5000000-0000-0000-0000-000000000006
A=e5000000-0000-0000-0000-0000000000a1; H=e5000000-0000-0000-0000-0000000000d1
q "insert into auth.users (id, email, email_confirmed_at) values ('$OWNER', 'owner@purge.test', now()), ('$SEC', 'sec@purge.test', now()), ('$RO', 'readonly@purge.test', now()),
     ('$MEMBER', 'member@purge.test', now()), ('$SUPER', 'super@purge.test', now()), ('$OWNER2', 'owner2@purge.test', now());
   insert into public.platform_admins (user_id, role) values ('$OWNER', 'zella_owner'), ('$SEC', 'security_admin'), ('$RO', 'read_only_admin'), ('$SUPER', 'super_admin'), ('$OWNER2', 'zella_owner');
   insert into public.platform_role_permissions (role, permission) values ('security_admin', 'security.manage'), ('security_admin', 'security.view'),
     ('read_only_admin', 'security.view') on conflict do nothing;
   insert into public.businesses (id, name) values ('$A', 'Purge Test Business'), ('$H', 'Held Purge Test');
   insert into public.calls (id, business_id, direction, status, created_at, ended_at, recording_url, transcript, duration_seconds, ai_handled) values
     ('e5000000-0000-0000-0000-00000000ca01', '$A', 'inbound', 'completed', now() - interval '100 days', now() - interval '100 days', 'https://rec.test/1', 'Old transcript words', 3, true),
     ('e5000000-0000-0000-0000-00000000ca02', '$A', 'inbound', 'completed', now() - interval '2 days', now() - interval '2 days', 'https://rec.test/2', 'New transcript words', 90, true),
     ('e5000000-0000-0000-0000-00000000ca04', '$H', 'inbound', 'completed', now() - interval '100 days', now() - interval '100 days', 'https://rec.test/4', 'Held transcript words', 90, true);
   insert into public.sms_messages (id, business_id, direction, message_body, created_at) values
     ('e5000000-0000-0000-0000-00000000aa01', '$A', 'outbound', 'Old text', now() - interval '800 days'), ('e5000000-0000-0000-0000-00000000aa02', '$A', 'outbound', 'New text', now() - interval '10 days');
   insert into public.audit_logs (id, action, created_at) values ('e5000000-0000-0000-0000-00000000ad01', 'test.old', now() - interval '3000 days'), ('e5000000-0000-0000-0000-00000000ad02', 'test.recent', now() - interval '30 days');
   insert into public.business_verification_documents (id, business_id, kind, file_path, file_name, mime_type, size_bytes, status, updated_at) values
     ('e5000000-0000-0000-0000-00000000d001', '$A', 'business_registration', '$A/old.pdf', 'old.pdf', 'application/pdf', 10, 'replaced', now() - interval '40 days'),
     ('e5000000-0000-0000-0000-00000000d002', '$A', 'business_registration', '$A/new.pdf', 'new.pdf', 'application/pdf', 10, 'verified', now() - interval '40 days')" > /dev/null || exit 1
srv() { "${P[@]}" -d $DB -c "set client_min_messages = warning" -c "set role service_role" -c "$1" 2>&1 | head -1; }
as() { local role=authenticated; [ -z "$1" ] && role=anon
  "${P[@]}" -d $DB -c "set role $role" -c "select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"$role\"}', false)" -c "$2" 2>&1 | sed -n 2p; }
policy() { srv "select public.zella_retention_policy_set('$OWNER', '$1', $2, '$3', 'Counsel decision for the test') ->> 'legal_status'" > /dev/null; }
switch() { srv "select public.zella_retention_switch_set('$OWNER', $1, 'Switch for the test')" > /dev/null; }
req() { srv "select public.zella_retention_run_request('$1', '$2', '${3:-Past its period}') ->> '${4:-id}'"; }
appr() { srv "select public.zella_retention_run_approve('$1', '$2', 'Checked the dry run') ->> 'status'"; }
exe() { srv "select public.zella_retention_run_execute('$1', '$2', '$3') ->> '${4:-status}'"; }
side() { q "select (select count(*) from public.callbacks) || '/' || (select count(*) from public.call_insights) || '/' || (select count(*) from public.usage_records)"; }

v=$(q "select to_regprocedure('public.zella_retention_run_execute(uuid,uuid,text)') is null"); [ "$v" = "t" ] && ok "before: nothing can remove data past its period (the gap)" || bad "before: $v"
"${P[@]}" -d $DB -f "$REPO/sql/zella_retention_purge.sql" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$REPO/sql/zella_retention_purge.sql" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$REPO/sql/zella_retention_purge.sql" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"
"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_retention_purge_rollback.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_retention_purge_rollback.sql" > /dev/null 2>&1 \
  && [ "$(q "select to_regclass('public.retention_purge_runs') is not null and to_regprocedure('public.zella_retention_run_execute(uuid,uuid,text)') is null and to_regclass('public.retention_removed_files') is not null")" = "t" ] \
  && ok "before any run, the rollback runs twice and removes only this file's objects" || bad "early rollback"
"${P[@]}" -d $DB -f "$REPO/sql/zella_retention_purge.sql" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_data_retention_rollback.sql" 2>&1); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "the retention periods rollback refuses while the purge uses them" || bad "g3 rollback: $out"

# request
[[ "$(req $SEC call_transcripts)" == *LEGAL_REVIEW_PENDING* ]] && ok "a run can't be asked for while the period is pending legal review" || bad "pending"
policy call_transcripts 90 approved
[[ "$(req $RO call_transcripts)" == *NOT_ALLOWED* ]] && ok "security.view alone can't ask for a run" || bad "ro request"
[[ "$(req $MEMBER call_transcripts)" == *NOT_ALLOWED* ]] && ok "someone who isn't an admin can't either" || bad "member request"
[[ "$(req $SEC call_transcripts x)" == *REASON_REQUIRED* ]] && ok "a reason is required" || bad "reason"
[[ "$(req $SEC cancelled_business)" == *BUSINESS_PURGE_SEPARATE* ]] && ok "whole businesses are not purged here" || bad "business here"
RUN=$(req $SEC call_transcripts); [ -n "$RUN" ] && ok "security.manage asks for a run" || bad "request"
[ "$(q "select item_count from public.retention_purge_runs where id = '$RUN'")" = "2" ] && ok "the run holds the exact rows the dry run listed" || bad "items"
[[ "$(req $SEC call_transcripts)" == *RUN_OPEN* ]] && ok "one open run per kind" || bad "two runs"

# approvals
[[ "$(exe $OWNER $RUN "PURGE 2")" == *APPROVER_REQUIRED* ]] && ok "nobody can run it before approving it" || bad "exec before approval"
[ "$(appr $SEC $RUN)" = "requested" ] && ok "the person who asked may be one of the two" || bad "first approval"
[[ "$(appr $SEC $RUN)" == *ALREADY_APPROVED* ]] && ok "the same person can't approve twice" || bad "double approval"
[[ "$(appr $SUPER $RUN)" == *OWNER_REQUIRED* ]] && ok "two approvals without a Zella Voice owner are not enough" || bad "no owner"
[[ "$(appr $RO $RUN)" == *NOT_ALLOWED* ]] && ok "security.view alone can't approve" || bad "ro approve"
[ "$(appr $OWNER $RUN)" = "approved" ] && ok "a Zella Voice owner's approval completes it" || bad "owner approval"

# execute guards
[[ "$(exe $SUPER $RUN "PURGE 2")" == *APPROVER_REQUIRED* ]] && ok "someone who didn't approve can't run it" || bad "non approver"
[[ "$(exe $OWNER $RUN "PURGE 2")" == *PURGE_SWITCHED_OFF* ]] && ok "it is refused while purges are switched off" || bad "switch off"
switch true
[[ "$(exe $OWNER $RUN "PURGE 3")" == *CONFIRM_MISMATCH* ]] && ok "the typed confirmation must name the number of rows" || bad "confirm"
[[ "$(exe $OWNER $RUN "")" == *CONFIRM_MISMATCH* ]] && ok "and can't be left out" || bad "no confirm"
policy call_transcripts 90 pending_legal_review
[[ "$(exe $OWNER $RUN "PURGE 2")" == *LEGAL_REVIEW_PENDING* ]] && ok "it is refused if legal approval was withdrawn after the approvals" || bad "legal withdrawn"
policy call_transcripts 90 approved
[ "$(q "select count(*) from public.calls where transcript is null")" = "0" ] && ok "no refused attempt removed anything" || bad "removed on refusal"

# execute
srv "select public.zella_legal_hold_place('$SEC', '$H', 'Counsel asked to keep everything')" > /dev/null
q "insert into public.calls (id, business_id, direction, status, created_at, ended_at, transcript) values ('e5000000-0000-0000-0000-00000000ca05', '$A', 'inbound', 'completed', now() - interval '200 days', now() - interval '200 days', 'Appeared later words')" > /dev/null
s0=$(side)
[ "$(exe $OWNER $RUN "PURGE 2" removed_count)" = "1" ] && ok "an approver runs it with the typed confirmation" || bad "execute"
v=$(q "select string_agg(id::text || ':' || coalesce(transcript, 'none') || ':' || coalesce(recording_url, 'none'), ',' order by id) from public.calls")
[ "$v" = "e5000000-0000-0000-0000-00000000ca01:Removed under the retention policy.:https://rec.test/1,e5000000-0000-0000-0000-00000000ca02:New transcript words:https://rec.test/2,e5000000-0000-0000-0000-00000000ca04:Held transcript words:https://rec.test/4,e5000000-0000-0000-0000-00000000ca05:Appeared later words:none" ] \
  && ok "only the listed old transcript went; the call, its recording, the new call, the held business and a row that appeared later stayed" || bad "calls: $v"
[ "$(side)/$(q "select status from public.calls where id = 'e5000000-0000-0000-0000-00000000ca01'")" = "$s0/completed" ] && ok "removing it set off no callback, insight or usage, and the short old call is still completed, not missed" || bad "side effects: $s0 -> $(side)"
[[ "$(exe $OWNER $RUN "PURGE 2")" == *NOT_APPROVED* ]] && ok "a run can't be run twice" || bad "twice"
v=$(q "select string_agg(action || ':' || user_id, ',' order by created_at, action) from public.audit_logs where entity_id = '$RUN'")
[ "$v" = "retention.purge_requested:$SEC,retention.purge_approved:$SEC,retention.purge_approved:$OWNER,retention.purge_executed:$OWNER" ] && ok "every step is audited with who did it" || bad "audit: $v"
[[ "$(q "select new_data::text from public.audit_logs where entity_id = '$RUN'")" != *"transcript words"* ]] && ok "the audit holds counts, never the words" || bad "content in audit"

# message words and audit rows
policy message_bodies 730 approved; R2=$(req $SEC message_bodies); appr $OWNER $R2 > /dev/null; appr $SUPER $R2 > /dev/null
[ "$(exe $SUPER $R2 "PURGE 1")" = "done" ] && [ "$(q "select coalesce(message_body, 'none') from public.sms_messages order by created_at")" = "$(printf 'none\nNew text')" ] \
  && ok "message words: the old text's words are removed, the text record and the new text stay" || bad "bodies"
policy audit_logs 2555 approved; R3=$(req $SEC audit_logs); appr $OWNER2 $R3 > /dev/null; appr $OWNER $R3 > /dev/null
[ "$(exe $OWNER2 $R3 "PURGE 1")" = "done" ] && [ "$(q "select string_agg(action, ',') from public.audit_logs where action like 'test.%'")" = "test.recent" ] \
  && ok "audit rows: two owners may be the two people; only the row older than 7 years goes" || bad "audit purge"

# documents
policy documents_replaced 30 approved; R4=$(req $SEC documents_replaced); appr $OWNER $R4 > /dev/null; appr $SUPER $R4 > /dev/null
[ "$(exe $SUPER $R4 "PURGE 1")" = "files_pending" ] && [ "$(q "select array_to_string(file_paths, ',') from public.retention_purge_runs where id = '$R4'")" = "$A/old.pdf" ] \
  && ok "documents: only the replaced copy's file is handed to the server to remove" || bad "documents"
[[ "$(srv "select public.zella_legal_hold_place('$SEC', '$A', 'Counsel asked mid removal')")" == *PURGE_IN_PROGRESS* ]] && ok "a hold can't be placed on a business while a run is removing its files" || bad "hold during removal"
[ "$(srv "select public.zella_retention_run_files_done('$SUPER', '$R4', array[]::text[], 'Storage timed out') ->> 'status'")" = "failed" ] && ok "a stopped removal is recorded as failed" || bad "files failed"
[[ "$(srv "select public.zella_retention_run_files_resume('$SEC', '$R4')")" == *APPROVER_REQUIRED* ]] && ok "only the person who ran it or an approver resumes it" || bad "resume by other"
[ "$(srv "select array_to_string(public.zella_retention_run_files_resume('$OWNER', '$R4'), ',')")/$(q "select status from public.retention_purge_runs where id = '$R4'")" = "$A/old.pdf/files_pending" ] \
  && ok "an approver resumes it: the files still to remove are handed back and the run is pending again" || bad "resume"
[[ "$(srv "select public.zella_retention_run_files_done('$SEC', '$R4', array['$A/old.pdf'], null)")" == *APPROVER_REQUIRED* ]] && ok "only the person who ran it or an approver records the files" || bad "files by other"
[ "$(srv "select public.zella_retention_run_files_done('$SUPER', '$R4', array['$A/old.pdf', '$A/new.pdf'], null) ->> 'status'")" = "done" ] && ok "the removed file is recorded and the run is done" || bad "files done"
[ "$(q "select count(*) from public.retention_removed_files")/$(q "select count(*) from public.business_verification_documents")" = "1/2" ] \
  && ok "a file the run didn't list is never recorded, and the document rows (the outcome) stay" || bad "removed files"
[ "$(srv "select public.zella_retention_preview('$RO', 'documents_replaced', 5) ->> 'count'")" = "0" ] && ok "the dry run no longer lists it" || bad "dry run after"

# the period is checked again when the run runs
policy call_recordings 30 approved; R5=$(req $SEC call_recordings); appr $OWNER $R5 > /dev/null; appr $SUPER $R5 > /dev/null
n5=$(q "select item_count from public.retention_purge_runs where id = '$R5'")
policy call_recordings 3650 approved
[ "${n5:-0}" -ge 1 ] && [ "$(exe $SUPER $R5 "PURGE $n5" removed_count)" = "0" ] \
  && [ "$(q "select recording_url from public.calls where id = 'e5000000-0000-0000-0000-00000000ca01'")" = "https://rec.test/1" ] \
  && ok "a period made longer after the approvals keeps the rows it now protects" || bad "longer period: $(exe $SUPER $R5 "PURGE $n5")"
policy call_recordings 30 approved

# cancel, direct access, schedule
switch false; policy documents_owner_id_verified 90 approved
[[ "$(req $SEC documents_owner_id_verified)" == *NOTHING_TO_PURGE* ]] && ok "a run with nothing past its period is refused" || bad "empty run"
policy call_recordings 30 approved; R6=$(req $SEC call_recordings)
[[ "$(srv "select public.zella_retention_run_cancel('$RO', '$R6', 'No')")" == *NOT_ALLOWED* ]] && ok "security.view can't cancel" || bad "ro cancel"
[ "$(srv "select public.zella_retention_run_cancel('$SEC', '$R6', 'Not now') ->> 'status'")" = "cancelled" ] && ok "a run is cancelled before it runs" || bad "cancel"
[ "$(srv "select jsonb_array_length(public.zella_retention_runs('$RO', 50))")" = "6" ] && ok "every run is listed for security.view" || bad "list"
[ "$(q "select count(*) from cron.job where command ilike '%retention%' or command ilike '%purge%'")" = "0" ] && ok "nothing is scheduled" || bad "scheduled"
for fn in "zella_retention_run_request('$SEC', 'audit_logs', 'Direct')" "zella_retention_run_approve('$OWNER', '$R6', 'Direct')" "zella_retention_run_execute('$OWNER', '$RUN', 'PURGE 2')" "zella_retention_run_files_done('$SUPER', '$R4', null, null)"; do
  [[ "$(as $OWNER "select public.$fn")" == *"permission denied"* ]] || { bad "a signed in owner could call $fn directly"; continue; }
  [[ "$(as "" "select public.$fn")" == *"permission denied"* ]] || bad "anonymous could call $fn"
done && ok "signed in people (even an owner) and anonymous can't call the functions directly"
[[ "$(as $OWNER "select count(*) from public.retention_purge_runs")" == *"permission denied"* ]] && ok "the runs can't be read directly" || bad "table readable"

# rollback after a purge
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_retention_purge_rollback.sql" 2>&1); [[ "$out" == *"a purge has run"* ]] && ok "the rollback refuses once a purge ran" || bad "rollback after run: $out"
q "create or replace function public.zella_retention_runs(p_actor uuid, p_limit integer default 50) returns jsonb language sql as \$f\$ select '[]'::jsonb \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_retention_purge_rollback.sql" 2>&1); [[ "$out" == *"has changed"* ]] && ok "the rollback refuses a changed function" || bad "rollback drift: $out"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_retention_purge.sql" 2>&1); [[ "$out" == *VERSION_MISMATCH* ]] && ok "a changed function stops the file" || bad "drift: $out"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
