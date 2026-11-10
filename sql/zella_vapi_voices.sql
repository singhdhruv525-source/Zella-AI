-- Zella AI: the receptionist can use Vapi's own voices (provider "vapi", voice by name, Version 2) as well as
-- ElevenLabs. Needs sql/zella_voice_assistant.sql and sql/zella_languages.sql (patches their live body; safe to run again).
--
-- Vapi's VapiVoice (@vapi-ai/server-sdk 3.0.0): { provider: "vapi", voiceId: <built-in voice name>, version: "2" }.
-- The ElevenLabs-only "eleven_multilingual_v2" model is now added only when the provider is 11labs.

do $$
declare sig text := 'public.zella_assistant_config(uuid)';
begin
  perform public.zella_patch_function(sig, 'not in (''11labs'', ''vapi'')',
    'if v_tts_provider <> ''11labs'' then',
    'if v_tts_provider not in (''11labs'', ''vapi'') then');
  perform public.zella_patch_function(sig, '''version'', ''2''',
    'v_voice := case when v_tts_voice is not null then jsonb_build_object(''provider'', v_tts_provider, ''voiceId'', v_tts_voice) end;',
    'v_voice := case when v_tts_voice is not null then jsonb_build_object(''provider'', v_tts_provider, ''voiceId'', v_tts_voice)'
      || ' || case when v_tts_provider = ''vapi'' then jsonb_build_object(''version'', ''2'') else ''{}''::jsonb end end;');
  perform public.zella_patch_function(sig, 'v_tts_provider = ''11labs'' then v_voice := v_voice ||',
    'if v_voice is not null then v_voice := v_voice || jsonb_build_object(''model'', ''eleven_multilingual_v2''); end if;',
    'if v_voice is not null and v_tts_provider = ''11labs'' then v_voice := v_voice || jsonb_build_object(''model'', ''eleven_multilingual_v2''); end if;');
end $$;

-- Optional ElevenLabs voice model (platform setting voice_tts_model, one of Vapi's ElevenLabsVoiceModel values);
-- unset = Vapi's default. Applied as migration zella_voice_tts_model with voice "burt" and model "eleven_v4_turbo".
do $$
declare sig text := 'public.zella_assistant_config(uuid)';
begin
  perform public.zella_patch_function(sig, 'voice_tts_model',
    ' || case when v_tts_provider = ''vapi'' then jsonb_build_object(''version'', ''2'') else ''{}''::jsonb end end;',
    ' || case when v_tts_provider = ''vapi'' then jsonb_build_object(''version'', ''2'') else ''{}''::jsonb end end;'
    || E'\n  -- ElevenLabs voice model chosen in Vapi (VapiVoice ElevenLabsVoiceModel list, @vapi-ai/server-sdk 3.0.0); none = Vapi''s default'
    || E'\n  if v_voice is not null and v_tts_provider = ''11labs'' and coalesce(public.zella_setting(''voice_tts_model'', ''null''::jsonb) #>> ''{}'', '''') = any (array[''eleven_multilingual_v2'', ''eleven_turbo_v2'', ''eleven_turbo_v2_5'', ''eleven_flash_v2'', ''eleven_flash_v2_5'', ''eleven_monolingual_v1'', ''eleven_v3'', ''eleven_v4_turbo'']) then'
    || E'\n    v_voice := v_voice || jsonb_build_object(''model'', public.zella_setting(''voice_tts_model'', ''null''::jsonb) #>> ''{}'');'
    || E'\n  end if;');
end $$;
insert into public.platform_settings (key, value) values ('voice_tts_model', 'null'::jsonb) on conflict (key) do nothing;
