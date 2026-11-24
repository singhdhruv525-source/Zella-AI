-- Zella Voice: a silent caller gets one check, then a polite goodbye, and the call ends (owner, 25 Nov 2026:
-- REQ-VOX-13, AI-24). If the caller says nothing for one minute, the AI receptionist says goodbye and hangs up.
--
-- Vapi's format (@vapi-ai/server-sdk 3.0.0, dist/cjs/api/types): CreateAssistantDto has no silenceTimeoutSeconds
-- (only TransferAssistant does) and no messagePlan or idle messages. Silence is handled with assistant hooks:
-- CreateAssistantDto.hooks takes CallHookCustomerSpeechTimeout { on: "customer.speech.timeout", name, options, do },
-- where CustomerSpeechTimeoutOptions has timeoutSeconds (minimum 2, maximum 1000; the clock starts when the assistant
-- finishes speaking and runs until the caller speaks), triggerMaxCount and triggerResetMode ("onUserSpeech" | "never"),
-- and do is a list of SayHookAction { type: "say", exact } and ToolCallHookAction { type: "tool", tool }. The goodbye
-- is the request-start message of an endCall tool (ToolMessageStart: content, contents per language as TextContent,
-- and blocking: true, "the tool call will only trigger after the message is spoken"), so the goodbye is always
-- spoken before the call ends. endCallMessage is left unset: the types don't say whether it plays after a hook's
-- endCall, and setting it as well could make the goodbye play twice.
--
--   1. New setting voice_silence_timeout_seconds = 60 (recorded in zella_migration_settings, so the rollback removes it
--      only if this file added it). It changes without code. It is clamped to 60..1000: never below the owner's one
--      minute, never above Vapi's maximum; anything that is not a number counts as 60.
--   2. zella_silence_hooks(business) builds two hooks: after half the timeout (30 s) one "Are you still there?"
--      ("¿Sigue ahí?"; a business that speaks both languages gets it as a prompt, said in the call's language);
--      at the timeout (60 s) the goodbye with the business's name, then the call ends. Both reset when the caller
--      speaks, so each silence gets one check and one goodbye. Spanish speaking businesses (primary language es)
--      hear Spanish; a business that also speaks the other language gets both goodbye variants (Vapi picks the
--      call's active language). The name is the business's name as the greeting uses it, with dashes and control
--      characters turned into spaces; without a name: "Thanks for calling, goodbye."
--   3. zella_assistant_config adds "hooks" next to maxDurationSeconds. Nothing else in the config changes.
-- zella_assistant_config is changed in place (archived first) and must be production's version (e2ae7cfc..., 24 Nov 2026)
-- or that version with sql/zella_admin_languages.sql applied (89e090f3...), otherwise VERSION_MISMATCH and nothing
-- changes. The edit does not overlap zella_admin_languages' edit. Safe to run twice.
-- Needs sql/zella_cartesia_voices.sql. Rollback: sql/rollback/zella_silence_timeout_rollback.sql
begin;

do $$
begin
  if to_regclass('public.zella_function_archive') is null or to_regclass('public.zella_migration_settings') is null
     or to_regclass('public.business_languages') is null or to_regprocedure('public.zella_assistant_config(uuid)') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing (apply sql/zella_cartesia_voices.sql first)';
  end if;
end $$;

-- 1. the timeout, in seconds of caller silence
with i as (
  insert into public.platform_settings (key, value) values ('voice_silence_timeout_seconds', '60'::jsonb)
  on conflict (key) do nothing returning key
)
insert into public.zella_migration_settings (migration, key) select 'zella_silence_timeout', key from i on conflict do nothing;

-- the timeout in use: the setting as a whole number, clamped to 60..1000 (Vapi's maximum); 60 when it isn't a number
create or replace function public.zella_silence_timeout_seconds() returns integer
language sql stable security definer set search_path = '' as $$
  select case when v ~ '^\s*[0-9]+(\.[0-9]+)?\s*$' then least(1000, greatest(60, round(v::numeric)))::integer else 60 end
  from (select public.zella_setting('voice_silence_timeout_seconds', '60'::jsonb) #>> '{}' as v) s;
$$;
revoke all on function public.zella_silence_timeout_seconds() from public, anon, authenticated;
grant execute on function public.zella_silence_timeout_seconds() to service_role;

-- 2. Vapi's CallHookCustomerSpeechTimeout hooks for one business (@vapi-ai/server-sdk 3.0.0)
create or replace function public.zella_silence_hooks(p_business_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  with b as (
    -- the name the greeting says, made safe to speak: no dashes, no control characters, single spaces
    select nullif(btrim(regexp_replace(regexp_replace(coalesce((select x.name from public.businesses x where x.id = p_business_id), ''),
             '[[:cntrl:]‐‑‒–—―−-]+', ' ', 'g'), '\s+', ' ', 'g')), '') as name,
           coalesce((select split_part(lower(l.primary_language), '-', 1) from public.business_languages l where l.business_id = p_business_id), 'en') as lang,
           coalesce((select array(select split_part(lower(e), '-', 1) from unnest(l.extra_languages) e) from public.business_languages l where l.business_id = p_business_id), '{}') as extra,
           public.zella_silence_timeout_seconds() as t
  ), m as (
    select b.*, case when b.lang = 'es' then 'es' else 'en' end as main,
      case when b.name is null then 'It seems we''ve been disconnected. Thanks for calling, goodbye.'
           else 'It seems we''ve been disconnected. Thanks for calling ' || b.name || ', goodbye.' end as bye_en,
      case when b.name is null then 'Parece que se cortó la llamada. Gracias por llamar, adiós.'
           else 'Parece que se cortó la llamada. Gracias por llamar a ' || b.name || ', adiós.' end as bye_es
    from b
  ), v as (
    -- the goodbye in the main language first; the other one too when the business speaks it
    select m.*, case when m.main = 'es' then m.bye_es else m.bye_en end as bye,
      (select jsonb_agg(jsonb_build_object('type', 'text', 'text', x.text, 'language', x.language) order by x.n)
       from (select 1 as n, m.main as language, case when m.main = 'es' then m.bye_es else m.bye_en end as text
             union all
             select 2, o.language, o.text from (select case when m.main = 'es' then 'en' else 'es' end as language,
                                                       case when m.main = 'es' then m.bye_en else m.bye_es end as text) o
             where o.language = m.lang or o.language = any (m.extra)) x) as contents
    from m
  )
  select jsonb_build_array(
    jsonb_build_object('name', 'zella_silence_check', 'on', 'customer.speech.timeout',
      'options', jsonb_build_object('timeoutSeconds', v.t / 2, 'triggerMaxCount', 1, 'triggerResetMode', 'onUserSpeech'),
      -- SayHookAction has no per language variants (exact is one text, or a list Vapi picks from at random): a business
      -- that speaks one language gets the exact line; one that speaks English and Spanish gets a prompt, so the check
      -- is said in the language the call is in, with the main language first
      'do', jsonb_build_array(case when jsonb_array_length(v.contents) > 1 then
          jsonb_build_object('type', 'say', 'prompt', 'The caller has been silent for a while. Ask only whether they are still there, in the language the caller is using now'
            || case when v.main = 'es' then ' (Spanish unless the caller has been speaking English): "¿Sigue ahí?", or in English "Are you still there?".'
                    else ' (English unless the caller has been speaking Spanish): "Are you still there?", or in Spanish "¿Sigue ahí?".' end
            || ' Say nothing else.')
        else jsonb_build_object('type', 'say', 'exact', case when v.main = 'es' then '¿Sigue ahí?' else 'Are you still there?' end) end)),
    jsonb_build_object('name', 'zella_silence_goodbye', 'on', 'customer.speech.timeout',
      'options', jsonb_build_object('timeoutSeconds', v.t, 'triggerMaxCount', 1, 'triggerResetMode', 'onUserSpeech'),
      'do', jsonb_build_array(jsonb_build_object('type', 'tool', 'tool', jsonb_build_object('type', 'endCall',
        'messages', jsonb_build_array(jsonb_build_object('type', 'request-start', 'blocking', true, 'content', v.bye, 'contents', v.contents)))))))
  from v;
$$;
revoke all on function public.zella_silence_hooks(uuid) from public, anon, authenticated;
grant execute on function public.zella_silence_hooks(uuid) to service_role;

-- 3. the change in place: production's version, or production's with zella_admin_languages, archived first
do $$
declare
  d text; v_new text; n integer; v_mine text;
  sig constant text := 'public.zella_assistant_config(uuid)';
  -- base md5 -> this file's md5 on that base
  bases constant jsonb := jsonb_build_object(
    'e2ae7cfcd60ebf32a7d6bd2247e39ab3', '7cb1c1ad81a872b2118d66db2eeba959',    -- production (zella_cartesia_voices applied)
    '89e090f31515920ac198874946e15780', '36ba71051bc6382c08e782d0a9754e20');   -- production with zella_admin_languages applied
  anchor constant text := $a$      'voice', v_voice, 'transcriber', v_transcriber, 'maxDurationSeconds', v_max,
$a$;
  edit constant text := $w$      'voice', v_voice, 'transcriber', v_transcriber, 'maxDurationSeconds', v_max,
      'hooks', public.zella_silence_hooks(p_business_id),   /* zella_silence_timeout: one check, then goodbye and end */
$w$;
begin
  d := pg_get_functiondef(sig::regprocedure);
  if exists (select 1 from jsonb_each_text(bases) b where b.value = md5(d)) then return; end if;   -- already applied
  if not bases ? md5(d) then raise exception 'VERSION_MISMATCH: % is not a version this file was written for', sig; end if;
  v_mine := bases ->> md5(d);
  n := (length(d) - length(replace(d, anchor, ''))) / length(anchor);
  if n <> 1 then raise exception 'VERSION_MISMATCH: % anchor found % times', sig, n; end if;
  v_new := replace(d, anchor, edit);
  insert into public.zella_function_archive (migration, signature, definition, definition_md5)
  values ('zella_silence_timeout', sig, d, md5(d)) on conflict (migration, signature) do nothing;
  execute v_new;
  if v_mine not like '\_\_%' and md5(pg_get_functiondef(sig::regprocedure)) <> v_mine then
    raise exception 'VERSION_MISMATCH: % did not come out as this file''s version', sig;
  end if;
end $$;

commit;
