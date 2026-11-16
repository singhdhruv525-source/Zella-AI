-- Rollback of sql/zella_stripe_checkout.sql. Restores the three onboarding functions exactly as archived, drops what
-- the file made, and refuses (ROLLBACK_DRIFT) if any of them differs from that file's version, or (ROLLBACK_HAS_DATA)
-- while any checkout exists: nothing is deleted. Safe to run twice.
begin;

do $$
declare s text; v_has boolean; d text;
  owned constant jsonb := '{
    "public.zella_billing_checkout_continue(uuid,boolean)": "2d0f417be1edd6dba431e972a2b3123d",
    "public.zella_billing_checkout_next_command(uuid)": "1de829f1bf61b380be0b25226d03368f",
    "public.zella_owner_billing_checkout_start(uuid,text)": "096c4a95c59712984e15ace4b4b69a27",
    "public.zella_stripe_after_customer(billing_outbox)": "79869917c8050995b88a9bebeaa57c31",
    "public.zella_stripe_after_product(billing_outbox)": "a9eb61e5d51628b53253a83df4efdb68",
    "public.zella_stripe_after_price(billing_outbox)": "651dce986b81b8bcf00033b3f32c8323",
    "public.zella_stripe_after_checkout_session(billing_outbox)": "5df8106e56d16ca2580479906e4aa8f0",
    "public.zella_stripe_failed_checkout_session(billing_outbox)": "3274f0c8857d89ebf9790d2ffa6d4295",
    "public.zella_stripe_on_checkout_session_completed(billing_events,jsonb)": "eb6740164eb5dd99408886144c09d2e6",
    "public.zella_stripe_on_checkout_session_expired(billing_events,jsonb)": "8e12fc8a241aad650435134fa83ae0cd",
    "public.zella_stripe_grant_subscription_create(jsonb,jsonb)": "617d28551ada05a996984777eae97aa2"
  }';
  replaced constant jsonb := '{
    "public.zella_onboarding_rules()": ["44a476a30d23837102550359e28f5c67", "26a478446b850a960496d86e13484979"],
    "public.zella_onboarding_payment_confirmed_at(uuid)": ["3bd343a55794b4120ed6421bba3f5ab8", "8f9e449e953522c5a931d282c58912c5"],
    "public.zella_onboarding_payment(uuid)": ["65909f32d9e0e9259bd5b07b1e1a5543", "c777f4fddec15495ef2f1fa2c2c95cd8"]
  }';
begin
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null and md5(pg_get_functiondef(s::regprocedure)) <> owned ->> s then
      raise exception 'ROLLBACK_DRIFT: % is not the version zella_stripe_checkout.sql made', s;
    end if;
  end loop;
  for s in select jsonb_object_keys(replaced) loop   -- this file's version, or the original (already rolled back)
    if md5(pg_get_functiondef(s::regprocedure)) not in (replaced -> s ->> 0, replaced -> s ->> 1) then
      raise exception 'ROLLBACK_DRIFT: % is not the version zella_stripe_checkout.sql made', s;
    end if;
  end loop;
  if to_regclass('public.billing_checkouts') is not null then
    execute 'select exists (select 1 from public.billing_checkouts)' into v_has;
    if v_has then raise exception 'ROLLBACK_HAS_DATA: checkouts exist; a person decides what to keep'; end if;
  end if;
  for s in select jsonb_object_keys(replaced) loop
    if md5(pg_get_functiondef(s::regprocedure)) = replaced -> s ->> 1 then
      select definition into d from public.zella_function_archive where migration = 'zella_stripe_checkout' and signature = s and definition_md5 = replaced -> s ->> 0;
      if d is null then raise exception 'ROLLBACK_DRIFT: the archived % is missing', s; end if;
      execute d;
    end if;
  end loop;
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null then execute format('drop function %s', s::regprocedure); end if;
  end loop;
  delete from public.zella_function_archive where migration = 'zella_stripe_checkout';
end $$;
drop table if exists public.billing_checkouts;
revoke execute on function public.zella_payments_live() from authenticated;

commit;
