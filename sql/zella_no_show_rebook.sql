-- Zella - no-show rebooking link (2026-10-26). Safe to re-run. Built from the live function bodies (checked
-- 2026-10-26); only the lines marked "rebook" are new.
--
-- Before: a no-show follow-up text said "Reply to book a new time", and the reply became a callback for staff.
-- The customer's reschedule link refused missed appointments ("not available").
-- After:  the no-show follow-up text and email also carry a private "Book a new time" link. The customer picks a
--         free time; the same calendar rules check it (zella_reschedule_appointment, which already moves a no-show
--         back to scheduled); the appointment triggers rebuild the reminders, tell the staff and cancel the pending
--         no-show follow-up. The reply path to staff stays as it was.
--
--   1. appointment_reschedule_links: purpose ('reschedule' as before, or 'rebook') and expires_at (rebook: 14 days).
--   2. zella_rebook_line(appointment): makes a rebook link, like zella_reschedule_line does for upcoming bookings.
--      Returns '' when the app address (app_base_url) isn't set, so the message still goes, without a link.
--   3. zella_reschedule_lookup: a rebook link opens for a missed appointment (start in the past is fine) until it
--      expires; it is still refused if the appointment was since cancelled, completed or rebooked another way.
--   4. zella_claim_followup_texts / _emails: for no-show follow-ups, add {{reschedule_line}} to the task's values.
--      The link is made when the message is about to go, never stored in readable form (only its hash).
--   5. The two starter no-show templates gain {{reschedule_line}}. Business-specific copies are left alone.
-- Rollback: re-run the previous definitions (zella_reschedule.sql, zella_followup_emails.sql) and
--   alter table public.appointment_reschedule_links drop column purpose, drop column expires_at.

alter table public.appointment_reschedule_links add column if not exists purpose text not null default 'reschedule';
alter table public.appointment_reschedule_links add column if not exists expires_at timestamptz;

create or replace function public.zella_rebook_line(p_appointment_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_base text := regexp_replace(coalesce(nullif(trim(public.zella_setting('app_base_url', '""'::jsonb) #>> '{}'), ''), ''), '/+$', '');
  v_token text; a record;
begin
  if v_base = '' or v_base !~ '^https://[^\s]+$' then return ''; end if;
  select id, business_id, status into a from public.appointments where id = p_appointment_id;
  if a.id is null or a.status <> 'no_show' then return ''; end if;
  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into public.appointment_reschedule_links (appointment_id, business_id, token_hash, purpose, expires_at)
  values (a.id, a.business_id, encode(sha256(convert_to(v_token, 'utf8')), 'hex'), 'rebook', now() + interval '14 days');
  return ' Book a new time: ' || v_base || '/r/' || v_token;
end $$;
revoke all on function public.zella_rebook_line(uuid) from public, anon, authenticated;

create or replace function public.zella_reschedule_lookup(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l record; a record; b record; c record; v_dur integer; v_rebook boolean;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then return jsonb_build_object('ok', false, 'reason', 'invalid'); end if;
  select * into l from public.appointment_reschedule_links where token_hash = encode(sha256(convert_to(p_token, 'utf8')), 'hex');
  if l.id is null then return jsonb_build_object('ok', false, 'reason', 'invalid'); end if;
  select * into a from public.appointments where id = l.appointment_id;
  select id, name, coalesce(timezone, 'America/New_York') as tz, suspended_at, cancelled_at into b from public.businesses where id = l.business_id;
  if a.id is null or b.id is null or b.suspended_at is not null or b.cancelled_at is not null then
    return jsonb_build_object('ok', false, 'reason', 'invalid');
  end if;
  -- rebook: a link sent after a no-show opens only while the appointment is still a no-show and the link is fresh.
  v_rebook := coalesce(l.purpose, 'reschedule') = 'rebook';
  if v_rebook then
    if l.expires_at is not null and l.expires_at < now() then return jsonb_build_object('ok', false, 'reason', 'past', 'business', b.name); end if;
    if a.status <> 'no_show' then return jsonb_build_object('ok', false, 'reason', 'not_available', 'business', b.name); end if;
  else
    if a.status in ('cancelled', 'no_show', 'completed') then
      return jsonb_build_object('ok', false, 'reason', 'not_available', 'business', b.name);
    end if;
    if coalesce(a.booking_state, 'confirmed') <> 'confirmed' then
      return jsonb_build_object('ok', false, 'reason', 'not_available', 'business', b.name);
    end if;
    if a.start_time <= now() then
      return jsonb_build_object('ok', false, 'reason', 'past', 'business', b.name);
    end if;
  end if;
  select nullif(trim(coalesce(first_name, '')), '') as first_name into c from public.customers where id = a.customer_id;
  v_dur := greatest(5, (extract(epoch from (a.end_time - a.start_time)) / 60)::int);
  return jsonb_build_object('ok', true, 'business', b.name, 'timezone', b.tz, 'first_name', c.first_name, 'missed', v_rebook,
    'appointment', jsonb_build_object('title', a.title, 'start', a.start_time, 'end', a.end_time, 'minutes', v_dur));
end $$;

create or replace function public.zella_claim_followup_texts(p_limit integer default 10, p_kinds text[] default null)
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(e || jsonb_build_object('vars',
           coalesce((select f.vars from public.followup_tasks f where f.id = (e ->> 'task_id')::uuid), '{}'::jsonb)
           -- rebook: no-show follow-ups carry the link to pick a new time
           || case when e ->> 'kind' = 'no_show_follow_up' and e #>> '{appointment,id}' is not null
                   then jsonb_build_object('reschedule_line', public.zella_rebook_line((e #>> '{appointment,id}')::uuid)) else '{}'::jsonb end)), '[]'::jsonb)
    from jsonb_array_elements(public.zella_claim_followup_texts_base(p_limit, p_kinds)) e;
$$;

create or replace function public.zella_claim_followup_emails(p_limit integer default 10, p_kinds text[] default null)
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(e || jsonb_build_object('vars',
           coalesce((select f.vars from public.followup_tasks f where f.id = (e ->> 'task_id')::uuid), '{}'::jsonb)
           -- rebook: no-show follow-ups carry the link to pick a new time
           || case when e ->> 'kind' = 'no_show_follow_up' and e #>> '{appointment,id}' is not null
                   then jsonb_build_object('reschedule_line', public.zella_rebook_line((e #>> '{appointment,id}')::uuid)) else '{}'::jsonb end)), '[]'::jsonb)
    from jsonb_array_elements(public.zella_claim_followup_emails_base(p_limit, p_kinds)) e;
$$;
revoke all on function public.zella_claim_followup_texts(integer, text[]) from public, anon, authenticated;
revoke all on function public.zella_claim_followup_emails(integer, text[]) from public, anon, authenticated;

update public.message_templates
   set body = 'Hi {{first_name}}, we missed you at {{business}} today.{{reschedule_line}} Or reply to book a new time. Reply STOP to opt out.'
 where key = 'no_show_follow_up' and channel = 'sms' and business_id is null and industry_id is null and body not like '%{{reschedule_line}}%';
update public.message_templates
   set body = E'Hi {{first_name}},\n\nWe missed you at {{business}} today. We would be happy to find you a new time.{{reschedule_line}}\n\nOr contact {{business}} to rebook.'
 where key = 'no_show_follow_up' and channel = 'email' and business_id is null and industry_id is null and body not like '%{{reschedule_line}}%';

-- Check: select key, channel, body from message_templates where key = 'no_show_follow_up';
