-- Zella Voice: only Zella Voice platform admins change a receptionist's languages; the plan decides whether Spanish can
-- be added; the voices offered and used follow the languages. Owner's rule, 24 Nov 2026.
--
--   1. zella_business_language_save (Settings > Languages and the admin business page) refuses everyone but a platform
--      admin who may manage businesses: an active admin whose role has businesses.manage, or the zella_owner and
--      super_admin roles (zella_admin_can, the same rule zella_setup_voice_apply checks for the wizard). Anyone else gets
--      LANGUAGES_ADMIN_ONLY. Every change is audited (receptionist.languages_changed). Owners and staff still read their
--      languages with zella_business_language_get, which platform admins with businesses.view can now read too, with
--      the business's plan and whether the saved languages are within it.
--   2. The plan decides. zella_language_plan_info reads the plan in effect: the business's own plan from Create Business
--      (business_plans, which names its languages, English and/or Spanish), else the current subscription's plan
--      (limits.languages, a count). 1 language means English only; 2 lets an admin add Spanish. No plan and no
--      subscription means no limit, as before, and is reported as such (source "none"). zella_language_plan_refusal
--      gives PLAN_LANGUAGES for a choice outside the plan; zella_business_language_save and the wizard's
--      zella_setup_language_apply (now also audited, and a no op when nothing changed) both use it. Calls keep using
--      zella_language_allowance as before.
--   3. Voices follow the languages. A voice with no language (ElevenLabs, multilingual) always fits; an en or es voice
--      (Cartesia) fits only while the business speaks that language (zella_voice_fits, from the languages calls use).
--      zella_business_voice_get lists only voices that fit; zella_business_voice_save and zella_setup_voice_apply refuse
--      one that doesn't (VOICE_LANGUAGE); zella_business_voice_choice ignores a saved voice that no longer fits (for
--      example after Spanish was removed), so zella_assistant_config uses the platform default voice instead and says so
--      in its notes. It is not a problem: problems stop calls from being served, and the default voice keeps them going.
-- The eight changed functions are archived first and must be the versions this file was written for (production's,
-- with sql/zella_cartesia_voices.sql applied; zella_assistant_config may also be that version with
-- sql/zella_silence_timeout.sql applied, in either order), otherwise VERSION_MISMATCH and nothing changes. Safe to run twice.
-- Needs sql/zella_cartesia_voices.sql and sql/zella_billing_allowances.sql. Rollback: sql/rollback/zella_admin_languages_rollback.sql
begin;

do $$
begin
  if to_regclass('public.zella_function_archive') is null or to_regclass('public.business_languages') is null
     or to_regclass('public.business_plans') is null or to_regprocedure('public.zella_plan_limits(uuid)') is null
     or to_regprocedure('public.zella_billing_plan_at(uuid,timestamptz)') is null
     or to_regprocedure('public.zella_setup_voice_apply(uuid,text,uuid)') is null
     or to_regprocedure('public.zella_business_voice_choice(uuid)') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing (apply sql/zella_billing_allowances.sql and sql/zella_cartesia_voices.sql first)';
  end if;
end $$;

-- the language family a catalog code belongs to: en for every English variant, otherwise the code's first part (es-419: es)
create or replace function public.zella_language_family(p_code text) returns text
language sql immutable set search_path = '' as $$
  select case when nullif(trim(coalesce(p_code, '')), '') is null then null
              when exists (select 1 from jsonb_array_elements(public.zella_language_catalog()) e where e ->> 'code' = p_code and (e ->> 'english')::boolean) then 'en'
              else split_part(lower(trim(p_code)), '-', 1) end;
$$;
revoke all on function public.zella_language_family(text) from public, anon, authenticated;
grant execute on function public.zella_language_family(text) to service_role;

-- which plan decides a business's languages, and what it allows. No prices.
--   source business_plan: the plan in effect (as zella_plan_limits reads it), which names its languages;
--   source subscription_plan: the current subscription's plan, limits.languages (a count, or none: no limit);
--   source none: neither, so no limit.
create or replace function public.zella_language_plan_info(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare bnd jsonb; b public.business_plans; s public.subscriptions; v_name text; v_limit text; v_allow integer;
begin
  bnd := public.zella_billing_period_bounds(p_business_id, now());
  b := case when bnd is not null then public.zella_billing_plan_at(p_business_id, (bnd ->> 'from')::timestamptz) else public.zella_billing_plan_current(p_business_id) end;
  if b.id is not null then
    v_allow := greatest(cardinality(b.languages), 1);
    return jsonb_build_object('source', 'business_plan', 'plan', initcap(b.tier) || ' v' || b.version, 'allowance', v_allow,
      'plan_languages', to_jsonb(b.languages), 'spanish_allowed', 'es' = any (b.languages), 'second_language_allowed', v_allow >= 2);
  end if;
  s := public.zella_current_subscription(p_business_id);
  if s.id is not null then
    select p.name, p.limits ->> 'languages' into v_name, v_limit from public.plans p where p.id = s.plan_id;
    if v_limit ~ '^[0-9]{1,2}$' then v_allow := greatest(v_limit::integer, 1); end if;
    return jsonb_build_object('source', 'subscription_plan', 'plan', v_name, 'allowance', v_allow, 'plan_languages', null,
      'spanish_allowed', v_allow is null or v_allow >= 2, 'second_language_allowed', v_allow is null or v_allow >= 2);
  end if;
  return jsonb_build_object('source', 'none', 'plan', null, 'allowance', null, 'plan_languages', null,
    'spanish_allowed', true, 'second_language_allowed', true);
end $$;
revoke all on function public.zella_language_plan_info(uuid) from public, anon, authenticated;
grant execute on function public.zella_language_plan_info(uuid) to service_role;

-- null when the plan allows this main language and these extra ones, otherwise PLAN_LANGUAGES: more languages than the
-- plan's count; a language the business's own plan doesn't name; or, on a plan with one language and no list, anything
-- but English.
create or replace function public.zella_language_plan_refusal(p_business_id uuid, p_primary text, p_extras text[]) returns text
language plpgsql stable security definer set search_path = '' as $$
declare i jsonb := public.zella_language_plan_info(p_business_id); v_allow integer; v_all text[];
begin
  v_allow := (i ->> 'allowance')::integer;
  if v_allow is null then return null; end if;
  v_all := array(select distinct x from unnest(array[p_primary] || coalesce(p_extras, '{}')) x where x is not null);
  if cardinality(v_all) > v_allow then return 'PLAN_LANGUAGES'; end if;
  if jsonb_typeof(i -> 'plan_languages') = 'array' then
    if exists (select 1 from unnest(v_all) x
               where not (coalesce(public.zella_language_family(x), '') in (select jsonb_array_elements_text(i -> 'plan_languages')))) then
      return 'PLAN_LANGUAGES';
    end if;
  elsif v_allow < 2 and exists (select 1 from unnest(v_all) x where public.zella_language_family(x) is distinct from 'en') then
    return 'PLAN_LANGUAGES';
  end if;
  return null;
end $$;
revoke all on function public.zella_language_plan_refusal(uuid, text, text[]) from public, anon, authenticated;
grant execute on function public.zella_language_plan_refusal(uuid, text, text[]) to service_role;

-- the language families calls to this business use (en, es ...): the main language (English when none is saved) and
-- the extra ones up to the plan's allowance, the same cut zella_business_language_plan makes
create or replace function public.zella_business_voice_languages(p_business_id uuid) returns text[]
language sql stable security definer set search_path = '' as $$
  with l as (select primary_language, extra_languages from public.business_languages where business_id = p_business_id),
  codes as (
    select coalesce((select primary_language from l), 'en-US') as code
    union all
    select x from l, unnest(array(select e from unnest(l.extra_languages) e where e <> l.primary_language)) with ordinality t(x, i)
     where public.zella_language_allowance(p_business_id) is null or i <= public.zella_language_allowance(p_business_id) - 1
  )
  select coalesce(array_agg(distinct public.zella_language_family(code) order by public.zella_language_family(code)), '{}')
  from codes where public.zella_language_family(code) is not null;
$$;
revoke all on function public.zella_business_voice_languages(uuid) from public, anon, authenticated;
grant execute on function public.zella_business_voice_languages(uuid) to service_role;

-- whether an approved voice speaks this business's languages: one with no language always does
create or replace function public.zella_voice_fits(p_business_id uuid, p_choice jsonb) returns boolean
language sql stable security definer set search_path = '' as $$
  select nullif(trim(coalesce(p_choice ->> 'language', '')), '') is null
      or split_part(lower(trim(p_choice ->> 'language')), '-', 1) = any (public.zella_business_voice_languages(p_business_id));
$$;
revoke all on function public.zella_voice_fits(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.zella_voice_fits(uuid, jsonb) to service_role;

-- the business's saved approved voice when it no longer fits its languages (calls then use the default), else null
create or replace function public.zella_business_voice_unfit(p_business_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select ch from public.business_voice bv
  join jsonb_array_elements(public.zella_voice_choices()) ch on ch ->> 'id' = bv.voice_id
  where bv.business_id = p_business_id and not public.zella_voice_fits(p_business_id, ch) limit 1;
$$;
revoke all on function public.zella_business_voice_unfit(uuid) from public, anon, authenticated;
grant execute on function public.zella_business_voice_unfit(uuid) to service_role;

-- the changes in place: each function must be the version this file was written for (archived first) or exactly this
-- file's; 'def' replaces the whole function, 'edits' replace exact pieces of it
do $$
declare
  f record; e record; d text; v_new text; n integer; v_mine text;
  plan constant jsonb := jsonb_build_array(
    jsonb_build_object('sig', 'public.zella_business_language_save(uuid,text,text[],text)', 'bases', jsonb_build_object('cf6fd925e723c0f3cd1df07e4974a562', '14a58fa33813daa316c70688a36c88a2'),
      'def', $d$CREATE OR REPLACE FUNCTION public.zella_business_language_save(p_business_id uuid, p_primary text, p_extras text[], p_greeting text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_codes text[]; v_extras text[]; v_greeting text; v_old public.business_languages; v_info jsonb;
begin
  -- zella_admin_languages: only Zella Voice platform admins change languages (businesses.manage, or the zella_owner and
  -- super_admin roles); owners and staff read them with zella_business_language_get
  if auth.uid() is null or not public.zella_admin_can('businesses.manage') then raise exception 'LANGUAGES_ADMIN_ONLY'; end if;
  if not exists (select 1 from public.businesses where id = p_business_id) then raise exception 'NOT_FOUND'; end if;
  select array_agg(e ->> 'code') into v_codes from jsonb_array_elements(public.zella_language_catalog()) e;
  if p_primary is null or not (p_primary = any (v_codes)) then raise exception 'UNKNOWN_LANGUAGE'; end if;
  select coalesce(array_agg(distinct x), '{}') into v_extras from unnest(coalesce(p_extras, '{}')) x where x <> p_primary;
  if exists (select 1 from unnest(v_extras) x where not (x = any (v_codes))) then raise exception 'UNKNOWN_LANGUAGE'; end if;
  if cardinality(v_extras) > 3 then raise exception 'TOO_MANY_LANGUAGES'; end if;
  -- the plan decides (zella_language_plan_refusal): its count, its languages, and English only on a one language plan
  if public.zella_language_plan_refusal(p_business_id, p_primary, v_extras) is not null then
    v_info := public.zella_language_plan_info(p_business_id);
    raise exception 'PLAN_LANGUAGES' using hint = 'The plan includes ' || (v_info ->> 'allowance') || ' language(s), the main one included'
      || coalesce(': ' || (select string_agg(x, ', ') from jsonb_array_elements_text(case when jsonb_typeof(v_info -> 'plan_languages') = 'array' then v_info -> 'plan_languages' else '[]'::jsonb end) x), '') || '.';
  end if;
  v_greeting := nullif(trim(regexp_replace(coalesce(p_greeting, ''), '\s+', ' ', 'g')), '');
  if v_greeting is not null and length(v_greeting) not between 5 and 200 then raise exception 'GREETING_LENGTH'; end if;
  if v_greeting ~ '(https?://|www\.|[<>\[\]`]|\{(?!name\}))' then raise exception 'GREETING_TEXT'; end if;
  -- zella_call_disclosure: an English greeting must say it is an AI (other languages get the sentence added on calls)
  if v_greeting is not null and p_primary like 'en%' and v_greeting !~* (public.zella_ai_disclosure(p_primary) ->> 'marker') then raise exception 'GREETING_AI_DISCLOSURE'; end if;
  select * into v_old from public.business_languages where business_id = p_business_id for update;
  if v_old.business_id is not null and v_old.primary_language = p_primary and v_old.extra_languages = v_extras
     and v_old.greeting is not distinct from v_greeting then
    return true;   -- nothing changed: nothing to record
  end if;
  insert into public.business_languages (business_id, primary_language, extra_languages, greeting, updated_by, updated_at)
  values (p_business_id, p_primary, v_extras, v_greeting, auth.uid(), now())
  on conflict (business_id) do update set primary_language = excluded.primary_language, extra_languages = excluded.extra_languages,
    greeting = excluded.greeting, updated_by = excluded.updated_by, updated_at = now();
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, auth.uid(), 'receptionist.languages_changed', 'business', p_business_id,
          case when v_old.business_id is not null then jsonb_build_object('primary', v_old.primary_language, 'extras', to_jsonb(v_old.extra_languages), 'greeting', v_old.greeting) end,
          jsonb_build_object('primary', p_primary, 'extras', to_jsonb(v_extras), 'greeting', v_greeting, 'by_platform_admin', true, 'source', 'admin'));
  return true;
end $function$
$d$),
    jsonb_build_object('sig', 'public.zella_business_language_get(uuid)', 'bases', jsonb_build_object('a8b05515020b557f2ea53422b41714dc', 'd48d06c07deb0a2c9b2c67e454a63c9f'),
      'def', $d$CREATE OR REPLACE FUNCTION public.zella_business_language_get(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare l public.business_languages;
begin
  -- zella_admin_languages: members of the business, and platform admins who may view businesses, read the languages
  if auth.uid() is null or not (public.zella_is_member(p_business_id) or public.zella_admin_can('businesses.view')) then raise exception 'NOT_ALLOWED'; end if;
  select * into l from public.business_languages where business_id = p_business_id;
  return jsonb_build_object('primary', coalesce(l.primary_language, 'en-US'), 'extras', to_jsonb(coalesce(l.extra_languages, '{}')),
    'greeting', l.greeting, 'saved', l.business_id is not null, 'updated_at', l.updated_at,
    -- only platform admins change languages; the plan (no prices) and whether what is saved is within it
    'can_edit', public.zella_admin_can('businesses.manage'), 'admin_only', true,
    'plan', public.zella_language_plan_info(p_business_id),
    'within_plan', public.zella_language_plan_refusal(p_business_id, coalesce(l.primary_language, 'en-US'), coalesce(l.extra_languages, '{}')) is null,
    'catalog', public.zella_language_catalog());
end $function$
$d$),
    jsonb_build_object('sig', 'public.zella_setup_language_apply(uuid,text,text)', 'bases', jsonb_build_object('b7ae3fffd860a57f32966a7e26b499ab', '3ff63339ea34147dcbe4eb1ba775f8ac'),
      'def', $d$CREATE OR REPLACE FUNCTION public.zella_setup_language_apply(p_business_id uuid, p_language text, p_greeting text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_primary text; v_extras text[] := '{}'; v_greeting text; v_old public.business_languages;
begin
  -- the wizard's choices: en-US, es-US, en-US+es-US (catalog codes: en-US, es)
  case coalesce(p_language, 'en-US')
    when 'en-US' then v_primary := 'en-US';
    when 'es-US' then v_primary := 'es';
    when 'en-US+es-US' then v_primary := 'en-US'; v_extras := array['es'];
    else return jsonb_build_object('ok', false, 'reason', 'UNKNOWN_LANGUAGE');
  end case;
  -- zella_admin_languages: the plan decides, as in zella_business_language_save (owner-provision-business checks the
  -- admin's businesses.manage before it calls this server only function)
  if public.zella_language_plan_refusal(p_business_id, v_primary, v_extras) is not null then
    return jsonb_build_object('ok', false, 'reason', 'PLAN_LANGUAGES', 'plan', public.zella_language_plan_info(p_business_id));
  end if;
  v_greeting := nullif(trim(regexp_replace(coalesce(p_greeting, ''), '\s+', ' ', 'g')), '');
  if v_greeting is not null and (length(v_greeting) not between 5 and 200 or v_greeting ~ '(https?://|www\.|[<>\[\]`]|\{(?!name\}))') then
    return jsonb_build_object('ok', false, 'reason', 'GREETING_TEXT');
  end if;
  select * into v_old from business_languages where business_id = p_business_id for update;
  if v_old.business_id is not null and v_old.primary_language = v_primary and v_old.extra_languages = v_extras
     and v_old.greeting is not distinct from v_greeting then
    return jsonb_build_object('ok', true, 'primary', v_primary, 'extras', to_jsonb(v_extras), 'changed', false);
  end if;
  insert into business_languages (business_id, primary_language, extra_languages, greeting, updated_by, updated_at)
  values (p_business_id, v_primary, v_extras, v_greeting, null, now())
  on conflict (business_id) do update set primary_language = excluded.primary_language, extra_languages = excluded.extra_languages,
    greeting = excluded.greeting, updated_by = null, updated_at = now();
  insert into audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, null, 'receptionist.languages_changed', 'business', p_business_id,
          case when v_old.business_id is not null then jsonb_build_object('primary', v_old.primary_language, 'extras', to_jsonb(v_old.extra_languages), 'greeting', v_old.greeting) end,
          jsonb_build_object('primary', v_primary, 'extras', to_jsonb(v_extras), 'greeting', v_greeting, 'by_platform_admin', true, 'source', 'setup_wizard'));
  return jsonb_build_object('ok', true, 'primary', v_primary, 'extras', to_jsonb(v_extras), 'changed', true);
end $function$
$d$),
    jsonb_build_object('sig', 'public.zella_business_voice_get(uuid)', 'bases', jsonb_build_object('f5de0c950ceb8d7df4be90cbca724b27', '63955f816a465e4042f6a3849044bc56'),
      'def', $d$CREATE OR REPLACE FUNCTION public.zella_business_voice_get(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_admin boolean := public.zella_admin_can('businesses.view'); v_default text; v_unfit jsonb;
begin
  if auth.uid() is null or not (public.zella_is_member(p_business_id) or v_admin) then raise exception 'NOT_ALLOWED'; end if;
  v_default := nullif(nullif(public.zella_setting('voice_tts_voice_id', 'null'::jsonb) #>> '{}', ''), 'null');
  -- zella_admin_languages: a saved voice that no longer speaks the business's languages isn't used on calls (the
  -- default speaks instead), so it isn't shown as the choice; unfit_voice_id names it
  v_unfit := public.zella_business_voice_unfit(p_business_id);
  return jsonb_build_object(
    'voice_id', case when v_unfit is null then (select voice_id from public.business_voice where business_id = p_business_id) end,
    'default_voice_id', v_default,
    'provider', coalesce(public.zella_setting('voice_tts_provider', '"11labs"'::jsonb) #>> '{}', '11labs'),
    -- only the voices that speak the business's languages (a voice with no language speaks them all)
    'choices', (select coalesce(jsonb_agg(c order by n), '[]'::jsonb) from jsonb_array_elements(public.zella_voice_choices()) with ordinality x(c, n)
                where public.zella_voice_fits(p_business_id, c)),
    'languages', to_jsonb(public.zella_business_voice_languages(p_business_id)),
    'unfit_voice_id', v_unfit ->> 'id',
    'updated_at', (select updated_at from public.business_voice where business_id = p_business_id),
    'can_edit', public.zella_can_manage(p_business_id) or public.zella_admin_can('ai.configure'));
end $function$
$d$),
    jsonb_build_object('sig', 'public.zella_business_voice_save(uuid,text)', 'bases', jsonb_build_object('59eb19efa4867a2b37abb13cc312cbb5', 'cd7cd28898995846a156fa1c5c31dab9'),
      'edits', jsonb_build_array(jsonb_build_object('count', 1,
        'anchor', $a$    raise exception 'UNKNOWN_VOICE';
  end if;
$a$,
        'with', $w$    raise exception 'UNKNOWN_VOICE';
  end if;
  -- zella_admin_languages: only a voice that speaks the business's languages
  if v_new is not null and not public.zella_voice_fits(p_business_id, (select c from jsonb_array_elements(public.zella_voice_choices()) c where c ->> 'id' = v_new limit 1)) then
    raise exception 'VOICE_LANGUAGE';
  end if;
$w$))),
    jsonb_build_object('sig', 'public.zella_setup_voice_apply(uuid,text,uuid)', 'bases', jsonb_build_object('778585e11ecce397967bf0a9ab251380', 'b2b29c7f4aa337003b0854235e73ce6b'),
      'edits', jsonb_build_array(jsonb_build_object('count', 1,
        'anchor', $a$    if v_choice is null then return jsonb_build_object('ok', false, 'reason', 'UNKNOWN_VOICE'); end if;
$a$,
        'with', $w$    if v_choice is null then return jsonb_build_object('ok', false, 'reason', 'UNKNOWN_VOICE'); end if;
    -- zella_admin_languages: only a voice that speaks the business's languages
    if not public.zella_voice_fits(p_business_id, v_choice) then return jsonb_build_object('ok', false, 'reason', 'VOICE_LANGUAGE'); end if;
$w$))),
    jsonb_build_object('sig', 'public.zella_business_voice_choice(uuid)', 'bases', jsonb_build_object('43d2361fe15ef605648317d67a5a1215', '580de72ac835968c0ed83b2ef2c3aca5'),
      'edits', jsonb_build_array(jsonb_build_object('count', 1,
        'anchor', $a$  where bv.business_id = p_business_id limit 1;$a$,
        'with', $w$  where bv.business_id = p_business_id and public.zella_voice_fits(p_business_id, ch) limit 1;   /* zella_admin_languages */$w$))),
    jsonb_build_object('sig', 'public.zella_assistant_config(uuid)', 'bases', jsonb_build_object(
      'e2ae7cfcd60ebf32a7d6bd2247e39ab3', '89e090f31515920ac198874946e15780',    -- production (zella_cartesia_voices applied)
      '7cb1c1ad81a872b2118d66db2eeba959', '36ba71051bc6382c08e782d0a9754e20'),   -- production with zella_silence_timeout applied
      'edits', jsonb_build_array(jsonb_build_object('count', 1,
        'anchor', $a$  if v_voice ->> 'provider' = 'cartesia' and not (v_voice ? 'model') then
$a$,
        'with', $w$  -- zella_admin_languages: a saved voice that no longer speaks the business's languages (for example after Spanish
  -- was removed) is not used (zella_business_voice_choice): the platform default voice speaks, and the notes say so
  if public.zella_business_voice_unfit(p_business_id) is not null then
    v_lang_notes := v_lang_notes || ('The saved voice ' || coalesce(public.zella_business_voice_unfit(p_business_id) ->> 'name', public.zella_business_voice_unfit(p_business_id) ->> 'id')
      || ' does not speak this business''s languages, so calls use the Zella Voice default voice. Choose another voice.')::text;
  end if;
  if v_voice ->> 'provider' = 'cartesia' and not (v_voice ? 'model') then
$w$))));
begin
  -- 'bases' maps each version this file was written for to the version it makes of it; a function already at one of
  -- those results is left alone (applied before)
  for f in select x from jsonb_array_elements(plan) x loop
    if to_regprocedure(f.x ->> 'sig') is null then raise exception 'VERSION_MISMATCH: % is missing', f.x ->> 'sig'; end if;
    d := pg_get_functiondef((f.x ->> 'sig')::regprocedure);
    if exists (select 1 from jsonb_each_text(f.x -> 'bases') b where b.value = md5(d)) then continue; end if;   -- already applied
    if not (f.x -> 'bases' ? md5(d)) then raise exception 'VERSION_MISMATCH: % is not a version this file was written for', f.x ->> 'sig'; end if;
  end loop;
  for f in select x from jsonb_array_elements(plan) x loop
    d := pg_get_functiondef((f.x ->> 'sig')::regprocedure);
    continue when exists (select 1 from jsonb_each_text(f.x -> 'bases') b where b.value = md5(d));
    v_mine := f.x -> 'bases' ->> md5(d);
    if f.x ? 'def' then
      v_new := f.x ->> 'def';
    else
      v_new := d;
      for e in select y from jsonb_array_elements(f.x -> 'edits') y loop
        n := (length(v_new) - length(replace(v_new, e.y ->> 'anchor', ''))) / length(e.y ->> 'anchor');
        if n <> (e.y ->> 'count')::integer then raise exception 'VERSION_MISMATCH: % anchor found % times', f.x ->> 'sig', n; end if;
        v_new := replace(v_new, e.y ->> 'anchor', e.y ->> 'with');
      end loop;
    end if;
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_admin_languages', f.x ->> 'sig', d, md5(d)) on conflict (migration, signature) do nothing;
    execute v_new;
    if md5(pg_get_functiondef((f.x ->> 'sig')::regprocedure)) <> v_mine then
      raise exception 'VERSION_MISMATCH: % did not come out as this file''s version', f.x ->> 'sig';
    end if;
  end loop;
end $$;

commit;
