-- Zella - what the setup wizard saves is what the AI receptionist does (5 Nov 2026). Safe to run twice.
-- Not applied. Trace and findings: docs/SETUP_FIELD_TRACE_2026-11-05.md.
--
-- D1  "Book / reschedule / cancel appointments" switched off in setup (appointment_rules.can_book / can_reschedule /
--     can_cancel = false) were never read: the tools stayed in the assistant's list and worked. Now they are left out
--     of the list and refused if called. Only an explicit false switches a tool off (older setups keep working).
-- D2  Setup FAQs, policies, "about", service area and industry details were saved to ai_agent_configs.knowledge_base,
--     which no call path reads (the prompt sends business facts to search_knowledge, which searches knowledge_items
--     only). They are now kept as knowledge_items with source_key 'setup:…', updated whenever the setup answers change;
--     items an owner adds on the Knowledge page are never touched.
-- D3  Booking used 30 minutes when no length was given, offered times from "now" and accepted bookings up to a year
--     ahead, ignoring setup's default length, minimum notice and how far ahead. Now availability, booking and
--     rescheduling keep to them. (The buffer between appointments is not enforced yet: see the trace, D3b.)
-- D6  Setup's language ("English and Spanish") and greeting were saved to voice_config, which the live assistant
--     doesn't read (it reads business_languages). zella_setup_language_apply saves them there with the same checks as
--     Settings > Languages; owner-provision-business calls it when the receptionist step is saved.
--
-- Each patch of an existing function anchors on text that is still in the function after the pending migrations
-- (zella_ai_caller_fixes, zella_store_orders), so they apply in any order; a function that changed stops this file.
-- Class V (live calls): from the next call, businesses with booking abilities off stop booking, setup facts become
-- answerable, and booking keeps to notice and horizon.
-- Rollback: sql/rollback/zella_setup_enforcement_rollback.sql.

-- ---------------------------------------------------------------------------------------------------------------
-- D1 + D3: helpers
create or replace function public.zella_booking_rules(p_business_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce((select c.appointment_rules from public.ai_agents a join public.ai_agent_configs c on c.agent_id = a.id
                    where a.business_id = p_business_id and a.is_default limit 1), '{}'::jsonb);
$$;
revoke execute on function public.zella_booking_rules(uuid) from public, anon, authenticated;
grant execute on function public.zella_booking_rules(uuid) to service_role;

-- The tools a business switched off in setup (only an explicit false counts).
create or replace function public.zella_setup_disabled_tools(p_business_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  with r as (select public.zella_booking_rules(p_business_id) j)
  select coalesce(jsonb_agg(t), '[]'::jsonb) from r, lateral (
    select 'check_availability' t where r.j ->> 'can_book' = 'false'
    union all select 'book_appointment' where r.j ->> 'can_book' = 'false'
    union all select 'reschedule_appointment' where r.j ->> 'can_reschedule' = 'false'
    union all select 'cancel_appointment' where r.j ->> 'can_cancel' = 'false') x;
$$;
revoke execute on function public.zella_setup_disabled_tools(uuid) from public, anon, authenticated;
grant execute on function public.zella_setup_disabled_tools(uuid) to service_role;

do $$
declare def text;
begin
  -- D1: the assistant's tool list
  def := pg_get_functiondef('public.zella_brain_context(uuid)'::regprocedure);
  if position('zella_setup_enforcement_tools' in def) = 0 then
    def := replace(def, $a$  v_disabled := coalesce(v_cfg.business_context -> 'disabled_tools', '[]'::jsonb);$a$,
      $a$  v_disabled := coalesce(v_cfg.business_context -> 'disabled_tools', '[]'::jsonb);
  /* zella_setup_enforcement_tools */ v_disabled := v_disabled || public.zella_setup_disabled_tools(p_business_id);$a$);
    if position('zella_setup_enforcement_tools' in def) = 0 then raise exception 'zella_brain_context has changed; review this patch'; end if;
    execute def;
  end if;

  -- D1: refused if called anyway
  def := pg_get_functiondef('public.zella_ai_tool(text, uuid, text, jsonb, text)'::regprocedure);
  if position('zella_setup_enforcement_tools' in def) = 0 then
    def := replace(def, $a$  if v_disabled is not null and jsonb_typeof(v_disabled) = 'array' and v_disabled ? p_tool then
    return jsonb_build_object('ok', false, 'status', 'not_available', 'say', 'This business does not use that. Offer to take a message instead.');
  end if;$a$, $a$  if v_disabled is not null and jsonb_typeof(v_disabled) = 'array' and v_disabled ? p_tool then
    return jsonb_build_object('ok', false, 'status', 'not_available', 'say', 'This business does not use that. Offer to take a message instead.');
  end if;
  /* zella_setup_enforcement_tools */
  if public.zella_setup_disabled_tools(v_biz) ? p_tool then
    return jsonb_build_object('ok', false, 'status', 'not_available', 'say', case when p_tool in ('check_availability', 'book_appointment')
      then 'The team handles bookings for this business. Offer to take a message so they can arrange a time.'
      else 'The team handles changes to appointments. Offer to take a message so they can help.' end);
  end if;$a$);
    if position('zella_setup_enforcement_tools' in def) = 0 then raise exception 'zella_ai_tool has changed; review this patch'; end if;
    execute def;
  end if;

  -- D3: booking length, notice and horizon
  def := pg_get_functiondef('public.zella_ai_booking(text, uuid, text, jsonb)'::regprocedure);
  if position('zella_setup_enforcement_booking' in def) = 0 then
    def := replace(def, $a$v_err text; v_when text;$a$, $a$v_err text; v_when text; v_book_rules jsonb; v_notice integer; v_ahead integer;$a$);
    def := replace(def, $a$  v_dur := least(480, greatest(5, coalesce(nullif(v_args ->> 'duration_minutes', '')::integer, 30)));$a$,
      $a$  v_dur := least(480, greatest(5, coalesce(nullif(v_args ->> 'duration_minutes', '')::integer, 30)));
  /* zella_setup_enforcement_booking: the setup's booking rules */
  v_book_rules := public.zella_booking_rules(v_biz);
  v_notice := case when (v_book_rules ->> 'min_notice_hours') ~ '^\d{1,3}$' then (v_book_rules ->> 'min_notice_hours')::integer else 0 end;
  v_ahead := case when (v_book_rules ->> 'max_days_ahead') ~ '^\d{1,3}$' then greatest(1, (v_book_rules ->> 'max_days_ahead')::integer) end;
  if nullif(v_args ->> 'duration_minutes', '') is null and (v_book_rules ->> 'default_minutes') ~ '^\d{1,3}$' then
    v_dur := least(480, greatest(5, (v_book_rules ->> 'default_minutes')::integer));
  end if;$a$);
    def := replace(def, $a$    v_to := (v_day + v_days)::timestamp at time zone v_tz;$a$,
      $a$    v_to := (v_day + v_days)::timestamp at time zone v_tz;
    v_from := greatest(v_from, now() + make_interval(hours => v_notice));
    if v_ahead is not null then v_to := least(v_to, now() + make_interval(days => v_ahead)); end if;
    if v_to <= v_from then
      return jsonb_build_object('ok', true, 'status', 'slots', 'slots', '[]'::jsonb, 'say',
        'There are no openings in that period. This business books from ' || v_notice || ' hours ahead'
        || coalesce(' and up to ' || v_ahead || ' days ahead', '') || '. Offer other days in that range, or take a message.');
    end if;$a$);
    def := replace(def, $a$  if v_start is null or v_start <= now() or v_start > now() + interval '1 year' then$a$,
      $a$  if v_start is not null and (v_start < now() + make_interval(hours => v_notice) or (v_ahead is not null and v_start > now() + make_interval(days => v_ahead))) then
    return jsonb_build_object('ok', false, 'status', 'unavailable', 'say', 'That time is outside when this business takes bookings. Offer the times from check_availability.');
  end if;
  if v_start is null or v_start <= now() or v_start > now() + interval '1 year' then$a$);
    if position('v_book_rules jsonb; v_notice integer' in def) = 0 or position('zella_setup_enforcement_booking' in def) = 0
       or position('v_from := greatest(v_from, now() + make_interval(hours => v_notice))' in def) = 0
       or position('outside when this business takes bookings' in def) = 0 then
      raise exception 'zella_ai_booking has changed; review this patch';
    end if;
    execute def;
  end if;

  -- D3: rescheduling keeps to the same notice and horizon
  def := pg_get_functiondef('public.zella_ai_manage_booking(text, uuid, text, jsonb)'::regprocedure);
  if position('zella_setup_enforcement_booking' in def) = 0 then
    def := replace(def, $a$  if v_start is null or v_start <= now() or v_start > now() + interval '1 year' then$a$,
      $a$  /* zella_setup_enforcement_booking */
  if v_start is not null and (
       v_start < now() + make_interval(hours => case when (public.zella_booking_rules(v_biz) ->> 'min_notice_hours') ~ '^\d{1,3}$' then (public.zella_booking_rules(v_biz) ->> 'min_notice_hours')::integer else 0 end)
       or ((public.zella_booking_rules(v_biz) ->> 'max_days_ahead') ~ '^\d{1,3}$' and v_start > now() + make_interval(days => (public.zella_booking_rules(v_biz) ->> 'max_days_ahead')::integer))) then
    return jsonb_build_object('ok', false, 'status', 'unavailable', 'say', 'That time is outside when this business takes bookings. Offer the times from check_availability.');
  end if;
  if v_start is null or v_start <= now() or v_start > now() + interval '1 year' then$a$);
    if position('zella_setup_enforcement_booking' in def) = 0 then raise exception 'zella_ai_manage_booking has changed; review this patch'; end if;
    execute def;
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- D2: setup answers become searchable knowledge
create or replace function public.zella_setup_knowledge_sync(p_business_id uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare
  kb jsonb; v_keys text[] := '{}'; n integer := 0; r record;
  v_policy_titles jsonb := '{"cancellation":"Cancellation policy","refund":"Refund policy","payment":"Payment policy","emergency":"Emergency policy","appointment":"Appointment policy","other":"Other information"}';
begin
  select coalesce(c.knowledge_base, '{}'::jsonb) into kb
    from ai_agents a join ai_agent_configs c on c.agent_id = a.id where a.business_id = p_business_id and a.is_default limit 1;
  kb := coalesce(kb, '{}'::jsonb);

  for r in
    select 'setup:faq:' || md5(lower(trim(f ->> 'question'))) k, 'faq' kind, left(trim(f ->> 'question'), 200) title, trim(f ->> 'question') q, left(trim(f ->> 'answer'), 4000) a
      from jsonb_array_elements(case when jsonb_typeof(kb -> 'faqs') = 'array' then kb -> 'faqs' else '[]'::jsonb end) f
     where coalesce(trim(f ->> 'question'), '') <> '' and coalesce(trim(f ->> 'answer'), '') <> ''
    union all
    select 'setup:policy:' || p.key, 'policy', coalesce(v_policy_titles ->> p.key, initcap(p.key) || ' policy'), null, left(trim(p.value #>> '{}'), 4000)
      from jsonb_each(case when jsonb_typeof(kb -> 'policies') = 'object' then kb -> 'policies' else '{}'::jsonb end) p
     where coalesce(trim(p.value #>> '{}'), '') <> '' and p.key ~ '^[a-z_]{2,30}$'
    union all
    select 'setup:about', 'other', 'About the business', null, left(trim(kb ->> 'about'), 4000) where coalesce(trim(kb ->> 'about'), '') <> ''
    union all
    select 'setup:service_area', 'other', 'Service area', 'What area do you serve?', left(trim(kb ->> 'service_area'), 1000) where coalesce(trim(kb ->> 'service_area'), '') <> ''
    union all
    select 'setup:detail:' || md5(lower(trim(d ->> 'label'))), 'other', left(trim(d ->> 'label'), 200), null, left(trim(d ->> 'value'), 1000)
      from jsonb_array_elements(case when jsonb_typeof(kb -> 'business_details') = 'array' then kb -> 'business_details' else '[]'::jsonb end) d
     where coalesce(trim(d ->> 'label'), '') <> '' and coalesce(trim(d ->> 'value'), '') <> ''
  loop
    v_keys := v_keys || r.k;
    -- service writes skip the member guards; ready at once, like the website crawler's items
    update knowledge_items set kind = r.kind, title = r.title, question = r.q, answer = r.a, status = 'ready', ready_at = coalesce(ready_at, now()),
           version = version + 1, updated_at = now()
     where business_id = p_business_id and source_key = r.k and source_page_id is null
       and (kind, title, coalesce(question, ''), answer, status) is distinct from (r.kind, r.title, coalesce(r.q, ''), r.a, 'ready');
    if not found and not exists (select 1 from knowledge_items where business_id = p_business_id and source_key = r.k and source_page_id is null) then
      insert into knowledge_items (business_id, kind, title, question, answer, status, ready_at, source_key)
      values (p_business_id, r.kind, r.title, r.q, r.a, 'ready', now(), r.k);
    end if;
    n := n + 1;
  end loop;

  -- setup answers that were removed in setup are archived (never deleted; never items the owner added)
  update knowledge_items set status = 'archived', updated_at = now()
   where business_id = p_business_id and source_page_id is null and source_key like 'setup:%'
     and not (source_key = any (v_keys)) and status <> 'archived';
  return n;
end $$;
revoke execute on function public.zella_setup_knowledge_sync(uuid) from public, anon, authenticated;
grant execute on function public.zella_setup_knowledge_sync(uuid) to service_role;

create or replace function public.zella_setup_knowledge_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_biz uuid;
begin
  if tg_op = 'UPDATE' and new.knowledge_base is not distinct from old.knowledge_base then return null; end if;
  select a.business_id into v_biz from ai_agents a where a.id = new.agent_id and a.is_default;
  if v_biz is not null then perform public.zella_setup_knowledge_sync(v_biz); end if;
  return null;
end $$;
revoke execute on function public.zella_setup_knowledge_trg() from public, anon, authenticated;
drop trigger if exists zella_setup_knowledge_trg on public.ai_agent_configs;
create trigger zella_setup_knowledge_trg after insert or update of knowledge_base on public.ai_agent_configs
  for each row execute function public.zella_setup_knowledge_trg();

-- ---------------------------------------------------------------------------------------------------------------
-- D6: setup's language and greeting into the live language settings (same checks as zella_business_language_save)
create or replace function public.zella_setup_language_apply(p_business_id uuid, p_language text, p_greeting text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_primary text; v_extras text[] := '{}'; v_greeting text;
begin
  -- the wizard's choices: en-US, es-US, en-US+es-US (catalog codes: en-US, es)
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
  insert into business_languages (business_id, primary_language, extra_languages, greeting, updated_by, updated_at)
  values (p_business_id, v_primary, v_extras, v_greeting, null, now())
  on conflict (business_id) do update set primary_language = excluded.primary_language, extra_languages = excluded.extra_languages,
    greeting = excluded.greeting, updated_by = null, updated_at = now();
  return jsonb_build_object('ok', true, 'primary', v_primary, 'extras', to_jsonb(v_extras));
end $$;
revoke execute on function public.zella_setup_language_apply(uuid, text, text) from public, anon, authenticated;
grant execute on function public.zella_setup_language_apply(uuid, text, text) to service_role;

-- One-time catch-up for businesses set up before this file (run explicitly after review; changes live calls):
--   select public.zella_setup_knowledge_sync(b.id) from businesses b;
--   select public.zella_setup_language_apply(a.business_id, c.voice_config ->> 'language', c.voice_config ->> 'greeting')
--     from ai_agents a join ai_agent_configs c on c.agent_id = a.id
--    where a.is_default and c.voice_config ? 'language'
--      and not exists (select 1 from business_languages l where l.business_id = a.business_id);
