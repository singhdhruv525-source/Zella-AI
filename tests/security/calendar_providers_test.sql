-- Calendar connections by owners and admins, Google and Outlook (zella_calendar_providers.sql).
\set ON_ERROR_STOP on
begin;
insert into auth.users (id, email, email_confirmed_at) values
 ('ec000000-0000-0000-0000-00000000000a', 'own@cal.test', now()), ('ec000000-0000-0000-0000-00000000000b', 'adm@cal.test', now()),
 ('ec000000-0000-0000-0000-00000000000c', 'stf@cal.test', now()), ('ec000000-0000-0000-0000-00000000000d', 'other@cal.test', now());
insert into public.businesses (id, name, timezone, is_active, onboarding_status) values
 ('ec000000-0000-0000-0000-0000000000a1', 'Cal Biz', 'UTC', true, 'active'), ('ec000000-0000-0000-0000-0000000000b1', 'Other Biz', 'UTC', true, 'active');
insert into public.business_members (business_id, user_id, role, status) values
 ('ec000000-0000-0000-0000-0000000000a1', 'ec000000-0000-0000-0000-00000000000a', 'owner', 'active'),
 ('ec000000-0000-0000-0000-0000000000a1', 'ec000000-0000-0000-0000-00000000000b', 'admin', 'active'),
 ('ec000000-0000-0000-0000-0000000000a1', 'ec000000-0000-0000-0000-00000000000c', 'staff', 'active'),
 ('ec000000-0000-0000-0000-0000000000b1', 'ec000000-0000-0000-0000-00000000000d', 'owner', 'active');

-- server: connect Google for the owner; the token goes to Vault, never into the table
do $$ declare v_id uuid; begin
  v_id := public.zella_calendar_connect_provider('ec000000-0000-0000-0000-0000000000a1', 'google', 'ec000000-0000-0000-0000-00000000000a', 'own@cal.test', 'rt-google-secret');
  assert (select provider || ':' || status from public.calendar_connections where id = v_id) = 'google:active', 'google active';
  assert (select decrypted_secret from vault.decrypted_secrets where name = 'zella_cal_google_ec000000-0000-0000-0000-0000000000a1') = 'rt-google-secret', 'token in vault';
  assert not exists (select 1 from public.calendar_connections c where row_to_json(c)::text like '%rt-google-secret%'), 'no token in the table';
  -- connecting again (new token) updates in place
  perform public.zella_calendar_connect_provider('ec000000-0000-0000-0000-0000000000a1', 'google', 'ec000000-0000-0000-0000-00000000000a', 'own@cal.test', 'rt-google-2');
  assert (select decrypted_secret from vault.decrypted_secrets where name = 'zella_cal_google_ec000000-0000-0000-0000-0000000000a1') = 'rt-google-2', 'token replaced';
  assert (select count(*) from public.calendar_connections where business_id = 'ec000000-0000-0000-0000-0000000000a1') = 1, 'one row';
  -- staff, or someone from another business, can't be the one who connected it
  begin perform public.zella_calendar_connect_provider('ec000000-0000-0000-0000-0000000000a1', 'outlook', 'ec000000-0000-0000-0000-00000000000c', 'x', 'rt'); raise exception 'staff connected';
  exception when others then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end;
  begin perform public.zella_calendar_connect_provider('ec000000-0000-0000-0000-0000000000a1', 'outlook', 'ec000000-0000-0000-0000-00000000000d', 'x', 'rt'); raise exception 'outsider connected';
  exception when others then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end;
  begin perform public.zella_calendar_connect_provider('ec000000-0000-0000-0000-0000000000a1', 'yahoo', 'ec000000-0000-0000-0000-00000000000a', 'x', 'rt'); raise exception 'bad provider';
  exception when others then if sqlerrm <> 'BAD_PROVIDER' then raise; end if; end;
  begin perform public.zella_calendar_connect_provider('ec000000-0000-0000-0000-0000000000a1', 'outlook', 'ec000000-0000-0000-0000-00000000000a', 'x', ' '); raise exception 'empty token';
  exception when others then if sqlerrm <> 'NO_TOKEN' then raise; end if; end;
end $$;

-- a busy time from Google, then the admin switches to Outlook: Google is disconnected, its token and busy times gone
do $$ declare g uuid := (select id from public.calendar_connections where business_id = 'ec000000-0000-0000-0000-0000000000a1' and provider = 'google'); begin
  insert into public.blocked_times (business_id, title, start_time, end_time, source, external_id, connection_id)
  values ('ec000000-0000-0000-0000-0000000000a1', 'Busy', now() + interval '1 day', now() + interval '1 day 1 hour', 'calendar', 'g-ev-1', g);
  perform public.zella_calendar_connect_provider('ec000000-0000-0000-0000-0000000000a1', 'outlook', 'ec000000-0000-0000-0000-00000000000b', 'adm@corp.test', 'rt-ms');
  assert (select string_agg(provider || ':' || status, ',' order by provider) from public.calendar_connections where business_id = 'ec000000-0000-0000-0000-0000000000a1') = 'google:disconnected,outlook:active', 'switched';
  assert not exists (select 1 from vault.secrets where name = 'zella_cal_google_ec000000-0000-0000-0000-0000000000a1'), 'google token deleted';
  assert not exists (select 1 from public.blocked_times where connection_id = g), 'google busy times removed';
end $$;

-- the claims say which provider (sync is live in this test only)
insert into public.platform_settings (key, value) values ('calendar_sync_live', 'true'::jsonb) on conflict (key) do update set value = excluded.value;
do $$ declare r jsonb; begin
  r := public.zella_claim_calendar_pulls(5);
  assert r -> 0 ->> 'provider' = 'outlook' and r -> 0 ->> 'refresh_token' = 'rt-ms', 'pull claim: ' || r::text;
end $$;

-- members see the connection's status and account, never the token; another business sees nothing
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"ec000000-0000-0000-0000-00000000000c","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  assert (select count(*) from public.calendar_connections) = 2, 'staff see the business''s connections';
  begin perform vault_secret_name from public.calendar_connections; raise exception 'staff read the secret name';
  exception when insufficient_privilege then null; end;
  assert not public.zella_calendar_can_manage('ec000000-0000-0000-0000-0000000000a1'), 'staff can''t manage';
  begin perform public.zella_calendar_disconnect('ec000000-0000-0000-0000-0000000000a1'); raise exception 'staff disconnected';
  exception when others then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end;
  begin perform public.zella_calendar_connect_provider('ec000000-0000-0000-0000-0000000000a1', 'google', 'ec000000-0000-0000-0000-00000000000c', 'x', 'rt'); raise exception 'member called the server function';
  exception when insufficient_privilege then null; end;
end $$;
select set_config('request.jwt.claims', '{"sub":"ec000000-0000-0000-0000-00000000000d","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  assert (select count(*) from public.calendar_connections where business_id = 'ec000000-0000-0000-0000-0000000000a1') = 0, 'other business sees nothing';
  begin perform public.zella_calendar_disconnect('ec000000-0000-0000-0000-0000000000a1'); raise exception 'outsider disconnected';
  exception when others then if sqlerrm <> 'NOT_ALLOWED' then raise; end if; end;
end $$;
-- the owner disconnects: token deleted, pending copies skipped, audited
select set_config('request.jwt.claims', '{"sub":"ec000000-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1"}', true);
do $$ begin
  assert public.zella_calendar_can_manage('ec000000-0000-0000-0000-0000000000a1'), 'owner can manage';
  assert public.zella_calendar_disconnect('ec000000-0000-0000-0000-0000000000a1') = 1, 'one disconnected';
end $$;
reset role;
do $$ begin
  assert not exists (select 1 from vault.secrets where name like 'zella_cal_%ec000000-0000-0000-0000-0000000000a1'), 'all tokens deleted';
  assert (select count(*) from public.calendar_connections where business_id = 'ec000000-0000-0000-0000-0000000000a1' and status = 'active') = 0, 'none active';
  assert (select count(*) from public.audit_logs where business_id = 'ec000000-0000-0000-0000-0000000000a1' and action in ('calendar_connected', 'calendar_disconnected')) = 4, 'audited';
  assert not exists (select 1 from public.audit_logs where business_id = 'ec000000-0000-0000-0000-0000000000a1' and coalesce(new_data, '{}')::text || coalesce(old_data, '{}')::text like '%rt-%'), 'no token in the audit log';
end $$;
select 'PASS calendar connections: owner/admin only (checked again when the sign-in finishes), Google or Outlook, one active at a time, tokens only in Vault and deleted on disconnect, busy times removed, claims name the provider, audited';
rollback;
