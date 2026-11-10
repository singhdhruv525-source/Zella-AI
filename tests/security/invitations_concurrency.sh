#!/usr/bin/env bash
# Two real sessions racing on one invitation (run by tests/security/run.sh after invitations_test.sql, which leaves
# its fixture users and business in the database). Usage: invitations_concurrency.sh <db>
set -u
DB="$1"; PSQL="psql -h $ZPG_HOST -p $ZPG_PORT -U postgres -X -q -At -v ON_ERROR_STOP=1 -d $DB"
OWNER=a0000000-0000-0000-0000-000000000001; PERSON=a0000000-0000-0000-0000-000000000005; BIZ=b0000000-0000-0000-0000-000000000001
ok=0
new_inv() { $PSQL -c "insert into public.business_invitations (business_id, email, owner_name, invited_by, status, role, invited_at, expires_at)
  values ('$BIZ', 'other@biz.test', 'x', '$OWNER', 'pending', 'staff', now(), now() + interval '1 day') returning id" | head -1; }
as_owner="select set_config('request.jwt.claims', '{\"sub\":\"$OWNER\",\"role\":\"authenticated\"}', true); set local role authenticated;"
$PSQL -c "delete from public.business_invitations where email = 'other@biz.test'; delete from public.business_members where user_id = '$PERSON'"

# A. The owner cancels (holding the row for 2 s) while the send finishes: the send must wait, then see CLOSED.
INV=$(new_inv)
( $PSQL -c "begin; $as_owner select public.zella_cancel_invitation('$INV'); select pg_sleep(2); commit;" >/dev/null ) &
sleep 0.5
R=$($PSQL -c "select public.zella_staff_invite_finalize('$INV', '$OWNER', '$PERSON')"); wait
S=$($PSQL -c "select status from public.business_invitations where id = '$INV'")
[ "$R" = "CLOSED" ] && [ "$S" = "revoked" ] && echo "PASS concurrent cancel then send: send waits and sees CLOSED, invitation stays revoked" || { echo "FAIL A: finalize=$R status=$S"; ok=1; }

# B. The send holds the row while the owner cancels: the cancel waits, wins afterwards, and a late error can't reopen it.
INV=$(new_inv)
( $PSQL -c "begin; select public.zella_staff_invite_finalize('$INV', '$OWNER', '$PERSON'); select pg_sleep(2); commit;" >/dev/null ) &
sleep 0.5
$PSQL -c "begin; $as_owner select public.zella_cancel_invitation('$INV'); commit;" >/dev/null; wait
F=$($PSQL -c "select public.zella_staff_invite_fail('$INV', 'late timeout')")
S=$($PSQL -c "select status from public.business_invitations where id = '$INV'")
[ "$F" = "CLOSED" ] && [ "$S" = "revoked" ] && echo "PASS concurrent send then cancel: cancel wins, late error can't reopen" || { echo "FAIL B: fail=$F status=$S"; ok=1; }

# C. The old code path (update by id only) DOES reopen a cancelled invitation; shown so the test proves the bug existed.
INV=$(new_inv)
$PSQL -c "begin; $as_owner select public.zella_cancel_invitation('$INV'); commit;" >/dev/null
$PSQL -c "update public.business_invitations set status = 'failed' where id = '$INV'"   # what staff-invite did before
S=$($PSQL -c "select status from public.business_invitations where id = '$INV'")
[ "$S" = "failed" ] && echo "PASS (repro) the previous unconditional update reopened a cancelled invitation" || { echo "FAIL C repro: $S"; ok=1; }
exit $ok
