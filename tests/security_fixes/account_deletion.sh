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
S2=fa000000-0000-0000-0000-000000000005
q "insert into auth.users (id, email, email_confirmed_at) values ('$S2', 'sup@del.test', now()); insert into public.platform_admins (user_id, role, is_active) values ('$S2', 'support_admin', true)" > /dev/null
r=$(conf $S2); [[ "$r" == ERR:* ]] && ok "an admin without security.manage can't confirm" || bad "support confirmed: $r"
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
# lane B's sql/zella_draft_delete.sql (audit history kept with business_id null, ACC-10) is in the template: it comes
# before this file in the go live order
[ "$(q "select confdeltype from pg_constraint where conname = 'audit_logs_business_id_fkey'")" = n ] && ok "lane B's audit SET NULL is in place (go live order)" || bad "lane B missing from the template"
AUD=$(q "select count(*) from public.audit_logs where business_id = '$BIZ'")
r=$(purge); [ "$r" = '{"purged": 1}' ] && ok "past its 30 days the business is purged" || bad "purge: $r $(q "select last_error from public.business_deletion_requests where business_id = '$BIZ' and status <> 'cancelled'")"
[ "$(q "select count(*) from public.businesses where id = '$BIZ'")" = 0 ] && [ "$(q "select count(*) from public.automations where business_id = '$BIZ'")" = 0 ] && ok "its rows are gone" || bad "rows left"
[ "$(q "select count(*) from public.audit_logs where business_id is null and entity_id in (select id from public.business_deletion_requests where business_id = '$BIZ')")" -ge 1 ] && ok "its audit history is kept without the business (SET NULL)" || bad "audit kept ($AUD before)"
[ "$(q "select reason from public.provider_deletions where external_id = 'vc-del-1'")" = business_deletion ] && ok "its calls are queued for deletion at Vapi" || bad "vapi queue"
RUN=$(q "select run_id from public.business_deletion_requests where business_id = '$BIZ' and status = 'purged'")
[ "$(q "select status || ':' || cardinality(removed_paths) from public.retention_purge_runs where id = '$RUN'")" = "done:0" ] && ok "recorded as a lane G purge run (done, removed_paths empty), the request as purged" || bad "run: $(q "select status, removed_paths from public.retention_purge_runs where id = '$RUN'")"
[ "$(q "select count(*) from public.audit_logs where action = 'business.purged' and entity_id = '$BIZ'")" = 1 ] && ok "audited as business.purged" || bad "purged audit"
# files: a purged business's stored files go through lane G's hand off (files_pending, then zella_business_purge_files_done)
mkbiz() { q "insert into public.businesses (name, industry_id, is_active) select '$1', id, true from public.industries limit 1 returning id" | head -1; }
own() { q "insert into public.business_members (business_id, user_id, role, status) values ('$1', '$O', 'owner', 'active')" > /dev/null; }
ask() { as_user $O aal1 "perform public.zella_business_deletion_request('$1', '$2', 'Closing the shop'); raise notice 'R=ok';"; as_user $A aal2 "perform public.zella_admin_business_deletion_confirm('$1', 'Owner confirmed by phone'); raise notice 'R=ok';"; q "update public.business_deletion_requests set purge_after = now() - interval '1 minute' where business_id = '$1' and status = 'confirmed'" > /dev/null; }
B2=$(mkbiz "Files Co"); own $B2
q "insert into storage.objects (bucket_id, name) values ('brand-assets', '$B2/logo.png')" > /dev/null
ask $B2 "Files Co" > /dev/null; purge > /dev/null
RUN2=$(q "select run_id from public.business_deletion_requests where business_id = '$B2' and status = 'purged'")
[ "$(q "select status || ':' || array_to_string(file_paths, ',') from public.retention_purge_runs where id = '$RUN2'")" = "files_pending:brand-assets/$B2/logo.png" ] && ok "a purge with stored files waits for their removal (files_pending)" || bad "files pending: $(q "select status, file_paths from public.retention_purge_runs where id = '$RUN2'")"
X=fa000000-0000-0000-0000-000000000004
q "insert into auth.users (id, email, email_confirmed_at) values ('$X', 'adm2@del.test', now()); insert into public.platform_admins (user_id, role, is_active) values ('$X', 'zella_owner', true)" > /dev/null
r=$(q "select public.zella_business_purge_files_done('$X', '$RUN2', array['brand-assets/$B2/logo.png'], null)" 2>&1); [[ "$r" == *APPROVER_REQUIRED* ]] && ok "another admin who neither confirmed nor ran it can't report the files" || bad "other admin: $r"
r=$(q "select public.zella_business_purge_files_done('$A', '$RUN2', array['brand-assets/$B2/logo.png'], null) ->> 'status'"); [ "$r" = done ] && ok "the confirming admin (executor, security.manage) reports them removed" || bad "files done: $r"
[ "$(q "select array_to_string(removed_paths, ',') from public.retention_purge_runs where id = '$RUN2'")" = "brand-assets/$B2/logo.png" ] && ok "removed_paths records exactly what was removed" || bad "removed_paths"
r=$(q "select public.zella_business_purge_files_done('$A', '$RUN2', array['brand-assets/$B2/logo.png'], null)" 2>&1); [[ "$r" == *NOT_RUNNING* ]] && ok "a late second report is refused (only files_pending runs accept one)" || bad "late report: $r"
# a legal hold (lane G's zella_legal_hold_place, under the same lock) stops a confirmed deletion
B3=$(mkbiz "Held Co"); own $B3; ask $B3 "Held Co" > /dev/null
q "select public.zella_legal_hold_place('$A', '$B3', 'litigation')" > /dev/null
purge > /dev/null
[ "$(q "select status || ':' || last_error from public.business_deletion_requests where business_id = '$B3'")" = "blocked:LEGAL_HOLD" ] && [ "$(q "select count(*) from public.businesses where id = '$B3'")" = 1 ] && ok "a business on a legal hold is not purged (blocked, alerted)" || bad "hold: $(q "select status, last_error from public.business_deletion_requests where business_id = '$B3'")"
[[ "$(q "select pg_get_functiondef('public.zella_business_deletion_purge_due()'::regprocedure)")" == *"hashtextextended('zella_legal_holds', 0)"* ]] && ok "the purge takes lane G's legal hold lock" || bad "lock"
[[ "$(q "select pg_get_functiondef('public.zella_run_schedule_group(text)'::regprocedure)")" == *"'zella_business_deletion_purge_due']"* ]] && [ "$(q "select public.zella_run_scheduled_job('zella_business_deletion_purge_due')")" = ok ] && ok "it runs in the daily job group" || bad "scheduler"
apply "$REPO/sql/rollback/zella_account_deletion_rollback.sql" > /dev/null && apply "$REPO/sql/rollback/zella_account_deletion_rollback.sql" > /dev/null && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "$before" ] && ok "rollback restores the job lists exactly" || bad "after rollback"
apply "$REPO/sql/zella_account_deletion.sql" > /dev/null
q "create or replace function public.zella_business_deletion_cancel(p_business_id uuid) returns jsonb language sql as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
out=$(apply "$REPO/sql/zella_account_deletion.sql"); [[ "$out" == *VERSION_MISMATCH* ]] && ok "a different existing version stops the file" || bad "drift: $out"
finish
