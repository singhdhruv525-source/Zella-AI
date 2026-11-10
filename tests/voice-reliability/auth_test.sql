-- zella_vapi_authenticate on the staging copy: Vapi's HMAC format ("{timestamp}.{body}", sha256, hex, x-signature and
-- x-timestamp), the 5-minute window, the replay cache, bearer mode, and failing closed. Test secrets only.
delete from vault.decrypted_secrets where name like 'zella_vapi_%';
delete from platform_settings where key = 'vapi_auth_mode';
delete from vapi_request_receipts;
do $$
declare
  k text := 'test-hmac-secret-0123456789abcdef'; body text := '{"message":{"type":"status-update","status":"ringing"}}';
  ts text; sig text; r text;
begin
  ts := extract(epoch from now())::bigint::text;
  sig := encode(extensions.hmac(convert_to(ts || '.' || body, 'utf8'), convert_to(k, 'utf8'), 'sha256'), 'hex');
  r := zella_vapi_authenticate(body, jsonb_build_object('x-signature', sig, 'x-timestamp', ts));
  assert r = 'not_configured', 'no secret: ' || r;
  raise notice 'PASS no secret in Vault: every request refused (not_configured), never let through';

  insert into vault.decrypted_secrets values ('zella_vapi_hmac_secret', k);
  assert zella_vapi_authenticate(body, jsonb_build_object('x-signature', sig, 'x-timestamp', ts)) = 'ok';
  raise notice 'PASS correctly signed request accepted';
  assert zella_vapi_authenticate(body, jsonb_build_object('x-signature', sig, 'x-timestamp', ts)) = 'replayed';
  raise notice 'PASS the same signed request a second time: replayed';
  assert zella_vapi_authenticate(body || ' ', jsonb_build_object('X-Signature', sig, 'X-Timestamp', ts)) = 'bad_signature';
  raise notice 'PASS body changed by one byte: bad_signature';
  assert zella_vapi_authenticate(body, jsonb_build_object('x-signature', sig, 'x-timestamp', (ts::bigint + 1)::text)) = 'bad_signature';
  raise notice 'PASS timestamp changed: bad_signature (the timestamp is signed)';
  assert zella_vapi_authenticate(body, '{}') = 'unauthenticated' and zella_vapi_authenticate(body, null) = 'unauthenticated'
     and zella_vapi_authenticate(body, jsonb_build_object('x-signature', sig)) = 'unauthenticated';
  raise notice 'PASS missing signature or timestamp: unauthenticated';
  assert zella_vapi_authenticate(body, jsonb_build_object('x-signature', 'zz', 'x-timestamp', ts)) = 'bad_signature'
     and zella_vapi_authenticate(body, jsonb_build_object('x-signature', sig, 'x-timestamp', 'yesterday')) = 'bad_signature'
     and zella_vapi_authenticate(body, jsonb_build_object('x-signature', jsonb_build_array(sig), 'x-timestamp', ts)) = 'unauthenticated';
  raise notice 'PASS malformed signature, timestamp or header types refused';
  assert zella_vapi_authenticate(body, jsonb_build_object('x-signature', encode(extensions.hmac(convert_to(ts || '.' || body, 'utf8'), convert_to('wrong-secret-0123456789', 'utf8'), 'sha256'), 'hex'), 'x-timestamp', ts)) = 'bad_signature';
  raise notice 'PASS signed with another secret: bad_signature';

  ts := (extract(epoch from now())::bigint - 400)::text;
  assert zella_vapi_authenticate(body, jsonb_build_object('x-signature', encode(extensions.hmac(convert_to(ts || '.' || body, 'utf8'), convert_to(k, 'utf8'), 'sha256'), 'hex'), 'x-timestamp', ts)) = 'expired';
  ts := (extract(epoch from now())::bigint + 400)::text;
  assert zella_vapi_authenticate(body, jsonb_build_object('x-signature', encode(extensions.hmac(convert_to(ts || '.' || body, 'utf8'), convert_to(k, 'utf8'), 'sha256'), 'hex'), 'x-timestamp', ts)) = 'expired';
  raise notice 'PASS correctly signed but 400 s old, or 400 s in the future: expired';
  ts := (extract(epoch from now()) * 1000)::bigint::text;
  assert zella_vapi_authenticate(body, jsonb_build_object('x-signature', upper(encode(extensions.hmac(convert_to(ts || '.' || body, 'utf8'), convert_to(k, 'utf8'), 'sha256'), 'hex')), 'x-timestamp', ts)) = 'ok';
  raise notice 'PASS millisecond timestamp and upper-case hex accepted (unit not stated by Vapi)';
  assert zella_vapi_authenticate(body, jsonb_build_object('authorization', 'Bearer ' || k)) = 'unauthenticated';
  raise notice 'PASS hmac mode: a bearer token alone is not enough';
  body := '{"message":{"type":"tool-calls","text":"caf' || chr(233) || ' ' || chr(128512) || '"}}';
  ts := extract(epoch from now())::bigint::text;
  assert zella_vapi_authenticate(body, jsonb_build_object('x-signature', encode(extensions.hmac(convert_to(ts || '.' || body, 'utf8'), convert_to(k, 'utf8'), 'sha256'), 'hex'), 'x-timestamp', ts)) = 'ok';
  raise notice 'PASS non-ASCII body (accents, emoji) verified over its UTF-8 bytes';

  -- bearer mode
  insert into platform_settings (key, value) values ('vapi_auth_mode', '"bearer"');
  assert zella_vapi_authenticate(body, jsonb_build_object('authorization', 'Bearer x')) = 'not_configured';
  insert into vault.decrypted_secrets values ('zella_vapi_bearer_token', 'test-bearer-token-0123456789');
  assert zella_vapi_authenticate(body, jsonb_build_object('Authorization', 'Bearer test-bearer-token-0123456789')) = 'ok'
     and zella_vapi_authenticate(body, jsonb_build_object('authorization', 'Bearer test-bearer-token-012345678')) = 'bad_signature'
     and zella_vapi_authenticate(body, jsonb_build_object('authorization', 'test-bearer-token-0123456789')) = 'unauthenticated'
     and zella_vapi_authenticate(body, '{}') = 'unauthenticated';
  raise notice 'PASS bearer mode: exact token only (no expiry or replay protection in this mode)';
  update platform_settings set value = '"none"' where key = 'vapi_auth_mode';
  assert zella_vapi_authenticate(body, jsonb_build_object('authorization', 'Bearer test-bearer-token-0123456789')) = 'not_configured';
  raise notice 'PASS unknown mode: everything refused (fails closed; there is no off switch)';
  delete from platform_settings where key = 'vapi_auth_mode';

  -- permissions: only the service role may call it, and nobody can read the receipts directly
  assert not has_function_privilege('anon', 'public.zella_vapi_authenticate(text, jsonb)', 'execute')
     and not has_function_privilege('authenticated', 'public.zella_vapi_authenticate(text, jsonb)', 'execute')
     and not has_table_privilege('anon', 'public.vapi_request_receipts', 'select')
     and not has_table_privilege('authenticated', 'public.vapi_request_receipts', 'select');
  raise notice 'PASS anon and signed-in users can neither call the check nor read the receipts';
end $$;
