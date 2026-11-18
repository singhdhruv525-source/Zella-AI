#!/usr/bin/env bash
# H3: sql/zella_privacy_retention.sql, on a copy with lane G applied and production's zella_erase_customer. Checks:
# drafts are stored as drafts and readable through zella_legal_current (marked draft) by anyone; the owner's
# onboarding acceptance is recorded and audited, a staff member can't; recordings and transcripts are 90 days; the
# automatic deletion does nothing while switched off or pending legal review, and once on removes exactly what is
# past 90 days (not newer calls, not a business on hold), queues the Vapi copies, audits; it is in the daily group and
# allowed by the job runner; erasing a customer queues their calls at Vapi; the queue is sent only while
# vapi_deletion_live is on; applies twice; rollback twice restores the three functions exactly; drift stops both.
. "$(dirname "$0")/lib.sh"; fresh_db privacy_retention
apply "$REPO/tests/security_fixes/prod_erase_customer.sql" > /dev/null || { bad "fixture"; finish; }
SIGS="'public.zella_erase_customer(uuid,uuid)','public.zella_run_scheduled_job(text)','public.zella_run_schedule_group(text)'"
fp() { q "select string_agg(md5(pg_get_functiondef(s::regprocedure)), ',' order by s) from unnest(array[$SIGS]) s"; }; before=$(fp)
out=$(apply "$REPO/sql/zella_privacy_retention.sql") && ok "applies" || { bad "applies: $out"; finish; }
out=$(apply "$REPO/sql/zella_privacy_retention.sql") && ok "applies again" || bad "second apply: $out"
[ "$(q "select count(*) from public.legal_documents where kind in ('privacy', 'terms') and status = 'draft' and title like '%Draft for owner and legal review%'")" = 2 ] && ok "privacy policy and terms are stored as drafts" || bad "drafts"
r=$(q "do \$\$ begin set local role anon; raise notice 'R=%', public.zella_legal_current('privacy') ->> 'draft'; reset role; end \$\$" 2>&1 | sed -n 's/.*R=//p')
[ "$r" = true ] && ok "anyone can read the current privacy policy, marked as a draft" || bad "anon read: $r"
B=$(q "select public.zella_legal_current('privacy') ->> 'body'"); for w in Supabase Vapi Anthropic Telnyx Resend Stripe n8n Persona "90 days" "30 days" "privacy@zellavoice.com"; do [[ "$B" == *"$w"* ]] || bad "policy lacks $w"; done; ok "the policy names every processor, the retention periods and a contact"
[ "$(q "select count(*) from public.legal_documents where body ~ '[-–—]'")" = 0 ] && ok "no dashes in the drafts" || bad "dashes"
BIZ=$(q "insert into public.businesses (name, industry_id, is_active) select 'Retention Test', id, true from public.industries limit 1 returning id" | head -1)
O=f9000000-0000-0000-0000-000000000001; S=f9000000-0000-0000-0000-000000000002
q "insert into auth.users (id, email, email_confirmed_at) values ('$O', 'own@ret.test', now()), ('$S', 'staff@ret.test', now()); insert into public.business_members (business_id, user_id, role, status) values ('$BIZ', '$O', 'owner', 'active'), ('$BIZ', '$S', 'staff', 'active')" > /dev/null
r=$(as_user $S aal1 "perform public.zella_owner_onboarding_legal_accept('$BIZ'); raise notice 'R=ran';"); [[ "$r" == *NOT_ALLOWED* ]] && ok "only the owner records the acceptance" || bad "staff: $r"
r=$(as_user $O aal1 "raise notice 'R=%', public.zella_owner_onboarding_legal_accept('$BIZ');"); [[ "$r" == *privacy* && "$r" == *terms* ]] && ok "the owner's acceptance of both is recorded with their versions" || bad "owner: $r"
[ "$(q "select count(*) from public.legal_acceptances where business_id = '$BIZ' and user_id = '$O'")" = 2 ] && [ "$(q "select count(*) from public.audit_logs where business_id = '$BIZ' and action = 'onboarding.legal_accepted'")" -ge 1 ] && ok "server side, and audited" || bad "acceptance rows"
[ "$(q "select string_agg(data_class || '=' || days, ',' order by data_class) from public.data_retention_policies where data_class in ('call_recordings', 'call_transcripts')")" = "call_recordings=90,call_transcripts=90" ] && ok "recordings and transcripts are kept 90 days" || bad "periods"
# calls: old (100 days), new (10 days), old on a business with a legal hold
mk() { q "insert into public.calls (business_id, direction, status, from_number, external_call_id, recording_url, transcript, created_at, ended_at, ai_handled, duration_seconds) values ('$1', 'inbound', 'answered', '+15125550123', '$2', 'https://storage.vapi.ai/$2.wav', 'Hello', now() - interval '$3 days', now() - interval '$3 days', true, 60) returning id" | head -1; }
OLD=$(mk $BIZ vc-old 100); NEW=$(mk $BIZ vc-new 10)
HB=$(q "insert into public.businesses (name, industry_id, is_active) select 'Held', id, true from public.industries limit 1 returning id" | head -1); HELD=$(mk $HB vc-held 100)
q "insert into public.legal_holds (business_id, reason, placed_by) values ('$HB', 'litigation', '$O')" > /dev/null 2>&1 || q "insert into public.legal_holds (business_id, reason) values ('$HB', 'litigation')" > /dev/null
run() { q "select public.zella_retention_auto_run()"; }
[ "$(run)" = '{"skipped": "switched_off"}' ] && ok "switched off: nothing happens" || bad "off: $(run)"
q "begin; set local zella.retention_switch = 'on'; update public.platform_settings set value = 'true' where key = 'retention_purge_enabled'; commit" > /dev/null
[[ "$(run)" == *legal_review_pending* ]] && [ "$(q "select recording_url is not null from public.calls where id = '$OLD'")" = t ] && ok "on but pending legal review: nothing happens" || bad "pending: $(run)"
q "update public.data_retention_policies set legal_status = 'approved' where data_class in ('call_recordings', 'call_transcripts')" > /dev/null
r=$(run); [ "$r" = '{"call_recordings": 1, "call_transcripts": 1}' ] && ok "on and approved: the old call loses its recording and transcript ($r)" || bad "run: $r"
[ "$(q "select (recording_url is null)::text || transcript from public.calls where id = '$OLD'")" = "trueRemoved under the retention policy." ] && ok "exactly as lane G's purge marks them" || bad "old row"
[ "$(q "select count(*) from public.calls where id in ('$NEW', '$HELD') and recording_url is not null and transcript = 'Hello'")" = 2 ] && ok "a newer call and a business on a legal hold are left alone" || bad "kept"
[ "$(q "select string_agg(external_id || ':' || reason || ':' || status, ',') from public.provider_deletions")" = "vc-old:retention:queued" ] && ok "the copy at Vapi is queued for deletion" || bad "queue: $(q "select string_agg(external_id, ',') from public.provider_deletions")"
[ "$(q "select count(*) from public.audit_logs where action = 'retention.auto_purge'")" = 2 ] && ok "each removal is audited (counts only)" || bad "audit"
[ "$(run)" = '{"call_recordings": 0, "call_transcripts": 0}' ] && ok "running again removes nothing more" || bad "rerun"
[ "$(q "select public.zella_run_scheduled_job('zella_retention_auto_run')")" = ok ] && [[ "$(q "select pg_get_functiondef('public.zella_run_schedule_group(text)'::regprocedure)")" == *"'zella_run_permission_check', 'zella_retention_auto_run']"* ]] && ok "it runs in the daily job group" || bad "scheduler"
# erasure
C=$(q "insert into public.customers (business_id, first_name, phone) values ('$BIZ', 'Pat', '+15125550199') returning id" | head -1)
q "update public.calls set customer_id = '$C' where id = '$NEW'" > /dev/null
q "create or replace function public.zella_approval_ok(p_business_id uuid, p_action text, p_entity_id uuid) returns boolean language sql as \$f\$ select true \$f\$" > /dev/null
q "alter table public.customers alter column qualification drop not null" > /dev/null   # production's customers allow it (the copy is older)
r=$(as_user $O aal1 "raise notice 'R=%', public.zella_erase_customer('$BIZ', '$C');"); [ "$r" = erased ] && [ "$(q "select reason from public.provider_deletions where external_id = 'vc-new'")" = customer_erasure ] && ok "erasing a customer queues their calls at Vapi" || bad "erase: $r"
# the worker's claim
[ "$(q "select public.zella_provider_deletions_claim(10)")" = "[]" ] && ok "nothing is handed to the worker while vapi_deletion_live is off" || bad "claim off"
q "update public.platform_settings set value = 'true' where key = 'vapi_deletion_live'" > /dev/null
r=$(q "select jsonb_array_length(public.zella_provider_deletions_claim(10))"); [ "$r" = 2 ] && ok "once on, the queue is handed out" || bad "claim on: $r"
ID=$(q "select id from public.provider_deletions where external_id = 'vc-old'"); q "select public.zella_provider_deletion_result('$ID', 'done')" > /dev/null
[ "$(q "select status from public.provider_deletions where id = '$ID'")" = done ] && ok "and each result is recorded" || bad "result"
q "update public.platform_settings set value = 'false' where key = 'vapi_deletion_live'" > /dev/null
r=$(as_user $O aal1 "perform count(*) from public.provider_deletions; raise notice 'R=ran';"); [[ "$r" == *"permission denied"* ]] && ok "the queue is server only" || bad "queue readable: $r"

apply "$REPO/sql/rollback/zella_privacy_retention_rollback.sql" > /dev/null && apply "$REPO/sql/rollback/zella_privacy_retention_rollback.sql" > /dev/null && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "$before" ] && ok "rollback restores the three functions exactly" || bad "after rollback"
[ "$(q "select days from public.data_retention_policies where data_class = 'call_recordings'")" = 30 ] && ok "and lane G's periods" || bad "periods back"
apply "$REPO/sql/zella_privacy_retention.sql" > /dev/null && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_run_scheduled_job(p_job text) returns text language sql as \$f\$ select 'x' \$f\$" > /dev/null
out=$(apply "$REPO/sql/rollback/zella_privacy_retention_rollback.sql"); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "the rollback refuses a changed function" || bad "rollback drift: $out"
q "delete from public.zella_function_archive where migration = 'zella_privacy_retention'" > /dev/null
out=$(apply "$REPO/sql/zella_privacy_retention.sql"); [[ "$out" == *VERSION_MISMATCH* ]] && ok "an unknown version stops the file" || bad "drift: $out"
finish
