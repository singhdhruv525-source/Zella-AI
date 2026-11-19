#!/usr/bin/env bash
# sql/zella_business_member_admin.sql on an ISOLATED copy of the production schema (never production). Test people only.
# Checks: applies, and applies again; member status changes from what the page showed only (STALE otherwise, also when
# the status was changed after the page read it), never the last active owner, also when two owners are deactivated
# at the same moment; only the server key may call either function; an owner invitation is revoked with its invited
# seat in one transaction (a failed seat removal leaves the invitation open), only the one the page showed while it
# is the latest; the rollback (run twice) drops both; a changed function, owner or grant stops the file and the rollback.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zle_member_admin}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
# this suite drops and recreates DB: only a database named for this suite (lowercase), and never the template
[[ "$DB" =~ ^z[a-z0-9_]*member_admin$ ]] && [[ "$TEMPLATE" =~ ^[a-z_][a-z0-9_]*$ ]] && [ "$DB" != "$TEMPLATE" ] \
  || { echo "REFUSED: DB must be this suite's own database (z..._member_admin) and TEMPLATE a lowercase name, not '$DB' / '$TEMPLATE'" >&2; exit 1; }
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
RUN=$(mktemp -d) || exit 1
# on any exit: the worker files and this suite's database go; a failed drop fails an otherwise passing run
cleanup() { local rc=$?; rm -rf "$RUN"; "${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null 2>&1 || { echo "FAIL dropping $DB"; [ $rc -eq 0 ] && rc=1; }; exit $rc; }
trap cleanup EXIT
q() { "${P[@]}" -d $DB -c "$1"; }
MIG="$REPO/sql/zella_business_member_admin.sql"; RB="$REPO/sql/rollback/zella_business_member_admin_rollback.sql"
BIZ=e8000000-0000-0000-0000-00000000b000
O1=e8000000-0000-0000-0000-0000000000a1; O2=e8000000-0000-0000-0000-0000000000a2; M1=e8000000-0000-0000-0000-0000000000a3; INV=e8000000-0000-0000-0000-0000000000a4
I1=e8000000-0000-0000-0000-0000000000c1; I2=e8000000-0000-0000-0000-0000000000c2
q "insert into auth.users (id, email, email_confirmed_at) values ('e8000000-0000-0000-0000-0000000000ad', 'admin@member.test', now()), ('$O1', 'own1@member.test', now()), ('$O2', 'own2@member.test', now()), ('$M1', 'staff@member.test', now()), ('$INV', 'invited@member.test', now());
   insert into public.businesses (id, name, industry_id, timezone, onboarding_status, is_active)
     select '$BIZ', 'Member Test', id, 'America/Chicago', 'active', true from public.industries order by name limit 1;
   insert into public.business_members (business_id, user_id, role, status) values ('$BIZ', '$O1', 'owner', 'active'), ('$BIZ', '$M1', 'staff', 'active')" > /dev/null \
  || { bad "fixture"; exit 1; }
[ "$(q "select count(*) from public.business_members where business_id = '$BIZ'")" = "2" ] || { bad "fixture rows"; exit 1; }

"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$MIG" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"

# as(role, sql): runs sql as that role; prints the result or the error
as() { q "do \$\$ declare r text; begin execute 'set local role $1'; begin execute '$2' into r; raise notice 'R=%', r; exception when others then raise notice 'R=%', sqlerrm; end; reset role; end \$\$" 2>&1 | sed -n 's/.*R=//p'; }
ADMIN=e8000000-0000-0000-0000-0000000000ad; REASON="Owner asked by phone, checked"
set_status() { as service_role "select public.zella_admin_member_set_status(''$BIZ'', ''$1'', ''$2'', ''$3'', $4, ''$ADMIN'', ''$REASON'')::text"; }
status() { q "select status from public.business_members where business_id = '$BIZ' and user_id = '$1'"; }

r=$(as authenticated "select public.zella_admin_member_set_status(''$BIZ'', ''$M1'', ''suspended'', ''active'', null, ''$ADMIN'', ''$REASON'')::text")
[[ "$r" == *"permission denied"* ]] && ok "a signed in person can't call the status change" || bad "authenticated status: $r"
r=$(as authenticated "select public.zella_admin_invitation_cancel(''$BIZ'', ''$I1'')::text")
[[ "$r" == *"permission denied"* ]] && ok "nor the invitation cancel" || bad "authenticated cancel: $r"

r=$(set_status "$M1" suspended suspended null)
[[ "$r" == *"STALE"* ]] && [ "$(status $M1)" = "active" ] && ok "a change from a status the page didn't show is refused (STALE)" || bad "stale expected: $r"
r=$(set_status "$M1" suspended active null)
[[ "$r" == *'"before": "active"'* ]] && [ "$(status $M1)" = "suspended" ] && ok "a member is deactivated from the status the page showed" || bad "suspend: $r"
row=$(q "select user_id || '|' || (old_data ->> 'status') || '|' || (new_data ->> 'status') || '|' || (new_data ->> 'reason') from public.audit_logs where business_id = '$BIZ' and action = 'member.suspended' and new_data ->> 'user_id' = '$M1'")
[ "$row" = "$ADMIN|active|suspended|$REASON" ] && ok "and its member.suspended row is written in the same transaction, with the admin, before, after and reason" || bad "audit row: $row"
r=$(as service_role "select public.zella_admin_member_set_status(''$BIZ'', ''$M1'', ''active'', ''suspended'', null, ''$ADMIN'', ''short'')::text")
[[ "$r" == *"BAD_INPUT"* ]] && [ "$(status $M1)" = "suspended" ] && ok "a reason under 10 characters changes nothing (BAD_INPUT)" || bad "short reason: $r"
# another admin reactivates and deactivates again after this page read the member (the function's own rows)
seen=$(q "select now()")
r1=$(set_status "$M1" active suspended null); r2=$(set_status "$M1" suspended active null)
[[ "$r1" == *before* ]] && [[ "$r2" == *before* ]] || bad "stale fixture: $r1 / $r2"
r=$(set_status "$M1" active suspended "''$seen''::timestamptz")
[[ "$r" == *"STALE"* ]] && [ "$(status $M1)" = "suspended" ] && ok "a page older than the member's last status change is refused (STALE), even with the same status" || bad "stale seen_at: $r"
r=$(set_status "$M1" active suspended "now()")
[[ "$r" == *'"before": "suspended"'* ]] && [ "$(status $M1)" = "active" ] && ok "a current page reactivates the member" || bad "reactivate: $r"
r=$(set_status "$O1" suspended active null)
[[ "$r" == *"LAST_OWNER"* ]] && [ "$(status $O1)" = "active" ] && ok "the only active owner can't be deactivated (LAST_OWNER)" || bad "last owner: $r"

# two owners deactivated at the same moment: one waits for the business row, then finds no other active owner
q "insert into public.business_members (business_id, user_id, role, status) values ('$BIZ', '$O2', 'owner', 'active')" > /dev/null || { bad "second owner"; exit 1; }
# both start together; whichever takes the business row first wins, the other waits and is refused
for o in "$O1" "$O2"; do
  ( "${P[@]}" -d $DB -c "begin; set local role service_role; select public.zella_admin_member_set_status('$BIZ', '$o', 'suspended', 'active', null, '$ADMIN', '$REASON'); select pg_sleep(1); commit;" > "$RUN/$o.out" 2>&1; echo $? > "$RUN/$o.rc" ) &
done
wait
won=0; lost=0
for o in "$O1" "$O2"; do
  if [ "$(cat "$RUN/$o.rc")" = "0" ]; then won=$((won + 1)); elif grep -q LAST_OWNER "$RUN/$o.out"; then lost=$((lost + 1)); fi
done
owners=$(q "select count(*) from public.business_members where business_id = '$BIZ' and role = 'owner' and status = 'active'")
[ $won -eq 1 ] && [ $lost -eq 1 ] && [ "$owners" = "1" ] && ok "two owners deactivated at once: one goes through, the other is refused (LAST_OWNER), one active owner stays" || bad "concurrent owners: won $won, lost $lost, owners $owners: $(cat "$RUN/$O1.out" "$RUN/$O2.out")"

# owner invitations: the one the page showed, with its seat, in one transaction
q "insert into public.business_invitations (id, business_id, email, owner_name, invited_by, status, role, auth_user_id, created_at) values
     ('$I1', '$BIZ', 'invited@member.test', 'Old', '$O1', 'expired', 'owner', null, now() - interval '2 days'),
     ('$I2', '$BIZ', 'invited@member.test', 'New', '$O1', 'sent', 'owner', '$INV', now());
   insert into public.business_members (business_id, user_id, role, status) values ('$BIZ', '$INV', 'owner', 'invited')" > /dev/null || { bad "invitation fixture"; exit 1; }
cancel() { as service_role "select public.zella_admin_invitation_cancel(''$BIZ'', ''$1'')::text"; }
r=$(cancel "$I1")
[[ "$r" == *"STALE"* ]] && [ "$(q "select status from public.business_invitations where id = '$I2'")" = "sent" ] && ok "an older invitation than the latest is refused (STALE) and the newer one stays" || bad "older invitation: $r"
# a seat removal that fails leaves the invitation open (test only trigger)
q "create function public.zq_no_delete() returns trigger language plpgsql as \$f\$ begin raise exception 'seat delete failed'; end \$f\$;
   create trigger zq_no_delete before delete on public.business_members for each row execute function public.zq_no_delete()" > /dev/null || bad "failure fixture"
r=$(cancel "$I2")
[[ "$r" == *"seat delete failed"* ]] && [ "$(q "select status from public.business_invitations where id = '$I2'")" = "sent" ] && [ "$(status $INV)" = "invited" ] && ok "when the seat can't be removed, the invitation stays open too (one transaction)" || bad "atomic cancel: $r"
q "drop trigger zq_no_delete on public.business_members; drop function public.zq_no_delete()" > /dev/null || bad "failure fixture cleanup"
r=$(cancel "$I2")
[[ "$r" == *'"seat_removed": true'* ]] && [ "$(q "select status from public.business_invitations where id = '$I2'")" = "revoked" ] && [ "$(q "select count(*) from public.business_members where business_id = '$BIZ' and user_id = '$INV'")" = "0" ] && ok "the shown invitation is revoked and its invited seat removed" || bad "cancel: $r"
r=$(cancel "$I2")
[[ "$r" == *"STALE"* ]] && ok "cancelling it again is refused (STALE)" || bad "cancel twice: $r"
q "update public.business_invitations set status = 'accepted' where id = '$I1'" > /dev/null
r=$(cancel "$I1")
[[ "$r" == *"ACCEPTED"* ]] && ok "an accepted invitation is refused (ACCEPTED)" || bad "accepted: $r"

# drift: a changed function, owner or grant stops the file and its rollback, and changes nothing
SIG="public.zella_admin_invitation_cancel(uuid,uuid)"
present() { local v; v=$(q "select to_regprocedure('$SIG') is not null") && [ "$v" = "t" ]; }
for change in "grant execute on function $SIG to authenticated|revoke execute on function $SIG from authenticated|given to another role|can be run by a role" \
              "revoke execute on function $SIG from service_role|grant execute on function $SIG to service_role|lost its grant|lost the grant" \
              "alter function $SIG owner to service_role|alter function $SIG owner to postgres; grant execute on function $SIG to service_role|changed owner|another owner"; do
  IFS='|' read -r make undo rbmsg migmsg <<< "$change"
  q "$make" > /dev/null || { bad "drift fixture: $make"; continue; }
  out=$("${P[@]}" -d $DB -f "$MIG" 2>&1); rc=$?
  [ $rc -ne 0 ] && [[ "$out" == *"$migmsg"* ]] && ok "the file stops when: $make" || bad "file drift ($make): $out"
  out=$("${P[@]}" -d $DB -f "$RB" 2>&1); rc=$?
  [ $rc -ne 0 ] && [[ "$out" == *"$rbmsg"* ]] && present && ok "and the rollback refuses, dropping nothing" || bad "rollback drift ($make): $out"
  q "$undo" > /dev/null || bad "drift undo: $undo"
done
audits=$(q "select count(*) from public.audit_logs where business_id = '$BIZ'")
o1=$("${P[@]}" -d $DB -f "$RB" 2>&1); e1=$?; o2=$("${P[@]}" -d $DB -f "$RB" 2>&1); e2=$?
[ $e1 -eq 0 ] && [ $e2 -eq 0 ] && ok "rollback runs twice" || bad "rollback: $o1 $o2"
v=$(q "select (to_regprocedure('public.zella_admin_member_set_status(uuid,uuid,text,text,timestamptz,uuid,text)') is null and to_regprocedure('$SIG') is null)::text") && [ "$v" = "true" ] && ok "rollback drops both functions" || bad "functions left: $v"
[ "$(status $M1)" = "active" ] && [ "$(q "select count(*) from public.audit_logs where business_id = '$BIZ'")" = "$audits" ] && ok "and leaves members and audit rows as they are" || bad "rollback changed data"
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_admin_invitation_cancel(p_business_id uuid, p_invitation_id uuid) returns jsonb language sql security definer set search_path = '' as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$MIG" 2>&1); rc=$?
[ $rc -ne 0 ] && [[ "$out" == *"VERSION_MISMATCH"* ]] && ok "a changed function stops the file (VERSION_MISMATCH)" || bad "drift not caught: $out"
out=$("${P[@]}" -d $DB -f "$RB" 2>&1); rc=$?
[ $rc -ne 0 ] && [[ "$out" == *"DRIFT"* ]] && present && ok "and the rollback (DRIFT), dropping nothing" || bad "rollback drift: $out"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
