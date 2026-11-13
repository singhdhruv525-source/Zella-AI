-- Billing step 2 checks (tests/billing/run.sh). Synthetic test data only, in a throwaway isolated database. The plan
-- values below are test values, not Zella Voice prices; pack prices are the fixed list prices of §17.3.
\set ON_ERROR_STOP 1
set client_min_messages = notice; reset role;
select set_config('request.jwt.claims', '', false);

-- businesses A (monthly), B (small texts plan), C (rollover), D (yearly), E (trial), X (another tenant)
insert into businesses (id, name, industry_id, timezone, is_active, onboarding_status)
select v.id::uuid, v.name, i.id, 'UTC', true, 'active' from (values
  ('b1000000-0000-4000-8000-00000000000a', 'Billing A'), ('b1000000-0000-4000-8000-00000000000b', 'Billing B'),
  ('b1000000-0000-4000-8000-00000000000c', 'Billing C'), ('b1000000-0000-4000-8000-00000000000d', 'Billing D'),
  ('b1000000-0000-4000-8000-00000000000e', 'Billing E'), ('b1000000-0000-4000-8000-0000000000ff', 'Billing X')) v(id, name)
  join industries i on i.slug = 'dental';
insert into auth.users (id, email, email_confirmed_at) values
  ('b1300000-0000-4000-8000-000000000001', 'owner-a@billing.test', now()), ('b1300000-0000-4000-8000-000000000002', 'staff-a@billing.test', now()),
  ('b1300000-0000-4000-8000-000000000003', 'owner-x@billing.test', now()), ('b1300000-0000-4000-8000-000000000009', 'billing-admin@billing.test', now()),
  ('b1300000-0000-4000-8000-000000000008', 'support-admin@billing.test', now());
insert into business_members (business_id, user_id, role, status) values
  ('b1000000-0000-4000-8000-00000000000a', 'b1300000-0000-4000-8000-000000000001', 'owner', 'active'),
  ('b1000000-0000-4000-8000-00000000000a', 'b1300000-0000-4000-8000-000000000002', 'staff', 'active'),
  ('b1000000-0000-4000-8000-0000000000ff', 'b1300000-0000-4000-8000-000000000003', 'owner', 'active');
insert into auth.identities (user_id, provider, email, identity_data) values
  ('b1300000-0000-4000-8000-000000000009', 'email', 'billing-admin@billing.test', '{"email": "billing-admin@billing.test", "email_verified": true}'),
  ('b1300000-0000-4000-8000-000000000008', 'email', 'support-admin@billing.test', '{"email": "support-admin@billing.test", "email_verified": true}');
insert into platform_admins (user_id, role, is_active) values ('b1300000-0000-4000-8000-000000000009', 'super_admin', true),
  ('b1300000-0000-4000-8000-000000000008', 'support_admin', true);
delete from platform_role_permissions where role = 'support_admin' and permission like 'billing.%';

create function pg_temp.as_user(u text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'aal', 'aal2')::text, false) $$;
create function pg_temp.plan(minutes int, texts int, emails int, price bigint, iv text default 'monthly', trial boolean default false) returns jsonb language sql as $$
  select jsonb_build_object('tier', 'base', 'billing_interval', iv, 'price_cents', price, 'setup_fee_cents', 0, 'minutes', minutes, 'texts', texts,
    'emails', emails, 'team_seats', 2, 'phone_numbers', 1, 'locations', 1, 'languages', jsonb_build_array('en'), 'trial_enabled', trial) $$;
create function pg_temp.acks() returns jsonb language sql as $$
  select '{"costs_not_configured": "Test database: no unit costs", "price_zero": "Test plan", "loss": "Test plan", "below_target_margin": "Test plan", "minutes_high": "Test plan"}'::jsonb $$;
-- a billing admin saves a plan (any warnings acknowledged)
create function pg_temp.save(b text, v jsonb, k text) returns jsonb language plpgsql as $$
declare r jsonb; begin
  perform pg_temp.as_user('b1300000-0000-4000-8000-000000000009');
  r := public.zella_admin_plan_save(b::uuid, v, pg_temp.acks(), k);
  perform set_config('request.jwt.claims', '', false);
  return r;
end $$;
create function pg_temp.bal(b text, r text) returns jsonb language sql as $$ select public.zella_billing_balance(b::uuid, r) $$;
create function pg_temp.sms(b text, body text, meta jsonb default '{}', st text default 'sent') returns uuid language sql as $$
  insert into sms_messages (business_id, direction, status, to_number, message_body, metadata, sent_at)
  values (b::uuid, 'outbound', st, '+15550009999', body, meta, now()) returning id $$;
create function pg_temp.call(b text, ext text, secs int) returns uuid language sql as $$
  insert into calls (business_id, direction, status, external_call_id, from_number, started_at, answered_at, ended_at, duration_seconds, ai_handled)
  values (b::uuid, 'inbound', 'completed', ext, '+15550001111', now() - interval '1 hour', now() - interval '1 hour', now() - interval '1 hour' + make_interval(secs => secs), secs, true)
  returning id $$;

-- 1. Who may do what --------------------------------------------------------------------------------------------
do $$ begin
  perform pg_temp.as_user('b1300000-0000-4000-8000-000000000001');
  begin perform public.zella_admin_plan_save('b1000000-0000-4000-8000-00000000000a', pg_temp.plan(500, 1000, 10000, 29900), pg_temp.acks(), 'owner-try-1');
    raise exception 'an owner set their own plan'; exception when raise_exception then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end;
  perform pg_temp.as_user('b1300000-0000-4000-8000-000000000008');
  begin perform public.zella_admin_plan_save('b1000000-0000-4000-8000-00000000000a', pg_temp.plan(500, 1000, 10000, 29900), pg_temp.acks(), 'support-try-1');
    raise exception 'an admin without billing.manage set a plan'; exception when raise_exception then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end;
  perform set_config('request.jwt.claims', '', false);
  raise notice 'PASS only a billing admin (billing.manage) can set a plan: the business owner and a support admin are refused';
end $$;

-- 2. Plan checks and versions (REQ-BIL-55/56/57) -------------------------------------------------------------------
do $$ declare r jsonb; v1 jsonb; begin
  r := public.zella_plan_evaluate(pg_temp.plan(500, 1000, 10000, 29900) || '{"tier": "gold", "languages": ["fr"], "team_seats": 0}');
  assert r ->> 'ok' = 'false' and r -> 'errors' @> '["tier", "languages", "team_seats"]', 'bad values accepted: ' || r::text;
  r := public.zella_plan_evaluate(pg_temp.plan(20000, 1000, 10000, 0));
  assert (select array_agg(x ->> 'code' order by x ->> 'code') from jsonb_array_elements(r -> 'warnings') x) = array['costs_not_configured', 'minutes_high', 'price_zero'],
    'warnings: ' || (r -> 'warnings')::text;
  -- with unit costs (test values) the margin is computed: cost = 500 x 10 + 1000 x 1 + 10000 x 0.1 + 1 x 115 + 1 x 400 = 7515 cents
  insert into platform_settings (key, value) values ('billing_rules', '{"unit_costs": {"sms_part": 1, "email": 0.1, "phone_number_month": 115, "texting_registration_month": 400}}')
    on conflict (key) do update set value = excluded.value;
  insert into voice_pricing (provider, unit_cost, effective_from) values ('vapi', 0.10, now() - interval '1 day');
  r := public.zella_plan_evaluate(pg_temp.plan(500, 1000, 10000, 29900));
  assert r #>> '{estimate,monthly_cost_cents}' = '7515' and (r #>> '{estimate,margin_percent}')::numeric = 74.9 and jsonb_array_length(r -> 'warnings') = 0, 'margin: ' || r::text;
  r := public.zella_plan_evaluate(pg_temp.plan(500, 1000, 10000, 5000));
  assert r -> 'warnings' @> '[{"code": "loss", "level": "red"}]', 'no loss warning: ' || r::text;
  r := public.zella_plan_evaluate(pg_temp.plan(500, 1000, 10000, 15000));
  assert r -> 'warnings' @> '[{"code": "below_target_margin"}]', 'no target warning: ' || r::text;
  r := public.zella_plan_evaluate(pg_temp.plan(500, 1000, 10000, 29900, 'yearly'));
  assert r #>> '{estimate,monthly_revenue_cents}' = '2492', 'a yearly price is not one twelfth: ' || r::text;
  raise notice 'PASS plan checks: bad values refused; profit (cost, revenue, margin; yearly as one twelfth), loss and below-target warnings, more than 10,000 minutes, $0 price, unknown unit costs reported and never guessed';

  perform pg_temp.as_user('b1300000-0000-4000-8000-000000000009');
  begin perform public.zella_admin_plan_save('b1000000-0000-4000-8000-00000000000a', pg_temp.plan(500, 1000, 10000, 5000), '{}', 'plan-a-loss-1');
    raise exception 'a loss-making plan saved without a reason'; exception when raise_exception then if sqlerrm <> 'WARNING_NOT_ACKNOWLEDGED' then raise; end if; end;
  begin perform public.zella_admin_plan_save('b1000000-0000-4000-8000-00000000000a', pg_temp.plan(500, 1000, 10000, 5000), '{"loss": "ok"}', 'plan-a-loss-1');
    raise exception 'a 2-character reason accepted'; exception when raise_exception then if sqlerrm <> 'WARNING_NOT_ACKNOWLEDGED' then raise; end if; end;
  v1 := public.zella_admin_plan_save('b1000000-0000-4000-8000-00000000000a', pg_temp.plan(500, 1000, 10000, 29900), '{}', 'plan-a-version-1');
  assert v1 ->> 'result' = 'saved' and v1 ->> 'version' = '1', 'v1: ' || v1::text;
  r := public.zella_admin_plan_save('b1000000-0000-4000-8000-00000000000a', pg_temp.plan(500, 1000, 10000, 29900), '{}', 'plan-a-version-1');
  assert r ->> 'result' = 'duplicate' and r ->> 'plan_id' = v1 ->> 'plan_id', 'retry made a second version: ' || r::text;
  begin perform public.zella_admin_plan_save('b1000000-0000-4000-8000-00000000000a', pg_temp.plan(600, 1000, 10000, 29900), '{}', 'plan-a-version-1');
    raise exception 'the same key saved different values'; exception when raise_exception then if sqlerrm <> 'IDEMPOTENCY_CONFLICT' then raise; end if; end;
  perform set_config('request.jwt.claims', '', false);
  assert (select count(*) from audit_logs where action = 'billing.plan_saved' and entity_id = (v1 ->> 'plan_id')::uuid) = 1, 'no audit record';
  begin update business_plans set price_cents = 1 where id = (v1 ->> 'plan_id')::uuid; raise exception 'a plan version was edited';
  exception when raise_exception then if sqlerrm not like 'IMMUTABLE%' then raise; end if; end;
  raise notice 'PASS plans: a warning needs a written reason; saving makes version 1 with an audit record; a retry with the same key returns it; the same key with other values is refused; a version is never edited';
end $$;

-- the other plans (test values)
select pg_temp.save('b1000000-0000-4000-8000-00000000000b', pg_temp.plan(100, 20, 40, 9900), 'plan-b-version-1');
select pg_temp.save('b1000000-0000-4000-8000-00000000000c', pg_temp.plan(500, 1000, 10000, 29900), 'plan-c-version-1');
select pg_temp.save('b1000000-0000-4000-8000-00000000000d', pg_temp.plan(300, 500, 5000, 299000, 'yearly'), 'plan-d-version-1');
select pg_temp.save('b1000000-0000-4000-8000-00000000000e', pg_temp.plan(500, 1000, 10000, 29900, 'monthly', true), 'plan-e-version-1');
select pg_temp.save('b1000000-0000-4000-8000-0000000000ff', pg_temp.plan(500, 1000, 10000, 29900), 'plan-x-version-1');
-- subscriptions without a shared plan (plan_id is empty); periods started yesterday
insert into subscriptions (business_id, plan_id, status, billing_interval, current_period_start, current_period_end)
select v.b::uuid, null, 'active', 'monthly', date_trunc('day', now()) - interval '1 day', date_trunc('day', now()) - interval '1 day' + interval '1 month'
  from (values ('b1000000-0000-4000-8000-00000000000a'), ('b1000000-0000-4000-8000-00000000000b'), ('b1000000-0000-4000-8000-0000000000ff')) v(b);

-- 3. Data stays private -------------------------------------------------------------------------------------------
do $$ begin
  perform pg_temp.as_user('b1300000-0000-4000-8000-000000000001');
  assert public.zella_billing_overview('b1000000-0000-4000-8000-00000000000a') #>> '{plan,price_cents}' = '29900', 'owner cannot see their plan';
  perform pg_temp.as_user('b1300000-0000-4000-8000-000000000002');
  begin perform public.zella_billing_overview('b1000000-0000-4000-8000-00000000000a'); raise exception 'staff saw the price';
  exception when raise_exception then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end;
  perform pg_temp.as_user('b1300000-0000-4000-8000-000000000003');
  begin perform public.zella_billing_overview('b1000000-0000-4000-8000-00000000000a'); raise exception 'another business''s owner saw it';
  exception when raise_exception then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end;
  perform pg_temp.as_user('b1300000-0000-4000-8000-000000000009');
  assert public.zella_billing_overview('b1000000-0000-4000-8000-00000000000a') ? 'usage', 'billing admin cannot see it';
  perform set_config('request.jwt.claims', '', false);
  raise notice 'PASS the Billing & Subscription data: the business owner and billing admins only (not staff, not another business)';
end $$;
select pg_temp.as_user('b1300000-0000-4000-8000-000000000001');
set role authenticated;
do $$ declare t text; begin
  foreach t in array array['business_plans', 'billing_periods', 'allowance_buckets', 'usage_charges', 'pack_purchases', 'auto_reload_settings', 'billing_pack_catalog'] loop
    begin execute format('select count(*) from public.%I', t); raise exception 'signed-in user read %', t;
    exception when insufficient_privilege then null; end;
  end loop;
  begin perform public.zella_usage_consume('b1000000-0000-4000-8000-00000000000a', 'minutes', 1, 'forged-key-1', 'call', null); raise exception 'a signed-in user subtracted usage';
  exception when insufficient_privilege then null; end;
  begin perform public.zella_plan_evaluate('{}'); raise exception 'an owner read the cost estimate';
  exception when raise_exception then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end;
  assert (select count(*) from public.plans) = 0, 'shared plans readable';
end $$;
reset role;
set role anon;
do $$ begin
  begin perform count(*) from public.plans; raise exception 'anon read plans'; exception when insufficient_privilege then null; end;
  begin perform public.zella_plan_evaluate('{}'); raise exception 'anon ran the plan check'; exception when insufficient_privilege then null; end;
end $$;
reset role;
select set_config('request.jwt.claims', '', false);
do $$ begin raise notice 'PASS signed-in users cannot read or write the billing tables, subtract usage directly or see the cost estimate (unit costs); anonymous visitors cannot read plans'; end $$;

-- 4. A monthly period: plan balances and the 5% buffer -----------------------------------------------------------
do $$ declare m jsonb; t jsonb; e jsonb; begin
  m := pg_temp.bal('b1000000-0000-4000-8000-00000000000a', 'minutes');
  t := pg_temp.bal('b1000000-0000-4000-8000-00000000000a', 'texts');
  e := pg_temp.bal('b1000000-0000-4000-8000-00000000000a', 'emails');
  assert m ->> 'included' = '500' and t ->> 'included' = '1000' and t ->> 'buffer' = '50' and e ->> 'buffer' = '500' and (m ->> 'buffer')::numeric = 0,
    'balances: ' || m::text || t::text || e::text;
  perform public.zella_billing_open_period('b1000000-0000-4000-8000-00000000000a', now());
  perform public.zella_billing_open_period('b1000000-0000-4000-8000-00000000000a', now());
  assert (select count(*) from billing_periods where business_id = 'b1000000-0000-4000-8000-00000000000a') = 1
     and (select count(*) from allowance_buckets where business_id = 'b1000000-0000-4000-8000-00000000000a') = 5, 'period opened twice';
  raise notice 'PASS a month opens once with the plan''s 500 minutes, 1,000 texts and 10,000 emails, plus a 5%% buffer of 50 texts and 500 emails (none for minutes)';
end $$;

-- 5. Calls (REQ-BIL-14) -------------------------------------------------------------------------------------------
do $$ declare c1 uuid; c2 uuid; c3 uuid; begin
  c1 := pg_temp.call('b1000000-0000-4000-8000-00000000000a', 'bill-call-1', 95);     -- 2 minutes
  c2 := pg_temp.call('b1000000-0000-4000-8000-00000000000a', 'bill-call-2', 10);     -- under 15 s: not counted
  update calls set outcome = 'spam' where external_call_id = 'bill-call-x';
  c3 := pg_temp.call('b1000000-0000-4000-8000-00000000000a', 'bill-call-3', 61);     -- 2 minutes, later marked spam
  assert pg_temp.bal('b1000000-0000-4000-8000-00000000000a', 'minutes') ->> 'used' = '4', 'used: ' || pg_temp.bal('b1000000-0000-4000-8000-00000000000a', 'minutes')::text;
  perform public.zella_process_call_usage(c1, 'event'); perform public.zella_billing_charge_call(c1);
  assert pg_temp.bal('b1000000-0000-4000-8000-00000000000a', 'minutes') ->> 'used' = '4', 'counted twice';
  update calls set duration_seconds = 185 where id = c1;      -- the provider reports a longer call: 4 minutes
  assert pg_temp.bal('b1000000-0000-4000-8000-00000000000a', 'minutes') ->> 'used' = '6', 'adjustment not counted: ' || pg_temp.bal('b1000000-0000-4000-8000-00000000000a', 'minutes')::text;
  update calls set outcome = 'spam' where id = c3;             -- marked as spam afterwards: given back
  assert pg_temp.bal('b1000000-0000-4000-8000-00000000000a', 'minutes') ->> 'used' = '4', 'spam not given back: ' || pg_temp.bal('b1000000-0000-4000-8000-00000000000a', 'minutes')::text;
  update calls set outcome = null where id = c3;               -- and back again: subtracted again, with a new key
  assert pg_temp.bal('b1000000-0000-4000-8000-00000000000a', 'minutes') ->> 'used' = '6', 'flip back not counted';
  update calls set outcome = 'spam' where id = c3;
  assert pg_temp.bal('b1000000-0000-4000-8000-00000000000a', 'minutes') ->> 'used' = '4', 'second spam not given back';
  assert (select count(*) from usage_charges where source_id = c2) = 0, 'a 10-second call was charged';
  raise notice 'PASS calls: rounded up to whole minutes (95 s = 2); under 15 s not counted; a repeat never counts twice; a longer reported duration adds the difference; a call marked spam is given back (and every later change is counted once)';
end $$;

-- 6. Texts and emails (REQ-BIL-15/16) -----------------------------------------------------------------------------
do $$ declare s1 uuid; begin
  perform pg_temp.sms('b1000000-0000-4000-8000-00000000000a', 'Your quote is ready.');                         -- 1 part
  perform pg_temp.sms('b1000000-0000-4000-8000-00000000000a', repeat('a', 200));                                -- 2 parts
  perform pg_temp.sms('b1000000-0000-4000-8000-00000000000a', 'Hola, su cita está confirmada ' || repeat('x', 50)); -- accented, 80 chars: 2 parts
  perform pg_temp.sms('b1000000-0000-4000-8000-00000000000a', 'Staff alert', '{"staff_alert": "true"}');       -- to the business's own staff: not counted
  perform pg_temp.sms('b1000000-0000-4000-8000-00000000000a', 'Blocked', '{}', 'blocked');                      -- never sent
  s1 := pg_temp.sms('b1000000-0000-4000-8000-00000000000a', 'Queued first', '{}', 'queued');
  update sms_messages set status = 'sent' where id = s1;
  update sms_messages set status = 'delivered' where id = s1;
  assert pg_temp.bal('b1000000-0000-4000-8000-00000000000a', 'texts') ->> 'used' = '6', 'texts: ' || pg_temp.bal('b1000000-0000-4000-8000-00000000000a', 'texts')::text;
  insert into email_messages (business_id, direction, status, to_email, subject, body_text, sent_at) values
    ('b1000000-0000-4000-8000-00000000000a', 'outbound', 'sent', 'c@example.test', 'Hi', 'Hello', now()),
    ('b1000000-0000-4000-8000-00000000000a', 'outbound', 'sent', 'c@example.test', 'Owner', 'x', now());
  update email_messages set metadata = '{"dedupe_key": "notif:abc:c@example.test"}' where subject = 'Owner';
  assert pg_temp.bal('b1000000-0000-4000-8000-00000000000a', 'emails') ->> 'used' = '2', 'emails: ' || pg_temp.bal('b1000000-0000-4000-8000-00000000000a', 'emails')::text;
  raise notice 'PASS texts count by part (160 / 70 characters; 153 / 67 per part when longer), once when sent (not when blocked, not again when delivered); alerts to the business''s own staff are not counted; emails count one each';
end $$;

-- 7. At 100%: the buffer and the checks (D-43, REQ-BIL-22) ---------------------------------------------------------
do $$ declare i int; r jsonb; late uuid; begin
  -- business B: 20 texts, buffer 1 (5%)
  for i in 1..16 loop perform pg_temp.sms('b1000000-0000-4000-8000-00000000000b', 'Follow-up ' || i); end loop;
  assert exists (select 1 from usage_threshold_events where business_id = 'b1000000-0000-4000-8000-00000000000b' and threshold_key = 'texts:pct:80'), 'no 80% alert';
  for i in 17..20 loop perform pg_temp.sms('b1000000-0000-4000-8000-00000000000b', 'Follow-up ' || i); end loop;
  assert exists (select 1 from usage_threshold_events where business_id = 'b1000000-0000-4000-8000-00000000000b' and threshold_key = 'texts:pct:100'), 'no 100% alert';
  assert (select count(*) from usage_threshold_events where business_id = 'b1000000-0000-4000-8000-00000000000b' and resource = 'texts') = 2, 'alerts repeated';
  assert (select count(*) from staff_notifications where business_id = 'b1000000-0000-4000-8000-00000000000b' and kind = 'usage_threshold') = 2, 'owner not notified';
  r := public.zella_message_allowance('b1000000-0000-4000-8000-00000000000b', 'sms', 'routine');
  assert r ->> 'would_permit' = 'false' and r ->> 'reason' = 'allowance_used', 'routine at 100%: ' || r::text;
  r := public.zella_message_allowance('b1000000-0000-4000-8000-00000000000b', 'sms', 'appointment');
  assert r ->> 'would_permit' = 'true' and r ->> 'reason' = 'buffer', 'reminder at 100%: ' || r::text;
  perform pg_temp.sms('b1000000-0000-4000-8000-00000000000b', 'Reminder: tomorrow 10am', '{"dedupe_key": "reminder:00000000-0000-0000-0000-000000000001"}');
  r := public.zella_message_allowance('b1000000-0000-4000-8000-00000000000b', 'sms', 'appointment');
  assert r ->> 'would_permit' = 'false', 'buffer not used up: ' || r::text;
  assert (select used from allowance_buckets k join billing_periods p on p.id = k.period_id where p.business_id = 'b1000000-0000-4000-8000-00000000000b' and k.resource = 'texts' and k.kind = 'buffer') = 1,
    'reminder did not use the buffer';
  -- a routine text sent anyway (the claims are not wired yet) never takes the buffer: it is recorded as over
  late := pg_temp.sms('b1000000-0000-4000-8000-00000000000b', 'Late follow-up');
  assert (select over_quantity from usage_charges where source_id = late) = 1, 'not recorded as over';
  raise notice 'PASS at 80%% and at 100%% the owner is alerted once each; at 100%% routine texts would stop while reminders use the 5%% buffer, then stop too; anything sent over is recorded, never hidden';
end $$;

-- minutes at 80% and 100% (the existing minute alerts, now from the balances); no 70% or 90% alert any more
do $$ declare c uuid; r jsonb; begin
  c := pg_temp.call('b1000000-0000-4000-8000-00000000000b', 'bill-call-b1', 85 * 60);
  assert exists (select 1 from usage_threshold_events where business_id = 'b1000000-0000-4000-8000-00000000000b' and threshold_key = 'pct:80' and resource = 'minutes'), 'no minute 80% alert';
  assert not exists (select 1 from usage_threshold_events where business_id = 'b1000000-0000-4000-8000-00000000000b' and threshold_key in ('pct:70', 'pct:90')), 'old levels used';
  c := pg_temp.call('b1000000-0000-4000-8000-00000000000b', 'bill-call-b2', 20 * 60);   -- a call in progress is never cut: 5 minutes over
  r := pg_temp.bal('b1000000-0000-4000-8000-00000000000b', 'minutes');
  assert r ->> 'over' = '5' and r ->> 'exhausted' = 'true' and exists (select 1 from usage_threshold_events where business_id = 'b1000000-0000-4000-8000-00000000000b' and threshold_key = 'pct:100'), 'minutes at 100%: ' || r::text;
  r := public.zella_call_entitlement_check('b1000000-0000-4000-8000-00000000000b');
  assert r ->> 'status' = 'exhausted' and r ->> 'would_permit' = 'false' and r ->> 'enforced' = 'false', 'entitlement: ' || r::text;
  perform pg_temp.as_user('b1300000-0000-4000-8000-000000000001');
  assert (public.zella_usage_preferences('b1000000-0000-4000-8000-00000000000a') -> 'notify_thresholds') = '[80, 100]', 'preferences still show the old levels';
  perform set_config('request.jwt.claims', '', false);
  raise notice 'PASS minutes alert at 80%% and 100%% only; over 100%% the extra minutes are recorded; the call check reports "exhausted" (going to the fallback number is not switched on: a live change)';
end $$;

-- 8. Rollover: the owner's example (500-minute plan, 380 used: next month 500 + 100) ------------------------------
do $$ declare t0 timestamptz := date_trunc('day', now()) - interval '40 days'; r jsonb; p1 uuid; begin
  insert into subscriptions (business_id, plan_id, status, billing_interval, current_period_start, current_period_end)
  values ('b1000000-0000-4000-8000-00000000000c', null, 'active', 'monthly', t0, t0 + interval '1 month');
  perform public.zella_billing_open_period('b1000000-0000-4000-8000-00000000000c', t0 + interval '1 hour');
  select id into p1 from billing_periods where business_id = 'b1000000-0000-4000-8000-00000000000c';
  perform public.zella_usage_consume('b1000000-0000-4000-8000-00000000000c', 'minutes', 380, 'test-c-usage-380', 'admin', null, null, t0 + interval '2 days');
  perform public.zella_usage_consume('b1000000-0000-4000-8000-00000000000c', 'texts', 10, 'test-c-texts-10', 'admin', null, 'routine', t0 + interval '2 days');
  -- a 100-minute pack, granted in that month and unused
  insert into pack_purchases (business_id, pack_code, resource, quantity, price_cents, status, source, reason, period_id, idempotency_key, purchased_at)
  values ('b1000000-0000-4000-8000-00000000000c', 'minutes_100', 'minutes', 100, 2900, 'granted', 'admin_grant', 'Test grant', p1, 'test-c-pack-1', t0 + interval '3 days');
  insert into allowance_buckets (business_id, period_id, resource, kind, pack_purchase_id, granted, expires_at)
  select 'b1000000-0000-4000-8000-00000000000c', p1, 'minutes', 'pack', id, 100, t0 + interval '1 month' from pack_purchases where idempotency_key = 'test-c-pack-1';
  -- the monthly charge succeeded: the provider moves the period on
  update subscriptions set current_period_start = t0 + interval '1 month', current_period_end = t0 + interval '2 months' where business_id = 'b1000000-0000-4000-8000-00000000000c';
  r := pg_temp.bal('b1000000-0000-4000-8000-00000000000c', 'minutes');
  assert r ->> 'included' = '500', 'before opening: ' || r::text;
  perform public.zella_billing_open_period('b1000000-0000-4000-8000-00000000000c', now());
  r := pg_temp.bal('b1000000-0000-4000-8000-00000000000c', 'minutes');
  assert r ->> 'included' = '620', 'rollover: ' || r::text;   -- 500 plan + 100 (20% of 500; 120 unused) + 20 (20% of the unused 100-minute pack)
  assert (select array_agg(k.granted::int order by k.granted) from allowance_buckets k join billing_periods p on p.id = k.period_id
           where p.business_id = 'b1000000-0000-4000-8000-00000000000c' and p.period_start = t0 + interval '1 month' and k.kind = 'rollover') = array[20, 100], 'rollover buckets';
  assert pg_temp.bal('b1000000-0000-4000-8000-00000000000c', 'texts') ->> 'included' = '1000', 'texts rolled over';
  -- a call from last month processed late is counted in last month, and this month's rollover comes down with it
  r := public.zella_usage_consume('b1000000-0000-4000-8000-00000000000c', 'minutes', 50, 'test-c-late-50', 'admin', null, null, t0 + interval '5 days');
  assert r ->> 'result' = 'recorded' and (r ->> 'period_id')::uuid = p1, 'late usage not in last month: ' || r::text;
  assert pg_temp.bal('b1000000-0000-4000-8000-00000000000c', 'minutes') ->> 'included' = '590', 'rollover not reduced: ' || pg_temp.bal('b1000000-0000-4000-8000-00000000000c', 'minutes')::text;
  -- rolled-over minutes are used first, and expire with this month
  perform public.zella_usage_consume('b1000000-0000-4000-8000-00000000000c', 'minutes', 110, 'test-c-usage-110', 'admin', null);
  assert (select string_agg(k.kind || '/' || (k.pack_purchase_id is not null) || '=' || k.used::int, ',' order by public.zella_billing_bucket_rank(k.kind, k.pack_purchase_id is not null))
            from allowance_buckets k join billing_periods p on p.id = k.period_id
           where p.business_id = 'b1000000-0000-4000-8000-00000000000c' and p.period_start = t0 + interval '1 month' and k.resource = 'minutes') = 'rollover/false=70,rollover/true=20,plan/false=20',
    'order of use';
  raise notice 'PASS rollover: 500 minutes with 380 used starts the next month with 500 + 100 (20%% cap; the other 20 expire), an unused 100-minute pack adds 20; texts do not roll over; a late call from last month is counted there and lowers this month''s rollover (100 to 70); rolled-over minutes are used first';
end $$;

-- 9. Yearly plans reset monthly, on the same day (D-46) -------------------------------------------------------------
do $$ declare b jsonb; begin
  insert into subscriptions (business_id, plan_id, status, billing_interval, current_period_start, current_period_end)
  values ('b1000000-0000-4000-8000-00000000000d', null, 'active', 'yearly', '2026-01-31 00:00+00', '2027-01-31 00:00+00');
  b := public.zella_billing_period_bounds('b1000000-0000-4000-8000-00000000000d', '2026-02-15 12:00+00');
  assert (b ->> 'from')::timestamptz = '2026-01-31 00:00+00' and (b ->> 'to')::timestamptz = '2026-02-28 00:00+00', 'Feb: ' || b::text;
  b := public.zella_billing_period_bounds('b1000000-0000-4000-8000-00000000000d', '2026-03-05 12:00+00');
  assert (b ->> 'from')::timestamptz = '2026-02-28 00:00+00' and (b ->> 'to')::timestamptz = '2026-03-31 00:00+00', 'Mar: ' || b::text;
  b := public.zella_billing_period_bounds('b1000000-0000-4000-8000-00000000000d', '2027-01-15 12:00+00');
  assert (b ->> 'from')::timestamptz = '2026-12-31 00:00+00' and (b ->> 'to')::timestamptz = '2027-01-31 00:00+00', 'Jan: ' || b::text;
  assert public.zella_billing_period_bounds('b1000000-0000-4000-8000-00000000000d', '2027-02-01 00:00+00') is null, 'after the paid year';
  perform public.zella_usage_consume('b1000000-0000-4000-8000-00000000000d', 'minutes', 300, 'test-d-feb-300', 'admin', null, null, '2026-02-15 12:00+00');
  perform public.zella_usage_consume('b1000000-0000-4000-8000-00000000000d', 'minutes', 10, 'test-d-mar-10', 'admin', null, null, '2026-03-05 12:00+00');
  assert (select sum(granted) from allowance_buckets k join billing_periods p on p.id = k.period_id where p.business_id = 'b1000000-0000-4000-8000-00000000000d'
           and p.period_start = '2026-02-28 00:00+00' and k.resource = 'minutes') = 300, 'March refresh';
  -- April has no activity at all; May still gets April's unused minutes (20% of 300)
  perform public.zella_usage_consume('b1000000-0000-4000-8000-00000000000d', 'minutes', 1, 'test-d-may-1', 'admin', null, null, '2026-05-10 12:00+00');
  assert (select count(*) from billing_periods where business_id = 'b1000000-0000-4000-8000-00000000000d' and period_start = '2026-04-30 00:00+00') = 1
     and (select granted from allowance_buckets k join billing_periods p on p.id = k.period_id where p.business_id = 'b1000000-0000-4000-8000-00000000000d'
            and p.period_start = '2026-04-30 00:00+00' and k.kind = 'rollover') = 60
     and (select granted from allowance_buckets k join billing_periods p on p.id = k.period_id where p.business_id = 'b1000000-0000-4000-8000-00000000000d'
            and p.period_start = '2026-05-31 00:00+00' and k.kind = 'rollover') is null, 'idle month rollover';
  raise notice 'PASS yearly plans: charged for the year, minutes reset every month on the same day (31 Jan, 28 Feb, 31 Mar ... 31 Dec), nothing after the paid year, and a quiet month still rolls its unused minutes into the next';
end $$;

-- 10. Trial (REQ-BIL-11) ------------------------------------------------------------------------------------------
do $$ declare m jsonb; t jsonb; begin
  insert into subscriptions (business_id, plan_id, status, trial_start_at, trial_end_at) values ('b1000000-0000-4000-8000-00000000000e', null, 'trial', now() - interval '1 day', now() + interval '4 days');
  m := pg_temp.bal('b1000000-0000-4000-8000-00000000000e', 'minutes'); t := pg_temp.bal('b1000000-0000-4000-8000-00000000000e', 'texts');
  assert m ->> 'included' = '20' and t ->> 'included' = '5' and (t ->> 'buffer')::numeric = 0 and pg_temp.bal('b1000000-0000-4000-8000-00000000000e', 'emails') ->> 'included' = '5'
     and m ->> 'trial' = 'true', 'trial: ' || m::text || t::text;
  raise notice 'PASS the 5-day trial has 20 minutes, 5 texts and 5 emails, whatever the plan, with no buffer';
end $$;

-- 11. Packs and auto-reload --------------------------------------------------------------------------------------
do $$ declare r jsonb; begin
  perform pg_temp.as_user('b1300000-0000-4000-8000-000000000001');
  begin perform public.zella_admin_pack_grant('b1000000-0000-4000-8000-00000000000a', 'minutes_100', 'Free minutes please', 'owner-grant-1'); raise exception 'owner granted a pack';
  exception when raise_exception then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end;
  perform pg_temp.as_user('b1300000-0000-4000-8000-000000000009');
  begin perform public.zella_admin_pack_grant('b1000000-0000-4000-8000-00000000000a', 'minutes_100', '', 'admin-grant-1'); raise exception 'no reason';
  exception when raise_exception then if sqlerrm <> 'REASON_REQUIRED' then raise; end if; end;
  r := public.zella_admin_pack_grant('b1000000-0000-4000-8000-00000000000a', 'minutes_250', 'Outage credit (test)', 'admin-grant-1');
  assert r ->> 'result' = 'granted', 'grant: ' || r::text;
  assert public.zella_admin_pack_grant('b1000000-0000-4000-8000-00000000000a', 'minutes_250', 'Outage credit (test)', 'admin-grant-1') ->> 'result' = 'duplicate', 'granted twice';
  assert pg_temp.bal('b1000000-0000-4000-8000-00000000000a', 'minutes') ->> 'included' = '750', 'pack not added';
  assert exists (select 1 from audit_logs where action = 'billing.pack_granted' and new_data ->> 'charged' = 'false'), 'no audit';
  -- auto-reload: the owner only; the cap must allow at least one pack; stored, not active
  perform pg_temp.as_user('b1300000-0000-4000-8000-000000000002');
  begin perform public.zella_auto_reload_save('b1000000-0000-4000-8000-00000000000a', 'minutes', true, 10, 'minutes_100', 10000); raise exception 'staff set auto-reload';
  exception when raise_exception then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end;
  perform pg_temp.as_user('b1300000-0000-4000-8000-000000000001');
  begin perform public.zella_auto_reload_save('b1000000-0000-4000-8000-00000000000a', 'minutes', true, 10, 'minutes_100', 1000); raise exception 'cap below one pack';
  exception when raise_exception then if sqlerrm <> 'BAD_INPUT' then raise; end if; end;
  begin perform public.zella_auto_reload_save('b1000000-0000-4000-8000-00000000000a', 'minutes', true, 10, 'texts_500', 10000); raise exception 'text pack for minutes';
  exception when raise_exception then if sqlerrm <> 'BAD_INPUT' then raise; end if; end;
  r := public.zella_auto_reload_save('b1000000-0000-4000-8000-00000000000a', 'minutes', true, 10, 'minutes_100', 10000);
  assert r ->> 'active' = 'false', 'auto-reload claims to be active';
  r := public.zella_billing_overview('b1000000-0000-4000-8000-00000000000a');
  assert r -> 'auto_reload' @> '[{"resource": "minutes", "enabled": true}]' and jsonb_array_length(r -> 'packs') = 11
     and r -> 'packs' @> '[{"code": "minutes_500", "price_cents": 14900, "rollover_if_unused": 100}]', 'overview: ' || (r -> 'packs')::text;
  perform set_config('request.jwt.claims', '', false);
  raise notice 'PASS packs: only a billing admin can grant one, with a reason, once per key, audited as not charged; auto-reload is the owner''s choice (cap at least one pack), stored but not active until payments';
end $$;

-- 12. Existing limit checks read the business's own plan ---------------------------------------------------------
do $$ declare e jsonb; begin
  assert public.zella_entitlement_allows('b1000000-0000-4000-8000-00000000000a', 'team_members', 0), 'two seats, two members';
  assert not public.zella_entitlement_allows('b1000000-0000-4000-8000-00000000000a', 'team_members', 1), 'third seat allowed on a two-seat plan';
  perform pg_temp.as_user('b1300000-0000-4000-8000-000000000001');
  e := public.zella_entitlements('b1000000-0000-4000-8000-00000000000a');
  assert e ->> 'plan' = 'custom' and e #>> '{limits,voice_minutes}' = '500' and e ->> 'active' = 'true', 'entitlements: ' || e::text;
  assert public.zella_language_allowance('b1000000-0000-4000-8000-00000000000a') = 1, 'languages';
  perform set_config('request.jwt.claims', '', false);
  raise notice 'PASS team seats, phone numbers and languages come from the business''s own plan (a subscription without a shared plan works)';
end $$;

-- 13. Idempotency and limits of the balances ------------------------------------------------------------------------
do $$ declare r jsonb; begin
  r := public.zella_usage_consume('b1000000-0000-4000-8000-0000000000ff', 'minutes', 5, 'test-x-same-key', 'admin', null);
  assert public.zella_usage_consume('b1000000-0000-4000-8000-0000000000ff', 'minutes', 5, 'test-x-same-key', 'admin', null) ->> 'result' = 'duplicate', 'key reused';
  assert pg_temp.bal('b1000000-0000-4000-8000-0000000000ff', 'minutes') ->> 'used' = '5', 'subtracted twice';
  begin update allowance_buckets set used = granted + 1 where business_id = 'b1000000-0000-4000-8000-0000000000ff'; raise exception 'a balance went below zero';
  exception when check_violation then null; end;
  begin perform public.zella_usage_consume('b1000000-0000-4000-8000-0000000000ff', 'texts', 1, 'test-x-no-kind', 'sms', null); raise exception 'a text without a kind';
  exception when raise_exception then if sqlerrm <> 'BAD_INPUT' then raise; end if; end;
  assert public.zella_usage_consume('b1000000-0000-4000-8000-00000000000e', 'minutes', 1, 'test-e-before', 'admin', null, null, now() - interval '3 days') ->> 'result' = 'not_configured', 'outside any period';
  assert (select count(*) from usage_charges where business_id = 'b1000000-0000-4000-8000-00000000000a' and source_kind = 'call') > 0
     and not exists (select 1 from usage_processing_issues where kind = 'billing_charge_failed'), 'a charge failed';
  raise notice 'PASS the same key never subtracts twice; a balance never goes below zero; usage outside a paid or trial period is not counted against anything';
end $$;

-- 14. A message that could not be counted is counted by the retry (the hourly usage check) ---------------------
alter table sms_messages disable trigger zella_billing_sms_trg;
do $$ declare m uuid; before numeric; begin
  before := (pg_temp.bal('b1000000-0000-4000-8000-0000000000ff', 'texts') ->> 'used')::numeric;
  m := pg_temp.sms('b1000000-0000-4000-8000-0000000000ff', 'Missed by the counter');
  perform public.zella_usage_open_issue('b1000000-0000-4000-8000-0000000000ff', null, 'billing_charge_failed', 'test failure', jsonb_build_object('table', 'sms_messages', 'id', m));
  update usage_processing_issues set next_attempt_at = now() - interval '1 minute' where kind = 'billing_charge_failed';
  assert public.zella_billing_retry_charges(10) = 1, 'retry did nothing';
  assert (pg_temp.bal('b1000000-0000-4000-8000-0000000000ff', 'texts') ->> 'used')::numeric = before + 1
     and exists (select 1 from usage_charges where idempotency_key = 'sms:' || m)
     and not exists (select 1 from usage_processing_issues where kind = 'billing_charge_failed' and status <> 'resolved'), 'not counted on retry';
  assert public.zella_billing_retry_charges(10) = 0, 'retried twice';
  raise notice 'PASS a text the counter missed is listed as a problem and counted once by the hourly retry';
end $$;
alter table sms_messages enable trigger zella_billing_sms_trg;

-- 15. The plan page reads the saved plan (billing admins only) ------------------------------------------------------
do $$ declare r jsonb; begin
  perform pg_temp.as_user('b1300000-0000-4000-8000-000000000009');
  r := public.zella_admin_plan_get('b1000000-0000-4000-8000-00000000000a');
  assert r ->> 'can_edit' = 'true' and r #>> '{plan,version}' = '1' and r #>> '{plan,price_cents}' = '29900' and jsonb_array_length(r -> 'versions') = 1, 'plan get: ' || r::text;
  perform pg_temp.as_user('b1300000-0000-4000-8000-000000000008');
  begin perform public.zella_admin_plan_get('b1000000-0000-4000-8000-00000000000a'); raise exception 'support admin read the plan';
  exception when raise_exception then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end;
  perform pg_temp.as_user('b1300000-0000-4000-8000-000000000001');
  begin perform public.zella_admin_plan_get('b1000000-0000-4000-8000-00000000000a'); raise exception 'owner used the admin plan page';
  exception when raise_exception then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end;
  perform set_config('request.jwt.claims', '', false);
  raise notice 'PASS the plan page reads the saved plan and its versions for billing admins only';
end $$;

-- 16. Text parts as carriers count them, failed calls, the saved-plan check, the hourly opening --------------------
do $$ declare c uuid; before numeric; r jsonb; begin
  assert public.zella_sms_parts(repeat('a', 160)) = 1 and public.zella_sms_parts(repeat('a', 161)) = 2, 'gsm basic';
  assert public.zella_sms_parts(repeat('a', 158) || '[]') = 2, '[ and ] take two places';
  assert public.zella_sms_parts(repeat('é', 80)) = 1, 'é is in GSM-7';
  assert public.zella_sms_parts(repeat('ж', 70)) = 1 and public.zella_sms_parts(repeat('ж', 71)) = 2, 'UCS-2';
  assert public.zella_sms_parts(repeat('😀', 35)) = 1 and public.zella_sms_parts(repeat('😀', 36)) = 2, 'emoji take two places';
  raise notice 'PASS text parts follow carrier rules: GSM-7 160 / 153 (é counts 1, [ ] count 2), UCS-2 70 / 67, emoji count 2';

  before := (pg_temp.bal('b1000000-0000-4000-8000-0000000000ff', 'minutes') ->> 'used')::numeric;
  insert into calls (business_id, direction, status, external_call_id, from_number, started_at, answered_at, ended_at, duration_seconds, ai_handled)
  values ('b1000000-0000-4000-8000-0000000000ff', 'inbound', 'failed', 'bill-failed-1', '+15550001111', now() - interval '1 hour', now() - interval '1 hour', now() - interval '50 minutes', 600, true) returning id into c;
  assert (pg_temp.bal('b1000000-0000-4000-8000-0000000000ff', 'minutes') ->> 'used')::numeric = before, 'a failed call was charged';
  c := pg_temp.call('b1000000-0000-4000-8000-0000000000ff', 'bill-failed-2', 120);
  assert (pg_temp.bal('b1000000-0000-4000-8000-0000000000ff', 'minutes') ->> 'used')::numeric = before + 2, 'normal call';
  update calls set status = 'failed' where id = c;
  assert (pg_temp.bal('b1000000-0000-4000-8000-0000000000ff', 'minutes') ->> 'used')::numeric = before, 'a call marked failed later was not given back';
  raise notice 'PASS our failures are never billable: a failed call counts nothing, and a call marked failed later is given back';

  perform pg_temp.as_user('b1300000-0000-4000-8000-000000000009');
  r := public.zella_setup_plan_saved('b1000000-0000-4000-8000-00000000000a');
  assert r = '{"saved": true, "version": 1}', 'saved check: ' || r::text;
  assert public.zella_setup_plan_saved('b1000000-0000-4000-8000-0000000000aa') ->> 'saved' = 'false', 'unsaved';
  perform pg_temp.as_user('b1300000-0000-4000-8000-000000000001');
  begin perform public.zella_setup_plan_saved('b1000000-0000-4000-8000-00000000000a'); raise exception 'owner used the setup check';
  exception when raise_exception then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end;
  perform set_config('request.jwt.claims', '', false);
  raise notice 'PASS the setup wizard can see whether a plan is saved (no prices), for platform admins only';

  delete from billing_periods where false;
  assert public.zella_billing_open_current_periods() >= 0 and public.zella_check_usage_thresholds() >= 0, 'hourly job';
  raise notice 'PASS the hourly check opens current periods and retries missed charges without errors';
end $$;

-- 17. Pay as you go (D-44): a per-business rate; the owner can choose it only when the plan has one ------------------
do $$ declare r jsonb; begin
  r := public.zella_plan_evaluate(pg_temp.plan(500, 1000, 10000, 29900) || '{"overage_cents_per_minute": 35}');
  assert r ->> 'ok' = 'true' and r #>> '{values,overage_cents_per_minute}' = '35', 'rate: ' || r::text;
  assert public.zella_plan_evaluate(pg_temp.plan(500, 1000, 10000, 29900) || '{"overage_cents_per_minute": 0}') -> 'errors' ? 'overage_cents_per_minute', 'zero rate accepted';
  r := public.zella_plan_evaluate(pg_temp.plan(500, 1000, 10000, 29900) || '{"overage_cents_per_minute": 5}');
  assert r -> 'warnings' @> '[{"code": "overage_below_cost", "level": "red"}]', 'below-cost rate not warned: ' || r::text;
  -- business A's plan has no rate: the owner can't choose pay as you go
  perform pg_temp.as_user('b1300000-0000-4000-8000-000000000001');
  begin perform public.zella_save_usage_preferences('b1000000-0000-4000-8000-00000000000a', null, 'pay_as_you_go', 5000, 'take_message');
    raise exception 'pay as you go chosen without a rate'; exception when raise_exception then if sqlerrm <> 'PLAN_NO_PAY_AS_YOU_GO' then raise; end if; end;
  perform pg_temp.as_user('b1300000-0000-4000-8000-000000000009');
  r := public.zella_admin_plan_save('b1000000-0000-4000-8000-00000000000a', pg_temp.plan(500, 1000, 10000, 29900) || '{"overage_cents_per_minute": 35}', pg_temp.acks(), 'plan-a-version-2-payg');
  assert r ->> 'version' = '2', 'v2: ' || r::text;
  perform pg_temp.as_user('b1300000-0000-4000-8000-000000000001');
  perform public.zella_save_usage_preferences('b1000000-0000-4000-8000-00000000000a', null, 'pay_as_you_go', 5000, 'take_message');
  assert (select overage_mode from business_usage_preferences where business_id = 'b1000000-0000-4000-8000-00000000000a') = 'pay_as_you_go', 'not saved';
  assert public.zella_billing_overview('b1000000-0000-4000-8000-00000000000a') #>> '{plan,overage_cents_per_minute}' = '35', 'overview';
  perform set_config('request.jwt.claims', '', false);
  raise notice 'PASS pay as you go: the per-minute rate is set per business (a rate below cost is warned); the owner can choose it only when the plan has one';
end $$;
