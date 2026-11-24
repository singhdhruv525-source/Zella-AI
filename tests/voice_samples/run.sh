#!/usr/bin/env bash
# sql/zella_voice_samples.sql on an isolated copy of production's schema (never production): a fresh zvc_samples from
# the template zcar_main (tests/cartesia_voices/lib.sh builds it; it is not rebuilt here). Checks: a different bucket or
# a policy naming it stops the file and changes nothing; it applies, and applies again; the bucket is private (signed
# in and anonymous people can neither see nor add files, only the server can); the rollback refuses while samples are
# stored or the bucket changed, is exact, and is safe twice; applying again after the rollback works.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}
TEMPLATE=${TEMPLATE:-zcar_main}; DB=zvc_samples
. "$REPO/tests/lib/isolated_guard.sh"
zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$TEMPLATE" || exit 1
zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
"${P[@]}" -d postgres -c "set client_min_messages = warning" -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
q() { "${P[@]}" -d "$DB" -c "$1"; }
apply() { "${P[@]}" -d "$DB" -f "$1" 2>&1; }
MIG="$REPO/sql/zella_voice_samples.sql"; RB="$REPO/sql/rollback/zella_voice_samples_rollback.sql"
U=ac000000-0000-0000-0000-000000000001
as_role() {   # as_role <role> <sql>: runs <sql> as that role with a signed in person's claims, prints the result or ERR
  q "do \$\$ declare r text; begin perform set_config('request.jwt.claims', json_build_object('sub', '$U', 'role', '$1', 'aal', 'aal2')::text, true);
    execute 'set local role $1'; begin execute \$s\$ $2 \$s\$ into r; exception when others then r := 'ERR:' || sqlerrm; end; reset role; raise notice 'R=%', r; end \$\$" 2>&1 | sed -n 's/.*R=//p' | head -1
}
fp() {
  q "select md5(coalesce(string_agg(x, '|' order by x collate \"C\"), '')) from (
       select 'b:' || id || ':' || coalesce(name, '') || ':' || public || ':' || coalesce(file_size_limit::text, '') || ':' || coalesce(allowed_mime_types::text, '') x from storage.buckets
       union all select 'p:' || polname || ':' || coalesce(pg_get_expr(polqual, polrelid), '') || ':' || coalesce(pg_get_expr(polwithcheck, polrelid), '') from pg_policy where polrelid = 'storage.objects'::regclass
       union all select 'o:' || bucket_id || '/' || name from storage.objects) t"
}

[ -n "$(q "select to_regclass('storage.buckets')")" ] && ok "the isolated copy has storage.buckets" || { bad "no storage schema"; exit 1; }
BEFORE=$(fp)

q "insert into storage.buckets (id, name, public) values ('voice-samples', 'voice-samples', true)" > /dev/null
DRIFT=$(fp); out=$(apply "$MIG")
[[ "$out" == *VERSION_MISMATCH*different\ voice-samples* ]] && [ "$(fp)" = "$DRIFT" ] && ok "a public voice-samples bucket stops the file, nothing changes" || bad "bucket drift: $out"
q "delete from storage.buckets where id = 'voice-samples'" > /dev/null
q "create policy voice_peek on storage.objects for select to authenticated using (bucket_id = 'voice-samples')" > /dev/null
DRIFT=$(fp); out=$(apply "$MIG")
[[ "$out" == *VERSION_MISMATCH*policy* ]] && [ "$(fp)" = "$DRIFT" ] && ok "a policy naming the bucket stops the file, nothing changes" || bad "policy drift: $out"
q "drop policy voice_peek on storage.objects" > /dev/null
[ "$(fp)" = "$BEFORE" ] && ok "back to the starting state" || bad "restore"

out=$(apply "$MIG") && ok "applies" || bad "applies: $out"
AFTER=$(fp)
out=$(apply "$MIG") && [ "$(fp)" = "$AFTER" ] && ok "applies again, no change" || bad "twice: $out"
[ "$(q "select name || '|' || public || '|' || file_size_limit || '|' || allowed_mime_types::text from storage.buckets where id = 'voice-samples'")" = "voice-samples|false|1048576|{audio/mpeg}" ] \
  && ok "private, 1 MB, MP3 only" || bad "bucket row"

# a stored sample, as the server writes it
q "insert into storage.objects (bucket_id, name) values ('voice-samples', 'cartesia/f786b574-daa5-4673-aa0c-cbe3e8534c02-0a1b2c3d.mp3')" > /dev/null
[ "$(as_role authenticated "select count(*)::text from storage.objects where bucket_id = 'voice-samples'")" = "0" ] && ok "a signed in person can't see samples" || bad "authenticated sees"
r=$(as_role anon "select count(*)::text from storage.objects where bucket_id = 'voice-samples'")
[[ "$r" = 0 || "$r" == ERR:permission\ denied* ]] && ok "an anonymous visitor can't see samples ($r)" || bad "anon sees: $r"
r=$(as_role authenticated "insert into storage.objects (bucket_id, name) values ('voice-samples', 'cartesia/x.mp3') returning name")
[[ "$r" == ERR:* ]] && ok "a signed in person can't add a sample ($r)" || bad "authenticated insert: $r"
r=$(as_role anon "insert into storage.objects (bucket_id, name) values ('voice-samples', '11labs/x.mp3') returning name")
[[ "$r" == ERR:* ]] && ok "an anonymous visitor can't add a sample" || bad "anon insert: $r"
r=$(as_role authenticated "update storage.buckets set public = true where id = 'voice-samples' returning id")
[ "$(q "select public from storage.buckets where id = 'voice-samples'")" = "f" ] && ok "a signed in person can't make the bucket public ($r)" || bad "bucket made public"

out=$(apply "$RB"); [[ "$out" == *SAMPLES_EXIST* ]] && [ "$(q "select count(*) from storage.buckets where id = 'voice-samples'")" = 1 ] && ok "rollback refuses while samples are stored" || bad "rollback with samples: $out"
q "delete from storage.objects where bucket_id = 'voice-samples'" > /dev/null
q "update storage.buckets set public = true where id = 'voice-samples'" > /dev/null
out=$(apply "$RB"); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "rollback refuses a changed bucket" || bad "rollback drift: $out"
q "update storage.buckets set public = false where id = 'voice-samples'" > /dev/null
out=$(apply "$RB") && [ "$(fp)" = "$BEFORE" ] && ok "rollback is exact" || bad "rollback: $out"
out=$(apply "$RB") && [ "$(fp)" = "$BEFORE" ] && ok "rollback twice is safe" || bad "rollback twice: $out"
out=$(apply "$MIG") && [ "$(fp)" = "$AFTER" ] && ok "applies again after the rollback" || bad "reapply: $out"

echo "md5 $(md5sum "$MIG" | cut -c1-32) sql/zella_voice_samples.sql"
echo "md5 $(md5sum "$RB" | cut -c1-32) sql/rollback/zella_voice_samples_rollback.sql"
[ -n "${KEEP:-}" ] || "${P[@]}" -d postgres -c "drop database if exists $DB" > /dev/null
echo; [ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
