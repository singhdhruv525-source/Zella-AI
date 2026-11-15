#!/usr/bin/env bash
# sql/zella_email_delivery.sql on an ISOLATED copy of the production schema (never production), after the migrations it
# needs: applied twice; server only; the same email rules as the old n8n path (owners and admins, or the one person;
# summaries, warnings and urgent alerts; each person's choice); the old path returns nothing and the n8n dispatcher no
# longer counts it; the database only calls the edge function when it is set up and there is work; the secret check;
# the rollback (run twice) restores both changed functions exactly. Test data only.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zemaildelivery
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template zdocs" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
for f in zella_fk_indexes zella_model_defaults zella_unsubscribe_limit zella_tenant_business_id zella_billing_allowances zella_platform_emails; do
  "${P[@]}" -d $DB -f "$REPO/sql/$f.sql" > /dev/null 2>&1 || { bad "prerequisite $f"; exit 1; }
done
before_owner=$(q "select md5(pg_get_functiondef('public.zella_claim_owner_emails(integer)'::regprocedure))")
before_dispatch=$(q "select md5(pg_get_functiondef('public.zella_dispatch_n8n()'::regprocedure))")
before_claim=$(q "select md5(pg_get_functiondef('public.zella_claim_platform_emails(integer)'::regprocedure))")
# a setting that already exists before the migration must survive its rollback
q "insert into platform_settings (key, value) values ('platform_emails_url', '\"\"'::jsonb)" > /dev/null

for i in 1 2; do out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_email_delivery.sql" 2>&1) || { bad "apply (run $i): $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"; exit 1; }; done
ok "applies twice"
[ "$(q "select bool_or(has_function_privilege(r, f, 'execute')) from unnest(array['anon','authenticated']) r, unnest(array['public.zella_claim_notification_emails(integer)','public.zella_platform_emails_check(text)','public.zella_dispatch_platform_emails()']) f")" = f ] \
  && ok "server only" || bad "callable from the browser"
[ "$(q "select count(*) from vault.secrets where name = 'zella_platform_emails_secret'")" = 1 ] && [ "$(q "select count(*) from cron.job where jobname = 'zella_platform_emails'")" = 1 ] \
  && ok "one secret in Vault and one job, even after two runs" || bad "secret or job missing or doubled"

out=$("${P[@]}" -d $DB 2>&1 <<'SQL'
insert into auth.users (id, email) values ('c0000000-0000-4000-8000-0000000000e1', 'owner@example.com'), ('c0000000-0000-4000-8000-0000000000e2', 'admin@example.com'),
  ('c0000000-0000-4000-8000-0000000000e3', 'staff@example.com');
insert into businesses (id, name) values ('b0000000-0000-4000-8000-0000000000d1', 'Test Clinic');
insert into business_members (business_id, user_id, role, status) values
  ('b0000000-0000-4000-8000-0000000000d1', 'c0000000-0000-4000-8000-0000000000e1', 'owner', 'active'),
  ('b0000000-0000-4000-8000-0000000000d1', 'c0000000-0000-4000-8000-0000000000e2', 'admin', 'active'),
  ('b0000000-0000-4000-8000-0000000000d1', 'c0000000-0000-4000-8000-0000000000e3', 'staff', 'active');
-- the admin switched off emails for on call gaps
insert into notification_preferences (business_id, user_id, notification_type, email_enabled)
  values ('b0000000-0000-4000-8000-0000000000d1', 'c0000000-0000-4000-8000-0000000000e2', 'on_call_gap', false);
insert into staff_notifications (id, business_id, kind, title, body, severity, page_key, user_id, delivery_status) values
  ('a1000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-0000000000d1', 'on_call_gap', 'Gaps in cover', 'Nobody from Saturday 18:00.', 'warning', 'on_call', null, 'pending'),
  ('a1000000-0000-4000-8000-000000000002', 'b0000000-0000-4000-8000-0000000000d1', 'new_lead', 'A new lead', null, 'info', 'leads', null, 'pending'),
  ('a1000000-0000-4000-8000-000000000003', 'b0000000-0000-4000-8000-0000000000d1', 'task_overdue', 'A task is late', 'Call Sam back', 'warning', 'tasks', 'c0000000-0000-4000-8000-0000000000e3', 'pending');
SQL
) || { bad "seed: $(echo "$out" | grep -m1 ERROR)"; exit 1; }

out=$("${P[@]}" -d $DB 2>&1 <<'SQL'
do $$ declare r jsonb; begin
  assert public.zella_claim_owner_emails(10) = '[]'::jsonb, 'old path retired';
  r := public.zella_claim_notification_emails(10);
  -- warning to owners and admins: only the owner (the admin switched it off); info: nobody (skipped); one person's: that person
  assert (select count(*) from jsonb_array_elements(r) x where x ->> 'notification_id' = 'a1000000-0000-4000-8000-000000000001') = 1, 'gap: owner only';
  assert (select x ->> 'to' from jsonb_array_elements(r) x where x ->> 'notification_id' = 'a1000000-0000-4000-8000-000000000001') = 'owner@example.com', 'gap to owner';
  assert (select x ->> 'to' from jsonb_array_elements(r) x where x ->> 'notification_id' = 'a1000000-0000-4000-8000-000000000003') = 'staff@example.com', 'personal to that person';
  assert not exists (select 1 from jsonb_array_elements(r) x where x ->> 'notification_id' = 'a1000000-0000-4000-8000-000000000002'), 'info not emailed';
  assert (select delivery_status from staff_notifications where id = 'a1000000-0000-4000-8000-000000000002') = 'skipped', 'info skipped';
  assert (select delivery_status from staff_notifications where id = 'a1000000-0000-4000-8000-000000000001') = 'sending', 'claimed';
  assert public.zella_claim_notification_emails(10) = '[]'::jsonb, 'not claimed twice';
  assert (select x ->> 'title' from jsonb_array_elements(r) x where x ->> 'notification_id' = 'a1000000-0000-4000-8000-000000000001') = 'Gaps in cover', 'facts carried';
  raise notice 'PASS the same rules as before: owners and admins or the one person, summaries and warnings, each person''s choice; claimed once; the old n8n path returns nothing';
end $$;
SQL
) && echo "$out" | grep -o 'PASS .*' || bad "claim: $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"

[ "$(q "select position('when ''owner-emails'' then' in pg_get_functiondef('public.zella_dispatch_n8n()'::regprocedure))")" = 0 ] && ok "the n8n dispatcher no longer wakes Owner Emails" || bad "n8n still counts owner emails"

out=$("${P[@]}" -d $DB 2>&1 <<'SQL'
do $$ begin
  assert public.zella_dispatch_platform_emails() = 'not_set_up', 'no url';
  update platform_settings set value = '"https://example.invalid/functions/v1/platform-emails"' where key = 'platform_emails_url';
  update staff_notifications set delivery_status = 'sent';
  delete from platform_emails;
  assert public.zella_dispatch_platform_emails() = 'nothing_due', 'no work, no call';
  update staff_notifications set delivery_status = 'pending' where id = 'a1000000-0000-4000-8000-000000000001';
  assert public.zella_dispatch_platform_emails() = 'called', 'work: called';
  assert public.zella_platform_emails_check((select decrypted_secret from vault.decrypted_secrets where name = 'zella_platform_emails_secret')), 'right secret';
  assert not public.zella_platform_emails_check('wrong') and not public.zella_platform_emails_check(null) and not public.zella_platform_emails_check(''), 'wrong secret';
  -- an email for someone who is no longer an active member is cancelled, never sent (even after a reactivation)
  insert into platform_emails (business_id, user_id, code, dedupe_key, to_email, subject, html, text_body, mandatory)
    values ('b0000000-0000-4000-8000-0000000000d1', 'c0000000-0000-4000-8000-0000000000e3', 'N1', 'email:N1:x:staff', 'staff@example.com', 's', 'h', 't', false),
           ('b0000000-0000-4000-8000-0000000000d1', 'c0000000-0000-4000-8000-0000000000e1', 'N1', 'email:N1:x:owner', 'owner@example.com', 's', 'h', 't', false);
  update business_members set status = 'suspended' where user_id = 'c0000000-0000-4000-8000-0000000000e3';
  perform public.zella_claim_platform_emails(10);
  assert (select status from platform_emails where dedupe_key = 'email:N1:x:staff') = 'suppressed', 'former member cancelled';
  assert (select status from platform_emails where dedupe_key = 'email:N1:x:owner') = 'dry_run', 'active member: test mode as usual';
  update business_members set status = 'active' where user_id = 'c0000000-0000-4000-8000-0000000000e3';
  perform public.zella_claim_platform_emails(10);
  assert (select status from platform_emails where dedupe_key = 'email:N1:x:staff') = 'suppressed', 'reactivation does not resend';
  raise notice 'PASS the edge function is called only when it is set up and there is work; only the Vault secret is accepted; an email to someone no longer an active member is cancelled';
end $$;
SQL
) && echo "$out" | grep -o 'PASS .*' || bad "dispatch: $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"

# the rollback waits while notification emails are still in the outbox
q "insert into platform_emails (business_id, code, dedupe_key, to_email, subject, html, text_body, mandatory) values ('b0000000-0000-4000-8000-0000000000d1', 'N1', 'email:N1:pending:1', 'o@example.com', 's', 'h', 't', false)" > /dev/null
if out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_email_delivery_rollback.sql" 2>&1); then bad "rollback ran with emails waiting"
elif echo "$out" | grep -q HAS_PENDING; then ok "the rollback refuses while notification emails are waiting"
else bad "rollback failed for another reason: $(echo "$out" | grep -m1 ERROR)"; fi
q "delete from platform_emails where code = 'N1' and status in ('queued', 'sending')" > /dev/null
for i in 1 2; do out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_email_delivery_rollback.sql" 2>&1) || bad "rollback (run $i): $(echo "$out" | grep -m2 ERROR)"; done
[ "$(q "select md5(pg_get_functiondef('public.zella_claim_owner_emails(integer)'::regprocedure))")" = "$before_owner" ] \
  && [ "$(q "select md5(pg_get_functiondef('public.zella_dispatch_n8n()'::regprocedure))")" = "$before_dispatch" ] \
  && [ "$(q "select md5(pg_get_functiondef('public.zella_claim_platform_emails(integer)'::regprocedure))")" = "$before_claim" ] \
  && [ "$(q "select count(*) from platform_settings where key = 'platform_emails_url'")" = 1 ] \
  && [ "$(q "select to_regprocedure('public.zella_claim_notification_emails(integer)') is null and not exists (select 1 from cron.job where jobname = 'zella_platform_emails') and not exists (select 1 from vault.secrets where name = 'zella_platform_emails_secret')")" = t ] \
  && ok "the rollback (run twice) restores all three functions exactly, keeps the setting that was already there and removes the job and the secret it made" || bad "rollback left a difference"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_email_delivery.sql" 2>&1) && ok "applies again after the rollback" || bad "re-apply: $(echo "$out" | grep -m1 ERROR)"

# only the known original is replaced: a changed zella_claim_owner_emails stops the migration
"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_email_delivery_rollback.sql" > /dev/null 2>&1
q "create or replace function public.zella_claim_owner_emails(p_limit integer default 20) returns jsonb language sql as \$f\$ select '[1]'::jsonb \$f\$" > /dev/null
if out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_email_delivery.sql" 2>&1); then bad "replaced an unknown version"
elif echo "$out" | grep -q VERSION_MISMATCH; then ok "an unknown version of the old function is never replaced"
else bad "failed for another reason: $(echo "$out" | grep -m1 ERROR)"; fi

[ -n "${KEEP_DB:-}" ] || "${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null
[ $fails = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
