#!/usr/bin/env bash
# M7: sql/zella_admin_pause_sticky.sql. Checks: before, the go live update turns an admin paused automation back on
# (the gap); after, it doesn't (nor does any update that isn't an admin function), other paused automations still go
# active, the mark can't be cleared outside the admin functions, an admin resume clears it, archive keeps it off;
# applies twice; rollback twice restores both functions exactly and drops the column; drift stops the file and the
# rollback.
. "$(dirname "$0")/lib.sh"; fresh_db admin_pause
PAUSE='public.zella_admin_business_automations_pause(uuid,text)'; SETS='public.zella_admin_automation_set_status(uuid,text,text)'
RES='public.zella_admin_business_automations_resume(uuid,text)'
fp() { q "select md5(pg_get_functiondef('$PAUSE'::regprocedure)) || md5(pg_get_functiondef('$SETS'::regprocedure)) || md5(pg_get_functiondef('$RES'::regprocedure))"; }
before=$(fp)
ADM=f4000000-0000-0000-0000-000000000001
q "insert into auth.users (id, email, email_confirmed_at) values ('$ADM', 'ap1@ap.test', now())" > /dev/null
q "insert into public.platform_admins (user_id, role, is_active) values ('$ADM', 'zella_owner', true)" > /dev/null
BIZ=$(q "insert into public.businesses (name, industry_id, is_active) select 'Pause Test', id, true from public.industries limit 1 returning id" | head -1)
mk() { q "insert into public.automations (business_id, name, trigger_type, status) values ('$BIZ', '$1', 'missed_call', '$2') returning id" | head -1; }
# what zella_request_activation runs when the business goes live (both versions)
golive() { q "update public.automations set status = 'active', updated_at = now() where business_id = '$BIZ' and status = 'paused'" > /dev/null; }
st() { q "select status from public.automations where id = '$1'"; }
admin() { as_user $ADM aal2 "raise notice 'R=%', $1;"; }

A=$(mk before active)
r=$(admin "public.zella_admin_business_automations_pause('$BIZ', 'abuse check')"); golive
[ "$(st $A)" = active ] && ok "before: a go live turns an automation staff paused back on (the gap)" || bad "before: $(st $A) ($r)"

out=$(apply "$REPO/sql/zella_admin_pause_sticky.sql") && ok "applies" || { bad "applies: $out"; finish; }
out=$(apply "$REPO/sql/zella_admin_pause_sticky.sql") && ok "applies again" || bad "second apply: $out"
[ "$(fp)" = "80fc3ae370fda10aab743a23aef4624de50b454d658b0c7a3e863f2cb98acca1f54e8b67f946cd489599224baa3364b9" ] && ok "new fingerprints are the recorded ones" || bad "fingerprints $(fp)"

B=$(mk staffpaused active); C=$(mk ownerpaused paused)
r=$(admin "public.zella_admin_business_automations_pause('$BIZ', 'abuse check')")
[ "$r" = '{"paused": 2}' ] && ok "the business pause pauses the active ones ($r)" || bad "pause: $r"
[ "$(q "select count(*) from public.automations where business_id = '$BIZ' and paused_by_admin")" = 3 ] && ok "and marks every paused automation" || bad "marks"
golive
[ "$(st $B)$(st $C)" = pausedpaused ] && ok "after: a go live leaves automations staff paused off" || bad "after: $(st $B) $(st $C)"
q "update public.automations set paused_by_admin = false, status = 'active' where id = '$B'" > /dev/null
[ "$(st $B)" = paused ] && [ "$(q "select paused_by_admin from public.automations where id = '$B'")" = t ] && ok "an update outside the admin functions can't clear the mark or turn it on" || bad "cleared outside"
q "update public.automations set name = 'renamed' where id = '$B'" > /dev/null
[ "$(q "select name from public.automations where id = '$B'")" = renamed ] && ok "other edits still work" || bad "other edits"
q "update public.automations set status = 'disabled' where id = '$C'" > /dev/null; q "update public.automations set status = 'active' where id = '$C'" > /dev/null
[ "$(st $C)" = disabled ] && ok "switching off then on again doesn't get around it" || bad "disable then active: $(st $C)"
D=$(q "insert into public.businesses (name, industry_id, is_active) select 'Other', id, true from public.industries limit 1 returning id" | head -1)
E=$(q "insert into public.automations (business_id, name, trigger_type, status) values ('$D', 'x', 'missed_call', 'paused') returning id" | head -1)
q "update public.automations set status = 'active' where id = '$E'" > /dev/null
[ "$(st $E)" = active ] && ok "automations not paused by staff go active as before" || bad "unmarked: $(st $E)"

# a refused attempt keeps the "Pause all" mark, and "Resume all" (staff) turns them back on and clears the mark
[ "$(q "select count(*) from public.automations where id = '$B' and bulk_paused_at is not null")" = 1 ] && ok "a refused attempt keeps the Pause all mark" || bad "bulk mark lost"
r=$(admin "public.zella_admin_business_automations_resume('$BIZ', 'checked, all fine')")
[ "$(st $B)" = active ] && [ "$(q "select paused_by_admin from public.automations where id = '$B'")" = f ] && ok "Resume all turns staff paused automations back on ($r)" || bad "resume all: $r $(st $B)"
r=$(admin "public.zella_admin_automation_set_status('$B', 'paused', 'pause again')")
r=$(admin "public.zella_admin_automation_set_status('$B', 'active', 'checked')")
[ "$(st $B)" = active ] && [ "$(q "select paused_by_admin from public.automations where id = '$B'")" = f ] && ok "an admin resume turns it on and clears the mark" || bad "resume: $r $(st $B)"
Z=$(mk ownerpaused2 paused); r=$(admin "public.zella_admin_automation_set_status('$Z', 'paused', 'abuse check, mark it')")
[ "$(q "select paused_by_admin from public.automations where id = '$Z'")" = t ] && ok "staff can mark an automation the business had already paused" || bad "mark paused: $r"
r=$(admin "public.zella_admin_automation_set_status('$B', 'disabled', 'archive')"); q "update public.automations set status = 'active' where id = '$B'" > /dev/null
[ "$(st $B)" = disabled ] && ok "an automation staff archived stays off" || bad "archive: $(st $B)"
r=$(admin "public.zella_admin_automation_set_status('$B', 'paused', 'abuse check again')"); q "update public.automations set status = 'active' where id = '$B'" > /dev/null
[ "$(st $B)" = paused ] && ok "an automation staff paused one by one stays off" || bad "single pause: $(st $B) ($r)"

apply "$REPO/sql/rollback/zella_admin_pause_sticky_rollback.sql" > /dev/null && apply "$REPO/sql/rollback/zella_admin_pause_sticky_rollback.sql" > /dev/null && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "$before" ] && ok "rollback restores both functions exactly" || bad "fingerprint after rollback"
[ "$(q "select count(*) from information_schema.columns where table_name = 'automations' and column_name = 'paused_by_admin'")" = 0 ] && ok "rollback drops the column and trigger" || bad "column left"
apply "$REPO/sql/zella_admin_pause_sticky.sql" > /dev/null && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_admin_business_automations_pause(p_business_id uuid, p_reason text) returns jsonb language sql as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
out=$(apply "$REPO/sql/rollback/zella_admin_pause_sticky_rollback.sql"); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "the rollback refuses a changed function" || bad "rollback drift: $out"
q "delete from public.zella_function_archive where migration = 'zella_admin_pause_sticky'" > /dev/null
out=$(apply "$REPO/sql/zella_admin_pause_sticky.sql"); [[ "$out" == *VERSION_MISMATCH* ]] && ok "an unknown version stops the file" || bad "drift not caught: $out"
finish
