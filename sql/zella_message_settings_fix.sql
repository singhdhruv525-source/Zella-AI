-- Zella - automation settings reach the messages that are sent (5 Nov 2026). Safe to run twice. Not applied.
-- Audit: docs/MESSAGING_EXECUTION_AUDIT_2026-11-05.md. Class M (customer messaging); texting and email are off, so
-- nothing changes for a customer until sending is switched on.
--
-- M1  Quote follow-up: the setup wizard and Settings > Automations save "Follow up after" as hours_after (24/48/72)
--     and "Try up to" as max_attempts (1-3); zella_issue_quote read every_days and max_follow_ups, so every quote used
--     the defaults (3 follow-ups, every 3 days). Now it reads the saved names (older names still work).
-- M2  Post-visit and quote follow-ups offer "Send by: Text / Email"; the queue sent anything that wasn't "call" as a
--     text, so Email was never used. Now Email is used when the customer has a valid email address (otherwise text,
--     as before). The email sender already handles both kinds (n8n/src/email-task-plan.js).
-- M3  Reminders and booking confirmations offered "AI call" and "Text and AI call", stored as channel call /
--     sms_and_call. Nothing claims those (only sms and email reminders are sent), so such reminders stayed pending for
--     ever, and the failure counts never showed them. AI reminder calls aren't built, so the reminder goes by text, and
--     the screens no longer offer the call options (web/src/automationOptions.js). An automation saved with them is
--     switched to text with what was asked kept as channel_requested, and its pending reminders are moved to text.
--     Production on 5 Nov: every reminder and automation uses text, so this changes no existing row there.

do $$
declare def text;
begin
  -- M1
  def := pg_get_functiondef('public.zella_issue_quote(uuid, text, integer)'::regprocedure);
  if position('zella_message_settings_fix' in def) = 0 then
    def := replace(def, $a$coalesce((v_auto.trigger_config ->> 'max_follow_ups')::integer, 3)$a$,
      $a$coalesce(case when (v_auto.trigger_config ->> 'max_attempts') ~ '^\d{1,2}$' then (v_auto.trigger_config ->> 'max_attempts')::integer end, (v_auto.trigger_config ->> 'max_follow_ups')::integer, 3) /* zella_message_settings_fix */$a$);
    def := replace(def, $a$coalesce((v_auto.trigger_config ->> 'every_days')::integer, 3)$a$,
      $a$coalesce(case when (v_auto.trigger_config ->> 'hours_after') ~ '^\d{1,4}$' then greatest(1, ceil((v_auto.trigger_config ->> 'hours_after')::numeric / 24)::integer) end, (v_auto.trigger_config ->> 'every_days')::integer, 3)$a$);
    if position('zella_message_settings_fix' in def) = 0 or position($a$(v_auto.trigger_config ->> 'hours_after')::numeric / 24$a$ in def) = 0 then
      raise exception 'zella_issue_quote has changed; review this patch';
    end if;
    execute def;
  end if;

  -- M2: quote follow-ups
  def := pg_get_functiondef('public.zella_queue_quote_followups()'::regprocedure);
  if position('zella_message_settings_fix' in def) = 0 then
    def := replace(def, $a$case when v_auto.trigger_config ->> 'channel' = 'call' then 'call' else 'sms' end$a$,
      $a$case v_auto.trigger_config ->> 'channel' when 'call' then 'call' when 'email' then (case when public.zella_valid_email(c.email) then 'email' else 'sms' end) else 'sms' end /* zella_message_settings_fix */$a$);
    if position('zella_message_settings_fix' in def) = 0 then raise exception 'zella_queue_quote_followups has changed; review this patch'; end if;
    execute def;
  end if;

  -- M2: post-visit follow-ups
  def := pg_get_functiondef('public.zella_appointment_after()'::regprocedure);
  if position('zella_message_settings_fix' in def) = 0 then
    def := replace(def, $a$case when v_auto.trigger_config ->> 'channel' = 'call' then 'call' else 'sms' end$a$,
      $a$case v_auto.trigger_config ->> 'channel' when 'call' then 'call' when 'email' then (case when public.zella_valid_email((select x.email from public.customers x where x.id = new.customer_id)) then 'email' else 'sms' end) else 'sms' end /* zella_message_settings_fix */$a$);
    if position('zella_message_settings_fix' in def) = 0 then raise exception 'zella_appointment_after has changed; review this patch'; end if;
    execute def;
  end if;

  -- M3: reminders and confirmations go by text when a call was asked for
  def := pg_get_functiondef('public.zella_replace_reminders(uuid, boolean, text)'::regprocedure);
  if position('zella_message_settings_fix' in def) = 0 then
    def := replace(def, $a$coalesce(v_rem.trigger_config ->> 'channel', 'sms')$a$,
      $a$(case when coalesce(v_rem.trigger_config ->> 'channel', 'sms') = 'email' then 'email' else 'sms' end) /* zella_message_settings_fix */$a$);
    def := replace(def, $a$coalesce(v_conf.trigger_config ->> 'channel', 'sms')$a$,
      $a$(case when coalesce(v_conf.trigger_config ->> 'channel', 'sms') = 'email' then 'email' else 'sms' end)$a$);
    if position('zella_message_settings_fix' in def) = 0 or position($a$v_conf.trigger_config ->> 'channel', 'sms') = 'email'$a$ in def) = 0 then
      raise exception 'zella_replace_reminders has changed; review this patch';
    end if;
    execute def;
  end if;
end $$;

-- M3: saved settings and waiting reminders that asked for a call
update public.automations
   set trigger_config = trigger_config || jsonb_build_object('channel', 'sms', 'channel_requested', trigger_config ->> 'channel'), updated_at = now()
 where trigger_type in ('appointment_reminder', 'appointment_confirmation') and trigger_config ->> 'channel' in ('call', 'sms_and_call');
update public.appointment_reminders set channel = 'sms' where status = 'pending' and channel not in ('sms', 'email');

-- M4  Switching reminders off, or changing when they go, didn't touch reminders already queued for future
--     appointments: they still went at the old times (the sender re-checked the appointment, not the automation).
--     Now a change to the reminder automation re-plans the waiting reminders of that business's future appointments
--     (only reminder rows: a waiting booking confirmation is kept), switching confirmations off withdraws waiting
--     confirmations, and the sender skips a reminder whose automation is no longer on (a safety net).
create or replace function public.zella_resync_reminders(p_business_id uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare a record; v_rem record; v_hours numeric[]; h numeric; n integer := 0;
begin
  select x.* into v_rem from automations x where x.business_id = p_business_id and x.trigger_type = 'appointment_reminder' and x.status = 'active' limit 1;
  for a in select * from appointments where business_id = p_business_id and start_time > now() and status in ('scheduled', 'confirmed')
             and coalesce(booking_state, 'confirmed') = 'confirmed' loop
    update appointment_reminders set status = 'cancelled', error = 'settings_changed'
     where appointment_id = a.id and kind = 'reminder' and status = 'pending';
    if v_rem.id is not null then
      v_hours := case when jsonb_typeof(v_rem.trigger_config -> 'hours_before') = 'array'
                      then array(select jsonb_array_elements_text(v_rem.trigger_config -> 'hours_before')::numeric) else array[24]::numeric[] end;
      foreach h in array v_hours loop
        if a.start_time - make_interval(secs => h * 3600) > now() then
          insert into appointment_reminders (business_id, appointment_id, customer_id, kind, hours_before, reason, due_at, channel)
          values (a.business_id, a.id, a.customer_id, 'reminder', h, 'settings_changed', a.start_time - make_interval(secs => h * 3600),
                  case when v_rem.trigger_config ->> 'channel' = 'email' then 'email' else 'sms' end)
          on conflict do nothing;
        end if;
      end loop;
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.zella_resync_reminders(uuid) from public, anon, authenticated;
grant execute on function public.zella_resync_reminders(uuid) to service_role;

create or replace function public.zella_reminder_settings_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and (new.status, new.trigger_config) is not distinct from (old.status, old.trigger_config) then return null; end if;
  if new.trigger_type = 'appointment_reminder' then
    perform public.zella_resync_reminders(new.business_id);
  elsif new.trigger_type = 'appointment_confirmation' and new.status <> 'active' then
    update appointment_reminders set status = 'cancelled', error = 'settings_changed'
     where business_id = new.business_id and kind in ('confirmation', 'confirmation_request') and status = 'pending';
  end if;
  return null;
end $$;
revoke execute on function public.zella_reminder_settings_trg() from public, anon, authenticated;
drop trigger if exists zella_reminder_settings_trg on public.automations;
create trigger zella_reminder_settings_trg after insert or update of status, trigger_config on public.automations
  for each row when (new.trigger_type in ('appointment_reminder', 'appointment_confirmation'))
  execute function public.zella_reminder_settings_trg();

do $$
declare def text;
begin
  def := pg_get_functiondef('public.zella_claim_reminders(integer, text)'::regprocedure);
  if position('zella_message_settings_fix' in def) = 0 then
    def := replace(def, $a$      update public.appointment_reminders set status = 'skipped', error = 'appointment_no_longer_active' where id = r.id; continue;
    end if;$a$, $a$      update public.appointment_reminders set status = 'skipped', error = 'appointment_no_longer_active' where id = r.id; continue;
    end if;
    /* zella_message_settings_fix: the automation that queued it must still be on */
    if not exists (select 1 from public.automations x where x.business_id = r.business_id and x.status = 'active'
                     and x.trigger_type = case when r.kind = 'reminder' then 'appointment_reminder' else 'appointment_confirmation' end) then
      update public.appointment_reminders set status = 'skipped', error = 'automation_off' where id = r.id; continue;
    end if;$a$);
    if position('zella_message_settings_fix' in def) = 0 then raise exception 'zella_claim_reminders has changed; review this patch'; end if;
    execute def;
  end if;
end $$;
