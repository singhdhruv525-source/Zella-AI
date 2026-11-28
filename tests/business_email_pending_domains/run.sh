#!/usr/bin/env bash
# sql/zella_business_email_pending_domains.sql on an ISOLATED copy of the schema baseline (never production), after the
# rest of the business email stack, sql/zella_business_email_caps.sql and sql/zella_business_email_mailbox_link.sql.
# Test data and fake Resend ids only; Resend is never called (the stub net.http_post only records the wake up call).
# Checks: refused before the link file and on a status read it wasn't written for; applies twice; a domain already
# pending starts its 7 days at apply; the daily job is created switched OFF, once; the setting and the Vault secret;
# row security and server only grants; the 7 day clock (set when a domain is set up or becomes unverified, kept while
# it stays unverified, cleared once verified or gone); until removal the business sends from the fallback with its own
# name; the job: a day 2 and a day 5 reminder (once each, a warning so the platform email path emails it, no dashes),
# removal from day 7 only after the day 5 reminder (a job switched on late warns first), a verified domain never
# touched; the removed domain is free for another business, the business is told, and its Resend domain is queued;
# an admin removes a pending domain at once (who may, a reason, never a verified domain, audited); the removal queue
# (claim with a token, done, retried with a longer wait, skipped when a business uses that Resend domain again, failed
# with an admin alert after 5 tries); the wake up call only when set up and there is work; the secret check; the status
# read (a removal date only while the job is on; who may remove now); the rollback refuses while removals are
# recorded, then runs twice and restores everything exactly; applies again.
#   tests/business_email_pending_domains/run.sh      (env ZPG_HOST ZPG_PORT; KEEP=1 keeps the database)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zbizempend
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
MIG="$REPO/sql/zella_business_email_pending_domains.sql"; RB="$REPO/sql/rollback/zella_business_email_pending_domains_rollback.sql"
STACK=(sql/zella_platform_emails.sql tests/business_email/prod_prepare_email.sql sql/zella_oauth_states.sql sql/zella_business_email.sql
       sql/zella_business_email_send.sql sql/zella_email_action_buttons.sql sql/zella_business_email_mailbox.sql sql/zella_business_email_caps.sql)
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
if [ "$("${P[@]}" -d postgres -c "select count(*) from pg_database where datname = 'zbase'")" != 1 ]; then
  "$REPO/sql/baseline/restore.sh" zbase > /dev/null 2>&1 || { echo "could not restore sql/baseline into zbase"; exit 1; }
fi
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template zbase" > /dev/null || exit 1
q() { "${P[@]}" -d "$DB" -c "set client_min_messages = warning" -c "$1"; }
apply() { "${P[@]}" -d "$DB" -c "set client_min_messages = warning" -f "$1" 2>&1; }
rollback() { "$REPO/sql/rollback/run.sh" "$RB" -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -d "$DB" -q 2>&1; }
md5of() { q "select md5(pg_get_functiondef('$1'::regprocedure))"; }
j() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(str(d.get(k)) for k in sys.argv[1:]))' "$@"; }
as() { q "do \$\$ declare r text; begin perform set_config('request.jwt.claims', json_build_object('sub', '$1', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '$1', true); set local role authenticated; begin r := $2; exception when others then r := 'ERR:' || sqlerrm; end; reset role;
  raise warning 'R=%', r; end \$\$" 2>&1 | sed -n 's/.*R=//p' | head -1; }
STA=public.zella_business_email_status\(uuid\)

for f in "${STACK[@]}"; do apply "$REPO/$f" > /dev/null || { bad "prerequisite $f"; exit 1; }; done
out=$(apply "$MIG"); echo "$out" | grep -q "VERSION_MISMATCH" && [ "$(q "select to_regclass('public.business_email_domain_removals') is null")" = t ] \
  && ok "refused before sql/zella_business_email_mailbox_link.sql; nothing created" || bad "applied without the link file: $out"
apply "$REPO/sql/zella_business_email_mailbox_link.sql" > /dev/null || { bad "prerequisite link"; exit 1; }
B_STA=$(md5of "$STA")
q "select public.zella_patch_function('$STA', '/* other */', '-- the route set up', '/* other */ -- the route set up')" > /dev/null
out=$(apply "$MIG"); echo "$out" | grep -q VERSION_MISMATCH && [ "$(q "select count(*) from information_schema.columns where table_name = 'business_email_senders' and column_name = 'domain_pending_since'")" = 0 ] \
  && ok "a status read it wasn't written for is refused; nothing changes" || bad "foreign status not refused: $out"
q "select public.zella_patch_function('$STA', 'zzz_never', '/* other */ -- the route set up', '-- the route set up')" > /dev/null

# test people and businesses only; Zella Voice's Resend ids are made up
A=b8000000-0000-4000-8000-000000000001; B=b8000000-0000-4000-8000-000000000002; C=b8000000-0000-4000-8000-000000000003; D=b8000000-0000-4000-8000-000000000004
OWN=a8000000-0000-4000-8000-000000000001; ADM=a8000000-0000-4000-8000-000000000002; OWNB=a8000000-0000-4000-8000-000000000003
ZOPS=a8000000-0000-4000-8000-000000000011; ZRO=a8000000-0000-4000-8000-000000000012
out=$(q "insert into auth.users (id, email) values ('$OWN', 'owner@a.example.test'), ('$ADM', 'admin@a.example.test'), ('$OWNB', 'owner@b.example.test'),
    ('$ZOPS', 'ops@zv.example.test'), ('$ZRO', 'ro@zv.example.test');
  insert into businesses (id, name, email, timezone) values ('$A', 'Test Salon', 'front@a.example.test', 'America/Denver'), ('$B', 'Other Studio', 'front@b.example.test', 'America/New_York'),
    ('$C', 'Old Clinic', 'front@c.example.test', 'America/Chicago'), ('$D', 'Verified Cafe', 'front@d.example.test', 'America/New_York');
  insert into business_members (business_id, user_id, role, status) values ('$A', '$OWN', 'owner', 'active'), ('$A', '$ADM', 'admin', 'active'), ('$B', '$OWNB', 'owner', 'active');
  set session_replication_role = replica;
  insert into platform_admins (user_id, role, is_active) values ('$ZOPS', 'platform_operations', true), ('$ZRO', 'read_only_admin', true);
  insert into platform_role_permissions (role, permission) values ('platform_operations', 'businesses.manage'), ('platform_operations', 'businesses.view'), ('read_only_admin', 'businesses.view');
  set session_replication_role = origin;
  insert into platform_settings (key, value) values ('email_from_address', '\"no-reply@zv.example.test\"') on conflict (key) do update set value = excluded.value;
  update platform_settings set value = '{\"domain\": true, \"mailbox\": true}' where key = 'business_email_routes';" 2>&1) || { bad "seed: $(echo "$out" | grep -m1 ERROR)"; exit 1; }
saved() { q "select public.zella_business_email_domain_saved('$1', '$2', '$3', '$4', '[]', '${5:-not_started}') ->> 'ok'"; }
[ "$(saved $C $ZOPS hello@oldclinic.example.test re_c)" = true ] || { bad "seed C"; exit 1; }    # pending before this file is applied

for i in 1 2; do out=$(apply "$MIG") || { bad "apply (run $i): $(echo "$out" | grep -m2 ERROR)"; exit 1; }; done
[ "$(md5of "$STA")" = 15745e93ec89f04f6fa22fa20b85228c ] && ok "applies twice; the status read is this file's version" || bad "status version"
[ "$(q "select (now() - domain_pending_since) < interval '1 minute' from business_email_senders where business_id = '$C'")" = t ] \
  && ok "a domain already pending starts its 7 days when this file is applied" || bad "backfill"
[ "$(q "select count(*) || ' ' || bool_and(not active) || ' ' || min(schedule) from cron.job where jobname = 'zella_business_email_pending_domains'")" = "1 true 41 17 * * *" ] \
  && ok "the daily job is created once, switched OFF (17:41 UTC)" || bad "cron: $(q "select jobname, schedule, active from cron.job")"
[ "$(q "select value::text from platform_settings where key = 'business_email_url'") $(q "select count(*) from vault.secrets where name = 'zella_business_email_jobs_secret'")" = '"" 1' ] \
  && ok "business_email_url starts empty; the call secret is made inside Vault" || bad "url or secret"
[ "$(q "select relrowsecurity from pg_class where oid = 'public.business_email_domain_removals'::regclass")" = t ] \
  && [ "$(q "select bool_or(has_table_privilege(r, 'public.business_email_domain_removals', p)) from unnest(array['anon','authenticated']) r, unnest(array['select','insert','update','delete']) p")" = f ] \
  && ok "removals: row security on; nobody in the browser reads or writes them" || bad "removals table access"
n=$(q "select count(*) from pg_proc p join pg_namespace s on s.oid = p.pronamespace, unnest(array['anon','authenticated']) r
        where s.nspname = 'public' and p.proname in ('zella_business_email_domain_drop', 'zella_business_email_pending_domains_run', 'zella_business_email_domain_remove_pending',
          'zella_business_email_domain_removals_claim', 'zella_business_email_domain_removal_done', 'zella_business_email_kick_removals', 'zella_business_email_jobs_check',
          'zella_business_email_pending_since_trg') and has_function_privilege(r, p.oid, 'execute')")
[ "$n" = 0 ] && [ "$(q "select has_function_privilege('service_role', 'public.zella_business_email_domain_drop(uuid,uuid,text,text)', 'execute')")" = f ] \
  && ok "every new function is server only; the removal helper isn't callable even with the server key" || bad "$n browser grants"

# the 7 day clock
since() { q "select coalesce(domain_pending_since::text, 'none') from business_email_senders where business_id = '$1'"; }
saved $A $OWN hello@salon.example.test re_a > /dev/null
S1=$(since $A); [ "$S1" != none ] && ok "clock: set when a domain is set up" || bad "not set"
q "update business_email_senders set domain_pending_since = now() - interval '3 days' where business_id = '$A'" > /dev/null
q "select public.zella_business_email_domain_checked('$A', '$OWN', 're_a', 'failed', '[]')" > /dev/null
[ "$(q "select (now() - domain_pending_since) > interval '2 days' from business_email_senders where business_id = '$A'")" = t ] && ok "clock: kept while it stays unverified (pending to failed)" || bad "reset on failed"
saved $A $OWN hello@salon.example.test re_a > /dev/null
[ "$(q "select (now() - domain_pending_since) > interval '2 days' from business_email_senders where business_id = '$A'")" = t ] && ok "clock: setting the same domain up again doesn't start it over" || bad "reset on same domain"
saved $D $ZOPS hello@cafe.example.test re_d > /dev/null
q "select public.zella_business_email_domain_checked('$D', '$ZOPS', 're_d', 'verified', '[]')" > /dev/null
[ "$(since $D)" = none ] && ok "clock: cleared once verified" || bad "verified keeps a clock"
r=$(q "select public.zella_business_email_sender('$A')")
[ "$(echo "$r" | j sender_route from from_name reply_to sender_note)" = "fallback no-reply@zv.example.test Test Salon front@a.example.test domain_not_verified" ] \
  && ok "until removal, the business sends from Zella Voice's address with its own name" || bad "sender while pending: $r"
[ "$(q "select public.zella_business_email_domain_begin('$B', '$OWNB', 'hi@salon.example.test') ->> 'reason'")" = DOMAIN_TAKEN ] && ok "while pending, no other business can set that domain up" || bad "not taken"

# the job, day by day
run() { q "select public.zella_business_email_pending_domains_run()"; }
notes() { q "select count(*) from staff_notifications where business_id = '$1' and kind = '$2'"; }
q "update business_email_senders set domain_pending_since = now() - interval '1 day 23 hours' where business_id = '$A';
   update business_email_senders set domain_pending_since = now() - interval '7 days 2 hours' where business_id = '$C'" > /dev/null
run > /dev/null
[ "$(notes $A business_email_domain_pending)" = 0 ] && ok "job: nothing before day 2" || bad "early reminder"
q "update business_email_senders set domain_pending_since = now() - interval '2 days 1 hour' where business_id = '$A'" > /dev/null
r=$(run); run > /dev/null
[ "$(notes $A business_email_domain_pending)" = 1 ] && [ "$(q "select severity || ' ' || title from staff_notifications where business_id = '$A' and kind = 'business_email_domain_pending'")" = "warning Your email domain isn't verified yet" ] \
  && ok "job: day 2, one reminder (a warning, so it is emailed), not twice" || bad "day 2: $r"
until2=$(q "select to_char((domain_pending_since + interval '7 days') at time zone 'America/Denver', 'FMDD Mon YYYY') from business_email_senders where business_id = '$A'")
q "select body from staff_notifications where business_id = '$A' and kind = 'business_email_domain_pending'" | grep -q "verified by $until2, it is removed" \
  && ok "job: the reminder says the date it is removed, in the business's time zone" || bad "reminder date"
[ "$(notes $C business_email_domain_pending) $(since $C | cut -c1-4)" != "0 none" ] && [ "$(q "select domain_reminded_day5_at is not null and route = 'domain' from business_email_senders where business_id = '$C'")" = t ] \
  && ok "job: a domain already past day 7 with no warning (the job was off) gets the day 5 reminder first, and is not removed" || bad "late job removed without warning"
q "update business_email_senders set domain_pending_since = now() - interval '5 days 1 hour' where business_id = '$A'" > /dev/null
run > /dev/null; run > /dev/null
[ "$(notes $A business_email_domain_pending)" = 2 ] && [ "$(q "select title from staff_notifications where business_id = '$A' and kind = 'business_email_domain_pending' order by created_at desc limit 1")" = "Your email domain still isn't verified" ] \
  && ok "job: day 5, one more reminder, not twice" || bad "day 5"
[ "$(q "select count(*) from staff_notifications where kind like 'business_email_domain%' and (title || body) ~ '[-‐‑‒–—―]'")" = 0 ] && ok "the reminders have no dashes or hyphens (BRD-6)" || bad "dash in a reminder"
q "update business_email_senders set domain_pending_since = now() - interval '7 days 1 hour', domain_reminded_day5_at = now() - interval '35 hours' where business_id = '$A'" > /dev/null
run > /dev/null
[ "$(q "select route from business_email_senders where business_id = '$A'")" = domain ] && ok "job: never sooner than 36 hours after the day 5 reminder" || bad "removed too soon"
q "update business_email_senders set domain_reminded_day5_at = now() - interval '2 days' where business_id = '$A'" > /dev/null
r=$(run)
[ "$(echo "$r" | j expired removals)" = "1 not_set_up" ] && [ "$(q "select coalesce(route, 'none') || ' ' || coalesce(domain, 'none') || ' ' || domain_status from business_email_senders where business_id = '$A'")" = "none none none" ] \
  && ok "job: day 7, the domain is removed from the business" || bad "day 7: $r"
[ "$(q "select reason || ' ' || status || ' ' || resend_domain_id || ' ' || domain from business_email_domain_removals where business_id = '$A'")" = "expired pending re_a salon.example.test" ] \
  && ok "job: its Resend domain is queued for removal" || bad "removal not queued"
[ "$(notes $A business_email_domain_removed) $(q "select count(*) from audit_logs where business_id = '$A' and action = 'business_email.domain_expired'")" = "1 1" ] \
  && ok "job: the business is told, and it is audited" || bad "told or audited"
r=$(q "select public.zella_business_email_sender('$A')"); [ "$(echo "$r" | j sender_route from_name reply_to)" = "fallback Test Salon front@a.example.test" ] \
  && ok "after removal: Zella Voice's address with the business's name, Reply-To the business email" || bad "sender after: $r"
[ "$(q "select public.zella_business_email_domain_begin('$B', '$OWNB', 'hi@salon.example.test') ->> 'ok'")" = true ] && ok "after removal the domain is free for another business" || bad "still taken"
q "update business_email_senders set domain_status = 'verified', domain_pending_since = null where business_id = '$D'" > /dev/null
run > /dev/null; [ "$(q "select route || ' ' || domain_status from business_email_senders where business_id = '$D'")" = "domain verified" ] && ok "job: a verified domain is never touched" || bad "verified touched"

# an admin removes a pending domain at once
saved $B $OWNB hello@studio.example.test re_b > /dev/null
rem() { q "select public.zella_business_email_domain_remove_pending('$1', '$2', '$3')"; }
[ "$(rem $B $OWNB 'mine' | j reason) $(rem $B $ZRO 'proof shown' | j reason) $(rem $B $ADM 'proof shown' | j reason)" = "NOT_ALLOWED NOT_ALLOWED NOT_ALLOWED" ] \
  && ok "admin removal: not the business's owner, an admin without businesses.manage, or another business's admin" || bad "admin removal allowed wrongly"
[ "$(rem $B $ZOPS ' x ' | j reason) $(rem $D $ZOPS 'proof shown' | j reason)" = "REASON_REQUIRED NOT_PENDING" ] && ok "admin removal: a reason is required, and a verified domain is never removed this way" || bad "reason or verified"
r=$(rem $B $ZOPS 'Another business proved it owns studio.example.test')
RID=$(echo "$r" | j removal_id)
[ "$(echo "$r" | j ok)" = True ] && [ "$(q "select coalesce(route, 'none') from business_email_senders where business_id = '$B'")" = none ] \
  && [ "$(q "select reason from business_email_domain_removals where id = '$RID'")" = admin ] \
  && [ "$(q "select (new_data ->> 'reason') || '|' || user_id from audit_logs where business_id = '$B' and action = 'business_email.domain_removed_by_admin'")" = "Another business proved it owns studio.example.test|$ZOPS" ] \
  && [ "$(notes $B business_email_domain_removed)" = 1 ] && ok "admin removal: at once, queued at Resend, audited with who and why, the business told" || bad "admin removal: $r"

# the removal queue
claim() { q "select public.zella_business_email_domain_removals_claim(10, ${1:-null})"; }
c=$(claim "'$RID'"); [ "$(echo "$c" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d), d[0]["resend_domain_id"])')" = "1 re_b" ] && ok "queue: one removal claimed by its id" || bad "claim by id: $c"
TOK=$(echo "$c" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["claim_token"])')
[ "$(claim "'$RID'")" = "[]" ] && ok "queue: a claimed removal isn't claimed again at once" || bad "claimed twice"
[ "$(q "select public.zella_business_email_domain_removal_done('$RID', gen_random_uuid(), true, 200)")" = NOT_THIS_CLAIM ] && ok "queue: only its claim may finish it" || bad "other claim finished it"
[ "$(q "select public.zella_business_email_domain_removal_done('$RID', '$TOK', true, 200)")" = done ] && ok "queue: Resend removed it" || bad "done"
AID=$(q "select id from business_email_domain_removals where business_id = '$A'")
c=$(claim); TOK=$(echo "$c" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["claim_token"])')
[ "$(q "select public.zella_business_email_domain_removal_done('$AID', '$TOK', false, 503)")" = pending ] \
  && [ "$(q "select (next_attempt_at > now() + interval '9 minutes') || ' ' || last_error from business_email_domain_removals where id = '$AID'")" = "true Resend answered 503" ] \
  && ok "queue: a refusal is tried again later, with a longer wait" || bad "retry"
q "update business_email_domain_removals set next_attempt_at = now() where id = '$AID'; insert into business_email_senders (business_id, route, address, domain, domain_status, resend_domain_id) values ('$B', 'domain', 'hi@salon.example.test', 'salon.example.test', 'pending', 're_a')
   on conflict (business_id) do update set route = 'domain', address = 'hi@salon.example.test', domain = 'salon.example.test', domain_status = 'pending', resend_domain_id = 're_a'" > /dev/null
[ "$(claim)" = "[]" ] && [ "$(q "select status || ' ' || last_error from business_email_domain_removals where id = '$AID'")" = "skipped in_use" ] \
  && ok "queue: a Resend domain another business uses again is never removed" || bad "in use removed"
q "insert into business_email_domain_removals (business_id, domain, resend_domain_id, reason, attempts) values ('$C', 'old.example.test', 're_old', 'expired', 5)" > /dev/null
claim > /dev/null
[ "$(q "select status from business_email_domain_removals where resend_domain_id = 're_old'") $(q "select count(*) from platform_alerts where kind = 'business_email_domain_removal_failed'")" = "failed 1" ] \
  && ok "queue: after 5 tries it is failed, with an admin alert" || bad "failed after 5"

# the wake up call and its secret
q "delete from net.http_requests" > /dev/null
q "insert into business_email_domain_removals (business_id, domain, resend_domain_id, reason) values ('$C', 'wake.example.test', 're_wake', 'expired')" > /dev/null
[ "$(q "select public.zella_business_email_kick_removals()")" = not_set_up ] && ok "wake: nothing is called until business_email_url is set" || bad "called without url"
q "update platform_settings set value = '\"https://fn.example.test/business-email\"' where key = 'business_email_url'" > /dev/null
SEC=$(q "select decrypted_secret from vault.decrypted_secrets where name = 'zella_business_email_jobs_secret'")
[ "$(q "select public.zella_business_email_kick_removals()")" = called ] && [ "$(q "select url || ' ' || (body ->> 'action') || ' ' || (headers ->> 'X-Zella-Secret' = '$SEC') from net.http_requests")" = "https://fn.example.test/business-email domain_removals true" ] \
  && ok "wake: called with the secret from Vault when a removal is due" || bad "wake call"
q "update business_email_domain_removals set status = 'done', done_at = now() where resend_domain_id = 're_wake'" > /dev/null
[ "$(q "select public.zella_business_email_kick_removals()")" = nothing_due ] && ok "wake: not called when nothing is due" || bad "called with nothing due"
[ "$(q "select public.zella_business_email_jobs_check('$SEC')")$(q "select public.zella_business_email_jobs_check('wrong')")$(q "select public.zella_business_email_jobs_check(null)")" = tff ] \
  && ok "the secret check: only the Vault secret" || bad "secret check"

# what the screen shows
saved $A $OWN hello@salon2.example.test re_a2 > /dev/null
st=$(as $OWN "public.zella_business_email_status('$A')::text")
[ "$(echo "$st" | j domain_status domain_expires_at can_remove_pending)" = "pending None False" ] && ok "status: no removal date while the daily job is off; the owner can't use the admin removal" || bad "status off: $st"
q "update cron.job set active = true where jobname = 'zella_business_email_pending_domains'" > /dev/null
st=$(as $OWN "public.zella_business_email_status('$A')::text")
[ "$(echo "$st" | j domain_expires_on)" = "$(q "select to_char((domain_pending_since + interval '7 days') at time zone 'America/Denver', 'FMDD Mon YYYY') from business_email_senders where business_id = '$A'")" ] \
  && ok "status: with the job on, the date it is removed if not verified" || bad "status on: $st"
st=$(as $ZOPS "(public.zella_business_email_status('$A') ->> 'can_remove_pending')"); [ "$st" = true ] && ok "status: a Zella Voice admin with businesses.manage may remove it now" || bad "admin status: $st"
q "update cron.job set active = false where jobname = 'zella_business_email_pending_domains'" > /dev/null

# the rollback
q "insert into business_email_domain_removals (business_id, domain, resend_domain_id, reason) values ('$C', 'late.example.test', 're_late', 'expired')" > /dev/null
out=$(rollback); echo "$out" | grep -q REMOVALS_WAITING && ok "rollback: refused while a removal is waiting" || bad "rollback with waiting: $out"
q "update business_email_domain_removals set status = 'done', done_at = now() where status in ('pending', 'sending')" > /dev/null
out=$(rollback); echo "$out" | grep -q REMOVALS_RECORDED && ok "rollback: refused while finished removals are recorded (nothing is deleted)" || bad "rollback with records: $out"
q "delete from business_email_domain_removals" > /dev/null
for i in 1 2; do out=$(rollback) || bad "rollback (run $i): $out"; done
[ "$(md5of "$STA")" = "$B_STA" ] && [ "$(q "select count(*) from information_schema.columns where table_name = 'business_email_senders' and column_name in ('domain_pending_since', 'domain_reminded_day2_at', 'domain_reminded_day5_at')")" = 0 ] \
  && [ "$(q "select to_regclass('public.business_email_domain_removals') is null and to_regprocedure('public.zella_business_email_pending_domains_run()') is null")" = t ] \
  && [ "$(q "select count(*) from cron.job where jobname = 'zella_business_email_pending_domains'") $(q "select count(*) from platform_settings where key = 'business_email_url'") $(q "select count(*) from vault.secrets where name = 'zella_business_email_jobs_secret'")" = "0 0 0" ] \
  && [ "$(q "select count(*) from pg_trigger where tgname = 'zella_business_email_pending_since'")" = 0 ] \
  && [ "$(q "select route || ' ' || domain from business_email_senders where business_id = '$A'")" = "domain salon2.example.test" ] \
  && ok "rollback (twice): the status read, columns, trigger, job, setting and secret all go back; a pending domain stays set up" || bad "rollback state"
out=$(apply "$MIG") && [ "$(md5of "$STA")" = 15745e93ec89f04f6fa22fa20b85228c ] && ok "applies again after the rollback" || bad "re-apply: $out"

[ -n "${KEEP:-}" ] || "${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null
echo; [ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
