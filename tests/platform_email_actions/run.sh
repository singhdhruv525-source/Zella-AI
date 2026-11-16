#!/usr/bin/env bash
# sql/zella_platform_email_actions.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Checks: before, a held email can't be read, released or discarded (the gap); applies, and applies again; the detail
# gives the bodies to businesses.view and is audited; release puts a held email back in the queue with its tries reset,
# closes its held alert and is audited; with email_live off the next claim marks it test mode, so nothing is handed
# out; discard is terminal (no claim takes it again), closes the alert and is audited; only held emails can be released
# or discarded; a reason is required; a role without comms.manage, an anonymous caller and a business owner are
# refused; the rollback (twice) drops the three functions and leaves the claim and finish functions untouched; applies
# again; a changed function stops the file (VERSION_MISMATCH) and the rollback (ROLLBACK_DRIFT).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zlb_email_actions}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
MIG="$REPO/sql/zella_platform_email_actions.sql"; RB="$REPO/sql/rollback/zella_platform_email_actions_rollback.sql"
fp() { q "select md5(pg_get_functiondef('public.zella_claim_platform_emails(integer)'::regprocedure)) || md5(pg_get_functiondef('public.zella_finish_platform_email(uuid,uuid,boolean,text,text)'::regprocedure))"; }
before=$(fp)
OWN=e1000000-0000-0000-0000-000000000001; RO=e1000000-0000-0000-0000-000000000002; BIZOWN=e1000000-0000-0000-0000-000000000003; SUP=e1000000-0000-0000-0000-000000000004
B=e2000000-0000-0000-0000-000000000001
q "insert into auth.users (id, email) values ('$OWN', 'owner@zella.test'), ('$RO', 'readonly@zella.test'), ('$BIZOWN', 'owner@glow.test'), ('$SUP', 'support@zella.test');
   insert into public.platform_admins (user_id, role, is_active) values ('$OWN', 'zella_owner', true), ('$RO', 'read_only_admin', true), ('$SUP', 'support_admin', true);
   insert into public.platform_role_permissions (role, permission) values ('read_only_admin', 'businesses.view'), ('support_admin', 'businesses.view'), ('support_admin', 'support.manage') on conflict do nothing;
   insert into public.businesses (id, name) values ('$B', 'Glow Test Studio');
   insert into public.business_members (business_id, user_id, role, status) values ('$B', '$BIZOWN', 'owner', 'active');
   delete from public.platform_settings where key = 'email_live'" > /dev/null || exit 1
# one email that kept failing: the claim holds it after 5 tries and raises the alert
held() { # dedupe suffix -> id
  local id; id=$(q "select public.zella_queue_platform_email('$B', 'C3', 'email:C3:$1:1', 'owner@glow.test', 'Payment received', '<p>Thanks</p>', 'Thanks', true)")
  q "update public.platform_emails set status = 'sending', attempts = 5, next_attempt_at = now() - interval '1 minute' where id = '$id'" > /dev/null
  q "select count(*) from public.zella_claim_platform_emails(10)" > /dev/null
  echo "$id"
}
as() { # user id, sql -> runs as that signed in person (aal2)
  printf '%s\n' "begin; set local role authenticated;" \
    "select set_config('request.jwt.claims', '{\"sub\": \"$1\", \"role\": \"authenticated\", \"aal\": \"aal2\"}', true) \\g /dev/null" \
    "$2;" "commit;" | "${P[@]}" -d $DB 2>&1; }
E1=$(held inv1)
[ "$(q "select status from public.platform_emails where id = '$E1'")" = "held" ] && [ "$(q "select count(*) from public.platform_alerts where kind = 'platform_email_held' and status = 'open'")" = "1" ] && ok "a fifth failure holds the email and raises the alert" || bad "setup"
out=$(as $OWN "select public.zella_admin_platform_email_release('$E1', 'checked')")
[[ "$out" == *"does not exist"* ]] && ok "before: a held email can't be released (the gap)" || bad "before: $out"

"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$MIG" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"

d=$(as $RO "select (r ->> 'html') || '|' || (r ->> 'text_body') || '|' || (r ->> 'business_name') || '|' || (r ->> 'can_manage') from public.zella_admin_platform_email_detail('$E1') r")
[ "$d" = "<p>Thanks</p>|Thanks|Glow Test Studio|false" ] && ok "the detail gives the bodies to businesses.view, and says it can't manage" || bad "detail: $d"
[ "$(q "select count(*) from public.audit_logs where action = 'comms.platform_email_viewed' and entity_id = '$E1' and user_id = '$RO'")" = "1" ] && ok "and the view is audited" || bad "view audit"
for who in "$RO" "$BIZOWN"; do
  out=$(as $who "select public.zella_admin_platform_email_release('$E1', 'checked it')"); [[ "$out" == *NOT_ALLOWED* ]] || bad "release allowed for $who: $out"
  out=$(as $who "select public.zella_admin_platform_email_discard('$E1', 'checked it')"); [[ "$out" == *NOT_ALLOWED* ]] || bad "discard allowed for $who: $out"
done
out=$(as $BIZOWN "select public.zella_admin_platform_email_detail('$E1')"); [[ "$out" == *NOT_ALLOWED* ]] || bad "a business owner read the detail: $out"
out=$("${P[@]}" -d $DB -c "begin; set local role anon; select public.zella_admin_platform_email_detail('$E1'); commit;" 2>&1); [[ "$out" == *"permission denied"* ]] || bad "anonymous: $out"
[ "$(q "select status from public.platform_emails where id = '$E1'")" = "held" ] && ok "a role without comms.manage, a business owner and anonymous are refused" || bad "refused callers changed it"
out=$(as $OWN "select public.zella_admin_platform_email_release('$E1', ' ')"); [[ "$out" == *REASON_REQUIRED* ]] && ok "a reason is required" || bad "reason: $out"

r=$(as $OWN "select public.zella_admin_platform_email_release('$E1', 'Provider outage is over') ->> 'status'")
s=$(q "select status || ',' || attempts || ',' || (claim_token is null) || ',' || (next_attempt_at <= now()) from public.platform_emails where id = '$E1'")
[ "$r" = "queued" ] && [ "$s" = "queued,0,true,true" ] && ok "release puts the held email back in the queue, tries reset" || bad "release: $r $s"
[ "$(q "select status || ',' || (resolved_by = '$OWN') from public.platform_alerts where kind = 'platform_email_held'")" = "resolved,true" ] && ok "release closes its held alert" || bad "alert after release"
[ "$(q "select new_data ->> 'reason' from public.audit_logs where action = 'comms.platform_email_released' and entity_id = '$E1' and business_id = '$B'")" = "Provider outage is over" ] && ok "release is audited with the reason" || bad "release audit"
n=$(q "select count(*) from public.zella_claim_platform_emails(10)")
[ "$n" = "0" ] && [ "$(q "select status from public.platform_emails where id = '$E1'")" = "dry_run" ] && ok "with email_live off the released email goes to test mode, nothing is handed out" || bad "after release claim: $n"
out=$(as $OWN "select public.zella_admin_platform_email_release('$E1', 'again please')"); [[ "$out" == *NOT_HELD* ]] && ok "only a held email can be released" || bad "release not held: $out"

E2=$(held inv2)
r=$(as $SUP "select public.zella_admin_platform_email_discard('$E2', 'Wrong address, sent by hand')"); [[ "$r" == *NOT_ALLOWED* ]] && ok "support admin without comms.manage can't discard" || bad "support: $r"
r=$(as $OWN "select public.zella_admin_platform_email_discard('$E2', 'Wrong address, sent by hand') ->> 'status'")
[ "$r" = "failed" ] && [ "$(q "select last_error from public.platform_emails where id = '$E2'")" = "Discarded by an admin: Wrong address, sent by hand" ] && ok "discard ends the email, with the reason" || bad "discard: $r"
q "update public.platform_settings set value = 'true' where key = 'email_live'; insert into public.platform_settings (key, value) select 'email_live', 'true' where not exists (select 1 from public.platform_settings where key = 'email_live')" > /dev/null
n=$(q "select count(*) from public.zella_claim_platform_emails(10) where id = '$E2'"); q "delete from public.platform_settings where key = 'email_live'" > /dev/null
[ "$n" = "0" ] && [ "$(q "select status from public.platform_emails where id = '$E2'")" = "failed" ] && ok "a discarded email is never claimed, even with email_live on" || bad "discarded claimed: $n"
[ "$(q "select count(*) from public.platform_alerts where kind = 'platform_email_held' and status = 'open'")" = "0" ] && ok "discard closes its held alert" || bad "alert after discard"
[ "$(q "select count(*) from public.audit_logs where action = 'comms.platform_email_discarded' and entity_id = '$E2'")" = "1" ] && ok "discard is audited" || bad "discard audit"
out=$(as $OWN "select public.zella_admin_platform_email_discard('$E2', 'again')"); [[ "$out" == *NOT_HELD* ]] && ok "only a held email can be discarded" || bad "discard not held: $out"
out=$(as $OWN "select public.zella_admin_platform_email_detail('e9999999-0000-0000-0000-000000000000')"); [[ "$out" == *NOT_FOUND* ]] && ok "an unknown email is not found" || bad "unknown: $out"
[ "$(fp)" = "$before" ] && ok "the claim and finish functions are unchanged" || bad "claim or finish changed"

"${P[@]}" -d $DB -f "$RB" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$RB" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
[ "$(q "select count(*) from pg_proc where proname in ('zella_admin_platform_email_detail', 'zella_admin_platform_email_release', 'zella_admin_platform_email_discard')")" = "0" ] && [ "$(fp)" = "$before" ] && ok "rollback drops the three functions and nothing else" || bad "rollback state"
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_admin_platform_email_discard(p_id uuid, p_reason text) returns jsonb language sql as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$MIG" 2>&1); [[ "$out" == *VERSION_MISMATCH* ]] && ok "a changed function stops the file" || bad "drift not caught: $out"
out=$("${P[@]}" -d $DB -f "$RB" 2>&1); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "and stops the rollback" || bad "rollback drift not caught: $out"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
