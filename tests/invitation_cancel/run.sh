#!/usr/bin/env bash
# BIZ-21 part b (owner-provision-business invitation_cancel) on an ISOLATED copy of the production schema (zprod3;
# never production). Test data only. What the cancel relies on in the database:
#   1. a revoked owner invitation stops zella_accept_my_invitations from activating the invited seat, even if the seat
#      row were left behind;
#   2. a seat can't be set 'inactive' (business_members_status_check), which is why the cancel deletes the invited seat;
#   3. after the cancel removed the seat, inviting the same person again and signing in through the link activates
#      the new seat.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zle_invitation_cancel}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
# this suite drops and recreates DB: only a database named for this suite, and never the template
[[ "$DB" =~ ^z[a-z0-9_]*invitation_cancel$ ]] && [ "$DB" != "$TEMPLATE" ] || { echo "REFUSED: DB must be this suite's own database (z..._invitation_cancel), not '$DB'" >&2; exit 1; }
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
OWNER=e9000000-0000-0000-0000-0000000000b1; ADMIN=e9000000-0000-0000-0000-0000000000a1; BIZ=e9000000-0000-0000-0000-00000000b000
q "insert into auth.users (id, email, email_confirmed_at) values ('$OWNER', 'ola@cancel.test', now()), ('$ADMIN', 'admin@cancel.test', now());
   insert into public.profiles (id) values ('$ADMIN') on conflict do nothing;
   insert into public.businesses (id, name, industry_id, timezone, onboarding_status, is_active)
     select '$BIZ', 'Cancel Test', id, 'America/New_York', 'testing', true from public.industries order by name limit 1;
   insert into public.business_invitations (business_id, email, owner_name, invited_by, status, auth_user_id, invited_at, expires_at, role)
     values ('$BIZ', 'ola@cancel.test', 'Ola', '$ADMIN', 'revoked', '$OWNER', now(), now() + interval '7 days', 'owner');
   insert into public.business_members (business_id, user_id, role, status) values ('$BIZ', '$OWNER', 'owner', 'invited');" > /dev/null \
  || { echo "FAIL fixtures"; exit 1; }
# signed in as the owner through the email link (amr otp), as the app does
accept() { q "do \$\$ declare v text; begin perform set_config('request.jwt.claims', json_build_object('sub', '$OWNER', 'role', 'authenticated', 'aal', 'aal1', 'amr', json_build_array(json_build_object('method', 'otp')))::text, true);
  set local role authenticated; begin v := public.zella_accept_my_invitations()::text; exception when others then v := 'ERR:' || sqlerrm; end; reset role; raise notice 'V=%', v; end \$\$" 2>&1 | sed -n 's/.*V=//p'; }

v=$(accept); s=$(q "select status from public.business_members where business_id = '$BIZ' and user_id = '$OWNER'")
[ "$v" = "0" ] && [ "$s" = "invited" ] && ok "a revoked owner invitation activates nothing, even with the seat left behind ($v, $s)" || bad "revoked: accepted=$v seat=$s"
v=$(q "update public.business_members set status = 'inactive' where business_id = '$BIZ' and user_id = '$OWNER'" 2>&1)
[[ "$v" == *business_members_status_check* ]] && ok "a seat can't be set inactive, so the cancel deletes the invited seat" || bad "inactive: $v"

# what invitation_cancel does, then what Owner and Finish (or Resend) do for the same person
q "delete from public.business_members where business_id = '$BIZ' and user_id = '$OWNER' and role = 'owner' and status = 'invited';
   insert into public.business_invitations (business_id, email, owner_name, invited_by, status, auth_user_id, invited_at, expires_at, role)
     values ('$BIZ', 'ola@cancel.test', 'Ola', '$ADMIN', 'sent', '$OWNER', now(), now() + interval '7 days', 'owner');
   insert into public.business_members (business_id, user_id, role, status) values ('$BIZ', '$OWNER', 'owner', 'invited');" > /dev/null || bad "reinvite fixtures"
v=$(accept); s=$(q "select status from public.business_members where business_id = '$BIZ' and user_id = '$OWNER'")
[ "$v" = "1" ] && [ "$s" = "active" ] && ok "inviting the same person again after a cancel works: signing in activates the seat" || bad "reinvite: accepted=$v seat=$s"

"${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null
[ $fails -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
