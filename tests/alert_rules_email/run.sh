#!/usr/bin/env bash
# sql/zella_alert_rules_email.sql on ISOLATED copies of the production schema (never production). Test people only;
# nothing is sent (the function only hands alerts to the n8n workflow). Checks: before, every alert goes to every
# admin whatever the kind (the gap); applies after sql/zella_alert_rules.sql, and applies again; with no rules the
# claim answers exactly as production's function; with email off nothing is claimed or marked; a bell only kind isn't
# emailed (marked bell_only) but an urgent alert of that kind is; a quiet window holds warnings and info and never an
# urgent alert, and lets them go once it ends (windows across midnight too); an email permission sends that kind only
# to admins holding it, one group per claim, and to every admin when nobody holds it; opted out admins never get one;
# only the server may claim; the rollback (twice) restores the function exactly; the rules rollback refuses while this
# is applied; applies again; a changed function stops both.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zld_alertemail}; REF=${REF:-zld_alertemail_ref}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$REF" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
OWNER=e8000000-0000-0000-0000-000000000001; OPS=e8000000-0000-0000-0000-000000000002; SUP=e8000000-0000-0000-0000-000000000003; QUIET=e8000000-0000-0000-0000-000000000004
for d in $DB $REF; do
  "${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $d" -c "create database $d template $TEMPLATE" > /dev/null || exit 1
  for f in zella_writing_cleanup zella_cancellations_scheduled zella_admin_permissions zella_admin_mfa zella_support_notes zella_status_honest; do
    "${P[@]}" -d $d -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { bad "$f on $d"; exit 1; }
  done
  "${P[@]}" -d $d -c "insert into auth.users (id, email, email_confirmed_at) values ('$OWNER', 'owner@email.test', now()), ('$OPS', 'ops@email.test', now()), ('$SUP', 'support@email.test', now()), ('$QUIET', 'optout@email.test', now());
     insert into public.platform_admins (user_id, role) values ('$OWNER', 'zella_owner'), ('$OPS', 'platform_operations'), ('$SUP', 'support_admin'), ('$QUIET', 'zella_owner');
     insert into public.admin_alert_prefs (user_id, email_enabled) values ('$QUIET', false);
     insert into public.platform_role_permissions (role, permission) values ('platform_operations', 'integrations.manage'), ('support_admin', 'support.manage') on conflict do nothing;
     insert into public.platform_settings (key, value) values ('email_live', 'true'), ('email_from_address', '\"alerts@example.test\"') on conflict (key) do update set value = excluded.value;
     delete from public.platform_alerts" > /dev/null || exit 1
done
q() { "${P[@]}" -d ${2:-$DB} -c "set client_min_messages = warning" -c "$1"; }
add() { q "insert into public.platform_alerts (id, kind, title, severity, dedupe_key, first_seen_at) values ('$1', '$2', 'Alert $1', '$3', '$1', now() - interval '${4:-1} minutes')" ${5:-$DB} > /dev/null; }
claim() { q "select public.zella_claim_admin_alert_email(25)" ${1:-$DB}; }
ids() { q "select coalesce(string_agg(right(x ->> 'id', 2), ',' order by ord), '') from jsonb_array_elements(public.zella_claim_admin_alert_email(25) -> 'alerts') with ordinality t(x, ord)"; }
to() { echo "$1" | python3 -I -c "import json,sys; d=json.load(sys.stdin); print(','.join(sorted(d['to'])))"; }
fp() { q "select md5(pg_get_functiondef('public.zella_claim_admin_alert_email(integer)'::regprocedure)) || (select string_agg(grantee || privilege_type, ',' order by grantee) from information_schema.routine_privileges where routine_name = 'zella_claim_admin_alert_email')"; }
A=e8100000-0000-0000-0000-0000000000
for d in $DB $REF; do add ${A}01 w_plain warning 5 $d; add ${A}02 w_plain urgent 4 $d; add ${A}03 w_info info 3 $d; done
before=$(fp)
"${P[@]}" -d $DB -f "$REPO/sql/zella_alert_rules.sql" > /dev/null 2>&1 || { bad "alert rules part 1"; exit 1; }
"${P[@]}" -d $DB -f "$REPO/sql/zella_alert_rules_email.sql" > /dev/null 2>&1 && ok "applies after the alert rules" || { bad "applies"; "${P[@]}" -d $DB -f "$REPO/sql/zella_alert_rules_email.sql" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$REPO/sql/zella_alert_rules_email.sql" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"
r_ref=$(claim $REF); r_new=$(claim)
strip() { echo "$1" | python3 -I -c "import json,sys; d=json.load(sys.stdin); d.pop('group', None); d['to']=sorted(d['to']); [a.pop(k) for a in d['alerts'] for k in ('first_seen_at', 'last_seen_at')]; print(json.dumps(d, sort_keys=True))"; }
[ "$(strip "$r_ref")" = "$(strip "$r_new")" ] && ok "with no rules the claim answers exactly as production's (same alerts, order, recipients)" || bad "differs: $r_ref | $r_new"
[ "$(to "$r_ref")" = "ops@email.test,owner@email.test,support@email.test" ] && ok "before: every alert goes to every admin who hasn't opted out, whatever the kind (the gap)" || bad "before to: $(to "$r_ref")"

q "delete from public.platform_alerts" > /dev/null
q "update public.platform_settings set value = 'false' where key = 'email_live'; insert into public.platform_alert_rules (kind, destination) values ('w_bell', 'bell')" > /dev/null
add ${A}11 w_bell warning 5
v=$(claim); [[ "$v" == *'"why": "email_off"'* ]] && [ "$(q "select count(*) from public.platform_alerts where notified_at is not null")" = "0" ] && ok "with email off nothing is claimed or marked" || bad "email off: $v"
q "update public.platform_settings set value = 'true' where key = 'email_live'" > /dev/null
add ${A}12 w_bell urgent 4
[ "$(ids)" = "12" ] && ok "a bell only kind isn't emailed, but an urgent alert of that kind is" || bad "bell: $(ids)"
[ "$(q "select meta ->> 'email_skipped' from public.platform_alerts where id = '${A}11'")" = "bell_only" ] && ok "the bell only alert is marked handled and stays in the bell (open)" || bad "bell mark"
[ "$(q "select status from public.platform_alerts where id = '${A}11'")" = "open" ] || bad "bell alert closed"

q "delete from public.platform_alerts; delete from public.platform_alert_rules;
   insert into public.platform_alert_rules (kind, quiet_start, quiet_end, quiet_tz) values ('w_quiet', (now() at time zone 'UTC' - interval '1 hour')::time, (now() at time zone 'UTC' + interval '1 hour')::time, 'UTC')" > /dev/null
add ${A}21 w_quiet warning 5; add ${A}22 w_quiet info 4; add ${A}23 w_quiet urgent 3
[ "$(ids)" = "23" ] && ok "a quiet window holds warning and info, never an urgent alert" || bad "quiet: $(ids)"
[ "$(ids)" = "" ] && ok "while it lasts, the held alerts stay held" || bad "still quiet"
q "update public.platform_alert_rules set quiet_start = (now() at time zone 'UTC' + interval '1 hour')::time, quiet_end = (now() at time zone 'UTC' + interval '2 hours')::time" > /dev/null
[ "$(ids)" = "21,22" ] && ok "once the window ends they go out, in order" || bad "after quiet: $(ids)"
q "delete from public.platform_alerts; update public.platform_alert_rules set quiet_start = (now() at time zone 'UTC' - interval '1 hour')::time, quiet_end = (now() at time zone 'UTC' - interval '2 hours')::time" > /dev/null
add ${A}24 w_quiet warning 2
[ "$(ids)" = "" ] && ok "a window that crosses midnight (start after end) is honoured" || bad "wrap: $(ids)"
q "update public.platform_alert_rules set quiet_tz = 'Not/AZone'" > /dev/null
[ "$(ids)" = "24" ] && ok "an unknown time zone never holds an alert back" || bad "bad tz"

q "delete from public.platform_alerts; delete from public.platform_alert_rules;
   insert into public.platform_alert_rules (kind, email_permission) values ('w_ops', 'integrations.manage'), ('w_nobody', 'billing.manage')" > /dev/null
add ${A}31 w_ops urgent 5; add ${A}32 w_plain warning 4; add ${A}33 w_ops warning 3; add ${A}34 w_nobody warning 2
r1=$(claim); g1=$(echo "$r1" | python3 -I -c "import json,sys; d=json.load(sys.stdin); print(d['group'], ','.join(sorted(d['to'])), ','.join(a['id'][-2:] for a in d['alerts']))")
[ "$g1" = "integrations.manage ops@email.test,owner@email.test 31,33" ] && ok "an email permission sends that kind only to admins holding it (the owner holds every one), one group per claim" || bad "group 1: $g1"
r2=$(claim); g2=$(echo "$r2" | python3 -I -c "import json,sys; d=json.load(sys.stdin); print(d['group'], ','.join(sorted(d['to'])), ','.join(a['id'][-2:] for a in d['alerts']))")
[ "$g2" = "None ops@email.test,owner@email.test,support@email.test 32" ] && ok "the next claim takes the next group (every admin)" || bad "group 2: $g2"
r3=$(claim); g3=$(echo "$r3" | python3 -I -c "import json,sys; d=json.load(sys.stdin); print(d['group'], ','.join(sorted(d['to'])), ','.join(a['id'][-2:] for a in d['alerts']))")
[ "$g3" = "billing.manage owner@email.test 34" ] && ok "a permission only the owner holds goes to the owner" || bad "group 3: $g3"
q "delete from public.platform_alerts; update public.platform_alert_rules set email_permission = 'growth.manage' where kind = 'w_nobody'; update public.platform_admins set is_active = false where role = 'zella_owner'" > /dev/null
add ${A}35 w_nobody warning 2
g4=$(claim | python3 -I -c "import json,sys; d=json.load(sys.stdin); print(','.join(sorted(d['to'])))")
[ "$g4" = "ops@email.test,support@email.test" ] && ok "when nobody holds the permission, every admin gets it, so it is never lost" || bad "nobody: $g4"
[[ "$g1$g2$g3$g4" != *optout@* ]] && ok "an admin who opted out never gets one" || bad "opt out ignored"
v=$("${P[@]}" -d $DB -c "set role authenticated" -c "select public.zella_claim_admin_alert_email(5)" 2>&1); [[ "$v" == *"permission denied"* ]] && ok "only the server may claim" || bad "authenticated claims"
q "update public.platform_admins set is_active = true" > /dev/null

out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_alert_rules_rollback.sql" 2>&1)
[[ "$out" == *"ROLLBACK_ORDER"* ]] && ok "the rules rollback refuses while this is applied" || bad "order: $out"
"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_alert_rules_email_rollback.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_alert_rules_email_rollback.sql" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "$before" ] && ok "rollback restores the function and its grants exactly" || bad "after rollback: $(fp)"
[ "$(q "select to_regprocedure('public.zella_alert_quiet_now(time,time,text)') is null")" = "t" ] && ok "rollback removes the quiet window helper" || bad "helper left"
"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_alert_rules_rollback.sql" > /dev/null 2>&1 && ok "then the rules roll back too" || bad "rules rollback"
"${P[@]}" -d $DB -f "$REPO/sql/zella_alert_rules.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$REPO/sql/zella_alert_rules_email.sql" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_claim_admin_alert_email(p_limit integer default 25) returns jsonb language sql as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_alert_rules_email_rollback.sql" 2>&1)
[[ "$out" == *"ROLLBACK_DRIFT"* ]] && ok "the rollback refuses a changed function" || bad "rollback drift: $out"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_alert_rules_email.sql" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"* ]] && ok "a version that isn't production's stops the file" || bad "drift: $out"
"${P[@]}" -d postgres -c "drop database if exists $REF" > /dev/null
echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
