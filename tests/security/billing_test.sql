-- Regression tests for sql/zella_billing_hardening.sql, on a restored baseline (tests/security/run.sh). Test data only.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

insert into public.businesses (id, name) values ('b1000000-0000-0000-0000-000000000001', 'Bill Co'), ('b1000000-0000-0000-0000-000000000002', 'Other Co');
insert into public.plans (id, name, slug, is_active) values ('c1000000-0000-0000-0000-000000000001', 'Starter', 'starter', true);
create or replace function pg_temp.ev(p_id text, p_type text, p_sub text default 'sub_1', p_pay text default null, p_minor bigint default null,
  p_cur text default 'usd', p_at timestamptz default now(), p_refund bigint default null) returns text language sql as $$
  select public.zella_process_billing_event('stripe', p_id, p_type, p_sub, null, p_minor, p_cur, p_pay, null, null, null, 'test', p_at, p_refund) $$;
create or replace function pg_temp.sub_status() returns text language sql as $$
  select status from public.subscriptions where business_id = 'b1000000-0000-0000-0000-000000000001' $$;

-- 1. Out of order: the payment arrives before its subscription is linked; it waits, then applies exactly once
do $$ declare r text; begin
  r := pg_temp.ev('evt_1', 'payment_succeeded', 'sub_1', 'pi_1', 2500);
  assert r = 'pending', 'unmatched event: ' || r;
  r := pg_temp.ev('evt_1', 'payment_succeeded', 'sub_1', 'pi_1', 2500);   -- provider retry while still unmatched
  assert r = 'pending', 'redelivery of a waiting event must not be "duplicate": ' || r;
  insert into public.subscriptions (business_id, plan_id, status, billing_interval, provider, external_subscription_id)
  values ('b1000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'past_due', 'monthly', 'stripe', 'sub_1');
  assert (select status from public.billing_events where external_event_id = 'evt_1') = 'processed', 'not applied when the subscription appeared';
  assert (select count(*) from public.payments where external_payment_id = 'pi_1') = 1;
  assert pg_temp.sub_status() = 'active', 'subscription not reactivated: ' || pg_temp.sub_status();
  r := pg_temp.ev('evt_1', 'payment_succeeded', 'sub_1', 'pi_1', 2500);
  assert r = 'duplicate' and (select count(*) from public.payments where external_payment_id = 'pi_1') = 1, 'duplicate created a payment: ' || r;
  raise notice 'PASS unmatched event waits, survives redelivery, applies once when the subscription is linked';
end $$;

-- 2. A failed attempt followed by a successful retry of the same payment: one row, succeeded
do $$ begin
  assert pg_temp.ev('evt_2a', 'payment_failed', 'sub_1', 'pi_2', 2500, 'usd', now() + interval '1 minute') = 'processed';
  assert pg_temp.sub_status() = 'past_due';
  assert pg_temp.ev('evt_2b', 'payment_succeeded', 'sub_1', 'pi_2', 2500, 'usd', now() + interval '2 minutes') = 'processed';
  assert (select count(*) from public.payments where external_payment_id = 'pi_2') = 1, 'retry added a second payment';
  assert (select status from public.payments where external_payment_id = 'pi_2') = 'succeeded';
  assert pg_temp.sub_status() = 'active';
  -- the failure delivered late (older) can't undo the success
  assert pg_temp.ev('evt_2c', 'payment_failed', 'sub_1', 'pi_2', 2500, 'usd', now() + interval '1 minute 30 seconds') = 'processed';
  assert (select status from public.payments where external_payment_id = 'pi_2') = 'succeeded' and pg_temp.sub_status() = 'active', 'late failure regressed the payment or subscription';
  raise notice 'PASS failed-then-succeeded payment is one row; a late failure never regresses it';
end $$;

-- 3. Out-of-order subscription events: an older "renewed" after a newer "cancelled" is recorded but changes nothing
do $$ begin
  assert pg_temp.ev('evt_3a', 'subscription_cancelled', 'sub_1', null, null, null, now() + interval '10 minutes') = 'processed';
  assert pg_temp.sub_status() = 'cancelled';
  assert pg_temp.ev('evt_3b', 'subscription_renewed', 'sub_1', null, null, null, now() + interval '5 minutes') = 'processed';
  assert pg_temp.sub_status() = 'cancelled', 'older renewal revived a cancelled subscription';
  assert (select error from public.billing_events where external_event_id = 'evt_3b') = 'older_than_current_state';
  assert pg_temp.ev('evt_3c', 'subscription_renewed', 'sub_1', null, null, null, now() + interval '20 minutes') = 'processed';
  assert pg_temp.sub_status() = 'active', 'newer renewal ignored';
  raise notice 'PASS subscription status follows event time, not arrival order';
end $$;

-- 4. Refunds and disputes
do $$ begin
  assert pg_temp.ev('evt_4a', 'payment_succeeded', 'sub_1', 'pi_4', 5000, 'usd', now() + interval '30 minutes') = 'processed';
  assert pg_temp.ev('evt_4b', 'payment_refunded_partial', null, 'pi_4', null, null, now() + interval '31 minutes', 1000) = 'processed';
  assert (select status from public.payments where external_payment_id = 'pi_4') = 'succeeded', 'partial refund marked the whole payment refunded';
  assert (select (metadata ->> 'refunded_minor')::int from public.payments where external_payment_id = 'pi_4') = 1000;
  assert pg_temp.ev('evt_4c', 'payment_disputed', null, 'pi_4', null, null, now() + interval '32 minutes') = 'processed';
  assert (select status || '/' || (metadata ->> 'disputed') from public.payments where external_payment_id = 'pi_4') = 'succeeded/true', 'dispute treated as refund';
  assert pg_temp.ev('evt_4d', 'payment_reversed', null, 'pi_4', null, null, now() + interval '33 minutes') = 'processed';   -- dispute lost
  assert (select status from public.payments where external_payment_id = 'pi_4') = 'refunded';
  raise notice 'PASS partial refund, dispute opened and dispute lost are told apart';
end $$;

-- 5. A refund that arrives before its payment waits, then applies after the payment
do $$ declare r text; begin
  r := pg_temp.ev('evt_5a', 'payment_reversed', null, 'pi_5', null, null, now() + interval '41 minutes', 3000);
  assert r = 'pending', 'refund for an unknown payment: ' || r;
  assert pg_temp.ev('evt_5b', 'payment_succeeded', 'sub_1', 'pi_5', 3000, 'usd', now() + interval '40 minutes') = 'processed';
  assert (select status from public.billing_events where external_event_id = 'evt_5a') = 'processed', 'waiting refund not applied after its payment';
  assert (select status from public.payments where external_payment_id = 'pi_5') = 'refunded';
  raise notice 'PASS refund before payment waits and applies once the payment exists';
end $$;

-- 6. Currency units: integer minor units kept exactly, display amount uses the currency''s decimals
do $$ begin
  assert pg_temp.ev('evt_6a', 'payment_succeeded', 'sub_1', 'pi_6a', 1999, 'usd', now() + interval '50 minutes') = 'processed';
  assert pg_temp.ev('evt_6b', 'payment_succeeded', 'sub_1', 'pi_6b', 1500, 'JPY', now() + interval '51 minutes') = 'processed';
  assert pg_temp.ev('evt_6c', 'payment_succeeded', 'sub_1', 'pi_6c', 1234, 'kwd', now() + interval '52 minutes') = 'processed';
  assert (select amount::text || ' ' || amount_minor from public.payments where external_payment_id = 'pi_6a') = '19.99 1999';
  assert (select amount::text || ' ' || currency from public.payments where external_payment_id = 'pi_6b') = '1500 jpy', 'JPY was divided by 100';
  assert (select amount::text from public.payments where external_payment_id = 'pi_6c') = '1.234', 'KWD has 3 decimals';
  assert exists (select 1 from public.platform_alerts where kind = 'billing_currency'), 'unsupported currency not alerted';
  assert pg_temp.ev('evt_6d', 'payment_succeeded', 'sub_1', 'pi_6d', -5, 'usd') = 'failed', 'negative amount accepted';
  assert pg_temp.ev('evt_6e', 'payment_succeeded', 'sub_1', 'pi_6e', null, 'usd') = 'failed', 'missing amount accepted';
  raise notice 'PASS currency minor units (USD 2, JPY 0, KWD 3 decimals); bad amounts refused; unsupported currency alerted';
end $$;

-- 7. A transient failure keeps the event (status failed) and a redelivery applies it once
do $$ declare r text; begin
  alter function public.zella_notify_owners(uuid, text, text, text, text, text) rename to zella_notify_owners_real;
  create function public.zella_notify_owners(uuid, text, text, text, text, text) returns void language plpgsql as $f$ begin raise exception 'transient outage'; end $f$;
  r := pg_temp.ev('evt_7', 'payment_succeeded', 'sub_1', 'pi_7', 900, 'usd', now() + interval '60 minutes');
  assert r = 'failed', 'transient error not reported: ' || r;
  assert (select status || '/' || attempts from public.billing_events where external_event_id = 'evt_7') = 'failed/1', 'failed event not kept';
  assert not exists (select 1 from public.payments where external_payment_id = 'pi_7'), 'half-applied payment left behind';
  drop function public.zella_notify_owners(uuid, text, text, text, text, text);
  alter function public.zella_notify_owners_real(uuid, text, text, text, text, text) rename to zella_notify_owners;
  r := pg_temp.ev('evt_7', 'payment_succeeded', 'sub_1', 'pi_7', 900, 'usd', now() + interval '60 minutes');
  assert r = 'processed' and (select count(*) from public.payments where external_payment_id = 'pi_7') = 1, 'redelivery after outage: ' || r;
  raise notice 'PASS transient failure keeps the event; redelivery applies it exactly once';
end $$;

-- 8. The reconciler retries due events and closes ones unmatched for 7 days
do $$ declare j jsonb; begin
  perform pg_temp.ev('evt_8a', 'payment_succeeded', 'sub_missing', 'pi_8a', 100);
  perform pg_temp.ev('evt_8b', 'payment_succeeded', 'sub_missing', 'pi_8b', 100);
  update public.billing_events set received_at = now() - interval '8 days', next_attempt_at = now() - interval '1 minute' where external_event_id = 'evt_8a';
  update public.billing_events set next_attempt_at = now() - interval '1 minute' where external_event_id = 'evt_8b';
  j := public.zella_reconcile_billing_events();
  assert (j ->> 'closed')::int = 1 and (j ->> 'waiting')::int = 1, j::text;
  assert (select status from public.billing_events where external_event_id = 'evt_8a') = 'ignored';
  assert (select status from public.billing_events where external_event_id = 'evt_8b') = 'pending';
  assert exists (select 1 from public.platform_alerts where kind = 'billing_event_unmatched');
  raise notice 'PASS reconciler retries due events and closes ones unmatched for 7 days with an alert';
end $$;

-- 9. Grants
do $$ begin
  assert not has_function_privilege('authenticated', 'public.zella_process_billing_event(text,text,text,text,uuid,bigint,text,text,timestamptz,timestamptz,text,text,timestamptz,bigint)', 'execute');
  assert not has_function_privilege('anon', 'public.zella_reconcile_billing_events(integer)', 'execute');
  assert not has_function_privilege('authenticated', 'public.zella_apply_billing_event(uuid)', 'execute');
  assert not exists (select 1 from pg_proc where proname = 'zella_process_billing_event' and pronargs = 12), 'old signature still present';
  raise notice 'PASS billing functions are service-role only; old signature removed';
end $$;
