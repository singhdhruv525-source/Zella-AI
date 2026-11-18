#!/usr/bin/env bash
# H5: sql/zella_account_deletion.sql (after zella_privacy_retention.sql), on a copy with lane G applied. Checks: only an
# active owner can ask, with the business name typed; an admin with businesses.manage confirms, which freezes the
# business (suspended: no calls answered, automations paused) with the purge 30 days out; the owner can cancel and the
# freeze lifts; the daily purge does nothing while switched off or before the 30 days; it refuses (blocked, alerted)
# while audit history is at risk, and with lane B's SET NULL (sql/zella_draft_delete.sql from claude/review-lane-b)
# removes the business, keeps its audit rows with business_id null, queues its calls at Vapi, records a lane G purge
# run and the request as purged; applies twice; rollback twice restores the job lists exactly; drift stops it.
. "$(dirname "$0")/lib.sh"; fresh_db account_deletion
apply "$REPO/tests/security_fixes/prod_erase_customer.sql" > /dev/null; apply "$REPO/sql/zella_privacy_retention.sql" > /dev/null || { bad "privacy retention first"; finish; }
SIGS="'public.zella_run_scheduled_job(text)','public.zella_run_schedule_group(text)'"
fp() { q "select string_agg(md5(pg_get_functiondef(s::regprocedure)), ',' order by s) from unnest(array[$SIGS]) s"; }; before=$(fp)
out=$(apply "$REPO/sql/zella_account_deletion.sql") && ok "applies" || { bad "applies: $out"; finish; }
out=$(apply "$REPO/sql/zella_account_deletion.sql") && ok "applies again" || bad "second apply: $out"
BIZ=$(q "insert into public.businesses (name, industry_id, is_active) select 'Gone Soon', id, true from public.industries limit 1 returning id" | head -1)
O=fa000000-0000-0000-0000-000000000001; S=fa000000-0000-0000-0000-000000000002; A=fa000000-0000-0000-0000-000000000003
q "insert into auth.users (id, email, email_confirmed_at) values ('$O', 'own@del.test', now()), ('$S', 'staff@del.test', now()), ('$A', 'adm@del.test', now())" > /dev/null
q "insert into public.business_members (business_id, user_id, role, status) values ('$BIZ', '$O', 'owner', 'active'), ('$BIZ', '$S', 'admin', 'active'); insert into public.platform_admins (user_id, role, is_active) values ('$A', 'zella_owner', true)" > /dev/null
q "insert into public.automations (business_id, name, trigger_type, status) values ('$BIZ', 'Reminders', 'appointment_reminder', 'active')" > /dev/null
q "insert into public.calls (business_id, direction, status, from_number, external_call_id, ai_handled, duration_seconds, ended_at) values ('$BIZ', 'inbound', 'answered', '+15125550144', 'vc-del-1', true, 60, now())" > /dev/null
req() { as_user $1 aal1 "raise notice 'R=%', public.zella_business_deletion_request('$BIZ', '$2', 'Closing the shop');"; }
r=$(req $S "Gone Soon"); [[ "$r" == *NOT_ALLOWED* ]] && ok "a business admin can't ask (owners only)" || bad "admin asked: $r"
r=$(req $O "gone soon"); [[ "$r" == *CONFIRM_MISMATCH* ]] && ok "the name must be typed exactly" || bad "name: $r"
r=$(req $O "Gone Soon"); [[ "$r" == *requested* ]] && ok "the owner asks" || bad "request: $r"
[ "$(q "select count(*) from public.platform_alerts where kind = 'business_deletion_requested' and business_id = '$BIZ'")" = 1 ] && [ "$(q "select suspended_at is null from public.businesses where id = '$BIZ'")" = t ] && ok "Zella Voice is alerted; nothing is frozen yet" || bad "after request"
conf() { as_user $1 aal2 "raise notice 'R=%', public.zella_admin_business_deletion_confirm('$BIZ', 'Owner asked by email too');"; }
r=$(conf $O); [[ "$r" == ERR:* ]] && ok "the owner can't confirm their own request" || bad "owner confirmed: $r"
r=$(conf $A); [[ "$r" == *confirmed* ]] && ok "a Zella Voice admin confirms" || bad "confirm: $r"
[ "$(q "select (suspended_at is not null)::text || ',' || (select status from public.automations where business_id = '$BIZ') from public.businesses where id = '$BIZ'")" = "true,paused" ] && ok "the account is frozen: suspended, automations paused" || bad "freeze: $(q "select suspended_at, suspension_reason from public.businesses where id = '$BIZ'")"
[ "$(q "select (purge_after - confirmed_at) = interval '30 days' from public.business_deletion_requests where business_id = '$BIZ'")" = t ] && ok "the purge date is 30 days later" || bad "30 days"
[ "$(q "select public.zella_business_for_number('+15559990000', null, '$BIZ') is null")" = t ] && ok "the receptionist no longer answers for it" || bad "still served"
r=$(as_user $O aal1 "raise notice 'R=%', public.zella_business_deletion_cancel('$BIZ');"); [[ "$r" == *cancelled* ]] && [ "$(q "select (suspended_at is null)::text || ',' || (select status from public.automations where business_id = '$BIZ') from public.businesses where id = '$BIZ'")" = "true,active" ] && ok "the owner cancels and the freeze lifts" || bad "cancel: $r $(q "select status from public.automations where business_id = '$BIZ'")"
req $O "Gone Soon" > /dev/null; conf $A > /dev/null
purge() { q "select public.zella_business_deletion_purge_due()"; }
[ "$(purge)" = '{"skipped": "switched_off"}' ] && ok "the purge does nothing while lane G's switch is off" || bad "off: $(purge)"
q "begin; set local zella.retention_switch = 'on'; update public.platform_settings set value = 'true' where key = 'retention_purge_enabled'; commit" > /dev/null
[ "$(purge)" = '{"purged": 0}' ] && ok "nor before the 30 days" || bad "early: $(purge)"
q "update public.business_deletion_requests set purge_after = now() - interval '1 minute' where business_id = '$BIZ' and status = 'confirmed'" > /dev/null
purge > /dev/null
if [ "$(q "select confdeltype from pg_constraint where conname = 'audit_logs_business_id_fkey'")" != n ]; then
  [ "$(q "select status || ':' || last_error from public.business_deletion_requests where business_id = '$BIZ' and status <> 'cancelled'")" = "blocked:AUDIT_HISTORY_AT_RISK" ] && ok "refused while audit history would be erased (lane B not applied), and alerted" || bad "blocked: $(q "select status, last_error from public.business_deletion_requests where business_id = '$BIZ'")"
fi
LB=$(git -C "$REPO" show origin/claude/review-lane-b:sql/zella_draft_delete.sql 2>/dev/null)
if [ -z "$LB" ]; then echo "SKIP the purge itself: lane B's sql/zella_draft_delete.sql is not available"; else
  printf '%s\n' "$LB" | "${P[@]}" -d "$DB" -f - > /dev/null 2>&1 || bad "lane B draft delete"
  AUD=$(q "select count(*) from public.audit_logs where business_id = '$BIZ'")
  r=$(purge); [ "$r" = '{"purged": 1}' ] && ok "with lane B applied the business is purged" || bad "purge: $r $(q "select last_error from public.business_deletion_requests where business_id = '$BIZ' and status <> 'cancelled'")"
  [ "$(q "select count(*) from public.businesses where id = '$BIZ'")" = 0 ] && [ "$(q "select count(*) from public.automations where business_id = '$BIZ'")" = 0 ] && ok "its rows are gone" || bad "rows left"
  [ "$(q "select count(*) from public.audit_logs where business_id is null and entity_id in (select id from public.business_deletion_requests where business_id = '$BIZ')")" -ge 1 ] && ok "its audit history is kept without the business (SET NULL)" || bad "audit kept ($AUD before)"
  [ "$(q "select reason from public.provider_deletions where external_id = 'vc-del-1'")" = business_deletion ] && ok "its calls are queued for deletion at Vapi" || bad "vapi queue"
  [ "$(q "select r.status from public.business_deletion_requests d join public.retention_purge_runs r on r.id = d.run_id where d.business_id = '$BIZ' and d.status = 'purged'")" = done ] && ok "recorded as a lane G purge run, and the request as purged" || bad "run"
  [ "$(q "select count(*) from public.audit_logs where action = 'business.purged' and entity_id = '$BIZ'")" = 1 ] && ok "audited as business.purged" || bad "purged audit"
fi
r=$(as_user $A aal2 "raise notice 'R=%', public.zella_admin_business_deletion_requests();"); [[ "$r" == *"Gone Soon"* ]] && ok "Zella Voice admins see the requests" || bad "admin list: $r"
r=$(as_user $O aal1 "raise notice 'R=%', public.zella_admin_business_deletion_requests();"); [[ "$r" == ERR:* ]] && ok "an owner can't list everyone's requests" || bad "owner list: $r"
[[ "$(q "select pg_get_functiondef('public.zella_run_schedule_group(text)'::regprocedure)")" == *"'zella_business_deletion_purge_due']"* ]] && [ "$(q "select public.zella_run_scheduled_job('zella_business_deletion_purge_due')")" = ok ] && ok "it runs in the daily job group" || bad "scheduler"
apply "$REPO/sql/rollback/zella_account_deletion_rollback.sql" > /dev/null && apply "$REPO/sql/rollback/zella_account_deletion_rollback.sql" > /dev/null && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "$before" ] && ok "rollback restores the job lists exactly" || bad "after rollback"
apply "$REPO/sql/zella_account_deletion.sql" > /dev/null
q "create or replace function public.zella_business_deletion_cancel(p_business_id uuid) returns jsonb language sql as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
out=$(apply "$REPO/sql/zella_account_deletion.sql"); [[ "$out" == *VERSION_MISMATCH* ]] && ok "a different existing version stops the file" || bad "drift: $out"
finish
