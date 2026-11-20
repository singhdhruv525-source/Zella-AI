-- Zella Voice: callers are told they are speaking with an AI receptionist, and that the call is recorded when it is
-- (security audit 18 Nov 2026, 12.1, H4; owner decisions 18 Nov 2026). The greeting said neither, and the assistant
-- left recording to Vapi's own default.
--   1. The standard greeting is now "Thank you for calling {name}. I'm the AI receptionist. How can I help you today?"
--      (the five English entries of zella_language_catalog). Each business can still write its own greeting.
--   2. The AI disclosure can't be removed: zella_call_greeting (server only) builds the greeting the assistant says. If
--      the business's greeting doesn't say it is an AI (in the greeting's language), the standard sentence for that
--      language is added. zella_business_language_save also refuses an English greeting without "AI"
--      (GREETING_AI_DISCLOSURE), so the owner sees why.
--   3. "This call is recorded." (or the legal wording in recording_disclosure_text) is added only while
--      zella_recording_effective says recording is on for that business (sql/zella_recording_policy.sql: off for every
--      business until legal approval).
--   4. The assistant sends Vapi artifactPlan.recordingEnabled from the same function, so recording is explicitly off
--      unless it is on for that business.
-- zella_assistant_config, zella_language_catalog and zella_business_language_save are changed in place (small text
-- changes, archived first) and must match production (18 Nov 2026), otherwise VERSION_MISMATCH.
-- Needs sql/zella_recording_policy.sql. Rollback: sql/rollback/zella_call_disclosure_rollback.sql
begin;

-- the AI disclosure in each language the receptionist speaks: the sentence added when a greeting lacks it, and what
-- counts as saying it. Translations other than English need a native speaker's check (owner item).
create or replace function public.zella_ai_disclosure(p_lang text) returns jsonb
language sql immutable set search_path = '' as $$
  -- the marker is an explicit statement that the receptionist is an AI, never a bare "AI" (a business can be called
  -- "AI Dental")
  select case split_part(coalesce(p_lang, 'en'), '-', 1)
    when 'es' then '{"sentence": "Soy la recepcionista virtual con inteligencia artificial.", "marker": "(recepcionista|asistente) (virtual|de inteligencia artificial)|con inteligencia artificial"}'
    when 'fr' then '{"sentence": "Je suis la réceptionniste virtuelle, une intelligence artificielle.", "marker": "(réceptionniste|assistante?) virtuelle?|une intelligence artificielle"}'
    when 'de' then '{"sentence": "Ich bin eine virtuelle Rezeptionistin mit künstlicher Intelligenz.", "marker": "mit künstlicher Intelligenz|virtuelle (Rezeptionistin|Assistentin)"}'
    when 'pt' then '{"sentence": "Sou a recepcionista virtual com inteligência artificial.", "marker": "(recepcionista|assistente) virtual|com inteligência artificial"}'
    when 'it' then '{"sentence": "Sono la receptionist virtuale con intelligenza artificiale.", "marker": "(receptionist|assistente) virtuale|con intelligenza artificiale"}'
    when 'nl' then '{"sentence": "Ik ben de virtuele receptioniste met kunstmatige intelligentie.", "marker": "virtuele (receptioniste|assistent)|met kunstmatige intelligentie"}'
    when 'pl' then '{"sentence": "Jestem wirtualną recepcjonistką opartą na sztucznej inteligencji.", "marker": "wirtualn\\S* (recepcjonistk|asystent)|na sztucznej inteligencji"}'
    when 'ru' then '{"sentence": "Я виртуальный администратор на основе искусственного интеллекта.", "marker": "виртуальн\\S* (администратор|ассистент)|на основе искусственного интеллекта"}'
    when 'tr' then '{"sentence": "Ben yapay zekâ destekli sanal resepsiyonistim.", "marker": "sanal (resepsiyonist|asistan)|yapay zek[aâ] destekli"}'
    when 'ta' then '{"sentence": "நான் செயற்கை நுண்ணறிவு வரவேற்பாளர்.", "marker": "செயற்கை நுண்ணறிவு வரவேற்பாளர்"}'
    when 'vi' then '{"sentence": "Tôi là lễ tân ảo sử dụng trí tuệ nhân tạo.", "marker": "lễ tân ảo|trợ lý ảo|sử dụng trí tuệ nhân tạo"}'
    when 'id' then '{"sentence": "Saya resepsionis virtual berbasis kecerdasan buatan.", "marker": "(resepsionis|asisten) virtual|berbasis kecerdasan buatan"}'
    when 'hi' then '{"sentence": "मैं एआई रिसेप्शनिस्ट हूँ।", "marker": "एआई (रिसेप्शनिस्ट|सहायक)"}'
    when 'ja' then '{"sentence": "私はAI受付です。", "marker": "AI(受付|アシスタント)"}'
    when 'ko' then '{"sentence": "저는 AI 상담원입니다.", "marker": "AI ?(상담원|비서|안내원)"}'
    when 'zh' then '{"sentence": "我是AI接待员。", "marker": "AI(接待员|助手|客服)"}'
    else '{"sentence": "I''m the AI receptionist.", "marker": "\\m(an?|the|your) (AI|artificial intelligence|virtual) (receptionist|assistant|agent)\\M|\\mI''m an? AI\\M"}' end::jsonb
$$;

-- the greeting the caller hears: the business's (or the standard one), always with the AI disclosure, and the
-- recording line only while recording is on for that business
create or replace function public.zella_call_greeting(p_business_id uuid, p_greeting text) returns text
language plpgsql stable security definer set search_path = '' as $$
declare v_name text; v_lang text; v_d jsonb; v_g text; v_rec text;
begin
  select coalesce(nullif(trim(b.name), ''), 'us') into v_name from public.businesses b where b.id = p_business_id;
  select l.primary_language into v_lang from public.business_languages l where l.business_id = p_business_id;
  v_lang := coalesce(v_lang, 'en-US');
  v_g := nullif(trim(coalesce(p_greeting, '')), '');
  if v_g is null then
    v_g := replace('Thank you for calling {name}. I''m the AI receptionist. How can I help you today?', '{name}', coalesce(v_name, 'us'));
  end if;
  -- recording wording is managed here, never kept from a saved greeting: removed, then added only while recording is on
  -- only the clause goes: one after a comma keeps what follows it; one that starts a sentence goes with its end mark
  v_g := regexp_replace(v_g, ',\s*[^.!?,]*\m(this|the|your) call (is|may be|will be) (being )?recorded[^.!?,]*', '', 'gi');
  v_g := btrim(regexp_replace(v_g, '\s*[^.!?,]*\m(this|the|your) call (is|may be|will be) (being )?recorded[^.!?,]*[.!?,]?', '', 'gi'));
  v_d := public.zella_ai_disclosure(v_lang);
  if v_g !~* (v_d ->> 'marker') then v_g := v_g || ' ' || (v_d ->> 'sentence'); end if;
  if public.zella_recording_effective(p_business_id) then
    v_rec := nullif(trim(coalesce(public.zella_setting('recording_disclosure_text', '""'::jsonb) #>> '{}', '')), '');
    v_g := v_g || ' ' || coalesce(v_rec, 'This call is recorded.');
  end if;
  return v_g;
end $$;
revoke all on function public.zella_ai_disclosure(text) from public, anon;
grant execute on function public.zella_ai_disclosure(text) to authenticated, service_role;
revoke all on function public.zella_call_greeting(uuid, text) from public, anon, authenticated;
grant execute on function public.zella_call_greeting(uuid, text) to service_role;

-- the three changes in place: each function must be production's version (archived first) or exactly this file's
do $$
declare
  f record; d text; v_new text; n integer;
  plan constant jsonb := jsonb_build_array(
    jsonb_build_object('sig', 'public.zella_language_catalog()', 'prod', 'cecccd5b19f78122e3e6cfb3e1dcf31b', 'mine', 'ee4cda5da339a236547506ace897a62b', 'count', 5,
      'anchor', $a$'greeting', 'Thank you for calling {name}. How can I help you?')$a$,
      'with', $w$'greeting', 'Thank you for calling {name}. I''m the AI receptionist. How can I help you today?')$w$),
    jsonb_build_object('sig', 'public.zella_business_language_save(uuid,text,text[],text)', 'prod', 'fe89c51e45cf0af18720e1b007f5a4e3', 'mine', 'cf6fd925e723c0f3cd1df07e4974a562', 'count', 1,
      'anchor', $a$  if v_greeting ~ '(https?://|www\.|[<>\[\]`]|\{(?!name\}))' then raise exception 'GREETING_TEXT'; end if;
$a$,
      'with', $w$  if v_greeting ~ '(https?://|www\.|[<>\[\]`]|\{(?!name\}))' then raise exception 'GREETING_TEXT'; end if;
  -- zella_call_disclosure: an English greeting must say it is an AI (other languages get the sentence added on calls)
  if v_greeting is not null and p_primary like 'en%' and v_greeting !~* (public.zella_ai_disclosure(p_primary) ->> 'marker') then raise exception 'GREETING_AI_DISCLOSURE'; end if;
$w$),
    jsonb_build_object('sig', 'public.zella_assistant_config(uuid)', 'prod', '99dadcfe4ae7812d2126146882f07241', 'mine', '99666d94ffea6b2aeff3f680405b30c9', 'count', 1,
      'anchor', $a$      'firstMessage', coalesce(v_lang ->> 'greeting', 'Thank you for calling ' || (c #>> '{business,name}') || '. How can I help you?'),
$a$,
      'with', $w$      'firstMessage', public.zella_call_greeting(p_business_id, v_lang ->> 'greeting'),   /* zella_call_disclosure */
      'artifactPlan', jsonb_build_object('recordingEnabled', public.zella_recording_effective(p_business_id)),
$w$));
begin
  if to_regclass('public.zella_function_archive') is null or to_regprocedure('public.zella_recording_effective(uuid)') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing (apply sql/zella_recording_policy.sql first)';
  end if;
  for f in select x from jsonb_array_elements(plan) x loop
    if to_regprocedure(f.x ->> 'sig') is null then raise exception 'VERSION_MISMATCH: % is missing', f.x ->> 'sig'; end if;
    d := pg_get_functiondef((f.x ->> 'sig')::regprocedure);
    continue when md5(d) = f.x ->> 'mine';   -- already applied
    if md5(d) <> f.x ->> 'prod' then raise exception 'VERSION_MISMATCH: % is not a version this file was written for', f.x ->> 'sig'; end if;
    n := (length(d) - length(replace(d, f.x ->> 'anchor', ''))) / length(f.x ->> 'anchor');
    if n <> (f.x ->> 'count')::integer then raise exception 'VERSION_MISMATCH: % anchor found % times', f.x ->> 'sig', n; end if;
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_call_disclosure', f.x ->> 'sig', d, md5(d)) on conflict (migration, signature) do nothing;
    v_new := replace(d, f.x ->> 'anchor', f.x ->> 'with');
    execute v_new;
    if f.x ->> 'mine' not like '\_\_%' and md5(pg_get_functiondef((f.x ->> 'sig')::regprocedure)) <> f.x ->> 'mine' then
      raise exception 'VERSION_MISMATCH: % did not come out as this file''s version', f.x ->> 'sig';
    end if;
  end loop;
end $$;

commit;
