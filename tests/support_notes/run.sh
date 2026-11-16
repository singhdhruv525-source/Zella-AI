#!/usr/bin/env bash
# sql/zella_support_notes.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Checks: before, a business member can read the admins' internal notes through the API; applies, and applies again;
# existing notes move to the server only table and leave metadata (other keys kept); members can't read the notes or
# the table; notes written into metadata later (an older admin function, a new ticket) are moved too; the rollback
# (run twice) puts every note back in order and removes the table; it applies again; a different table stops the file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=zsupportnotes; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
MEMBER=f3000000-0000-0000-0000-000000000001; ADMIN=f3000000-0000-0000-0000-000000000002
q "insert into auth.users (id, email, email_confirmed_at) values ('$MEMBER', 'member@notes.test', now()), ('$ADMIN', 'admin@notes.test', now())" > /dev/null || exit 1
BIZ=$(q "insert into public.businesses (name, industry_id) select 'Notes Test', id from public.industries limit 1 returning id" | head -1)
q "insert into public.business_members (business_id, user_id, role, status) values ('$BIZ', '$MEMBER', 'staff', 'active')" > /dev/null || exit 1
T=$(q "insert into public.support_tickets (business_id, subject, metadata) values ('$BIZ', 'Calls drop',
     jsonb_build_object('source', 'app', 'notes', jsonb_build_array(
       jsonb_build_object('text', 'Owner sounded upset; check carrier', 'author_id', '$ADMIN', 'created_at', '2026-11-10T10:00:00Z'),
       jsonb_build_object('text', 'Second note', 'author_id', '$ADMIN', 'created_at', '2026-11-11T10:00:00Z')))) returning id" | head -1)
# what a signed in business member sees through the API
as_member() { q "do \$\$ declare v text; begin perform set_config('request.jwt.claims', json_build_object('sub', '$MEMBER', 'role', 'authenticated', 'aal', 'aal1')::text, true);
  set local role authenticated; begin execute \$q\$$1\$q\$ into v; exception when others then v := 'ERR:' || sqlerrm; end; reset role; raise notice 'V=%', v; end \$\$" 2>&1 | sed -n 's/.*V=//p'; }

v=$(as_member "select metadata::text from public.support_tickets where id = '$T'")
[[ "$v" == *"Owner sounded upset"* ]] && ok "before: a business member can read the admins' internal notes (the bug)" || bad "before: $v"

"${P[@]}" -d $DB -f "$REPO/sql/zella_support_notes.sql" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$REPO/sql/zella_support_notes.sql" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$REPO/sql/zella_support_notes.sql" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"
n=$(q "select string_agg(body, '|' order by created_at) from public.support_ticket_notes where ticket_id = '$T'")
[ "$n" = "Owner sounded upset; check carrier|Second note" ] && ok "existing notes moved to the server only table, in order, once" || bad "moved: $n"
m=$(q "select metadata::text from public.support_tickets where id = '$T'")
[ "$m" = '{"source": "app"}' ] && ok "and removed from metadata, other keys kept" || bad "metadata: $m"
v=$(as_member "select metadata::text from public.support_tickets where id = '$T'")
[[ "$v" != *"upset"* && "$v" != ERR* ]] && ok "a member can still read the ticket, but no notes ($v)" || bad "member sees: $v"
v=$(as_member "select count(*)::text from public.support_ticket_notes")
[[ "$v" == ERR* ]] && ok "a member can't read the notes table at all ($v)" || bad "member read notes table: $v"

# an older admin function still writing notes into metadata, and a new ticket created with notes
q "update public.support_tickets set metadata = metadata || jsonb_build_object('notes', jsonb_build_array(jsonb_build_object('text', 'Late note', 'author_id', '$ADMIN', 'created_at', '2026-11-12T10:00:00Z'))) where id = '$T'" > /dev/null
T2=$(q "insert into public.support_tickets (business_id, subject, metadata) values ('$BIZ', 'Second', '{\"notes\": [{\"text\": \"Note on a new ticket\"}]}') returning id" | head -1)
c=$(q "select (select count(*) from public.support_tickets where metadata ? 'notes') || ':' || (select count(*) from public.support_ticket_notes)")
[ "$c" = "0:4" ] && ok "notes written into metadata later (old function, new ticket) are moved too" || bad "later notes: $c"

"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_support_notes_rollback.sql" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_support_notes_rollback.sql" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
r=$(q "select string_agg(n ->> 'text', '|' order by ord) from public.support_tickets t, jsonb_array_elements(t.metadata -> 'notes') with ordinality x(n, ord) where t.id = '$T'")
[ "$r" = "Owner sounded upset; check carrier|Second note|Late note" ] && ok "rollback puts every note back into metadata, oldest first" || bad "rollback notes: $r"
[ "$(q "select to_regclass('public.support_ticket_notes') is null and to_regprocedure('public.zella_take_ticket_notes(uuid,jsonb)') is null")" = "t" ] && ok "rollback removes the table and helpers" || bad "left behind"
"${P[@]}" -d $DB -f "$REPO/sql/zella_support_notes.sql" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
"${P[@]}" -d $DB -f "$REPO/sql/rollback/zella_support_notes_rollback.sql" > /dev/null 2>&1
q "create table public.support_ticket_notes (id uuid primary key, x text)" > /dev/null
out=$("${P[@]}" -d $DB -f "$REPO/sql/zella_support_notes.sql" 2>&1)
[[ "$out" == *"VERSION_MISMATCH"* ]] && ok "a different support_ticket_notes table stops the file" || bad "not caught: $out"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
