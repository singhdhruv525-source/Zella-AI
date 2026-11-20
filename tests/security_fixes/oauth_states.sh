#!/usr/bin/env bash
# M8: sql/zella_oauth_states.sql. Checks: a stored sign in is used up once, only by the same person, business and
# provider, only before it expires; expiry is clamped to 1..10 minutes; signed in people and anon can't call either
# function or read the table; applies twice; rollback twice removes everything; a different existing version stops it.
. "$(dirname "$0")/lib.sh"; fresh_db oauth_states
out=$(apply "$REPO/sql/zella_oauth_states.sql") && ok "applies" || { bad "applies: $out"; finish; }
out=$(apply "$REPO/sql/zella_oauth_states.sql") && ok "applies again" || bad "second apply: $out"
U=f6000000-0000-0000-0000-000000000001; O=f6000000-0000-0000-0000-000000000002
q "insert into auth.users (id, email, email_confirmed_at) values ('$U', 'o1@oauth.test', now()), ('$O', 'o2@oauth.test', now())" > /dev/null
BIZ=$(q "insert into public.businesses (name, industry_id) select 'OAuth Test', id from public.industries limit 1 returning id" | head -1)
H=$(printf 'a%.0s' {1..64}); H2=$(printf 'b%.0s' {1..64}); H3=$(printf 'c%.0s' {1..64})
q "select public.zella_oauth_state_issue('$H', '$U', '$BIZ', 'google', 300)" > /dev/null
c() { q "select public.zella_oauth_state_consume('$1', '$2', '$BIZ', '$3')"; }
[ "$(c $H $O google)" = f ] && ok "another person can't use it" || bad "other person"
[ "$(c $H $U outlook)" = f ] && ok "another provider can't use it" || bad "other provider"
[ "$(q "select public.zella_oauth_state_consume('$H', '$U', gen_random_uuid(), 'google')")" = f ] && ok "another business can't use it" || bad "other business"
[ "$(c $H $U google)" = t ] && ok "the person who started it uses it once" || bad "first use"
[ "$(c $H $U google)" = f ] && ok "and never again" || bad "second use"
# two finishes at the same moment: exactly one uses it
H4=$(printf 'd%.0s' {1..64}); q "select public.zella_oauth_state_issue('$H4', '$U', '$BIZ', 'google', 300)" > /dev/null
race=$(for n in 1 2 3 4; do c $H4 $U google & done; wait)
[ "$(grep -c '^t$' <<< "$race")" = 1 ] && ok "four finishes at the same moment: exactly one uses it" || bad "race: $race"
q "select public.zella_oauth_state_issue('$H2', '$U', '$BIZ', 'google', 300)" > /dev/null
q "update public.oauth_states set expires_at = now() - interval '1 second' where nonce_hash = '$H2'" > /dev/null
[ "$(c $H2 $U google)" = f ] && ok "an expired one can't be used" || bad "expired"
q "select public.zella_oauth_state_issue('$H3', '$U', '$BIZ', 'outlook', 99999)" > /dev/null
[ "$(q "select extract(epoch from expires_at - created_at)::int <= 600 from public.oauth_states where nonce_hash = '$H3'")" = t ] && ok "a longer expiry is cut to 10 minutes" || bad "clamp"
r=$(q "select public.zella_oauth_state_issue('short', '$U', '$BIZ', 'google', 300)" 2>&1); [[ "$r" == *BAD_REQUEST* ]] && ok "a malformed hash is refused" || bad "bad hash: $r"
r=$(as_user $U aal1 "perform public.zella_oauth_state_consume('$H3', '$U', '$BIZ', 'outlook'); raise notice 'R=ran';"); [[ "$r" == *"permission denied"* ]] && ok "signed in people can't call it" || bad "authenticated: $r"
r=$(as_user $U aal1 "perform count(*) from public.oauth_states; raise notice 'R=ran';"); [[ "$r" == *"permission denied"* ]] && ok "or read the table" || bad "table: $r"
apply "$REPO/sql/rollback/zella_oauth_states_rollback.sql" > /dev/null && apply "$REPO/sql/rollback/zella_oauth_states_rollback.sql" > /dev/null && ok "rollback runs twice" || bad "rollback"
[ -z "$(q "select to_regclass('public.oauth_states')")" ] && [ -z "$(q "select to_regprocedure('public.zella_oauth_state_issue(text,uuid,uuid,text,integer)')")" ] && ok "rollback removes the table and functions" || bad "left behind"
q "create function public.zella_oauth_state_consume(text, uuid, uuid, text) returns boolean language sql as \$f\$ select true \$f\$" > /dev/null
out=$(apply "$REPO/sql/zella_oauth_states.sql"); [[ "$out" == *VERSION_MISMATCH* ]] && ok "a different existing version stops the file" || bad "drift: $out"
finish
