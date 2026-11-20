#!/usr/bin/env bash
# H2: sql/zella_caller_verification.sql. Through the receptionist's gateway (zella_ai_tool), as the server does:
# before, caller ID alone finds and cancels a booking and replaces an email (the gap); after, finding needs the name on
# the booking and the date, cancelling and moving need the confirmation code, three failed checks lock the call, an
# email or phone for a known caller waits for the team; codes are unique, 6 characters without lookalikes, and in the
# confirmation text; applies twice; the rollback restores all seven functions exactly; drift stops the file.
. "$(dirname "$0")/lib.sh"; fresh_db caller_verification
SIGS="'public.zella_ai_tool(text,uuid,text,jsonb,text)','public.zella_ai_manage_booking(text,uuid,text,jsonb)','public.zella_brain_tool_defs()','public.zella_brain_prompt_base(uuid)','public.zella_claim_reminders(integer,text)','public.zella_prepare_sms(uuid,uuid,text,jsonb,text)','public.zella_prepare_email(uuid,uuid,text,jsonb,text)'"
fp() { q "select string_agg(md5(pg_get_functiondef(s::regprocedure)), ',' order by s) from unnest(array[$SIGS]) s"; }
before=$(fp)
BIZ=$(q "insert into public.businesses (name, industry_id, is_active, timezone) select 'Verify Test', id, true, 'America/New_York' from public.industries limit 1 returning id" | head -1)
CUST=$(q "insert into public.customers (business_id, first_name, last_name, phone, email) values ('$BIZ', 'Dana', 'Reyes', '+15550001111', 'dana@verify.test') returning id" | head -1)
DAY=$(q "select to_char((now() at time zone 'America/New_York')::date + 3, 'YYYY-MM-DD')")
mkappt() { q "insert into public.appointments (business_id, customer_id, title, start_time, end_time, status) values ('$BIZ', '$CUST', '$1', ('$DAY 10:00'::timestamp at time zone 'America/New_York') + interval '$2 hours', ('$DAY 10:30'::timestamp at time zone 'America/New_York') + interval '$2 hours', 'scheduled') returning id" | head -1; }
mkcall() { q "insert into public.calls (business_id, direction, status, from_number, external_call_id) values ('$BIZ', 'inbound', 'answered', '${2:-+15550001111}', '$1')" > /dev/null; }
# tool <call id> <tool> <args json>: the gateway, as voice-rules calls it
tool() { q "select public.zella_ai_tool('$1', '$BIZ', '$2', '$3'::jsonb || jsonb_build_object('caller_number', (select from_number from public.calls where external_call_id = '$1')), null)"; }
js() { python3 -I -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('$1'))" "$2"; }
st() { q "select status from public.appointments where id = '$1'"; }

A0=$(mkappt Haircut 0); mkcall c0
r=$(tool c0 find_my_appointments '{}'); [ "$(js status "$r")" = appointments ] && ok "before: caller ID alone lists the bookings (the gap)" || bad "before find: $r"
r=$(tool c0 cancel_appointment "{\"appointment_id\":\"$A0\",\"confirmed\":\"true\"}"); [ "$(st $A0)" = cancelled ] && ok "before: caller ID alone cancels (the gap)" || bad "before cancel: $r"
tool c0 update_caller '{"email":"attacker@evil.test"}' > /dev/null
[ "$(q "select email from public.customers where id = '$CUST'")" = attacker@evil.test ] && ok "before: caller ID alone replaces the email (the gap)" || bad "before email"
q "update public.customers set email = 'dana@verify.test' where id = '$CUST'" > /dev/null

out=$(apply "$REPO/sql/zella_caller_verification.sql") && ok "applies" || { bad "applies: $out"; finish; }
out=$(apply "$REPO/sql/zella_caller_verification.sql") && ok "applies again" || bad "second apply: $out"
[ "$(fp)" = "$(q "select string_agg(m, ',' order by s) from (values ('public.zella_ai_tool(text,uuid,text,jsonb,text)','292cb59edd14074f69b90a74572ac16b'),('public.zella_ai_manage_booking(text,uuid,text,jsonb)','4e44bde81572948e1df7dc516f1c8e14'),('public.zella_brain_tool_defs()','858008c205ec3271a00bf375852ac646'),('public.zella_brain_prompt_base(uuid)','7ab9163c4df52183697bd8108aa94d15'),('public.zella_claim_reminders(integer,text)','0025c2100523b5f21ec3ee7ba979208e'),('public.zella_prepare_sms(uuid,uuid,text,jsonb,text)','038dad2c92525376fbeaf5e4964766a0'),('public.zella_prepare_email(uuid,uuid,text,jsonb,text)','d0d67a384b0e6a3e270e613ca4af923c')) v(s, m)")" ] && ok "new fingerprints are the recorded ones" || bad "fingerprints"

# codes
[ "$(q "select count(*) from public.appointment_confirmation_codes where appointment_id = '$A0'")" = 1 ] && ok "an existing booking got a code" || bad "backfill"
A1=$(mkappt Colour 1); A2=$(mkappt Trim 2)
CODE=$(q "select code from public.appointment_confirmation_codes where appointment_id = '$A1'")
[[ "$CODE" =~ ^[A-HJKMNP-Z2-9]{6}$ ]] && ok "a new booking gets a code like $CODE (no 0, O, 1, I or L)" || bad "code $CODE"
q "insert into public.appointments (business_id, customer_id, title, start_time, end_time, status) select '$BIZ', '$CUST', 'bulk', now() + interval '30 days' + n * interval '1 hour', now() + interval '30 days' + n * interval '1 hour' + interval '15 minutes', 'scheduled' from generate_series(1, 300) n" > /dev/null
[ "$(q "select count(distinct code) = count(*) and count(*) >= 303 and bool_and(code ~ '^[A-HJKMNP-Z2-9]{6}\$') from public.appointment_confirmation_codes where business_id = '$BIZ'")" = t ] && ok "codes are unique in the business and all well formed" || bad "uniqueness"
r=$(as_user 00000000-0000-0000-0000-000000000000 aal1 "update public.appointment_confirmation_codes set code = 'AAAAAA'; raise notice 'R=ran';")
[[ "$r" == ERR:* ]] && ok "nobody signed in can change a code ($r)" || bad "code writable: $r"

# find
mkcall c1
r=$(tool c1 find_my_appointments '{}'); [ "$(js status "$r")" = need_info ] && ok "find without name and date asks for them (not counted)" || bad "find bare: $r"
r=$(tool c1 find_my_appointments "{\"name\":\"dana reyes\",\"date\":\"$DAY\"}")
[ "$(js status "$r")" = appointments ] && [ "$(q "select jsonb_array_length('$r'::jsonb -> 'appointments')")" = 2 ] && ok "find with the name on the booking and the date lists that date's bookings" || bad "find ok: $r"
[[ "$r" != *"$CODE"* && "$r" != *dana@* && "$r" != *5550001111* ]] && ok "and shares no code, email or number" || bad "find leaks: $r"
mkcall c1b +15559990000
r=$(tool c1b find_my_appointments "{\"name\":\"Dana Reyes\",\"date\":\"$DAY\"}"); [ "$(js status "$r")" = not_found ] && ok "the right name and date from another number find nothing" || bad "other number: $r"
r=$(tool c1 find_my_appointments "{\"name\":\"Sam\",\"date\":\"$DAY\"}"); [ "$(js status "$r")" = not_found ] && ok "a wrong name finds nothing" || bad "wrong name: $r"
mkcall c1c; r=$(tool c1c find_my_appointments "{\"name\":\"Dana\",\"date\":\"$DAY\"}"); [ "$(js status "$r")" = not_found ] && ok "the first name alone isn't enough when the booking has a full name" || bad "first name only: $r"

# cancel and move need the code
mkcall c2
r=$(tool c2 cancel_appointment "{\"appointment_id\":\"$A1\",\"confirmed\":\"true\"}"); [ "$(js status "$r")" = need_code ] && [ "$(st $A1)" = scheduled ] && ok "cancel without the code is refused and offers a message" || bad "no code: $r"
r=$(tool c2 cancel_appointment "{\"confirmation_code\":\"ZZZZZZ\",\"confirmed\":\"true\"}"); [ "$(js status "$r")" = code_mismatch ] && ok "a wrong code is refused" || bad "wrong code: $r"
OTHER=$(q "select code from public.appointment_confirmation_codes where appointment_id = '$A2'")
r=$(tool c2 cancel_appointment "{\"appointment_id\":\"$A1\",\"confirmation_code\":\"$OTHER\",\"confirmed\":\"true\"}"); [ "$(js status "$r")" = code_mismatch ] && [ "$(st $A1)$(st $A2)" = scheduledscheduled ] && ok "another booking's code doesn't cancel this one" || bad "mixed: $r"
SPOKEN=$(echo "$CODE" | sed 's/./& /g; s/ $//' | tr 'A-Z' 'a-z')
r=$(tool c2 cancel_appointment "{\"confirmation_code\":\"QQQQQQ\",\"confirmed\":\"true\"}"); [ "$(js status "$r")" = locked ] && ok "the third failed check locks the call" || bad "lock: $r"
r=$(tool c2 cancel_appointment "{\"confirmation_code\":\"$SPOKEN\",\"confirmed\":\"true\"}"); [ "$(js status "$r")" = locked ] && [ "$(st $A1)" = scheduled ] && ok "after that even the right code does nothing on this call" || bad "after lock: $r"
[ "$(q "select count(*) from public.callbacks where business_id = '$BIZ'")" -ge 1 ] && ok "the team gets a callback request" || bad "no callback"
# a callback that can't be created never undoes the lock
q "alter function public.zella_create_callback(uuid,text,text,text,text,timestamptz,uuid,uuid,uuid,text,text) rename to zz_create_callback_real" > /dev/null
q "create function public.zella_create_callback(p1 uuid, p2 text, p3 text, p4 text, p5 text, p6 timestamptz, p7 uuid, p8 uuid, p9 uuid, p10 text, p11 text default null) returns uuid language plpgsql as \$f\$ begin raise exception 'callback down'; end \$f\$" > /dev/null
mkcall c2b; for x in 1 2; do tool c2b cancel_appointment '{"confirmation_code":"QQQQQQ","confirmed":"true"}' > /dev/null; done
r=$(tool c2b cancel_appointment '{"confirmation_code":"QQQQQQ","confirmed":"true"}'); [ "$(js status "$r")" = locked ] && [ "$(q "select failures from public.ai_call_verification_failures where call_key = 'c2b'")" = 3 ] && ok "the third failure locks the call even when the callback can't be created" || bad "callback down: $r"
q "drop function public.zella_create_callback(uuid,text,text,text,text,timestamptz,uuid,uuid,uuid,text,text); alter function public.zz_create_callback_real(uuid,text,text,text,text,timestamptz,uuid,uuid,uuid,text,text) rename to zella_create_callback" > /dev/null
mkcall c3 +15557770000
r=$(tool c3 cancel_appointment "{\"confirmation_code\":\"$SPOKEN\",\"confirmed\":\"true\"}"); [ "$(js status "$r")" = cancelled ] && [ "$(st $A1)" = cancelled ] && ok "on a new call the code, read out with spaces in lower case, cancels (any number)" || bad "cancel by code: $r"
NEWSTART=$(q "select to_char(((('$DAY'::date + 1) + time '15:00') at time zone 'America/New_York') at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
C2=$(q "select code from public.appointment_confirmation_codes where appointment_id = '$A2'")
r=$(tool c3 reschedule_appointment "{\"confirmation_code\":\"$C2\",\"start\":\"$NEWSTART\",\"confirmed\":\"true\"}")
case "$(js status "$r")" in rescheduled|unavailable|need_info) ok "move with the code reaches the booking checks ($(js status "$r"))";; *) bad "move: $r";; esac

# update_caller
mkcall c4
r=$(tool c4 update_caller '{"email":"attacker@evil.test","phone":"+15553334444"}')
[ "$(js status "$r")" = saved_for_review ] && [ "$(q "select email || phone from public.customers where id = '$CUST'")" = "dana@verify.test+15550001111" ] && ok "a known caller's new email and phone are not changed" || bad "update_caller: $r"
[ "$(q "select string_agg(field || '=' || new_value, ',' order by field) from public.customer_pending_changes where customer_id = '$CUST' and status = 'pending'")" = "email=attacker@evil.test,phone=+15553334444" ] && ok "they wait for the team" || bad "pending rows"
[ "$(q "select count(*) from public.crm_tasks where business_id = '$BIZ' and title = 'Check contact details a caller gave'" 2>/dev/null)" = 1 ] && ok "and the team gets a task" || bad "task"
NEW=$(q "insert into public.customers (business_id, phone) values ('$BIZ', '+15556660000') returning id" | head -1)
mkcall c5 +15556660000; tool c5 update_caller '{"first_name":"Lee","email":"lee@verify.test"}' > /dev/null
[ "$(q "select first_name from public.customers where id = '$NEW'")" = Lee ] && ok "an empty name is still filled in" || bad "name fill"
# the team decides
U=f5000000-0000-0000-0000-000000000001; V=f5000000-0000-0000-0000-000000000002
q "insert into auth.users (id, email, email_confirmed_at) values ('$U', 'own@verify.test', now()), ('$V', 'view@verify.test', now())" > /dev/null
q "insert into public.business_members (business_id, user_id, role, status) values ('$BIZ', '$U', 'owner', 'active'), ('$BIZ', '$V', 'viewer', 'active')" > /dev/null
r=$(as_user $V aal1 "raise notice 'R=%', (select count(*) from public.customer_pending_changes) + (select count(*) from public.appointment_confirmation_codes);"); [ "$r" = 0 ] && ok "a viewer can't read pending changes or confirmation codes" || bad "viewer reads: $r"
PID=$(q "select id from public.customer_pending_changes where customer_id = '$CUST' and field = 'email' and status = 'pending'")
r=$(as_user $V aal1 "perform public.zella_customer_pending_change_decide('$PID', true); raise notice 'R=ran';"); [[ "$r" == *NOT_ALLOWED* ]] && ok "a viewer can't approve" || bad "viewer: $r"
r=$(as_user $U aal1 "raise notice 'R=%', public.zella_customer_pending_changes('$BIZ'::uuid, null::uuid);"); [[ "$r" == *attacker@evil.test* ]] && ok "the owner sees the request" || bad "list: $r"
r=$(as_user $U aal1 "raise notice 'R=%', public.zella_customer_pending_change_decide('$PID', false);"); [[ "$r" == *rejected* ]] && [ "$(q "select email from public.customers where id = '$CUST'")" = dana@verify.test ] && ok "rejecting leaves the email" || bad "reject: $r"
PID=$(q "select id from public.customer_pending_changes where customer_id = '$CUST' and field = 'phone' and status = 'pending'")
r=$(as_user $U aal1 "raise notice 'R=%', public.zella_customer_pending_change_decide('$PID', true);"); [ "$(q "select phone from public.customers where id = '$CUST'")" = +15553334444 ] && ok "approving changes the phone" || bad "approve: $r"
[ "$(q "select count(*) from public.audit_logs where business_id = '$BIZ' and action like 'customer.contact_change_%'")" = 2 ] && ok "both decisions are audited" || bad "audit"

# messages carry the code
B=$(q "select public.zella_code_sentence('appointment_confirmation', 'Hi, booked {{date}}.', jsonb_build_object('reschedule_line', public.zella_confirmation_code_line('$A2') || ' Need a new time? x'))")
[ "$B" = "Your confirmation code is $C2." ] && ok "a template without the reschedule line still gets the code sentence" || bad "sentence: $B"
[ -z "$(q "select public.zella_code_sentence('appointment_confirmation', 'Hi {{reschedule_line}}', '{\"reschedule_line\":\" Your confirmation code is $C2.\"}')")" ] && ok "and isn't added twice" || bad "twice"
[ "$(q "select public.zella_confirmation_code_line('$A2')")" = " Your confirmation code is $C2." ] && ok "the reminder line starts with the code" || bad "line"
grep -q "confirmation_code" <<< "$(q "select public.zella_brain_tool_defs()::text")" && ok "the tool definitions ask for the code" || bad "tool defs"

apply "$REPO/sql/rollback/zella_caller_verification_rollback.sql" > /dev/null && apply "$REPO/sql/rollback/zella_caller_verification_rollback.sql" > /dev/null && ok "rollback runs twice" || bad "rollback"
[ "$(fp)" = "$before" ] && ok "rollback restores all seven functions exactly" || bad "fingerprints after rollback"
[ "$(q "select count(*) from public.appointment_confirmation_codes")" -ge 303 ] && [ "$(q "select count(*) from public.customer_pending_changes")" -ge 2 ] && ok "and keeps the codes and the contact change requests (no customer data deleted)" || bad "data lost"
apply "$REPO/sql/zella_caller_verification.sql" > /dev/null && ok "applies again after the rollback" || bad "reapply"
q "create or replace function public.zella_brain_tool_defs() returns jsonb language sql immutable as \$f\$ select '[]'::jsonb \$f\$" > /dev/null
out=$(apply "$REPO/sql/rollback/zella_caller_verification_rollback.sql"); [[ "$out" == *ROLLBACK_DRIFT* ]] && ok "the rollback refuses a changed function" || bad "rollback drift: $out"
q "delete from public.zella_function_archive where migration = 'zella_caller_verification'" > /dev/null
out=$(apply "$REPO/sql/zella_caller_verification.sql"); [[ "$out" == *VERSION_MISMATCH* ]] && ok "an unknown version stops the file" || bad "drift not caught: $out"
finish
