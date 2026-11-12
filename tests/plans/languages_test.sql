-- Section 4: languages follow the plan, on the server (tests/plans/run.sh). The plans below are TEST rows with a test
-- limit only (no name, price or tier of Zella's); production has no plans defined. Test data only.
\set ON_ERROR_STOP 1
set client_min_messages = notice; reset role;
select set_config('request.jwt.claims', '', false);
insert into plans (id, name, slug, limits) values
  ('5c900000-0000-0000-0000-000000000001', 'TEST two languages', 'test-two-languages', '{"languages": 2}'),
  ('5c900000-0000-0000-0000-000000000002', 'TEST one language', 'test-one-language', '{"languages": 1}'),
  ('5c900000-0000-0000-0000-000000000003', 'TEST no language limit', 'test-no-limit', '{}');
insert into businesses (id, name, industry_id, timezone, is_active, onboarding_status)
select v.id::uuid, v.name, i.id, 'UTC', true, 'active' from (values ('5c000000-0000-0000-0000-00000000000a', 'Plan Clinic'), ('5c000000-0000-0000-0000-00000000000b', 'Unplanned Clinic')) v(id, name)
  join industries i on i.slug = 'dental';
insert into subscriptions (business_id, plan_id, status) values ('5c000000-0000-0000-0000-00000000000a', '5c900000-0000-0000-0000-000000000001', 'active');
insert into auth.users (id, email, email_confirmed_at) values ('5c300000-0000-0000-0000-000000000001', 'owner@plan.test', now()), ('5c300000-0000-0000-0000-000000000002', 'owner@unplanned.test', now());
insert into business_members (business_id, user_id, role, status) values
  ('5c000000-0000-0000-0000-00000000000a', '5c300000-0000-0000-0000-000000000001', 'owner', 'active'), ('5c000000-0000-0000-0000-00000000000b', '5c300000-0000-0000-0000-000000000002', 'owner', 'active');
create function pg_temp.as_owner(u text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'aal', 'aal1')::text, false) $$;
create function pg_temp.langs(b text) returns jsonb language sql as $$ select coalesce(public.zella_business_language_plan(b::uuid) -> 'languages', '[]') $$;

-- the CRM save (any caller of the RPC) is held to the plan
select pg_temp.as_owner('5c300000-0000-0000-0000-000000000001'); set role authenticated;
do $$ begin
  perform public.zella_business_language_save('5c000000-0000-0000-0000-00000000000a', 'en-US', array['es', 'fr'], null);
  raise exception 'three languages saved on a two-language plan';
exception when raise_exception then if sqlerrm <> 'PLAN_LANGUAGES' then raise; end if; end $$;
select public.zella_business_language_save('5c000000-0000-0000-0000-00000000000a', 'en-US', array['es'], null);
reset role;
do $$ begin
  assert pg_temp.langs('5c000000-0000-0000-0000-00000000000a') = '["English (US)", "Spanish"]'::jsonb or jsonb_array_length(pg_temp.langs('5c000000-0000-0000-0000-00000000000a')) = 2, 'allowed languages not used: ' || pg_temp.langs('5c000000-0000-0000-0000-00000000000a')::text;
  raise notice 'PASS Settings > Languages refuses more languages than the plan allows (PLAN_LANGUAGES); within it they are saved and used on calls';
end $$;

-- a smaller plan: calls stop offering the extra language at once, the saved choice is kept for an upgrade
update subscriptions set plan_id = '5c900000-0000-0000-0000-000000000002' where business_id = '5c000000-0000-0000-0000-00000000000a';
do $$ begin
  assert public.zella_business_language_plan('5c000000-0000-0000-0000-00000000000a') ->> 'mode' = 'english', 'extra language still offered: ' || public.zella_business_language_plan('5c000000-0000-0000-0000-00000000000a')::text;
  assert (select extra_languages from business_languages where business_id = '5c000000-0000-0000-0000-00000000000a') = array['es'], 'saved choice lost';
end $$;
update subscriptions set plan_id = '5c900000-0000-0000-0000-000000000001' where business_id = '5c000000-0000-0000-0000-00000000000a';
do $$ begin
  assert jsonb_array_length(pg_temp.langs('5c000000-0000-0000-0000-00000000000a')) = 2, 'upgrade did not bring it back';
  raise notice 'PASS on a smaller plan the next call offers only what the plan allows; moving back restores the saved languages';
end $$;

-- setup is held to the same rule and says so
update subscriptions set plan_id = '5c900000-0000-0000-0000-000000000002' where business_id = '5c000000-0000-0000-0000-00000000000a';
do $$ declare r jsonb; begin
  r := public.zella_setup_language_apply('5c000000-0000-0000-0000-00000000000a', 'en-US+es-US', null);
  assert r ->> 'reason' = 'PLAN_LANGUAGES', 'setup saved two languages on a one-language plan: ' || r::text;
  r := public.zella_setup_language_apply('5c000000-0000-0000-0000-00000000000a', 'es-US', null);
  assert r ->> 'ok' = 'true', 'one language refused: ' || r::text;
  raise notice 'PASS the setup''s language choice is refused (reported) when over the plan, and saved when within it';
end $$;

-- no limit set, or no subscription: unchanged behaviour
update subscriptions set plan_id = '5c900000-0000-0000-0000-000000000003' where business_id = '5c000000-0000-0000-0000-00000000000a';
select pg_temp.as_owner('5c300000-0000-0000-0000-000000000002'); set role authenticated;
select public.zella_business_language_save('5c000000-0000-0000-0000-00000000000b', 'en-US', array['es', 'fr', 'de'], null);
reset role;
-- zella_language_allowance answers only a member of the business (zella_review_sql_fixes), so each is asked by its own owner
do $$ begin
  perform pg_temp.as_owner('5c300000-0000-0000-0000-000000000001');
  assert public.zella_language_allowance('5c000000-0000-0000-0000-00000000000a') is null, 'a limit was assumed (plan without one)';
  perform pg_temp.as_owner('5c300000-0000-0000-0000-000000000002');
  assert public.zella_language_allowance('5c000000-0000-0000-0000-00000000000b') is null, 'a limit was assumed (no subscription)';
  assert jsonb_array_length(pg_temp.langs('5c000000-0000-0000-0000-00000000000b')) = 4, 'unplanned business lost languages';
  raise notice 'PASS no limit is assumed: a plan without one, or no subscription, keeps today''s behaviour (up to four)';
end $$;
