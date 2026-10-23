-- Zella - email delivery events (bounces and spam complaints). Safe to run more than once.
-- Needs zella_email_sender.sql (email_messages) and zella_run_all.sql (zella_notify).
-- Resend tells us what happened to each email. This keeps the sender list clean and protects the sending domain:
--   * delivered            -> the message is marked delivered
--   * bounced (permanent)  -> the address is invalid: that email address is never emailed again (for every business),
--                             the message is marked failed, and the business is told so they can fix the address
--   * bounced (temporary)  -> recorded only; the address stays usable
--   * complained (spam)    -> that person is never emailed again by that business, and the business is told
-- Texts and calls are not affected. A person who is on the do-not-email list is skipped by every email sender already.
-- The webhook is protected by a secret key in its address, checked here against a Vault secret (see the end of this file).

alter table public.customers add column if not exists email_suppressed_at timestamptz, add column if not exists email_suppressed_reason text;

create table if not exists public.email_events (
  id uuid primary key default gen_random_uuid(),
  provider_event_id text not null unique,
  type text not null,
  email_message_id uuid,
  business_id uuid,
  to_email text,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists email_events_created_idx on public.email_events (created_at desc);
alter table public.email_events enable row level security;
revoke all on public.email_events from anon, authenticated;

create or replace function public.zella_record_email_event(p_key text, p_event jsonb, p_event_id text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare
  v_secret text; v_type text; v_data jsonb; v_ext text; v_to text; v_msg record; v_bounce text; v_n integer; v_cust record;
begin
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'zella_resend_webhook_key' limit 1;
  if v_secret is null or v_secret = '' then return 'not_configured'; end if;
  if p_key is null or encode(sha256(convert_to(p_key, 'utf8')), 'hex') <> encode(sha256(convert_to(v_secret, 'utf8')), 'hex') then return 'unauthorized'; end if;
  if p_event is null or jsonb_typeof(p_event) <> 'object' or nullif(p_event_id, '') is null then return 'ignored'; end if;

  v_type := left(coalesce(p_event ->> 'type', ''), 60);
  v_data := case when jsonb_typeof(p_event -> 'data') = 'object' then p_event -> 'data' else '{}'::jsonb end;
  v_ext := nullif(left(coalesce(v_data ->> 'email_id', ''), 200), '');
  v_to := lower(nullif(trim(left(coalesce(case when jsonb_typeof(v_data -> 'to') = 'array' then v_data -> 'to' ->> 0 else v_data ->> 'to' end, ''), 300)), ''));
  v_bounce := lower(coalesce(v_data -> 'bounce' ->> 'type', ''));

  select m.id, m.business_id, m.customer_id, m.to_email into v_msg from public.email_messages m
   where v_ext is not null and m.external_message_id = v_ext and m.direction = 'outbound' limit 1;
  v_to := coalesce(v_to, lower(v_msg.to_email));

  insert into public.email_events (provider_event_id, type, email_message_id, business_id, to_email, detail)
  values (left(p_event_id, 200), v_type, v_msg.id, v_msg.business_id, v_to,
          jsonb_build_object('bounce_type', nullif(v_bounce, ''), 'bounce_sub_type', v_data -> 'bounce' ->> 'subType'))
  on conflict (provider_event_id) do nothing;
  if not found then return 'duplicate'; end if;
  if v_msg.id is null and v_to is null then return 'ignored'; end if;

  if v_type = 'email.delivered' then
    update public.email_messages set status = 'delivered', delivered_at = now(), updated_at = now() where id = v_msg.id and status in ('sent', 'queued');
    return 'delivered';
  end if;

  if v_type = 'email.bounced' and v_bounce in ('permanent', 'hard') then
    if v_msg.id is not null then
      update public.email_messages set status = 'failed', metadata = metadata || jsonb_build_object('bounced', true), updated_at = now() where id = v_msg.id;
    end if;
    if v_to is not null then
      for v_cust in
        update public.customers c set do_not_email = true, email_suppressed_at = now(), email_suppressed_reason = 'bounced', updated_at = now()
         where lower(c.email) = v_to and not coalesce(c.do_not_email, false)
        returning c.business_id, c.id
      loop
        perform public.zella_notify(v_cust.business_id, 'email_bounced', 'An email address does not work',
          'An email to ' || v_to || ' could not be delivered, so we will not email that address again. Please check the address with the customer.', 'info', 'customers', v_cust.id);
      end loop;
    end if;
    return 'bounced';
  end if;

  if v_type = 'email.complained' then
    if v_msg.business_id is not null and v_to is not null then
      for v_cust in
        update public.customers c set do_not_email = true, email_suppressed_at = now(), email_suppressed_reason = 'complained', updated_at = now()
         where c.business_id = v_msg.business_id and lower(c.email) = v_to and not coalesce(c.do_not_email, false)
        returning c.business_id, c.id
      loop
        perform public.zella_notify(v_cust.business_id, 'email_complaint', 'A customer marked an email as spam',
          v_to || ' marked an email as spam, so we will not email them again.', 'warning', 'customers', v_cust.id);
      end loop;
    end if;
    return 'complained';
  end if;

  return 'recorded';
end $$;
revoke execute on function public.zella_record_email_event(text, jsonb, text) from public, anon, authenticated;
grant execute on function public.zella_record_email_event(text, jsonb, text) to service_role;

-- One-time step (run once in the SQL editor with your own long random value; do not paste it anywhere else but the
-- Resend webhook address you will be given):
--   select vault.create_secret('PASTE_A_LONG_RANDOM_VALUE', 'zella_resend_webhook_key');
