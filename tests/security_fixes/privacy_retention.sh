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
# an owner set the recording period to 60 days before this file: the rollback must put back 60, not lane G's 30
q "update public.data_retention_policies set days = 60 where data_class = 'call_recordings'" > /dev/null
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
js() { python3 -I -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('$1'))" "$2"; }
[ "$(run)" = '{"skipped": "switched_off"}' ] && ok "switched off: nothing happens" || bad "off: $(run)"
q "begin; set local zella.retention_switch = 'on'; update public.platform_settings set value = 'true' where key = 'retention_purge_enabled'; commit" > /dev/null
[[ "$(run)" == *legal_review_pending* ]] && [ "$(q "select recording_url is not null from public.calls where id = '$OLD'")" = t ] && ok "on but pending legal review: nothing happens" || bad "pending: $(run)"
q "update public.data_retention_policies set legal_status = 'approved' where data_class = 'call_recordings'" > /dev/null
r=$(run); [ "$(q "select (recording_url is null)::text from public.calls where id = '$OLD'")" = true ] && [ "$(q "select count(*) from public.provider_deletions")" = 0 ] && ok "recordings approved, transcripts pending: the recording goes, nothing is queued at Vapi (it holds both)" || bad "recordings only: $r"
q "update public.data_retention_policies set legal_status = 'approved' where data_class = 'call_transcripts'" > /dev/null
r=$(run); [ "$(js call_transcripts "$r")$(js vapi_queued "$r")" = "11" ] && ok "both approved: the transcript goes and the call is queued at Vapi ($r)" || bad "run: $r"
[ "$(q "select (recording_url is null)::text || transcript from public.calls where id = '$OLD'")" = "trueRemoved under the retention policy." ] && ok "exactly as lane G's purge marks them" || bad "old row"
[ "$(q "select count(*) from public.calls where id in ('$NEW', '$HELD') and recording_url is not null and transcript = 'Hello'")" = 2 ] && ok "a newer call and a business on a legal hold are left alone" || bad "kept"
[ "$(q "select string_agg(external_id || ':' || reason || ':' || status, ',') from public.provider_deletions")" = "vc-old:retention:queued" ] && ok "the copy at Vapi is queued for deletion" || bad "queue: $(q "select string_agg(external_id, ',') from public.provider_deletions")"
[ "$(q "select count(*) from public.audit_logs where action = 'retention.auto_purge'")" = 2 ] && ok "each removal is audited (counts only)" || bad "audit"
[ "$(run)" = '{"vapi_queued": 0, "call_recordings": 0, "call_transcripts": 0}' ] && ok "running again removes nothing more" || bad "rerun: $(run)"
# a backlog over one batch is cleared in one run
q "insert into public.calls (business_id, direction, status, from_number, external_call_id, recording_url, transcript, created_at, ended_at, ai_handled, duration_seconds) select '$BIZ', 'inbound', 'answered', '+15125550123', 'vc-bulk-' || n, 'https://storage.vapi.ai/x.wav', 'Hi', now() - interval '120 days', now() - interval '120 days', true, 60 from generate_series(1, 1500) n" > /dev/null
r=$(run); [ "$(js call_recordings "$r")$(js call_transcripts "$r")$(js vapi_queued "$r")" = "150015001500" ] && ok "a backlog of 1500 calls is cleared in one run" || bad "drain: $r"
[[ "$(q "select pg_get_functiondef('public.zella_retention_auto_run()'::regprocedure)")" == *"hashtextextended('zella_legal_holds', 0)"* ]] && ok "it takes lane G's legal hold lock before choosing" || bad "lock"
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
# the backlog rows were handled already (the claim hands out at most 100 at a time)
q "update public.provider_deletions set status = 'done' where external_id like 'vc-bulk-%'" > /dev/null
q "select public.zella_queue_provider_deletion('$HB', 'vc-held', 'customer_erasure')" > /dev/null
r=$(q "select count(*) from jsonb_array_elements(public.zella_provider_deletions_claim(100)) x where x ->> 'external_id' in ('vc-old', 'vc-new', 'vc-held')"); [ "$r" = 2 ] && ok "once on, the queue is handed out, except a business on a legal hold" || bad "claim on: $r"
[ "$(q "select status from public.provider_deletions where external_id = 'vc-held'")" = queued ] && ok "the held business's deletion waits, queued" || bad "held claimed"
ID=$(q "select id from public.provider_deletions where external_id = 'vc-old'"); q "select public.zella_provider_deletion_result('$ID', 'done')" > /dev/null
[ "$(q "select status from public.provider_deletions where id = '$ID'")" = done ] && ok "and each result is recorded" || bad "result"
q "update public.platform_settings set value = 'false' where key = 'vapi_deletion_live'" > /dev/null
r=$(as_user $O aal1 "perform count(*) from public.provider_deletions; raise notice 'R=ran';"); [[ "$r" == *"permission denied"* ]] && ok "the queue is server only" || bad "queue readable: $r"

apply "$REPO/sql/rollback/zella_privacy_retention_rollback.sql" > /dev/null && apply "$REPO/sql/rollback/zella_privacy_retention_rollback.sql" > /dev/null && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "$before" ] && ok "rollback restores the three functions exactly" || bad "after rollback"
[ "$(q "select days from public.data_retention_policies where data_class = 'call_recordings'")" = 60 ] && ok "and exactly the periods it found (60 days, set by the owner)" || bad "periods back: $(q "select days from public.data_retention_policies where data_class = 'call_recordings'")"
[ "$(q "select count(*) from public.provider_deletions")" -ge 1500 ] && ok "and keeps the Vapi deletion queue" || bad "queue dropped"
apply "$REPO/sql/zella_privacy_retention.sql" > /dev/null && ok "applies again after the rollback" || bad "reapply"
q "update public.data_retention_policies set days = 45 where data_class = 'call_transcripts'" > /dev/null
out=$(apply "$REPO/sql/rollback/zella_privacy_retention_rollback.sql"); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "the rollback refuses once a period was changed after the migration" || bad "period drift: $out"
q "update public.data_retention_policies set days = 90 where data_class = 'call_transcripts'" > /dev/null
q "create or replace function public.zella_run_scheduled_job(p_job text) returns text language sql as \$f\$ select 'x' \$f\$" > /dev/null
out=$(apply "$REPO/sql/rollback/zella_privacy_retention_rollback.sql"); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "the rollback refuses a changed function" || bad "rollback drift: $out"
q "delete from public.zella_function_archive where migration = 'zella_privacy_retention'" > /dev/null
out=$(apply "$REPO/sql/zella_privacy_retention.sql"); [[ "$out" == *VERSION_MISMATCH* ]] && ok "an unknown version stops the file" || bad "drift: $out"
finish
