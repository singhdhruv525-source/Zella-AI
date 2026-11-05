-- Calendar connections a business can make itself, for Google Calendar and Outlook (Microsoft 365) (5 Nov 2026).
-- Until now the setup wizard offered "Google Calendar" and "Outlook Calendar", but nothing could connect either: the
-- sync (zella_calendar_sync.sql, n8n) existed for Google only, and zella_calendar_connect had no caller.
--
--   * The calendar-connect edge function runs the provider's sign-in (OAuth): an owner or admin starts it in
--     Settings > Calendar connections; the provider sends them back with a one-time code; the function exchanges it
--     and stores the refresh token in Vault through zella_calendar_connect_provider (server only). The token is never
--     shown, logged or sent to the browser.
--   * One active calendar per business. Connecting the other provider disconnects the first (its token is deleted).
--   * Disconnecting (owners and admins) deletes the stored token, stops syncing and removes the busy times that came
--     from that calendar; bookings already copied to it stay there (they are the business's own calendar).
--   * The sync and busy-time claims now say which provider each item is for, so n8n calls Google or Microsoft Graph.
--   * Connecting and disconnecting are written to the audit log (provider and account, never the token).
-- Needs zella_calendar_sync.sql. Safe to run twice. Needs the owner's approval; nothing syncs until calendar_sync_live.

alter table public.calendar_connections drop constraint if exists calendar_connections_provider_check;
alter table public.calendar_connections add constraint calendar_connections_provider_check check (provider in ('google', 'outlook'));
create unique index if not exists calendar_connections_one_active on public.calendar_connections (business_id) where status = 'active';

-- may this signed-in person connect or disconnect the business's calendar? (owners and admins)
create or replace function public.zella_calendar_can_manage(p_business_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = auth.uid()
                  and m.status = 'active' and m.role in ('owner', 'admin'))
     and exists (select 1 from public.businesses b where b.id = p_business_id and b.suspended_at is null and b.cancelled_at is null) $$;

-- server only (calendar-connect, after the provider's sign-in): store the token and make this the active calendar
create or replace function public.zella_calendar_connect_provider(p_business_id uuid, p_provider text, p_actor uuid, p_account_email text,
                                                                  p_refresh_token text, p_calendar_id text default 'primary')
returns uuid language plpgsql security definer set search_path = public, vault as $$
declare v_name text; v_id uuid; o record;
begin
  if p_provider not in ('google', 'outlook') then raise exception 'BAD_PROVIDER'; end if;
  -- the person who started the sign-in must still be allowed when it finishes
  if not exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = p_actor and m.status = 'active' and m.role in ('owner', 'admin'))
     or not exists (select 1 from public.businesses where id = p_business_id and suspended_at is null and cancelled_at is null) then
    raise exception 'NOT_ALLOWED';
  end if;
  if nullif(trim(coalesce(p_refresh_token, '')), '') is null then raise exception 'NO_TOKEN'; end if;
  -- the other provider's calendar, if any, is disconnected and its token deleted
  for o in select * from public.calendar_connections where business_id = p_business_id and provider <> p_provider and status <> 'disconnected' loop
    update public.calendar_connections set status = 'disconnected', busy_refresh_due_at = null, last_error = null where id = o.id;
    if o.vault_secret_name is not null then delete from vault.secrets where name = o.vault_secret_name; end if;
    delete from public.blocked_times where connection_id = o.id and end_time > now();
  end loop;
  v_name := 'zella_cal_' || p_provider || '_' || p_business_id::text;
  if exists (select 1 from vault.secrets where name = v_name) then
    perform vault.update_secret((select id from vault.secrets where name = v_name), p_refresh_token);
  else
    perform vault.create_secret(p_refresh_token, v_name);
  end if;
  insert into public.calendar_connections (business_id, provider, status, calendar_id, account_email, vault_secret_name, busy_refresh_due_at, last_error)
  values (p_business_id, p_provider, 'active', coalesce(nullif(trim(p_calendar_id), ''), 'primary'), left(p_account_email, 200), v_name, now(), null)
  on conflict (business_id, provider) do update set status = 'active', calendar_id = excluded.calendar_id, account_email = excluded.account_email,
    vault_secret_name = excluded.vault_secret_name, busy_refresh_due_at = now(), last_error = null, connected_at = now()
  returning id into v_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (p_business_id, p_actor, 'calendar_connected', 'calendar_connection', v_id, jsonb_build_object('provider', p_provider, 'account', left(p_account_email, 200)));
  return v_id;
end $$;

-- owners and admins disconnect
create or replace function public.zella_calendar_disconnect(p_business_id uuid) returns integer
language plpgsql security definer set search_path = public, vault as $$
declare c record; n integer := 0;
begin
  if not public.zella_calendar_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  for c in select * from public.calendar_connections where business_id = p_business_id and status <> 'disconnected' loop
    update public.calendar_connections set status = 'disconnected', busy_refresh_due_at = null where id = c.id;
    if c.vault_secret_name is not null then delete from vault.secrets where name = c.vault_secret_name; end if;
    delete from public.blocked_times where connection_id = c.id and end_time > now();
    update public.calendar_sync_queue set status = 'skipped', error = 'calendar_disconnected', completed_at = now() where business_id = p_business_id and status = 'pending';
    insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data)
    values (p_business_id, auth.uid(), 'calendar_disconnected', 'calendar_connection', c.id, jsonb_build_object('provider', c.provider, 'account', c.account_email));
    n := n + 1;
  end loop;
  return n;
end $$;

-- the sync and busy-time claims say which provider each item is for
do $$
declare def text;
begin
  def := pg_get_functiondef('public.zella_claim_calendar_sync(integer)'::regprocedure);
  if position('''provider'', c.provider' in def) = 0 then
    def := replace(def, $a$'calendar_id', c.calendar_id, 'refresh_token', v_token,$a$, $a$'calendar_id', c.calendar_id, 'provider', c.provider, 'refresh_token', v_token,$a$);
    if position('''provider'', c.provider' in def) = 0 then raise exception 'zella_claim_calendar_sync has changed; review this patch'; end if;
    execute def;
  end if;
  def := pg_get_functiondef('public.zella_claim_calendar_pulls(integer)'::regprocedure);
  if position('''provider'', c.provider' in def) = 0 then
    def := replace(def, $a$'calendar_id', c.calendar_id,$a$, $a$'calendar_id', c.calendar_id, 'provider', c.provider,$a$);
    if position('''provider'', c.provider' in def) = 0 then raise exception 'zella_claim_calendar_pulls has changed; review this patch'; end if;
    execute def;
  end if;
end $$;

revoke execute on function public.zella_calendar_connect_provider(uuid, text, uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.zella_calendar_connect_provider(uuid, text, uuid, text, text, text) to service_role;
revoke execute on function public.zella_calendar_can_manage(uuid), public.zella_calendar_disconnect(uuid) from public, anon;
grant execute on function public.zella_calendar_can_manage(uuid), public.zella_calendar_disconnect(uuid) to authenticated, service_role;
