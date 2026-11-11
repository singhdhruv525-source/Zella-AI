-- Before running: unpublish or revert BOTH the Inbound Email and Email Events workflows.
-- Rollback for sql/zella_n8n_webhook_auth.sql: restores both signed functions exactly as sql/zella_resend_signature.sql
-- defined them and removes zella_n8n_resend_auth. Deletes no data. One transaction.
begin;
drop function if exists public.zella_n8n_resend_auth(text, text, text, text, text, text);
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
commit;
