-- Zella - owner summaries and owner emails. Safe to run more than once.
-- Adds: a daily summary for each business (posted at 8am business time), and email delivery of owner
-- notifications (daily summary, weekly review, and any warning or urgent alert) with per-person
-- preferences. Needs zella_email_sender.sql first. Nothing here sends an email; the n8n
-- "Zella - Owner Emails" workflow does, and only when email_live is true.

-- 1. A notification being sent by email has its own short state, so a crashed run can be picked up again.
do $$
declare c text;
begin
  select conname into c from pg_constraint
   where conrelid = 'public.staff_notifications'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%delivery_status%';
  if c is not null then execute format('alter table public.staff_notifications drop constraint %I', c); end if;
  alter table public.staff_notifications add constraint staff_notifications_delivery_status_check
    check (delivery_status in ('pending','sending','sent','failed','skipped'));
end $$;
alter table public.staff_notifications add column if not exists claimed_at timestamptz;

-- 2. Daily summary. Runs every hour; a business gets one when its local time is 8am, once a day,
--    and only when there is something to say (activity, appointments today, or something to look at).
create or replace function public.zella_post_daily_summaries()
returns integer language plpgsql security definer set search_path = public as $$
declare
  b record; v_tz text; v_rev jsonb; v_leads int; v_today int; v_overdue int; v_issues text; v_body text; v_day_start timestamptz; n integer := 0;
begin
  for b in select id, name, coalesce(timezone, 'America/New_York') as tz from public.businesses
            where onboarding_status = 'active' and suspended_at is null and cancelled_at is null loop
    v_tz := b.tz;
    begin
      if extract(hour from (now() at time zone v_tz)) <> 8 then continue; end if;
    exception when others then continue; end;
    if exists (select 1 from public.staff_notifications where business_id = b.id and kind = 'daily_summary' and created_at > now() - interval '20 hours') then continue; end if;

    v_rev := public.zella_performance_review(b.id, 1);
    select count(*) into v_leads from public.customers where business_id = b.id and created_at >= now() - interval '24 hours';
    v_day_start := date_trunc('day', now() at time zone v_tz) at time zone v_tz;
    select count(*) into v_today from public.appointments
     where business_id = b.id and start_time >= v_day_start and start_time < v_day_start + interval '1 day'
       and status in ('scheduled', 'confirmed') and coalesce(booking_state, 'confirmed') = 'confirmed';
    select count(*) into v_overdue from public.callbacks
     where business_id = b.id and status not in ('completed', 'cancelled', 'needs_review') and due_at < now();

    v_issues := (select string_agg(x, ' ') from jsonb_array_elements_text(v_rev -> 'issues') x);
    if v_overdue > 0 then v_issues := concat_ws(' ', v_issues, v_overdue || ' callback(s) are overdue.'); end if;

    if (v_rev ->> 'calls')::int = 0 and v_leads = 0 and v_today = 0 and (v_rev ->> 'appointments_booked')::int = 0 and v_issues is null then continue; end if;

    v_body := 'Yesterday: ' || (v_rev ->> 'calls') || ' call(s), ' || (v_rev ->> 'missed') || ' missed, '
           || (v_rev ->> 'appointments_booked') || ' booked, ' || v_leads || ' new customer(s) or lead(s). '
           || 'Today: ' || v_today || ' appointment(s). '
           || case when v_issues is not null then 'To look at: ' || v_issues else 'Nothing needs attention.' end;
    perform public.zella_notify_owners(b.id, 'daily_summary', 'Your day with Zella - ' || b.name, v_body,
      case when v_issues is not null then 'warning' else 'info' end, 'reports');
    n := n + 1;
  end loop;
  return n;
end $$;

-- 3. Who gets an email, and how the email looks.
--    A notification is emailed when it is a daily summary, a weekly review, or a warning/urgent alert,
--    unless that person turned email off for that kind. A person can also turn email ON for any kind.
--    Notifications meant for one person go to that person; the rest go to the business owners and admins.
create or replace function public.zella_claim_owner_emails(p_limit integer default 20)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  n record; m record; v_res jsonb := '[]'::jsonb; v_pref boolean; v_default boolean; v_found int; v_html text; v_text text;
  v_live boolean := coalesce(public.zella_setting('email_live', 'false'::jsonb) = 'true'::jsonb, false);
  v_from text := nullif(trim(public.zella_setting('email_from_address', '""'::jsonb) #>> '{}'), '');
begin
  for n in select s.*, b.name as business_name from public.staff_notifications s join public.businesses b on b.id = s.business_id
            where (s.delivery_status = 'pending' or (s.delivery_status = 'sending' and s.claimed_at < now() - interval '30 minutes'))
              and b.suspended_at is null and b.cancelled_at is null
            order by s.created_at limit greatest(1, least(coalesce(p_limit, 20), 50)) for update of s skip locked loop
    v_default := n.kind in ('daily_summary', 'weekly_review') or n.severity in ('warning', 'urgent');
    v_found := 0;
    v_text := n.title || E'\n\n' || coalesce(n.body, '') || E'\n\nOpen Zella to see the details.';
    v_html := replace(replace(replace(replace(replace(v_text, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;');
    v_html := '<p>' || replace(replace(v_html, E'\n\n', '</p><p>'), E'\n', '<br>') || '</p>';
    for m in select bm.user_id, lower(trim(u.email)) as email from public.business_members bm join auth.users u on u.id = bm.user_id
              where bm.business_id = n.business_id and bm.status = 'active'
                and ((n.user_id is not null and bm.user_id = n.user_id) or (n.user_id is null and bm.role in ('owner', 'admin')))
                and coalesce(u.email, '') ~ '^[^@\s,;<>]+@[^@\s,;<>]+\.[^@\s,;<>]+$' loop
      select np.email_enabled into v_pref from public.notification_preferences np
       where np.user_id = m.user_id and np.business_id = n.business_id and np.notification_type = n.kind limit 1;
      if coalesce(v_pref, v_default) then
        v_found := v_found + 1;
        v_res := v_res || jsonb_build_array(jsonb_build_object(
          'notification_id', n.id, 'business_id', n.business_id, 'to', m.email,
          'subject', left(regexp_replace(n.title, '[\r\n]+', ' ', 'g'), 200), 'body_text', v_text, 'body_html', v_html,
          'live', v_live, 'from', v_from, 'from_name', 'Zella', 'kind', n.kind));
      end if;
    end loop;
    if v_found = 0 then
      update public.staff_notifications set delivery_status = 'skipped', delivery_error = 'not_emailed', claimed_at = now() where id = n.id;
    else
      update public.staff_notifications set delivery_status = 'sending', claimed_at = now() where id = n.id;
    end if;
  end loop;
  return v_res;
end $$;

-- 4. Report the result for a claimed notification. A sent email always wins over a later failure or skip,
--    so one failing address never hides an email that did go out.
create or replace function public.zella_finish_owner_email(p_id uuid, p_result text, p_note text default null)
returns text language plpgsql security definer set search_path = public as $$
begin
  if p_result not in ('sent', 'skipped', 'failed') then raise exception 'INVALID_RESULT'; end if;
  if p_result = 'sent' then
    update public.staff_notifications set delivery_status = 'sent', delivered_at = now(), delivery_error = null where id = p_id and delivery_status in ('sending', 'failed', 'skipped');
  else
    update public.staff_notifications set delivery_status = p_result, delivery_error = left(coalesce(p_note, p_result), 300) where id = p_id and delivery_status = 'sending';
  end if;
  return p_result;
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'zella_post_daily_summaries()',
    'zella_claim_owner_emails(integer)',
    'zella_finish_owner_email(uuid,text,text)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
