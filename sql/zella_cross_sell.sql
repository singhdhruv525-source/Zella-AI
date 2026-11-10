-- Zella - "You might also need" follow-ups (2026-10-28). Safe to re-run.
-- Needs sql/zella_followups.sql / zella_customer_touches.sql (followup_tasks, the follow-up text and email workflows),
-- sql/zella_automation_foundation.sql (message_templates) and sql/zella_dispatcher.sql.
--
-- A business adds rules: "after <service>, suggest <other service> <N> days later". When an appointment whose title
-- or type mentions the service is marked completed, one follow-up (kind cross_sell) is queued for that customer.
-- It is MARKETING: it is only sent to people who opted in to marketing on that channel (zella_can_contact), never
-- in quiet hours, never while sms_marketing_allowed is off, and stops on STOP / unsubscribe like every other message.
-- Limits: one suggestion per appointment, the same rule at most once per customer every 90 days, any suggestion at
-- most once per customer every 14 days, and a pending suggestion is cancelled when the customer books it anyway.
-- The message uses the templates "cross_sell" (text and email), editable per business like any other template.
-- Rollback: drop trigger zella_cross_sell_completed / zella_cross_sell_booked on public.appointments; drop table
--   public.cross_sell_rules; drop the zella_cross_sell_* functions; delete from message_templates where key = 'cross_sell';
--   re-run sql/zella_dispatcher.sql and rebuild the n8n follow-up workflows.

create table if not exists public.cross_sell_rules (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  after_service text not null check (length(after_service) between 2 and 80),
  suggestion text not null check (length(suggestion) between 2 and 80),
  delay_days integer not null default 14 check (delay_days between 1 and 365),
  active boolean not null default true,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists cross_sell_rules_unique on public.cross_sell_rules (business_id, lower(after_service), lower(suggestion));
alter table public.cross_sell_rules enable row level security;
drop policy if exists cross_sell_rules_read on public.cross_sell_rules;
create policy cross_sell_rules_read on public.cross_sell_rules for select to authenticated using (public.zella_is_member(business_id));
revoke insert, update, delete on public.cross_sell_rules from anon, authenticated;

insert into public.message_templates (business_id, industry_id, key, channel, purpose, locale, subject, body)
select null, null, 'cross_sell', ch, 'marketing', 'en-US', subj, body from (values
  ('sms', null, 'Hi {{first_name}}, thanks for choosing {{business}} for your {{service}}. Many customers also book {{suggestion}}. Reply here if you''d like a time. Reply STOP to opt out.'),
  ('email', 'Something you might also like from {{business}}', E'Hi {{first_name}},\n\nThanks for choosing {{business}} for your {{service}}. Many customers also book {{suggestion}}. Reply to this email if you would like us to find you a time.')
) v(ch, subj, body)
where not exists (select 1 from public.message_templates t where t.business_id is null and t.industry_id is null and t.key = 'cross_sell' and t.channel = v.ch and t.status = 'active');

-- Starter ideas per industry (shown in the settings screen; nothing is created until the business adds one).
-- Health, legal and money industries get none: promotional follow-ups there need more care than a template.
create or replace function public.zella_cross_sell_ideas(p_industry_slug text) returns jsonb
language sql immutable set search_path = '' as $$
  select coalesce(ideas.v -> p_industry_slug, '[]'::jsonb) from (select '{
    "dental": [{"after_service": "cleaning", "suggestion": "teeth whitening", "delay_days": 14}],
    "beauty-salon": [{"after_service": "colour", "suggestion": "deep conditioning treatment", "delay_days": 21},
                     {"after_service": "cut", "suggestion": "blow-dry", "delay_days": 28}],
    "spa-wellness": [{"after_service": "massage", "suggestion": "facial", "delay_days": 21}],
    "hvac": [{"after_service": "install", "suggestion": "annual maintenance plan", "delay_days": 30},
             {"after_service": "repair", "suggestion": "annual maintenance plan", "delay_days": 14}],
    "plumbing": [{"after_service": "repair", "suggestion": "water heater check", "delay_days": 30}],
    "electrical": [{"after_service": "install", "suggestion": "electrical safety inspection", "delay_days": 30}],
    "automotive": [{"after_service": "oil change", "suggestion": "tire rotation", "delay_days": 30}],
    "cleaning-services": [{"after_service": "clean", "suggestion": "deep clean", "delay_days": 30}],
    "landscaping-lawn-care": [{"after_service": "mow", "suggestion": "seasonal clean-up", "delay_days": 30}],
    "pest-control": [{"after_service": "treatment", "suggestion": "quarterly prevention plan", "delay_days": 30}],
    "fitness": [{"after_service": "trial", "suggestion": "personal training session", "delay_days": 3}],
    "pet-care-veterinary": [{"after_service": "grooming", "suggestion": "nail trim", "delay_days": 28}],
    "photography-events": [{"after_service": "session", "suggestion": "printed photos", "delay_days": 7}]
  }'::jsonb as v) ideas;
$$;
grant execute on function public.zella_cross_sell_ideas(text) to authenticated, service_role;

-- An appointment was completed: queue at most one suggestion.
create or replace function public.zella_cross_sell_completed() returns trigger
language plpgsql security definer set search_path = public as $$
declare r public.cross_sell_rules; c record; v_channel text; v_text text;
begin
  if new.status <> 'completed' or old.status is not distinct from new.status or new.customer_id is null then return new; end if;
  if coalesce(public.zella_setting('customer_touches', '{}'::jsonb) -> 'cross_sell', 'true'::jsonb) = 'false'::jsonb then return new; end if;
  v_text := lower(coalesce(new.title, '') || ' ' || coalesce(new.appointment_type, ''));
  select x.id, x.phone, x.email, coalesce(x.do_not_contact, false) dnc, coalesce(x.do_not_sms, false) dns, coalesce(x.do_not_email, false) dne, x.preferred_channel pref
    into c from public.customers x where x.id = new.customer_id and x.business_id = new.business_id;
  if c.id is null or c.dnc then return new; end if;
  -- any suggestion at most once every 14 days
  if exists (select 1 from public.followup_tasks f where f.customer_id = c.id and f.kind = 'cross_sell' and f.created_at > now() - interval '14 days') then return new; end if;
  for r in select * from public.cross_sell_rules where business_id = new.business_id and active order by created_at loop
    continue when position(lower(r.after_service) in v_text) = 0;
    -- the same rule at most once every 90 days
    continue when exists (select 1 from public.followup_tasks f where f.customer_id = c.id and f.kind = 'cross_sell'
                            and f.vars ->> 'rule_id' = r.id::text and f.created_at > now() - interval '90 days');
    -- already booked what we would suggest
    continue when exists (select 1 from public.appointments a where a.customer_id = c.id and a.business_id = new.business_id
                            and a.start_time > now() and a.status in ('scheduled', 'confirmed') and position(lower(r.suggestion) in lower(coalesce(a.title, ''))) > 0);
    if c.pref = 'email' and public.zella_valid_email(c.email) and not c.dne then v_channel := 'email';
    elsif public.zella_digits(c.phone) is not null and not c.dns then v_channel := 'sms';
    elsif public.zella_valid_email(c.email) and not c.dne then v_channel := 'email';
    else return new; end if;
    insert into public.followup_tasks (business_id, customer_id, appointment_id, kind, channel, due_at, max_attempts, vars)
    values (new.business_id, c.id, new.id, 'cross_sell', v_channel, now() + make_interval(days => r.delay_days), 2,
            jsonb_build_object('service', left(coalesce(nullif(trim(new.title), ''), r.after_service), 80), 'suggestion', r.suggestion, 'rule_id', r.id))
    on conflict do nothing;
    exit;
  end loop;
  return new;
exception when others then
  return new;   -- a suggestion must never block completing an appointment
end $$;
drop trigger if exists zella_cross_sell_completed on public.appointments;
create trigger zella_cross_sell_completed after update of status on public.appointments for each row execute function public.zella_cross_sell_completed();

-- The customer booked the suggested service anyway: the pending suggestion is no longer needed.
create or replace function public.zella_cross_sell_booked() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.customer_id is null then return new; end if;
  update public.followup_tasks f set status = 'cancelled', outcome = 'already_booked', completed_at = now(), updated_at = now()
   where f.customer_id = new.customer_id and f.business_id = new.business_id and f.kind = 'cross_sell' and f.status = 'pending'
     and position(lower(f.vars ->> 'suggestion') in lower(coalesce(new.title, '') || ' ' || coalesce(new.appointment_type, ''))) > 0;
  return new;
exception when others then
  return new;
end $$;
drop trigger if exists zella_cross_sell_booked on public.appointments;
create trigger zella_cross_sell_booked after insert on public.appointments for each row execute function public.zella_cross_sell_booked();
-- Trigger functions run only as triggers; nobody calls them directly.
revoke all on function public.zella_cross_sell_completed(), public.zella_cross_sell_booked() from public, anon, authenticated;

-- ---------------------------------------------------------------- settings screen
create or replace function public.zella_cross_sell_list(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_slug text;
begin
  if auth.uid() is null or not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select i.slug into v_slug from public.businesses b left join public.industries i on i.id = b.industry_id where b.id = p_business_id;
  return jsonb_build_object(
    'can_edit', public.zella_can_manage(p_business_id),
    'marketing_texts_allowed', coalesce(public.zella_setting('sms_marketing_allowed', 'false'::jsonb) = 'true'::jsonb, false),
    'rules', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'after_service', r.after_service, 'suggestion', r.suggestion, 'delay_days', r.delay_days,
                 'active', r.active,
                 'queued', (select count(*) from public.followup_tasks f where f.business_id = p_business_id and f.kind = 'cross_sell' and f.vars ->> 'rule_id' = r.id::text and f.status in ('pending', 'in_progress')),
                 'sent', (select count(*) from public.followup_tasks f where f.business_id = p_business_id and f.kind = 'cross_sell' and f.vars ->> 'rule_id' = r.id::text and f.status = 'done' and f.created_at > now() - interval '90 days'),
                 'not_sent', (select count(*) from public.followup_tasks f where f.business_id = p_business_id and f.kind = 'cross_sell' and f.vars ->> 'rule_id' = r.id::text and f.status in ('skipped', 'cancelled', 'failed') and f.created_at > now() - interval '90 days'))
               order by r.created_at) from public.cross_sell_rules r where r.business_id = p_business_id), '[]'::jsonb),
    'ideas', (select coalesce(jsonb_agg(i), '[]'::jsonb) from jsonb_array_elements(public.zella_cross_sell_ideas(v_slug)) i
               where not exists (select 1 from public.cross_sell_rules r where r.business_id = p_business_id
                                   and lower(r.after_service) = lower(i ->> 'after_service') and lower(r.suggestion) = lower(i ->> 'suggestion'))));
end $$;
revoke all on function public.zella_cross_sell_list(uuid) from public, anon;
grant execute on function public.zella_cross_sell_list(uuid) to authenticated;

-- p_rule: {id?, after_service, suggestion, delay_days, active}
create or replace function public.zella_cross_sell_save(p_business_id uuid, p_rule jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_after text; v_sugg text; v_days integer; v_active boolean;
begin
  if auth.uid() is null or not public.zella_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if jsonb_typeof(p_rule) <> 'object' then raise exception 'INVALID_RULE'; end if;
  v_after := trim(regexp_replace(coalesce(p_rule ->> 'after_service', ''), '\s+', ' ', 'g'));
  v_sugg := trim(regexp_replace(coalesce(p_rule ->> 'suggestion', ''), '\s+', ' ', 'g'));
  if length(v_after) not between 2 and 80 or length(v_sugg) not between 2 and 80 then raise exception 'INVALID_RULE'; end if;
  -- these are put into a text message: no links, no placeholders
  if (v_after || ' ' || v_sugg) ~ '(https?://|www\.|[{}<>])' then raise exception 'RULE_TEXT'; end if;
  if lower(v_after) = lower(v_sugg) then raise exception 'SAME_SERVICE'; end if;
  begin v_days := coalesce((p_rule ->> 'delay_days')::integer, 14); exception when others then raise exception 'INVALID_DELAY'; end;
  if v_days not between 1 and 365 then raise exception 'INVALID_DELAY'; end if;
  v_active := coalesce((p_rule ->> 'active')::boolean, true);
  if nullif(p_rule ->> 'id', '') is not null then
    begin v_id := (p_rule ->> 'id')::uuid; exception when others then raise exception 'NOT_FOUND'; end;
    update public.cross_sell_rules set after_service = v_after, suggestion = v_sugg, delay_days = v_days, active = v_active, updated_at = now()
     where id = v_id and business_id = p_business_id;
    if not found then raise exception 'NOT_FOUND'; end if;
  else
    if (select count(*) from public.cross_sell_rules where business_id = p_business_id) >= 30 then raise exception 'TOO_MANY_RULES'; end if;
    insert into public.cross_sell_rules (business_id, after_service, suggestion, delay_days, active, created_by)
    values (p_business_id, v_after, v_sugg, v_days, v_active, auth.uid()) returning id into v_id;
  end if;
  return v_id;
exception when unique_violation then raise exception 'DUPLICATE_RULE';
end $$;
revoke all on function public.zella_cross_sell_save(uuid, jsonb) from public, anon;
grant execute on function public.zella_cross_sell_save(uuid, jsonb) to authenticated;

-- Deleting a rule also cancels the suggestions it queued that haven't gone out yet.
create or replace function public.zella_cross_sell_delete(p_business_id uuid, p_rule_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.zella_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  update public.followup_tasks set status = 'cancelled', outcome = 'rule_removed', completed_at = now(), updated_at = now()
   where business_id = p_business_id and kind = 'cross_sell' and status = 'pending' and vars ->> 'rule_id' = p_rule_id::text;
  delete from public.cross_sell_rules where id = p_rule_id and business_id = p_business_id;
  return found;
end $$;
revoke all on function public.zella_cross_sell_delete(uuid, uuid) from public, anon;
grant execute on function public.zella_cross_sell_delete(uuid, uuid) to authenticated;

create or replace function public.zella_cross_sell_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('table', to_regclass('public.cross_sell_rules') is not null,
    'templates', (select count(*) = 2 from public.message_templates where business_id is null and key = 'cross_sell' and status = 'active' and purpose = 'marketing'),
    'dispatcher_kind', coalesce(pg_get_functiondef(to_regprocedure('public.zella_dispatch_n8n()')) like '%''cross_sell''%', false));
$$;
revoke all on function public.zella_cross_sell_status() from public, anon, authenticated;
grant execute on function public.zella_cross_sell_status() to service_role;
