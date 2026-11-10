-- Money the team records (zella_money.sql): roles, same-business links, balances, refunds, gift cards, idempotency,
-- manual vs provider, capability, no access across businesses.
\set ON_ERROR_STOP on
begin;
insert into auth.users (id, email, email_confirmed_at) values
 ('e6000000-0000-0000-0000-00000000000a', 'own@m.test', now()), ('e6000000-0000-0000-0000-00000000000b', 'mgr@m.test', now()),
 ('e6000000-0000-0000-0000-00000000000c', 'stf@m.test', now()), ('e6000000-0000-0000-0000-00000000000d', 'view@m.test', now()),
 ('e6000000-0000-0000-0000-00000000000e', 'other@m.test', now());
insert into public.businesses (id, name, timezone, is_active, onboarding_status, country) values
 ('e6000000-0000-0000-0000-0000000000a1', 'Money Co', 'UTC', true, 'active', 'AU'),
 ('e6000000-0000-0000-0000-0000000000b1', 'Other Co', 'UTC', true, 'active', 'US');
insert into public.business_members (business_id, user_id, role, status) values
 ('e6000000-0000-0000-0000-0000000000a1', 'e6000000-0000-0000-0000-00000000000a', 'owner', 'active'),
 ('e6000000-0000-0000-0000-0000000000a1', 'e6000000-0000-0000-0000-00000000000b', 'manager', 'active'),
 ('e6000000-0000-0000-0000-0000000000a1', 'e6000000-0000-0000-0000-00000000000c', 'staff', 'active'),
 ('e6000000-0000-0000-0000-0000000000a1', 'e6000000-0000-0000-0000-00000000000d', 'viewer', 'active'),
 ('e6000000-0000-0000-0000-0000000000b1', 'e6000000-0000-0000-0000-00000000000e', 'owner', 'active');
insert into public.customers (id, business_id, first_name) values
 ('e6000000-0000-0000-0000-0000000000c1', 'e6000000-0000-0000-0000-0000000000a1', 'Ann'),
 ('e6000000-0000-0000-0000-0000000000c2', 'e6000000-0000-0000-0000-0000000000b1', 'Bob');
create temp table ids (k text primary key, id uuid) on commit drop;
grant all on ids to authenticated;
set local role authenticated;

-- staff creates an invoice (currency from the country: AUD); a repeat with the same key returns the same one
select set_config('request.jwt.claims', '{"sub":"e6000000-0000-0000-0000-00000000000c","role":"authenticated","aal":"aal1"}', true);
insert into ids select 'inv', (public.zella_create_charge('e6000000-0000-0000-0000-0000000000a1', 'invoice', 25050, 'Repair', 'e6000000-0000-0000-0000-0000000000c1',
  null, null, null, null, 'k1') ->> 'id')::uuid;
do $$ declare r jsonb; begin
  r := public.zella_create_charge('e6000000-0000-0000-0000-0000000000a1', 'invoice', 25050, 'Repair', null, null, null, null, null, 'k1');
  assert (r ->> 'repeat')::boolean and (r ->> 'id')::uuid = (select id from ids where k = 'inv'), 'same key, same invoice';
  assert (select currency from public.customer_charges where id = (select id from ids where k = 'inv')) = 'AUD', 'currency from the country';
  begin perform public.zella_create_charge('e6000000-0000-0000-0000-0000000000a1', 'invoice', 100, null, 'e6000000-0000-0000-0000-0000000000c2');
    raise exception 'linked another business''s customer';
  exception when others then if sqlerrm not like 'NOT_ALLOWED%' then raise; end if; end;
  begin perform public.zella_create_charge('e6000000-0000-0000-0000-0000000000a1', 'invoice', 0); raise exception 'zero amount';
  exception when others then if sqlerrm not like 'BAD_AMOUNT%' then raise; end if; end;
  begin perform public.zella_record_charge_payment((select id from ids where k = 'inv'), 'payment', 100, 'cash'); raise exception 'staff recorded a payment';
  exception when others then if sqlerrm not like 'NOT_ALLOWED%' then raise; end if; end;
end $$;

-- viewer and another business see and do nothing
select set_config('request.jwt.claims', '{"sub":"e6000000-0000-0000-0000-00000000000d","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  assert (select count(*) from public.customer_charges) = 0, 'viewer sees no money';
  begin perform public.zella_create_charge('e6000000-0000-0000-0000-0000000000a1', 'invoice', 100); raise exception 'viewer created';
  exception when others then if sqlerrm not like 'NOT_ALLOWED%' then raise; end if; end;
end $$;
select set_config('request.jwt.claims', '{"sub":"e6000000-0000-0000-0000-00000000000e","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  assert (select count(*) from public.customer_charges) = 0, 'other business sees nothing';
  begin perform public.zella_charge_balance((select id from ids where k = 'inv')); raise exception 'other business read a balance';
  exception when others then if sqlerrm not like 'NOT_ALLOWED%' then raise; end if; end;
  begin perform public.zella_record_charge_payment((select id from ids where k = 'inv'), 'payment', 100, 'cash'); raise exception 'other business paid';
  exception when others then if sqlerrm not like 'NOT_ALLOWED%' then raise; end if; end;
end $$;

-- manager: partial payment, then the rest; no overpaying; card details have no place to go; provider method refused
select set_config('request.jwt.claims', '{"sub":"e6000000-0000-0000-0000-00000000000b","role":"authenticated","aal":"aal1"}', true);
do $$ declare i uuid := (select id from ids where k = 'inv'); r jsonb; begin
  r := public.zella_record_charge_payment(i, 'payment', 10000, 'card_terminal', null, 'p1');
  assert r ->> 'status' = 'partially_paid', 'partial payment';
  r := public.zella_record_charge_payment(i, 'payment', 10000, 'card_terminal', null, 'p1');
  assert (r ->> 'repeat')::boolean, 'same payment key is not counted twice';
  assert (public.zella_charge_balance(i) ->> 'balance_minor')::bigint = 15050, 'balance after partial';
  begin perform public.zella_record_charge_payment(i, 'payment', 15051, 'cash'); raise exception 'overpaid';
  exception when others then if sqlerrm not like 'MORE_THAN_OWED%' then raise; end if; end;
  begin perform public.zella_record_charge_payment(i, 'payment', 100, 'provider'); raise exception 'manual provider payment';
  exception when others then if sqlerrm not like 'NOT_VALID%' then raise; end if; end;
  r := public.zella_record_charge_payment(i, 'payment', 15050, 'cash');
  assert r ->> 'status' = 'paid', 'paid in full';
  begin perform public.zella_record_charge_payment(i, 'refund', 100, 'cash'); raise exception 'manager refunded';
  exception when others then if sqlerrm not like 'NOT_ALLOWED%' then raise; end if; end;
  begin perform public.zella_set_charge_status(i, 'void'); raise exception 'voided a paid invoice';
  exception when others then if sqlerrm not like 'HAS_PAYMENTS%' then raise; end if; end;
end $$;

-- owner refunds part, not more than was paid
select set_config('request.jwt.claims', '{"sub":"e6000000-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1"}', true);
do $$ declare i uuid := (select id from ids where k = 'inv'); r jsonb; e uuid; g uuid; begin
  r := public.zella_record_charge_payment(i, 'refund', 5000, 'cash');
  assert r ->> 'status' = 'partially_paid' and (public.zella_charge_balance(i) ->> 'balance_minor')::bigint = 5000, 'partial refund';
  begin perform public.zella_record_charge_payment(i, 'refund', 20051, 'cash'); raise exception 'refunded more than paid';
  exception when others then if sqlerrm not like 'MORE_THAN_PAID%' then raise; end if; end;
  -- estimates are proposals: never payable
  e := (public.zella_create_charge('e6000000-0000-0000-0000-0000000000a1', 'estimate', 90000) ->> 'id')::uuid;
  assert (select status from public.customer_charges where id = e) = 'proposed', 'estimate is proposed';
  begin perform public.zella_record_charge_payment(e, 'payment', 100, 'cash'); raise exception 'paid an estimate';
  exception when others then if sqlerrm not like 'NOT_PAYABLE%' then raise; end if; end;
  perform public.zella_set_charge_status(e, 'accepted');
  -- gift card: sold for the full value, then redeemed in parts, never beyond its value
  g := (public.zella_create_charge('e6000000-0000-0000-0000-0000000000a1', 'gift_card', 5000) ->> 'id')::uuid;
  begin perform public.zella_record_charge_payment(g, 'redemption', 100, 'gift_card'); raise exception 'redeemed an unpaid card';
  exception when others then if sqlerrm not like 'NOT_PAID%' then raise; end if; end;
  perform public.zella_record_charge_payment(g, 'payment', 5000, 'cash');
  perform public.zella_record_charge_payment(g, 'redemption', 3000, 'gift_card');
  begin perform public.zella_record_charge_payment(g, 'redemption', 2001, 'gift_card'); raise exception 'redeemed beyond value';
  exception when others then if sqlerrm not like 'MORE_THAN_OWED%' then raise; end if; end;
  -- numbers run per kind
  assert (select number from public.customer_charges where id = i) = 'INV-1001' and (select number from public.customer_charges where id = e) = 'E-1001', 'numbers';
  -- no direct writes
  begin update public.customer_charges set amount_minor = 1 where id = i; raise exception 'direct update allowed';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

-- provider-confirmed payments: server only, labelled, once per provider reference
do $$ declare i uuid; r jsonb; begin
  i := (select id from public.customer_charges where kind = 'invoice' and business_id = 'e6000000-0000-0000-0000-0000000000a1');
  r := public.zella_provider_charge_payment(i, 'payment', 5000, 'pi_123');
  r := public.zella_provider_charge_payment(i, 'payment', 5000, 'pi_123');
  assert (r ->> 'repeat')::boolean, 'provider reference counted once';
  assert (public.zella_charge_balance(i) ->> 'provider_minor')::bigint = 5000 and (public.zella_charge_balance(i) ->> 'manual_minor')::bigint = 25050, 'manual vs provider kept apart';
  assert (select status from public.customer_charges where id = i) = 'paid', 'paid after provider confirmation';
  assert (select count(*) from public.audit_logs where entity_type = 'customer_charge' and business_id = 'e6000000-0000-0000-0000-0000000000a1') >= 8, 'audited';
  assert not has_function_privilege('authenticated', 'public.zella_provider_charge_payment(uuid, text, bigint, text)', 'execute'), 'provider path is server-only';
end $$;
-- the money capability off: nothing new recorded, nothing deleted
insert into public.business_capabilities (business_id, capability, enabled) values ('e6000000-0000-0000-0000-0000000000a1', 'money', false);
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"e6000000-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  begin perform public.zella_create_charge('e6000000-0000-0000-0000-0000000000a1', 'invoice', 100); raise exception 'created while money is off';
  exception when others then if sqlerrm not like 'CAPABILITY_OFF:money%' then raise; end if; end;
  assert (select count(*) from public.customer_charges) = 3, 'existing records kept';
end $$;
select 'PASS money: roles (staff create, manager pay, owner refund, viewer/other business nothing), balances, no overpay/over-refund, estimates unpayable, gift cards, idempotent, manual vs provider, capability';
rollback;
