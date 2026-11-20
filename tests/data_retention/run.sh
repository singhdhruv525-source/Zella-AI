#!/usr/bin/env bash
# sql/zella_data_retention.sql on an ISOLATED copy of the production schema (never production). Test people and made up
# rows only. Checks: before, there is one retention period and nothing lists what is past it (the gap); applies (after
# the earlier lane G files), and applies again; every period starts at the architecture's value and "pending legal
# review"; the purge switch starts off and only a Zella Voice owner can change it; the dry run lists exactly the rows
# past their period for each kind (ids, business and date, never content), leaves out businesses on a legal hold, and
# deletes and changes nothing; only an owner changes a period or releases a hold; every change is audited; signed in
# people and anonymous can't call the functions or read the tables; the rollback (twice) removes it, refusing while
# anything would be lost or a function changed; applies again; a changed function stops the file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zlg_data_retention}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "set client_min_messages = warning" -c "$1"; }
# production's functions: the writing cleanup, then the merged migrations not applied yet (docs/SCHEMA_STATUS.md)
for f in zella_writing_cleanup zella_cancellations_scheduled zella_admin_permissions zella_admin_mfa zella_support_notes zella_status_honest zella_retry_event_safe; do
  "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { bad "$f"; exit 1; }
done
for f in zella_number_orders zella_recording_policy; do "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { bad "$f"; exit 1; }; done
OWNER=e4000000-0000-0000-0000-000000000001; SEC=e4000000-0000-0000-0000-000000000002; RO=e4000000-0000-0000-0000-000000000003
MEMBER=e4000000-0000-0000-0000-000000000004; SUPER=e4000000-0000-0000-0000-000000000005
A=e4000000-0000-0000-0000-0000000000a1; C=e4000000-0000-0000-0000-0000000000c1; H=e4000000-0000-0000-0000-0000000000d1
q "insert into auth.users (id, email, email_confirmed_at) values ('$OWNER', 'owner@ret.test', now()), ('$SEC', 'sec@ret.test', now()),
     ('$RO', 'readonly@ret.test', now()), ('$MEMBER', 'member@ret.test', now()), ('$SUPER', 'super@ret.test', now());
   insert into public.platform_admins (user_id, role) values ('$OWNER', 'zella_owner'), ('$SEC', 'security_admin'), ('$RO', 'read_only_admin'), ('$SUPER', 'super_admin');
   insert into public.platform_role_permissions (role, permission) values ('security_admin', 'security.manage'), ('security_admin', 'security.view'),
     ('read_only_admin', 'security.view') on conflict do nothing;
   insert into public.businesses (id, name) values ('$A', 'Active Retention Test'), ('$C', 'Cancelled Retention Test'), ('$H', 'Held Retention Test');
   update public.businesses set cancelled_at = now() - interval '40 days' where id = '$C';
   insert into public.calls (id, business_id, direction, status, created_at, ended_at, recording_url, transcript) values
     ('e4000000-0000-0000-0000-00000000ca01', '$A', 'inbound', 'completed', now() - interval '100 days', now() - interval '100 days', 'https://rec.test/1', 'Old transcript text'),
     ('e4000000-0000-0000-0000-00000000ca02', '$A', 'inbound', 'completed', now() - interval '45 days', now() - interval '45 days', 'https://rec.test/2', 'Recent transcript'),
     ('e4000000-0000-0000-0000-00000000ca03', '$A', 'inbound', 'completed', now() - interval '2 days', now() - interval '2 days', 'https://rec.test/3', 'New transcript'),
     ('e4000000-0000-0000-0000-00000000ca04', '$H', 'inbound', 'completed', now() - interval '100 days', now() - interval '100 days', 'https://rec.test/4', 'Held transcript');
   insert into public.sms_messages (id, business_id, direction, message_body, created_at) values
     ('e4000000-0000-0000-0000-00000000aa01', '$A', 'outbound', 'Old text', now() - interval '800 days'), ('e4000000-0000-0000-0000-00000000aa02', '$A', 'outbound', 'New text', now() - interval '10 days');
   insert into public.conversations (id, business_id, channel, status, last_message_at) values ('e4000000-0000-0000-0000-00000000cc01', '$A', 'sms', 'open', now() - interval '800 days');
   insert into public.conversation_messages (id, conversation_id, sender_type, message_type, content, created_at) values
     ('e4000000-0000-0000-0000-00000000c301', 'e4000000-0000-0000-0000-00000000cc01', 'customer', 'text', 'Old conversation message', now() - interval '800 days');
   insert into public.email_messages (id, business_id, direction, body_text, created_at) values ('e4000000-0000-0000-0000-00000000ee01', '$A', 'outbound', 'Old email', now() - interval '800 days');
   insert into public.audit_logs (id, business_id, action, created_at) values ('e4000000-0000-0000-0000-00000000ad01', null, 'test.old', now() - interval '3000 days'),
     ('e4000000-0000-0000-0000-00000000ad02', '$A', 'test.recent', now() - interval '30 days');
   insert into public.business_verification_documents (id, business_id, kind, file_path, file_name, mime_type, size_bytes, status, reviewed_at, updated_at) values
     ('e4000000-0000-0000-0000-00000000d001', '$A', 'business_registration', '$A/old.pdf', 'old.pdf', 'application/pdf', 10, 'replaced', null, now() - interval '40 days'),
     ('e4000000-0000-0000-0000-00000000d002', '$A', 'owner_identity', '$A/id.png', 'id.png', 'image/png', 10, 'verified', now() - interval '100 days', now() - interval '100 days'),
     ('e4000000-0000-0000-0000-00000000d003', '$A', 'owner_identity', '$A/id2.png', 'id2.png', 'image/png', 10, 'verified', now() - interval '10 days', now() - interval '10 days'),
     ('e4000000-0000-0000-0000-00000000d004', '$C', 'business_registration', '$C/reg.pdf', 'reg.pdf', 'application/pdf', 10, 'verified', now() - interval '60 days', now() - interval '60 days')" > /dev/null || exit 1
srv() { "${P[@]}" -d $DB -c "set client_min_messages = warning" -c "set role service_role" -c "$1" 2>&1 | head -1; }
as() { local role=authenticated; [ -z "$1" ] && role=anon
  "${P[@]}" -d $DB -c "set role $role" -c "select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"$role\"}', false)" -c "$2" 2>&1 | sed -n 2p; }
prev() { srv "select public.zella_retention_preview('$RO', '$1', 50) ${2:-}"; }
fp() { q "select md5(string_agg(t, '|' order by t)) from (select md5(c::text) t from public.calls c union all select md5(s::text) from public.sms_messages s
          union all select md5(e::text) from public.email_messages e union all select md5(d::text) from public.business_verification_documents d
          union all select md5(m::text) from public.conversation_messages m
          union all select md5(a::text) from public.audit_logs a where a.created_at <= '$T0'::timestamptz) x"; }

v=$(q "select to_regclass('public.data_retention_policies') is null and to_regprocedure('public.zella_retention_preview(uuid,text,integer)') is null")
[ "$v" = "t" ] && ok "before: there is one retention period and nothing lists what is past it (the gap)" || bad "before: $v"
"${P[@]}" -d $DB -f "$REPO/sql/zella_data_retention.sql" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$REPO/sql/zella_data_retention.sql" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$REPO/sql/zella_data_retention.sql" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"
v=$(q "select string_agg(data_class || '=' || days, ',' order by data_class) || '/' || bool_and(days = architecture_days and legal_status = 'pending_legal_review') from public.data_retention_policies")
[ "$v" = "audit_logs=2555,call_recordings=30,call_transcripts=90,cancelled_business=30,documents_cancelled_business=30,documents_owner_id_verified=90,documents_replaced=30,message_bodies=730/true" ] \
  && ok "every period starts at the architecture's value, pending legal review" || bad "seed: $v"
[ "$(q "select value::text from public.platform_settings where key = 'retention_purge_enabled'")" = "false" ] && ok "the purge switch starts off" || bad "switch"
[ "$(srv "select public.zella_retention_overview('$RO') ->> 'scheduled'")" = "false" ] && ok "nothing is scheduled" || bad "scheduled"
[ "$(q "select count(*) from cron.job where command ilike '%retention%' or jobname ilike '%purge%'")" = "0" ] && ok "and no job runs it" || bad "cron job"

T0=$(q "select clock_timestamp()"); before=$(fp)
[ "$(prev call_recordings "->> 'count'")" = "3" ] && [ "$(prev call_recordings "-> 'sample' -> 2 ->> 'id'")" = "e4000000-0000-0000-0000-00000000ca02" ] && ok "recordings: only calls older than 30 days, oldest first" || bad "recordings: $(prev call_recordings)"
[ "$(prev call_transcripts "->> 'count'")" = "2" ] && ok "transcripts: only the ones older than 90 days" || bad "transcripts: $(prev call_transcripts "->> 'count'")"
q "insert into public.calls (id, business_id, direction, status, created_at, ended_at, transcript) values ('e4000000-0000-0000-0000-00000000ca09', '$A', 'inbound', 'completed', now() - interval '300 days', now() - interval '300 days', 'Removed under the retention policy.')" > /dev/null || bad "the removed transcript fixture"
[ "$(q "select count(*) from public.calls where id = 'e4000000-0000-0000-0000-00000000ca09'")" = "1" ] || bad "removed transcript fixture missing"
[ "$(prev call_transcripts "->> 'count'")" = "2" ] && ok "a transcript already removed under retention isn't listed again" || bad "marker listed"
q "delete from public.calls where id = 'e4000000-0000-0000-0000-00000000ca09'" > /dev/null
[ "$(prev message_bodies "->> 'by_source'")" = '{"sms_messages": 1, "email_messages": 1, "conversation_messages": 1}' ] && ok "message bodies: the old text, email and conversation message, not the new text" || bad "bodies: $(prev message_bodies "->> 'by_source'")"
[ "$(prev audit_logs "->> 'count'")" = "1" ] && ok "audit logs: only rows older than 7 years" || bad "audit: $(prev audit_logs "->> 'count'")"
[ "$(prev documents_replaced "-> 'sample' -> 0 ->> 'id'")" = "e4000000-0000-0000-0000-00000000d001" ] && ok "replaced documents: the copy replaced 40 days ago" || bad "replaced"
[ "$(prev documents_owner_id_verified "->> 'count'")" = "1" ] && ok "owner identity files: verified more than 90 days ago only" || bad "owner id"
[ "$(prev documents_cancelled_business "-> 'sample' -> 0 ->> 'id'")" = "e4000000-0000-0000-0000-00000000d004" ] && ok "a cancelled business's files, 30 days after cancellation" || bad "cancelled docs"
q "insert into public.retention_removed_files (document_id, file_path) values ('e4000000-0000-0000-0000-00000000d004', '$C/reg.pdf')" > /dev/null
[ "$(prev documents_cancelled_business "->> 'count'")" = "0" ] && ok "a file already removed under retention isn't listed again" || bad "removed file listed"
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_data_retention_rollback.sql" 2>&1); [[ "$out" == *"files were removed"* ]] && ok "the rollback refuses once files were removed (their record would be lost)" || bad "rollback with removed files: $out"
q "delete from public.retention_removed_files" > /dev/null
[ "$(prev cancelled_business "->> 'count'")" = "0" ] && ok "the cancelled business itself waits for its retention date too (retention_days, 90 days)" || bad "cancelled business: $(prev cancelled_business "->> 'count'")"
v=$(prev call_transcripts "::text"); [[ "$v" == *e4000000-0000-0000-0000-00000000ca01* && "$v" != *ERROR* && "$v" != *"transcript text"* && "$v" != *"rec.test"* ]] && ok "the dry run never returns content" || bad "content leaked: $v"
[[ "$(srv "select public.zella_retention_preview('$MEMBER', 'call_recordings', 5)")" == *NOT_ALLOWED* ]] && ok "someone who isn't an admin can't run the dry run" || bad "member preview"
[[ "$(prev nonsense)" == *UNKNOWN_CLASS* ]] && ok "an unknown kind of data is refused" || bad "unknown class"

# legal holds
[[ "$(srv "select public.zella_legal_hold_place('$RO', '$H', 'Litigation')")" == *NOT_ALLOWED* ]] && ok "security.view alone can't place a hold" || bad "ro hold"
[[ "$(srv "select public.zella_legal_hold_place('$SEC', '$H', 'x')")" == *REASON_REQUIRED* ]] && ok "a hold needs a reason" || bad "hold reason"
HOLD=$(srv "select public.zella_legal_hold_place('$SEC', '$H', 'Counsel asked to keep everything') ->> 'id'")
[ -n "$HOLD" ] && ok "security.manage places a legal hold" || bad "place"
[[ "$(srv "select public.zella_legal_hold_place('$SEC', '$H', 'Again')")" == *ALREADY_ON_HOLD* ]] && ok "one active hold per business" || bad "double hold"
[ "$(prev call_recordings "->> 'count'")" = "2" ] && [ "$(prev call_transcripts "->> 'count'")" = "1" ] && ok "a business on hold is left out of the dry run" || bad "hold ignored: $(prev call_recordings "->> 'count'")"
[[ "$(srv "select public.zella_legal_hold_release('$SEC', '$HOLD', 'Done')")" == *OWNER_REQUIRED* ]] && ok "only a Zella Voice owner releases a hold" || bad "sec released"
[[ "$(srv "select public.zella_legal_hold_release('$SUPER', '$HOLD', 'Done')")" == *OWNER_REQUIRED* ]] && ok "a super admin can't either" || bad "super released"
[[ "$(q "delete from public.businesses where id = '$H'" 2>&1)" == *"violates foreign key"* ]] && ok "a business on hold can't be deleted at all" || bad "held business deleted"

# periods and the switch
[[ "$(srv "select public.zella_retention_policy_set('$SEC', 'call_recordings', 30, 'approved', 'Counsel approved')")" == *OWNER_REQUIRED* ]] && ok "only a Zella Voice owner changes a period or its legal status" || bad "sec policy"
[[ "$(srv "select public.zella_retention_policy_set('$OWNER', 'call_recordings', 0, 'approved', 'Counsel approved')")" == *INVALID_DAYS* ]] && ok "a period is 1 day or more" || bad "days"
[[ "$(srv "select public.zella_retention_policy_set('$OWNER', 'call_recordings', 30, 'done', 'Counsel approved')")" == *INVALID_STATUS* ]] && ok "the legal status is pending or approved" || bad "status"
[[ "$(srv "select public.zella_retention_policy_set('$OWNER', 'call_recordings', 30, null, 'Counsel approved')")" == *INVALID_STATUS* ]] && ok "and can't be left out" || bad "null status"
[ "$(srv "select public.zella_retention_policy_set('$OWNER', 'call_transcripts', 120, 'pending_legal_review', 'Counsel asked for longer') ->> 'days'")" = "120" ] && ok "the owner changes a period" || bad "policy set"
[ "$(prev call_transcripts "->> 'count'")" = "0" ] && ok "and the dry run follows it" || bad "after change"
[[ "$(srv "update public.platform_settings set value = 'true' where key = 'retention_purge_enabled'")" == *RETENTION_SWITCH_OWNER_ONLY* ]] && ok "the purge switch can't be changed directly, even by the server" || bad "direct switch"
[[ "$(srv "select public.zella_retention_switch_set('$SEC', true, 'Ready')")" == *OWNER_REQUIRED* ]] && ok "only a Zella Voice owner can switch purges on" || bad "sec switch"
[ "$(srv "select public.zella_retention_switch_set('$OWNER', true, 'Testing the switch') ->> 'purge_enabled'")/$(srv "select public.zella_retention_switch_set('$OWNER', false, 'Back off') ->> 'purge_enabled'")" = "true/false" ] && ok "the owner switches it on and off" || bad "owner switch"
[ "$(fp)" = "$before" ] && ok "nothing was deleted or changed by any dry run" || bad "rows changed"
v=$(q "select string_agg(action || ':' || user_id, ',' order by created_at, action) from public.audit_logs where action in ('business.legal_hold_placed', 'platform.retention_policy_set', 'platform.retention_purge_switch')")
[ "$v" = "business.legal_hold_placed:$SEC,platform.retention_policy_set:$OWNER,platform.retention_purge_switch:$OWNER,platform.retention_purge_switch:$OWNER" ] && ok "every change is audited with who made it" || bad "audit: $v"

for fn in "zella_retention_preview('$OWNER', 'call_recordings', 5)" "zella_retention_switch_set('$OWNER', true, 'Direct')" "zella_legal_hold_release('$OWNER', '$HOLD', 'Direct')" "zella_retention_candidates('audit_logs', now())"; do
  [[ "$(as $OWNER "select public.$fn")" == *"permission denied"* ]] || { bad "a signed in owner could call $fn directly"; continue; }
  [[ "$(as "" "select public.$fn")" == *"permission denied"* ]] || bad "anonymous could call $fn"
done && ok "signed in people (even an owner) and anonymous can't call the functions directly"
[[ "$(as $OWNER "select count(*) from public.legal_holds")" == *"permission denied"* && "$(as $OWNER "select count(*) from public.data_retention_policies")" == *"permission denied"* ]] && ok "the tables can't be read directly" || bad "tables readable"

out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_data_retention_rollback.sql" 2>&1); [[ "$out" == *"legal hold is active"* ]] && ok "the rollback refuses while a legal hold is active" || bad "rollback with hold: $out"
srv "select public.zella_legal_hold_release('$OWNER', '$HOLD', 'Counsel released it')" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_data_retention_rollback.sql" 2>&1); [[ "$out" == *"changed a retention period"* ]] && ok "the rollback refuses while an owner's period would be lost" || bad "rollback with change: $out"
srv "select public.zella_retention_policy_set('$OWNER', 'call_transcripts', 90, 'pending_legal_review', 'Back to the proposal')" > /dev/null
"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_data_retention_rollback.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_data_retention_rollback.sql" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
v=$(q "select to_regclass('public.data_retention_policies') is not null and exists (select 1 from public.legal_holds where id = '$HOLD') and to_regprocedure('public.zella_retention_preview(uuid,text,integer)') is null and not exists (select 1 from public.platform_settings where key = 'retention_purge_enabled') and not exists (select 1 from pg_trigger where tgname = 'zella_retention_setting_guard')")
[ "$v" = "t" ] && ok "rollback removes the functions, guard and switch, and keeps the policies and holds" || bad "leftovers"
[ "$(fp)" = "$before" ] && ok "and leaves every call, message, document and audit row as it was" || bad "rows changed by rollback"
"${P[@]}" -d $DB -f "$REPO/sql/zella_data_retention.sql" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_retention_on_hold(p_business uuid) returns boolean language sql as \$f\$ select false \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_data_retention_rollback.sql" 2>&1); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "the rollback refuses a changed function" || bad "rollback drift: $out"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_data_retention.sql" 2>&1); [[ "$out" == *VERSION_MISMATCH* ]] && ok "a changed function stops the file" || bad "drift: $out"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
