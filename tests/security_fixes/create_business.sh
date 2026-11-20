#!/usr/bin/env bash
# M6: sql/zella_create_business_revoke.sql. Checks: before, a signed in person can create a business; after, they
# can't (and anon can't), the server key still can, the body is unchanged, applies twice, rollback twice restores
# the grants exactly, a different version stops the file, and a missing function is a no op.
. "$(dirname "$0")/lib.sh"; fresh_db create_business
S='public.create_business(text,uuid,text,text,text,text,text,text)'
acl() { q "select string_agg(a::text, ',' order by a::text) from pg_proc, unnest(proacl) a where oid = '$S'::regprocedure"; }
fp() { q "select md5(pg_get_functiondef('$S'::regprocedure))"; }
before_acl=$(acl); before_fp=$(fp)
U=f3000000-0000-0000-0000-000000000001
q "insert into auth.users (id, email, email_confirmed_at) values ('$U', 'cb1@cb.test', now())" > /dev/null
IND=$(q "select id from public.industries order by name limit 1")
call="raise notice 'R=%', public.create_business('Test Biz', '$IND'::uuid, p_portal_id => 'cbtest1');"
r=$(as_user $U aal1 "$call"); [[ "$r" != ERR:* ]] && ok "before: a signed in person creates a business (the gap)" || bad "before: $r"

out=$(apply "$REPO/sql/zella_create_business_revoke.sql") && ok "applies" || { bad "applies: $out"; finish; }
out=$(apply "$REPO/sql/zella_create_business_revoke.sql") && ok "applies again" || bad "second apply: $out"
r=$(as_user $U aal1 "$call"); [[ "$r" == *"permission denied"* ]] && ok "after: a signed in person is refused ($r)" || bad "after: $r"
r=$(q "do \$\$ begin set local role anon; begin perform public.create_business('X', '$IND'::uuid); raise notice 'R=ran'; exception when others then raise notice 'R=%', sqlerrm; end; reset role; end \$\$" 2>&1 | sed -n 's/.*R=//p')
[[ "$r" == *"permission denied"* ]] && ok "anon is refused" || bad "anon: $r"
r=$(q "select has_function_privilege('service_role', '$S', 'execute')"); [ "$r" = t ] && ok "service_role keeps execute" || bad "service_role: $r"
[ "$(fp)" = "$before_fp" ] && ok "function body unchanged" || bad "body changed"

apply "$REPO/sql/rollback/zella_create_business_revoke_rollback.sql" > /dev/null && apply "$REPO/sql/rollback/zella_create_business_revoke_rollback.sql" > /dev/null && ok "rollback runs twice" || bad "rollback"
[ "$(acl)" = "$before_acl" ] && ok "rollback restores the grants exactly ($before_acl)" || bad "grants after rollback: $(acl)"

q "create or replace function public.create_business(p_name text, p_industry_id uuid, p_business_type text DEFAULT NULL, p_email text DEFAULT NULL, p_phone text DEFAULT NULL, p_website text DEFAULT NULL, p_timezone text DEFAULT 'America/New_York', p_portal_id text DEFAULT NULL) returns uuid language sql as \$f\$ select null::uuid \$f\$" > /dev/null
out=$(apply "$REPO/sql/zella_create_business_revoke.sql"); [[ "$out" == *VERSION_MISMATCH* ]] && ok "an unknown version stops the file" || bad "drift not caught: $out"
out=$(apply "$REPO/sql/rollback/zella_create_business_revoke_rollback.sql"); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "and the rollback doesn't grant a changed function" || bad "rollback drift: $out"
q "drop function $S" > /dev/null
out=$(apply "$REPO/sql/zella_create_business_revoke.sql") && ok "a missing function is a no op" || bad "missing: $out"
finish
