#!/usr/bin/env bash
# sql/zella_business_email_mailbox_link.sql on an ISOLATED copy of the schema baseline (never production), after the
# rest of the business email stack and sql/zella_business_email_caps.sql. Test people and fake values only; no email
# is sent and no provider is called.
# Checks: refused before sql/zella_business_email_caps.sql and on a status read it wasn't written for; applies twice;
# the table has row security and no browser access, and every new function is server only; who may send a link (an
# active Zella Voice admin with businesses.manage; not the business's owner or admin, staff, an admin without the
# permission or an inactive one); the owner it is bound to (active first, else invited; none, or no address, is
# refused); a connected mailbox, a bad hash and more than 5 links a day are refused; a new link replaces the open one;
# only the hash is stored and nothing in the audit log holds the token or its hash; the link opens once, for its owner
# only (not another business's owner, not the admin who sent it), not after 7 days, not after the owner lost the role
# or the business was paused; the admin still can't connect the mailbox; the status read shows the link's state and
# nothing secret; the link email queued in the platform outbox stays in test mode while email_live is off; the
# rollback refuses on drift, then runs twice and restores the status read exactly; applies again.
#   tests/business_email_mailbox_link/run.sh      (env ZPG_HOST ZPG_PORT; KEEP=1 keeps the database)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zbizemlink
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
MIG="$REPO/sql/zella_business_email_mailbox_link.sql"; RB="$REPO/sql/rollback/zella_business_email_mailbox_link_rollback.sql"
STACK=(sql/zella_platform_emails.sql tests/business_email/prod_prepare_email.sql sql/zella_oauth_states.sql sql/zella_business_email.sql
       sql/zella_business_email_send.sql sql/zella_email_action_buttons.sql sql/zella_business_email_mailbox.sql)
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
# as <user> <expression>: the expression's value as that signed in person
as() { q "do \$\$ declare r text; begin perform set_config('request.jwt.claims', json_build_object('sub', '$1', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '$1', true); set local role authenticated; begin r := $2; exception when others then r := 'ERR:' || sqlerrm; end; reset role;
  raise warning 'R=%', r; end \$\$" 2>&1 | sed -n 's/.*R=//p' | head -1; }
STA=public.zella_business_email_status\(uuid\)

for f in "${STACK[@]}"; do apply "$REPO/$f" > /dev/null || { bad "prerequisite $f"; exit 1; }; done
out=$(apply "$MIG"); echo "$out" | grep -q "sql/zella_business_email_caps.sql first" && [ "$(q "select to_regclass('public.business_email_mailbox_links') is null")" = t ] \
  && ok "refused before sql/zella_business_email_caps.sql; nothing created" || bad "applied without the caps file: $out"
apply "$REPO/sql/zella_business_email_caps.sql" > /dev/null || { bad "prerequisite caps"; exit 1; }
B_STA=$(md5of "$STA")
q "select public.zella_patch_function('$STA', '/* other */', '-- the route set up', '/* other */ -- the route set up')" > /dev/null
out=$(apply "$MIG"); echo "$out" | grep -q VERSION_MISMATCH && [ "$(q "select to_regclass('public.business_email_mailbox_links') is null")" = t ] \
  && ok "a status read it wasn't written for is refused; nothing created" || bad "foreign status not refused: $out"
q "select public.zella_patch_function('$STA', 'zzz_never', '/* other */ -- the route set up', '-- the route set up')" > /dev/null
for i in 1 2; do out=$(apply "$MIG") || { bad "apply (run $i): $(echo "$out" | grep -m2 ERROR)"; exit 1; }; done
[ "$(md5of "$STA")" = ba293561f9b771ea5eab89b9a22e9c85 ] && ok "applies twice; the status read is this file's version" || bad "status version"
[ "$(q "select relrowsecurity from pg_class where oid = 'public.business_email_mailbox_links'::regclass")" = t ] \
  && [ "$(q "select bool_or(has_table_privilege(r, 'public.business_email_mailbox_links', p)) from unnest(array['anon','authenticated']) r, unnest(array['select','insert','update','delete']) p")" = f ] \
  && ok "links: row security on; nobody in the browser reads or writes them" || bad "table access"
n=$(q "select count(*) from unnest(array['public.zella_business_email_platform_admin(uuid,uuid)', 'public.zella_business_email_mailbox_link_issue(uuid,uuid,text)',
        'public.zella_business_email_mailbox_link_redeem(text,uuid)']) f, unnest(array['anon', 'authenticated']) r where has_function_privilege(r, f::regprocedure, 'execute')")
[ "$n" = 0 ] && ok "the three link functions are server only" || bad "$n browser grants"

# test people and businesses only
A=b7000000-0000-4000-8000-000000000001; B=b7000000-0000-4000-8000-000000000002; C=b7000000-0000-4000-8000-000000000003
OWN=a7000000-0000-4000-8000-000000000001; ADM=a7000000-0000-4000-8000-000000000002; STF=a7000000-0000-4000-8000-000000000003
OWNB=a7000000-0000-4000-8000-000000000004; INV=a7000000-0000-4000-8000-000000000005
ZOPS=a7000000-0000-4000-8000-000000000011; ZRO=a7000000-0000-4000-8000-000000000012; ZOFF=a7000000-0000-4000-8000-000000000013; ZOWN=a7000000-0000-4000-8000-000000000014
out=$(q "insert into auth.users (id, email) values ('$OWN', 'owner@a.example.test'), ('$ADM', 'admin@a.example.test'), ('$STF', 'staff@a.example.test'),
    ('$OWNB', 'owner@b.example.test'), ('$INV', 'invited@c.example.test'), ('$ZOPS', 'ops@zv.example.test'), ('$ZRO', 'ro@zv.example.test'),
    ('$ZOFF', 'off@zv.example.test'), ('$ZOWN', 'zowner@zv.example.test');
  insert into businesses (id, name, email, timezone) values ('$A', 'Test Salon', 'front@a.example.test', 'America/Denver'), ('$B', 'Other Studio', 'front@b.example.test', 'America/New_York'),
    ('$C', 'New Clinic', 'front@c.example.test', 'America/Chicago');
  insert into business_members (business_id, user_id, role, status) values ('$A', '$OWN', 'owner', 'active'), ('$A', '$ADM', 'admin', 'active'), ('$A', '$STF', 'staff', 'active'),
    ('$B', '$OWNB', 'owner', 'active'), ('$C', '$INV', 'owner', 'invited');
  -- the 4 Nov baseline still limits platform roles to two (production has the granular ones): its trigger is skipped here
  set session_replication_role = replica;
  insert into platform_admins (user_id, role, is_active) values ('$ZOPS', 'platform_operations', true), ('$ZRO', 'read_only_admin', true), ('$ZOFF', 'platform_operations', false), ('$ZOWN', 'zella_owner', true);
  insert into platform_role_permissions (role, permission) values ('platform_operations', 'businesses.manage'), ('platform_operations', 'businesses.view'), ('read_only_admin', 'businesses.view');
  set session_replication_role = origin;" 2>&1) \
  || { bad "seed: $(echo "$out" | grep -m1 ERROR)"; exit 1; }
H() { printf '%064x' "$1"; }   # a fake token hash (the edge function hashes the real token; only the hash reaches here)
issue() { q "select public.zella_business_email_mailbox_link_issue('$1', '$2', '$3')"; }
why() { issue "$@" | j reason; }
[ "$(why $A $OWN "$(H 1)") $(why $A $ADM "$(H 1)") $(why $A $STF "$(H 1)") $(why $A $ZRO "$(H 1)") $(why $A $ZOFF "$(H 1)") $(why $A $OWNB "$(H 1)")" \
  = "NOT_ALLOWED NOT_ALLOWED NOT_ALLOWED NOT_ALLOWED NOT_ALLOWED NOT_ALLOWED" ] \
  && ok "issue: not the business's owner or admin, staff, an admin without businesses.manage, an inactive admin or another business's owner" || bad "issue allowed wrongly"
[ "$(why $A $ZOPS not-a-hash)" = BAD_REQUEST ] && ok "issue: only a SHA 256 hash is accepted" || bad "bad hash"
r=$(issue $A $ZOPS "$(H 1)")
[ "$(echo "$r" | j ok owner_id owner_invited to business_name email_live)" = "True $OWN False owner@a.example.test Test Salon False" ] \
  && [ "$(q "select (expires_at - created_at) = interval '7 days' and status = 'open' from business_email_mailbox_links where token_hash = '$(H 1)'")" = t ] \
  && ok "issue: a Zella Voice admin with businesses.manage; bound to the business's active owner; 7 days; email not live is said" || bad "issue: $r"
L1=$(echo "$r" | j link_id)
[ "$(echo "$r" | j expires_on)" = "$(q "select to_char((now() + interval '7 days') at time zone 'America/Denver', 'FMDD Mon YYYY')")" ] && ok "issue: the expiry date in the business's own time zone" || bad "expires_on: $r"
r=$(issue $C $ZOWN "$(H 2)"); [ "$(echo "$r" | j ok owner_id owner_invited)" = "True $INV True" ] && ok "issue: an owner still to accept the invitation is used when there's no active one" || bad "invited owner: $r"
q "insert into businesses (id, name) values ('b7000000-0000-4000-8000-000000000009', 'Ownerless')" > /dev/null
[ "$(why b7000000-0000-4000-8000-000000000009 $ZOPS "$(H 3)")" = NO_OWNER ] && ok "issue: a business with no owner is refused" || bad "no owner"
q "update auth.users set email = 'not an address' where id = '$OWNB'" > /dev/null
[ "$(why $B $ZOPS "$(H 3)")" = NO_OWNER_EMAIL ] && ok "issue: an owner without a usable address is refused" || bad "no owner email"
q "update auth.users set email = 'owner@b.example.test' where id = '$OWNB'" > /dev/null
r=$(issue $A $ZOPS "$(H 4)"); L2=$(echo "$r" | j link_id)
[ "$(q "select string_agg(status, ',' order by created_at) from business_email_mailbox_links where business_id = '$A'")" = "replaced,open" ] \
  && ok "issue: a new link replaces the open one" || bad "replace"
for i in 5 6 7; do issue $A $ZOPS "$(H $i)" > /dev/null; done
[ "$(why $A $ZOPS "$(H 8)")" = TOO_MANY_LINKS ] && ok "issue: at most 5 links a day for one business" || bad "no daily limit"
[ "$(q "select count(*) from audit_logs where business_id = '$A' and action = 'business_email.mailbox_link_sent' and user_id = '$ZOPS'")" = 5 ] \
  && [ "$(q "select count(*) from audit_logs where row_to_json(audit_logs)::text like '%$(H 5)%'")" = 0 ] \
  && ok "issue: each link is audited with who sent it, never the token's hash" || bad "issue audit"

# opening the link
L=$(H 7)   # the open one
red() { q "select public.zella_business_email_mailbox_link_redeem('$1', '$2')"; }
[ "$(red "$(H 4)" $OWN | j reason) $(red "$(H 99)" $OWN | j reason) $(red bad $OWN | j reason)" = "MAILBOX_LINK_REPLACED MAILBOX_LINK_NOT_FOUND MAILBOX_LINK_NOT_FOUND" ] \
  && ok "open: a replaced link or an unknown one does nothing" || bad "replaced or unknown"
[ "$(red "$L" $OWNB | j reason) $(red "$L" $ZOPS | j reason) $(red "$L" $ADM | j reason)" = "MAILBOX_LINK_NOT_YOURS MAILBOX_LINK_NOT_YOURS MAILBOX_LINK_NOT_YOURS" ] \
  && [ "$(q "select status from business_email_mailbox_links where token_hash = '$L'")" = open ] \
  && ok "open: only its owner (not another business's owner, the admin who sent it, or the business's admin); trying doesn't use it up" || bad "not yours"
q "update business_members set role = 'admin' where business_id = '$A' and user_id = '$OWN'" > /dev/null
[ "$(red "$L" $OWN | j reason)" = NOT_OWNER ] && ok "open: the role is checked on the server: no longer the owner, refused" || bad "demoted owner"
q "update business_members set role = 'owner' where business_id = '$A' and user_id = '$OWN'; update businesses set suspended_at = now() where id = '$A'" > /dev/null
[ "$(red "$L" $OWN | j reason)" = NOT_OWNER ] && ok "open: not for a paused business" || bad "paused business"
q "update businesses set suspended_at = null where id = '$A'" > /dev/null
r=$(red "$L" $OWN); [ "$(echo "$r" | j ok business_id business_name)" = "True $A Test Salon" ] && ok "open: the owner, signed in: it answers that business, to open its connect flow" || bad "open: $r"
[ "$(red "$L" $OWN | j reason)" = MAILBOX_LINK_USED ] && ok "open: once only" || bad "used twice"
[ "$(q "select public.zella_business_email_mailbox_can_connect('$A', '$OWN')") $(q "select public.zella_business_email_mailbox_can_connect('$A', '$ZOPS')")" = "t f" ] \
  && ok "the owner connects the mailbox themselves; the admin who sent the link never can" || bad "can_connect"
[ "$(q "select count(*) from audit_logs where business_id = '$A' and action = 'business_email.mailbox_link_opened' and user_id = '$OWN'")" = 1 ] && ok "open: audited" || bad "open audit"
q "update business_email_mailbox_links set created_at = now() - interval '8 days', expires_at = now() - interval '1 day' where token_hash = '$(H 2)'" > /dev/null
[ "$(red "$(H 2)" $INV | j reason)" = MAILBOX_LINK_EXPIRED ] && ok "open: not after 7 days" || bad "expired"

# what the screen shows
st=$(as $OWN "public.zella_business_email_status('$A')::text")
[ "$(echo "$st" | python3 -c 'import json,sys; d=json.load(sys.stdin)["mailbox_link"]; print(d["status"], sorted(d))')" = "used ['expires_at', 'expires_on', 'sent_at', 'status', 'used_at']" ] \
  && [[ "$st" != *"$(H 7)"* ]] && ok "status: the latest link's state and dates, never its token or hash" || bad "status: $st"
st=$(as $INV "public.zella_business_email_status('$C')::text"); [[ "$st" == ERR:*NOT_ALLOWED* ]] && ok "status: an invited owner can't read it before accepting" || bad "invited status: $st"
q "update business_members set status = 'active' where user_id = '$INV'" > /dev/null
st=$(as $INV "(public.zella_business_email_status('$C') -> 'mailbox_link' ->> 'status')"); [ "$st" = expired ] && ok "status: an expired link says expired" || bad "expired status: $st"
st=$(as $STF "public.zella_business_email_status('$A')::text"); [[ "$st" == ERR:*NOT_ALLOWED* ]] && ok "status: staff can't read it" || bad "staff status: $st"
q "insert into business_email_senders (business_id, route, mailbox_provider, mailbox_status, mailbox_account) values ('$B', 'mailbox', 'gmail', 'connected', 'studio@gmail.com')" > /dev/null
[ "$(why $B $ZOPS "$(H 20)")" = ALREADY_CONNECTED ] && ok "issue: not when a mailbox is already connected" || bad "already connected"

# the link email through the platform outbox: test mode while email_live is off
E=$(q "select public.zella_queue_platform_email('$A', 'S8', 'email:S8:$L2:1', 'owner@a.example.test', 'Connect your mailbox', '<p>x</p>', 'x', true, '$OWN', '{}')")
q "select count(*) from public.zella_claim_platform_emails(20)" > /dev/null
[ "$(q "select status from platform_emails where id = '$E'")" = dry_run ] && ok "the link email is queued in the platform outbox and held as test mode while email_live is off" || bad "outbox: $(q "select status from platform_emails where id = '$E'")"

# the rollback
q "select public.zella_patch_function('$STA', '/* drift */', '-- the route set up', '/* drift */ -- the route set up')" > /dev/null
out=$(rollback); echo "$out" | grep -q ROLLBACK_DRIFT && [ "$(q "select to_regclass('public.business_email_mailbox_links') is not null")" = t ] && ok "rollback: refused on drift; nothing changes" || bad "drift: $out"
q "select public.zella_patch_function('$STA', 'zzz_never', '/* drift */ -- the route set up', '-- the route set up')" > /dev/null
for i in 1 2; do out=$(rollback) || bad "rollback (run $i): $out"; done
[ "$(md5of "$STA")" = "$B_STA" ] && [ "$(q "select to_regclass('public.business_email_mailbox_links') is null and to_regprocedure('public.zella_business_email_mailbox_link_issue(uuid,uuid,text)') is null")" = t ] \
  && [ "$(q "select count(*) from platform_emails where id = '$E'")" = 1 ] \
  && ok "rollback (twice): the status read comes back exactly, the links and functions go, the outbox is untouched" || bad "rollback state"
out=$(apply "$MIG") && [ "$(md5of "$STA")" = ba293561f9b771ea5eab89b9a22e9c85 ] && ok "applies again after the rollback" || bad "re-apply: $out"

[ -n "${KEEP:-}" ] || "${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null
echo; [ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
