-- Zella - text alerts for team members. Safe to run more than once.
-- Needs zella_sms_sender.sql first. Urgent notifications (a lost AI connection, an emergency call, a failed transfer...)
-- can also be sent as a text to team members who switched this on for themselves. Nobody is texted unless they opted in
-- and nothing is sent until the platform setting sms_live is true. At most 5 alert texts per business per hour.
-- The sending itself is done by the n8n workflow "Zella - Staff Texts".

alter table public.business_members add column if not exists sms_alerts boolean not null default false;
alter table public.staff_notifications add column if not exists sms_status text check (sms_status in ('pending', 'sending', 'done', 'skipped'));
alter table public.staff_notifications add column if not exists sms_claimed_at timestamptz;
create index if not exists staff_notifications_sms_idx on public.staff_notifications (created_at) where sms_status in ('pending', 'sending');

-- A person turns text alerts on or off for themselves. They need a phone number on their profile.
create or replace function public.zella_set_my_sms_alerts(p_business_id uuid, p_enabled boolean) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_phone text;
begin
  if auth.uid() is null or not exists (select 1 from public.business_members where business_id = p_business_id and user_id = auth.uid() and status = 'active') then raise exception 'NOT_ALLOWED'; end if;
  if p_enabled then
    select regexp_replace(coalesce(phone, ''), '\D', '', 'g') into v_phone from public.profiles where id = auth.uid();
    if length(coalesce(v_phone, '')) < 10 then raise exception 'NO_PHONE'; end if;
  end if;
  update public.business_members set sms_alerts = p_enabled where business_id = p_business_id and user_id = auth.uid();
  return true;
end $$;

-- Urgent notifications are marked for texting when someone in the business opted in.
create or replace function public.zella_mark_staff_sms() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.severity = 'urgent' and exists (select 1 from public.business_members m where m.business_id = new.business_id and m.status = 'active' and m.sms_alerts
                                          and (new.user_id is null and m.role in ('owner', 'admin') or m.user_id = new.user_id)) then
    new.sms_status := 'pending';
  end if;
  return new;
end $$;
drop trigger if exists zella_mark_staff_sms_trg on public.staff_notifications;
create trigger zella_mark_staff_sms_trg before insert on public.staff_notifications for each row execute function public.zella_mark_staff_sms();

-- n8n asks for the texts to send. Everything is decided here: who, what, and whether the limit was reached.
create or replace function public.zella_claim_staff_sms(p_limit integer default 10) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_live boolean := coalesce(public.zella_setting('sms_live', 'false'::jsonb) = 'true'::jsonb, false);
  v_from text := nullif(public.zella_setting('sms_from_number', '""'::jsonb) #>> '{}', '');
  n record; m record; v_out jsonb := '[]'::jsonb; v_to text; v_digits text; v_text text; v_msg uuid; v_sent integer; v_bn text;
begin
  if not v_live or v_from is null then return v_out; end if;
  for n in select sn.* from public.staff_notifications sn
            where (sn.sms_status = 'pending' or (sn.sms_status = 'sending' and sn.sms_claimed_at < now() - interval '15 minutes'))
              and sn.created_at > now() - interval '6 hours'
            order by sn.created_at limit greatest(1, least(coalesce(p_limit, 10), 25)) for update skip locked loop
    update public.staff_notifications set sms_status = 'sending', sms_claimed_at = now() where id = n.id;
    select b.name into v_bn from public.businesses b where b.id = n.business_id and b.suspended_at is null and b.cancelled_at is null;
    if v_bn is null then update public.staff_notifications set sms_status = 'skipped' where id = n.id; continue; end if;
    select count(*) into v_sent from public.sms_messages where business_id = n.business_id and metadata ->> 'staff_alert' = 'true' and created_at > now() - interval '1 hour';
    if v_sent >= 5 then update public.staff_notifications set sms_status = 'skipped' where id = n.id; continue; end if;
    v_text := left(regexp_replace('Zella: ' || n.title || coalesce('. ' || n.body, ''), '\s+', ' ', 'g'), 300);
    for m in select bm.user_id, p.phone from public.business_members bm join public.profiles p on p.id = bm.user_id
              where bm.business_id = n.business_id and bm.status = 'active' and bm.sms_alerts
                and ((n.user_id is null and bm.role in ('owner', 'admin')) or bm.user_id = n.user_id) loop
      v_digits := regexp_replace(coalesce(m.phone, ''), '\D', '', 'g');
      v_to := case when coalesce(m.phone, '') like '+%' and length(v_digits) between 8 and 15 then '+' || v_digits
                   when length(v_digits) = 10 then '+1' || v_digits
                   when length(v_digits) = 11 and left(v_digits, 1) = '1' then '+' || v_digits end;
      continue when v_to is null;
      insert into public.sms_messages (business_id, direction, status, from_number, to_number, message_body, metadata)
      values (n.business_id, 'outbound', 'queued', v_from, v_to, v_text, jsonb_build_object('dedupe_key', 'staffsms:' || n.id || ':' || m.user_id, 'staff_alert', 'true'))
      on conflict (business_id, (metadata ->> 'dedupe_key')) where metadata ->> 'dedupe_key' is not null do nothing
      returning id into v_msg;
      continue when v_msg is null;
      v_out := v_out || jsonb_build_array(jsonb_build_object('message_id', v_msg, 'from', v_from, 'to', v_to, 'text', v_text));
    end loop;
    update public.staff_notifications set sms_status = 'done' where id = n.id;
  end loop;
  return v_out;
end $$;

do $$
declare f text;
begin
  execute 'revoke execute on function public.zella_set_my_sms_alerts(uuid,boolean) from public, anon';
  execute 'grant execute on function public.zella_set_my_sms_alerts(uuid,boolean) to authenticated, service_role';
  foreach f in array array['zella_mark_staff_sms()', 'zella_claim_staff_sms(integer)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
