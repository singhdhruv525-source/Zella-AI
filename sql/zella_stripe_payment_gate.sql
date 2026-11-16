-- Zella Voice: the first payment is required only once payments are live (owner decision, 16 Nov 2026).
-- While payments_live is false (the default) the go live gate doesn't wait for a payment, the owner's step 6 shows
-- "Payment opens here soon" and can be passed, and nothing pretends a payment happened. Once the owner switches
-- payments on (zella_payments_switch), the rule "pay before going live" applies to every business not live yet.
--   - zella_onboarding_rules(): first_payment is 'pay_before_live' while payments are live, otherwise
--     'not_until_payments_live'.
--   - zella_onboarding_payment_passed(business): the gate's answer (not required yet, or a bound payment confirmed).
--   - zella_activation_checks, zella_request_activation and zella_owner_onboarding_complete_step use it instead of
--     "a payment confirmed"; zella_onboarding_payment says whether a payment is required (required).
-- Each replaced function is changed by an exact text replacement on the version this file was written for (checked by
-- md5 first, archived for the rollback). Rollback: sql/rollback/zella_stripe_payment_gate_rollback.sql.
-- Tests: tests/stripe_payment_gate/run.sh.
begin;

do $$ begin
  if to_regprocedure('public.zella_admin_plan_change_start(uuid,uuid,text)') is null then raise exception 'VERSION_MISMATCH: needs zella_stripe_plan_change.sql'; end if;
  if to_regprocedure('public.zella_onboarding_payment_passed(uuid)') is not null
     and md5(pg_get_functiondef(to_regprocedure('public.zella_onboarding_payment_passed(uuid)'))) <> 'e70908add03c370de86fdc4893bc984f' then
    raise exception 'VERSION_MISMATCH: zella_onboarding_payment_passed is not the version this file makes';
  end if;
end $$;

-- the helper first (the replaced bodies call it)
create or replace function public.zella_onboarding_payment_passed(p_business_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.zella_onboarding_rules() ->> 'first_payment' = 'not_until_payments_live'
      or public.zella_onboarding_payment_confirmed_at(p_business_id) is not null;
$$;

do $$
declare s text; d text; r jsonb;
  -- signature: [this file's input md5, this file's output md5, [text to find, text to put instead]...]
  known constant jsonb := '{
    "public.zella_onboarding_rules()": ["26a478446b850a960496d86e13484979", "501c44f37a050dac331bb47411fd7584",
      ["''first_payment'', ''pay_before_live'',", "''first_payment'', case when public.zella_payments_live() then ''pay_before_live'' else ''not_until_payments_live'' end,"]],
    "public.zella_onboarding_payment(uuid)": ["c777f4fddec15495ef2f1fa2c2c95cd8", "d0052c2dc317fee183d08f8445208158",
      ["''checkout_available'', v_at is null", "''required'', public.zella_onboarding_rules() ->> ''first_payment'' <> ''not_until_payments_live'',\n    ''checkout_available'', v_at is null"]],
    "public.zella_activation_checks(uuid)": ["51e92e389b2dc9d9fef1613655c75a07", "04c12adfc77e83f79483eb4ceb038742",
      ["public.zella_onboarding_payment_confirmed_at(p_business_id) is not null", "public.zella_onboarding_payment_passed(p_business_id)"]],
    "public.zella_request_activation(uuid)": ["41ab61c937ec1fd0b05b7fbd91b8353f", "c809897e3b1bd7f5c19e9ab3b601b9d7",
      ["public.zella_onboarding_payment_confirmed_at(p_business_id) is not null", "public.zella_onboarding_payment_passed(p_business_id)"]],
    "public.zella_owner_onboarding_complete_step(uuid,text)": ["b43eec8dd1a0dc0810da790882978cce", "d1c40de4dce54a191891acefbd3c30ac",
      ["if public.zella_onboarding_payment_confirmed_at(p_business_id) is null then", "if not public.zella_onboarding_payment_passed(p_business_id) then"]]
  }';
begin
  for s in select jsonb_object_keys(known) loop
    d := pg_get_functiondef(s::regprocedure);
    if md5(d) = known -> s ->> 1 then continue; end if;   -- already this file's version
    if md5(d) <> known -> s ->> 0 then raise exception 'VERSION_MISMATCH: % is not a version this file was written for', s; end if;
    insert into public.zella_function_archive (migration, signature, definition, definition_md5) values ('zella_stripe_payment_gate', s, d, md5(d)) on conflict (migration, signature) do nothing;
    for r in select value from jsonb_array_elements(known -> s) with ordinality x(value, n) where n > 2 loop
      if position(r ->> 0 in d) = 0 then raise exception 'VERSION_MISMATCH: % lacks the text this file changes', s; end if;
      d := replace(d, r ->> 0, r ->> 1);
    end loop;
    execute d;
  end loop;
end $$;
revoke execute on function public.zella_onboarding_payment_passed(uuid) from public, anon;
grant execute on function public.zella_onboarding_payment_passed(uuid) to authenticated, service_role;

commit;
