-- Customer messages around a booking and a visit, by industry (5 Nov 2026). Replaces the first version of this file,
-- which applied salon rules to every business. The policy, its defaults for each of the 28 industries, and what each
-- message is timed from are in docs/MESSAGING_POLICY_2026-11-05.md; that document is what the owner approves.
--
--   * industry_message_policy: the default for each industry. A business can change its own (owners and admins,
--     zella_set_message_policy; stored in businesses.setup_data.message_policy, audited).
--   * Settings, each with the values allowed:
--       welcome           until_booked | on | off   the "welcome, we'll be in touch" text 10 minutes after a new
--                                                    customer record; until_booked withdraws it when a booking
--                                                    confirmation is scheduled first
--       booking_follow_up skip_if_confirmations | on | off   the "you are booked for ..." text an hour after a booking
--                                                    made more than 2 days ahead
--       feedback_request  on | off                  "How did it go?" 3 hours after a visit is marked completed
--       review_request    on | off                  an automation message that asks for a review ({review_link})
--       after_visit       one | all                 one: at most one after-visit check-in per customer in
--       check_in_hours    12..168                    check_in_hours (feedback request, post-visit follow-up, job
--                                                    completed note, "thanks for visiting"); review requests are
--                                                    not check-ins and are governed only by review_request
--   * A message held back is not deleted or silently dropped: it is stored as skipped with the reason, so the team
--     can see it in the message history.
--   * Cancelled or no-show bookings withdraw their own pending booking follow-up and after-visit messages (the
--     cancellation confirmation and no-show follow-up are untouched); a moved booking withdraws its stale "you are
--     booked for <old time>" follow-up (the reschedule confirmation carries the new time).
-- Never held back by this: replies to the customer, confirmations, reminders, reschedule and cancellation
-- confirmations, status updates on their records. Consent, opt-out (do not contact / text / email), channel choice
-- and quiet hours are unchanged and still apply to everything.
-- Changes what customers receive once texting is live: needs the owner's approval. Safe to run twice.

create table if not exists public.industry_message_policy (
  industry_key text primary key,
  policy jsonb not null,
  reason text,
  updated_at timestamptz not null default now()
);
alter table public.industry_message_policy enable row level security;
drop policy if exists industry_message_policy_read on public.industry_message_policy;
create policy industry_message_policy_read on public.industry_message_policy for select to authenticated using (true);
revoke all on public.industry_message_policy from anon, authenticated;
grant select on public.industry_message_policy to authenticated;
grant select, insert, update, delete on public.industry_message_policy to service_role;

-- defaults by industry (proposed; see the policy document). Only rows not changed since are refreshed.
insert into public.industry_message_policy (industry_key, policy, reason) values
 ('other',                '{}', 'Standard'),
 ('beauty_salon',         '{}', 'Standard: one aftercare check-in, then a review request'),
 ('spa_wellness',         '{}', 'Standard'),
 ('fitness',              '{}', 'Standard'),
 ('pet_care',             '{}', 'Standard'),
 ('photography_events',   '{}', 'Standard'),
 ('hospitality',          '{}', 'Standard'),
 ('travel',               '{}', 'Standard'),
 ('education',            '{}', 'Standard'),
 ('professional_services','{}', 'Standard'),
 ('real_estate',          '{}', 'Standard'),
 ('cleaning',             '{}', 'Standard: the job-completed note counts as the after-visit check-in'),
 ('hvac',                 '{}', 'Standard: the job-completed note counts as the after-visit check-in'),
 ('plumbing',             '{}', 'Standard: the job-completed note counts as the after-visit check-in'),
 ('electrical',           '{}', 'Standard: the job-completed note counts as the after-visit check-in'),
 ('landscaping',          '{}', 'Standard: the job-completed note counts as the after-visit check-in'),
 ('pest_control',         '{}', 'Standard: the job-completed note counts as the after-visit check-in'),
 ('home_services',        '{}', 'Standard: the job-completed note counts as the after-visit check-in'),
 ('automotive',           '{}', 'Standard: the job-completed note counts as the after-visit check-in'),
 ('restaurant',           '{"welcome":"off"}', 'Guests booking a table do not expect a "we will be in touch" text'),
 ('ecommerce',            '{"welcome":"off"}', 'Shoppers are not booked; a welcome text from a phone call is unexpected'),
 ('property_management',  '{"review_request":"off"}', 'Tenants and owners are in a contract; review requests after repairs need the manager''s choice'),
 ('childcare',            '{"review_request":"off"}', 'Messages go to parents about their children; review requests are the owner''s choice'),
 ('healthcare',           '{"welcome":"off","feedback_request":"off","review_request":"off"}', 'A text can reveal that someone is a patient; nothing after a visit unless the practice turns it on'),
 ('dental',               '{"welcome":"off","feedback_request":"off","review_request":"off"}', 'A text can reveal that someone is a patient; nothing after a visit unless the practice turns it on'),
 ('legal',                '{"welcome":"off","feedback_request":"off","review_request":"off"}', 'A text can reveal that someone is a client; nothing after a consultation unless the firm turns it on'),
 ('financial_services',   '{"welcome":"off","feedback_request":"off","review_request":"off"}', 'A text can reveal a client relationship; review requests can be restricted for advisers'),
 ('insurance',            '{"welcome":"off","feedback_request":"off","review_request":"off"}', 'A text can reveal a policy or claim; nothing after a meeting unless the agency turns it on')
on conflict (industry_key) do nothing; -- a default changed later by the platform team is kept

-- the business's policy: standard, then its industry's defaults, then the owner's own choices (internal; no access check)
create or replace function public.zella_message_policy_for(p_business_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select '{"welcome":"until_booked","booking_follow_up":"skip_if_confirmations","feedback_request":"on","review_request":"on","after_visit":"one","check_in_hours":36}'::jsonb
         || coalesce((select policy from public.industry_message_policy where industry_key = public.zella_industry_key_for(p_business_id)), '{}'::jsonb)
         || coalesce((select setup_data -> 'message_policy' from public.businesses where id = p_business_id and jsonb_typeof(setup_data -> 'message_policy') = 'object'), '{}'::jsonb) $$;
-- the same for the app: members of the business only
create or replace function public.zella_message_policy(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  return public.zella_message_policy_for(p_business_id);
end $$;

-- owners and admins change their own business's policy; every change is audited
create or replace function public.zella_set_message_policy(p_business_id uuid, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare k text; v jsonb; v_clean jsonb := '{}'::jsonb; v_old jsonb;
begin
  if not exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active' and m.role in ('owner', 'admin')) then
    raise exception 'NOT_ALLOWED';
  end if;
  if jsonb_typeof(p_patch) <> 'object' then raise exception 'BAD_POLICY'; end if;
  for k, v in select * from jsonb_each(p_patch) loop
    if not ((k = 'welcome' and v #>> '{}' in ('until_booked', 'on', 'off'))
         or (k = 'booking_follow_up' and v #>> '{}' in ('skip_if_confirmations', 'on', 'off'))
         or (k in ('feedback_request', 'review_request') and v #>> '{}' in ('on', 'off'))
         or (k = 'after_visit' and v #>> '{}' in ('one', 'all'))
         or (k = 'check_in_hours' and jsonb_typeof(v) = 'number' and (v #>> '{}')::numeric between 12 and 168)) then
      raise exception 'BAD_POLICY: %', k;
    end if;
    v_clean := v_clean || jsonb_build_object(k, v);
  end loop;
  select coalesce(setup_data -> 'message_policy', '{}'::jsonb) into v_old from public.businesses where id = p_business_id;
  update public.businesses set setup_data = jsonb_set(coalesce(setup_data, '{}'::jsonb), '{message_policy}', coalesce(v_old, '{}'::jsonb) || v_clean), updated_at = now()
   where id = p_business_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, auth.uid(), 'message_policy_changed', 'business', p_business_id, v_old, coalesce(v_old, '{}'::jsonb) || v_clean);
  return public.zella_message_policy(p_business_id);
end $$;

-- applied to every customer message as it is queued, whichever path queues it
create or replace function public.zella_message_policy_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare p jsonb; v_reason text; v_checkin boolean;
begin
  if new.status <> 'pending' or new.customer_id is null then return new; end if;
  if new.kind not in ('welcome_new_customer', 'booking_follow_up', 'feedback_request', 'post_appointment_follow_up', 'service_completed', 'record_status_update') then return new; end if;
  p := public.zella_message_policy_for(new.business_id);
  v_checkin := new.kind in ('feedback_request', 'post_appointment_follow_up', 'service_completed')
            or (new.kind = 'record_status_update' and coalesce(new.vars ->> 'record_title', '') = 'your visit' and not coalesce((new.vars ->> 'review')::boolean, false));
  if new.kind = 'welcome_new_customer' and p ->> 'welcome' = 'off' then
    v_reason := 'Welcome texts are off for this business.';
  elsif new.kind = 'booking_follow_up' and p ->> 'booking_follow_up' = 'off' then
    v_reason := 'Booking follow-ups are off for this business.';
  elsif new.kind = 'booking_follow_up' and p ->> 'booking_follow_up' = 'skip_if_confirmations'
        and exists (select 1 from public.automations x where x.business_id = new.business_id and x.trigger_type = 'appointment_confirmation' and x.status = 'active') then
    v_reason := 'The booking confirmation already says this.';
  elsif new.kind = 'feedback_request' and p ->> 'feedback_request' = 'off' then
    v_reason := 'Feedback requests are off for this business.';
  elsif new.kind = 'record_status_update' and coalesce((new.vars ->> 'review')::boolean, false) and p ->> 'review_request' = 'off' then
    v_reason := 'Review requests are off for this business.';
  elsif v_checkin and p ->> 'after_visit' = 'one' and exists (
          select 1 from public.followup_tasks f
           where f.customer_id = new.customer_id and f.business_id = new.business_id and f.status in ('pending', 'in_progress', 'done')
             and f.created_at > now() - make_interval(hours => greatest(12, least(168, coalesce((p ->> 'check_in_hours')::int, 36))))
             and (f.kind in ('feedback_request', 'post_appointment_follow_up', 'service_completed')
                  or (f.kind = 'record_status_update' and coalesce(f.vars ->> 'record_title', '') = 'your visit' and not coalesce((f.vars ->> 'review')::boolean, false)))) then
    v_reason := 'They already had an after-visit check-in.';
  end if;
  if v_reason is not null then
    new.status := 'skipped'; new.outcome := 'policy'; new.outcome_notes := v_reason; new.completed_at := now();
  end if;
  return new;
end $$;
revoke execute on function public.zella_message_policy_trg() from public, anon, authenticated;
drop trigger if exists zella_message_policy on public.followup_tasks;
create trigger zella_message_policy before insert on public.followup_tasks for each row execute function public.zella_message_policy_trg();

-- automation messages that ask for a review are marked as such (so review_request can govern them)
do $$
declare def text;
begin
  def := pg_get_functiondef('public.zella_industry_act(uuid, jsonb, uuid, uuid, text, text, uuid)'::regprocedure);
  if position('''review'', (p_rule ->> ''message'') like' in def) > 0 then return; end if;
  def := replace(def, $a$jsonb_build_object('status_line', v_line, 'status', p_status, 'record_title', p_title),$a$,
                      $a$jsonb_build_object('status_line', v_line, 'status', p_status, 'record_title', p_title, 'review', (p_rule ->> 'message') like '%{review_link}%'),$a$);
  if position('''review'', (p_rule ->> ''message'') like' in def) = 0 then raise exception 'zella_industry_act has changed; review this patch'; end if;
  execute def;
end $$;

-- the booking confirmation replaces a pending welcome text (where the policy says until_booked)
create or replace function public.zella_welcome_superseded_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'confirmation' and new.customer_id is not null and public.zella_message_policy_for(new.business_id) ->> 'welcome' = 'until_booked' then
    update public.followup_tasks set status = 'skipped', outcome = 'superseded', outcome_notes = 'The booking confirmation was sent instead.', completed_at = now(), updated_at = now()
     where customer_id = new.customer_id and kind = 'welcome_new_customer' and status = 'pending';
  end if;
  return null;
end $$;
revoke execute on function public.zella_welcome_superseded_trg() from public, anon, authenticated;
drop trigger if exists zella_welcome_superseded on public.appointment_reminders;
create trigger zella_welcome_superseded after insert on public.appointment_reminders for each row execute function public.zella_welcome_superseded_trg();

-- a cancelled, no-show or moved booking withdraws its own messages that no longer fit
create or replace function public.zella_booking_messages_withdrawn_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status and new.status in ('cancelled', 'no_show') then
    update public.followup_tasks set status = 'cancelled', outcome = 'appointment_' || new.status,
           outcome_notes = 'The booking was ' || case new.status when 'cancelled' then 'cancelled' else 'missed' end || '.', completed_at = now(), updated_at = now()
     where appointment_id = new.id and status = 'pending' and kind in ('booking_follow_up', 'feedback_request', 'post_appointment_follow_up', 'reschedule_confirmation');
  elsif new.start_time is distinct from old.start_time then
    update public.followup_tasks set status = 'cancelled', outcome = 'appointment_moved', outcome_notes = 'The booking was moved; the reschedule confirmation has the new time.',
           completed_at = now(), updated_at = now()
     where appointment_id = new.id and status = 'pending' and kind = 'booking_follow_up';
  end if;
  return null;
end $$;
revoke execute on function public.zella_booking_messages_withdrawn_trg() from public, anon, authenticated;
drop trigger if exists zella_booking_messages_withdrawn on public.appointments;
create trigger zella_booking_messages_withdrawn after update of status, start_time on public.appointments
  for each row execute function public.zella_booking_messages_withdrawn_trg();

revoke execute on function public.zella_message_policy_for(uuid) from public, anon, authenticated;
grant execute on function public.zella_message_policy_for(uuid) to service_role;
revoke execute on function public.zella_message_policy(uuid), public.zella_set_message_policy(uuid, jsonb) from public, anon;
grant execute on function public.zella_message_policy(uuid), public.zella_set_message_policy(uuid, jsonb) to authenticated, service_role;
