#!/usr/bin/env bash
# sql/zella_draft_delete.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Checks: before, deleting a draft with a receptionist fails (the privileged audit trigger points at the business being
# deleted) and deleting one without erases its audit rows (cascade); a foreign key that isn't exactly CASCADE stops the
# file; applies, and applies again; the audit foreign key is SET NULL (the owner's ACC-10 decision); a Zella Voice
# owner deletes an eligible draft: its modules, receptionist and pending owner invitation go, its earlier audit rows
# stay with business_id empty, the deletion entry survives with business_id empty and keeps the business id, name,
# industry, the earlier row ids and the reason, and
# the business-documents paths come back for the server to remove; a super admin may delete too; a read only admin, an
# unknown person, a wrong name and a missing reason are refused; drafts that are live, active, in testing, cancelled,
# with an accepted owner, an active member, calls, phone numbers, subscriptions, payments or assistant deliveries are
# refused and untouched; only the server may call it; the rollback (twice) restores the trigger function and the
# cascade exactly; applies again; a changed function stops the file (VERSION_MISMATCH) and the rollback (ROLLBACK_DRIFT).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zlb_draft_delete}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
MIG="$REPO/sql/zella_draft_delete.sql"; RB="$REPO/sql/rollback/zella_draft_delete_rollback.sql"
fp() { q "select md5(pg_get_functiondef('public.zella_audit_privileged()'::regprocedure)) || (select confdeltype::text from pg_constraint where conname = 'audit_logs_business_id_fkey')"; }
before=$(fp)
OWN=f1000000-0000-0000-0000-000000000001; SUP=f1000000-0000-0000-0000-000000000002; RO=f1000000-0000-0000-0000-000000000003; MEM=f1000000-0000-0000-0000-000000000004
q "insert into auth.users (id, email) values ('$OWN', 'owner@zella.test'), ('$SUP', 'super@zella.test'), ('$RO', 'readonly@zella.test'), ('$MEM', 'member@glow.test');
   insert into public.platform_admins (user_id, role, is_active) values ('$OWN', 'zella_owner', true), ('$SUP', 'super_admin', true), ('$RO', 'read_only_admin', true)" > /dev/null || exit 1
IND=$(q "select id from public.industries where is_active order by name limit 1")
draft() { # name -> id of a draft made the real way, with a pending owner invitation, a document and an audit row
  local b; b=$(q "select public.zella_create_business_draft('{\"name\": \"$1\", \"industry_id\": \"$IND\"}'::jsonb) ->> 'business_id'")
  q "insert into public.business_invitations (business_id, email, owner_name, invited_by, status, role) values ('$b', lower(replace('$1', ' ', '')) || '@owner.test', 'Pat', '$OWN', 'pending', 'owner');
     insert into public.business_verification_documents (business_id, kind, file_path, file_name, mime_type, size_bytes, status, uploaded_by)
       values ('$b', 'business_registration', '$b/business_registration/a.pdf', 'a.pdf', 'application/pdf', 10, 'pending_review', '$OWN');
     insert into storage.objects (bucket_id, name) values ('business-documents', '$b/business_registration/a.pdf'), ('business-documents', '$b/other/orphan.png');
     insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id) values ('$b', '$OWN', 'business.draft_created', 'business', '$b')" > /dev/null || exit 1
  echo "$b"
}
q "insert into storage.buckets (id, name) values ('business-documents', 'business-documents') on conflict do nothing" > /dev/null 2>&1
del() { q "select public.zella_delete_draft_business('$1', '$2', '$3', '$4')" 2>&1; }

# before
B0=$(draft "Before Dental")
out=$(q "delete from public.businesses where id = '$B0'" 2>&1)
[[ "$out" == *audit_logs_business_id_fkey* ]] && ok "before: a draft with a receptionist can't be deleted at all (the bug)" || bad "before: $out"
B00=$(q "insert into public.businesses (name, industry_id) values ('Bare Draft', '$IND') returning id" | head -1)
q "insert into public.audit_logs (business_id, action, entity_type) values ('$B00', 'business.updated', 'business')" > /dev/null
q "delete from public.businesses where id = '$B00'" > /dev/null 2>&1
[ "$(q "select count(*) from public.audit_logs where action = 'business.updated' and entity_type = 'business' and business_id is null")" = "0" ] && ok "before: a delete erases the business's audit rows (cascade)" || bad "before cascade"

q "alter table public.audit_logs drop constraint audit_logs_business_id_fkey; alter table public.audit_logs add constraint audit_logs_business_id_fkey foreign key (business_id) references public.businesses(id) on delete restrict" > /dev/null
out=$("${P[@]}" -d $DB -f "$MIG" 2>&1); [[ "$out" == *VERSION_MISMATCH*audit_logs_business_id_fkey* ]] && [ "$(q "select count(*) from public.zella_function_archive where migration = 'zella_draft_delete'")" = "0" ] && ok "a foreign key that isn't exactly CASCADE stops the file, changing nothing" || bad "fk guard: $out"
q "alter table public.audit_logs drop constraint audit_logs_business_id_fkey; alter table public.audit_logs add constraint audit_logs_business_id_fkey foreign key (business_id) references public.businesses(id) on delete cascade" > /dev/null
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$MIG" 2>&1 | grep -v NOTICE | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"

B1=$(draft "Glow Draft Studio")
early=$(q "select count(*) from public.audit_logs where business_id = '$B1'")
for args in "$RO|Glow Draft Studio|test cleanup" "$MEM|Glow Draft Studio|test cleanup" "$OWN|Glow Studio|test cleanup" "$OWN|Glow Draft Studio| "; do
  IFS='|' read -r who name why <<< "$args"; out=$(del "$B1" "$who" "$name" "$why")
  [[ "$out" == *NOT_ALLOWED* || "$out" == *NAME_MISMATCH* || "$out" == *REASON_REQUIRED* ]] || bad "refusal expected for $args: $out"
done
[ "$(q "select count(*) from public.businesses where id = '$B1'")" = "1" ] && ok "a read only admin, an unknown person, a wrong name and a missing reason are refused" || bad "refusals deleted it"
r=$(del "$B1" "$OWN" "  glow draft studio " "Duplicate made by mistake")
paths=$(q "select string_agg(p, ',' order by p) from jsonb_array_elements_text('$r'::jsonb -> 'paths') p")
[ "$paths" = "$B1/business_registration/a.pdf,$B1/other/orphan.png" ] && ok "a Zella Voice owner deletes it (name in any case) and gets the document paths, orphans too" || bad "delete: $r"
s=$(q "select (select count(*) from public.businesses where id = '$B1') || ',' || (select count(*) from public.ai_agents where business_id = '$B1') || ',' || (select count(*) from public.business_modules where business_id = '$B1') || ',' || (select count(*) from public.business_invitations where business_id = '$B1')")
[ "$s" = "0,0,0,0" ] && ok "the business, receptionist, modules and pending owner invitation are gone" || bad "left over: $s"
[ "$(q "select confdeltype::text from pg_constraint where conname = 'audit_logs_business_id_fkey'")" = "n" ] && ok "the audit foreign key is SET NULL (ACC-10, the owner's decision)" || bad "fk not set null"
[ "$(q "select count(*) from public.audit_logs where action = 'business.draft_created' and entity_id = '$B1' and business_id is null")" = "1" ] && ok "its earlier audit rows survive, with business_id empty" || bad "earlier rows"
e=$(q "select (business_id is null) || '|' || (old_data ->> 'business_id') || '|' || (old_data ->> 'name') || '|' || (old_data ->> 'industry' is not null) || '|' || jsonb_array_length(old_data -> 'earlier_audit_ids') || '|' || (new_data ->> 'reason') || '|' || user_id from public.audit_logs where action = 'business.draft_deleted' and entity_id = '$B1'")
[ "$e" = "true|$B1|Glow Draft Studio|true|$early|Duplicate made by mistake|$OWN" ] && ok "the deletion row survives with business_id empty and keeps the id, name, industry, earlier row ids and reason" || bad "entry: $e"
pd=$(q "select count(*) from public.audit_logs where action = 'privileged_delete' and business_id is null and new_data ->> 'deleted_business_id' = '$B1'")
[ "$pd" -ge 2 ] && ok "the cascade's own privileged audit rows are kept, pointing at the deleted id in new_data" || bad "privileged rows: $pd"
B2=$(draft "Super Draft"); r=$(del "$B2" "$SUP" "Super Draft" "Test record")
[[ "$r" == *paths* ]] && ok "a super admin may delete a draft too" || bad "super admin: $r"

# not drafts
mk() { local b; b=$(draft "$1"); q "$2" | sed "s/X/$b/g" > /dev/null; echo "$b"; }
check_refused() { # name, setup sql with BIZ placeholder, expected blocker
  local b; b=$(draft "$1"); q "$(echo "$2" | sed "s/BIZ/$b/g")" > /dev/null || { bad "setup $1"; return; }
  local out; out=$(del "$b" "$OWN" "$1" "Clean up test")
  [[ "$out" == *NOT_A_DRAFT*"$3"* ]] && [ "$(q "select count(*) from public.businesses where id = '$b'")" = "1" ] && ok "refused and untouched: $1 ($3)" || bad "$1: $out"
}
check_refused "Live One" "update public.businesses set onboarding_status = 'active', is_active = true where id = 'BIZ'" setup_finished
check_refused "Testing One" "update public.businesses set onboarding_status = 'testing' where id = 'BIZ'" setup_finished
check_refused "Active One" "update public.businesses set is_active = true where id = 'BIZ'" active
check_refused "Cancelled One" "update public.businesses set cancelled_at = now() where id = 'BIZ'" cancelled
check_refused "Accepted One" "update public.business_invitations set status = 'accepted' where business_id = 'BIZ'" owner_accepted
check_refused "Member One" "insert into public.business_members (business_id, user_id, role, status) values ('BIZ', '$MEM', 'staff', 'active')" members
check_refused "Calls One" "insert into public.calls (business_id, direction) values ('BIZ', 'inbound')" calls
check_refused "Number One" "insert into public.business_phone_numbers (business_id, e164) values ('BIZ', '+15550000' || floor(random() * 900 + 100)::int)" phone_numbers
check_refused "Subscribed One" "insert into public.subscriptions (business_id, status) values ('BIZ', 'trial')" subscriptions
check_refused "Paid One" "insert into public.payments (business_id, amount) values ('BIZ', 10)" payments
check_refused "Delivered One" "insert into public.assistant_deliveries (business_id, outcome) values ('BIZ', 'served')" assistant_deliveries
out=$(del "f9999999-0000-0000-0000-000000000000" "$OWN" "x" "Clean up test"); [[ "$out" == *NOT_FOUND* ]] && ok "an unknown business is not found" || bad "unknown: $out"
g=$(q "select has_function_privilege('authenticated', 'public.zella_delete_draft_business(uuid,uuid,text,text)', 'execute')::text || has_function_privilege('anon', 'public.zella_delete_draft_business(uuid,uuid,text,text)', 'execute')::text")
[ "$g" = "falsefalse" ] && ok "only the server may call it" || bad "grants: $g"

"${P[@]}" -d $DB -f "$RB" > /dev/null 2>&1 && "${P[@]}" -d $DB -f "$RB" > /dev/null 2>&1 && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "$before" ] && [ -z "$(q "select to_regprocedure('public.zella_delete_draft_business(uuid,uuid,text,text)')")" ] && ok "rollback restores the trigger function and the CASCADE exactly, and drops the delete" || bad "after rollback: $(fp)"
[ "$(q "select count(*) from public.audit_logs where action = 'business.draft_deleted'")" = "2" ] && [ "$(q "select count(*) from public.audit_logs where action = 'business.draft_created' and business_id is null")" -ge 1 ] && ok "deletion entries and the deleted drafts' earlier rows stay after the rollback" || bad "entries after rollback"
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_delete_draft_business(p_business_id uuid, p_actor uuid, p_confirm_name text, p_reason text) returns jsonb language sql as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$MIG" 2>&1); [[ "$out" == *VERSION_MISMATCH* ]] && ok "a changed function stops the file" || bad "drift not caught: $out"
out=$("${P[@]}" -d $DB -f "$RB" 2>&1); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "and stops the rollback" || bad "rollback drift not caught: $out"

echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
