-- Zella AI: each business can have its own receptionist voice, chosen from a list the platform approves.
-- Needs sql/zella_vapi_voices.sql (voice_tts_model). Safe to run again.
--
-- - platform setting voice_tts_choices: the approved ElevenLabs voices (Vapi's built-in ElevenLabs voice names,
--   ElevenLabsVoiceIdEnum in @vapi-ai/server-sdk 3.0.0); voice_tts_voice_id stays the platform default.
-- - business_voice: one row per business that picked something other than the default.
-- - zella_business_voice_get / _save: owners, admins and managers of the business, or a Zella admin with
--   ai.configure, can change it; every member can see it. Saved changes are audited.
-- - zella_assistant_config uses the business's voice when it is on the approved list (ElevenLabs only), otherwise
--   the platform default.

insert into public.platform_settings (key, value) values ('voice_tts_choices',
  '[{"id":"burt","name":"Burt"},{"id":"marissa","name":"Marissa"},{"id":"andrea","name":"Andrea"},{"id":"sarah","name":"Sarah"},
    {"id":"phillip","name":"Phillip"},{"id":"steve","name":"Steve"},{"id":"joseph","name":"Joseph"},{"id":"myra","name":"Myra"},
    {"id":"paula","name":"Paula"},{"id":"ryan","name":"Ryan"},{"id":"drew","name":"Drew"},{"id":"paul","name":"Paul"},
    {"id":"mrb","name":"Mr B"},{"id":"matilda","name":"Matilda"},{"id":"mark","name":"Mark"}]'::jsonb)
on conflict (key) do nothing;

create table if not exists public.business_voice (
  business_id uuid primary key references public.businesses (id) on delete cascade,
  voice_id text not null check (voice_id ~ '^[A-Za-z0-9_-]{2,64}$'),
  updated_by uuid,
  updated_at timestamptz not null default now()
);
alter table public.business_voice enable row level security;
revoke all on public.business_voice from anon, authenticated;

create or replace function public.zella_voice_choices() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(public.zella_setting('voice_tts_choices', '[]'::jsonb), '[]'::jsonb);
$$;
revoke all on function public.zella_voice_choices() from public, anon, authenticated;

create or replace function public.zella_business_voice_get(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_admin boolean := public.zella_admin_can('businesses.view'); v_default text;
begin
  if auth.uid() is null or not (public.zella_is_member(p_business_id) or v_admin) then raise exception 'NOT_ALLOWED'; end if;
  v_default := nullif(nullif(public.zella_setting('voice_tts_voice_id', 'null'::jsonb) #>> '{}', ''), 'null');
  return jsonb_build_object(
    'voice_id', (select voice_id from public.business_voice where business_id = p_business_id),
    'default_voice_id', v_default,
    'provider', coalesce(public.zella_setting('voice_tts_provider', '"11labs"'::jsonb) #>> '{}', '11labs'),
    'choices', public.zella_voice_choices(),
    'updated_at', (select updated_at from public.business_voice where business_id = p_business_id),
    'can_edit', public.zella_can_manage(p_business_id) or public.zella_admin_can('ai.configure'));
end $$;
revoke all on function public.zella_business_voice_get(uuid) from public, anon;
grant execute on function public.zella_business_voice_get(uuid) to authenticated;

-- p_voice_id null = use the platform default again.
create or replace function public.zella_business_voice_save(p_business_id uuid, p_voice_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_old text; v_new text := nullif(trim(coalesce(p_voice_id, '')), '');
begin
  if auth.uid() is null or not (public.zella_can_manage(p_business_id) or public.zella_admin_can('ai.configure')) then raise exception 'NOT_ALLOWED'; end if;
  if not exists (select 1 from public.businesses where id = p_business_id) then raise exception 'NOT_FOUND'; end if;
  if v_new is not null and not exists (select 1 from jsonb_array_elements(public.zella_voice_choices()) c where c ->> 'id' = v_new) then
    raise exception 'UNKNOWN_VOICE';
  end if;
  select voice_id into v_old from public.business_voice where business_id = p_business_id;
  if v_old is not distinct from v_new then return public.zella_business_voice_get(p_business_id); end if;
  if v_new is null then
    delete from public.business_voice where business_id = p_business_id;
  else
    insert into public.business_voice (business_id, voice_id, updated_by, updated_at) values (p_business_id, v_new, auth.uid(), now())
    on conflict (business_id) do update set voice_id = excluded.voice_id, updated_by = excluded.updated_by, updated_at = now();
  end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, auth.uid(), 'receptionist.voice_changed', 'business', p_business_id,
          jsonb_build_object('voice_id', v_old), jsonb_build_object('voice_id', v_new, 'by_platform_admin', not public.zella_can_manage(p_business_id)));
  return public.zella_business_voice_get(p_business_id);
end $$;
revoke all on function public.zella_business_voice_save(uuid, text) from public, anon;
grant execute on function public.zella_business_voice_save(uuid, text) to authenticated;

-- zella_assistant_config: the business's own voice (after the platform voice and model are set).
do $$
declare sig text := 'public.zella_assistant_config(uuid)';
begin
  perform public.zella_patch_function(sig, 'business_voice',
    E'    v_voice := v_voice || jsonb_build_object(''model'', public.zella_setting(''voice_tts_model'', ''null''::jsonb) #>> ''{}'');\n  end if;',
    E'    v_voice := v_voice || jsonb_build_object(''model'', public.zella_setting(''voice_tts_model'', ''null''::jsonb) #>> ''{}'');\n  end if;'
    || E'\n  -- the business''s own voice (sql/zella_business_voice.sql), only if it is on the approved list'
    || E'\n  if v_voice is not null and v_tts_provider = ''11labs'' and exists (select 1 from public.business_voice bv'
    || E'\n       join jsonb_array_elements(public.zella_voice_choices()) ch on ch ->> ''id'' = bv.voice_id where bv.business_id = p_business_id) then'
    || E'\n    v_voice := v_voice || jsonb_build_object(''voiceId'', (select bv.voice_id from public.business_voice bv where bv.business_id = p_business_id));'
    || E'\n  end if;');
end $$;
