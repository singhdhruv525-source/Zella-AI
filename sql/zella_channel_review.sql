-- Zella - messages the owner asked to send by AI call: held for the owner's choice, never switched to text silently
-- (5 Nov 2026). Safe to run twice. Not applied. Replaces the M3 part of sql/zella_message_settings_fix.sql (applied to
-- production on 5 Nov), which queued such reminders as texts. Report: docs/CHANNEL_REVIEW_2026-11-05.md. Class M.
--
-- C1  AI reminder calls, AI confirmation calls and AI waitlist calls aren't built. The screens offered them (reminders:
--     "AI call", "Text and AI call"; confirmations and waitlist offers: "AI call"). M3 sent those as texts instead,
--     which a customer who only agreed to calls may not have agreed to, and which the owner never chose.
--     Now:
--       * the choices are refused when saved (zella_clean_automation_config), and the screens no longer offer them;
--       * an automation already saved with them gets an open review (automation_channel_reviews): nothing is sent for
--         it - no reminder, confirmation or waitlist offer is queued, and anything already waiting is held with the
--         reason "channel_needs_review" - and its owners and admins are notified;
--       * the owner (or an admin) resolves it: text, email (reminders and confirmations) or off. Text or email needs
--         them to confirm their customers agreed to be contacted that way; the choice, who made it and that
--         confirmation are written to the audit log. Each customer's own opt-outs and channel still apply when sending.
--       * M3's switch is undone: an automation it switched to text (it kept the original in channel_requested) goes
--         back to what the owner saved, with an open review.
-- Production on 5 Nov (read only): every reminder and confirmation automation uses text and there is no waitlist
-- automation, so no review is opened there today. That is current configuration, not proof that none was ever saved.

create table if not exists public.automation_channel_reviews (
  automation_id uuid primary key references public.automations(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  trigger_type text not null,
  requested_channel text not null,
  status text not null default 'needs_review' check (status in ('needs_review', 'resolved')),
  choice text check (choice in ('sms', 'email', 'off')),
  consent_confirmed boolean,
  resolved_by uuid,
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists automation_channel_reviews_open on public.automation_channel_reviews (business_id) where status = 'needs_review';
alter table public.automation_channel_reviews enable row level security;
revoke all on public.automation_channel_reviews from anon, authenticated;
grant select on public.automation_channel_reviews to authenticated;
grant select, insert, update, delete on public.automation_channel_reviews to service_role;
drop policy if exists automation_channel_reviews_read on public.automation_channel_reviews;
create policy automation_channel_reviews_read on public.automation_channel_reviews for select to authenticated
  using (public.zella_has_role(business_id, array['owner', 'admin', 'manager']));

-- which channels each kind of message can really be sent by
create or replace function public.zella_channel_supported(p_type text, p_channel text) returns boolean
language sql immutable set search_path = '' as $$
  select case p_type
    when 'appointment_reminder' then coalesce(p_channel, 'sms') in ('sms', 'email')
    when 'appointment_confirmation' then coalesce(p_channel, 'sms') in ('sms', 'email')
    when 'waitlist_offer' then coalesce(p_channel, 'sms') = 'sms'
    else true end;
$$;

create or replace function public.zella_channel_on_hold(p_business_id uuid, p_type text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.automation_channel_reviews r where r.business_id = p_business_id and r.trigger_type = p_type and r.status = 'needs_review');
$$;
revoke execute on function public.zella_channel_on_hold(uuid, text) from public, anon, authenticated;
grant execute on function public.zella_channel_on_hold(uuid, text) to service_role;

do $$
declare def text;
begin
  -- saving: the unsupported choices are refused
  def := pg_get_functiondef('public.zella_clean_automation_config(text, jsonb)'::regprocedure);
  if position('zella_channel_review' in def) = 0 then
    def := replace(def, $a$      when k = 'channel' and p_type in ('appointment_reminder') then v_text := array['sms','call','sms_and_call'];
      when k = 'channel' and p_type in ('appointment_confirmation','no_show_follow_up','waitlist_offer','staff_unavailable') then v_text := array['sms','call'];$a$,
      $a$      when k = 'channel' and p_type in ('appointment_reminder', 'appointment_confirmation') then v_text := array['sms','email']; /* zella_channel_review */
      when k = 'channel' and p_type = 'waitlist_offer' then v_text := array['sms'];
      when k = 'channel' and p_type in ('no_show_follow_up','staff_unavailable') then v_text := array['sms','call'];$a$);
    if position('zella_channel_review' in def) = 0 then raise exception 'zella_clean_automation_config has changed; review this patch'; end if;
    execute def;
  end if;

  -- queueing reminders and confirmations: nothing for an unsupported channel
  def := pg_get_functiondef('public.zella_replace_reminders(uuid, boolean, text)'::regprocedure);
  if position('zella_channel_review' in def) = 0 then
    def := replace(def, $a$  if v_rem.id is not null then$a$,
      $a$  if v_rem.id is not null and public.zella_channel_supported('appointment_reminder', v_rem.trigger_config ->> 'channel') then /* zella_channel_review */$a$);
    def := replace(def, $a$  if v_conf.id is not null and p_send_confirmation then$a$,
      $a$  if v_conf.id is not null and p_send_confirmation and public.zella_channel_supported('appointment_confirmation', v_conf.trigger_config ->> 'channel') then$a$);
    if position('zella_channel_review' in def) = 0 or position($a$zella_channel_supported('appointment_confirmation'$a$ in def) = 0 then
      raise exception 'zella_replace_reminders has changed; review this patch';
    end if;
    execute def;
  end if;

  def := pg_get_functiondef('public.zella_resync_reminders(uuid)'::regprocedure);
  if position('zella_channel_review' in def) = 0 then
    def := replace(def, $a$    if v_rem.id is not null then$a$,
      $a$    if v_rem.id is not null and public.zella_channel_supported('appointment_reminder', v_rem.trigger_config ->> 'channel') then /* zella_channel_review */$a$);
    if position('zella_channel_review' in def) = 0 then raise exception 'zella_resync_reminders has changed; review this patch'; end if;
    execute def;
  end if;

  -- waitlist offers: none while the channel can't be used
  def := pg_get_functiondef('public.zella_offer_slot(uuid, timestamptz, timestamptz, uuid, uuid)'::regprocedure);
  if position('zella_channel_review' in def) = 0 then
    def := replace(def, $a$  if v_auto.id is null or p_start <= now() then return 0; end if;$a$,
      $a$  if v_auto.id is null or p_start <= now() then return 0; end if;
  if not public.zella_channel_supported('waitlist_offer', v_auto.trigger_config ->> 'channel') then return 0; end if; /* zella_channel_review */$a$);
    if position('zella_channel_review' in def) = 0 then raise exception 'zella_offer_slot has changed; review this patch'; end if;
    execute def;
  end if;

  -- the sender: anything already waiting for an automation under review is held, visibly
  def := pg_get_functiondef('public.zella_claim_reminders(integer, text)'::regprocedure);
  if position('zella_channel_review' in def) = 0 then
    def := replace(def, $a$    /* zella_message_settings_fix: the automation that queued it must still be on */$a$,
      $a$    /* zella_channel_review: held while the owner chooses how it is sent */
    if public.zella_channel_on_hold(r.business_id, case when r.kind = 'reminder' then 'appointment_reminder' else 'appointment_confirmation' end) then
      update public.appointment_reminders set status = 'skipped', error = 'channel_needs_review' where id = r.id; continue;
    end if;
    /* zella_message_settings_fix: the automation that queued it must still be on */$a$);
    if position('zella_channel_review' in def) = 0 then
      def := replace(def, $a$    select * into a from public.appointments where id = r.appointment_id;$a$,
        $a$    /* zella_channel_review: repository definitions before message-settings patch */
    if public.zella_channel_on_hold(r.business_id, case when r.kind = 'reminder' then 'appointment_reminder' else 'appointment_confirmation' end) then
      update public.appointment_reminders set status = 'skipped', error = 'channel_needs_review' where id = r.id; continue;
    end if;
    if not exists (select 1 from public.automations au where au.business_id = r.business_id
                   and au.trigger_type = case when r.kind = 'reminder' then 'appointment_reminder' else 'appointment_confirmation' end
                   and au.status = 'active') then
      update public.appointment_reminders set status = 'skipped', error = 'automation_disabled' where id = r.id; continue;
    end if;
    select * into a from public.appointments where id = r.appointment_id;$a$);
    end if;
    if position('zella_channel_review' in def) = 0 then raise exception 'zella_claim_reminders has changed; review this patch'; end if;
    execute def;
  end if;
end $$;

-- the review list (owners, admins, managers) and the owner's decision (owners and admins)
create or replace function public.zella_channel_reviews(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('automation_id', r.automation_id, 'name', a.name, 'trigger_type', r.trigger_type,
            'requested_channel', r.requested_channel, 'since', r.created_at,
            'choices', case when r.trigger_type = 'waitlist_offer' then '["sms","off"]'::jsonb else '["sms","email","off"]'::jsonb end) order by a.name)
     from public.automation_channel_reviews r join public.automations a on a.id = r.automation_id
    where r.business_id = p_business_id and r.status = 'needs_review'), '[]'::jsonb);
end $$;

create or replace function public.zella_resolve_channel_review(p_automation_id uuid, p_choice text, p_consent_confirmed boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; a record;
begin
  select * into r from public.automation_channel_reviews where automation_id = p_automation_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not public.zella_has_role(r.business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  if r.status <> 'needs_review' then return jsonb_build_object('status', r.status, 'choice', r.choice); end if;
  if p_choice not in ('sms', 'email', 'off') or (p_choice <> 'off' and not public.zella_channel_supported(r.trigger_type, p_choice)) then raise exception 'BAD_CHOICE'; end if;
  if p_choice <> 'off' and not coalesce(p_consent_confirmed, false) then raise exception 'CONSENT_NOT_CONFIRMED'; end if;
  select * into a from public.automations where id = p_automation_id;
  -- the review closes first, so the settings change below re-plans reminders with nothing on hold
  update public.automation_channel_reviews set status = 'resolved', choice = p_choice, consent_confirmed = (p_choice <> 'off' and p_consent_confirmed),
         resolved_by = auth.uid(), resolved_at = now() where automation_id = p_automation_id;
  if p_choice = 'off' then
    update public.automations set status = 'disabled', updated_at = now() where id = p_automation_id;
  else
    update public.automations set trigger_config = coalesce(trigger_config, '{}'::jsonb) || jsonb_build_object('channel', p_choice), updated_at = now() where id = p_automation_id;
  end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (r.business_id, auth.uid(), 'automation_channel_resolved', 'automation', p_automation_id,
          jsonb_build_object('channel', r.requested_channel, 'status', a.status),
          jsonb_build_object('choice', p_choice, 'customers_agreed_to_channel', p_choice <> 'off' and p_consent_confirmed));
  return jsonb_build_object('status', 'resolved', 'choice', p_choice);
end $$;
revoke execute on function public.zella_channel_reviews(uuid), public.zella_resolve_channel_review(uuid, text, boolean) from public, anon;
grant execute on function public.zella_channel_reviews(uuid), public.zella_resolve_channel_review(uuid, text, boolean) to authenticated, service_role;

-- any later write with an unsupported channel (a path that skips the check above) also opens a review, so nothing is
-- ever held without the owner being told
create or replace function public.zella_channel_review_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.trigger_type in ('appointment_reminder', 'appointment_confirmation', 'waitlist_offer')
     and not public.zella_channel_supported(new.trigger_type, new.trigger_config ->> 'channel')
     and not exists (select 1 from public.automation_channel_reviews r where r.automation_id = new.id and r.status = 'needs_review') then
    insert into public.automation_channel_reviews (automation_id, business_id, trigger_type, requested_channel)
    values (new.id, new.business_id, new.trigger_type, new.trigger_config ->> 'channel')
    on conflict (automation_id) do update set status = 'needs_review', requested_channel = excluded.requested_channel, choice = null,
      consent_confirmed = null, resolved_by = null, resolved_at = null, created_at = now();
    perform public.zella_notify(new.business_id, 'automation_review', 'Choose how "' || new.name || '" is sent',
      'It is set to a channel that isn''t available yet, so nothing is sent for it. Choose text, email or off in Settings > Automations.', 'warning', 'automations', new.id, null);
  end if;
  return null;
end $$;
revoke execute on function public.zella_channel_review_trg() from public, anon, authenticated;
drop trigger if exists zella_channel_review_trg on public.automations;
create trigger zella_channel_review_trg after insert or update of trigger_config on public.automations
  for each row execute function public.zella_channel_review_trg();

-- existing automations saved with an unsupported channel (including the ones M3 switched to text)
do $$
declare x record; v_req text; n integer := 0;
begin
  for x in select * from public.automations
            where trigger_type in ('appointment_reminder', 'appointment_confirmation', 'waitlist_offer')
              and (not public.zella_channel_supported(trigger_type, trigger_config ->> 'channel') or trigger_config ? 'channel_requested')
              and not exists (select 1 from public.automation_channel_reviews r where r.automation_id = automations.id and r.status = 'needs_review') loop
    v_req := coalesce(x.trigger_config ->> 'channel_requested', x.trigger_config ->> 'channel');
    insert into public.automation_channel_reviews (automation_id, business_id, trigger_type, requested_channel)
    values (x.id, x.business_id, x.trigger_type, v_req) on conflict (automation_id) do nothing;
    -- back to what the owner saved (M3 had replaced it with text); the settings trigger then withdraws waiting reminders
    update public.automations set trigger_config = (trigger_config - 'channel_requested') || jsonb_build_object('channel', v_req), updated_at = now() where id = x.id;
    update public.appointment_reminders set status = 'skipped', error = 'channel_needs_review'
     where business_id = x.business_id and status = 'pending'
       and kind = any (case when x.trigger_type = 'appointment_reminder' then array['reminder'] when x.trigger_type = 'appointment_confirmation' then array['confirmation', 'confirmation_request'] else array[]::text[] end);
    perform public.zella_notify(x.business_id, 'automation_review', 'Choose how "' || x.name || '" is sent',
      'It was set to ' || case v_req when 'sms_and_call' then 'text and AI call' else 'AI call' end
      || ', which isn''t available yet, so nothing is sent for it. Choose text, email or off in Settings > Automations.', 'warning', 'automations', x.id, null);
    n := n + 1;
  end loop;
  raise notice 'zella_channel_review: % automations held for the owner''s choice', n;
end $$;
