#!/usr/bin/env bash
# M10 (database part): sql/zella_invitation_limits.sql. Checks: before, an owner can invite without any cap (the gap);
# after, the 21st invitation in an hour is refused (TOO_MANY_INVITES), a resend within 10 minutes is refused
# (RESEND_TOO_SOON) only after its email went out, resends count against the same cap, another business is unaffected;
# applies twice; rollback twice restores both functions exactly; drift stops the file and the rollback.
. "$(dirname "$0")/lib.sh"; fresh_db invitation_limits
SIGS="'public.zella_invite_staff(uuid,text,text,text)','public.zella_resend_invitation(uuid)'"
fp() { q "select string_agg(md5(pg_get_functiondef(s::regprocedure)), ',' order by s) from unnest(array[$SIGS]) s"; }; before=$(fp)
O=f7000000-0000-0000-0000-000000000001; O2=f7000000-0000-0000-0000-000000000002
q "insert into auth.users (id, email, email_confirmed_at) values ('$O', 'own@inv.test', now()), ('$O2', 'own2@inv.test', now())" > /dev/null
B=$(q "insert into public.businesses (name, industry_id) select 'Invite Test', id from public.industries limit 1 returning id" | head -1)
B2=$(q "insert into public.businesses (name, industry_id) select 'Other', id from public.industries limit 1 returning id" | head -1)
q "insert into public.business_members (business_id, user_id, role, status) values ('$B', '$O', 'owner', 'active'), ('$B2', '$O2', 'owner', 'active')" > /dev/null
inv() { as_user $1 aal1 "raise notice 'R=%', public.zella_invite_staff('$2', '$3', 'X', 'staff');"; }
for n in $(seq 1 25); do inv $O $B "pre$n@inv.test" > /dev/null; done
[ "$(q "select count(*) from public.business_invitations where business_id = '$B'")" = 25 ] && ok "before: 25 invitations in a row go through (the gap)" || bad "before"
q "delete from public.business_invitations" > /dev/null
out=$(apply "$REPO/sql/zella_invitation_limits.sql") && ok "applies" || { bad "applies: $out"; finish; }
out=$(apply "$REPO/sql/zella_invitation_limits.sql") && ok "applies again" || bad "second apply: $out"
[ "$(fp)" = "cab03bae58b60089f19b480b7f6f58ee,bc0872cbffde6dc83f1bb89943aef9bf" ] && ok "new fingerprints are the recorded ones" || bad "fingerprints $(fp)"
for n in $(seq 1 20); do r=$(inv $O $B "p$n@inv.test"); [[ "$r" == ERR:* ]] && bad "invite $n refused: $r"; done
r=$(inv $O $B "p21@inv.test"); [[ "$r" == *TOO_MANY_INVITES* ]] && ok "the 21st invitation in an hour is refused" || bad "21st: $r"
[ "$(q "select count(*) from public.business_invitations where business_id = '$B'")" = 20 ] && ok "and nothing was saved for it" || bad "count"
r=$(inv $O2 $B2 "q1@inv.test"); [[ "$r" != ERR:* ]] && ok "another business is unaffected" || bad "other business: $r"
I=$(q "select id from public.business_invitations where business_id = '$B2'")
r=$(as_user $O2 aal1 "perform public.zella_resend_invitation('$I'); raise notice 'R=ran';"); [ "$r" = ran ] && ok "a resend before any email went out (still pending) is allowed" || bad "pending resend: $r"
q "update public.business_invitations set status = 'sent', invited_at = now() where id = '$I'" > /dev/null
r=$(as_user $O2 aal1 "perform public.zella_resend_invitation('$I'); raise notice 'R=ran';"); [[ "$r" == *RESEND_TOO_SOON* ]] && ok "a resend within 10 minutes of a sent email is refused" || bad "too soon: $r"
q "update public.business_invitations set status = 'failed' where id = '$I'" > /dev/null
r=$(as_user $O2 aal1 "perform public.zella_resend_invitation('$I'); raise notice 'R=ran';"); [ "$r" = ran ] && ok "a failed send can be retried at once" || bad "failed retry: $r"
q "update public.business_invitations set invited_at = now() - interval '11 minutes' where business_id = '$B'" > /dev/null
I1=$(q "select id from public.business_invitations where business_id = '$B' limit 1")
r=$(as_user $O aal1 "perform public.zella_resend_invitation('$I1'); raise notice 'R=ran';"); [[ "$r" == *TOO_MANY_INVITES* ]] && ok "resends count against the business's cap" || bad "resend cap: $r"
apply "$REPO/sql/rollback/zella_invitation_limits_rollback.sql" > /dev/null && apply "$REPO/sql/rollback/zella_invitation_limits_rollback.sql" > /dev/null && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "$before" ] && ok "rollback restores both functions exactly" || bad "after rollback"
apply "$REPO/sql/zella_invitation_limits.sql" > /dev/null
q "create or replace function public.zella_resend_invitation(p_invitation_id uuid) returns void language sql as \$f\$ select \$f\$" > /dev/null
out=$(apply "$REPO/sql/rollback/zella_invitation_limits_rollback.sql"); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "the rollback refuses a changed function" || bad "rollback drift: $out"
q "delete from public.zella_function_archive where migration = 'zella_invitation_limits'" > /dev/null
out=$(apply "$REPO/sql/zella_invitation_limits.sql"); [[ "$out" == *VERSION_MISMATCH* ]] && ok "an unknown version stops the file" || bad "drift: $out"
finish
