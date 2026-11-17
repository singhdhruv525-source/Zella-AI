#!/usr/bin/env bash
# sql/zella_business_purge.sql on an ISOLATED copy of the production schema (never production). Made up businesses
# only. Checks: before, nothing can purge a cancelled business and a delete by hand would erase its audit history (the
# gap); applies, applies again, and rolls back twice before any run; a purge can't be asked for while the period is
# pending legal review, without a recorded final export offer, or for a business not past its retention date or on a
# legal hold; every guard refuses in turn (someone who didn't approve, the switch off, the wrong name, the audit history
# at risk until lane B's sql/zella_draft_delete.sql is applied, which keeps a deleted business's audit rows and makes
# audit_logs.business_id ON DELETE SET NULL (ACC-10, the owner's decision of 16 Nov 2026), an export offer under 14 days old, billing
# records, phone numbers still assigned); the purge deletes the business and what belongs to it, keeps its audit rows
# and a purge record, hands over its storage files and records them; every step is audited; nothing is scheduled;
# signed in people and anonymous can't call it; the rollback refuses once a purge ran or a function changed.
# Lane B's sql/zella_draft_delete.sql is read from this repository, or from its branch until it is merged.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zlg_business_purge}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "set client_min_messages = warning" -c "$1"; }
# production's functions: the writing cleanup, then the merged migrations not applied yet (docs/SCHEMA_STATUS.md)
for f in zella_writing_cleanup zella_cancellations_scheduled zella_admin_permissions zella_admin_mfa zella_support_notes zella_status_honest zella_retry_event_safe; do
  "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { bad "$f"; exit 1; }
done
for f in zella_number_orders zella_recording_policy zella_data_retention zella_retention_purge; do "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { bad "$f"; exit 1; }; done
DRAFT_DELETE="$REPO/sql/zella_draft_delete.sql"
if [ ! -f "$DRAFT_DELETE" ]; then
  DRAFT_DELETE=$(mktemp); git -C "$REPO" show origin/claude/lane-b-draft-delete:sql/zella_draft_delete.sql > "$DRAFT_DELETE" 2>/dev/null || { bad "lane B's sql/zella_draft_delete.sql is not available"; exit 1; }
fi
OWNER=e6000000-0000-0000-0000-000000000001; SEC=e6000000-0000-0000-0000-000000000002; RO=e6000000-0000-0000-0000-000000000003; MEMBER=e6000000-0000-0000-0000-000000000004
C=e6000000-0000-0000-0000-0000000000c1; PAY=e6000000-0000-0000-0000-0000000000c2; R=e6000000-0000-0000-0000-0000000000c3; H=e6000000-0000-0000-0000-0000000000c4; A=e6000000-0000-0000-0000-0000000000a1
q "insert into auth.users (id, email, email_confirmed_at) values ('$OWNER', 'owner@bp.test', now()), ('$SEC', 'sec@bp.test', now()), ('$RO', 'readonly@bp.test', now()), ('$MEMBER', 'member@bp.test', now());
   insert into public.platform_admins (user_id, role) values ('$OWNER', 'zella_owner'), ('$SEC', 'security_admin'), ('$RO', 'read_only_admin');
   insert into public.platform_role_permissions (role, permission) values ('security_admin', 'security.manage'), ('security_admin', 'security.view'), ('read_only_admin', 'security.view') on conflict do nothing;
   insert into public.businesses (id, name, is_active) values ('$C', 'Closed Test Salon', false), ('$PAY', 'Paid Test Salon', false), ('$R', 'Recent Test Salon', false), ('$H', 'Held Test Salon', false), ('$A', 'Active Test Salon', true);
   update public.businesses set cancelled_at = now() - interval '120 days' where id in ('$C', '$PAY', '$H');
   update public.businesses set cancelled_at = now() - interval '10 days' where id = '$R';
   insert into public.calls (business_id, direction, status, created_at, transcript) values ('$C', 'inbound', 'completed', now() - interval '130 days', 'Closed salon call words'), ('$A', 'inbound', 'completed', now(), 'Active call');
   insert into public.sms_messages (business_id, direction, message_body) values ('$C', 'outbound', 'Closed salon text');
   insert into public.audit_logs (business_id, action) values ('$C', 'test.closed_history'), ('$C', 'test.closed_history');
   insert into public.business_verification_documents (business_id, kind, file_path, file_name, mime_type, size_bytes) values ('$C', 'owner_identity', '$C/id.png', 'id.png', 'image/png', 10);
   insert into storage.objects (bucket_id, name) values ('brand-assets', '$C/logo.png'), ('brand-assets', '$A/logo.png');
   insert into public.payments (business_id, amount) values ('$PAY', 10)" > /dev/null || exit 1
srv() { "${P[@]}" -d $DB -c "set client_min_messages = warning" -c "set role service_role" -c "$1" 2>&1 | head -1; }
as() { local role=authenticated; [ -z "$1" ] && role=anon
  "${P[@]}" -d $DB -c "set role $role" -c "select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"$role\"}', false)" -c "$2" 2>&1 | sed -n 2p; }
req() { srv "select public.zella_business_purge_request('$1', '$2', now() - interval '${3:-20} days', '${4:-Emailed the owner the export link}', 'Past its retention date') ->> 'id'"; }
appr() { srv "select public.zella_retention_run_approve('$1', '$2', 'Checked it') ->> 'status'"; }
exe() { srv "select public.zella_business_purge_execute('$1', '$2', '$3') ->> '${4:-status}'"; }

v=$(q "select to_regprocedure('public.zella_business_purge_execute(uuid,uuid,text)') is null and (select confdeltype from pg_constraint where conname = 'audit_logs_business_id_fkey') = 'c'")
[ "$v" = "t" ] && ok "before: nothing purges a cancelled business, and a delete by hand would erase its audit history (the gap)" || bad "before: $v"
"${P[@]}" -d $DB -f "$REPO/sql/zella_business_purge.sql" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$REPO/sql/zella_business_purge.sql" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$REPO/sql/zella_business_purge.sql" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"
"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_business_purge_rollback.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_business_purge_rollback.sql" > /dev/null 2>&1 \
  && [ "$(q "select to_regprocedure('public.zella_business_purge_execute(uuid,uuid,text)') is null and to_regclass('public.retention_purge_runs') is not null")" = "t" ] && ok "before any run, the rollback runs twice and removes only this file's functions" || bad "early rollback"
"${P[@]}" -d $DB -f "$REPO/sql/zella_business_purge.sql" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_retention_purge_rollback.sql" 2>&1); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "the purge runs rollback refuses while this file uses them" || bad "g4 rollback: $out"

# request
[[ "$(req $SEC $C)" == *LEGAL_REVIEW_PENDING* ]] && ok "a business purge can't be asked for while its period is pending legal review" || bad "pending"
srv "select public.zella_retention_policy_set('$OWNER', 'cancelled_business', 30, 'approved', 'Counsel approved 30 days')" > /dev/null
[[ "$(req $RO $C)" == *NOT_ALLOWED* ]] && ok "security.view alone can't ask" || bad "ro"
[[ "$(req $MEMBER $C)" == *NOT_ALLOWED* ]] && ok "someone who isn't an admin can't ask" || bad "member"
[[ "$(srv "select public.zella_business_purge_request('$SEC', '$C', null, 'Emailed', 'Past its date')")" == *EXPORT_OFFER_REQUIRED* ]] && ok "the final export offer must be recorded" || bad "no offer"
[[ "$(req $SEC $C 20 x)" == *EXPORT_OFFER_REQUIRED* ]] && ok "with how it was offered" || bad "no offer note"
[[ "$(srv "select public.zella_business_purge_request('$SEC', '$C', now() + interval '1 day', 'Will email', 'Past its date')")" == *EXPORT_OFFER_REQUIRED* ]] && ok "and not in the future" || bad "future offer"
[[ "$(req $SEC $R)" == *NOT_PAST_RETENTION* ]] && ok "a business cancelled 10 days ago is refused" || bad "recent"
[[ "$(req $SEC $A)" == *NOT_PAST_RETENTION* ]] && ok "an active business is refused" || bad "active"
srv "select public.zella_legal_hold_place('$SEC', '$H', 'Counsel asked to keep it')" > /dev/null
[[ "$(req $SEC $H)" == *NOT_PAST_RETENTION* ]] && ok "a business on a legal hold is refused" || bad "held"
[[ "$(q "delete from public.businesses where id = '$H'" 2>&1)" == *"violates foreign key"* ]] && ok "and can't be deleted by hand either" || bad "held deleted"
RUN=$(req $SEC $C); [ -n "$RUN" ] && [[ "$RUN" != *ERROR* ]] && ok "security.manage asks to purge a cancelled business past its retention date" || bad "request: $RUN"
[[ "$(req $SEC $C)" == *RUN_OPEN* ]] && ok "one open purge per business" || bad "two runs"
RUNP=$(req $SEC $PAY 3)

# approvals (the shared two person rule)
[[ "$(exe $SEC $RUN "Closed Test Salon")" == *APPROVER_REQUIRED* ]] && ok "nobody can run it before approving it" || bad "early exec"
appr $SEC $RUN > /dev/null; [[ "$(appr $SEC $RUN)" == *ALREADY_APPROVED* ]] && ok "the same person can't approve twice" || bad "double"
[ "$(appr $OWNER $RUN)" = "approved" ] && ok "a Zella Voice owner completes the two approvals" || bad "approve"
appr $SEC $RUNP > /dev/null; appr $OWNER $RUNP > /dev/null

# execute guards
[[ "$(exe $RO $RUN "Closed Test Salon")" == *APPROVER_REQUIRED* ]] && ok "someone who didn't approve can't run it" || bad "non approver"
[[ "$(exe $OWNER $RUN "Closed Test Salon")" == *PURGE_SWITCHED_OFF* ]] && ok "refused while purges are switched off" || bad "switch"
srv "select public.zella_retention_switch_set('$OWNER', true, 'For the test')" > /dev/null
[[ "$(srv "select public.zella_retention_run_execute('$OWNER', '$RUN', 'PURGE 1')")" == *BUSINESS_PURGE_SEPARATE* ]] && ok "the record purge can't run a business purge" || bad "wrong runner"
[[ "$(exe $OWNER $RUN "closed test salon")" == *CONFIRM_MISMATCH* ]] && ok "the business's name must be typed exactly" || bad "name"
[[ "$(exe $OWNER $RUN "Closed Test Salon")" == *AUDIT_HISTORY_AT_RISK* ]] && ok "refused while deleting would erase its audit history (ACC-10 not applied)" || bad "audit fk"
"${P[@]}" -d $DB -f "$DRAFT_DELETE" > /dev/null 2>&1 && ok "lane B's sql/zella_draft_delete.sql applies (the audit trigger keeps a deleted business's rows)" || { bad "draft delete"; "${P[@]}" -d $DB -f "$DRAFT_DELETE" 2>&1 | tail -2; }
[ "$(q "select confdeltype from pg_constraint where conrelid = 'public.audit_logs'::regclass and conname = 'audit_logs_business_id_fkey'")" = n ] \
  && ok "after it, audit_logs.business_id is ON DELETE SET NULL (ACC-10, the owner's decision of 16 Nov 2026)" || bad "audit fk set null"
[[ "$(exe $OWNER $RUNP "Paid Test Salon")" == *EXPORT_OFFER_TOO_RECENT* ]] && ok "refused until 14 days after the export offer" || bad "too recent"
q "update public.retention_purge_runs set export_offered_at = now() - interval '20 days' where id = '$RUNP'" > /dev/null
[[ "$(exe $OWNER $RUNP "Paid Test Salon")" == *BILLING_RECORDS_KEPT* ]] && ok "refused while it has payment records (their retention is a legal decision not taken)" || bad "billing"
q "insert into public.business_phone_numbers (business_id, e164, status) values ('$C', '+15550109999', 'paused')" > /dev/null
[[ "$(exe $OWNER $RUN "Closed Test Salon")" == *NUMBERS_STILL_ASSIGNED* ]] && ok "refused while a phone number is still assigned" || bad "numbers"
q "delete from public.business_phone_numbers where business_id = '$C'" > /dev/null
[ "$(q "select count(*) from public.businesses where id = '$C'")" = "1" ] && ok "no refused attempt deleted anything" || bad "deleted on refusal"

# execute
OLD=$(q "select count(*) from public.audit_logs where business_id = '$C'")
[ "$(exe $OWNER $RUN "Closed Test Salon")" = "files_pending" ] && ok "an approver runs it with the name typed" || bad "execute"
v=$(q "select (select count(*) from public.businesses where id = '$C') || '/' || (select count(*) from public.calls where business_id = '$C') || '/' || (select count(*) from public.sms_messages where business_id = '$C') || '/' || (select count(*) from public.business_verification_documents where business_id = '$C')")
[ "$v" = "0/0/0/0" ] && ok "the business and everything that belongs to it are gone" || bad "left: $v"
[ "$(q "select count(*) from public.businesses where id in ('$A', '$PAY', '$R', '$H')")/$(q "select count(*) from public.calls where business_id = '$A'")" = "4/1" ] && ok "no other business was touched" || bad "others touched"
[ "$(q "select count(*) from public.audit_logs where action = 'test.closed_history' and business_id is null")" = "2" ] && ok "its audit history stays (business id cleared)" || bad "audit history lost"
v=$(q "select user_id || '|' || (old_data ->> 'name') from public.audit_logs where action = 'business.purged' and entity_id = '$C'")
[ "$v" = "$OWNER|Closed Test Salon" ] && ok "the purge is audited with who ran it and the business's name" || bad "purge audit: $v"
[ "$(q "select array_to_string(file_paths, ',') from public.retention_purge_runs where id = '$RUN'")" = "brand-assets/$C/logo.png,business-documents/$C/id.png" ] && ok "its storage files, and only its, are handed to the server" || bad "paths"
[[ "$(srv "select public.zella_business_purge_files_done('$SEC', '$RUN', array['brand-assets/$C/logo.png'], null)")" == *APPROVER_REQUIRED* ]] && ok "only the person who ran it records the files" || bad "files other"
[ "$(srv "select public.zella_business_purge_files_done('$OWNER', '$RUN', array['brand-assets/$C/logo.png', 'business-documents/$C/id.png', 'brand-assets/$A/logo.png'], null) ->> 'files_removed'")" = "2" ] && ok "the removed files are recorded; a path the run didn't list isn't counted" || bad "files done"
v=$(q "select string_agg(action, ',' order by created_at, action) from public.audit_logs where entity_id = '$RUN'")
[ "$v" = "business.purge_requested,retention.purge_approved,retention.purge_approved,business.purge_files_removed" ] && ok "every step of the run is audited" || bad "steps: $v"
[ "$(q "select count(*) from cron.job where command ilike '%purge%'")" = "0" ] && ok "nothing is scheduled" || bad "scheduled"
for fn in "zella_business_purge_request('$SEC', '$R', now(), 'x', 'Direct')" "zella_business_purge_execute('$OWNER', '$RUNP', 'Paid Test Salon')" "zella_business_purge_files_done('$OWNER', '$RUN', null, null)"; do
  [[ "$(as $OWNER "select public.$fn")" == *"permission denied"* ]] || { bad "a signed in owner could call $fn directly"; continue; }
  [[ "$(as "" "select public.$fn")" == *"permission denied"* ]] || bad "anonymous could call $fn"
done && ok "signed in people (even an owner) and anonymous can't call the functions directly"

out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_business_purge_rollback.sql" 2>&1); [[ "$out" == *"business purge has run"* ]] && ok "the rollback refuses once a business purge ran" || bad "rollback after run: $out"
q "create or replace function public.zella_business_purge_files_done(p_actor uuid, p_run uuid, p_removed text[], p_error text) returns jsonb language sql as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_business_purge_rollback.sql" 2>&1); [[ "$out" == *"has changed"* ]] && ok "the rollback refuses a changed function" || bad "rollback drift: $out"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_business_purge.sql" 2>&1); [[ "$out" == *VERSION_MISMATCH* ]] && ok "a changed function stops the file" || bad "drift: $out"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
