#!/usr/bin/env bash
# The admin Business page's data (owner-provision-business detail.ts, payload v2) on an ISOLATED copy of the production
# schema (zprod3; never production). Test data only. Checks:
#   - the readiness, activation and delivery functions answer the server key (auth.uid() null), and the routing one
#     refuses it (so detail.ts works routing out itself);
#   - reading them creates no billing period (the page writes nothing);
#   - routingFrom (detail.ts) gives what zella_admin_routing_get gives an admin for the same rules;
#   - usageSummary over the current period's balances (reserve included) equals zella_billing_overview's numbers for a billing.view admin.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zle_admin_detail}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
# this suite drops and recreates DB: only a database named for this suite, and never the template
[[ "$DB" =~ ^z[a-z0-9_]*admin_detail$ ]] && [ "$DB" != "$TEMPLATE" ] || { echo "REFUSED: DB must be this suite's own database (z..._admin_detail), not '$DB'" >&2; exit 1; }
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
ADMIN=e7000000-0000-0000-0000-0000000000a1; BIZ=e7000000-0000-0000-0000-00000000b000
q "insert into auth.users (id, email, email_confirmed_at) values ('$ADMIN', 'admin@detail.test', now());
   insert into public.platform_admins (user_id, role) values ('$ADMIN', 'zella_owner');
   insert into public.businesses (id, name, industry_id, timezone, onboarding_status, is_active)
     select '$BIZ', 'Detail Test', id, 'America/Chicago', 'active', true from public.industries order by name limit 1;
   insert into public.ai_agents (business_id, name, agent_type, is_default, status) values ('$BIZ', 'Ava', 'receptionist', true, 'active');
   insert into public.ai_agent_configs (agent_id, escalation_rules)
     select id, '{\"transfer_to\": {\"type\": \"phone_number\", \"phone\": \"+15550104001\"}, \"fallback_number\": \"+15550104002\", \"transfer_route\": \"primary\", \"transfer_open_hours_only\": false}'
       from public.ai_agents where business_id = '$BIZ';
   insert into public.business_plans (business_id, version, tier, billing_interval, price_cents, minutes, texts, emails, team_seats,
     phone_numbers, locations, languages, idempotency_key, values_hash, overage_cents_per_minute)
     values ('$BIZ', 1, 'base', 'monthly', 9900, 300, 500, 1000, 3, 1, 1, array['en'], 'detail-test-1', 'h1', 20);
   insert into public.subscriptions (business_id, status, billing_interval, current_period_start, current_period_end)
     values ('$BIZ', 'active', 'monthly', date_trunc('month', now()), date_trunc('month', now()) + interval '1 month');
   insert into public.billing_periods (business_id, business_plan_id, period_start, period_end)
     select '$BIZ', id, date_trunc('month', now()), date_trunc('month', now()) + interval '1 month' from public.business_plans where business_id = '$BIZ';
   insert into public.allowance_buckets (business_id, period_id, resource, kind, granted, used, expires_at)
     select '$BIZ', p.id, r, k, g, u, p.period_end from public.billing_periods p,
       (values ('minutes', 'plan', 300, 120), ('minutes', 'rollover', 20, 20), ('texts', 'plan', 500, 10), ('texts', 'buffer', 25, 0), ('emails', 'plan', 1000, 0)) v(r, k, g, u)
      where p.business_id = '$BIZ';
   insert into public.business_phone_numbers (business_id, e164, status) values ('$BIZ', '+15550104000', 'active');
   insert into public.platform_alerts (kind, title, business_id, status) values ('test_open', 'Open one', '$BIZ', 'open'), ('test_done', 'Done one', '$BIZ', 'resolved');
   insert into public.assistant_deliveries (business_id, outcome, problems) values ('$BIZ', 'served', '[]'), ('$BIZ', 'not_ready', '[\"no hours\"]');" > /dev/null \
  || { echo "FAIL fixtures"; exit 1; }

as_service() { q "set role service_role; select $1"; }
as_admin() { q "do \$\$ declare v text; begin perform set_config('request.jwt.claims', json_build_object('sub', '$ADMIN', 'role', 'authenticated', 'aal', 'aal2')::text, true);
  set local role authenticated; begin execute \$q\$select ($1)::text\$q\$ into v; exception when others then v := 'ERR:' || sqlerrm; end; reset role; raise notice 'V=%', v; end \$\$" 2>&1 | sed -n 's/.*V=//p'; }

before=$(q "select count(*) from public.billing_periods")
for f in zella_business_readiness zella_activation_report zella_assistant_delivery_status; do
  v=$(as_service "public.$f('$BIZ')::text" 2>&1 | tail -1)
  [[ "$v" == "{"* ]] && ok "$f answers the server key" || bad "$f as server: $v"
done
v=$(as_service "public.zella_admin_routing_get('$BIZ')::text" 2>&1 | tr "\n" " ")
[[ "$v" == *NOT_ALLOWED* ]] && ok "zella_admin_routing_get refuses the server key, so detail.ts derives routing" || bad "routing as server: $v"
after=$(q "select count(*) from public.billing_periods")
[ "$before" = "$after" ] && ok "reading the page's functions creates no billing period ($before)" || bad "billing periods $before -> $after"

routing=$(as_admin "public.zella_admin_routing_get('$BIZ')")
rules=$(q "select coalesce(c.escalation_rules, '{}')::text from public.ai_agents a join public.ai_agent_configs c on c.agent_id = a.id where a.business_id = '$BIZ' and a.is_default")
mine=$(cd "$REPO/web/supabase/functions/owner-provision-business" && deno eval --no-lock --config deno.json "
  import { routingFrom } from './detail.ts';
  const r = routingFrom(JSON.parse(Deno.args[0] ?? '{}'), { timezone: 'America/Chicago', hasAgent: true, hasHours: false, onCall: null });
  console.log(JSON.stringify(r));" -- "$rules" 2>&1)
cmp=$(python3 -I -c "
import json,sys
db=json.loads(sys.argv[1]); mine=json.loads(sys.argv[2]); db.pop('business_id', None)
print('same' if db == mine else 'db=%s mine=%s' % (db, mine))" "$routing" "$mine" 2>&1)
[ "$cmp" = same ] && ok "routingFrom equals zella_admin_routing_get for the same rules" || bad "routing: $cmp"

overview=$(as_admin "public.zella_billing_overview('$BIZ')")
buckets=$(q "select json_agg(json_build_object('resource', resource, 'kind', kind, 'granted', granted, 'used', used)) from public.allowance_buckets b
  join public.billing_periods p on p.id = b.period_id where b.business_id = '$BIZ' and p.period_start <= now() and now() < p.period_end")
mine=$(cd "$REPO/web/supabase/functions/owner-provision-business" && deno eval --no-lock --config deno.json "
  import { usageSummary } from './detail.ts';
  console.log(JSON.stringify(usageSummary(JSON.parse(Deno.args[0]))));" -- "$buckets" 2>&1)
cmp=$(python3 -I -c "
import json,sys
o=json.loads(sys.argv[1])['usage']; m=json.loads(sys.argv[2]); out=[]
for r in ('minutes','texts','emails'):
    if float(o[r]['included']) != m[r]['granted'] or float(o[r]['remaining']) != m[r]['remaining'] or float(o[r]['buffer_remaining']) != m[r]['reserveRemaining']: out.append('%s db=%s mine=%s' % (r, o[r], m[r]))
print('; '.join(out) or 'same')" "$overview" "$mine" 2>&1)
[ "$cmp" = same ] && ok "usage totals and the message reserve equal zella_billing_overview for a billing.view admin" || bad "usage: $cmp"

"${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null
[ $fails -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
