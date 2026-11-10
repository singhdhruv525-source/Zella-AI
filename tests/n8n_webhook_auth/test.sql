-- Behaviour checks for zella_n8n_resend_auth. Runs inside one transaction that is rolled back, with obviously fake
-- secrets created only in this isolated copy.
begin;
select vault.create_secret('test-url-key', 'zella_resend_webhook_key');
select vault.create_secret('whsec_' || encode(convert_to('test-signing-secret', 'utf8'), 'base64'), 'zella_resend_signing_secret');
create temp table t(ts text, sig text);
insert into t select extract(epoch from now())::bigint::text,
  'v1,' || encode(extensions.hmac(convert_to('msg_1.' || extract(epoch from now())::bigint::text || '.{"a":1}', 'utf8'), convert_to('test-signing-secret', 'utf8'), 'sha256'), 'base64');
select case when public.zella_n8n_resend_auth('test-url-key', 'events', 'msg_1', ts, sig, '{"a":1}') = 'ok' then 'PASS a correct key and signature is accepted' else 'FAIL correct signature refused' end from t;
select case when public.zella_n8n_resend_auth('test-url-key', 'events', 'msg_1', ts, 'v0,x ' || sig, '{"a":1}') = 'ok' then 'PASS any v1 entry among several signatures is accepted' else 'FAIL multi-signature header refused' end from t;
select case when public.zella_n8n_resend_auth('wrong-key', 'events', 'msg_1', ts, sig, '{"a":1}') = 'bad' then 'PASS a wrong URL key is refused' else 'FAIL wrong key accepted' end from t;
select case when public.zella_n8n_resend_auth('test-url-key', 'events', 'msg_1', ts, sig, '{"a":2}') = 'bad' then 'PASS a changed body is refused' else 'FAIL tampered body accepted' end from t;
select case when public.zella_n8n_resend_auth('test-url-key', 'events', 'msg_1', (ts::bigint - 600)::text, sig, '{"a":1}') = 'bad' then 'PASS a timestamp outside 5 minutes is refused' else 'FAIL old timestamp accepted' end from t;
select case when public.zella_n8n_resend_auth('test-url-key', 'inbound', 'msg_1', ts, sig, '{"a":1}') = 'bad' then 'PASS inbound is refused while its signing secret is missing' else 'FAIL inbound accepted without its secret' end from t;
select case when public.zella_n8n_resend_auth('test-url-key', 'other', 'msg_1', ts, sig, '{"a":1}') = 'bad' then 'PASS an unknown endpoint is refused' else 'FAIL unknown endpoint accepted' end from t;
select case when public.zella_record_email_event_signed('test-url-key', '{}'::jsonb, 'e1', jsonb_build_object('id', 'msg_1', 'timestamp', ts, 'signature', 'v1,bad', 'raw', '{"a":1}')) = 'unauthorized' then 'PASS the signed event function refuses a bad signature' else 'FAIL signed event accepted a bad signature' end from t;
select case when public.zella_receive_inbound_email_signed('test-url-key', '{}'::jsonb, jsonb_build_object('id', 'msg_1', 'timestamp', ts, 'signature', 'v1,bad', 'raw', '{"a":1}')) ->> 'result' = 'unauthorized' then 'PASS the signed inbound function refuses a bad signature' else 'FAIL signed inbound accepted a bad signature' end from t;
select case when not has_function_privilege(r, 'public.zella_n8n_resend_auth(text,text,text,text,text,text)', 'execute') then 'PASS ' || r || ' cannot call zella_n8n_resend_auth' else 'FAIL ' || r || ' can call zella_n8n_resend_auth' end from unnest(array['anon', 'authenticated']) r;
rollback;
