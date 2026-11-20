#!/usr/bin/env bash
# M9 (database part): sql/zella_website_fetch_guard.sql. Checks: before, a nip.io address passes the add time check
# (the gap); after, wildcard DNS names are refused and ordinary sites still pass; applies twice; rollback twice
# restores the function exactly; drift stops the file and the rollback.
. "$(dirname "$0")/lib.sh"; fresh_db website_fetch_guard
S='public.zella_website_url_ok(text)'; fp() { q "select md5(pg_get_functiondef('$S'::regprocedure))"; }; before=$(fp)
okurl() { q "select public.zella_website_url_ok('$1')"; }
[ "$(okurl 'https://127.0.0.1.nip.io/')" = t ] && ok "before: a nip.io name passes (the gap)" || bad "before"
out=$(apply "$REPO/sql/zella_website_fetch_guard.sql") && ok "applies" || { bad "applies: $out"; finish; }
out=$(apply "$REPO/sql/zella_website_fetch_guard.sql") && ok "applies again" || bad "second apply: $out"
[ "$(fp)" = 23c362d28709b0567a7427d2f253009e ] && ok "new fingerprint is the recorded one" || bad "fingerprint $(fp)"
for u in https://127.0.0.1.nip.io/ http://10-0-0-1.sslip.io/x https://app.localtest.me/ http://lvh.me/ https://a.b.xip.io/ https://x.traefik.me/; do
  [ "$(okurl "$u")" = f ] || bad "still accepted: $u"; done; ok "wildcard DNS names are refused"
for u in https://www.sunnysalon.com/ https://shop.example.co.uk/about http://nipio.com/ https://lvh.melbourne/; do
  [ "$(okurl "$u")" = t ] || bad "refused: $u"; done; ok "ordinary sites still pass (including look alike names)"
apply "$REPO/sql/rollback/zella_website_fetch_guard_rollback.sql" > /dev/null && apply "$REPO/sql/rollback/zella_website_fetch_guard_rollback.sql" > /dev/null && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "$before" ] && ok "rollback restores the function exactly" || bad "after rollback"
apply "$REPO/sql/zella_website_fetch_guard.sql" > /dev/null
q "create or replace function public.zella_website_url_ok(p_url text) returns boolean language sql immutable as \$f\$ select true \$f\$" > /dev/null
out=$(apply "$REPO/sql/rollback/zella_website_fetch_guard_rollback.sql"); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "the rollback refuses a changed function" || bad "rollback drift: $out"
q "delete from public.zella_function_archive where migration = 'zella_website_fetch_guard'" > /dev/null
out=$(apply "$REPO/sql/zella_website_fetch_guard.sql"); [[ "$out" == *VERSION_MISMATCH* ]] && ok "an unknown version stops the file" || bad "drift: $out"
finish
