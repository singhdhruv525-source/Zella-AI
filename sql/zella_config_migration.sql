-- Zella - bringing existing businesses' setup answers into the live settings: preview, apply with a snapshot, restore
-- (5 Nov 2026). Safe to run twice. Not applied. Report: docs/CONFIG_MIGRATION_PREVIEW_2026-11-05.md. Class V.
--
-- zella_setup_enforcement.sql (applied 5 Nov) makes NEW setup saves reach the live settings, but businesses set up before
-- it keep stale live settings until someone re-saves setup: their FAQs aren't answerable, a chosen second language and
-- greeting aren't used, a setup transfer number isn't used. This file lets the platform team see, per business, what
-- is live now and what would be live, apply it with a snapshot, and undo it.
--
-- Precedence, for each setting (the first that is set wins; a later source never overwrites an earlier one):
--   language and greeting   Settings > Languages (a business_languages row: the owner's own choice) > setup answers
--   transfer number         call routing set by an admin (transfer_number not written by setup) > setup receptionist
--                           step's transfer phone > setup integrations transfer number > owner's phone (type "owner")
--   setup knowledge         always the current setup answers (items with source_key 'setup:...'); the owner's own
--                           Knowledge items are never touched
-- Validation is the same as when the owner saves (language catalog, greeting text rules, phone in E.164); a business whose
-- setup value fails is reported as needs_fix and left as it is.

create table if not exists public.config_migration_snapshots (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  taken_at timestamptz not null default now(),
  taken_by uuid,
  languages jsonb,              -- the business_languages row, or null when there was none
  escalation_rules jsonb,
  setup_knowledge jsonb not null default '[]',   -- id, status and content of every setup:... item
  applied jsonb,
  restored_at timestamptz
);
alter table public.config_migration_snapshots enable row level security;
revoke all on public.config_migration_snapshots from anon, authenticated;
grant select, insert, update, delete on public.config_migration_snapshots to service_role;

-- the same checks as zella_setup_language_apply, without writing
create or replace function public.zella_setup_language_check(p_language text, p_greeting text) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare v_primary text; v_extras text[] := '{}'; v_greeting text;
begin
  case coalesce(p_language, 'en-US')
    when 'en-US' then v_primary := 'en-US';
    when 'es-US' then v_primary := 'es';
    when 'en-US+es-US' then v_primary := 'en-US'; v_extras := array['es'];
    else return jsonb_build_object('ok', false, 'reason', 'UNKNOWN_LANGUAGE');
  end case;
  v_greeting := nullif(trim(regexp_replace(coalesce(p_greeting, ''), '\s+', ' ', 'g')), '');
  if v_greeting is not null and (length(v_greeting) not between 5 and 200 or v_greeting ~ '(https?://|www\.|[<>\[\]`]|\{(?!name\}))') then
    return jsonb_build_object('ok', false, 'reason', 'GREETING_TEXT');
  end if;
  return jsonb_build_object('ok', true, 'primary', v_primary, 'extras', to_jsonb(v_extras), 'greeting', v_greeting);
end $$;

create or replace function public.zella_mask_phone(p text) returns text language sql immutable set search_path = '' as $$
  select case when p is null or p = '' then null else '…' || right(regexp_replace(p, '\D', '', 'g'), 2) end $$;

-- What each business has live now, what it would have, and why. Phone numbers are masked; no customer data.
create or replace function public.zella_config_migration_preview(p_business_id uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare b record; out_arr jsonb := '[]'; item jsonb; lang jsonb; kb jsonb; er jsonb; sd jsonb; vc jsonb;
        v_live_lang record; v_chk jsonb; v_setup_n int; v_live_n int; v_pick text; v_live_num text; v_live_src text; v_items jsonb; v_stale boolean;
begin
  for b in select x.id, x.name, x.setup_data, x.onboarding_status from businesses x where p_business_id is null or x.id = p_business_id order by x.created_at loop
    select coalesce(c.voice_config, '{}'), coalesce(c.knowledge_base, '{}'), coalesce(c.escalation_rules, '{}') into vc, kb, er
      from ai_agents a join ai_agent_configs c on c.agent_id = a.id where a.business_id = b.id and a.is_default limit 1;
    vc := coalesce(vc, '{}'); kb := coalesce(kb, '{}'); er := coalesce(er, '{}'); sd := coalesce(b.setup_data, '{}');
    v_items := '[]'; v_stale := false;

    -- language
    select * into v_live_lang from business_languages where business_id = b.id;
    if vc ? 'language' or vc ? 'greeting' then
      v_chk := public.zella_setup_language_check(vc ->> 'language', vc ->> 'greeting');
      lang := jsonb_build_object('setting', 'language',
        'live', case when v_live_lang.business_id is null then null else jsonb_build_object('primary', v_live_lang.primary_language, 'extras', v_live_lang.extra_languages, 'greeting_set', v_live_lang.greeting is not null) end,
        'setup', jsonb_build_object('language', vc ->> 'language', 'greeting_set', nullif(vc ->> 'greeting', '') is not null),
        'action', case when v_live_lang.business_id is not null then 'keep_override' when not (v_chk ->> 'ok')::boolean then 'needs_fix' else 'apply_setup' end,
        'reason', case when v_live_lang.business_id is not null then 'The owner chose languages in Settings; that choice is kept.'
                       when not (v_chk ->> 'ok')::boolean then 'The setup value fails the same check as Settings: ' || (v_chk ->> 'reason')
                       else 'Setup chose ' || (vc ->> 'language') || '; the live assistant has no language settings yet.' end,
        'proposed', case when v_live_lang.business_id is null and (v_chk ->> 'ok')::boolean then v_chk - 'ok' end);
      v_items := v_items || lang;
    end if;

    -- setup knowledge
    v_setup_n := coalesce(jsonb_array_length(case when jsonb_typeof(kb -> 'faqs') = 'array' then kb -> 'faqs' end), 0)
               + (select count(*) from jsonb_each(case when jsonb_typeof(kb -> 'policies') = 'object' then kb -> 'policies' else '{}' end) p where coalesce(trim(p.value #>> '{}'), '') <> '')
               + case when coalesce(trim(kb ->> 'about'), '') <> '' then 1 else 0 end + case when coalesce(trim(kb ->> 'service_area'), '') <> '' then 1 else 0 end
               + coalesce(jsonb_array_length(case when jsonb_typeof(kb -> 'business_details') = 'array' then kb -> 'business_details' end), 0);
    select count(*) into v_live_n from knowledge_items where business_id = b.id and source_key like 'setup:%' and source_page_id is null and status = 'ready';
    if v_setup_n > 0 or v_live_n > 0 then
      v_items := v_items || jsonb_build_object('setting', 'setup_knowledge', 'live', v_live_n, 'setup', v_setup_n,
        'action', case when v_setup_n <> v_live_n then 'apply_setup' else 'none' end,
        'reason', case when v_setup_n <> v_live_n then v_setup_n || ' setup answers, ' || v_live_n || ' answerable now.' else 'Already answerable.' end);
    end if;

    -- transfer number
    v_live_num := nullif(er ->> 'transfer_number', ''); v_live_src := er ->> 'transfer_number_source';
    v_pick := coalesce(nullif(er #>> '{transfer_to,phone}', ''), nullif(sd #>> '{integrations,transfer_number}', ''),
                       case when er #>> '{transfer_to,type}' = 'owner' then nullif(sd #>> '{owner,phone}', '') end);
    if v_pick is not null or v_live_num is not null then
      v_items := v_items || jsonb_build_object('setting', 'transfer_number',
        'live', public.zella_mask_phone(coalesce(v_live_num, er #>> '{transfer_to,phone}')), 'live_source', case when v_live_num is null then 'setup receptionist step' when v_live_src = 'setup' then 'setup' else 'admin call routing' end,
        'setup', public.zella_mask_phone(v_pick),
        'action', case when v_live_num is not null and coalesce(v_live_src, '') <> 'setup' then 'keep_override'
                       when v_pick is null then 'none'
                       when public.zella_normalize_e164(v_pick) is null then 'needs_fix'
                       when v_pick is not distinct from coalesce(v_live_num, er #>> '{transfer_to,phone}') then 'none' else 'apply_setup' end,
        'reason', case when v_live_num is not null and coalesce(v_live_src, '') <> 'setup' then 'An admin set this number in call routing; it is kept.'
                       when v_pick is not null and public.zella_normalize_e164(v_pick) is null then 'The setup number is not a valid phone number with country code.'
                       else 'Setup''s number, by precedence.' end);
    end if;

    -- messages held for the owner (sql/zella_channel_review.sql)
    if to_regclass('public.automation_channel_reviews') is not null then
      execute 'select coalesce(jsonb_agg(jsonb_build_object(''setting'', ''message_channel'', ''automation'', a.name, ''live'', r.requested_channel, ''action'', ''owner_decides'',
                 ''reason'', ''Saved as AI call, which is not available; nothing is sent until the owner chooses.'')), ''[]'')
                 from automation_channel_reviews r join automations a on a.id = r.automation_id where r.business_id = $1 and r.status = ''needs_review'''
        into item using b.id;
      v_items := v_items || item;
    end if;

    v_stale := exists (select 1 from jsonb_array_elements(v_items) x where x ->> 'action' in ('apply_setup', 'needs_fix', 'owner_decides'));
    out_arr := out_arr || jsonb_build_object('business_id', b.id, 'name', b.name, 'status', b.onboarding_status, 'stale', v_stale, 'items', v_items);
  end loop;
  return out_arr;
end $$;

-- Apply one business: snapshot, then each apply_setup item; returns what changed. Owners are told.
create or replace function public.zella_config_migration_apply(p_business_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p jsonb := public.zella_config_migration_preview(p_business_id) -> 0; it jsonb; v_snap uuid; v_done jsonb := '[]'; vc jsonb; er jsonb; sd jsonb; v_pick text; v_agent uuid;
begin
  if p is null then raise exception 'NOT_FOUND'; end if;
  select a.id, coalesce(c.voice_config, '{}'), coalesce(c.escalation_rules, '{}') into v_agent, vc, er
    from ai_agents a join ai_agent_configs c on c.agent_id = a.id where a.business_id = p_business_id and a.is_default limit 1;
  select coalesce(setup_data, '{}') into sd from businesses where id = p_business_id;
  insert into config_migration_snapshots (business_id, taken_by, languages, escalation_rules, setup_knowledge)
  values (p_business_id, auth.uid(), (select to_jsonb(l) from business_languages l where l.business_id = p_business_id), er,
          coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'status', k.status, 'title', k.title, 'question', k.question, 'answer', k.answer, 'kind', k.kind))
                      from knowledge_items k where k.business_id = p_business_id and k.source_key like 'setup:%' and k.source_page_id is null), '[]'))
  returning id into v_snap;
  for it in select * from jsonb_array_elements(p -> 'items') where value ->> 'action' = 'apply_setup' loop
    if it ->> 'setting' = 'language' then
      perform public.zella_setup_language_apply(p_business_id, vc ->> 'language', vc ->> 'greeting');
    elsif it ->> 'setting' = 'setup_knowledge' then
      perform public.zella_setup_knowledge_sync(p_business_id);
    elsif it ->> 'setting' = 'transfer_number' then
      v_pick := coalesce(nullif(er #>> '{transfer_to,phone}', ''), nullif(sd #>> '{integrations,transfer_number}', ''),
                         case when er #>> '{transfer_to,type}' = 'owner' then nullif(sd #>> '{owner,phone}', '') end);
      update ai_agent_configs set escalation_rules = coalesce(escalation_rules, '{}') || jsonb_build_object('transfer_number', public.zella_normalize_e164(v_pick), 'transfer_number_source', 'setup'),
             updated_at = now() where agent_id = v_agent;
    end if;
    v_done := v_done || jsonb_build_array(it ->> 'setting');
  end loop;
  update config_migration_snapshots set applied = v_done where id = v_snap;
  if jsonb_array_length(v_done) > 0 then
    perform public.zella_notify(p_business_id, 'settings_migrated', 'Your setup answers are now live',
      'Zella brought these setup answers into your receptionist: ' || (select string_agg(replace(x, '_', ' '), ', ') from jsonb_array_elements_text(v_done) x)
      || '. Review them in Settings; your own changes were kept.', 'info', 'receptionist', null, null);
  end if;
  return jsonb_build_object('snapshot_id', v_snap, 'applied', v_done, 'after', public.zella_config_migration_preview(p_business_id) -> 0);
end $$;

-- Undo one apply exactly: languages row, call routing, setup knowledge (items created by it are archived, earlier ones get
-- their earlier text and status back).
create or replace function public.zella_config_migration_restore(p_snapshot_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s record; v_agent uuid; k jsonb;
begin
  select * into s from config_migration_snapshots where id = p_snapshot_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if s.restored_at is not null then return jsonb_build_object('restored', false, 'reason', 'already restored'); end if;
  select a.id into v_agent from ai_agents a where a.business_id = s.business_id and a.is_default limit 1;
  delete from business_languages where business_id = s.business_id;
  if s.languages is not null then
    insert into business_languages select * from jsonb_populate_record(null::business_languages, s.languages);
  end if;
  if s.applied ? 'transfer_number' then
    update ai_agent_configs
       set escalation_rules = (coalesce(escalation_rules, '{}'::jsonb) - 'transfer_number' - 'transfer_number_source')
             || (select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
                   from jsonb_each(coalesce(s.escalation_rules, '{}'::jsonb))
                  where key in ('transfer_number', 'transfer_number_source')),
           updated_at = now()
     where agent_id = v_agent;
  end if;
  update knowledge_items set status = 'archived', updated_at = now()
   where business_id = s.business_id and source_key like 'setup:%' and source_page_id is null
     and not exists (select 1 from jsonb_array_elements(s.setup_knowledge) x where (x ->> 'id')::uuid = knowledge_items.id);
  for k in select * from jsonb_array_elements(s.setup_knowledge) loop
    update knowledge_items set status = k ->> 'status', title = k ->> 'title', question = k ->> 'question', answer = k ->> 'answer', kind = k ->> 'kind', updated_at = now()
     where id = (k ->> 'id')::uuid;
  end loop;
  update config_migration_snapshots set restored_at = now() where id = p_snapshot_id;
  return jsonb_build_object('restored', true, 'business_id', s.business_id);
end $$;

revoke execute on function public.zella_config_migration_preview(uuid), public.zella_config_migration_apply(uuid), public.zella_config_migration_restore(uuid),
  public.zella_setup_language_check(text, text), public.zella_mask_phone(text) from public, anon, authenticated;
grant execute on function public.zella_config_migration_preview(uuid), public.zella_config_migration_apply(uuid), public.zella_config_migration_restore(uuid),
  public.zella_setup_language_check(text, text), public.zella_mask_phone(text) to service_role;
