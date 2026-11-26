-- Zella Voice: the business's own email address, part 6: a connected mailbox's daily limits and pacing (owner, 27 Nov
-- 2026; docs/ARCHITECTURE.md §14.4, REQ-BEM-10 to REQ-BEM-14). Needs sql/zella_business_email.sql (and
-- sql/zella_business_email_send.sql, which made zella_function_archive).
--   1. business_email_mailbox_caps becomes 80% of each provider's limit, per connected mailbox: free Gmail 400 a day,
--      Google Workspace 1,600, Outlook.com personal 240, Microsoft 365 8,000, and at most 20 a minute for every type
--      ("per_minute"). Only the value this file was written for (sql/zella_business_email.sql's) is changed; the old
--      value is archived for the rollback.
--   2. zella_business_email_mailbox_cap(provider, type): the daily cap of one mailbox type, or "per_minute". A type
--      that couldn't be determined (null) gets the LOWEST cap for that provider (free Gmail's, or Outlook.com's).
--   3. zella_business_email_mailbox_saved gets p_mailbox_kind ("personal", "work" or null), worked out by the
--      business-email function from the provider's own sign in (Google's hd claim, Microsoft's tenant id): free mail
--      domains are always personal; otherwise "work" is Google Workspace or Microsoft 365, "personal" free Gmail or
--      Outlook.com, and anything else is stored as not known (null), so the lowest cap applies. The old five argument
--      version is dropped (one function, so a call by name is never ambiguous).
--   4. zella_business_email_sender: at the daily cap the rest of the business's day still goes from Zella Voice's
--      address with the business's name (unchanged, now with these caps); under it, when the mailbox already has 20
--      emails in the last 60 seconds, the answer says pace_until (when the oldest of them is a minute old) and the
--      Email Sender and Follow up Emails put that reminder or follow up back until then with
--      zella_business_email_paced, without using up a try. Nothing goes from the fallback because of pacing.
--   5. zella_business_email_status also says the mailbox's type, daily cap, per minute cap and emails sent today.
-- Who may call what does not change: everything is server only except the status read (signed in).
-- Each replaced function must be sql/zella_business_email.sql's version (or already this file's), otherwise
-- VERSION_MISMATCH and nothing changes. Safe to run twice. Rollback: sql/rollback/zella_business_email_caps_rollback.sql
begin;

do $$
declare f record; d text; v jsonb;
  plan constant jsonb := '{
    "public.zella_business_email_sender(uuid)": {"base": "193583411ec9519f57a68684c7ebf224", "mine": "4869cab9ec6319740667de295508c884"},
    "public.zella_business_email_status(uuid)": {"base": "5fb484efb0cb4d193f59d1fcf7cac16b", "mine": "59e30c139362c44863045142ee98aa43"}}';
  old_caps constant jsonb := '{"gmail": 500, "google_workspace": 2000, "outlook": 300, "microsoft_365": 2000}';
  new_caps constant jsonb := '{"gmail": 400, "google_workspace": 1600, "outlook": 240, "microsoft_365": 8000, "per_minute": 20}';
begin
  if to_regclass('public.business_email_senders') is null or to_regclass('public.zella_function_archive') is null
     or to_regprocedure('public.zella_setting(text,jsonb)') is null then
    raise exception 'VERSION_MISMATCH: apply sql/zella_business_email.sql and sql/zella_business_email_send.sql first';
  end if;
  -- check everything first
  for f in select key, value from jsonb_each(plan) loop
    if to_regprocedure(f.key) is null then raise exception 'VERSION_MISMATCH: % is missing', f.key; end if;
    d := pg_get_functiondef(f.key::regprocedure);
    if md5(d) not in (f.value ->> 'base', f.value ->> 'mine') then raise exception 'VERSION_MISMATCH: % is not a version this file was written for', f.key; end if;
  end loop;
  if to_regprocedure('public.zella_business_email_mailbox_saved(uuid,uuid,text,text,text)') is not null then
    if md5(pg_get_functiondef('public.zella_business_email_mailbox_saved(uuid,uuid,text,text,text)'::regprocedure)) <> '6dc2549df6f019fa5e61ab57346ff1bc' then
      raise exception 'VERSION_MISMATCH: zella_business_email_mailbox_saved is not a version this file was written for';
    end if;
  elsif to_regprocedure('public.zella_business_email_mailbox_saved(uuid,uuid,text,text,text,text)') is null then
    raise exception 'VERSION_MISMATCH: zella_business_email_mailbox_saved is missing';
  end if;
  for f in select * from (values ('public.zella_business_email_mailbox_cap(text,text)', 'bdff7c09430adeeb89d57595ca12cd67'),
                                 ('public.zella_business_email_paced(text,uuid,timestamptz)', '9c86894efd14ee848702d00e15dacf76'),
                                 ('public.zella_business_email_mailbox_saved(uuid,uuid,text,text,text,text)', '0b43ade45c628f71091efbbcdf71b73d')) as t(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'VERSION_MISMATCH: % already exists in another version', f.sig;
    end if;
  end loop;
  select value into v from public.platform_settings where key = 'business_email_mailbox_caps';
  if v is null or (v <> old_caps and v <> new_caps) then
    raise exception 'VERSION_MISMATCH: business_email_mailbox_caps is not the value this file was written for';
  end if;

  -- then archive what is replaced, and change the setting
  for f in select key, value from jsonb_each(plan) loop
    d := pg_get_functiondef(f.key::regprocedure);
    if md5(d) = f.value ->> 'base' then
      insert into public.zella_function_archive (migration, signature, definition, definition_md5)
      values ('zella_business_email_caps', f.key, d, md5(d)) on conflict (migration, signature) do nothing;
    end if;
  end loop;
  if to_regprocedure('public.zella_business_email_mailbox_saved(uuid,uuid,text,text,text)') is not null then
    d := pg_get_functiondef('public.zella_business_email_mailbox_saved(uuid,uuid,text,text,text)'::regprocedure);
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_business_email_caps', 'public.zella_business_email_mailbox_saved(uuid,uuid,text,text,text)', d, md5(d)) on conflict (migration, signature) do nothing;
    drop function public.zella_business_email_mailbox_saved(uuid, uuid, text, text, text);
  end if;
  if v = old_caps then
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_business_email_caps', 'setting: business_email_mailbox_caps', v::text, md5(v::text)) on conflict (migration, signature) do nothing;
    update public.platform_settings set value = new_caps where key = 'business_email_mailbox_caps';
  end if;
end $$;

-- 2. one mailbox type's daily cap, or "per_minute". Not known (null): the lowest cap for that provider.
create or replace function public.zella_business_email_mailbox_cap(p_provider text, p_type text) returns integer
language plpgsql stable security definer set search_path = '' as $$
declare c jsonb := coalesce(public.zella_setting('business_email_mailbox_caps', '{}'::jsonb), '{}'::jsonb); v integer;
        v_types text[] := case p_provider when 'gmail' then array['gmail', 'google_workspace'] when 'outlook' then array['outlook', 'microsoft_365']
                               else array['gmail', 'google_workspace', 'outlook', 'microsoft_365'] end;
begin
  if p_type = 'per_minute' then
    return case when (c ->> 'per_minute') ~ '^[0-9]{1,5}$' and (c ->> 'per_minute')::integer > 0 then (c ->> 'per_minute')::integer else 20 end;
  end if;
  if p_type = any (v_types) and (c ->> p_type) ~ '^[0-9]{1,7}$' then return (c ->> p_type)::integer; end if;
  select min((c ->> t)::integer) into v from unnest(v_types) t where (c ->> t) ~ '^[0-9]{1,7}$';
  return coalesce(v, case when p_provider = 'gmail' then 400 else 240 end);
end $$;

-- 3. a mailbox connected through the provider's sign in, with its type when the sign in said it
create or replace function public.zella_business_email_mailbox_saved(p_business_id uuid, p_actor uuid, p_provider text, p_account_email text,
                                                                     p_refresh_token text, p_mailbox_kind text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.business_email_senders; v_name text; v_acct text := lower(trim(coalesce(p_account_email, ''))); v_dom text; v_cap text;
begin
  if p_provider not in ('gmail', 'outlook') then return jsonb_build_object('ok', false, 'reason', 'BAD_PROVIDER'); end if;
  if not public.zella_business_email_mailbox_can_connect(p_business_id, p_actor) then return jsonb_build_object('ok', false, 'reason', 'NOT_ALLOWED'); end if;
  if nullif(trim(coalesce(p_refresh_token, '')), '') is null then return jsonb_build_object('ok', false, 'reason', 'NO_TOKEN'); end if;
  if length(v_acct) > 254 or v_acct !~ '^[a-z0-9._%+-]{1,64}@[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$' then
    return jsonb_build_object('ok', false, 'reason', 'NO_ACCOUNT_EMAIL');   -- the From address must be the mailbox's own
  end if;
  v_dom := split_part(v_acct, '@', 2);
  -- the mailbox type (owner, 27 Nov 2026): a free mail domain is personal; otherwise the provider's sign in says it;
  -- not known stays null, and the lowest cap for the provider applies (zella_business_email_mailbox_cap)
  v_cap := case when p_provider = 'gmail' then
                  case when v_dom in ('gmail.com', 'googlemail.com') then 'gmail' when p_mailbox_kind = 'work' then 'google_workspace'
                       when p_mailbox_kind = 'personal' then 'gmail' end
                else
                  case when v_dom in ('outlook.com', 'hotmail.com', 'live.com', 'msn.com') then 'outlook' when p_mailbox_kind = 'work' then 'microsoft_365'
                       when p_mailbox_kind = 'personal' then 'outlook' end end;
  select * into s from public.business_email_senders where business_id = p_business_id for update;
  v_name := 'zella_mail_' || p_provider || '_' || p_business_id::text;
  if s.mailbox_secret_name is not null and s.mailbox_secret_name <> v_name then delete from vault.secrets where name = s.mailbox_secret_name; end if;
  if exists (select 1 from vault.secrets where name = v_name) then
    perform vault.update_secret((select id from vault.secrets where name = v_name), p_refresh_token);
  else
    perform vault.create_secret(p_refresh_token, v_name);
  end if;
  insert into public.business_email_senders as x (business_id, route, address, domain, domain_status, resend_domain_id, dns_records, domain_checked_at, domain_verified_at,
                                                  mailbox_provider, mailbox_status, mailbox_account, mailbox_cap_key, mailbox_secret_name, mailbox_connected_at,
                                                  cap_reached_on, updated_at, updated_by)
  values (p_business_id, 'mailbox', null, null, 'none', null, '[]'::jsonb, null, null, p_provider, 'connected', v_acct, v_cap, v_name, now(), null, now(), p_actor)
  on conflict (business_id) do update set route = 'mailbox', address = null, domain = null, domain_status = 'none', resend_domain_id = null, dns_records = '[]'::jsonb,
    domain_checked_at = null, domain_verified_at = null, mailbox_provider = excluded.mailbox_provider, mailbox_status = 'connected', mailbox_account = excluded.mailbox_account,
    mailbox_cap_key = excluded.mailbox_cap_key, mailbox_secret_name = excluded.mailbox_secret_name, mailbox_connected_at = now(), cap_reached_on = null,
    updated_at = now(), updated_by = p_actor;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, p_actor, 'business_email.mailbox_connected', 'business', p_business_id,
          jsonb_strip_nulls(jsonb_build_object('route', s.route, 'domain', s.domain, 'mailbox_provider', s.mailbox_provider, 'mailbox_account', s.mailbox_account)),
          jsonb_build_object('route', 'mailbox', 'mailbox_provider', p_provider, 'mailbox_account', v_acct, 'mailbox_type', coalesce(v_cap, 'unknown')));
  return jsonb_build_object('ok', true, 'account', v_acct, 'mailbox_type', coalesce(v_cap, 'unknown'), 'removed_domain_id', s.resend_domain_id);
end $$;

-- 4. who sends this business's next email to a customer, and how (sql/zella_business_email.sql), with the 27 Nov 2026
-- caps (zella_business_email_mailbox_cap: a type not known gets the provider's lowest) and pacing: 20 mailbox emails in
-- the last 60 seconds and the answer says pace_until, when the oldest of them is a minute old.
create or replace function public.zella_business_email_sender(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare s public.business_email_senders; b record; v_routes jsonb; v_reply text; v_name text; v_note text; v_day date; v_cap integer; v_sent integer;
        v_tz text; v_recent integer; v_oldest timestamptz;
        v_from text := nullif(trim(public.zella_setting('email_from_address', '""'::jsonb) #>> '{}'), '');
begin
  select x.id, x.name, x.email, x.timezone into b from public.businesses x where x.id = p_business_id;
  if b.id is null then return jsonb_build_object('sender_route', 'fallback', 'sender_note', 'unknown_business'); end if;
  v_name := left(btrim(regexp_replace(coalesce(b.name, ''), '[\r\n"<>]+', ' ', 'g')), 80);
  v_reply := nullif(lower(trim(coalesce(b.email, ''))), '');
  if not coalesce(public.zella_valid_email(v_reply), false) or v_reply !~ '^[^@\s,;<>"]+@[^@\s,;<>"]+\.[^@\s,;<>"]+$' then v_reply := null; end if;
  select * into s from public.business_email_senders where business_id = p_business_id;
  v_routes := coalesce(public.zella_setting('business_email_routes', '{}'::jsonb), '{}'::jsonb);
  if s.route = 'domain' then
    if s.domain_status <> 'verified' then v_note := 'domain_not_verified';
    elsif coalesce(v_routes ->> 'domain', 'false') <> 'true' then v_note := 'domain_route_off';
    else
      return jsonb_build_object('sender_route', 'domain', 'transport', 'resend', 'from', s.address, 'from_name', v_name, 'reply_to', s.address, 'sender_note', null);
    end if;
  elsif s.route = 'mailbox' then
    v_day := public.zella_business_email_local_day(p_business_id);
    v_tz := coalesce(nullif(b.timezone, ''), 'America/New_York');
    if s.mailbox_status <> 'connected' then v_note := 'mailbox_reconnect_needed';
    elsif coalesce(v_routes ->> 'mailbox', 'false') <> 'true' then v_note := 'mailbox_route_off';
    elsif s.cap_reached_on = v_day then v_note := 'mailbox_daily_cap';
    else
      v_cap := public.zella_business_email_mailbox_cap(s.mailbox_provider, s.mailbox_cap_key);
      -- today's mailbox emails, at the business's midnight; queued ones count
      select count(*) into v_sent from public.email_messages m
       where m.business_id = p_business_id and m.direction = 'outbound' and m.metadata ->> 'transport' in ('gmail', 'outlook')
         and m.status in ('queued', 'sent', 'delivered') and m.created_at >= (v_day::timestamp at time zone v_tz);
      if v_sent >= v_cap then v_note := 'mailbox_daily_cap';
      else
        -- pacing: at most per_minute mailbox emails in any 60 seconds; the next one waits, it never goes from the fallback
        select count(*), min(m.created_at) into v_recent, v_oldest from public.email_messages m
         where m.business_id = p_business_id and m.direction = 'outbound' and m.metadata ->> 'transport' in ('gmail', 'outlook')
           and m.status in ('queued', 'sent', 'delivered') and m.created_at > now() - interval '60 seconds';
        return jsonb_build_object('sender_route', 'mailbox', 'transport', s.mailbox_provider, 'from', s.mailbox_account, 'from_name', v_name, 'reply_to', s.mailbox_account,
                                  'sender_note', case when v_recent >= public.zella_business_email_mailbox_cap(s.mailbox_provider, 'per_minute') then 'mailbox_paced' end)
               || case when v_recent >= public.zella_business_email_mailbox_cap(s.mailbox_provider, 'per_minute')
                       then jsonb_build_object('pace_until', greatest(v_oldest + interval '60 seconds', now() + interval '1 second')) else '{}'::jsonb end;
      end if;
    end if;
  end if;
  return jsonb_build_object('sender_route', 'fallback', 'transport', 'resend', 'from', v_from, 'from_name', v_name, 'sender_note', v_note)
         || case when v_reply is not null then jsonb_build_object('reply_to', v_reply) else '{}'::jsonb end;
end $$;

-- pacing: the reminder or follow up whose mailbox email has to wait goes back until p_until (at least now, at most two
-- minutes away), with its try given back, so it is prepared again then. Server only (n8n, from its Decide step).
create or replace function public.zella_business_email_paced(p_item text, p_id uuid, p_until timestamptz) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_due timestamptz := least(greatest(coalesce(p_until, now()), now()), now() + interval '2 minutes'); v_done text;
begin
  if p_item = 'reminder' then
    update public.appointment_reminders set status = 'pending', due_at = v_due, attempts = greatest(attempts - 1, 0)
     where id = p_id and status = 'sending' returning 'reminder' into v_done;
  elsif p_item = 'task' then
    update public.followup_tasks set status = 'pending', due_at = v_due, attempts = greatest(attempts - 1, 0), updated_at = now()
     where id = p_id and status = 'in_progress' returning 'task' into v_done;
  else
    raise exception 'BAD_ITEM';
  end if;
  return jsonb_build_object('ok', v_done is not null, 'requeued', v_done, 'due_at', case when v_done is not null then v_due end);
end $$;

-- 5. what the setup screen shows, now with the mailbox's type, its caps and today's count
create or replace function public.zella_business_email_status(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare s public.business_email_senders; b record; v_routes jsonb; v_reply text; v_active text; v_day date; v_sent integer;
begin
  if not (exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = auth.uid()
                   and m.status = 'active' and m.role in ('owner', 'admin', 'manager'))
          or coalesce(public.zella_admin_can('businesses.view'), false)) then
    raise exception 'NOT_ALLOWED';
  end if;
  select x.id, x.name, x.email, x.timezone into b from public.businesses x where x.id = p_business_id;
  if b.id is null then raise exception 'NOT_FOUND'; end if;
  select * into s from public.business_email_senders where business_id = p_business_id;
  v_routes := coalesce(public.zella_setting('business_email_routes', '{}'::jsonb), '{}'::jsonb);
  v_reply := nullif(lower(trim(coalesce(b.email, ''))), '');
  v_day := public.zella_business_email_local_day(p_business_id);
  v_active := public.zella_business_email_sender(p_business_id) ->> 'sender_route';
  if s.route = 'mailbox' then
    select count(*) into v_sent from public.email_messages m
     where m.business_id = p_business_id and m.direction = 'outbound' and m.metadata ->> 'transport' in ('gmail', 'outlook')
       and m.status in ('queued', 'sent', 'delivered') and m.created_at >= (v_day::timestamp at time zone coalesce(nullif(b.timezone, ''), 'America/New_York'));
  end if;
  return jsonb_build_object(
    'route', s.route,                  -- the route set up (or being set up), or null: the fallback
    'active_route', v_active,          -- the route the next email actually uses: domain, mailbox or fallback
    'address', coalesce(s.address, case when s.route = 'mailbox' then s.mailbox_account end),
    'domain', s.domain, 'domain_status', coalesce(s.domain_status, 'none'), 'dns_records', coalesce(s.dns_records, '[]'::jsonb),
    'domain_checked_at', s.domain_checked_at, 'domain_verified_at', s.domain_verified_at,
    'mailbox_provider', s.mailbox_provider, 'mailbox_status', coalesce(s.mailbox_status, 'none'), 'mailbox_account', s.mailbox_account,
    'mailbox_connected_at', s.mailbox_connected_at, 'cap_reached_today', s.cap_reached_on is not distinct from v_day and s.cap_reached_on is not null,
    -- the limits (owner, 27 Nov 2026): the type, its daily cap (the lowest for the provider when the type isn't known),
    -- the per minute cap, and today's mailbox emails
    'mailbox_type', case when s.route = 'mailbox' then coalesce(s.mailbox_cap_key, 'unknown') end,
    'mailbox_daily_cap', case when s.route = 'mailbox' then public.zella_business_email_mailbox_cap(s.mailbox_provider, s.mailbox_cap_key) end,
    'mailbox_per_minute', case when s.route = 'mailbox' then public.zella_business_email_mailbox_cap(s.mailbox_provider, 'per_minute') end,
    'mailbox_sent_today', v_sent,
    'routes_live', jsonb_build_object('domain', coalesce(v_routes ->> 'domain', 'false') = 'true', 'mailbox', coalesce(v_routes ->> 'mailbox', 'false') = 'true'),
    'fallback', jsonb_build_object('from_name', left(regexp_replace(coalesce(b.name, ''), '[\r\n"<>]+', ' ', 'g'), 80),
                                   'reply_to', case when public.zella_valid_email(v_reply) then v_reply end));
end $$;

-- who may call what (SEC-6, SEC-7): unchanged, everything new is server only
revoke all on function public.zella_business_email_mailbox_cap(text,text), public.zella_business_email_paced(text,uuid,timestamptz),
  public.zella_business_email_mailbox_saved(uuid,uuid,text,text,text,text) from public, anon, authenticated;
grant execute on function public.zella_business_email_mailbox_cap(text,text), public.zella_business_email_paced(text,uuid,timestamptz),
  public.zella_business_email_mailbox_saved(uuid,uuid,text,text,text,text) to service_role;

do $$
declare f record;
begin
  for f in select * from (values ('public.zella_business_email_sender(uuid)', '4869cab9ec6319740667de295508c884'), ('public.zella_business_email_status(uuid)', '59e30c139362c44863045142ee98aa43'),
                                 ('public.zella_business_email_mailbox_cap(text,text)', 'bdff7c09430adeeb89d57595ca12cd67'), ('public.zella_business_email_paced(text,uuid,timestamptz)', '9c86894efd14ee848702d00e15dacf76'),
                                 ('public.zella_business_email_mailbox_saved(uuid,uuid,text,text,text,text)', '0b43ade45c628f71091efbbcdf71b73d')) as t(sig, want) loop
    if md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then raise exception 'VERSION_MISMATCH: % did not come out as this file''s version', f.sig; end if;
  end loop;
end $$;

commit;
