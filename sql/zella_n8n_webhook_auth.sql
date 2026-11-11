-- zella_n8n_webhook_auth: Resend webhooks must pass the URL key and the signature check before any provider
-- fetch or database write (CodeRabbit review #46). Replaces zella_record_email_event_signed and
-- zella_receive_inbound_email_signed from sql/zella_resend_signature.sql and adds zella_n8n_resend_auth.
-- Depends on: zella_resend_signature.sql. Callable by: service_role only (no change for anon or signed-in users).
-- Verify: tests/n8n_webhook_auth/run.sh on an isolated copy. Roll back: sql/rollback/zella_n8n_webhook_auth_rollback.sql.
-- Version guard: stops unless both replaced functions match the definitions this was written against (or this
-- migration's own, so it is safe to run twice).
begin;
do $guard$
declare r record;
begin
  for r in select * from (values
      ('public.zella_record_email_event_signed(text,jsonb,text,jsonb)', array['ba28dce846ec37695b45c1ab32ffe538','aa0ae322d2fa5e84f508d74f9ab8506d']),
      ('public.zella_receive_inbound_email_signed(text,jsonb,jsonb)', array['7cfc7088f1f5dbf16d5f2c0efc2445b4','d14eabc82402a91957326778f881f202'])) v(sig, ok)
  loop
    if to_regprocedure(r.sig) is null or not (md5(pg_get_functiondef(to_regprocedure(r.sig))) = any(r.ok)) then
      raise exception 'VERSION_MISMATCH: % is not the definition this migration was written against', r.sig;
    end if;
  end loop;
end $guard$;

create or replace function public.zella_n8n_resend_auth(p_key text, p_endpoint text, p_id text, p_timestamp text, p_signature text, p_raw text)
returns text language plpgsql stable security definer set search_path = public, extensions as $$
declare v_secret text; v_key bytea; v_expect text; v_part text; v_ts bigint; v_url_key text;
begin
  if p_endpoint not in ('inbound', 'events') or p_endpoint is null then return 'bad'; end if;
  select decrypted_secret into v_url_key from vault.decrypted_secrets where name = 'zella_resend_webhook_key' limit 1;
  if nullif(v_url_key, '') is null or p_key is null or
     sha256(convert_to(p_key, 'utf8')) <> sha256(convert_to(v_url_key, 'utf8')) then return 'bad'; end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets
    where name = case p_endpoint when 'inbound' then 'zella_resend_inbound_signing_secret' else 'zella_resend_signing_secret' end limit 1;
  if nullif(v_secret, '') is null then return 'bad'; end if;
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

revoke execute on function public.zella_n8n_resend_auth(text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.zella_n8n_resend_auth(text, text, text, text, text, text) to service_role;

-- Enforce the same requirement for direct signed-RPC callers, too.
create or replace function public.zella_record_email_event_signed(p_key text, p_event jsonb, p_event_id text, p_sig jsonb)
returns text language plpgsql security definer set search_path = public, extensions as $$
begin
  if public.zella_n8n_resend_auth(p_key, 'events', p_sig ->> 'id', p_sig ->> 'timestamp', p_sig ->> 'signature', p_sig ->> 'raw') <> 'ok' then return 'unauthorized'; end if;
  return public.zella_record_email_event(p_key, p_event, p_event_id);
end $$;
revoke execute on function public.zella_record_email_event_signed(text, jsonb, text, jsonb) from public, anon, authenticated;
grant execute on function public.zella_record_email_event_signed(text, jsonb, text, jsonb) to service_role;

create or replace function public.zella_receive_inbound_email_signed(p_key text, p_message jsonb, p_sig jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if public.zella_n8n_resend_auth(p_key, 'inbound', p_sig ->> 'id', p_sig ->> 'timestamp', p_sig ->> 'signature', p_sig ->> 'raw') <> 'ok' then
    return jsonb_build_object('result', 'unauthorized');
  end if;
  return public.zella_receive_inbound_email(p_key, p_message);
end $$;
revoke execute on function public.zella_receive_inbound_email_signed(text, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.zella_receive_inbound_email_signed(text, jsonb, jsonb) to service_role;

commit;
