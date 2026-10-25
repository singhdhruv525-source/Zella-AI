-- Zella - Resend webhook signatures (Svix). Adds a real signature check on top of the secret key in the webhook address.
-- Needs: sql/zella_email_events.sql and sql/zella_email_inbound.sql.
-- One-time step at go-live (value comes from Resend > Webhooks > Signing secret, starts with whsec_):
--   select vault.create_secret('whsec_PASTE_FROM_RESEND', 'zella_resend_signing_secret');
-- Until that secret exists the check is off and only the key in the address protects the webhooks (as before).
-- Once it exists, a missing, wrong or old (over 5 minutes) signature changes nothing.

create or replace function public.zella_resend_signature_ok(p_id text, p_timestamp text, p_signature text, p_raw text)
returns text language plpgsql stable security definer set search_path = public, extensions as $$
declare v_secret text; v_key bytea; v_expect text; v_part text; v_ts bigint;
begin
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'zella_resend_signing_secret' limit 1;
  if v_secret is null or v_secret = '' then return 'off'; end if;
  if coalesce(p_id, '') = '' or coalesce(p_timestamp, '') !~ '^[0-9]{9,12}$' or coalesce(p_signature, '') = '' or p_raw is null then return 'bad'; end if;
  v_ts := p_timestamp::bigint;
  if abs(extract(epoch from now())::bigint - v_ts) > 300 then return 'bad'; end if;
  begin
    v_key := decode(regexp_replace(v_secret, '^whsec_', ''), 'base64');
  exception when others then return 'bad'; end;
  v_expect := encode(hmac(convert_to(p_id || '.' || p_timestamp || '.' || p_raw, 'utf8'), v_key, 'sha256'), 'base64');
  -- the header holds one or more "v1,<signature>" entries separated by spaces
  foreach v_part in array regexp_split_to_array(trim(left(p_signature, 500)), '\s+') loop
    if split_part(v_part, ',', 1) = 'v1'
       and encode(sha256(convert_to(split_part(v_part, ',', 2), 'utf8')), 'hex') = encode(sha256(convert_to(v_expect, 'utf8')), 'hex') then
      return 'ok';
    end if;
  end loop;
  return 'bad';
end $$;
revoke execute on function public.zella_resend_signature_ok(text, text, text, text) from public, anon, authenticated;
grant execute on function public.zella_resend_signature_ok(text, text, text, text) to service_role;

-- p_sig = { "id": svix-id, "timestamp": svix-timestamp, "signature": svix-signature, "raw": exact body text }
create or replace function public.zella_record_email_event_signed(p_key text, p_event jsonb, p_event_id text, p_sig jsonb)
returns text language plpgsql security definer set search_path = public, extensions as $$
begin
  if public.zella_resend_signature_ok(p_sig ->> 'id', p_sig ->> 'timestamp', p_sig ->> 'signature', p_sig ->> 'raw') = 'bad' then return 'unauthorized'; end if;
  return public.zella_record_email_event(p_key, p_event, p_event_id);
end $$;
revoke execute on function public.zella_record_email_event_signed(text, jsonb, text, jsonb) from public, anon, authenticated;
grant execute on function public.zella_record_email_event_signed(text, jsonb, text, jsonb) to service_role;

create or replace function public.zella_receive_inbound_email_signed(p_key text, p_message jsonb, p_sig jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if public.zella_resend_signature_ok(p_sig ->> 'id', p_sig ->> 'timestamp', p_sig ->> 'signature', p_sig ->> 'raw') = 'bad' then
    return jsonb_build_object('result', 'unauthorized');
  end if;
  return public.zella_receive_inbound_email(p_key, p_message);
end $$;
revoke execute on function public.zella_receive_inbound_email_signed(text, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.zella_receive_inbound_email_signed(text, jsonb, jsonb) to service_role;
