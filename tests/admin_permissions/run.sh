#!/usr/bin/env bash
# sql/zella_admin_permissions.sql on an ISOLATED copy of the production schema (never production). Test people and the
# live permission matrix only; nothing is sent. Checks: applies, and applies again; each admin role gets exactly the
# functions its permissions allow (owner and super admin everything, restricted roles their ticks, a business member
# nothing); offer approval stays Zella Voice owner only; retry_event is unchanged; incidents readable by businesses.view;
# incident and alert changes and admin claim actions write audit rows naming the admin; the rollback (run twice)
# restores every function exactly and removes the policy and triggers; applying again after the rollback works.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zadminperms; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
FUNCS="'zella_admin_acknowledge_alert','zella_automation_readiness','zella_business_readiness','zella_capabilities','zella_set_capability','zella_set_business_size','zella_platform_health_summary','zella_open_incident','zella_resolve_incident','zella_set_incident_public','zella_offers_list','zella_offer_detail','zella_offer_audience','zella_offer_monitor','zella_offer_report','zella_offer_rules_list','zella_offer_save','zella_offer_transition','zella_offer_apply_admin','zella_offer_cancel_claim','zella_offer_set_redemption','zella_offer_retry','zella_offer_log','zella_retry_event'"
fingerprint() { q "select string_agg(p.oid::regprocedure::text || '=' || md5(pg_get_functiondef(p.oid)), ',' order by p.oid::regprocedure::text) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ($FUNCS)"; }
before=$(fingerprint)

# test people: one per platform role, plus a business owner who is not an admin; the live matrix (16 Nov 2026)
q "insert into public.platform_role_permissions (role, permission) values
  ('platform_operations','ai.configure'),('platform_operations','analytics.view'),('platform_operations','businesses.manage'),('platform_operations','businesses.view'),
  ('platform_operations','comms.manage'),('platform_operations','integrations.manage'),('platform_operations','support.manage'),('platform_operations','telephony.manage'),
  ('billing_admin','analytics.view'),('billing_admin','billing.manage'),('billing_admin','billing.view'),('billing_admin','businesses.view'),('billing_admin','plans.manage'),
  ('read_only_admin','analytics.view'),('read_only_admin','audit.view'),('read_only_admin','billing.view'),('read_only_admin','businesses.view'),('read_only_admin','security.view'),
  ('security_admin','audit.view'),('security_admin','businesses.view'),('security_admin','security.manage'),('security_admin','security.view'),
  ('support_admin','analytics.view'),('support_admin','businesses.view'),('support_admin','support.manage') on conflict do nothing" > /dev/null || exit 1
q "insert into auth.users (id, email, email_confirmed_at) select ('f0000000-0000-0000-0000-00000000000' || n)::uuid, r || '@perm.test', now()
     from (values (1,'zella_owner'),(2,'super_admin'),(3,'billing_admin'),(4,'platform_operations'),(5,'support_admin'),(6,'read_only_admin'),(7,'security_admin'),(8,'member'),(9,'other_owner')) x(n, r)" > /dev/null || exit 1
q "insert into public.platform_admins (user_id, role) select ('f0000000-0000-0000-0000-00000000000' || n)::uuid, r
     from (values (1,'zella_owner'),(2,'super_admin'),(3,'billing_admin'),(4,'platform_operations'),(5,'support_admin'),(6,'read_only_admin'),(7,'security_admin')) x(n, r)" > /dev/null || exit 1
BIZ=$(q "insert into public.businesses (name, industry_id) select 'Perm Test', id from public.industries limit 1 returning id" | head -1)
q "insert into public.business_members (business_id, user_id, role, status) values ('$BIZ', 'f0000000-0000-0000-0000-000000000008', 'owner', 'active')" > /dev/null || exit 1

# who gets past each function's permission check (NOT_ALLOWED = refused; anything else, error or not, = let through)
probe() {
  q "create table if not exists public._probe (fn text, who text, allowed boolean); truncate public._probe; grant all on public._probe to authenticated" > /dev/null
  q "do \$\$
  declare u record; c record; v_err text;
  begin
    for u in select * from (values (1,'zella_owner'),(2,'super_admin'),(3,'billing_admin'),(4,'platform_operations'),(5,'support_admin'),(6,'read_only_admin'),(7,'security_admin'),(8,'member')) x(n, who) loop
      for c in select * from (values
          ('zella_admin_acknowledge_alert', 'select public.zella_admin_acknowledge_alert(gen_random_uuid())'),
          ('zella_automation_readiness', 'select public.zella_automation_readiness()'),
          ('zella_business_readiness', 'select public.zella_business_readiness(gen_random_uuid())'),
          ('zella_capabilities', 'select public.zella_capabilities(gen_random_uuid())'),
          ('zella_set_capability', 'select public.zella_set_capability(gen_random_uuid(), ''x'', true)'),
          ('zella_set_business_size', 'select public.zella_set_business_size(gen_random_uuid(), ''small'')'),
          ('zella_platform_health_summary', 'select public.zella_platform_health_summary()'),
          ('zella_open_incident', 'select public.zella_open_incident('''', null)'),
          ('zella_resolve_incident', 'select public.zella_resolve_incident(gen_random_uuid(), null)'),
          ('zella_set_incident_public', 'select public.zella_set_incident_public(gen_random_uuid(), true, null, null)'),
          ('zella_offers_list', 'select public.zella_offers_list()'),
          ('zella_offer_detail', 'select public.zella_offer_detail(gen_random_uuid())'),
          ('zella_offer_audience', 'select public.zella_offer_audience(gen_random_uuid())'),
          ('zella_offer_monitor', 'select public.zella_offer_monitor(''all'', 1)'),
          ('zella_offer_report', 'select public.zella_offer_report(now() - interval ''1 day'', now())'),
          ('zella_offer_rules_list', 'select public.zella_offer_rules_list()'),
          ('zella_offer_save', 'select public.zella_offer_save(gen_random_uuid(), ''{}''::jsonb)'),
          ('zella_offer_transition', 'select public.zella_offer_transition(gen_random_uuid(), ''submit'', null)'),
          ('zella_offer_apply_admin', 'select public.zella_offer_apply_admin(gen_random_uuid(), gen_random_uuid(), ''n'', ''k'')'),
          ('zella_offer_cancel_claim', 'select public.zella_offer_cancel_claim(gen_random_uuid())'),
          ('zella_offer_set_redemption', 'select public.zella_offer_set_redemption(gen_random_uuid(), ''reversed'', ''why'')'),
          ('zella_offer_retry', 'select public.zella_offer_retry()'),
          ('zella_retry_event', 'select public.zella_retry_event(gen_random_uuid())')) x(fn, sql) loop
        v_err := null;
        perform set_config('request.jwt.claims', json_build_object('sub', ('f0000000-0000-0000-0000-00000000000' || u.n), 'role', 'authenticated', 'aal', 'aal1')::text, true);
        set local role authenticated;
        begin execute c.sql; exception when others then v_err := sqlerrm; end;
        reset role;
        insert into public._probe values (c.fn, u.who, coalesce(v_err, '') not in ('NOT_ALLOWED', 'OWNER_ONLY', 'NOT_AUTHORIZED'));
      end loop;
    end loop;
  end \$\$" > /dev/null || { bad "probe ran"; return; }
}
# expected: which roles get past each check after the migration
expected_after() {
  q "select string_agg(fn || ':' || roles, ' ' order by fn) from (values
    ('zella_admin_acknowledge_alert', 'owner,super,platform_operations,support_admin'),
    ('zella_automation_readiness', 'owner,super,billing,platform_operations,support_admin,read_only,security'),
    ('zella_business_readiness', 'owner,super,billing,platform_operations,support_admin,read_only,security'),
    ('zella_capabilities', 'owner,super,billing,platform_operations,support_admin,read_only,security'),
    ('zella_set_capability', 'owner,super,platform_operations'),
    ('zella_set_business_size', 'owner,super,platform_operations'),
    ('zella_platform_health_summary', 'owner,super,billing,platform_operations,support_admin,read_only,security'),
    ('zella_open_incident', 'owner,super,platform_operations,support_admin'),
    ('zella_resolve_incident', 'owner,super,platform_operations,support_admin'),
    ('zella_set_incident_public', 'owner,super,platform_operations,support_admin'),
    ('zella_offers_list', 'owner,super,billing,read_only'), ('zella_offer_detail', 'owner,super,billing,read_only'),
    ('zella_offer_audience', 'owner,super,billing,read_only'), ('zella_offer_monitor', 'owner,super,billing,read_only'),
    ('zella_offer_report', 'owner,super,billing,read_only'), ('zella_offer_rules_list', 'owner,super,billing,read_only'),
    ('zella_offer_save', 'owner,super,billing'), ('zella_offer_transition', 'owner,super,billing'), ('zella_offer_apply_admin', 'owner,super,billing'),
    -- a missing claim answers NOT_FOUND before the permission check, so the probe lets everyone through; the check
    -- itself is exercised with existing claims in both businesses below
    ('zella_offer_cancel_claim', 'owner,super,billing,platform_operations,support_admin,read_only,security,member'), ('zella_offer_set_redemption', 'owner,super,billing'), ('zella_offer_retry', 'owner,super,billing'),
    ('zella_retry_event', 'owner,super')) x(fn, roles)"
}
got() {
  q "select string_agg(fn || ':' || roles, ' ' order by fn) from (select fn, string_agg(case who when 'zella_owner' then 'owner' when 'super_admin' then 'super' when 'billing_admin' then 'billing'
       when 'read_only_admin' then 'read_only' when 'security_admin' then 'security' else who end, ',' order by array_position(array['zella_owner','super_admin','billing_admin','platform_operations','support_admin','read_only_admin','security_admin','member'], who)) as roles
     from public._probe where allowed group by fn) x"
}

probe
n=$(q "select count(*) from public._probe where allowed and who not in ('zella_owner','super_admin') and fn <> 'zella_offer_cancel_claim'")
[ "$n" = "0" ] && ok "before: every restricted role is refused by these functions (the bug the audit found)" || bad "before: $n unexpected"

"${P[@]}" -d $DB -f "$REPO/sql/zella_admin_permissions.sql" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$REPO/sql/zella_admin_permissions.sql" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$REPO/sql/zella_admin_permissions.sql" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"
# Migrated definitions retaining the permission expressions must still match exactly.
for sig in 'public.zella_offers_list()' 'public.zella_offer_log(uuid,text,text,text,jsonb,uuid)'; do
  q "alter function $sig cost 101;" > /dev/null || exit 1
  if out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_admin_permissions.sql" 2>&1); then
    bad "migrated drift accepted: $sig"
  elif [[ "$out" == *"VERSION_MISMATCH"* ]]; then
    ok "migrated drift refused: $sig"
  else
    bad "unexpected migrated drift error: $out"
  fi
  q "alter function $sig cost 100" > /dev/null || exit 1
done
probe; after=$(got); want=$(expected_after)
[ "$after" = "$want" ] && ok "each role gets exactly what its permissions allow (business member: nothing)" || { bad "access matrix"; diff <(tr ' ' '\n' <<<"$want") <(tr ' ' '\n' <<<"$after"); }
n=$(q "select count(*) from public._probe where allowed and who = 'member' and fn <> 'zella_offer_cancel_claim'")
[ "$n" = "0" ] && ok "a business member who isn't an admin gets none of them" || bad "member let through $n"
# Real pending claims in two businesses exercise ownership and admin authorization.
BIZ2=$(q "insert into public.businesses (name, industry_id) select 'Other Perm Test', id from public.industries limit 1 returning id") || exit 1
q "insert into public.business_members (business_id, user_id, role, status) values ('$BIZ2', 'f0000000-0000-0000-0000-000000000009', 'owner', 'active')" > /dev/null || exit 1
q "insert into public.offers (id, name, status, needs_approval) values ('f1000000-0000-0000-0000-000000000001', 'Perm offer', 'pending_approval', true)" > /dev/null || exit 1
q "insert into public.offers (id, name) values ('f1000000-0000-0000-0000-000000000002', 'Cancel fixture')" > /dev/null || exit 1
ok "offer fixtures created separately"
q "do \$\$
declare b uuid; u record; claim uuid; denied boolean;
begin
  foreach b in array array['$BIZ'::uuid, '$BIZ2'::uuid] loop
    for u in select * from (values (8), (9), (3), (6)) x(n) loop
      insert into public.offer_redemptions (offer_id, business_id, source, idempotency_key)
      values ('f1000000-0000-0000-0000-000000000002', b, 'dashboard', gen_random_uuid()::text) returning id into claim;
      perform set_config('request.jwt.claims', json_build_object('sub', 'f0000000-0000-0000-0000-00000000000' || u.n, 'role', 'authenticated', 'aal', 'aal1')::text, true);
      denied := false;
      set local role authenticated;
      begin
        perform public.zella_offer_cancel_claim(claim);
      exception when raise_exception then
        if sqlerrm <> 'NOT_ALLOWED' then raise; end if;
        denied := true;
      end;
      reset role;
      if denied is distinct from (u.n <> 3 and not (u.n = 8 and b = '$BIZ'::uuid or u.n = 9 and b = '$BIZ2'::uuid)) then
        raise exception 'Unexpected cancellation authorization for user % business %', u.n, b;
      end if;
      if not exists (select 1 from public.offer_redemptions where id = claim and status = case when denied then 'pending' else 'cancelled' end) then
        raise exception 'Unexpected claim status for user % business %', u.n, b;
      end if;
    end loop;
  end loop;
end \$\$" > /dev/null && ok "claim cancellation: own business and billing admin allowed; other business owner and read only admin refused (both businesses)" || bad "claim cancellation authorization"
seen_as() { q "do \$\$ declare n int; begin perform set_config('request.jwt.claims', json_build_object('sub', '$1', 'role', 'authenticated', 'aal', 'aal1')::text, true); set local role authenticated; select count(*) into n from public.platform_incidents; reset role; raise notice 'N=%', n; end \$\$" 2>&1 | sed -n 's/.*N=//p'; }

# offer approval stays owner only
if q "do \$\$ begin
  perform set_config('request.jwt.claims', '{\"sub\":\"f0000000-0000-0000-0000-000000000003\",\"role\":\"authenticated\",\"aal\":\"aal1\"}', true);
  set local role authenticated;
  begin
    perform public.zella_offer_transition('f1000000-0000-0000-0000-000000000001', 'approve', null);
  exception when raise_exception then
    if sqlerrm = 'OWNER_ONLY' then return; end if;
    raise;
  end;
  raise exception 'Expected OWNER_ONLY from billing admin approval';
end \$\$" > /dev/null; then
  ok "a billing admin cannot approve an offer (OWNER_ONLY)"
else
  bad "billing admin approval did not return OWNER_ONLY"
fi

# incidents: readable by businesses.view, and opening and resolving are audited
q "do \$\$ begin
  perform set_config('request.jwt.claims', '{\"sub\":\"f0000000-0000-0000-0000-000000000005\",\"role\":\"authenticated\",\"aal\":\"aal1\"}', true);
  set local role authenticated;
  perform public.zella_open_incident('Texts delayed (perm test)', 'checking');
  reset role; end \$\$" > /dev/null 2>&1 || bad "support admin opens an incident"
inc=$(q "select id from public.platform_incidents where title = 'Texts delayed (perm test)'")
[ -n "$inc" ] && ok "a support admin can open an incident" || bad "incident not opened"
seen=$(seen_as f0000000-0000-0000-0000-000000000006)
[ "$seen" = "1" ] && ok "a read only admin can read incidents" || bad "read only admin sees $seen incidents"
seen=$(seen_as f0000000-0000-0000-0000-000000000008)
[ "$seen" = "0" ] && ok "a business member can't read incidents" || bad "member sees $seen incidents"
q "do \$\$ begin
  perform set_config('request.jwt.claims', '{\"sub\":\"f0000000-0000-0000-0000-000000000005\",\"role\":\"authenticated\",\"aal\":\"aal1\"}', true);
  set local role authenticated;
  perform public.zella_set_incident_public('$inc', true, 'Some texts are delayed.', 'texts');
  perform public.zella_resolve_incident('$inc', 'fixed');
  reset role; end \$\$" > /dev/null 2>&1 || bad "publish and resolve"
a=$(q "select string_agg(action, ',' order by created_at, action) from public.audit_logs where entity_id = '$inc' and user_id = 'f0000000-0000-0000-0000-000000000005'")
[[ "$a" == *"platform.incident_opened"* && "$a" == *"platform.incident_public_changed"* && "$a" == *"platform.incident_resolved"* ]] && ok "opening, publishing and resolving an incident are audited with the admin's id ($a)" || bad "incident audit: $a"

# alert acknowledge audited
al=$(q "insert into public.platform_alerts (kind, severity, title, status, dedupe_key) values ('perm_test', 'warning', 'Perm alert', 'open', 'perm-test-' || gen_random_uuid()) returning id" | head -1)
q "do \$\$ begin
  perform set_config('request.jwt.claims', '{\"sub\":\"f0000000-0000-0000-0000-000000000004\",\"role\":\"authenticated\",\"aal\":\"aal1\"}', true);
  set local role authenticated; perform public.zella_admin_acknowledge_alert('$al'); reset role; end \$\$" > /dev/null 2>&1 || bad "acknowledge"
a=$(q "select action || ':' || user_id from public.audit_logs where entity_id = '$al'")
[ "$a" = "platform.alert_acknowledged:f0000000-0000-0000-0000-000000000004" ] && ok "acknowledging an alert is audited with the admin's id" || bad "alert audit: $a"
q "update public.platform_alerts set status = 'resolved' where id = '$al'" > /dev/null
n=$(q "select count(*) from public.audit_logs where entity_id = '$al'")
[ "$n" = "1" ] && ok "a change without a signed in person (server, scheduled job) adds no audit row from the trigger" || bad "server change audited: $n"

# claim actions: audited for admins, not for a business's own claims
q "do \$\$ begin
  perform set_config('request.jwt.claims', '{\"sub\":\"f0000000-0000-0000-0000-000000000003\",\"role\":\"authenticated\",\"aal\":\"aal1\"}', true);
  perform public.zella_offer_log('f1000000-0000-0000-0000-000000000001', 'claim_cancelled', 'pending', 'cancelled', '{}', '$BIZ');
  perform set_config('request.jwt.claims', '{\"sub\":\"f0000000-0000-0000-0000-000000000008\",\"role\":\"authenticated\",\"aal\":\"aal1\"}', true);
  perform public.zella_offer_log('f1000000-0000-0000-0000-000000000001', 'claimed', null, 'pending', '{}', '$BIZ'); end \$\$" > /dev/null 2>&1 || bad "offer log calls"
a=$(q "select string_agg(action || ':' || right(user_id::text, 1), ',' order by action) from public.audit_logs where entity_id = 'f1000000-0000-0000-0000-000000000001' and action like 'offer.claim%'")
[ "$a" = "offer.claim_cancelled:3" ] && ok "an admin's claim action is audited; a business's own claim is not ($a)" || bad "claim audit: $a"

# rollback, twice, restores every function exactly; then applies again
"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_admin_permissions_rollback.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_admin_permissions_rollback.sql" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
[ "$(fingerprint)" = "$before" ] && ok "rollback restores every function exactly" || bad "fingerprints differ after rollback"
left=$(q "select (select count(*) from pg_policies where policyname = 'platform_incidents_admin_view') + (select count(*) from pg_trigger where tgname in ('zella_audit_admin_incident','zella_audit_admin_alert')) + (select count(*) from public.zella_function_archive where migration = 'zella_admin_permissions')")
[ "$left" = "0" ] && ok "rollback leaves no policy, trigger or archive rows behind" || bad "rollback left $left"
"${P[@]}" -d $DB -f "$REPO/sql/zella_admin_permissions.sql" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"

# a function that drifted from production stops the file
q "create or replace function public.zella_offers_list() returns jsonb language sql as \$f\$ select '[]'::jsonb \$f\$" > /dev/null
"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_admin_permissions_rollback.sql" > /dev/null 2>&1
q "create or replace function public.zella_offers_list() returns jsonb language plpgsql as \$f\$ begin if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if; return '[]'::jsonb; end \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_admin_permissions.sql" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"* ]] && ok "a function that isn't production's version stops the file (VERSION_MISMATCH)" || bad "drift not caught: $out"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
