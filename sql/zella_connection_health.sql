-- Zella - connection health: provider tests (run by the n8n "Connection Tests" workflow), reconnect prompts for broken
-- calendar and integration connections, and setup reminders. Safe to run more than once.
-- Tests stay off until the platform setting provider_checks_live is true (set it at go-live, after the keys are in n8n).

create table if not exists public.provider_health (
  provider text primary key, ok boolean, detail text, checked_at timestamptz, claimed_at timestamptz,
  consecutive_failures integer not null default 0, last_ok_at timestamptz);
alter table public.provider_health enable row level security;   -- service role only

create or replace function public.zella_provider_checks_live()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.zella_setting('provider_checks_live', 'false'::jsonb) = 'true'::jsonb, false);
$$;

-- Which providers are due for a test (every 3 hours). Marks them claimed so a slow run is not repeated.
create or replace function public.zella_claim_provider_checks(p_limit integer default 5)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p text; v_out jsonb := '[]'::jsonb; n integer := 0;
begin
  if not public.zella_provider_checks_live() then return v_out; end if;
  foreach p in array array['telnyx', 'vapi', 'resend'] loop
    exit when n >= greatest(1, least(coalesce(p_limit, 5), 10));
    if exists (select 1 from public.provider_health h where h.provider = p
                and (coalesce(h.checked_at, 'epoch') > now() - interval '3 hours' or coalesce(h.claimed_at, 'epoch') > now() - interval '10 minutes')) then continue; end if;
    insert into public.provider_health (provider, claimed_at) values (p, now()) on conflict (provider) do update set claimed_at = now();
    v_out := v_out || jsonb_build_array(jsonb_build_object('provider', p));
    n := n + 1;
  end loop;
  return v_out;
end $$;

-- Record one result. Two failures in a row raise an alert; a recovery clears it with a note.
create or replace function public.zella_record_provider_check(p_provider text, p_ok boolean, p_detail text default null)
returns text language plpgsql security definer set search_path = public as $$
declare h public.provider_health;
begin
  if p_provider not in ('telnyx', 'vapi', 'resend') then raise exception 'UNKNOWN_PROVIDER'; end if;
  insert into public.provider_health (provider) values (p_provider) on conflict do nothing;
  select * into h from public.provider_health where provider = p_provider for update;
  update public.provider_health set ok = p_ok, detail = left(p_detail, 120), checked_at = now(), claimed_at = null,
         consecutive_failures = case when p_ok then 0 else consecutive_failures + 1 end,
         last_ok_at = case when p_ok then now() else last_ok_at end
   where provider = p_provider;
  if not p_ok and h.consecutive_failures + 1 = 2 then
    perform public.zella_platform_alert('provider_down', initcap(p_provider) || ' is not responding', left(p_detail, 120), 'urgent', null, 'provider_down:' || p_provider);
  elsif p_ok and h.consecutive_failures >= 2 then
    perform public.zella_platform_alert('provider_recovered', initcap(p_provider) || ' is working again', null, 'info', null, 'provider_recovered:' || p_provider);
  end if;
  return case when p_ok then 'ok' else 'failed' end;
end $$;

-- Daily: ask owners to reconnect a broken connection, and remind new businesses to finish setup. Each at most every few days.
create or replace function public.zella_check_connections()
returns integer language plpgsql security definer set search_path = public as $$
declare c record; b record; n integer := 0;
begin
  for c in select distinct business_id from public.calendar_connections where status = 'error' loop
    continue when exists (select 1 from public.staff_notifications s where s.business_id = c.business_id and s.kind = 'integration_reconnect' and s.created_at > now() - interval '3 days');
    perform public.zella_notify_owners(c.business_id, 'integration_reconnect', 'Reconnect your calendar', 'Your Google Calendar stopped syncing. Open Integrations and reconnect it so bookings stay up to date.', 'warning', 'integrations');
    n := n + 1;
  end loop;
  for c in select distinct business_id from public.integrations where status in ('error', 'expired', 'failed', 'disconnected') and coalesce(error_count, 0) > 0 loop
    continue when exists (select 1 from public.staff_notifications s where s.business_id = c.business_id and s.kind = 'integration_reconnect' and s.created_at > now() - interval '3 days');
    perform public.zella_notify_owners(c.business_id, 'integration_reconnect', 'An integration needs attention', 'One of your connected apps stopped working. Open Integrations to reconnect it.', 'warning', 'integrations');
    n := n + 1;
  end loop;
  for b in select id from public.businesses where suspended_at is null and cancelled_at is null and created_at < now() - interval '2 days' loop
    continue when public.zella_validate_business_config(b.id) ->> 'ok' = 'true';
    continue when exists (select 1 from public.staff_notifications s where s.business_id = b.id and s.kind = 'setup_reminder' and s.created_at > now() - interval '7 days');
    perform public.zella_notify_owners(b.id, 'setup_reminder', 'Finish setting up Zella', 'A few things are still missing, such as a phone number or answers for your AI receptionist. Open Settings to finish.', 'info', 'settings');
    n := n + 1;
  end loop;
  return n;
end $$;

do $$
declare f text;
begin
  foreach f in array array['zella_provider_checks_live()', 'zella_claim_provider_checks(integer)', 'zella_record_provider_check(text,boolean,text)', 'zella_check_connections()'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
