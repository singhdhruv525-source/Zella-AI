-- Zella - languages per business for the AI receptionist (2026-10-28). Safe to re-run.
-- Needs sql/zella_voice_assistant.sql (zella_assistant_config v2) and sql/zella_voice_reliability.sql (zella_patch_function).
--
-- Each business picks the language its receptionist greets in and up to three more it may switch to when a caller
-- speaks them. zella_assistant_config then sends Vapi:
--   - transcriber language: the main language, or "multi" (Deepgram code-switching) when there are extra languages;
--   - for anything other than English only: the transcriber model from the platform setting
--     voice_stt_model_multilingual (no default: the Zella team picks a Deepgram model that supports the languages;
--     until then the config says it isn't ready) and the ElevenLabs model eleven_multilingual_v2;
--   - a greeting in the main language (or the business's own) and language rules added to the system prompt.
-- English-only businesses are unchanged except that an English variant (en-GB, en-IN...) is passed to the transcriber.
-- Every language code is in DeepgramTranscriberLanguage and the voice model in ElevenLabsVoiceModel
-- (@vapi-ai/server-sdk 3.0.0, checked 2026-10-28). No voice id or transcriber model is chosen here.
-- Rollback: drop table public.business_languages; drop the zella_language_* / zella_business_language_* functions;
--   re-run sql/zella_voice_assistant.sql.

create table if not exists public.business_languages (
  business_id uuid primary key references public.businesses (id) on delete cascade,
  primary_language text not null default 'en-US',
  extra_languages text[] not null default '{}',
  greeting text check (greeting is null or length(greeting) between 5 and 200),
  updated_by uuid,
  updated_at timestamptz not null default now(),
  constraint business_languages_extra_max check (cardinality(extra_languages) <= 3)
);
alter table public.business_languages enable row level security;
drop policy if exists business_languages_read on public.business_languages;
create policy business_languages_read on public.business_languages for select to authenticated using (public.zella_is_member(business_id));
revoke insert, update, delete on public.business_languages from anon, authenticated;

-- The languages offered, each a DeepgramTranscriberLanguage code. The greeting is the default first sentence;
-- {name} becomes the business name. A business can write its own instead.
create or replace function public.zella_language_catalog() returns jsonb
language sql immutable as $$
  select jsonb_build_array(
    jsonb_build_object('code', 'en-US', 'label', 'English (US)', 'english', true, 'greeting', 'Thank you for calling {name}. How can I help you?'),
    jsonb_build_object('code', 'en-GB', 'label', 'English (UK)', 'english', true, 'greeting', 'Thank you for calling {name}. How can I help you?'),
    jsonb_build_object('code', 'en-AU', 'label', 'English (Australia)', 'english', true, 'greeting', 'Thank you for calling {name}. How can I help you?'),
    jsonb_build_object('code', 'en-IN', 'label', 'English (India)', 'english', true, 'greeting', 'Thank you for calling {name}. How can I help you?'),
    jsonb_build_object('code', 'en-NZ', 'label', 'English (New Zealand)', 'english', true, 'greeting', 'Thank you for calling {name}. How can I help you?'),
    jsonb_build_object('code', 'es', 'label', 'Spanish', 'english', false, 'greeting', 'Gracias por llamar a {name}. ¿En qué puedo ayudarle?'),
    jsonb_build_object('code', 'es-419', 'label', 'Spanish (Latin America)', 'english', false, 'greeting', 'Gracias por llamar a {name}. ¿En qué le puedo ayudar?'),
    jsonb_build_object('code', 'hi', 'label', 'Hindi', 'english', false, 'greeting', '{name} में कॉल करने के लिए धन्यवाद। बताइए, मैं आपकी कैसे मदद करूँ?'),
    jsonb_build_object('code', 'fr', 'label', 'French', 'english', false, 'greeting', 'Merci d''avoir appelé {name}. Comment puis-je vous aider ?'),
    jsonb_build_object('code', 'fr-CA', 'label', 'French (Canada)', 'english', false, 'greeting', 'Merci d''avoir appelé {name}. Comment puis-je vous aider?'),
    jsonb_build_object('code', 'de', 'label', 'German', 'english', false, 'greeting', 'Vielen Dank für Ihren Anruf bei {name}. Wie kann ich Ihnen helfen?'),
    jsonb_build_object('code', 'pt-BR', 'label', 'Portuguese (Brazil)', 'english', false, 'greeting', 'Obrigado por ligar para {name}. Como posso ajudar?'),
    jsonb_build_object('code', 'it', 'label', 'Italian', 'english', false, 'greeting', 'Grazie per aver chiamato {name}. Come posso aiutarla?'),
    jsonb_build_object('code', 'nl', 'label', 'Dutch', 'english', false, 'greeting', 'Bedankt voor het bellen naar {name}. Waarmee kan ik u helpen?'),
    jsonb_build_object('code', 'pl', 'label', 'Polish', 'english', false, 'greeting', 'Dzień dobry, tu {name}. W czym mogę pomóc?'),
    jsonb_build_object('code', 'ru', 'label', 'Russian', 'english', false, 'greeting', 'Здравствуйте, это {name}. Чем могу помочь?'),
    jsonb_build_object('code', 'tr', 'label', 'Turkish', 'english', false, 'greeting', 'Merhaba, {name}. Size nasıl yardımcı olabilirim?'),
    jsonb_build_object('code', 'ta', 'label', 'Tamil', 'english', false, 'greeting', 'வணக்கம், {name}. நான் உங்களுக்கு எப்படி உதவலாம்?'),
    jsonb_build_object('code', 'vi', 'label', 'Vietnamese', 'english', false, 'greeting', 'Xin chào, đây là {name}. Tôi có thể giúp gì cho quý khách?'),
    jsonb_build_object('code', 'id', 'label', 'Indonesian', 'english', false, 'greeting', 'Terima kasih telah menghubungi {name}. Ada yang bisa saya bantu?'),
    jsonb_build_object('code', 'ja', 'label', 'Japanese', 'english', false, 'greeting', '{name}にお電話いただきありがとうございます。ご用件をお伺いします。'),
    jsonb_build_object('code', 'ko', 'label', 'Korean', 'english', false, 'greeting', '{name}에 전화해 주셔서 감사합니다. 무엇을 도와드릴까요?'),
    jsonb_build_object('code', 'zh-CN', 'label', 'Chinese (Mandarin, Simplified)', 'english', false, 'greeting', '感谢您致电{name}。请问有什么可以帮您？'));
$$;
grant execute on function public.zella_language_catalog() to authenticated, service_role;

-- What zella_assistant_config does for one business: mode 'default' (nothing set), 'english' (English only) or
-- 'other' (any other language involved); the transcriber language; the greeting; the extra prompt text.
create or replace function public.zella_business_language_plan(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare l public.business_languages; v_cat jsonb := public.zella_language_catalog(); v_main jsonb; v_extra jsonb; v_name text;
  v_labels text; v_all_english boolean; v_greeting text; v_prompt text;
begin
  select * into l from public.business_languages where business_id = p_business_id;
  if l.business_id is null then return jsonb_build_object('mode', 'default'); end if;
  select e into v_main from jsonb_array_elements(v_cat) e where e ->> 'code' = l.primary_language;
  if v_main is null then return jsonb_build_object('mode', 'default'); end if;
  select coalesce(jsonb_agg(e order by array_position(l.extra_languages, e ->> 'code')), '[]'::jsonb) into v_extra
    from jsonb_array_elements(v_cat) e where e ->> 'code' = any (l.extra_languages) and e ->> 'code' <> l.primary_language;
  select coalesce(b.name, 'us') into v_name from public.businesses b where b.id = p_business_id;
  v_all_english := (v_main ->> 'english')::boolean and not exists (select 1 from jsonb_array_elements(v_extra) x where not (x ->> 'english')::boolean);
  v_greeting := replace(coalesce(nullif(trim(l.greeting), ''), v_main ->> 'greeting'), '{name}', v_name);
  -- English only (extra English variants change nothing: the transcriber already understands them)
  if v_all_english then
    return jsonb_build_object('mode', 'english', 'stt_language', l.primary_language, 'greeting', v_greeting);
  end if;
  select string_agg(x ->> 'label', ', ') into v_labels from jsonb_array_elements(v_extra) x;
  v_prompt := E'\n\nLANGUAGES\n- Greet the caller and speak in ' || (v_main ->> 'label') || E' unless the caller uses another language below.\n'
    || case when v_labels is not null then '- If the caller speaks ' || v_labels || E', switch to that language and keep using it for the rest of the call.\n' else '' end
    || '- If the caller uses any other language, say politely in ' || (v_main ->> 'label') || ' that you can help in '
    || (v_main ->> 'label') || coalesce(', ' || v_labels, '') || E' and offer to take a message.\n'
    || E'- Tool answers and instructions are written in English: always say them to the caller in the caller''s language, in your own words. Dates, times and names stay exactly as given.\n';
  return jsonb_build_object('mode', 'other',
    'stt_language', case when jsonb_array_length(v_extra) > 0 then 'multi' else l.primary_language end,
    'greeting', v_greeting, 'prompt', v_prompt,
    'languages', (select jsonb_agg(x ->> 'label') from (select v_main as x union all select e from jsonb_array_elements(v_extra) e) z));
end $$;
revoke all on function public.zella_business_language_plan(uuid) from public, anon, authenticated;
grant execute on function public.zella_business_language_plan(uuid) to service_role;

create or replace function public.zella_business_language_get(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare l public.business_languages;
begin
  if auth.uid() is null or not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select * into l from public.business_languages where business_id = p_business_id;
  return jsonb_build_object('primary', coalesce(l.primary_language, 'en-US'), 'extras', to_jsonb(coalesce(l.extra_languages, '{}')),
    'greeting', l.greeting, 'saved', l.business_id is not null, 'updated_at', l.updated_at,
    'can_edit', public.zella_can_manage(p_business_id), 'catalog', public.zella_language_catalog());
end $$;
revoke all on function public.zella_business_language_get(uuid) from public, anon;
grant execute on function public.zella_business_language_get(uuid) to authenticated;

create or replace function public.zella_business_language_save(p_business_id uuid, p_primary text, p_extras text[], p_greeting text)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_codes text[]; v_extras text[]; v_greeting text;
begin
  if auth.uid() is null or not public.zella_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select array_agg(e ->> 'code') into v_codes from jsonb_array_elements(public.zella_language_catalog()) e;
  if p_primary is null or not (p_primary = any (v_codes)) then raise exception 'UNKNOWN_LANGUAGE'; end if;
  select coalesce(array_agg(distinct x), '{}') into v_extras from unnest(coalesce(p_extras, '{}')) x where x <> p_primary;
  if exists (select 1 from unnest(v_extras) x where not (x = any (v_codes))) then raise exception 'UNKNOWN_LANGUAGE'; end if;
  if cardinality(v_extras) > 3 then raise exception 'TOO_MANY_LANGUAGES'; end if;
  v_greeting := nullif(trim(regexp_replace(coalesce(p_greeting, ''), '\s+', ' ', 'g')), '');
  if v_greeting is not null and length(v_greeting) not between 5 and 200 then raise exception 'GREETING_LENGTH'; end if;
  -- the greeting is spoken as the first thing on every call: no links, no instructions-looking braces other than {name}
  if v_greeting ~ '(https?://|www\.|[<>\[\]`]|\{(?!name\}))' then raise exception 'GREETING_TEXT'; end if;
  insert into public.business_languages (business_id, primary_language, extra_languages, greeting, updated_by, updated_at)
  values (p_business_id, p_primary, v_extras, v_greeting, auth.uid(), now())
  on conflict (business_id) do update set primary_language = excluded.primary_language, extra_languages = excluded.extra_languages,
    greeting = excluded.greeting, updated_by = excluded.updated_by, updated_at = now();
  return true;
end $$;
revoke all on function public.zella_business_language_save(uuid, text, text[], text) from public, anon;
grant execute on function public.zella_business_language_save(uuid, text, text[], text) to authenticated;

insert into public.platform_settings (key, value) values ('voice_stt_model_multilingual', 'null'::jsonb) on conflict (key) do nothing;

-- zella_assistant_config: the business's language(s). Four exact pieces of the v2 body.
do $$
declare sig text := 'public.zella_assistant_config(uuid)';
begin
  perform public.zella_patch_function(sig, 'v_lang jsonb;',
    E'  v_voice jsonb; v_transcriber jsonb; v_max integer;\n',
    E'  v_voice jsonb; v_transcriber jsonb; v_max integer;\n  v_lang jsonb; v_lang_notes text[] := ''{}''; v_stt_multi text;\n');
  perform public.zella_patch_function(sig, 'zella_languages',
    E'  v_transfer := coalesce((c #>> ''{agent,escalation,transfer_enabled}'')::boolean, true);\n',
    E'  v_transfer := coalesce((c #>> ''{agent,escalation,transfer_enabled}'')::boolean, true);\n'
    || E'  -- zella_languages: the business''s own language(s) (sql/zella_languages.sql)\n'
    || E'  v_lang := public.zella_business_language_plan(p_business_id);\n'
    || E'  if v_lang ->> ''mode'' = ''english'' and v_transcriber is not null then\n'
    || E'    v_transcriber := v_transcriber || jsonb_build_object(''language'', v_lang ->> ''stt_language'');\n'
    || E'  elsif v_lang ->> ''mode'' = ''other'' then\n'
    || E'    v_stt_multi := nullif(nullif(public.zella_setting(''voice_stt_model_multilingual'', ''null''::jsonb) #>> ''{}'', ''''), ''null'');\n'
    || E'    if v_stt_multi is null then\n'
    || E'      v_problems := v_problems || (''voice_stt_model_multilingual is not set (choose a Deepgram model that supports '' || (select string_agg(x, '', '') from jsonb_array_elements_text(v_lang -> ''languages'') x) || '')'')::text;\n'
    || E'    elsif not (v_stt_multi = any (v_deepgram_models)) then\n'
    || E'      v_problems := v_problems || (''voice_stt_model_multilingual '' || v_stt_multi || '' is not a Deepgram model Vapi lists'')::text;\n'
    || E'    end if;\n'
    || E'    v_transcriber := jsonb_build_object(''provider'', v_stt_provider, ''model'', v_stt_multi, ''language'', v_lang ->> ''stt_language'');\n'
    || E'    if v_voice is not null then v_voice := v_voice || jsonb_build_object(''model'', ''eleven_multilingual_v2''); end if;\n'
    || E'    v_lang_notes := v_lang_notes || (''Test a call in each language: '' || (select string_agg(x, '', '') from jsonb_array_elements_text(v_lang -> ''languages'') x) || ''. Check the voice sounds right in each.'')::text;\n'
    || E'  end if;\n');
  perform public.zella_patch_function(sig, 'v_lang ->> ''greeting''',
    E'''firstMessage'', ''Thank you for calling '' || (c #>> ''{business,name}'') || ''. How can I help you?'',',
    E'''firstMessage'', coalesce(v_lang ->> ''greeting'', ''Thank you for calling '' || (c #>> ''{business,name}'') || ''. How can I help you?''),');
  perform public.zella_patch_function(sig, 'v_lang ->> ''prompt''',
    E'public.zella_brain_prompt(p_business_id))),',
    E'public.zella_brain_prompt(p_business_id) || coalesce(v_lang ->> ''prompt'', ''''))),');
  perform public.zella_patch_function(sig, '''notes'', to_jsonb(v_lang_notes)',
    E'''problems'', to_jsonb(v_problems));',
    E'''problems'', to_jsonb(v_problems), ''notes'', to_jsonb(v_lang_notes));');
end $$;

create or replace function public.zella_languages_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'table', to_regclass('public.business_languages') is not null,
    'assistant_config', pg_get_functiondef('public.zella_assistant_config(uuid)'::regprocedure) like '%zella_languages%'
                        and pg_get_functiondef('public.zella_assistant_config(uuid)'::regprocedure) like '%v_lang ->> ''prompt''%'
                        and pg_get_functiondef('public.zella_assistant_config(uuid)'::regprocedure) like '%v_lang ->> ''greeting''%');
$$;
revoke all on function public.zella_languages_status() from public, anon, authenticated;
grant execute on function public.zella_languages_status() to service_role;
