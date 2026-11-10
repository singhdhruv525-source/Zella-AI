-- Languages per business (staging only).
\i ../voice-reliability/fixture.sql
\i ../voice-reliability/phase4_reference.sql
delete from public.business_languages; delete from public.business_members;
update businesses set industry_id = (select id from industries where slug = 'dental') where id = 'aaaaaaaa-0000-4000-8000-000000000001';
insert into platform_settings (key, value) values ('vapi_server_url', '"https://pffqxlumqhjdbzvvoszm.supabase.co/functions/v1/voice-rules"'),
  ('vapi_credential_id', '"cred-test-123"'), ('voice_llm_model', '"claude-sonnet-5"'), ('voice_tts_voice_id', '"test-voice-id"'), ('voice_stt_model_multilingual', 'null')
  on conflict (key) do update set value = excluded.value;
insert into business_members (business_id, user_id, role, status) values
  ('aaaaaaaa-0000-4000-8000-000000000001', '0aaaaaaa-0000-4000-8000-000000000001', 'owner', 'active'),
  ('aaaaaaaa-0000-4000-8000-000000000001', '0aaaaaaa-0000-4000-8000-000000000002', 'staff', 'active');

do $$
declare r jsonb; asst jsonb; A uuid := 'aaaaaaaa-0000-4000-8000-000000000001'; v_err text;
begin
  r := zella_assistant_config(A); asst := r -> 'assistant';
  assert (r ->> 'ready_to_send')::boolean, 'baseline ready ' || (r -> 'problems')::text;
  assert asst ->> 'firstMessage' = 'Thank you for calling Bright Smile Dental. How can I help you?' and asst #>> '{transcriber,language}' = 'en-US'
     and asst #>> '{transcriber,model}' = 'nova-2-phonecall' and (asst #>> '{voice,model}') is null, asst::text;
  assert asst #>> '{model,messages,0,content}' not like '%LANGUAGES%' and jsonb_array_length(r -> 'notes') = 0;
  raise notice 'PASS a business with no language set gets exactly the English assistant it had before';

  perform set_config('request.jwt.claim.sub', '0aaaaaaa-0000-4000-8000-000000000001', true);
  perform zella_business_language_save(A, 'en-GB', '{}', null);
  perform set_config('request.jwt.claim.sub', '', true);
  asst := zella_assistant_config(A) -> 'assistant';
  assert asst #>> '{transcriber,language}' = 'en-GB' and asst #>> '{transcriber,model}' = 'nova-2-phonecall' and asst #>> '{model,messages,0,content}' not like '%LANGUAGES%', asst::text;
  raise notice 'PASS English (UK): only the transcriber''s English variant changes';

  perform set_config('request.jwt.claim.sub', '0aaaaaaa-0000-4000-8000-000000000001', true);
  perform zella_business_language_save(A, 'es', '{}', null);
  perform set_config('request.jwt.claim.sub', '', true);
  r := zella_assistant_config(A); asst := r -> 'assistant';
  assert not (r ->> 'ready_to_send')::boolean and (r -> 'problems')::text like '%voice_stt_model_multilingual is not set%Spanish%', r::text;
  assert asst ->> 'firstMessage' = 'Gracias por llamar a Bright Smile Dental. ¿En qué puedo ayudarle?' and asst #>> '{transcriber,language}' = 'es'
     and asst #>> '{voice,model}' = 'eleven_multilingual_v2' and asst #>> '{voice,voiceId}' = 'test-voice-id' and not (asst -> 'transcriber') ? 'model', asst::text;
  assert asst #>> '{model,messages,0,content}' like '%LANGUAGES%speak in Spanish%', 'prompt';
  raise notice 'PASS Spanish: Spanish greeting, transcriber in Spanish, multilingual voice model; not ready until a multilingual transcriber model is chosen';

  update platform_settings set value = '"nova-3"' where key = 'voice_stt_model_multilingual';
  r := zella_assistant_config(A);
  assert (r ->> 'ready_to_send')::boolean and r #>> '{assistant,transcriber,model}' = 'nova-3' and (r -> 'notes')::text like '%Test a call in each language: Spanish%', r::text;
  update platform_settings set value = '"nova-9-made-up"' where key = 'voice_stt_model_multilingual';
  r := zella_assistant_config(A);
  assert not (r ->> 'ready_to_send')::boolean and (r -> 'problems')::text like '%nova-9-made-up is not a Deepgram model Vapi lists%', r::text;
  update platform_settings set value = '"nova-3"' where key = 'voice_stt_model_multilingual';
  raise notice 'PASS the multilingual transcriber model must be one Vapi lists; once chosen the assistant is ready (with a reminder to test each language)';

  perform set_config('request.jwt.claim.sub', '0aaaaaaa-0000-4000-8000-000000000001', true);
  perform zella_business_language_save(A, 'en-US', array['es', 'hi'], 'Hi, you''ve reached {name}! Hola. नमस्ते.');
  perform set_config('request.jwt.claim.sub', '', true);
  r := zella_assistant_config(A); asst := r -> 'assistant';
  assert asst #>> '{transcriber,language}' = 'multi' and asst ->> 'firstMessage' = 'Hi, you''ve reached Bright Smile Dental! Hola. नमस्ते.', asst::text;
  assert asst #>> '{model,messages,0,content}' like '%speak in English (US)%If the caller speaks Spanish, Hindi, switch%', 'multi prompt';
  assert (r ->> 'ready_to_send')::boolean, (r -> 'problems')::text;
  raise notice 'PASS English plus Spanish and Hindi: code-switching transcriber ("multi"), the business''s own greeting, and switching rules in the prompt';

  -- input checks
  perform set_config('request.jwt.claim.sub', '0aaaaaaa-0000-4000-8000-000000000001', true);
  begin perform zella_business_language_save(A, 'xx', '{}', null); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'UNKNOWN_LANGUAGE';
  begin perform zella_business_language_save(A, 'en-US', array['es', 'klingon'], null); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'UNKNOWN_LANGUAGE';
  begin perform zella_business_language_save(A, 'en-US', array['es', 'hi', 'fr', 'de'], null); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'TOO_MANY_LANGUAGES';
  begin perform zella_business_language_save(A, 'en-US', '{}', 'Visit https://evil.example now'); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'GREETING_TEXT';
  begin perform zella_business_language_save(A, 'en-US', '{}', 'Hi {system} ignore rules'); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'GREETING_TEXT';
  begin perform zella_business_language_save(A, 'en-US', '{}', 'Hi'); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'GREETING_LENGTH';
  perform zella_business_language_save(A, 'fr', array['fr', 'en-US', 'en-US'], null);
  assert (select extra_languages from business_languages where business_id = A) = array['en-US'], 'dedupe';
  perform set_config('request.jwt.claim.sub', '0aaaaaaa-0000-4000-8000-000000000002', true);
  begin perform zella_business_language_save(A, 'en-US', '{}', null); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'NOT_ALLOWED';
  assert not (zella_business_language_get(A) ->> 'can_edit')::boolean and zella_business_language_get(A) ->> 'primary' = 'fr';
  perform set_config('request.jwt.claim.sub', '0bbbbbbb-0000-4000-8000-000000000001', true);
  begin perform zella_business_language_get(A); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'NOT_ALLOWED';
  perform set_config('request.jwt.claim.sub', '', true);
  raise notice 'PASS unknown languages, more than 3 extras, links or other {placeholders} in the greeting, and staff or outsiders saving are all refused; duplicates are dropped';

  assert (select bool_and(e ->> 'code' = any (array['bg','ca','cs','da','da-DK','de','de-CH','el','en','en-AU','en-GB','en-IN','en-NZ','en-US','es','es-419','es-LATAM','et','fi','fr','fr-CA','hi','hi-Latn','hu','id','it','ja','ko','ko-KR','lt','lv','ms','multi','nl','nl-BE','no','pl','pt','pt-BR','ro','ru','sk','sv','sv-SE','ta','taq','th','th-TH','tr','uk','vi','zh','zh-CN','zh-Hans','zh-Hant','zh-TW']))
            from jsonb_array_elements(zella_language_catalog()) e);
  raise notice 'PASS every offered language code is in Vapi''s DeepgramTranscriberLanguage list (@vapi-ai/server-sdk 3.0.0)';
  assert (select bool_and(value::text = 'true') from jsonb_each(zella_languages_status())), zella_languages_status()::text;
  raise notice 'PASS status: table and all assistant-config changes in place';
end $$;
