-- Undoes sql/zella_admin_languages.sql exactly. Seven changed functions come back from zella_function_archive.
-- zella_assistant_config has its one edit taken out again, so a later sql/zella_silence_timeout.sql is kept: from this
-- file's version of production's (89e090f3...) it goes back to production's (e2ae7cfc...), and from the version with
-- zella_silence_timeout too (36ba7105..., whichever was applied first) to production's with zella_silence_timeout
-- (7cb1c1ad...). Each function must be exactly a version this file made, otherwise ROLLBACK_DRIFT and nothing changes.
-- The six new functions go. Saved languages, voices and audit rows are kept. Owners can then change languages again in
-- Settings (the rule before this file), and voices are no longer filtered by language. Grants are kept (same
-- signatures). Safe to run twice.
begin;
do $$
declare a record; d text; v_new text; n integer;
  mine constant jsonb := jsonb_build_object(
    'public.zella_business_language_save(uuid,text,text[],text)', '14a58fa33813daa316c70688a36c88a2',
    'public.zella_business_language_get(uuid)', 'd48d06c07deb0a2c9b2c67e454a63c9f',
    'public.zella_setup_language_apply(uuid,text,text)', '3ff63339ea34147dcbe4eb1ba775f8ac',
    'public.zella_business_voice_get(uuid)', '63955f816a465e4042f6a3849044bc56',
    'public.zella_business_voice_save(uuid,text)', 'cd7cd28898995846a156fa1c5c31dab9',
    'public.zella_setup_voice_apply(uuid,text,uuid)', 'b2b29c7f4aa337003b0854235e73ce6b',
    'public.zella_business_voice_choice(uuid)', '580de72ac835968c0ed83b2ef2c3aca5');
  -- zella_assistant_config: this file's versions, and what each goes back to
  config_back constant jsonb := jsonb_build_object(
    '89e090f31515920ac198874946e15780', 'e2ae7cfcd60ebf32a7d6bd2247e39ab3',
    '36ba71051bc6382c08e782d0a9754e20', '7cb1c1ad81a872b2118d66db2eeba959');
  config_sig constant text := 'public.zella_assistant_config(uuid)';
  edit_in constant text := $w$  -- zella_admin_languages: a saved voice that no longer speaks the business's languages (for example after Spanish
  -- was removed) is not used (zella_business_voice_choice): the platform default voice speaks, and the notes say so
  if public.zella_business_voice_unfit(p_business_id) is not null then
    v_lang_notes := v_lang_notes || ('The saved voice ' || coalesce(public.zella_business_voice_unfit(p_business_id) ->> 'name', public.zella_business_voice_unfit(p_business_id) ->> 'id')
      || ' does not speak this business''s languages, so calls use the Zella Voice default voice. Choose another voice.')::text;
  end if;
  if v_voice ->> 'provider' = 'cartesia' and not (v_voice ? 'model') then
$w$;
  edit_out constant text := $a$  if v_voice ->> 'provider' = 'cartesia' and not (v_voice ? 'model') then
$a$;
begin
  if to_regclass('public.zella_function_archive') is null
     or not exists (select 1 from public.zella_function_archive where migration = 'zella_admin_languages') then
    return;   -- not applied, or already rolled back
  end if;
  for a in select signature from public.zella_function_archive where migration = 'zella_admin_languages' loop
    if to_regprocedure(a.signature) is null then raise exception 'ROLLBACK_DRIFT: % is missing', a.signature; end if;
    d := md5(pg_get_functiondef(a.signature::regprocedure));
    if (a.signature = config_sig and not (config_back ? d)) or (a.signature <> config_sig and d is distinct from mine ->> a.signature) then
      raise exception 'ROLLBACK_DRIFT: % has changed since this migration', a.signature;
    end if;
  end loop;
  for a in select signature, definition from public.zella_function_archive where migration = 'zella_admin_languages' loop
    if a.signature = config_sig then
      d := pg_get_functiondef(config_sig::regprocedure);
      n := (length(d) - length(replace(d, edit_in, ''))) / length(edit_in);
      if n <> 1 then raise exception 'ROLLBACK_DRIFT: % edit found % times', config_sig, n; end if;
      v_new := replace(d, edit_in, edit_out);
      execute v_new;
      if md5(pg_get_functiondef(config_sig::regprocedure)) <> config_back ->> md5(d) then
        raise exception 'ROLLBACK_DRIFT: % did not come back as the version before this migration', config_sig;
      end if;
    else
      execute a.definition;
    end if;
  end loop;
  delete from public.zella_function_archive where migration = 'zella_admin_languages';
end $$;
drop function if exists public.zella_business_voice_unfit(uuid);
drop function if exists public.zella_voice_fits(uuid, jsonb);
drop function if exists public.zella_business_voice_languages(uuid);
drop function if exists public.zella_language_plan_refusal(uuid, text, text[]);
drop function if exists public.zella_language_plan_info(uuid);
drop function if exists public.zella_language_family(text);
commit;
