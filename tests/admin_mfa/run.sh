#!/usr/bin/env bash
# sql/zella_admin_mfa.sql on an ISOLATED copy of the production schema (never production). Test people only.
# Checks: applies, and applies again; an active admin needs a session verified with a code whether or not they set one
# up (the request check refuses them, the table policy hides rows); a deactivated admin, a business member without an
# authenticator, server code and anonymous requests are unchanged; a member with an authenticator still needs the
# code; grants are kept; the rollback (run twice) restores the function exactly; a different version stops the file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zadminmfa; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
fp() { q "select md5(pg_get_functiondef('public.zella_mfa_satisfied()'::regprocedure))"; }
grants() { q "select string_agg(grantee || ':' || privilege_type, ',' order by grantee) from information_schema.routine_privileges where routine_schema = 'public' and routine_name = 'zella_mfa_satisfied'"; }
before=$(fp); before_grants=$(grants)

# 1 admin, no authenticator · 2 admin with one · 3 deactivated admin, none · 4 member, none · 5 member with one
q "insert into auth.users (id, email, email_confirmed_at) select ('f2000000-0000-0000-0000-00000000000' || n)::uuid, 'mfa' || n || '@mfa.test', now() from generate_series(1, 5) n" > /dev/null || exit 1
q "insert into public.platform_admins (user_id, role, is_active) values ('f2000000-0000-0000-0000-000000000001', 'zella_owner', true), ('f2000000-0000-0000-0000-000000000002', 'support_admin', true), ('f2000000-0000-0000-0000-000000000003', 'zella_owner', false)" > /dev/null || exit 1
q "insert into auth.mfa_factors (id, user_id, factor_type, status) values (gen_random_uuid(), 'f2000000-0000-0000-0000-000000000002', 'totp', 'verified'), (gen_random_uuid(), 'f2000000-0000-0000-0000-000000000005', 'totp', 'verified')" > /dev/null || exit 1

# zella_mfa_satisfied() for each person at aal1 and aal2, as the signed in role
matrix() {
  q "do \$\$ declare r text := ''; v boolean; n int; a text; begin
    for n in 1..5 loop foreach a in array array['aal1','aal2'] loop
      perform set_config('request.jwt.claims', json_build_object('sub', 'f2000000-0000-0000-0000-00000000000' || n, 'role', 'authenticated', 'aal', a)::text, true);
      set local role authenticated; select public.zella_mfa_satisfied() into v; reset role;
      r := r || n || a || '=' || case when v then 'y' else 'n' end || ' ';
    end loop; end loop;
    raise notice 'M=%', trim(r); end \$\$" 2>&1 | sed -n 's/.*M=//p'
}
m=$(matrix)
[ "$m" = "1aal1=y 1aal2=y 2aal1=n 2aal2=y 3aal1=y 3aal2=y 4aal1=y 4aal2=y 5aal1=n 5aal2=y" ] && ok "before: an admin without an authenticator passes with a password only (the gap)" || bad "before: $m"

"${P[@]}" -d $DB -f "$REPO/sql/zella_admin_mfa.sql" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$REPO/sql/zella_admin_mfa.sql" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$REPO/sql/zella_admin_mfa.sql" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"
m=$(matrix)
[ "$m" = "1aal1=n 1aal2=y 2aal1=n 2aal2=y 3aal1=y 3aal2=y 4aal1=y 4aal2=y 5aal1=n 5aal2=y" ] && ok "after: every active admin needs a code; a deactivated admin and members are unchanged ($m)" || bad "after: $m"
[ "$(grants)" = "$before_grants" ] && ok "grants are unchanged" || bad "grants changed: $(grants)"
s=$(q "select public.zella_mfa_satisfied()")
[ "$s" = "t" ] && ok "server code (no signed in person) is unchanged" || bad "server code: $s"

# the request check refuses the admin with only a password, and the table policy hides rows from them
r=$(q "do \$\$ begin perform set_config('request.jwt.claims', '{\"sub\":\"f2000000-0000-0000-0000-000000000001\",\"role\":\"authenticated\",\"aal\":\"aal1\"}', true);
  set local role authenticated; begin perform public.zella_pre_request(); raise notice 'R=passed'; exception when others then raise notice 'R=%', sqlerrm; end; reset role; end \$\$" 2>&1 | sed -n 's/.*R=//p')
[ "$r" = "MFA_REQUIRED" ] && ok "the request check refuses an admin with only a password (MFA_REQUIRED)" || bad "pre_request: $r"
n=$(q "do \$\$ declare n int; begin perform set_config('request.jwt.claims', '{\"sub\":\"f2000000-0000-0000-0000-000000000001\",\"role\":\"authenticated\",\"aal\":\"aal1\"}', true);
  set local role authenticated; select count(*) into n from public.industries; reset role; raise notice 'N=%', n; end \$\$" 2>&1 | sed -n 's/.*N=//p')
[ "$n" = "0" ] && ok "and tables show them nothing until they verify a code" || bad "rows visible: $n"
n=$(q "do \$\$ declare n int; begin perform set_config('request.jwt.claims', '{\"sub\":\"f2000000-0000-0000-0000-000000000001\",\"role\":\"authenticated\",\"aal\":\"aal2\"}', true);
  set local role authenticated; select count(*) into n from public.industries; reset role; raise notice 'N=%', n; end \$\$" 2>&1 | sed -n 's/.*N=//p')
[ "${n:-0}" -gt 0 ] && ok "with a verified code they see the data again ($n industries)" || bad "aal2 sees $n"

"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_admin_mfa_rollback.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_admin_mfa_rollback.sql" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "$before" ] && ok "rollback restores the function exactly" || bad "fingerprint after rollback"
[ "$(q "select count(*) from public.zella_function_archive where migration = 'zella_admin_mfa'")" = "0" ] && ok "rollback leaves no archive rows" || bad "archive rows left"
"${P[@]}" -d $DB -f "$REPO/sql/zella_admin_mfa.sql" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_admin_mfa_rollback.sql" > /dev/null 2>&1
q "create or replace function public.zella_mfa_satisfied() returns boolean language sql stable security definer set search_path = '' as \$f\$ select true \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_admin_mfa.sql" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"* ]] && ok "an unknown version stops the file (VERSION_MISMATCH)" || bad "drift not caught: $out"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
