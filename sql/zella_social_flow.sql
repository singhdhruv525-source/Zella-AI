-- Zella - social DM flow (checklist 121-123). Safe to run more than once. Needs zella_meta.sql.
-- A simple, rules-based chat for Messenger / Instagram / WhatsApp, off until the owner turns it on per page:
--   1. get a phone or email (the lead is created), 2. ask what they need (qualifies the lead),
--   3. offer up to 3 real open times, 4. a reply of 1, 2 or 3 books it. Anything else goes to a person.
-- It stops the moment a person has answered the conversation, or the customer asks for a human or complains.
-- Assignment (122) is the existing round-robin in zella_meta_process_event.

alter table public.meta_connections add column if not exists qualify_flow boolean not null default false;

create table if not exists public.social_flows (
  conversation_id uuid primary key references public.conversations(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  step text not null default 'ask_contact' check (step in ('ask_contact','ask_need','offer_slots','done','handoff')),
  answers jsonb not null default '{}'::jsonb,
  offered jsonb not null default '[]'::jsonb,
  tries integer not null default 0,
  updated_at timestamptz not null default now()
);
alter table public.social_flows enable row level security;
revoke all on public.social_flows from anon, authenticated;
drop policy if exists social_flows_read on public.social_flows;
create policy social_flows_read on public.social_flows for select to authenticated using (public.zella_is_member(business_id));
grant select on public.social_flows to authenticated;

-- Owners switch the flow on or off for a connected page.
create or replace function public.zella_meta_set_flow(p_business_id uuid, p_page_id text, p_enabled boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.zella_has_role(p_business_id, array['owner','admin','manager']) then raise exception 'NOT_ALLOWED'; end if;
  update public.meta_connections set qualify_flow = coalesce(p_enabled, false) where business_id = p_business_id and page_id = p_page_id;
end $$;
revoke execute on function public.zella_meta_set_flow(uuid, text, boolean) from public, anon;
grant execute on function public.zella_meta_set_flow(uuid, text, boolean) to authenticated, service_role;

-- One step of the chat. Returns the reply to send, or null when the flow has nothing to say.
create or replace function public.zella_social_flow(p_conversation_id uuid, p_text text, p_intent text)
returns text language plpgsql security definer set search_path = public as $$
declare
  cv public.conversations%rowtype; f public.social_flows%rowtype; v_tz text; v_biz text;
  v_email text; v_phone text; v_cust uuid; v_name text; v_pick int; v_slot timestamptz; v_n int := 0;
  v_offer jsonb := '[]'::jsonb; v_lines text := ''; s record; v_appt uuid; v_need text;
begin
  select * into cv from public.conversations where id = p_conversation_id;
  if not found then return null; end if;
  select coalesce(b.timezone, 'America/New_York'), b.name into v_tz, v_biz from public.businesses b where b.id = cv.business_id and b.suspended_at is null and b.cancelled_at is null;
  if v_biz is null then return null; end if;
  select * into f from public.social_flows where conversation_id = p_conversation_id;

  -- a person has answered, or the customer wants a person: the flow steps aside
  if exists (select 1 from public.conversation_messages m where m.conversation_id = p_conversation_id and m.sender_type = 'agent') then
    update public.social_flows set step = 'handoff', updated_at = now() where conversation_id = p_conversation_id and step not in ('done','handoff');
    return null;
  end if;
  -- "call me on 415..." while we are asking for a number is an answer, not a request for a person
  if p_intent in ('human', 'complaint') and not (f.step = 'ask_contact' and p_intent = 'human'
       and (public.zella_digits(substring(p_text from '(\+?[0-9][0-9 ().-]{7,18}[0-9])')) is not null or p_text ~* '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')) then
    if f.conversation_id is null then
      insert into public.social_flows (conversation_id, business_id, step) values (p_conversation_id, cv.business_id, 'handoff');
    else update public.social_flows set step = 'handoff', updated_at = now() where conversation_id = p_conversation_id and step not in ('done','handoff'); end if;
    return null;
  end if;

  if f.conversation_id is null then
    if p_intent not in ('booking', 'price') then return null; end if;
    insert into public.social_flows (conversation_id, business_id, step) values (p_conversation_id, cv.business_id, case when cv.customer_id is null then 'ask_contact' else 'ask_need' end)
    returning * into f;
    return case when f.step = 'ask_contact' then 'Happy to help! What is the best phone number or email to reach you?' else 'Happy to help! What service are you looking for?' end;
  end if;
  if f.step in ('done', 'handoff') then return null; end if;

  if f.step = 'ask_contact' then
    v_email := lower(substring(p_text from '([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})'));
    v_phone := substring(p_text from '(\+?[0-9][0-9 ().-]{7,18}[0-9])');
    if public.zella_digits(v_phone) is null and v_email is null then
      if f.tries >= 1 then
        update public.social_flows set step = 'handoff', updated_at = now() where conversation_id = p_conversation_id;
        perform public.zella_notify_owners(cv.business_id, 'social_handoff', 'A chat needs a person', 'The customer did not share contact details. Please reply in the inbox.', 'info', 'inbox');
        return 'No problem, a team member will pick this up here shortly.';
      end if;
      update public.social_flows set tries = tries + 1, updated_at = now() where conversation_id = p_conversation_id;
      return 'Sorry, I did not catch that. Please send a phone number (or an email) so we can confirm your booking.';
    end if;
    select m.customer_id into v_cust from public.zella_match_customer(cv.business_id, v_phone, v_email) m where m.certainty = 'exact' limit 1;
    if v_cust is null then
      select coalesce(display_name, 'Social contact') into v_name from public.meta_contacts where conversation_id = p_conversation_id limit 1;
      insert into public.customers (business_id, first_name, last_name, phone, email, status, source, lead_stage, priority, qualification)
      values (cv.business_id, coalesce(nullif(split_part(v_name, ' ', 1), ''), 'Social contact'),
              nullif(trim(substr(v_name, length(split_part(v_name, ' ', 1)) + 1)), ''),
              case when public.zella_digits(v_phone) is not null then v_phone end, v_email, 'active', cv.channel, 'new', 'normal', '{}'::jsonb)
      returning id into v_cust;
    end if;
    update public.conversations set customer_id = v_cust where id = p_conversation_id;
    update public.meta_contacts set customer_id = coalesce(customer_id, v_cust) where conversation_id = p_conversation_id;
    update public.social_flows set step = 'ask_need', updated_at = now() where conversation_id = p_conversation_id;
    return 'Thanks! What service are you looking for?';
  end if;

  if f.step = 'ask_need' then
    v_need := left(trim(regexp_replace(p_text, '[[:cntrl:]]', ' ', 'g')), 200);
    if length(v_need) < 2 then return 'What service are you looking for?'; end if;
    update public.customers set lead_stage = case when lead_stage = 'new' then 'qualified' else lead_stage end,
           qualification = coalesce(qualification, '{}'::jsonb) || jsonb_build_object('need', v_need, 'via', 'social_flow', 'qualified_at', now())
     where id = cv.customer_id and business_id = cv.business_id;
    for s in select * from public.zella_available_slots(cv.business_id, now() + interval '2 hours', now() + interval '7 days', 30, null, 30, 40) loop
      exit when v_n >= 3;
      -- spread the choices at least 3 hours apart
      if v_n = 0 or s.slot_start - (v_offer ->> (v_n - 1))::timestamptz >= interval '3 hours' then
        v_n := v_n + 1; v_offer := v_offer || to_jsonb(s.slot_start);
        v_lines := v_lines || v_n || ') ' || to_char(s.slot_start at time zone v_tz, 'Dy Mon FMDD, FMHH12:MI AM') || E'\n';
      end if;
    end loop;
    if v_n = 0 then
      update public.social_flows set step = 'handoff', answers = jsonb_build_object('need', v_need), updated_at = now() where conversation_id = p_conversation_id;
      perform public.zella_notify_owners(cv.business_id, 'social_handoff', 'A social lead needs a time', 'No open times were found. Need: ' || v_need, 'info', 'inbox');
      return 'Thanks! A team member will reply here shortly with available times.';
    end if;
    update public.social_flows set step = 'offer_slots', offered = v_offer, answers = jsonb_build_object('need', v_need), updated_at = now() where conversation_id = p_conversation_id;
    return 'We have these times open:' || E'\n' || v_lines || 'Reply 1, 2 or 3 to book, or tell us another time and the team will follow up.';
  end if;

  if f.step = 'offer_slots' then
    v_pick := case when trim(p_text) ~ '^[123]\M' then substring(trim(p_text) from '^([123])')::int end;
    if v_pick is null or v_pick > jsonb_array_length(f.offered) then
      update public.social_flows set step = 'handoff', updated_at = now() where conversation_id = p_conversation_id;
      perform public.zella_notify_owners(cv.business_id, 'social_handoff', 'A social lead asked for another time', left(p_text, 200), 'info', 'inbox');
      return 'Thanks! A team member will reply here shortly to find a time that works.';
    end if;
    v_slot := (f.offered ->> (v_pick - 1))::timestamptz;
    begin
      v_appt := public.zella_book_appointment(cv.business_id, cv.customer_id, coalesce(nullif(f.answers ->> 'need', ''), 'Appointment'), v_slot, 30, null, null, 'Booked from a social chat');
    exception when others then
      update public.social_flows set step = 'handoff', updated_at = now() where conversation_id = p_conversation_id;
      perform public.zella_notify_owners(cv.business_id, 'social_handoff', 'A time was taken before it could be booked', 'Please reply to the chat with other times.', 'info', 'inbox');
      return 'Sorry, that time was just taken. A team member will reply here shortly with other options.';
    end;
    update public.social_flows set step = 'done', updated_at = now() where conversation_id = p_conversation_id;
    perform public.zella_notify_owners(cv.business_id, 'social_booking', 'Booked from a social chat', to_char(v_slot at time zone v_tz, 'Dy Mon FMDD, FMHH12:MI AM'), 'info', 'calendar');
    return 'You are booked for ' || to_char(v_slot at time zone v_tz, 'Dy Mon FMDD at FMHH12:MI AM') || ' with ' || v_biz || '. See you then!';
  end if;
  return null;
end $$;
revoke execute on function public.zella_social_flow(uuid, text, text) from public, anon, authenticated;
grant execute on function public.zella_social_flow(uuid, text, text) to service_role;
