-- Zella Voice: Cartesia voices for the AI receptionist, through Vapi, beside Vapi's own voices and ElevenLabs.
-- Vapi calls Cartesia with the Cartesia key the owner saves in the Vapi dashboard (provider keys); no key is stored here.
--
-- Vapi's format (@vapi-ai/server-sdk 3.0.0, dist/cjs/api/types): AssistantVoice.Cartesia is CartesiaVoice with
-- provider "cartesia"; CartesiaVoice has voiceId (required), model (CartesiaVoiceModel, optional) and language
-- (CartesiaVoiceLanguage, optional; both default to the voice's own). The lists below are copied from those two files.
--
--   1. business_voice gets provider ('11labs', 'vapi' or 'cartesia'; existing rows are ElevenLabs, the only voices the
--      approved list held). zella_voice_choices fills in provider '11labs' for list entries that don't name one.
--   2. Six Cartesia voices join the approved list voice_tts_choices (ids from Cartesia's public voice list, see the PR):
--      English Katie, Kiefer, Jacqueline and Blake; Spanish (Mexican) Daniela and Pedro. The earlier entries stay as
--      they are. New setting voice_cartesia_model = "sonic-3" (one of Vapi's CartesiaVoiceModel values).
--   3. zella_assistant_config sends {provider: "cartesia", voiceId, model, language} for a business's approved
--      Cartesia choice (whatever the platform voice provider is), and for a platform default voice when
--      voice_tts_provider is 'cartesia'. language is the business's primary language when Vapi lists it for Cartesia,
--      otherwise the voice's own. ElevenLabs and Vapi voices are sent exactly as before.
--   4. zella_setup_voice_apply (server only): the admin create business wizard's voice choice becomes the business's
--      business_voice row, for an active platform admin with businesses.manage, audited like a saved voice.
-- zella_voice_choices, zella_business_voice_save and zella_assistant_config are changed in place (archived first) and
-- must be production's version (24 Nov 2026), otherwise VERSION_MISMATCH and nothing changes. Safe to run twice.
-- Needs sql/zella_business_voice.sql and sql/zella_call_disclosure.sql. Rollback: sql/rollback/zella_cartesia_voices_rollback.sql
begin;

do $$
begin
  if to_regclass('public.zella_function_archive') is null or to_regclass('public.zella_migration_values') is null
     or to_regclass('public.zella_migration_settings') is null or to_regclass('public.business_voice') is null
     or to_regprocedure('public.zella_call_greeting(uuid,text)') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing (apply sql/zella_business_voice.sql and sql/zella_call_disclosure.sql first)';
  end if;
end $$;

-- 1. which provider a business's chosen voice is from (copied from the approved list when it is saved)
alter table public.business_voice add column if not exists provider text not null default '11labs';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'business_voice_provider_check' and conrelid = 'public.business_voice'::regclass) then
    alter table public.business_voice add constraint business_voice_provider_check check (provider in ('11labs', 'vapi', 'cartesia'));
  end if;
end $$;

-- 2. the approved Cartesia voices, added once; the list as it was is kept for the rollback
do $$
declare
  v_old jsonb := coalesce((select value from public.platform_settings where key = 'voice_tts_choices'), '[]'::jsonb);
  v_add constant jsonb := '[
    {"id": "f786b574-daa5-4673-aa0c-cbe3e8534c02", "name": "Katie", "provider": "cartesia", "language": "en", "gender": "female"},
    {"id": "228fca29-3a0a-435c-8728-5cb483251068", "name": "Kiefer", "provider": "cartesia", "language": "en", "gender": "male"},
    {"id": "9626c31c-bec5-4cca-baa8-f8ba9e84c8bc", "name": "Jacqueline", "provider": "cartesia", "language": "en", "gender": "female"},
    {"id": "a167e0f3-df7e-4d52-a9c3-f949145efdab", "name": "Blake", "provider": "cartesia", "language": "en", "gender": "male"},
    {"id": "5c5ad5e7-1020-476b-8b91-fdcbe9cc313c", "name": "Daniela", "provider": "cartesia", "language": "es", "gender": "female"},
    {"id": "15d0c2e2-8d29-44c3-be23-d585d5f154a1", "name": "Pedro", "provider": "cartesia", "language": "es", "gender": "male"}]'::jsonb;
  v_new jsonb;
begin
  if exists (select 1 from public.zella_migration_values where migration = 'zella_cartesia_voices' and key = 'voice_tts_choices') then
    return;   -- already applied
  end if;
  if jsonb_typeof(v_old) <> 'array' then raise exception 'VERSION_MISMATCH: voice_tts_choices is not a list'; end if;
  select v_old || coalesce(jsonb_agg(a order by n), '[]'::jsonb) into v_new
  from jsonb_array_elements(v_add) with ordinality x(a, n)
  where not exists (select 1 from jsonb_array_elements(v_old) o where o ->> 'id' = a ->> 'id');
  insert into public.zella_migration_values (migration, key, value) values
    -- null: there was no list (the rollback removes the row again)
    ('zella_cartesia_voices', 'voice_tts_choices', (select value from public.platform_settings where key = 'voice_tts_choices')),
    ('zella_cartesia_voices', 'voice_tts_choices_after', v_new);
  insert into public.platform_settings (key, value) values ('voice_tts_choices', v_new)
  on conflict (key) do update set value = excluded.value, updated_at = now();
end $$;

with i as (
  insert into public.platform_settings (key, value) values ('voice_cartesia_model', '"sonic-3"'::jsonb)
  on conflict (key) do nothing returning key
)
insert into public.zella_migration_settings (migration, key) select 'zella_cartesia_voices', key from i on conflict do nothing;

-- the approved choice a business picked (provider filled in), or null when it has none or it left the list
create or replace function public.zella_business_voice_choice(p_business_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select ch from public.business_voice bv
  join jsonb_array_elements(public.zella_voice_choices()) ch on ch ->> 'id' = bv.voice_id
  where bv.business_id = p_business_id limit 1;
$$;
revoke all on function public.zella_business_voice_choice(uuid) from public, anon, authenticated;
grant execute on function public.zella_business_voice_choice(uuid) to service_role;

-- Vapi's CartesiaVoice for one business: model from voice_cartesia_model when Vapi lists it (left out otherwise, and
-- zella_assistant_config reports it), language the business's primary language when Vapi lists it, else the voice's
create or replace function public.zella_cartesia_voice(p_business_id uuid, p_voice_id text, p_voice_language text) returns jsonb
language sql stable security definer set search_path = '' as $$
  with lists as (
    -- CartesiaVoiceModel and CartesiaVoiceLanguage, @vapi-ai/server-sdk 3.0.0
    select array['sonic-3.5', 'sonic-3.5-2026-05-04', 'sonic-3', 'sonic-3-2026-01-12', 'sonic-3-2025-10-27', 'sonic-2',
                 'sonic-2-2025-06-11', 'sonic-english', 'sonic-multilingual', 'sonic-preview', 'sonic'] as models,
           array['ar', 'bg', 'bn', 'cs', 'da', 'de', 'el', 'en', 'es', 'fi', 'fr', 'gu', 'he', 'hi', 'hr', 'hu', 'id', 'it',
                 'ja', 'ka', 'kn', 'ko', 'ml', 'mr', 'ms', 'nl', 'no', 'pa', 'pl', 'pt', 'ro', 'ru', 'sk', 'sv', 'ta', 'te',
                 'th', 'tl', 'tr', 'uk', 'vi', 'zh'] as langs
  ), v as (
    select public.zella_setting('voice_cartesia_model', 'null'::jsonb) #>> '{}' as model,
           (select split_part(lower(l.primary_language), '-', 1) from public.business_languages l where l.business_id = p_business_id) as business_lang
  )
  select jsonb_strip_nulls(jsonb_build_object('provider', 'cartesia', 'voiceId', p_voice_id,
    'model', case when v.model = any (lists.models) then v.model end,
    'language', case when v.business_lang = any (lists.langs) then v.business_lang
                     when lower(p_voice_language) = any (lists.langs) then lower(p_voice_language) end))
  from lists, v;
$$;
revoke all on function public.zella_cartesia_voice(uuid, text, text) from public, anon, authenticated;
grant execute on function public.zella_cartesia_voice(uuid, text, text) to service_role;

-- the admin create business wizard's voice: an active platform admin with businesses.manage (the edge function checks
-- it too) sets or clears the business's voice; same list and audit as zella_business_voice_save. Owners change it later
-- in Settings with zella_business_voice_save.
create or replace function public.zella_setup_voice_apply(p_business_id uuid, p_voice_id text, p_actor uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_new text := nullif(trim(coalesce(p_voice_id, '')), ''); v_old text; v_role text; v_choice jsonb;
begin
  select pa.role into v_role from public.platform_admins pa where pa.user_id = p_actor and pa.is_active;
  if v_role is null or not (v_role in ('zella_owner', 'super_admin')
     or exists (select 1 from public.platform_role_permissions p where p.role = v_role and p.permission = 'businesses.manage')) then
    return jsonb_build_object('ok', false, 'reason', 'NOT_ALLOWED');
  end if;
  if not exists (select 1 from public.businesses where id = p_business_id) then return jsonb_build_object('ok', false, 'reason', 'NOT_FOUND'); end if;
  if v_new is not null then
    select c into v_choice from jsonb_array_elements(public.zella_voice_choices()) c where c ->> 'id' = v_new limit 1;
    if v_choice is null then return jsonb_build_object('ok', false, 'reason', 'UNKNOWN_VOICE'); end if;
  end if;
  select voice_id into v_old from public.business_voice where business_id = p_business_id for update;
  if v_old is not distinct from v_new then return jsonb_build_object('ok', true, 'voice_id', v_new, 'changed', false); end if;
  if v_new is null then
    delete from public.business_voice where business_id = p_business_id;
  else
    insert into public.business_voice (business_id, voice_id, provider, updated_by, updated_at) values (p_business_id, v_new, v_choice ->> 'provider', p_actor, now())
    on conflict (business_id) do update set voice_id = excluded.voice_id, provider = excluded.provider, updated_by = excluded.updated_by, updated_at = now();
  end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, p_actor, 'receptionist.voice_changed', 'business', p_business_id, jsonb_build_object('voice_id', v_old),
          jsonb_build_object('voice_id', v_new, 'provider', v_choice ->> 'provider', 'by_platform_admin', true, 'source', 'setup_wizard'));
  return jsonb_build_object('ok', true, 'voice_id', v_new, 'changed', true);
end $$;
revoke all on function public.zella_setup_voice_apply(uuid, text, uuid) from public, anon, authenticated;
grant execute on function public.zella_setup_voice_apply(uuid, text, uuid) to service_role;

-- 3. the changes in place: each function must be production's version (archived first) or exactly this file's
do $$
declare
  f record; e record; d text; v_new text; n integer;
  plan constant jsonb := jsonb_build_array(
    jsonb_build_object('sig', 'public.zella_voice_choices()', 'prod', '895f10570bad779f98f8e282ea0bf57e', 'mine', '30751307dabbaf6d28214d76d67f57ff',
      'edits', jsonb_build_array(jsonb_build_object('count', 1,
        'anchor', $a$  select coalesce(public.zella_setting('voice_tts_choices', '[]'::jsonb), '[]'::jsonb);
$a$,
        'with', $w$  -- zella_cartesia_voices: every entry names its provider; entries from before Cartesia are ElevenLabs
  select coalesce(jsonb_agg(case when jsonb_typeof(c) = 'object' and not (c ? 'provider') then c || '{"provider": "11labs"}'::jsonb else c end order by n), '[]'::jsonb)
  from jsonb_array_elements(case when jsonb_typeof(public.zella_setting('voice_tts_choices', '[]'::jsonb)) = 'array'
                                 then public.zella_setting('voice_tts_choices', '[]'::jsonb) else '[]'::jsonb end) with ordinality x(c, n);
$w$))),
    jsonb_build_object('sig', 'public.zella_business_voice_save(uuid,text)', 'prod', '9f11f2c62a38724d47e9a54a96c02f53', 'mine', '59eb19efa4867a2b37abb13cc312cbb5',
      'edits', jsonb_build_array(jsonb_build_object('count', 1,
        'anchor', $a$    insert into public.business_voice (business_id, voice_id, updated_by, updated_at) values (p_business_id, v_new, auth.uid(), now())
    on conflict (business_id) do update set voice_id = excluded.voice_id, updated_by = excluded.updated_by, updated_at = now();
$a$,
        'with', $w$    insert into public.business_voice (business_id, voice_id, provider, updated_by, updated_at)   /* zella_cartesia_voices */
    values (p_business_id, v_new, (select c ->> 'provider' from jsonb_array_elements(public.zella_voice_choices()) c where c ->> 'id' = v_new limit 1), auth.uid(), now())
    on conflict (business_id) do update set voice_id = excluded.voice_id, provider = excluded.provider, updated_by = excluded.updated_by, updated_at = now();
$w$))),
    jsonb_build_object('sig', 'public.zella_assistant_config(uuid)', 'prod', '99666d94ffea6b2aeff3f680405b30c9', 'mine', 'e2ae7cfcd60ebf32a7d6bd2247e39ab3',
      'edits', jsonb_build_array(
        jsonb_build_object('count', 1,
          'anchor', $a$  if v_tts_provider not in ('11labs', 'vapi') then $a$,
          'with', $w$  if v_tts_provider not in ('11labs', 'vapi', 'cartesia') then $w$),
        jsonb_build_object('count', 1,
          'anchor', $a$  if v_voice is not null and v_tts_provider = '11labs' and exists (select 1 from public.business_voice bv
       join jsonb_array_elements(public.zella_voice_choices()) ch on ch ->> 'id' = bv.voice_id where bv.business_id = p_business_id) then
    v_voice := v_voice || jsonb_build_object('voiceId', (select bv.voice_id from public.business_voice bv where bv.business_id = p_business_id));
  end if;
$a$,
          'with', $w$  -- zella_cartesia_voices: Cartesia, as the platform voice or as the business's approved choice (whatever the platform
  -- provider), goes as Vapi's CartesiaVoice (@vapi-ai/server-sdk 3.0.0): provider, voiceId, model, language
  if v_voice is not null and v_tts_provider = 'cartesia' then
    v_voice := public.zella_cartesia_voice(p_business_id, v_tts_voice, null);
  end if;
  if v_voice is not null and public.zella_business_voice_choice(p_business_id) ->> 'provider' = 'cartesia' then
    v_voice := public.zella_cartesia_voice(p_business_id, public.zella_business_voice_choice(p_business_id) ->> 'id', public.zella_business_voice_choice(p_business_id) ->> 'language');
  elsif v_voice is not null and v_tts_provider = '11labs' and public.zella_business_voice_choice(p_business_id) ->> 'provider' = '11labs' then
    v_voice := v_voice || jsonb_build_object('voiceId', public.zella_business_voice_choice(p_business_id) ->> 'id');
  end if;
  if v_voice ->> 'provider' = 'cartesia' and not (v_voice ? 'model') then
    v_problems := v_problems || ('voice_cartesia_model ' || coalesce(public.zella_setting('voice_cartesia_model', 'null'::jsonb) #>> '{}', 'null') || ' is not a Cartesia model Vapi lists')::text;
  end if;
$w$),
        jsonb_build_object('count', 1,
          'anchor', $a$    if v_voice is not null and v_tts_provider = '11labs' then v_voice := v_voice || jsonb_build_object('model', 'eleven_multilingual_v2'); end if;$a$,
          'with', $w$    if v_voice is not null and v_voice ->> 'provider' = '11labs' then v_voice := v_voice || jsonb_build_object('model', 'eleven_multilingual_v2'); end if;$w$))));
begin
  for f in select x from jsonb_array_elements(plan) x loop
    if to_regprocedure(f.x ->> 'sig') is null then raise exception 'VERSION_MISMATCH: % is missing', f.x ->> 'sig'; end if;
    d := pg_get_functiondef((f.x ->> 'sig')::regprocedure);
    continue when md5(d) = f.x ->> 'mine';   -- already applied
    if md5(d) <> f.x ->> 'prod' then raise exception 'VERSION_MISMATCH: % is not a version this file was written for', f.x ->> 'sig'; end if;
    v_new := d;
    for e in select y from jsonb_array_elements(f.x -> 'edits') y loop
      n := (length(v_new) - length(replace(v_new, e.y ->> 'anchor', ''))) / length(e.y ->> 'anchor');
      if n <> (e.y ->> 'count')::integer then raise exception 'VERSION_MISMATCH: % anchor found % times', f.x ->> 'sig', n; end if;
      v_new := replace(v_new, e.y ->> 'anchor', e.y ->> 'with');
    end loop;
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_cartesia_voices', f.x ->> 'sig', d, md5(d)) on conflict (migration, signature) do nothing;
    execute v_new;
    if f.x ->> 'mine' not like '\_\_%' and md5(pg_get_functiondef((f.x ->> 'sig')::regprocedure)) <> f.x ->> 'mine' then
      raise exception 'VERSION_MISMATCH: % did not come out as this file''s version', f.x ->> 'sig';
    end if;
  end loop;
end $$;

-- rows saved before this file (or kept by a rollback and applied again) take their provider from the list
update public.business_voice bv set provider = ch ->> 'provider'
from jsonb_array_elements(public.zella_voice_choices()) ch
where ch ->> 'id' = bv.voice_id and ch ->> 'provider' in ('11labs', 'vapi', 'cartesia') and bv.provider is distinct from ch ->> 'provider';

commit;
