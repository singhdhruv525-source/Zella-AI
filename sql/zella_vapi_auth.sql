-- Zella - Vapi request authentication (voice reliability phase 2, 2026-10-27). Safe to re-run. Needs pgcrypto (extensions)
-- and Supabase Vault. Changes and deletes no existing rows. Design: docs/VOICE_RELIABILITY.md ("Phase 2").
--
-- Every request Vapi sends to Zella (tool calls, transfer destination requests, status updates, end-of-call reports) is
-- checked HERE before anything else happens. The secret lives only in Vault: the edge function and n8n hand over the
-- exact request bytes and headers and get back one word. They never see the secret.
--
-- Mode (platform setting vapi_auth_mode):
--   'hmac'   (default, recommended) Vapi credential of type HMAC: algorithm sha256, signature header x-signature,
--            timestamp header x-timestamp, payload "{timestamp}.{body}", hex, no prefix (Vapi's defaults).
--            Requests older or newer than 5 minutes are refused, and each signed request is accepted ONCE (replay cache).
--   'bearer' Vapi credential of type Bearer (Authorization: Bearer <token>). A fixed token: no expiry and no replay
--            protection. Only for when HMAC can't be used.
-- Anything else, or a mode whose secret is missing, refuses every request (fails closed). There is no "off".
--
-- One-time steps at go-live (values never go in git, chat or the browser):
--   select vault.create_secret('<random 32+ byte secret>', 'zella_vapi_hmac_secret');   -- same value in the Vapi credential
--   -- or, only for bearer mode: select vault.create_secret('<token>', 'zella_vapi_bearer_token');
--     insert into platform_settings (key, value) values ('vapi_auth_mode', '"bearer"') on conflict (key) do update set value = excluded.value;
--
-- Rollback: drop function zella_vapi_authenticate(text, jsonb); drop table vapi_request_receipts.

create table if not exists public.vapi_request_receipts (
  signature_hash text primary key,
  received_at timestamptz not null default now()
);
create index if not exists vapi_request_receipts_received_idx on public.vapi_request_receipts (received_at);
alter table public.vapi_request_receipts enable row level security;   -- no policies: service role only
revoke all on public.vapi_request_receipts from anon, authenticated;

-- p_raw: the request body exactly as received. p_headers: request headers (names in any case).
-- Returns ok | unauthenticated | bad_signature | expired | replayed | not_configured.
create or replace function public.zella_vapi_authenticate(p_raw text, p_headers jsonb)
returns text language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_mode text := coalesce(public.zella_setting('vapi_auth_mode', '"hmac"'::jsonb) #>> '{}', 'hmac');
  v_h jsonb := '{}'::jsonb; v_k text; v_v jsonb;
  v_secret text; v_sig text; v_ts text; v_tsn numeric; v_expect text; v_hash text; v_new int;
begin
  -- header names are case-insensitive; only short string values are read
  if jsonb_typeof(p_headers) = 'object' then
    for v_k, v_v in select * from jsonb_each(p_headers) loop
      if jsonb_typeof(v_v) = 'string' and length(v_k) <= 100 then v_h := v_h || jsonb_build_object(lower(v_k), left(v_v #>> '{}', 1000)); end if;
    end loop;
  end if;
  if p_raw is null or length(p_raw) > 1048576 then return 'unauthenticated'; end if;

  if v_mode = 'bearer' then
    select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'zella_vapi_bearer_token' limit 1;
    if coalesce(length(v_secret), 0) < 16 then return 'not_configured'; end if;
    v_sig := coalesce(v_h ->> 'authorization', '');
    if v_sig !~* '^bearer ' then return 'unauthenticated'; end if;
    -- compare digests, not the strings, so timing reveals nothing about the token
    return case when digest(convert_to(substr(v_sig, 8), 'utf8'), 'sha256') = digest(convert_to(v_secret, 'utf8'), 'sha256') then 'ok' else 'bad_signature' end;
  end if;
  if v_mode <> 'hmac' then return 'not_configured'; end if;

  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'zella_vapi_hmac_secret' limit 1;
  if coalesce(length(v_secret), 0) < 16 then return 'not_configured'; end if;
  v_sig := lower(coalesce(v_h ->> 'x-signature', ''));
  v_ts := coalesce(v_h ->> 'x-timestamp', '');
  if v_sig = '' or v_ts = '' then return 'unauthenticated'; end if;
  if v_sig !~ '^[0-9a-f]{64}$' or v_ts !~ '^[0-9]{9,13}$' then return 'bad_signature'; end if;

  v_expect := encode(hmac(convert_to(v_ts || '.' || p_raw, 'utf8'), convert_to(v_secret, 'utf8'), 'sha256'), 'hex');
  if digest(v_sig, 'sha256') <> digest(v_expect, 'sha256') then return 'bad_signature'; end if;

  -- The timestamp is signed, so it can't be changed. Seconds or milliseconds (Vapi does not state the unit).
  v_tsn := v_ts::numeric; if v_tsn >= 1e12 then v_tsn := v_tsn / 1000; end if;
  if abs(extract(epoch from now()) - v_tsn) > 300 then return 'expired'; end if;

  -- Each signed request once. Receipts older than the 5-minute window can't be replayed anyway (they'd be expired).
  v_hash := encode(digest(v_sig, 'sha256'), 'hex');
  insert into public.vapi_request_receipts (signature_hash) values (v_hash) on conflict (signature_hash) do nothing;
  get diagnostics v_new = row_count;
  if v_new = 0 then return 'replayed'; end if;
  if random() < 0.02 then
    delete from public.vapi_request_receipts where received_at < now() - interval '15 minutes';
  end if;
  return 'ok';
end $$;
revoke execute on function public.zella_vapi_authenticate(text, jsonb) from public, anon, authenticated;
grant execute on function public.zella_vapi_authenticate(text, jsonb) to service_role;
