-- Fewer, non-repeating customer texts around a booking and a visit (found by the end-to-end launch workflow, 5 Nov 2026).
--
-- A new salon client who booked by phone and came in was due, from the automations production's salon has switched on:
--   at booking:  the booking confirmation, a "welcome, we will be in touch" text 10 minutes after their record was made,
--                and a "you are booked for ..." follow-up an hour later repeating the confirmation;
--   after visit: a feedback request after 3 hours, "Thanks for visiting. How did it go?" and an aftercare
--                "Thank you for visiting ..." the next day, and a review request the day after.
-- After this:
--   1. "You are booked" follow-ups are not queued when the business sends booking confirmations (they say the same).
--   2. A pending welcome text is withdrawn as soon as a booking confirmation is scheduled for that person (the
--      confirmation is the better first message); the task is closed with the reason, not deleted.
--   3. After a visit, one check-in: a feedback request or "thanks for visiting" note is not queued when the person had
--      one in the last 36 hours. The review request (two days later) still goes.
-- Replies to the customer's own messages, confirmations, reminders, reschedules, cancellations and status updates on
-- their records are never held back. Every message held back is visible with its reason.
-- Changes what customers receive once texting is live: needs the owner's approval. Safe to run twice.

do $$
declare def text;
begin
  def := pg_get_functiondef('public.zella_queue_customer_message(uuid, uuid, text, jsonb, interval, uuid, interval)'::regprocedure);
  if position('zella_message_courtesy' in def) > 0 then return; end if;
  def := replace(def, $a$  insert into public.followup_tasks (business_id, customer_id, appointment_id, kind, channel, due_at, max_attempts, vars)$a$,
$a$  /* zella_message_courtesy: one booking message, one after-visit check-in */
  if p_kind = 'booking_follow_up' and exists (select 1 from public.automations x where x.business_id = p_business_id
       and x.trigger_type = 'appointment_confirmation' and x.status = 'active') then
    return null;
  end if;
  if p_kind = 'feedback_request' or (p_kind = 'record_status_update' and coalesce(p_vars ->> 'record_title', '') = 'your visit') then
    if exists (select 1 from public.followup_tasks f where f.customer_id = p_customer_id and f.created_at > now() - interval '36 hours'
                  and f.status in ('pending', 'in_progress', 'done')
                  and (f.kind = 'feedback_request' or (f.kind = 'record_status_update' and coalesce(f.vars ->> 'record_title', '') = 'your visit'))) then
      return null;
    end if;
  end if;
  insert into public.followup_tasks (business_id, customer_id, appointment_id, kind, channel, due_at, max_attempts, vars)$a$);
  if position('zella_message_courtesy' in def) = 0 then raise exception 'zella_queue_customer_message has changed; review this patch'; end if;
  execute def;
end $$;

-- the booking confirmation replaces a pending welcome text
create or replace function public.zella_welcome_superseded_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'confirmation' and new.customer_id is not null then
    update public.followup_tasks set status = 'skipped', outcome = 'superseded', outcome_notes = 'The booking confirmation was sent instead.', updated_at = now()
     where customer_id = new.customer_id and kind = 'welcome_new_customer' and status = 'pending';
  end if;
  return null;
end $$;
revoke execute on function public.zella_welcome_superseded_trg() from public, anon, authenticated;
drop trigger if exists zella_welcome_superseded on public.appointment_reminders;
create trigger zella_welcome_superseded after insert on public.appointment_reminders for each row execute function public.zella_welcome_superseded_trg();
