#!/usr/bin/env bash
# sql/zella_document_requests.sql on an ISOLATED copy of the production schema (never production). Test data only.
# Checks: before, nothing makes Request documents one step (the gap); applies, and applies again; a request queues S4
# in the outbox and writes its audit row together; a second request inside the wait is refused (TOO_SOON) and queues
# nothing; two requests at once: the second waits for the first, then is refused; if the audit write fails, the email
# isn't queued and the next request isn't held back; no address means no email but the request is still recorded; a
# cancelled or unknown business is refused; only the server may call it; the rollback runs twice and keeps audit rows
# and emails; applies again; drift stops the file and the rollback.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zlb_document_requests}; TEMPLATE=${TEMPLATE:-zprod3}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)
"${P[@]}" -d postgres -c "drop database if exists $DB" -c "create database $DB template $TEMPLATE" > /dev/null || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
q() { "${P[@]}" -d $DB -c "$1"; }
MIG="$REPO/sql/zella_document_requests.sql"; RB="$REPO/sql/rollback/zella_document_requests_rollback.sql"
RBRUN=("$REPO/sql/rollback/run.sh" "$RB" -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -d $DB -q)
ADM=e7000000-0000-0000-0000-000000000001
q "insert into auth.users (id, email) values ('$ADM', 'support@zella.test')" > /dev/null || exit 1
B=$(q "insert into public.businesses (name) values ('Request Test Studio') returning id" | head -1)
C=$(q "insert into public.businesses (name, cancelled_at) values ('Closed Test Studio', now()) returning id" | head -1)
req() { q "select public.zella_request_documents('$1', '$ADM', array['owner_identity'], 24, '$2', 'Documents needed', '<p>Please upload</p>', 'Please upload')" 2>&1; }
emails() { q "select count(*) from public.platform_emails where business_id = '$B' and code = 'S4'"; }
audits() { q "select count(*) from public.audit_logs where business_id = '$B' and action = 'business.documents_requested'"; }

[ -z "$(q "select to_regprocedure('public.zella_request_documents(uuid,uuid,text[],integer,text,text,text,text)')")" ] && ok "before: nothing makes a request one step (the gap)" || bad "before"
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies" || { bad "applies"; "${P[@]}" -d $DB -f "$MIG" 2>&1 | tail -3; exit 1; }
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again (idempotent)" || bad "second apply"

# the audit write fails: nothing is queued, and the next request isn't held back
q "create function public.zq_fail_audit() returns trigger language plpgsql as \$f\$ begin if new.action = 'business.documents_requested' then raise exception 'audit down'; end if; return new; end \$f\$;
   create trigger zq_fail_audit before insert on public.audit_logs for each row execute function public.zq_fail_audit()" > /dev/null
out=$(req "$B" "owner@request.test")
[[ "$out" == *"audit down"* ]] && [ "$(emails)" = "0" ] && [ "$(audits)" = "0" ] && ok "if the audit write fails, the email isn't queued either" || bad "audit failure: $out / $(emails)"
q "drop trigger zq_fail_audit on public.audit_logs; drop function public.zq_fail_audit()" > /dev/null

r=$(req "$B" "Owner@Request.test")
[ "$(q "select '$r'::jsonb ->> 'email'")" = "queued" ] && [ "$(emails)" = "1" ] && [ "$(audits)" = "1" ] \
  && [ "$(q "select to_email from public.platform_emails where business_id = '$B' and code = 'S4'")" = "owner@request.test" ] && ok "a request queues S4 and writes its audit row together" || bad "request: $r"
out=$(req "$B" "owner@request.test"); [[ "$out" == *TOO_SOON* ]] && [ "$(emails)" = "1" ] && [ "$(audits)" = "1" ] && ok "a second request inside the wait is refused and queues nothing" || bad "too soon: $out"

# two at once: the first holds the business until it commits; the second waits, then sees it and is refused
q "update public.audit_logs set created_at = now() - interval '25 hours' where business_id = '$B' and action = 'business.documents_requested'" > /dev/null
PGAPPNAME=zlb_req1 "${P[@]}" -d $DB -c "begin; select public.zella_request_documents('$B', '$ADM', array['owner_identity'], 24, 'owner@request.test', 's', 'h', 't'); select pg_sleep(3); commit;" > /dev/null 2>&1 & bgp=$!
for i in $(seq 1 100); do [ "$(q "select count(*) from pg_stat_activity where application_name = 'zlb_req1' and wait_event = 'PgSleep'")" = "1" ] && break; sleep 0.1; done
out=$(req "$B" "owner@request.test"); wait $bgp
[[ "$out" == *TOO_SOON* ]] && [ "$(emails)" = "2" ] && [ "$(audits)" = "2" ] && ok "two requests at once: one email and one audit row" || bad "concurrent: $out / $(emails) / $(audits)"

q "update public.audit_logs set created_at = now() - interval '25 hours' where business_id = '$B' and action = 'business.documents_requested'" > /dev/null
r=$(req "$B" ""); [ "$(q "select '$r'::jsonb ->> 'email'")" = "no_address" ] && [ "$(emails)" = "2" ] && [ "$(audits)" = "3" ] && ok "no address: no email, the request is still recorded" || bad "no address: $r"
out=$(req "$C" "x@closed.test"); [[ "$out" == *NOT_FOUND* ]] && ok "a cancelled business is refused" || bad "cancelled: $out"
out=$(q "select public.zella_request_documents('$B', '$ADM', '{}', 24, null, null, null, null)" 2>&1); [[ "$out" == *INVALID_INPUT* ]] && ok "nothing missing is invalid" || bad "invalid: $out"
g=$(q "select has_function_privilege('authenticated', 'public.zella_request_documents(uuid,uuid,text[],integer,text,text,text,text)', 'execute')::text || has_function_privilege('anon', 'public.zella_request_documents(uuid,uuid,text[],integer,text,text,text,text)', 'execute')::text")
[ "$g" = "falsefalse" ] && ok "only the server may call it" || bad "grants: $g"

"${RBRUN[@]}" > /dev/null 2>&1 && "${RBRUN[@]}" > /dev/null 2>&1 && ok "rollback runs twice (through the rollback runner)" || bad "rollback"
[ -z "$(q "select to_regprocedure('public.zella_request_documents(uuid,uuid,text[],integer,text,text,text,text)')")" ] && [ "$(audits)" = "3" ] && [ "$(emails)" = "2" ] && ok "rollback drops the function, keeps the audit rows and emails" || bad "after rollback"
"${P[@]}" -d $DB -f "$MIG" > /dev/null 2>&1 && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_request_documents(p_business uuid, p_actor uuid, p_missing text[], p_cooldown_hours integer, p_to text, p_subject text, p_html text, p_text text) returns jsonb language sql as \$f\$ select '{}'::jsonb \$f\$" > /dev/null
out=$("${P[@]}" -d $DB -f "$MIG" 2>&1); [[ "$out" == *VERSION_MISMATCH* ]] && ok "a changed function stops the file" || bad "drift: $out"
out=$("${RBRUN[@]}" 2>&1); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "and stops the rollback" || bad "rollback drift: $out"
echo
[ $fails -eq 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
