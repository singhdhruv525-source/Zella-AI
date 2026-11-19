#!/usr/bin/env bash
# sql/zella_admin_contact_lookup.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Checks: before, nothing finds why one number gets no texts (the gap); applies, and applies again; a lookup by the last
# 4 digits finds the business's customer with its do not text flag, its latest consent per channel, its block entry and
# platform wide block, and the last blocked text with its reason; by full email finds email suppression and a blocked
# domain; full numbers, addresses, names and message bodies never appear; another business's records never appear; short
# queries, a missing business and a missing reason are refused; each lookup is audited with the masked query; a role
# without comms.manage, a business owner and anonymous are refused; the rollback (twice) drops it; applies again; drift
# stops the file (VERSION_MISMATCH) and the rollback (ROLLBACK_DRIFT).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zlb_contact_lookup}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
MIG="$REPO/sql/zella_admin_contact_lookup.sql"; RB="$REPO/sql/rollback/zella_admin_contact_lookup_rollback.sql"
OWN=e4000000-0000-0000-0000-000000000001; RO=e4000000-0000-0000-0000-000000000002; BO=e4000000-0000-0000-0000-000000000003
B=e4100000-0000-0000-0000-000000000001; O=e4100000-0000-0000-0000-000000000002
q "insert into auth.users (id, email) values ('$OWN', 'owner@zella.test'), ('$RO', 'readonly@zella.test'), ('$BO', 'owner@glow.test');
   insert into public.platform_admins (user_id, role, is_active) values ('$OWN', 'zella_owner', true), ('$RO', 'read_only_admin', true);
   insert into public.platform_role_permissions (role, permission) values ('read_only_admin', 'businesses.view') on conflict do nothing;
   insert into public.businesses (id, name) values ('$B', 'Glow Test Studio'), ('$O', 'Other Test Studio');
   insert into public.business_members (business_id, user_id, role, status) values ('$B', '$BO', 'owner', 'active')" > /dev/null || exit 1
C=$(q "insert into public.customers (business_id, first_name, last_name, phone, email, do_not_sms, email_suppressed_at, email_suppressed_reason)
       values ('$B', 'Casey', 'Testperson', '+1 (555) 201-7788', 'casey.test@example.org', true, now(), 'bounced') returning id" | head -1)
q "insert into public.customers (business_id, first_name, phone, do_not_contact) values ('$O', 'Other', '+15552017788', true);
   insert into public.contact_consents (business_id, customer_id, phone_digits, channel, purpose, status, source, recorded_at)
     values ('$B', '$C', '15552017788', 'sms', 'marketing', 'opted_in', 'web_form', now() - interval '3 days'),
            ('$B', '$C', '15552017788', 'sms', 'marketing', 'opted_out', 'inbound_sms_keyword', now() - interval '1 day'),
            ('$O', null, '15552017788', 'sms', 'transactional', 'opted_out', 'staff', now());
   insert into public.spam_list_entries (business_id, list, channel, value_type, value, reason, source) values
     ('$B', 'block', 'sms', 'phone', '+15552017788', 'Asked us to stop', 'manual'),
     (null, 'block', 'email', 'domain', 'example.org', 'Platform wide test block', 'manual'),
     ('$O', 'block', 'sms', 'phone', '+15552017788', 'Other business only', 'manual');
   insert into public.sms_messages (business_id, customer_id, direction, status, to_number, message_body, metadata)
     values ('$B', '$C', 'outbound', 'blocked', '+15552017788', 'Secret body text', '{\"block_reason\": \"opted out\"}')" > /dev/null || exit 1
as() { printf '%s\n' "begin; set local role authenticated;" \
    "select set_config('request.jwt.claims', '{\"sub\": \"$1\", \"role\": \"authenticated\", \"aal\": \"aal2\"}', true) \\g /dev/null" \
    "$2;" "commit;" | "${P[@]}" -d $DB 2>&1; }
[ -z "$(q "select to_regprocedure('public.zella_admin_contact_lookup(uuid,text,text)')")" ] && ok "before: nothing finds why one number gets no texts (the gap)" || bad "before"
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$MIG" 2>&1 | grep -v NOTICE | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"
r=$(as $OWN "select public.zella_admin_contact_lookup('$B', '7788', 'Customer says texts stopped')")
j() { q "select '$r'::jsonb $1"; }
[ "$(j "-> 'contacts' -> 0 ->> 'contact'")" = "…7788" ] && [ "$(j "-> 'contacts' -> 0 ->> 'do_not_sms'")" = "true" ] && ok "by the last 4 digits: the customer, masked, with do not text" || bad "contact: $r"
[ "$(j "-> 'consents' -> 0 ->> 'status'")" = "opted_out" ] && [ "$(j "-> 'consents' -> 0 ->> 'source'")" = "inbound_sms_keyword" ] && [ "$(j "-> 'consents' ->> 1")" = "" ] && ok "the latest consent per channel and purpose, this business only" || bad "consents: $(j "-> 'consents'")"
[ "$(j "-> 'lists' -> 0 ->> 'reason'")" = "Asked us to stop" ] && [ "$(j "-> 'lists' ->> 1")" = "" ] && ok "this business's block entry, not another business's" || bad "lists: $(j "-> 'lists'")"
[ "$(j "-> 'last_blocked' ->> 'reason'")" = "opted out" ] && ok "the last blocked text and its reason" || bad "blocked: $(j "-> 'last_blocked'")"
[[ "$r" != *2017788* && "$r" != *Casey* && "$r" != *Testperson* && "$r" != *"Secret body"* && "$r" != *casey.test* ]] && ok "no full number, name or message body comes back" || bad "leak: $r"
r=$(as $OWN "select public.zella_admin_contact_lookup('$B', 'Casey.Test@Example.org', 'Emails bounce')")
[ "$(j "-> 'contacts' -> 0 ->> 'contact'")" = "c…@example.org" ] && [ "$(j "-> 'contacts' -> 0 ->> 'email_suppressed_reason'")" = "bounced" ] && [ "$(j "-> 'lists' -> 0 ->> 'platform_wide'")" = "true" ] && ok "by full email: suppression and the platform wide domain block, masked" || bad "email: $r"
[[ "$r" != *casey.test* ]] && ok "the address is never returned in full" || bad "email leak"
r=$(as $OWN "select public.zella_admin_contact_lookup('$O', '7788', 'Check other')"); [ "$(j "-> 'contacts' -> 0 ->> 'do_not_contact'")" = "true" ] && [ "$(j "-> 'lists' -> 0 ->> 'reason'")" = "Other business only" ] && ok "another business sees only its own records" || bad "other: $r"
for args in "'$B', '778', 'x reason'|QUERY_TOO_SHORT" "'$B', 'casey', 'x reason'|QUERY_TOO_SHORT" "null, '7788', 'x reason'|BUSINESS_REQUIRED" "'$B', '7788', ' '|REASON_REQUIRED"; do
  IFS='|' read -r a want <<< "$args"; out=$(as $OWN "select public.zella_admin_contact_lookup($a)"); [[ "$out" == *"$want"* ]] || bad "should refuse $want: $out"
done; ok "short or partial queries, a missing business and a missing reason are refused"
[ "$(q "select count(*) from public.audit_logs where action = 'comms.contact_lookup' and user_id = '$OWN'")" = "3" ] && [ "$(q "select string_agg(distinct new_data ->> 'query', ',') from public.audit_logs where action = 'comms.contact_lookup'")" = "c…@example.org,…7788" ] && ok "each lookup is audited with the masked query only" || bad "audit: $(q "select string_agg(new_data::text, ' ') from public.audit_logs where action = 'comms.contact_lookup'")"
# a second contact of the same business whose number ends the same way: its opt in never hides the first one's opt out
q "insert into public.contact_consents (business_id, phone_digits, channel, purpose, status, source, recorded_at) values ('$B', '15559997788', 'sms', 'marketing', 'opted_in', 'web_form', now())" > /dev/null
r2=$(as $OWN "select public.zella_admin_contact_lookup('$B', '7788', 'Two contacts check')")
[ "$(q "select string_agg((c ->> 'contact') || ':' || (c ->> 'status'), '+' order by c ->> 'contact') from jsonb_array_elements('$r2'::jsonb -> 'consents') c")" = "…7788, contact 1:opted_out+…7788, contact 2:opted_in" ] && ok "two matching contacts: each keeps its own latest consent, told apart" || bad "two contacts: $(q "select '$r2'::jsonb -> 'consents'")"
q "delete from public.contact_consents where phone_digits = '15559997788'" > /dev/null
# an email consent that also stored the phone number, then a later email only one for the same address: one contact
q "insert into public.contact_consents (business_id, customer_id, phone_digits, email_lower, channel, purpose, status, source, recorded_at) values
     ('$B', '$C', '15552017788', 'casey.test@example.org', 'email', 'marketing', 'opted_in', 'web_form', now() - interval '2 days'),
     ('$B', null, null, 'casey.test@example.org', 'email', 'marketing', 'opted_out', 'email_link', now() - interval '1 hour')" > /dev/null
r3=$(as $OWN "select public.zella_admin_contact_lookup('$B', 'casey.test@example.org', 'Email consent check')")
[ "$(q "select string_agg((c ->> 'channel') || ':' || (c ->> 'status'), '+') from jsonb_array_elements('$r3'::jsonb -> 'consents') c where c ->> 'channel' = 'email'")" = "email:opted_out" ] && ok "email consents of one address are one contact, whatever else a row stored: only the latest shows" || bad "email identity: $(q "select '$r3'::jsonb -> 'consents'")"
# by phone: the older email row matches the number, the newer one doesn't store it; the latest still shows
r4=$(as $OWN "select public.zella_admin_contact_lookup('$B', '7788', 'Phone consent check')")
[ "$(q "select string_agg((c ->> 'channel') || ':' || (c ->> 'status'), '+') from jsonb_array_elements('$r4'::jsonb -> 'consents') c where c ->> 'channel' = 'email'")" = "email:opted_out" ] && ok "found by phone: that contact's email consent is still its latest, from all its rows" || bad "phone query: $(q "select '$r4'::jsonb -> 'consents'")"
for who in "$RO" "$BO"; do out=$(as $who "select public.zella_admin_contact_lookup('$B', '7788', 'x reason')"); [[ "$out" == *NOT_ALLOWED* ]] || bad "allowed for $who: $out"; done
out=$("${P[@]}" -d $DB -c "begin; set local role anon; select public.zella_admin_contact_lookup('$B', '7788', 'x reason'); commit;" 2>&1); [[ "$out" == *"permission denied"* ]] || bad "anon: $out"
ok "a role without comms.manage, a business owner and anonymous are refused"
"${P[@]}" -d $DB -f "$RB" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$RB" > /dev/null 2>&1 && [ -z "$(q "select to_regprocedure('public.zella_admin_contact_lookup(uuid,text,text)')")" ] && ok "rollback runs twice and drops it" || bad "rollback"
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_admin_contact_lookup(p_business uuid, p_query text, p_reason text) returns jsonb language sql as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$MIG" 2>&1); [[ "$out" == *VERSION_MISMATCH* ]] && ok "a changed function stops the file" || bad "drift: $out"
out=$("${P[@]}" -d $DB -f "$RB" 2>&1); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "and stops the rollback" || bad "rollback drift: $out"
echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
