-- Checks for sql/zella_review_sql_fixes.sql on an ISOLATED copy of the production schema (tests/review_sql/run.sh).
-- Synthetic data only (ids fa…, *.rf.test, numbers +1555…); everything is rolled back. In the order of CodeRabbit's
-- findings on the full-repository review (PR #38), numbered as there.
\set ON_ERROR_STOP on
begin;
-- Compile every replaced PL/pgSQL function, including triggers against their actual relations.
-- plpgsql_check is installed only in this isolated database and rolled back with the fixtures.
create extension if not exists plpgsql_check;
do $$ declare f record; t record; e record; begin
  for f in select p.oid, p.prorettype, p.proname from pg_proc p join pg_language l on l.oid = p.prolang
    where p.pronamespace = 'public'::regnamespace and l.lanname = 'plpgsql'
      and p.proname = any (array['zella_claim_admin_alert_email', 'zella_admin_routing_save', 'zella_admin_message_detail', 'zella_admin_template_variables', 'zella_admin_numbers', 'zella_admin_calls', 'zella_admin_automations', 'zella_admin_runs', 'zella_admin_templates', 'zella_set_industry_rules', 'zella_answer_knowledge_gap', 'zella_knowledge_guard', 'zella_capture_web_lead', 'zella_ai_booking', 'zella_flag_unrecorded_appointments', 'zella_rebalance_assignments', 'zella_save_business_hours', 'zella_add_business_closure', 'zella_finish_calendar_sync', 'zella_calendar_connect_provider', 'zella_queue_calendar_sync', 'zella_claim_calendar_sync', 'zella_replace_calendar_busy', 'zella_sensitive_industry', 'zella_today_operations', 'zella_merge_customers', 'zella_log_customer_request', 'zella_update_customer_request', 'zella_record_status_touches_trg', 'zella_queue_customer_touches', 'zella_check_engine_health', 'zella_ai_voice', 'zella_complete_followup_task', 'zella_claim_reminders', 'zella_permission_check', 'zella_apply_industry_automations', 'zella_decide_draft', 'zella_claim_events', 'zella_complete_event', 'zella_record_consent', 'zella_calls_page', 'zella_inbox_previews']) loop
    if f.prorettype = 'trigger'::regtype then
      for t in select distinct tgrelid from pg_trigger where tgfoid = f.oid loop
        for e in select * from plpgsql_check_function_tb(f.oid, t.tgrelid) where level = 'error' loop
          raise exception 'Function %: %', f.proname, e.message;
        end loop;
      end loop;
    else
      for e in select * from plpgsql_check_function_tb(f.oid) where level = 'error' loop
        raise exception 'Function %: %', f.proname, e.message;
      end loop;
    end if;
  end loop;
end $$;
select 'PASS execution-time validation of all replaced PL/pgSQL functions and trigger relations';

reset role; set timezone = 'UTC';
create or replace function pg_temp.as_user(u text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'aal', 'aal1')::text, true) $$;
create or replace function pg_temp.as_server() returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true) $$;
-- raises unless the statement fails with an error containing the expected text
create or replace function pg_temp.must_fail(stmt text, expected text) returns void language plpgsql as $$
begin
  execute stmt;
  raise exception 'expected % but it succeeded: %', expected, stmt;
exception when others then
  if sqlerrm not like '%' || expected || '%' then raise exception 'expected %, got %: %', expected, sqlerrm, stmt; end if;
end $$;
grant execute on function pg_temp.must_fail(text, text) to authenticated;
grant execute on function pg_temp.as_user(text) to authenticated;

insert into auth.users (id, email, email_confirmed_at) values
 ('fa000000-0000-0000-0000-00000000000a', 'owner@rf.test', now()), ('fa000000-0000-0000-0000-00000000000b', 'staff@rf.test', now()),
 ('fa000000-0000-0000-0000-00000000000c', 'manager@rf.test', now()), ('fa000000-0000-0000-0000-00000000000e', 'outsider@rf.test', now()),
 ('fa000000-0000-0000-0000-00000000000f', 'newadmin@rf.test', now());
insert into public.profiles (id) select id from auth.users where email like '%@rf.test' on conflict do nothing;
insert into public.businesses (id, name, timezone, is_active, onboarding_status, industry_id) values
 ('fa000000-0000-0000-0000-0000000000a1', 'RF Dental', 'UTC', true, 'active', (select id from public.industries where slug = 'dental' limit 1)),
 ('fa000000-0000-0000-0000-0000000000b1', 'RF Plumbing', 'UTC', true, 'active', (select id from public.industries where slug = 'plumbing' limit 1));
insert into public.business_members (business_id, user_id, role, status) values
 ('fa000000-0000-0000-0000-0000000000a1', 'fa000000-0000-0000-0000-00000000000a', 'owner', 'active'),
 ('fa000000-0000-0000-0000-0000000000a1', 'fa000000-0000-0000-0000-00000000000b', 'staff', 'active'),
 ('fa000000-0000-0000-0000-0000000000a1', 'fa000000-0000-0000-0000-00000000000c', 'manager', 'active');
insert into public.customers (id, business_id, first_name, phone, email, status) values
 ('fa100000-0000-0000-0000-000000000001', 'fa000000-0000-0000-0000-0000000000a1', 'Keep', '+15550100001', 'keep@rf.test', 'active'),
 ('fa100000-0000-0000-0000-000000000002', 'fa000000-0000-0000-0000-0000000000a1', 'Drop', '+15550100002', 'drop@rf.test', 'active'),
 ('fa100000-0000-0000-0000-000000000003', 'fa000000-0000-0000-0000-0000000000a1', 'Archived', '+15550100003', null, 'archived'),
 ('fa100000-0000-0000-0000-000000000004', 'fa000000-0000-0000-0000-0000000000a1', 'Stopped', '+15550100004', 'stopped@rf.test', 'active');
update public.customers set do_not_sms = true where id = 'fa100000-0000-0000-0000-000000000004';
insert into public.calls (id, business_id, direction, status, from_number) values
 ('fa200000-0000-0000-0000-000000000001', 'fa000000-0000-0000-0000-0000000000a1', 'inbound', 'completed', '+15550100001'),
 ('fa200000-0000-0000-0000-000000000002', 'fa000000-0000-0000-0000-0000000000b1', 'inbound', 'completed', '+15550100009');

-- #8 dental reminders don't name the treatment; other industries' wording is unchanged
do $$ begin
  if (select count(*) from public.message_templates t join public.industries i on i.id = t.industry_id
       where i.slug = 'dental' and t.business_id is null and t.key = 'appointment_reminder') <> 2 then raise exception 'FAIL #8 fixture'; end if;
  if exists (select 1 from public.message_templates t join public.industries i on i.id = t.industry_id
              where i.slug = 'dental' and t.business_id is null and t.key = 'appointment_reminder' and t.body like '%{{appointment}}%') then raise exception 'FAIL #8 still names it'; end if;
  if not exists (select 1 from public.message_templates t join public.industries i on i.id = t.industry_id
                  where i.slug = 'fitness' and t.body like '%{{appointment}}%') then raise exception 'FAIL #8 changed another industry'; end if;
end $$;
select 'PASS #8 dental reminders say "your appointment"; other industries unchanged';

-- #13 knowledge: an approval can't be supplied by the app
set local role authenticated; select pg_temp.as_user('fa000000-0000-0000-0000-00000000000b');
insert into public.knowledge_items (id, business_id, kind, title, answer, status, approved_by, approved_at)
values ('fa300000-0000-0000-0000-000000000001', 'fa000000-0000-0000-0000-0000000000a1', 'faq', 'Parking', 'Free parking', 'draft', 'fa000000-0000-0000-0000-00000000000a', now());
update public.knowledge_items set approved_by = 'fa000000-0000-0000-0000-00000000000a' where id = 'fa300000-0000-0000-0000-000000000001';
reset role;
do $$ begin
  if (select approved_by from public.knowledge_items where id = 'fa300000-0000-0000-0000-000000000001') is not null then raise exception 'FAIL #13 forged approval kept'; end if;
end $$;
select 'PASS #13 knowledge: approved_by/approved_at from the app are ignored on insert and update';

-- #21 #41 #46 grants
do $$ begin
  if has_function_privilege('authenticated', 'public.zella_booking_choices(uuid,timestamptz,timestamptz,integer,integer,integer)', 'execute')
     or has_function_privilege('authenticated', 'public.zella_arrival_window(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.zella_capability_on(uuid,text)', 'execute') then raise exception 'FAIL #21/#41 helpers still callable'; end if;
  if has_function_privilege('anon', 'public.zella_cross_sell_ideas(text)', 'execute') then raise exception 'FAIL #46 anon can call cross-sell'; end if;
  if not has_function_privilege('service_role', 'public.zella_arrival_window(uuid)', 'execute') then raise exception 'FAIL #21 service role lost access'; end if;
end $$;
select 'PASS #21 #41 #46 internal helpers not callable by signed-in users; cross-sell not by anon';

-- #35 legacy connect removed
do $$ begin if to_regprocedure('public.zella_calendar_connect(uuid,text,text,text)') is not null then raise exception 'FAIL #35'; end if; end $$;
select 'PASS #35 legacy zella_calendar_connect removed';

-- #38 a pull of more than 500 events is refused before busy times are removed
insert into public.calendar_connections (id, business_id, provider, status, calendar_id, vault_secret_name)
values ('fa400000-0000-0000-0000-000000000001', 'fa000000-0000-0000-0000-0000000000b1', 'outlook', 'active', 'primary', 'x');
insert into public.blocked_times (business_id, title, start_time, end_time, source, external_id, connection_id)
values ('fa000000-0000-0000-0000-0000000000b1', 'Busy', now() + interval '1 day', now() + interval '1 day 1 hour', 'google', 'ev-old', 'fa400000-0000-0000-0000-000000000001');
select pg_temp.must_fail($q$select public.zella_replace_calendar_busy('fa400000-0000-0000-0000-000000000001',
  (select jsonb_agg(jsonb_build_object('id', 'e' || i, 'start', now() + make_interval(hours => i), 'end', now() + make_interval(hours => i, mins => 30))) from generate_series(1, 501) i))$q$, 'TOO_MANY_EVENTS');
do $$ begin if not exists (select 1 from public.blocked_times where external_id = 'ev-old') then raise exception 'FAIL #38 busy time removed'; end if; end $$;
select public.zella_replace_calendar_busy('fa400000-0000-0000-0000-000000000001', jsonb_build_array(jsonb_build_object('id', 'e1', 'start', now() + interval '2 days', 'end', now() + interval '2 days 1 hour')));
do $$ begin if (select title from public.blocked_times where external_id = 'e1') <> 'Busy (Outlook calendar)' then raise exception 'FAIL #33 title'; end if; end $$;
select 'PASS #38 501 events refused and nothing removed; #33 an Outlook busy time is labelled Outlook';

-- #39 sensitive industry only for the caller's own business
set local role authenticated; select pg_temp.as_user('fa000000-0000-0000-0000-00000000000a');
do $$ begin if not public.zella_sensitive_industry('fa000000-0000-0000-0000-0000000000a1') then raise exception 'FAIL #39 owner'; end if; end $$;
select pg_temp.as_user('fa000000-0000-0000-0000-00000000000e');
do $$ begin if public.zella_sensitive_industry('fa000000-0000-0000-0000-0000000000a1') then raise exception 'FAIL #39 outsider learns it'; end if; end $$;
reset role;
select 'PASS #39 sensitive-industry answer only for members';

-- #47 #48 merge: no archived keep; the duplicate's opt-out follows the kept customer
insert into public.contact_consents (business_id, customer_id, phone_digits, channel, purpose, status, source)
values ('fa000000-0000-0000-0000-0000000000a1', 'fa100000-0000-0000-0000-000000000002', '15550100002', 'sms', 'marketing', 'opted_out', 'staff');
set local role authenticated; select pg_temp.as_user('fa000000-0000-0000-0000-00000000000a');
select pg_temp.must_fail($q$select public.zella_merge_customers('fa000000-0000-0000-0000-0000000000a1', 'fa100000-0000-0000-0000-000000000003', 'fa100000-0000-0000-0000-000000000002')$q$, 'KEEP_ARCHIVED');
select public.zella_merge_customers('fa000000-0000-0000-0000-0000000000a1', 'fa100000-0000-0000-0000-000000000001', 'fa100000-0000-0000-0000-000000000002');
reset role;
do $$ begin
  if public.zella_can_contact('fa000000-0000-0000-0000-0000000000a1', 'fa100000-0000-0000-0000-000000000001', 'sms', 'marketing') then raise exception 'FAIL #48 opt-out lost'; end if;
  if not exists (select 1 from public.contact_consents where customer_id = 'fa100000-0000-0000-0000-000000000001' and evidence ? 'merged_from') then raise exception 'FAIL #48 not moved'; end if;
end $$;
select 'PASS #47 archived customer cannot be kept; #48 the duplicate''s opt-out applies to the kept customer';

-- #50 two unidentified callers are two requests; the same call is one
do $$ declare a uuid; b uuid; c uuid; begin
  a := public.zella_log_customer_request('fa000000-0000-0000-0000-0000000000a1', null, 'complaint', 'First caller is unhappy', 'phone', null);
  b := public.zella_log_customer_request('fa000000-0000-0000-0000-0000000000a1', null, 'complaint', 'Second caller is unhappy', 'phone', null);
  c := public.zella_log_customer_request('fa000000-0000-0000-0000-0000000000a1', null, 'complaint', 'Same call again', 'phone', 'fa200000-0000-0000-0000-000000000001');
  if a = b then raise exception 'FAIL #50 merged two callers'; end if;
  if c <> public.zella_log_customer_request('fa000000-0000-0000-0000-0000000000a1', null, 'complaint', 'Same call, said twice', 'phone', 'fa200000-0000-0000-0000-000000000001') then raise exception 'FAIL #50 same call not merged'; end if;
end $$;
select 'PASS #50 unidentified callers kept apart; repeats on the same call merged';

-- #51 a privacy request is rejected or reopened only by an owner or admin
insert into public.customer_requests (id, business_id, kind, summary, source, status, priority, due_at)
values ('fa500000-0000-0000-0000-000000000001', 'fa000000-0000-0000-0000-0000000000a1', 'data_deletion', 'Delete my data', 'phone', 'waiting_verification', 'normal', now() + interval '30 days');
set local role authenticated; select pg_temp.as_user('fa000000-0000-0000-0000-00000000000b');
select pg_temp.must_fail($q$select public.zella_update_customer_request('fa500000-0000-0000-0000-000000000001', 'rejected', 'not needed')$q$, 'NOT_ALLOWED');
select pg_temp.as_user('fa000000-0000-0000-0000-00000000000a');
select public.zella_update_customer_request('fa500000-0000-0000-0000-000000000001', 'rejected', 'Could not verify');
select pg_temp.as_user('fa000000-0000-0000-0000-00000000000b');
select pg_temp.must_fail($q$select public.zella_update_customer_request('fa500000-0000-0000-0000-000000000001', 'open', null)$q$, 'NOT_ALLOWED');
reset role;
select 'PASS #51 staff can neither reject nor reopen a privacy request; the owner can';

-- #64 the assistant can't label a transfer an emergency
do $$ declare r jsonb; begin
  r := public.zella_ai_voice('rf-no-such-call', 'fa000000-0000-0000-0000-0000000000a1', 'transfer', '{"reason": "Emergency"}'::jsonb);
  if r ->> 'status' <> 'use_emergency' then raise exception 'FAIL #64 got %', r; end if;
end $$;
select 'PASS #64 transfer with reason "emergency" is sent to report_emergency instead';

-- #65 #66 follow-up tasks: finished once; the call must be the task's business
insert into public.followup_tasks (id, business_id, customer_id, kind, channel, due_at, status, attempts, max_attempts)
values ('fa600000-0000-0000-0000-000000000001', 'fa000000-0000-0000-0000-0000000000a1', 'fa100000-0000-0000-0000-000000000001', 'no_show', 'call', now(), 'in_progress', 1, 3);
select pg_temp.must_fail($q$select public.zella_complete_followup_task('fa600000-0000-0000-0000-000000000001', 'wants_callback', 'x', null, 'fa200000-0000-0000-0000-000000000002')$q$, 'TENANT_MISMATCH');
do $$ begin
  if public.zella_complete_followup_task('fa600000-0000-0000-0000-000000000001', 'wants_callback', 'Call me', null, 'fa200000-0000-0000-0000-000000000001') <> 'done' then raise exception 'FAIL #65'; end if;
  update public.calls set needs_human = false where id = 'fa200000-0000-0000-0000-000000000001';
  perform public.zella_complete_followup_task('fa600000-0000-0000-0000-000000000001', 'wants_callback', 'Again', null, 'fa200000-0000-0000-0000-000000000001');
  if (select needs_human from public.calls where id = 'fa200000-0000-0000-0000-000000000001') then raise exception 'FAIL #65 finished twice'; end if;
  if (select needs_human from public.calls where id = 'fa200000-0000-0000-0000-000000000002') then raise exception 'FAIL #66 other business touched'; end if;
end $$;
select 'PASS #65 a finished task is not finished again; #66 a call from another business is refused';

-- #70 platform-admin changes are audited
-- (second pass) a user whose email identity is not verified cannot be made a platform admin
update auth.users set last_sign_in_at = now() where id = 'fa000000-0000-0000-0000-00000000000f';
do $$ begin
  insert into public.platform_admins (user_id, role, is_active) values ('fa000000-0000-0000-0000-00000000000f', 'super_admin', true);
  raise exception 'FAIL platform admin without a verified email identity was accepted';
exception when others then if sqlerrm like 'FAIL%' then raise; end if;
end $$;
select 'PASS platform admin needs a verified email identity (CodeRabbit #38 second pass)';
insert into auth.identities (user_id, provider, email, identity_data) values ('fa000000-0000-0000-0000-00000000000f', 'email', 'newadmin@rf.test', '{"email": "newadmin@rf.test", "email_verified": true}');
insert into public.platform_admins (user_id, role, is_active) values ('fa000000-0000-0000-0000-00000000000f', 'super_admin', true);
do $$ begin
  if not exists (select 1 from public.audit_logs where entity_type = 'platform_admins' and new_data ->> 'user_id' = 'fa000000-0000-0000-0000-00000000000f') then raise exception 'FAIL #70'; end if;
end $$;
select 'PASS #70 granting platform-admin rights writes audit_logs';

-- #71 the permission check reports tables with row security off
do $$ begin if not (public.zella_permission_check() ? 'tables_without_row_security') then raise exception 'FAIL #71'; end if; end $$;
create table public.rf_open_table (id int); grant select on public.rf_open_table to authenticated;
do $$ begin
  if not (public.zella_permission_check() -> 'tables_without_row_security') ? 'rf_open_table' or (public.zella_permission_check() ->> 'ok')::boolean then raise exception 'FAIL #71 not reported'; end if;
end $$;
drop table public.rf_open_table;
select 'PASS #71 a reachable table without row security is reported and makes ok false';

-- #73 marketing is rejected by the function's existing exception contract.
insert into public.message_drafts (id, business_id, customer_id, body, reason)
values ('fa730000-0000-0000-0000-000000000001', 'fa000000-0000-0000-0000-0000000000a1',
        'fa100000-0000-0000-0000-000000000001', 'Get 20% off this week', 'Synthetic test');
set local role authenticated; select pg_temp.as_user('fa000000-0000-0000-0000-00000000000a');
select pg_temp.must_fail($q$select public.zella_decide_draft('fa730000-0000-0000-0000-000000000001', true)$q$, 'NO_MARKETING_OR_PRICES');
reset role;
select 'PASS #73 decide_draft rejects percent-off marketing';

-- #75 completing an event that is no longer being processed does nothing
insert into public.automation_events (id, business_id, event_type, source, idempotency_key, payload, status, attempts)
values ('fa700000-0000-0000-0000-000000000001', 'fa000000-0000-0000-0000-0000000000a1', 'call.ended', 'system', 'rf-event-0001', '{}', 'processed', 1),
       ('fa700000-0000-0000-0000-000000000002', 'fa000000-0000-0000-0000-0000000000a1', 'call.ended', 'system', 'rf-event-0002', '{}', 'processing', 5);
update public.automation_events set claimed_at = now() - interval '1 hour' where id = 'fa700000-0000-0000-0000-000000000002';
do $$ begin
  if public.zella_complete_event('fa700000-0000-0000-0000-000000000001', false, 'unknown_error', 'late') <> 'ignored' then raise exception 'FAIL #75 completed twice'; end if;
  if exists (select 1 from public.zella_claim_events(100) e where e.id = 'fa700000-0000-0000-0000-000000000002') then raise exception 'FAIL #75 reclaimed after 5 attempts'; end if;
  if not exists (select 1 from public.automation_dead_letters where event_id = 'fa700000-0000-0000-0000-000000000002') then raise exception 'FAIL #75 no dead letter'; end if;
end $$;
select 'PASS #75 a finished event ignores late reports; an event with 5 attempts is not claimed again';

-- Health cleanup uses the same completion lock/dead-letter path; earlier attempts remain reclaimable.
insert into public.automation_events (id, business_id, event_type, source, idempotency_key, payload, status, attempts, claimed_at)
values ('fa750000-0000-0000-0000-000000000001', 'fa000000-0000-0000-0000-0000000000a1', 'call.ended', 'system', 'rf-health-final', '{}', 'processing', 5, now() - interval '1 hour'),
       ('fa750000-0000-0000-0000-000000000002', 'fa000000-0000-0000-0000-0000000000a1', 'call.ended', 'system', 'rf-health-retry', '{}', 'processing', 4, now() - interval '1 hour');
select public.zella_check_engine_health();
do $$ begin
  if (select status from public.automation_events where id = 'fa750000-0000-0000-0000-000000000001') <> 'failed'
     or not exists (select 1 from public.automation_dead_letters where event_id = 'fa750000-0000-0000-0000-000000000001') then raise exception 'FAIL exhausted health cleanup'; end if;
  if public.zella_complete_event('fa750000-0000-0000-0000-000000000001', true) <> 'ignored' then raise exception 'FAIL late completion'; end if;
  if not exists (select 1 from public.zella_claim_events(100) where id = 'fa750000-0000-0000-0000-000000000002' and attempts = 5) then raise exception 'FAIL fourth attempt not reclaimed'; end if;
end $$;
select 'PASS health cleanup dead-letters final attempts and preserves earlier reclaiming';

-- #76 consent: only staff-witnessed sources, opt-ins need a manager, only the server lifts do-not flags
set local role authenticated; select pg_temp.as_user('fa000000-0000-0000-0000-00000000000b');
select pg_temp.must_fail($q$select public.zella_record_consent('fa000000-0000-0000-0000-0000000000a1', 'sms', 'opted_in', 'email_link', 'fa100000-0000-0000-0000-000000000004')$q$, 'NOT_ALLOWED');
select pg_temp.must_fail($q$select public.zella_record_consent('fa000000-0000-0000-0000-0000000000a1', 'sms', 'opted_in', 'staff', 'fa100000-0000-0000-0000-000000000004')$q$, 'NOT_ALLOWED');
select public.zella_record_consent('fa000000-0000-0000-0000-0000000000a1', 'email', 'opted_out', 'staff', 'fa100000-0000-0000-0000-000000000004');
select pg_temp.as_user('fa000000-0000-0000-0000-00000000000c');
select public.zella_record_consent('fa000000-0000-0000-0000-0000000000a1', 'sms', 'opted_in', 'verbal_call', 'fa100000-0000-0000-0000-000000000004');
reset role;
do $$ begin
  if not (select do_not_sms from public.customers where id = 'fa100000-0000-0000-0000-000000000004') then raise exception 'FAIL #76 a signed-in manager lifted STOP'; end if;
end $$;
select pg_temp.as_server();
select public.zella_record_consent('fa000000-0000-0000-0000-0000000000a1', 'sms', 'opted_in', 'inbound_sms_keyword', 'fa100000-0000-0000-0000-000000000004', null, null, 'marketing', 'START');
do $$ begin
  if (select do_not_sms from public.customers where id = 'fa100000-0000-0000-0000-000000000004') then raise exception 'FAIL #76 the customer''s own START did not lift it'; end if;
end $$;
select 'PASS #76 staff can''t opt a customer in or use server sources; only the customer''s own reply lifts STOP';

-- #78 the preview limit counts every element
set local role authenticated; select pg_temp.as_user('fa000000-0000-0000-0000-00000000000a');
select pg_temp.must_fail($q$select public.zella_inbox_previews('fa000000-0000-0000-0000-0000000000a1',
  (select array_agg(array[gen_random_uuid(), gen_random_uuid()]) from generate_series(1, 60))::uuid[])$q$, 'TOO_MANY');
reset role;
select 'PASS #78 a 60x2 array (120 ids) is refused';

-- second pass (CodeRabbit's autofix on #38): dispatch is off unless switched on; admin lists break ties by id;
-- restoring a config migration puts back only the transfer keys it changed
do $$ begin
  delete from public.platform_settings where key = 'n8n_dispatch_enabled';
  if position($p$zella_setting('n8n_dispatch_enabled', 'false'::jsonb) = 'true'::jsonb, false)$p$ in pg_get_functiondef('public.zella_dispatch_n8n'::regproc)) = 0 then raise exception 'FAIL dispatch default'; end if;
  if position('order by created_at desc, id limit v_lim' in pg_get_functiondef(to_regprocedure((select oid::regprocedure::text from pg_proc where proname = 'zella_admin_messages')))) = 0 then raise exception 'FAIL admin_messages tie-break'; end if;
  if position($p$if s.applied ? 'transfer_number' then$p$ in pg_get_functiondef('public.zella_config_migration_restore'::regproc)) = 0 then raise exception 'FAIL config restore'; end if;
end $$;
select 'PASS dispatch is off unless n8n_dispatch_enabled is true; admin messages break ties by id; config restore puts back only transfer keys';

-- PR #41 (SQL part 2): CodeRabbit's autofix, in its order
do $$
declare d text;
begin
  d := pg_get_functiondef((select oid from pg_proc where proname = 'zella_offer_redeem_core'));
  if position('pg_advisory_xact_lock(hashtextextended(p_key, 0))' in d) = 0 then raise exception 'FAIL #41 offer redemptions are not serialized per key'; end if;
  d := pg_get_functiondef((select oid from pg_proc where proname = 'zella_reassign_callback'));
  if position($p$if not found then return 'closed'; end if;$p$ in d) = 0 then raise exception 'FAIL #41 reassigning a closed callback'; end if;
  d := pg_get_functiondef((select oid from pg_proc where proname = 'zella_erase_customer'));
  if position('update public.appointments set description = null' in d) = 0 or position('customer_requests' in d) = 0 then raise exception 'FAIL #41 erase leaves appointment, task or request text'; end if;
  d := pg_get_functiondef((select oid from pg_proc where proname = 'zella_language_allowance'));
  if position($p$zella_has_role(p_business_id, array['owner','admin','manager','staff','viewer'])$p$ in d) = 0 then raise exception 'FAIL #41 language allowance readable by non-members'; end if;
  d := pg_get_functiondef((select oid from pg_proc where proname = 'zella_decide_time_off'));
  if position('where id = p_request_id for update' in d) = 0 then raise exception 'FAIL #41 time-off decision not locked'; end if;
  d := pg_get_functiondef((select oid from pg_proc where proname = 'zella_offboard_member'));
  if position('TARGET_NOT_ACTIVE' in d) = 0 then raise exception 'FAIL #41 offboarding can reassign to an inactive member'; end if;
  d := pg_get_functiondef((select oid from pg_proc where proname = 'zella_public_status'));
  if position($p$'title', i.title$p$ in d) > 0 then raise exception 'FAIL #41 public status shows internal incident titles'; end if;
  d := pg_get_functiondef((select oid from pg_proc where proname = 'zella_check_uptime'));
  if position('greatest(v_last, v_since)' in d) = 0 then raise exception 'FAIL #41 uptime uses the older of the two times'; end if;
end $$;
-- a non-member cannot read a business's language allowance
do $$ begin
  set local role anon;
  begin perform public.zella_language_allowance((select id from public.businesses limit 1));
    raise exception 'FAIL #41 anon read the language allowance';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  reset role;
end $$;
select 'PASS #41 offer key lock, closed callbacks, erase scrubs more, allowance needs a role, time-off lock, offboard target, public status hides titles, uptime age';

rollback;
