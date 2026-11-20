-- Rollback of sql/zella_stripe_payment_gate.sql: puts the five functions back exactly as archived and drops the helper.
-- Refuses (ROLLBACK_DRIFT) if any of them is neither that file's version nor the original. Safe to run twice.
begin;

do $$
declare s text; d text;
  known constant jsonb := '{
    "public.zella_onboarding_rules()": ["26a478446b850a960496d86e13484979", "501c44f37a050dac331bb47411fd7584"],
    "public.zella_onboarding_payment(uuid)": ["c777f4fddec15495ef2f1fa2c2c95cd8", "d0052c2dc317fee183d08f8445208158"],
    "public.zella_activation_checks(uuid)": ["51e92e389b2dc9d9fef1613655c75a07", "04c12adfc77e83f79483eb4ceb038742"],
    "public.zella_request_activation(uuid)": ["41ab61c937ec1fd0b05b7fbd91b8353f", "c809897e3b1bd7f5c19e9ab3b601b9d7"],
    "public.zella_owner_onboarding_complete_step(uuid,text)": ["b43eec8dd1a0dc0810da790882978cce", "d1c40de4dce54a191891acefbd3c30ac"]
  }';
begin
  for s in select jsonb_object_keys(known) loop
    d := pg_get_functiondef(s::regprocedure);
    if md5(d) = known -> s ->> 0 then continue; end if;
    if md5(d) <> known -> s ->> 1 then raise exception 'ROLLBACK_DRIFT: % is not the version zella_stripe_payment_gate.sql made', s; end if;
    select definition into d from public.zella_function_archive where migration = 'zella_stripe_payment_gate' and signature = s and definition_md5 = known -> s ->> 0;
    if d is null then raise exception 'ROLLBACK_DRIFT: the archived % is missing', s; end if;
    execute d;
  end loop;
  if to_regprocedure('public.zella_onboarding_payment_passed(uuid)') is not null then
    if md5(pg_get_functiondef('public.zella_onboarding_payment_passed(uuid)'::regprocedure)) <> '6065905149390deeed6e519af5464864' then
      raise exception 'ROLLBACK_DRIFT: zella_onboarding_payment_passed is not the version zella_stripe_payment_gate.sql made';
    end if;
    drop function public.zella_onboarding_payment_passed(uuid);
  end if;
  delete from public.zella_function_archive where migration = 'zella_stripe_payment_gate';
end $$;

commit;
