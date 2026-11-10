#!/usr/bin/env bash
# Release 3 workflow checks on an ISOLATED copy of the production state: tests/lib/build_full.sh plus every file applied
# since (the pending list of tests/deploy/run_all.sh, Batch 1, Batch 3), then sql/zella_record_workflows.sql twice,
# tests/workflows/test.sql, two people using a package's last credit at the same moment, every existing function
# unchanged, the new functions' rights, the rollback (keeps every row), and a second apply after it.
# Never point this at production.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}; DB=${DB:-zworkflows}
. "$REPO/tests/lib/isolated_guard.sh"; zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$DB" || exit 1
P=(psql -h "$ZPG_HOST" -p "$ZPG_PORT" -U postgres -qtAX -v ON_ERROR_STOP=1)   # an array: each value stays one argument
read -r -a PENDING <<< "$(sed -n '/^PENDING=(/,/)/p' "$REPO/tests/deploy/run_all.sh" | tr -d '()' | sed 's/^PENDING=//' | tr '\n' ' ')"
for m in "${PENDING[@]}"; do [[ "$m" =~ ^zella_[a-z0-9_]+$ ]] || { echo "FAIL unexpected pending entry: $m"; exit 1; }; done
[ "${#PENDING[@]}" -ge 10 ] || { echo "FAIL could not read the pending list"; exit 1; }
"$REPO/tests/lib/build_full.sh" "$DB" "$REPO/tests/channel/fixture.sql" || exit 1
for m in "${PENDING[@]}" zella_batch1_security zella_batch3_pagination; do
  [ "$m" = zella_record_workflows ] && continue   # applied below, after the baseline is taken
  [ -f "$REPO/sql/$m.sql" ] || continue
  out=$("${P[@]}" -d "$DB" -f "$REPO/sql/$m.sql" 2>&1) || { echo "FAIL apply $m: $(echo "$out" | grep -m1 ERROR)"; exit 1; }
done
fails=0
# every public function that exists before this release, so a change to any of them is caught
OLD="select md5(string_agg(p.oid::regprocedure::text || pg_get_functiondef(p.oid), '' order by p.oid::regprocedure::text)) from pg_proc p
       where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.oid::regprocedure::text = any (string_to_array(:'names', ','))"
names=$("${P[@]}" -d "$DB" -c "select string_agg(p.oid::regprocedure::text, ',') from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'")
old_before=$("${P[@]}" -d "$DB" -v names="$names" -f <(echo "$OLD"))
for i in 1 2; do out=$("${P[@]}" -d "$DB" -f "$REPO/sql/zella_record_workflows.sql" 2>&1) || { echo "FAIL migration run $i: $(echo "$out" | grep -m1 ERROR)"; fails=$((fails + 1)); }; done
[ $fails = 0 ] && echo "PASS sql/zella_record_workflows.sql applies twice"
out=$("${P[@]}" -d "$DB" -f "$HERE/test.sql" 2>&1); code=$?
echo "$out" | grep -o 'PASS .*'
if [ $code -ne 0 ]; then echo "FAIL test.sql: $(echo "$out" | grep -m3 -E 'ERROR|CONTEXT' | tr '\n' ' ')"; fails=$((fails + 1)); fi
old_after=$("${P[@]}" -d "$DB" -v names="$names" -f <(echo "$OLD"))
if [ -n "$old_before" ] && [ "$old_after" = "$old_before" ]; then echo "PASS every existing function is byte-for-byte unchanged ($(tr ',' '\n' <<< "$names" | wc -l) functions)"; else echo "FAIL an existing function changed"; fails=$((fails + 1)); fi

# two people use a package's last credit at the same moment: exactly one succeeds
"${P[@]}" -d "$DB" -c "insert into public.businesses (id, name, timezone, is_active, onboarding_status) values ('c6000000-0000-0000-0000-0000000000c1', 'R3 Race', 'UTC', true, 'active');
  insert into auth.users (id, email) values ('c6000000-0000-0000-0000-0000000000c9', 'race@r3.test');
  insert into public.business_members (business_id, user_id, role, status) values ('c6000000-0000-0000-0000-0000000000c1', 'c6000000-0000-0000-0000-0000000000c9', 'owner', 'active');
  insert into public.crm_record_types (business_id, key, singular, plural, statuses, closed_statuses, preset_key) values ('c6000000-0000-0000-0000-0000000000c1', 'packages', 'Package', 'Packages', '[{\"key\":\"active\",\"label\":\"Active\"},{\"key\":\"used_up\",\"label\":\"Used up\"}]', '{used_up}', 'spa_wellness');
  insert into public.crm_records (id, business_id, type_key, title, status) values ('c6000000-0000-0000-0000-0000000002c1', 'c6000000-0000-0000-0000-0000000000c1', 'packages', 'Race', 'active');
  insert into public.record_credits (business_id, record_id, kind, units) values ('c6000000-0000-0000-0000-0000000000c1', 'c6000000-0000-0000-0000-0000000002c1', 'grant', 1);" > /dev/null
USE="begin; set local role authenticated; select set_config('request.jwt.claims', '{\"sub\":\"c6000000-0000-0000-0000-0000000000c9\",\"role\":\"authenticated\",\"aal\":\"aal1\"}', true);
  select public.zella_credit_add('c6000000-0000-0000-0000-0000000002c1', 'use', 1); select pg_sleep(1); commit;"
( "${P[@]}" -d "$DB" -c "$USE" > /dev/null 2>&1 && echo ok || echo refused ) > /tmp/zwf_race1 &
( "${P[@]}" -d "$DB" -c "$USE" > /dev/null 2>&1 && echo ok || echo refused ) > /tmp/zwf_race2 &
wait
race="$(cat /tmp/zwf_race1 /tmp/zwf_race2 | sort | tr '\n' ' ')"; rm -f /tmp/zwf_race1 /tmp/zwf_race2
bal=$("${P[@]}" -d "$DB" -c "select coalesce(sum(case when kind in ('grant','refund') then units else -units end), 0) from public.record_credits where record_id = 'c6000000-0000-0000-0000-0000000002c1'")
if [ "$race" = "ok refused " ] && [ "$bal" = 0 ]; then echo "PASS two people using the last credit at once: one succeeds, the other is refused, the balance never goes below zero"; else echo "FAIL race: $race balance $bal"; fails=$((fails + 1)); fi

# the new functions: exactly these, owner's rights only where needed, a fixed search path, nothing for anon
NEW="('zella_workflow_record','zella_workflow_log','zella_workflow_move','zella_approval_request','zella_approval_approver','zella_approval_decide','zella_approval_withdraw',
  'zella_approval_approvers','zella_milestone_save','zella_milestone_done','zella_inspection_clean','zella_inspection_save','zella_exception_open','zella_exception_resolve',
  'zella_credit_balance','zella_credit_add','zella_workflow_clean','zella_record_workflow_save','zella_record_workflow_defaults_trg','zella_workflow_due')"
if res=$("${P[@]}" -d "$DB" -c "select count(*), count(*) filter (where p.prosecdef), count(*) filter (where not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search\_path=%')),
    coalesce(string_agg(p.proname, ',') filter (where has_function_privilege('anon', p.oid, 'execute')), ''),
    coalesce(string_agg(p.proname, ',') filter (where p.proname in ('zella_workflow_record','zella_workflow_log','zella_workflow_move','zella_approval_approver','zella_credit_balance','zella_record_workflow_defaults_trg') and has_function_privilege('authenticated', p.oid, 'execute')), '')
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in $NEW"); then
  IFS='|' read -r nfn ndef nbad anon inner <<< "$res"
  if [ "$nfn" -eq 20 ] && [ "$ndef" -eq 18 ] && [ "$nbad" = 0 ] && [ -z "$anon" ] && [ -z "$inner" ]; then echo "PASS exactly the 20 new functions (18 with the owner's rights, all with a fixed search path); anon can run none; signed-in users can't call the internal helpers"
  else echo "FAIL catalog: $nfn functions, $ndef definer, $nbad without a search path, anon: ${anon:-none}, internal callable: ${inner:-none}"; fails=$((fails + 1)); fi
else echo "FAIL catalog check could not run"; fails=$((fails + 1)); fi

# rollback keeps the data (renamed tables, the setting kept), removes the functions and trigger; a second apply works
"${P[@]}" -d "$DB" -c "insert into public.record_milestones (business_id, record_id, title, due_on) values ('c6000000-0000-0000-0000-0000000000c1', 'c6000000-0000-0000-0000-0000000002c1', 'Kept', current_date)" > /dev/null
out=$("${P[@]}" -d "$DB" -f "$REPO/sql/rollback/zella_record_workflows_rollback.sql" 2>&1) || { echo "FAIL rollback: $(echo "$out" | grep -m1 ERROR)"; fails=$((fails + 1)); }
res=$("${P[@]}" -d "$DB" -c "select (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in $NEW),
  (select count(*) from pg_trigger where tgname = 'zella_record_workflow_defaults'),
  (select count(*) from public.record_credits_rolled_back), (select count(*) from public.record_milestones_rolled_back),
  (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'crm_record_types' and column_name = 'workflow')")
IFS='|' read -r left trig kept_c kept_m col <<< "$res"
old_rb=$("${P[@]}" -d "$DB" -v names="$names" -f <(echo "$OLD"))
if [ "$left" = 0 ] && [ "$trig" = 0 ] && [ "$kept_c" -ge 1 ] && [ "$kept_m" -ge 1 ] && [ "$col" = 1 ] && [ "$old_rb" = "$old_before" ]; then
  echo "PASS rollback removes the functions and trigger, keeps the data ($kept_c credit entries, $kept_m milestones set aside; the workflow setting kept), and every existing function is as before"
else echo "FAIL rollback: $left functions and $trig triggers left; kept $kept_c credits, $kept_m milestones, column $col"; fails=$((fails + 1)); fi
out=$("${P[@]}" -d "$DB" -f "$REPO/sql/zella_record_workflows.sql" 2>&1 && "${P[@]}" -d "$DB" -f "$HERE/test.sql" 2>&1) && echo "PASS re-apply after the rollback: fresh tables, all checks pass again" || { echo "FAIL after re-apply: $(echo "$out" | grep -m1 -E 'ERROR')"; fails=$((fails + 1)); }
echo; [ $fails = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
