#!/usr/bin/env bash
# CFG-22 (owner-provision-business business_pack_grant, which calls zella_admin_pack_grant as the signed in admin) on an
# ISOLATED copy of the production schema (zprod3; never production). Test data only. Checks, with simulated admin JWT
# claims (as the function's caller client sends them):
#   - a billing.manage admin grants a pack once per idempotency key (a second call is a duplicate, one balance added);
#   - an admin without billing.manage is refused;
#   - a business with no current period is refused (NO_CURRENT_PERIOD), and no period is opened to make it work.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zle_pack_grant}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
# this suite drops and recreates DB: only a database named for this suite, and never the template
[[ "$DB" =~ ^z[a-z0-9_]*pack_grant$ ]] && [[ "$TEMPLATE" =~ ^[a-z_][a-z0-9_]*$ ]] && [ "$DB" != "$TEMPLATE" ] \
  || { echo "REFUSED: DB must be this suite's own database (z..._pack_grant) and TEMPLATE a lowercase name, not '$DB' / '$TEMPLATE'" >&2; exit 1; }
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
# on any exit this suite's database goes; a failed drop fails an otherwise passing run
cleanup() { local rc=$?; "${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null 2>&1 || { echo "FAIL dropping $DB"; [ $rc -eq 0 ] && rc=1; }; exit $rc; }
trap cleanup EXIT
q() { "${P[@]}" -d $DB -c "$1"; }
BILL=ea000000-0000-0000-0000-0000000000a1; RO=ea000000-0000-0000-0000-0000000000a2; BIZ=ea000000-0000-0000-0000-00000000b000; BARE=ea000000-0000-0000-0000-00000000b001
q "insert into auth.users (id, email, email_confirmed_at) values ('$BILL', 'billing@grant.test', now()), ('$RO', 'reader@grant.test', now());
   insert into public.platform_admins (user_id, role) values ('$BILL', 'billing_admin'), ('$RO', 'read_only_admin');
   insert into public.platform_role_permissions (role, permission) values ('billing_admin', 'billing.view'), ('billing_admin', 'billing.manage'), ('read_only_admin', 'businesses.view') on conflict do nothing;
   insert into public.businesses (id, name, industry_id, timezone, onboarding_status, is_active)
     select v.id, v.n, i.id, 'America/New_York', 'active', true from (values ('$BIZ'::uuid, 'Grant Test'), ('$BARE'::uuid, 'No Period Test')) v(id, n),
       (select id from public.industries order by name limit 1) i;
   insert into public.business_plans (business_id, version, tier, billing_interval, price_cents, minutes, texts, emails, team_seats, phone_numbers, locations, languages, idempotency_key, values_hash, overage_cents_per_minute)
     values ('$BIZ', 1, 'base', 'monthly', 9900, 300, 500, 1000, 3, 1, 1, array['en'], 'grant-test-1', 'h1', 20);
   insert into public.subscriptions (business_id, status, billing_interval, current_period_start, current_period_end)
     values ('$BIZ', 'active', 'monthly', date_trunc('month', now()), date_trunc('month', now()) + interval '1 month');" > /dev/null \
  || { echo "FAIL fixtures"; exit 1; }
PACK=$(q "select code from public.billing_pack_catalog where active order by resource, quantity limit 1")
[ -n "$PACK" ] || { echo "FAIL no active pack in the catalog"; exit 1; }
as() { q "do \$\$ declare v text; begin perform set_config('request.jwt.claims', json_build_object('sub', '$1', 'role', 'authenticated', 'aal', 'aal2')::text, true);
  set local role authenticated; begin v := ($2)::text; exception when others then v := 'ERR:' || sqlerrm; end; reset role; raise notice 'V=%', v; end \$\$" 2>&1 | sed -n 's/.*V=//p'; }

v=$(as $BILL "public.zella_admin_pack_grant('$BIZ', '$PACK', 'Goodwill for an outage', 'dialog-key-0001')")
[[ "$v" == *'"granted"'* ]] && ok "a billing.manage admin grants a pack" || bad "grant: $v"
v=$(as $BILL "public.zella_admin_pack_grant('$BIZ', '$PACK', 'Goodwill for an outage', 'dialog-key-0001')")
[[ "$v" == *'"duplicate"'* ]] && ok "the same dialog's key again is a duplicate" || bad "duplicate: $v"
n=$(q "select count(*) from public.allowance_buckets where business_id = '$BIZ' and kind = 'pack'")
[ "$n" = "1" ] && ok "one balance added for the two calls" || bad "pack balances: $n"
a=$(q "select count(*) from public.audit_logs where business_id = '$BIZ' and action = 'billing.pack_granted' and user_id = '$BILL'")
[ "$a" = "1" ] && ok "one billing.pack_granted row, with the admin's id" || bad "audit rows: $a"
v=$(as $RO "public.zella_admin_pack_grant('$BIZ', '$PACK', 'Goodwill for an outage', 'dialog-key-0002')")
[[ "$v" == *NOT_ALLOWED* ]] && ok "an admin without billing.manage is refused" || bad "read only: $v"
before=$(q "select count(*) from public.billing_periods where business_id = '$BARE'") || before="read failed"
v=$(as $BILL "public.zella_admin_pack_grant('$BARE', '$PACK', 'Goodwill for an outage', 'dialog-key-0003')")
after=$(q "select count(*) from public.billing_periods where business_id = '$BARE'") || after="read failed"
[[ "$v" == *NO_CURRENT_PERIOD* ]] && [ "$before" = "0" ] && [ "$after" = "0" ] && ok "no current period is refused and no period is opened ($before -> $after)" || bad "no period: $v ($before -> $after)"

[ $fails -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
