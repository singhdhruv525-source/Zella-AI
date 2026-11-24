-- Zella Voice production deploy: paste this whole file into Supabase SQL Editor and click Run. Files in the tested order; each records itself as applied.

-- ===== zella_call_disclosure =====
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
    when 'es' then '{"sentence": "Soy la recepcionista virtual con inteligencia artificial.", "marker": "(recepcionista|asistente) (virtual|de inteligencia artificial)|con inteligencia artificial", "recording": "grabad[ao]s?|grabación", "call": "llamada|conversación"}'
    when 'fr' then '{"sentence": "Je suis la réceptionniste virtuelle, une intelligence artificielle.", "marker": "(réceptionniste|assistante?) virtuelle?|une intelligence artificielle", "recording": "enregistr", "call": "appel|conversation"}'
    when 'de' then '{"sentence": "Ich bin eine virtuelle Rezeptionistin mit künstlicher Intelligenz.", "marker": "mit künstlicher Intelligenz|virtuelle (Rezeptionistin|Assistentin)", "recording": "aufgezeichnet|Aufzeichnung", "call": "Anruf|Gespräch|Telefonat"}'
    when 'pt' then '{"sentence": "Sou a recepcionista virtual com inteligência artificial.", "marker": "(recepcionista|assistente) virtual|com inteligência artificial", "recording": "gravad[ao]s?|gravação", "call": "chamada|ligação|conversa"}'
    when 'it' then '{"sentence": "Sono la receptionist virtuale con intelligenza artificiale.", "marker": "(receptionist|assistente) virtuale|con intelligenza artificiale", "recording": "registrat[ao]|registrazione", "call": "chiamata|telefonata|conversazione"}'
    when 'nl' then '{"sentence": "Ik ben de virtuele receptioniste met kunstmatige intelligentie.", "marker": "virtuele (receptioniste|assistent)|met kunstmatige intelligentie", "recording": "opgenomen|opname", "call": "gesprek|oproep"}'
    when 'pl' then '{"sentence": "Jestem wirtualną recepcjonistką opartą na sztucznej inteligencji.", "marker": "wirtualn\\S* (recepcjonistk|asystent)|na sztucznej inteligencji", "recording": "nagrywan|nagran", "call": "rozmow|połączeni"}'
    when 'ru' then '{"sentence": "Я виртуальный администратор на основе искусственного интеллекта.", "marker": "виртуальн\\S* (администратор|ассистент)|на основе искусственного интеллекта", "recording": "записывае|записан", "call": "звон|разговор"}'
    when 'tr' then '{"sentence": "Ben yapay zekâ destekli sanal resepsiyonistim.", "marker": "sanal (resepsiyonist|asistan)|yapay zek[aâ] destekli", "recording": "kaydedil|kayıt altına", "call": "görüşme|arama"}'
    when 'ta' then '{"sentence": "நான் செயற்கை நுண்ணறிவு வரவேற்பாளர்.", "marker": "செயற்கை நுண்ணறிவு வரவேற்பாளர்", "recording": "பதிவு செய்யப்", "call": "அழைப்பு"}'
    when 'vi' then '{"sentence": "Tôi là lễ tân ảo sử dụng trí tuệ nhân tạo.", "marker": "lễ tân ảo|trợ lý ảo|sử dụng trí tuệ nhân tạo", "recording": "ghi âm", "call": "cuộc gọi"}'
    when 'id' then '{"sentence": "Saya resepsionis virtual berbasis kecerdasan buatan.", "marker": "(resepsionis|asisten) virtual|berbasis kecerdasan buatan", "recording": "direkam|rekaman", "call": "panggilan|percakapan"}'
    when 'hi' then '{"sentence": "मैं एआई रिसेप्शनिस्ट हूँ।", "marker": "एआई (रिसेप्शनिस्ट|सहायक)", "recording": "रिकॉर्ड", "call": "कॉल"}'
    when 'ja' then '{"sentence": "私はAI受付です。", "marker": "AI(受付|アシスタント)", "recording": "録音", "call": "通話"}'
    when 'ko' then '{"sentence": "저는 AI 상담원입니다.", "marker": "AI ?(상담원|비서|안내원)", "recording": "녹음", "call": "통화"}'
    when 'zh' then '{"sentence": "我是AI接待员。", "marker": "AI(接待员|助手|客服)", "recording": "录音", "call": "通话|电话"}'
    else '{"sentence": "I''m the AI receptionist.", "marker": "\\m(an?|the|your) (AI|artificial intelligence|virtual) (receptionist|assistant|agent)\\M|\\mI''m an? AI\\M", "recording": "\\mrecord(ed|ing)\\M", "call": "\\m(call|conversation)\\M"}' end::jsonb
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
  -- the same in the business's own language: a clause or sentence that says the call is recorded (a word for the
  -- call and a word for recording together, so "I can book your appointment" style sentences stay) goes
  if v_d ? 'recording' then
    v_rec := '((' || (v_d ->> 'call') || ')[^.!?。！？,，、]*(' || (v_d ->> 'recording') || ')|(' || (v_d ->> 'recording') || ')[^.!?。！？,，、]*(' || (v_d ->> 'call') || '))';
    v_g := regexp_replace(v_g, '[,，、]\s*[^.!?。！？,，、]*' || v_rec || '[^.!?。！？,，、]*', '', 'gi');
    v_g := btrim(regexp_replace(v_g, '\s*[^.!?。！？,，、]*' || v_rec || '[^.!?。！？,，、]*[.!?。！？,，、]?', '', 'gi'));
    -- then any sentence still holding both, across commas ("Cet appel, qui est enregistré, peut durer"): the whole sentence
    v_rec := '((' || (v_d ->> 'call') || ')[^.!?。！？]*(' || (v_d ->> 'recording') || ')|(' || (v_d ->> 'recording') || ')[^.!?。！？]*(' || (v_d ->> 'call') || '))';
    v_g := btrim(regexp_replace(v_g, '\s*[^.!?。！？]*' || v_rec || '[^.!?。！？]*[.!?。！？]?', '', 'gi'));
    v_rec := null;
  end if;
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


insert into supabase_migrations.schema_migrations (version, name) select to_char(now() at time zone 'utc', 'YYYYMMDDHH24MI') || '01', 'zella_call_disclosure' where not exists (select 1 from supabase_migrations.schema_migrations where name = 'zella_call_disclosure');

-- ===== zella_privacy_retention =====
-- Zella Voice: privacy policy and terms (drafts), 90 day automatic deletion of call recordings and transcripts, and
-- deletion at Vapi (security audit 18 Nov 2026, 12.2 and 12.3, H3 and part of H5; owner decisions 18 Nov 2026).
--   1. Drafts of the Zella Voice Privacy Policy and Terms of Service in legal_documents, status draft, marked "Draft
--      for owner and legal review" (nothing is published). zella_legal_current(kind) gives anyone the published version,
--      or the latest draft marked as a draft, for the /privacy and /terms pages. zella_owner_onboarding_legal_accept
--      records the owner's acceptance of the current versions, server side and audited (the onboarding step).
--   2. Retention, owner decision: call recordings and call transcripts are kept 90 days and deleted automatically
--      (all that is due, in batches, under lane G's legal hold lock).
--      data_retention_policies (sql/zella_data_retention.sql) now says 90 days for both; their legal status is not
--      changed. zella_retention_auto_run (server only) removes what is past 90 days, in batches of 1000, skipping
--      businesses on a legal hold, and runs in the daily job group; it does nothing while retention_purge_enabled (lane
--      G's owner only switch) is off or while the period is still pending legal review. Both are off today.
--   3. provider_deletions: a queue of calls to delete at Vapi (recording, transcript and the call itself). Filled by the
--      automatic deletion, by zella_erase_customer (changed in place, production's version only) and by the account
--      deletion purge (sql/zella_account_deletion.sql). The provider-deletions edge function sends them only while the
--      platform setting vapi_deletion_live is true (added here as false).
-- Needs sql/zella_data_retention.sql. zella_erase_customer, zella_run_schedule_group and zella_run_scheduled_job are
-- archived first and must be versions this file knows, otherwise VERSION_MISMATCH.
-- Rollback: sql/rollback/zella_privacy_retention_rollback.sql
begin;

do $$
begin
  if to_regclass('public.zella_function_archive') is null or to_regclass('public.data_retention_policies') is null
     or to_regprocedure('public.zella_retention_candidates(text,timestamptz)') is null or to_regclass('public.legal_documents') is null
     or to_regprocedure('public.zella_onboarding_authorize(uuid,boolean,boolean)') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing (lane G retention and owner onboarding first)';
  end if;
end $$;

-- 3. the Vapi deletion queue (server only)
create table if not exists public.provider_deletions (
  id uuid primary key default gen_random_uuid(),
  provider text not null check (provider in ('vapi')),
  object_kind text not null check (object_kind in ('call')),
  external_id text not null check (length(external_id) between 1 and 200),
  business_id uuid references public.businesses (id) on delete set null,
  reason text not null check (reason in ('retention', 'customer_erasure', 'business_deletion')),
  status text not null default 'queued' check (status in ('queued', 'sending', 'done', 'failed', 'not_found')),
  attempts integer not null default 0,
  last_error text,
  next_attempt_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  done_at timestamptz,
  unique (provider, object_kind, external_id)
);
comment on table public.provider_deletions is 'Calls to delete at Vapi (recording, transcript, call), sent by provider-deletions only while vapi_deletion_live is on';
create index if not exists provider_deletions_due_idx on public.provider_deletions (next_attempt_at) where status in ('queued', 'failed');
alter table public.provider_deletions enable row level security;
revoke all on public.provider_deletions from public, anon, authenticated;
grant all on public.provider_deletions to service_role;
insert into public.platform_settings (key, value) values ('vapi_deletion_live', 'false'::jsonb) on conflict (key) do nothing;

create or replace function public.zella_queue_provider_deletion(p_business_id uuid, p_external_call_id text, p_reason text)
returns boolean language sql security definer set search_path = '' as $$
  insert into public.provider_deletions (provider, object_kind, external_id, business_id, reason)
  select 'vapi', 'call', left(p_external_call_id, 200), p_business_id, p_reason where nullif(trim(coalesce(p_external_call_id, '')), '') is not null
  on conflict (provider, object_kind, external_id) do nothing
  returning true
$$;

-- the worker's two calls (server key): claim due rows, and record each result
create or replace function public.zella_provider_deletions_claim(p_limit integer default 20)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb;
begin
  if not coalesce(public.zella_setting('vapi_deletion_live', 'false'::jsonb) = 'true'::jsonb, false) then return '[]'::jsonb; end if;
  with c as (
    select id from public.provider_deletions
     where ((status in ('queued', 'failed') and next_attempt_at <= now() and attempts < 10)
        or (status = 'sending' and next_attempt_at <= now() - interval '10 minutes'))
       -- never for a business on a legal hold: those wait until the hold is released
       and (business_id is null or not public.zella_retention_on_hold(business_id))
     order by next_attempt_at limit greatest(1, least(coalesce(p_limit, 20), 100)) for update skip locked),
  u as (
    update public.provider_deletions d set status = 'sending', attempts = attempts + 1, next_attempt_at = now()
      from c where d.id = c.id returning d.id, d.provider, d.object_kind, d.external_id)
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'provider', provider, 'kind', object_kind, 'external_id', external_id)), '[]'::jsonb) into v from u;
  return v;
end $$;

create or replace function public.zella_provider_deletion_result(p_id uuid, p_outcome text, p_error text default null)
returns text language plpgsql security definer set search_path = '' as $$
begin
  if p_outcome not in ('done', 'failed', 'not_found') then raise exception 'BAD_OUTCOME'; end if;
  update public.provider_deletions set status = p_outcome, last_error = left(p_error, 300),
         done_at = case when p_outcome in ('done', 'not_found') then now() end,
         next_attempt_at = case when p_outcome = 'failed' then now() + least(interval '1 day', interval '5 minutes' * power(2, least(attempts, 8))) else next_attempt_at end
   where id = p_id and status = 'sending';
  if not found then return 'not_sending'; end if;
  if p_outcome = 'failed' and (select attempts from public.provider_deletions where id = p_id) >= 10 then
    perform public.zella_platform_alert('provider_deletion_failed', 'A call could not be deleted at Vapi', left(p_error, 300), 'warning', null, p_id::text);
  end if;
  return p_outcome;
end $$;

-- 2. 90 days for recordings and transcripts (owner, 18 Nov 2026); legal status unchanged
-- what the periods were before (once, never overwritten), so the rollback puts back exactly those
create table if not exists public.zella_migration_values (migration text not null, key text not null, value jsonb, primary key (migration, key));
alter table public.zella_migration_values enable row level security;
revoke all on public.zella_migration_values from public, anon, authenticated;
insert into public.zella_migration_values (migration, key, value)
select 'zella_privacy_retention', k || data_class, case k when 'days:' then to_jsonb(days) else to_jsonb(note) end
  from public.data_retention_policies, unnest(array['days:', 'note:']) k
 where data_class in ('call_recordings', 'call_transcripts') and coalesce(note, '') not like 'Owner decision 18 Nov 2026%'
on conflict do nothing;
update public.data_retention_policies set days = 90, updated_at = now(),
       note = 'Owner decision 18 Nov 2026: 90 days, deleted automatically (zella_retention_auto_run). ' || coalesce(note, '')
 where data_class in ('call_recordings', 'call_transcripts') and (days <> 90 or coalesce(note, '') not like 'Owner decision 18 Nov 2026%');

create or replace function public.zella_retention_auto_run()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare k text; p public.data_retention_policies; v_ids uuid[]; v_out jsonb := '{}'::jsonb; v_n integer; v_total integer; v_batch integer;
        pr public.data_retention_policies; pt public.data_retention_policies; v_q integer := 0;
begin
  if not coalesce((select value = 'true'::jsonb from public.platform_settings where key = 'retention_purge_enabled'), false) then
    return jsonb_build_object('skipped', 'switched_off');
  end if;
  -- the same lock as lane G's purges and zella_legal_hold_place: a hold never lands between the selection and the removal
  perform pg_advisory_xact_lock(hashtextextended('zella_legal_holds', 0));
  foreach k in array array['call_recordings', 'call_transcripts'] loop
    select * into p from public.data_retention_policies where data_class = k;
    if p.data_class is null or p.legal_status <> 'approved' then v_out := v_out || jsonb_build_object(k, 'legal_review_pending'); continue; end if;
    v_total := 0;
    -- batches of 1000 until nothing is due, at most 50 a run (50 000 calls), so a backlog clears within the run
    for v_batch in 1..50 loop
      select coalesce(array_agg(c.row_id), '{}') into v_ids from (
        select row_id from public.zella_retention_candidates(k, now() - make_interval(days => p.days)) where source = 'calls' order by dated limit 1000) c;
      exit when cardinality(v_ids) = 0;
      if k = 'call_recordings' then
        update public.calls set recording_url = null where id = any (v_ids);
      else
        update public.calls set transcript = 'Removed under the retention policy.' where id = any (v_ids);
      end if;
      get diagnostics v_n = row_count;
      v_total := v_total + v_n;
    end loop;
    v_out := v_out || jsonb_build_object(k, v_total);
    if v_total > 0 then
      insert into public.audit_logs (business_id, user_id, action, entity_type, new_data)
      values (null, null, 'retention.auto_purge', 'data_retention_policy', jsonb_build_object('data_class', k, 'days', p.days, 'removed', v_total));
    end if;
  end loop;
  -- the copy at Vapi holds the recording and the transcript together, so the whole call is queued for deletion only when
  -- both kinds are approved and the call is past both periods with neither left here (whoever removed them: this job
  -- or a manual purge run); a business on a legal hold is left out
  select * into pr from public.data_retention_policies where data_class = 'call_recordings';
  select * into pt from public.data_retention_policies where data_class = 'call_transcripts';
  if pr.legal_status = 'approved' and pt.legal_status = 'approved' then
    with q as (
      select public.zella_queue_provider_deletion(c.business_id, c.external_call_id, 'retention') as queued from public.calls c
       where c.external_call_id is not null and c.recording_url is null
         and (c.transcript is null or c.transcript = 'Removed under the retention policy.')
         and coalesce(c.ended_at, c.created_at) < now() - make_interval(days => greatest(pr.days, pt.days))
         and not public.zella_retention_on_hold(c.business_id)
         and not exists (select 1 from public.provider_deletions d where d.provider = 'vapi' and d.object_kind = 'call' and d.external_id = c.external_call_id)
       limit 50000)
    select count(*) filter (where queued) into v_q from q;
    v_out := v_out || jsonb_build_object('vapi_queued', v_q);
  end if;
  return v_out;
end $$;

-- 1. the drafts
insert into public.legal_documents (kind, version, title, body, status, requires_acceptance) values
  ('privacy', '0.1', 'Zella Voice Privacy Policy (Draft for owner and legal review)', $doc$DRAFT FOR OWNER AND LEGAL REVIEW. This text is not yet in effect.

Zella Voice Privacy Policy

1. Who we are
Zella Voice provides an AI receptionist and customer tools to businesses. A business that uses Zella Voice (our customer) decides how it uses them. For the calls, messages and records of a business's own customers, that business is responsible and Zella Voice processes the information on its behalf. For the people who sign in to Zella Voice to run a business, Zella Voice is responsible.

2. What we collect
a. Account information: name, email address, phone number, role, sign in and two step sign in records.
b. Business information: business name, address, opening hours, services, staff, phone numbers and settings.
c. Calls: the calling and called numbers, time and length of the call, what the AI receptionist did, a written summary, the transcript, and a recording only when the business has turned recording on. Callers are told at the start of every call that they are speaking with an AI receptionist, and that the call is recorded when it is.
d. Messages: texts and emails sent or received for the business, and appointment details.
e. Customer records the business keeps: names, contact details, appointments, notes and requests.
f. Identity checks for business owners, when the owner completes them.
g. Payment records for the business's plan. Card details are handled by our payment provider and never reach Zella Voice.
h. Technical records: the address and browser of people who sign in, and security logs.

3. Why we use it
To answer and route calls, book and change appointments, send the messages a business has set up, keep the business's records, verify business owners, bill for the service, keep the service secure, prevent abuse, and meet legal duties. We do not sell personal information and we do not use it for advertising.

4. Who processes it for us
a. Supabase: our database, sign in and file storage.
b. Vapi: runs the phone calls, the voice and the transcript.
c. Anthropic: the AI model that writes the receptionist's answers and summaries.
d. Telnyx: phone numbers and texts.
e. Resend: sending emails.
f. Stripe: payments.
g. n8n: runs our scheduled and automatic tasks.
h. Persona: identity checks for business owners.
Each one receives only what it needs to do its part and is bound by a written agreement.

5. How long we keep it
a. Call recordings and transcripts: 90 days after the call, then deleted automatically.
b. Text and email contents: 2 years, then the words are removed and only the record that a message was sent stays.
c. Audit and security logs: 7 years.
d. Owner identity files: 90 days after the check. The result of the check is kept.
e. When a business cancels, its records are kept for 90 days and then removed.
f. When a business owner asks to delete the account and Zella Voice confirms the request, the account is frozen at once and everything is deleted 30 days later unless the request is cancelled. Audit history is kept without the business's details.
g. When a business erases one of its customers, that customer's details, messages and calls are removed, and a request to delete the call at our phone provider is sent.

6. Your choices and rights
You can ask to see, correct, export or delete your information. Customers of a business can ask that business, which handles the request in Zella Voice within 30 days. You can stop marketing messages at any time with the link or by replying STOP.

7. Security
Information is encrypted in transit and at rest. Every Zella Voice staff member uses two step sign in. Access is limited to people who need it, and every access by our staff is logged.

8. Contact
privacy@zellavoice.com (owner to confirm the address and the company's legal name and postal address).

9. Changes
We will post any change here and tell business owners before it takes effect.$doc$, 'draft', true),
  ('terms', '0.1', 'Zella Voice Terms of Service (Draft for owner and legal review)', $doc$DRAFT FOR OWNER AND LEGAL REVIEW. This text is not yet in effect.

Zella Voice Terms of Service

1. The service
Zella Voice gives a business an AI receptionist that answers its calls, books appointments, takes messages and sends messages the business sets up, together with tools to keep its customer records.

2. Your account
You must give accurate details, keep your sign in safe, use two step sign in where asked, and make sure everyone you invite follows these terms. You are responsible for what is done in your account.

3. Your responsibilities to your callers and customers
a. You must have the right to contact the people you message or call, and you must honour requests to stop.
b. Callers are told at the start of each call that they are speaking with an AI receptionist. You may change the greeting but not remove that disclosure.
c. If you turn call recording on, you must make sure recording is lawful where you and your callers are. Callers are told when a call is recorded.
d. You must not use Zella Voice for anything unlawful, harmful, deceptive or abusive.

4. The AI receptionist
The receptionist works from the information you approve. It can make mistakes. It will not give medical, legal or financial advice, and it hands a call to a person or takes a message when it cannot help. Check what it books and records.

5. Plans, minutes and payment
Your plan sets your price and your allowances. When your minutes run out, calls are forwarded to your own number if you have one, or the caller is told the call can't be taken right now, unless you have chosen a paid option to continue. Prices and renewal terms are shown before you pay.

6. Your data
You own your business's data. We process it to provide the service as described in our Privacy Policy. You can export it, and you can ask us to delete your account: it is frozen at once and deleted 30 days after we confirm the request, unless you cancel it.

7. Availability
We work to keep Zella Voice available, and our status page says when something is not working. We are not responsible for failures of phone networks or of services outside our control.

8. Ending the service
You can cancel at any time. We may suspend an account that breaks these terms or puts others at risk, and we will tell you why.

9. Liability
To the extent the law allows, our total liability is limited to what you paid us in the 12 months before the claim. (Owner and counsel to confirm.)

10. Contact
support@zellavoice.com (owner to confirm the address and the company's legal name).$doc$, 'draft', true)
on conflict (kind, version) do nothing;

-- the version in effect for a page anyone can open: published if there is one, otherwise the latest draft, marked
create or replace function public.zella_legal_current(p_kind text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select jsonb_build_object('id', d.id, 'kind', d.kind, 'version', d.version, 'title', d.title, 'body', d.body, 'draft', false, 'effective_at', d.effective_at)
       from public.legal_documents d where d.kind = p_kind and d.status = 'published' order by d.published_at desc nulls last limit 1),
    (select jsonb_build_object('id', d.id, 'kind', d.kind, 'version', d.version, 'title', d.title, 'body', d.body, 'draft', true, 'effective_at', null)
       from public.legal_documents d where d.kind = p_kind and d.status in ('draft', 'in_review') order by d.created_at desc limit 1))
   where p_kind in ('privacy', 'terms')
$$;

-- the owner onboarding step: the owner accepts the current privacy policy and terms (recorded with their version)
create or replace function public.zella_owner_onboarding_legal_accept(p_business_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare k text; d jsonb; v_out jsonb := '[]'::jsonb;
begin
  perform public.zella_onboarding_authorize(p_business_id, true, false);
  foreach k in array array['privacy', 'terms'] loop
    d := public.zella_legal_current(k);
    if d is null then raise exception 'LEGAL_DOCUMENT_MISSING'; end if;
    insert into public.legal_acceptances (document_id, business_id, user_id) values ((d ->> 'id')::uuid, p_business_id, auth.uid())
    on conflict do nothing;
    v_out := v_out || jsonb_build_array(jsonb_build_object('kind', k, 'version', d ->> 'version', 'draft', (d ->> 'draft')::boolean));
  end loop;
  perform public.zella_onboarding_audit(p_business_id, auth.uid(), 'onboarding.legal_accepted', null, jsonb_build_object('documents', v_out));
  return jsonb_build_object('accepted', v_out);
end $$;

-- erasing a customer also queues their calls for deletion at Vapi; the daily group runs the automatic deletion
do $$
declare
  f record; d text; n integer;
  plan constant jsonb := jsonb_build_array(
    jsonb_build_object('sig', 'public.zella_erase_customer(uuid,uuid)', 'known', jsonb_build_array('3e070f982d65afbe1bf78ea4af835fe8'), 'marker', 'zella_privacy_retention',
      'anchor', $a$  update public.calls set transcript = null, recording_url = null, summary = null, from_number = null, to_number = null where customer_id = p_customer_id and business_id = p_business_id;
$a$,
      'with', $w$  -- zella_privacy_retention: the copies at Vapi are deleted too (sent while vapi_deletion_live is on)
  perform public.zella_queue_provider_deletion(p_business_id, c.external_call_id, 'customer_erasure') from public.calls c where c.customer_id = p_customer_id and c.business_id = p_business_id;
  update public.calls set transcript = null, recording_url = null, summary = null, from_number = null, to_number = null where customer_id = p_customer_id and business_id = p_business_id;
$w$),
    -- production's version, or main's with every pending migration before this file applied (weekly report, business
    -- moments, job intent, voice admin)
    jsonb_build_object('sig', 'public.zella_run_scheduled_job(text)', 'known', jsonb_build_array('671ec3ca5b53cc2d660f054b837d67d1', '0b2182d27e25e8dbf49041120fafee29'), 'marker', 'zella_retention_auto_run',
      'anchor', $a$  if p_job not in ('$a$, 'with', $w$  if p_job not in ('zella_retention_auto_run', '$w$),
    -- production's version, with sql/zella_cancellations_scheduled.sql applied, or main's with every pending migration
    jsonb_build_object('sig', 'public.zella_run_schedule_group(text)', 'known', jsonb_build_array('78b7fdfea58e49d1dfb594e7acc9b808', '5a9bc8c34841edd1ad3d66ff4156a006', '7e119dba5056dde8ffa8247419743808'), 'marker', 'zella_retention_auto_run',
      'anchor', $a$'zella_run_permission_check']$a$, 'with', $w$'zella_run_permission_check', 'zella_retention_auto_run']$w$));
begin
  for f in select x from jsonb_array_elements(plan) x loop
    if to_regprocedure(f.x ->> 'sig') is null then raise exception 'VERSION_MISMATCH: % is missing', f.x ->> 'sig'; end if;
    d := pg_get_functiondef((f.x ->> 'sig')::regprocedure);
    continue when position(f.x ->> 'marker' in d) > 0;   -- already applied
    if not (f.x -> 'known') ? md5(d) then raise exception 'VERSION_MISMATCH: % is not a version this file was written for', f.x ->> 'sig'; end if;
    n := (length(d) - length(replace(d, f.x ->> 'anchor', ''))) / length(f.x ->> 'anchor');
    if n <> 1 then raise exception 'VERSION_MISMATCH: % anchor found % times', f.x ->> 'sig', n; end if;
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_privacy_retention', f.x ->> 'sig', d, md5(d)) on conflict (migration, signature) do nothing;
    execute replace(d, f.x ->> 'anchor', f.x ->> 'with');
  end loop;
end $$;

revoke all on function public.zella_queue_provider_deletion(uuid, text, text), public.zella_provider_deletions_claim(integer),
  public.zella_provider_deletion_result(uuid, text, text), public.zella_retention_auto_run() from public, anon, authenticated;
grant execute on function public.zella_queue_provider_deletion(uuid, text, text), public.zella_provider_deletions_claim(integer),
  public.zella_provider_deletion_result(uuid, text, text), public.zella_retention_auto_run() to service_role;
revoke all on function public.zella_legal_current(text) from public;
grant execute on function public.zella_legal_current(text) to anon, authenticated, service_role;
revoke all on function public.zella_owner_onboarding_legal_accept(uuid) from public, anon;
grant execute on function public.zella_owner_onboarding_legal_accept(uuid) to authenticated, service_role;

commit;


insert into supabase_migrations.schema_migrations (version, name) select to_char(now() at time zone 'utc', 'YYYYMMDDHH24MI') || '02', 'zella_privacy_retention' where not exists (select 1 from supabase_migrations.schema_migrations where name = 'zella_privacy_retention');

-- ===== zella_account_deletion =====
-- Zella Voice: a business owner can ask for the account to be deleted (security audit 18 Nov 2026, 12.3, H5; owner
-- decisions 18 Nov 2026). There was no way to delete a business on request.
--   1. The owner asks in Settings (zella_business_deletion_request: an active owner, the business name typed exactly,
--      a reason). Zella Voice is alerted; nothing changes for the business yet. The owner can cancel any time before
--      the data is removed (zella_business_deletion_cancel).
--   2. A Zella Voice admin with security.manage (the permission lane G's purges need) confirms (zella_admin_business_deletion_confirm, audited). The
--      account is frozen at once: the business is suspended, so the AI receptionist stops answering its numbers and its
--      automations pause (the existing suspension rules); the purge date is 30 days later. Cancelling lifts this freeze.
--   3. zella_business_deletion_purge_due (daily job group) removes every confirmed business past its 30 days, using
--      lane G's purge path: the same switch (retention_purge_enabled, owner only, off), the same refusals (a legal
--      hold, audit history at risk until lane B's SET NULL is applied, billing or offer records kept, phone numbers
--      still assigned), a retention_purge_runs row approved by the confirming admin, the same "business.purged" audit,
--      the same storage file hand off (zella_business_purge_files_done), and the business row deleted (everything that
--      belongs to it goes with it; audit_logs keep their rows with business_id set to null, ACC-10). Its calls are
--      queued for deletion at Vapi first (provider_deletions, sent only while vapi_deletion_live is on). A request that
--      can't be purged yet is marked blocked with the reason and Zella Voice is alerted; it is tried again each day.
-- Every object is new; a function that exists already must be exactly this file's version (VERSION_MISMATCH).
-- Needs sql/zella_business_purge.sql and sql/zella_privacy_retention.sql.
-- Rollback: sql/rollback/zella_account_deletion_rollback.sql
begin;

do $$
declare f record;
  mine constant jsonb := '{"public.zella_business_deletion_freeze_note()": "50e160e55012c38d51692dab5e1f7dd8",
    "public.zella_business_deletion_purge_due()": "e35b7e44e4d303e48f4662674fa94515",
    "public.zella_business_deletion_status(uuid)": "ac7156772cbfd63060438b4137217983",
    "public.zella_business_deletion_request(uuid,text,text)": "5ea41bd703309f71ff4b7cddaefcdca6",
    "public.zella_business_deletion_cancel(uuid)": "f3e11179817eb9477d4dabcee45c3344",
    "public.zella_admin_business_deletion_confirm(uuid,text)": "b9a57d8ab2ade1f0c4e96565441ee050",
    "public.zella_admin_business_deletion_requests()": "e4c264caa842e2dae0394ea0e1699620"}';
begin
  if to_regclass('public.retention_purge_runs') is null or to_regprocedure('public.zella_business_purge_files_done(uuid,uuid,text[],text)') is null
     or to_regprocedure('public.zella_queue_provider_deletion(uuid,text,text)') is null or to_regprocedure('public.zella_admin_require(text)') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing (lane G business purge and zella_privacy_retention first)';
  end if;
  for f in select key, value from jsonb_each_text(mine) loop
    if to_regprocedure(f.key) is not null and md5(pg_get_functiondef(f.key::regprocedure)) <> f.value then
      raise exception 'VERSION_MISMATCH: % already exists in another version', f.key;
    end if;
  end loop;
end $$;

-- kept after the business is gone (no foreign key), as the record that the owner asked and who confirmed
create table if not exists public.business_deletion_requests (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  business_name text not null,
  status text not null default 'requested' check (status in ('requested', 'confirmed', 'blocked', 'cancelled', 'purged')),
  reason text not null check (length(btrim(reason)) between 3 and 300),
  requested_by uuid not null,
  requested_at timestamptz not null default now(),
  confirmed_by uuid,
  confirmed_at timestamptz,
  purge_after timestamptz,
  cancelled_by uuid,
  cancelled_at timestamptz,
  purged_at timestamptz,
  run_id uuid,
  last_error text check (last_error is null or length(last_error) <= 300)
);
-- whether confirming froze the business (it wasn't suspended already): only then does cancelling lift the suspension
alter table public.business_deletion_requests add column if not exists froze_business boolean not null default false;
comment on table public.business_deletion_requests is
  'Owner requests to delete a business account: confirmed by a Zella Voice admin, frozen, purged 30 days later (kept after the purge)';
create unique index if not exists business_deletion_requests_open on public.business_deletion_requests (business_id) where status in ('requested', 'confirmed', 'blocked');
alter table public.business_deletion_requests enable row level security;
revoke all on public.business_deletion_requests from public, anon, authenticated;
grant all on public.business_deletion_requests to service_role;

create or replace function public.zella_business_deletion_freeze_note() returns text language sql immutable as $$ select 'Account deletion confirmed: frozen until it is deleted'::text $$;

-- what the owner's Settings page shows
create or replace function public.zella_business_deletion_status(p_business_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when public.zella_has_role(p_business_id, array['owner', 'admin']) then coalesce(
    (select jsonb_build_object('id', r.id, 'status', r.status, 'requested_at', r.requested_at, 'confirmed_at', r.confirmed_at, 'purge_after', r.purge_after)
       from public.business_deletion_requests r where r.business_id = p_business_id and r.status in ('requested', 'confirmed', 'blocked')), '{}'::jsonb) end
$$;

create or replace function public.zella_business_deletion_request(p_business_id uuid, p_confirm_name text, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare b public.businesses; r public.business_deletion_requests; v_reason text := left(btrim(coalesce(p_reason, '')), 300);
begin
  if auth.uid() is null or not exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = auth.uid()
                                         and m.role = 'owner' and m.status = 'active') then raise exception 'NOT_ALLOWED'; end if;
  if not public.zella_mfa_satisfied() then raise exception 'MFA_REQUIRED'; end if;
  select * into b from public.businesses where id = p_business_id for update;
  if coalesce(p_confirm_name, '') <> b.name then raise exception 'CONFIRM_MISMATCH'; end if;
  if length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  if exists (select 1 from public.business_deletion_requests where business_id = b.id and status in ('requested', 'confirmed', 'blocked')) then raise exception 'ALREADY_REQUESTED'; end if;
  insert into public.business_deletion_requests (business_id, business_name, reason, requested_by) values (b.id, b.name, v_reason, auth.uid()) returning * into r;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (b.id, auth.uid(), 'business.deletion_requested', 'business_deletion_request', r.id, jsonb_build_object('reason', v_reason));
  perform public.zella_platform_alert('business_deletion_requested', 'An owner asked to delete their account', b.name, 'warning', b.id, r.id::text);
  return jsonb_build_object('id', r.id, 'status', r.status);
end $$;

create or replace function public.zella_business_deletion_cancel(p_business_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.business_deletion_requests;
begin
  if auth.uid() is null or not (public.zella_has_role(p_business_id, array['owner']) or public.zella_admin_can('businesses.manage')) then raise exception 'NOT_ALLOWED'; end if;
  update public.business_deletion_requests set status = 'cancelled', cancelled_by = auth.uid(), cancelled_at = now()
   where business_id = p_business_id and status in ('requested', 'confirmed', 'blocked') returning * into r;
  if r.id is null then raise exception 'NOT_FOUND'; end if;
  -- lift only the freeze this flow put on (an admin's own suspension stays)
  if r.froze_business then
    update public.businesses set suspended_at = null, suspension_reason = null, updated_at = now()
     where id = p_business_id and suspension_reason = public.zella_business_deletion_freeze_note();
  end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id) values (p_business_id, auth.uid(), 'business.deletion_cancelled', 'business_deletion_request', r.id);
  perform public.zella_resolve_platform_alerts('business_deletion_requested', p_business_id, null, 'Cancelled');
  return jsonb_build_object('id', r.id, 'status', r.status);
end $$;

create or replace function public.zella_admin_business_deletion_confirm(p_business_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.business_deletion_requests; v_reason text := left(btrim(coalesce(p_reason, '')), 300);
begin
  -- security.manage, as for lane G's purges: the confirming admin is the run's approver and executor, who finishes
  -- the file removal (zella_business_purge_files_done needs it)
  perform public.zella_admin_require('security.manage');
  if length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  update public.business_deletion_requests set status = 'confirmed', confirmed_by = auth.uid(), confirmed_at = now(), purge_after = now() + interval '30 days'
   where business_id = p_business_id and status = 'requested' returning * into r;
  if r.id is null then raise exception 'NOT_FOUND'; end if;
  -- frozen at once: a suspended business isn't answered and its automations pause (the lifecycle rules). A business
  -- already suspended for another reason stays exactly as it is, and cancelling won't lift that suspension
  update public.businesses set suspended_at = now(), suspension_reason = public.zella_business_deletion_freeze_note(), updated_at = now()
   where id = p_business_id and suspended_at is null;
  if found then update public.business_deletion_requests set froze_business = true where id = r.id; end if;
  perform public.zella_admin_audit('business.deletion_confirmed', 'business_deletion_request', r.id, p_business_id, null,
    jsonb_build_object('purge_after', r.purge_after, 'reason', v_reason));
  begin
    perform public.zella_notify_owners(p_business_id, 'account_deletion_confirmed', 'Your account will be deleted',
      'Zella Voice confirmed your request. Your account is frozen and everything will be deleted on ' || to_char(r.purge_after, 'FMMonth FMDD, YYYY')
      || '. You can cancel until then in Settings.', 'warning', 'settings');
  exception when others then null;
  end;
  return jsonb_build_object('id', r.id, 'status', r.status, 'purge_after', r.purge_after);
end $$;

-- Zella Voice admins: the requests waiting, confirmed or blocked, and the last 50 closed ones
create or replace function public.zella_admin_business_deletion_requests()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.zella_admin_require('businesses.view');
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.requested_at desc) from (
    (select r.id, r.business_id, r.business_name, r.status, r.reason, r.requested_at, r.confirmed_at, r.purge_after, r.last_error
       from public.business_deletion_requests r where r.status in ('requested', 'confirmed', 'blocked'))
    union all
    (select r.id, r.business_id, r.business_name, r.status, r.reason, r.requested_at, r.confirmed_at, r.purge_after, r.last_error
       from public.business_deletion_requests r where r.status in ('cancelled', 'purged') order by r.requested_at desc limit 50)) x), '[]'::jsonb);
end $$;

-- the daily job: lane G's purge path for every confirmed request past its 30 days
create or replace function public.zella_business_deletion_purge_due()
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.business_deletion_requests; b public.businesses; v_run public.retention_purge_runs; v_paths text[]; v_audit int; v_why text; v_n int := 0;
begin
  if not coalesce((select value = 'true'::jsonb from public.platform_settings where key = 'retention_purge_enabled'), false) then
    return jsonb_build_object('skipped', 'switched_off');
  end if;
  -- the same lock as lane G's purges and zella_legal_hold_place: a hold never lands in the middle of a purge
  perform pg_advisory_xact_lock(hashtextextended('zella_legal_holds', 0));
  for r in select * from public.business_deletion_requests where status in ('confirmed', 'blocked') and purge_after <= now() order by purge_after for update skip locked loop
    select * into b from public.businesses where id = r.business_id for update;
    v_why := case
      when b.id is null then 'BUSINESS_NOT_FOUND'
      -- like lane G's purge: the cancelled business period must be legally approved
      when (select legal_status from public.data_retention_policies where data_class = 'cancelled_business') is distinct from 'approved' then 'LEGAL_REVIEW_PENDING'
      when public.zella_retention_on_hold(b.id) then 'LEGAL_HOLD'
      when (select confdeltype from pg_constraint where conrelid = 'public.audit_logs'::regclass and conname = 'audit_logs_business_id_fkey') is distinct from 'n'
           or position('deleted_business_id' in pg_get_functiondef('public.zella_audit_privileged()'::regprocedure)) = 0 then 'AUDIT_HISTORY_AT_RISK'
      when exists (select 1 from public.payments where business_id = b.id) or exists (select 1 from public.billing_events where business_id = b.id)
           or exists (select 1 from public.customer_charge_payments where business_id = b.id) or exists (select 1 from public.usage_charges where business_id = b.id)
           or (to_regclass('public.billing_periods') is not null and exists (select 1 from public.billing_periods where business_id = b.id)) then 'BILLING_RECORDS_KEPT'
      when exists (select 1 from public.offer_redemptions where business_id = b.id) then 'OFFER_HISTORY_KEPT'
      when exists (select 1 from public.business_phone_numbers where business_id = b.id) then 'NUMBERS_STILL_ASSIGNED' end;
    if v_why is not null then
      update public.business_deletion_requests set status = 'blocked', last_error = v_why where id = r.id;
      perform public.zella_platform_alert('business_deletion_blocked', 'An account deletion is waiting', r.business_name || ': ' || v_why, 'warning', r.business_id, r.id::text);
      continue;
    end if;
    perform public.zella_queue_provider_deletion(b.id, c.external_call_id, 'business_deletion') from public.calls c where c.business_id = b.id and c.external_call_id is not null;
    insert into public.retention_purge_runs (data_class, business_id, status, requested_by, request_reason, cutoff, items, item_count, owner_approved_by, owner_approved_at, executed_by, executed_at)
    values ('cancelled_business', b.id, 'running', r.requested_by, 'The owner asked to delete the account', now(), jsonb_build_array(jsonb_build_object('source', 'businesses', 'id', b.id)), 1,
            r.confirmed_by, r.confirmed_at, r.confirmed_by, now()) returning * into v_run;
    select coalesce(array_agg(distinct x order by x), '{}') into v_paths from (
      select 'business-documents/' || file_path as x from public.business_verification_documents where business_id = b.id
      union select 'record-files/' || path from public.crm_record_files where business_id = b.id
      union select o.bucket_id || '/' || o.name from storage.objects o
       where o.bucket_id in ('business-documents', 'record-files', 'brand-assets') and o.name like b.id::text || '/%') s;
    select count(*) into v_audit from public.audit_logs where business_id = b.id;
    perform public.zella_actor_audit(r.confirmed_by, 'business.purged', 'business', b.id, null,
      jsonb_build_object('name', b.name, 'industry_id', b.industry_id, 'created_at', b.created_at),
      jsonb_build_object('run', v_run.id, 'deletion_request', r.id, 'requested_at', r.requested_at, 'confirmed_at', r.confirmed_at,
                         'audit_rows_kept', v_audit, 'files_to_remove', coalesce(array_length(v_paths, 1), 0)));
    delete from public.legal_holds where business_id = b.id and released_at is not null;
    delete from public.businesses where id = b.id;
    update public.retention_purge_runs set status = case when coalesce(array_length(v_paths, 1), 0) > 0 then 'files_pending' else 'done' end,
           removed_count = 1, file_paths = v_paths, updated_at = now() where id = v_run.id;
    update public.business_deletion_requests set status = 'purged', purged_at = now(), run_id = v_run.id, last_error = null where id = r.id;
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('purged', v_n);
end $$;

-- applied again after a rollback (which lifted its freezes): every open confirmed or blocked request is frozen again,
-- the same way confirming freezes, before the daily purge can reach it; a business suspended for another reason is left as is
with f as (
  update public.businesses b set suspended_at = now(), suspension_reason = public.zella_business_deletion_freeze_note(), updated_at = now()
    from public.business_deletion_requests r
   where r.business_id = b.id and r.status in ('confirmed', 'blocked') and b.suspended_at is null
  returning b.id)
update public.business_deletion_requests r set froze_business = true from f where r.business_id = f.id and r.status in ('confirmed', 'blocked');

revoke all on function public.zella_business_deletion_freeze_note(), public.zella_business_deletion_purge_due() from public, anon, authenticated;
grant execute on function public.zella_business_deletion_freeze_note(), public.zella_business_deletion_purge_due() to service_role;
revoke all on function public.zella_business_deletion_status(uuid), public.zella_business_deletion_request(uuid, text, text),
  public.zella_business_deletion_cancel(uuid), public.zella_admin_business_deletion_confirm(uuid, text), public.zella_admin_business_deletion_requests() from public, anon;
grant execute on function public.zella_business_deletion_status(uuid), public.zella_business_deletion_request(uuid, text, text),
  public.zella_business_deletion_cancel(uuid), public.zella_admin_business_deletion_confirm(uuid, text), public.zella_admin_business_deletion_requests() to authenticated, service_role;

-- the daily group runs it (after zella_retention_auto_run, which sql/zella_privacy_retention.sql added)
do $$
declare d text; s1 constant text := 'public.zella_run_scheduled_job(text)'; s2 constant text := 'public.zella_run_schedule_group(text)';
  a1 constant text := $a$  if p_job not in ('zella_retention_auto_run', '$a$;
  w1 constant text := $w$  if p_job not in ('zella_retention_auto_run', 'zella_business_deletion_purge_due', '$w$;
  a2 constant text := $a$'zella_retention_auto_run']$a$;
  w2 constant text := $w$'zella_retention_auto_run', 'zella_business_deletion_purge_due']$w$;
begin
  d := pg_get_functiondef(s1::regprocedure);
  if position('zella_business_deletion_purge_due' in d) = 0 then
    if (length(d) - length(replace(d, a1, ''))) / length(a1) <> 1 then raise exception 'VERSION_MISMATCH: % (apply sql/zella_privacy_retention.sql first)', s1; end if;
    insert into public.zella_function_archive (migration, signature, definition, definition_md5) values ('zella_account_deletion', s1, d, md5(d)) on conflict do nothing;
    execute replace(d, a1, w1);
  end if;
  d := pg_get_functiondef(s2::regprocedure);
  if position('zella_business_deletion_purge_due' in d) = 0 then
    if (length(d) - length(replace(d, a2, ''))) / length(a2) <> 1 then raise exception 'VERSION_MISMATCH: % (apply sql/zella_privacy_retention.sql first)', s2; end if;
    insert into public.zella_function_archive (migration, signature, definition, definition_md5) values ('zella_account_deletion', s2, d, md5(d)) on conflict do nothing;
    execute replace(d, a2, w2);
  end if;
end $$;

commit;


insert into supabase_migrations.schema_migrations (version, name) select to_char(now() at time zone 'utc', 'YYYYMMDDHH24MI') || '03', 'zella_account_deletion' where not exists (select 1 from supabase_migrations.schema_migrations where name = 'zella_account_deletion');
