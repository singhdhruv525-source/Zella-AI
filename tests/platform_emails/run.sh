#!/usr/bin/env bash
# sql/zella_platform_emails.sql on an ISOLATED copy of the production schema (never production): applied twice; never
# twice for one key; dry run while email_live is off (nothing handed to the sender); live claims, retries with backoff
# and holds after 5 attempts with an admin alert; optional emails respect the person's choice; server only writes;
# owners read only their own business; the rollback refuses once something was sent.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zplatformemails
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template zdocs" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }

for i in 1 2; do out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_platform_emails.sql" 2>&1) || { bad "apply (run $i): $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"; exit 1; }; done
ok "applies twice"
for f in "zella_queue_platform_email(uuid,text,text,text,text,text,text,boolean,uuid,text[])" "zella_claim_platform_emails(integer)" "zella_finish_platform_email(uuid,boolean,text,text)"; do
  [ "$(q "select has_function_privilege('authenticated', 'public.$f', 'execute') or has_function_privilege('anon', 'public.$f', 'execute')")" = f ] || bad "$f callable from the browser"
done
[ "$(q "select has_table_privilege('authenticated', 'public.platform_emails', 'insert') or has_table_privilege('authenticated', 'public.platform_emails', 'update') or has_table_privilege('anon', 'public.platform_emails', 'select')")" = f ] \
  && ok "server only: the browser can't queue, claim, finish or write" || bad "browser can write the outbox"

out=$("${P[@]}" -d $DB 2>&1 <<'SQL'
-- test data only
insert into auth.users (id, email) values ('c0000000-0000-4000-8000-000000000001', 'person@example.com');
insert into businesses (id, name) values ('b0000000-0000-4000-8000-0000000000e1', 'Test Clinic'), ('b0000000-0000-4000-8000-0000000000e2', 'Test Other');
insert into notification_preferences (business_id, user_id, notification_type, email_enabled)
  values ('b0000000-0000-4000-8000-0000000000e1', 'c0000000-0000-4000-8000-000000000001', 'email:R1', false);
SQL
) || { bad "seed: $(echo "$out" | grep -m1 ERROR)"; exit 1; }

out=$("${P[@]}" -d $DB 2>&1 <<'SQL'
do $$ declare a uuid; b uuid; n int; r record; begin
  -- never twice
  a := public.zella_queue_platform_email('b0000000-0000-4000-8000-0000000000e1', 'C3', 'email:C3:inv_1:1', 'Owner@Example.com', 'Payment received', '<p>x</p>', 'x', true);
  b := public.zella_queue_platform_email('b0000000-0000-4000-8000-0000000000e1', 'C3', 'email:C3:inv_1:1', 'other@example.com', 'Changed', '<p>y</p>', 'y', true);
  assert a = b, 'same key, same row';
  assert (select count(*) from platform_emails) = 1 and (select to_email from platform_emails) = 'owner@example.com', 'first row kept, address tidied';
  -- a key that doesn't match the code is refused
  begin perform public.zella_queue_platform_email('b0000000-0000-4000-8000-0000000000e1', 'C3', 'email:D1:inv_1:1', 'o@example.com', 's', 'h', 't', true); assert false, 'bad key accepted';
  exception when raise_exception then null; end;
  -- optional email the person switched off: suppressed; the same email mandatory: queued
  perform public.zella_queue_platform_email('b0000000-0000-4000-8000-0000000000e1', 'R1', 'email:R1:2026-11-14:1', 'o@example.com', 's', 'h', 't', false, 'c0000000-0000-4000-8000-000000000001');
  assert (select status from platform_emails where code = 'R1') = 'suppressed', 'opted out email suppressed';
  -- email_live off: claimed rows become dry_run and nothing is handed out
  delete from platform_settings where key = 'email_live';
  select count(*) into n from public.zella_claim_platform_emails(10);
  assert n = 0, 'nothing handed out while email_live is off';
  assert (select status from platform_emails where id = a) = 'dry_run', 'dry run while off';
  raise notice 'PASS never twice for one key; keys must match the code; opted out optional emails are suppressed; dry run while email_live is off';
end $$;
SQL
) && echo "$out" | grep -o 'PASS .*' || bad "queue: $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"

out=$("${P[@]}" -d $DB 2>&1 <<'SQL'
do $$ declare a uuid; n int; i int; s text; begin
  insert into platform_settings (key, value) values ('email_live', 'true'::jsonb) on conflict (key) do update set value = 'true'::jsonb;
  a := public.zella_queue_platform_email('b0000000-0000-4000-8000-0000000000e1', 'D1', 'email:D1:inv_2:1', 'o@example.com', 'Payment failed', 'h', 't', true);
  select count(*) into n from public.zella_claim_platform_emails(10) where id = a;
  assert n = 1, 'live: claimed';
  assert (select count(*) from public.zella_claim_platform_emails(10) where id = a) = 0, 'not claimed twice while sending';
  s := public.zella_finish_platform_email(a, false, null, 'provider timeout');
  assert s = 'queued' and (select next_attempt_at > now() from platform_emails where id = a), 'failure waits before the retry';
  assert public.zella_finish_platform_email(a, true) = 'NOT_SENDING', 'finish only a row being sent';
  -- four more failures: held, with an admin alert, never sent again
  for i in 2..5 loop
    update platform_emails set next_attempt_at = now() - interval '1 second' where id = a;
    assert (select count(*) from public.zella_claim_platform_emails(10) where id = a) = 1, 'retry ' || i;
    perform public.zella_finish_platform_email(a, false, null, 'provider timeout');
  end loop;
  update platform_emails set next_attempt_at = now() - interval '1 second' where id = a;
  assert (select count(*) from public.zella_claim_platform_emails(10) where id = a) = 0, 'no sixth try';
  assert (select status from platform_emails where id = a) = 'held', 'held after 5';
  assert exists (select 1 from platform_alerts where kind = 'platform_email_held' and business_id = 'b0000000-0000-4000-8000-0000000000e1'), 'admin alert';
  -- a good send
  a := public.zella_queue_platform_email('b0000000-0000-4000-8000-0000000000e1', 'S6', 'email:S6:live:1', 'o@example.com', 'Live', 'h', 't', true);
  perform public.zella_claim_platform_emails(10);
  assert public.zella_finish_platform_email(a, true, 'msg_123') = 'sent', 'sent';
  assert (select sent_at is not null and provider_message_id = 'msg_123' from platform_emails where id = a), 'sent recorded';
  raise notice 'PASS live: claimed once, retried with backoff, held after 5 tries with an admin alert, sends recorded';
end $$;
SQL
) && echo "$out" | grep -o 'PASS .*' || bad "send: $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"

# a business's own owner reads only their own rows (row security as a signed in user)
out=$("${P[@]}" -d $DB 2>&1 <<'SQL'
insert into platform_emails (business_id, code, dedupe_key, to_email, subject, html, text_body, mandatory)
  values ('b0000000-0000-4000-8000-0000000000e2', 'S1', 'email:S1:other:1', 'x@example.com', 's', 'h', 't', true);
create or replace function public.zella_has_role(p_business_id uuid, p_roles text[]) returns boolean language sql stable
  as $f$ select p_business_id = 'b0000000-0000-4000-8000-0000000000e1' $f$;   -- test stand in: member of the first business only
set role authenticated;
do $$ begin
  assert (select count(*) from platform_emails where business_id = 'b0000000-0000-4000-8000-0000000000e2') = 0, 'saw another business';
  assert (select count(*) from platform_emails) > 0, 'sees its own';
  raise notice 'PASS an owner reads only their own business''s emails';
end $$;
reset role;
SQL
) && echo "$out" | grep -o 'PASS .*' || bad "row security: $(echo "$out" | grep -m2 -E 'ERROR|CONTEXT' | tr '\n' ' ')"

out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_platform_emails_rollback.sql" 2>&1) && bad "rollback ran with sent emails" || { echo "$out" | grep -q HAS_HISTORY && ok "the rollback refuses once an email was sent"; }
q "delete from platform_emails" > /dev/null
for i in 1 2; do out=$("${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_platform_emails_rollback.sql" 2>&1) || { bad "rollback (run $i): $(echo "$out" | grep -m2 ERROR)"; }; done
[ "$(q "select to_regclass('public.platform_emails') is null and to_regprocedure('public.zella_claim_platform_emails(integer)') is null")" = t ] && ok "the rollback (run twice) removes everything" || bad "rollback left something"
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_platform_emails.sql" 2>&1) && ok "applies again after the rollback" || bad "re-apply: $(echo "$out" | grep -m1 ERROR)"

[ -n "${KEEP_DB:-}" ] || "${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null
[ $fails = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
