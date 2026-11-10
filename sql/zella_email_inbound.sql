-- Zella - inbound email, reply sorting, CRM linking, and text delivery receipts. Safe to run more than once.
-- Needs zella_email_sender.sql, zella_email_events.sql (Vault key zella_resend_webhook_key), zella_inbox.sql, zella_run_all.sql.
-- How it works:
--   * every business gets its own inbound address  <token>@<inbound_email_domain>  (platform setting inbound_email_domain).
--     Emails Zella sends use that address as Reply-To, so customer replies come back here instead of the owner's inbox.
--   * the inbound webhook (n8n "Zella - Inbound Email") hands each email to zella_receive_inbound_email, which:
--       checks the secret key, ignores repeats, finds the business from the address, finds the customer by email
--       (exact match only), saves the email on the customer's record and in the inbox thread, sorts the reply,
--       and acts: unsubscribe -> never email again; auto-reply -> saved quietly; everything else -> staff are told.
--   * text delivery receipts (delivered / failed) update the saved text and tell the business about failures.

-- 1. The business address
alter table public.businesses add column if not exists inbound_email_token text;
update public.businesses set inbound_email_token = substr(md5(random()::text || clock_timestamp()::text || id::text), 1, 12) where inbound_email_token is null;
create unique index if not exists businesses_inbound_email_token_idx on public.businesses (inbound_email_token);
alter table public.businesses alter column inbound_email_token set default substr(md5(random()::text || clock_timestamp()::text), 1, 12);

create or replace function public.zella_inbound_email_address(p_business_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select case when d.dom ~ '^[a-z0-9.-]+\.[a-z]{2,}$' then b.inbound_email_token || '@' || d.dom end
    from public.businesses b,
         lateral (select lower(trim(both '"' from coalesce(public.zella_setting('inbound_email_domain', 'null'::jsonb)::text, ''))) as dom) d
   where b.id = p_business_id and b.inbound_email_token is not null;
$$;
revoke execute on function public.zella_inbound_email_address(uuid) from public, anon, authenticated;
grant execute on function public.zella_inbound_email_address(uuid) to service_role;

-- Replies to Zella emails use the business's inbound address when it is set up (otherwise the business email, as before).
do $$
declare d text; old_t text := $o$'reply_to', nullif(lower(trim(coalesce(to_jsonb(b) ->> 'email', ''))), ''),$o$;
begin
  d := pg_get_functiondef('public.zella_prepare_email'::regproc);
  if position(old_t in d) > 0 then
    d := replace(d, old_t, $n$'reply_to', coalesce(public.zella_inbound_email_address(b.id), nullif(lower(trim(coalesce(to_jsonb(b) ->> 'email', ''))), '')),$n$);
    execute d;
  end if;
end $$;

-- 2. Sorting a reply (plain rules; the words are only read, never run)
create or replace function public.zella_classify_email(p_subject text, p_body text, p_auto boolean default false) returns text
language sql immutable as $$
  select case
    when p_auto or coalesce(p_subject, '') ~* '^\s*(automatic reply|auto[- ]?reply|auto:|out of office|undeliverable|delivery status notification|mail delivery)' then 'auto_reply'
    when coalesce(p_body, '') ~* '\m(unsubscribe|remove me|stop (emailing|sending)|take me off|opt[- ]?out)\M' then 'unsubscribe'
    when coalesce(p_subject, '') || ' ' || coalesce(p_body, '') ~* '\m(complain|complaint|unhappy|disappointed|terrible|refund|chargeback|lawyer|legal action|sue)\M' then 'complaint'
    when coalesce(p_subject, '') || ' ' || coalesce(p_body, '') ~* '\m(cancel|cancellation|cancelled)\M' then 'cancel'
    when coalesce(p_subject, '') || ' ' || coalesce(p_body, '') ~* '\m(reschedule|different time|another time|move (my|the) appointment|change (my|the) (appointment|time))\M' then 'reschedule'
    when left(trim(coalesce(p_body, '')), 120) ~* '^(yes|confirmed?|confirm|ok(ay)?|sounds good|see you)\M' then 'confirm'
    when coalesce(p_body, '') like '%?%' then 'question'
    else 'other' end;
$$;
revoke execute on function public.zella_classify_email(text, text, boolean) from public, anon, authenticated;
grant execute on function public.zella_classify_email(text, text, boolean) to service_role;

-- 3. Receive one inbound email.
create or replace function public.zella_receive_inbound_email(p_key text, p_message jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_secret text; m jsonb := p_message;
  v_mid text; v_from text; v_to text; v_tok text; v_biz uuid; v_name text; v_subject text; v_body text; v_irt text;
  v_cust uuid; v_cname text; v_conv uuid; v_prev uuid; v_cat text; v_auto boolean; v_emid uuid; v_known boolean;
  v_prio text; v_title text;
begin
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'zella_resend_webhook_key' limit 1;
  if v_secret is null or v_secret = '' then return jsonb_build_object('result', 'not_configured'); end if;
  if p_key is null or encode(sha256(convert_to(p_key, 'utf8')), 'hex') <> encode(sha256(convert_to(v_secret, 'utf8')), 'hex') then return jsonb_build_object('result', 'unauthorized'); end if;
  if m is null or jsonb_typeof(m) <> 'object' then return jsonb_build_object('result', 'ignored'); end if;

  v_mid := nullif(left(trim(coalesce(m ->> 'message_id', '')), 300), '');
  v_from := lower(substring(coalesce(m ->> 'from', '') from '([A-Za-z0-9._%+''-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})'));
  v_irt := nullif(left(trim(coalesce(m ->> 'in_reply_to', '')), 300), '');
  v_subject := left(regexp_replace(coalesce(m ->> 'subject', ''), '[\r\n]+', ' ', 'g'), 300);
  v_body := left(coalesce(m ->> 'text', ''), 20000);
  v_auto := coalesce((m ->> 'auto_submitted')::boolean, false);
  if v_mid is null or v_from is null then return jsonb_build_object('result', 'ignored'); end if;

  -- which business? the token in any "to" address
  select b.id, b.name, lower(a) into v_biz, v_name, v_to
    from jsonb_array_elements_text(case when jsonb_typeof(m -> 'to') = 'array' then m -> 'to' when jsonb_typeof(m -> 'to') = 'string' then jsonb_build_array(m ->> 'to') else '[]'::jsonb end) a
    join public.businesses b on b.inbound_email_token = substring(lower(a) from '([a-z0-9]{12})@')
   where b.suspended_at is null and b.cancelled_at is null limit 1;
  if v_biz is null then return jsonb_build_object('result', 'no_business'); end if;

  if exists (select 1 from public.email_messages e where e.business_id = v_biz and e.direction = 'inbound' and e.external_message_id = v_mid) then
    return jsonb_build_object('result', 'duplicate');
  end if;
  if not public.zella_rate_limit('inbound_email:' || v_biz::text, 300, 3600) then return jsonb_build_object('result', 'rate_limited'); end if;

  -- the customer: exact match on the sender's email only
  select m2.customer_id into v_cust from public.zella_match_customer(v_biz, null, v_from) m2 where m2.certainty = 'exact' limit 1;
  v_known := v_cust is not null;
  if v_known then select trim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')) into v_cname from public.customers where id = v_cust; end if;
  v_cname := coalesce(nullif(v_cname, ''), v_from);

  -- the thread: the email it answers, otherwise this customer's open email thread, otherwise a new one
  if v_irt is not null then
    select e.conversation_id into v_prev from public.email_messages e where e.business_id = v_biz and e.external_message_id = v_irt and e.conversation_id is not null limit 1;
  end if;
  v_conv := v_prev;
  if v_conv is null and v_cust is not null then
    select c.id into v_conv from public.conversations c where c.business_id = v_biz and c.customer_id = v_cust and c.channel = 'email' and c.status <> 'closed' order by c.last_message_at desc nulls last limit 1;
  end if;
  if v_conv is null then
    insert into public.conversations (business_id, customer_id, channel, status, subject, ai_handled)
    values (v_biz, v_cust, 'email', 'open', nullif(v_subject, ''), false) returning id into v_conv;
  end if;

  v_cat := public.zella_classify_email(v_subject, v_body, v_auto);

  insert into public.email_messages (business_id, customer_id, conversation_id, direction, status, from_email, to_email, subject, body_text, external_message_id, sent_at, metadata)
  values (v_biz, v_cust, v_conv, 'inbound', 'received', v_from, v_to, nullif(v_subject, ''), v_body, v_mid, now(),
          jsonb_build_object('category', v_cat, 'known_customer', v_known)) returning id into v_emid;
  insert into public.conversation_messages (conversation_id, sender_type, message_type, content, external_message_id, metadata)
  values (v_conv, 'customer', 'text', left(v_body, 5000), v_mid, jsonb_build_object('category', v_cat, 'subject', v_subject, 'email_message_id', v_emid));

  -- actions
  if v_cat = 'auto_reply' then
    return jsonb_build_object('result', 'saved', 'category', v_cat);
  end if;
  if v_cat = 'unsubscribe' then
    perform public.zella_record_consent(v_biz, 'email', 'opted_out', 'email_link', v_cust, null, v_from, 'marketing', 'reply');
    if v_cust is not null then
      update public.customers set do_not_email = true, email_suppressed_at = now(), email_suppressed_reason = 'unsubscribed', updated_at = now() where id = v_cust and (not coalesce(do_not_email, false) or email_suppressed_reason is null);
    end if;
    perform public.zella_notify_owners(v_biz, 'email_unsubscribed', v_cname || ' unsubscribed', 'They will not get marketing emails any more.', 'info', 'inbox');
    return jsonb_build_object('result', 'saved', 'category', v_cat, 'unsubscribed', true);
  end if;

  v_prio := case when v_cat in ('complaint', 'cancel') then 'high' else 'normal' end;
  update public.conversations set status = 'open', priority = case when v_prio = 'high' then 'high' else priority end, updated_at = now() where id = v_conv;
  v_title := case v_cat
    when 'complaint' then 'Complaint by email from ' || v_cname
    when 'cancel' then v_cname || ' wants to cancel'
    when 'reschedule' then v_cname || ' wants a different time'
    when 'confirm' then v_cname || ' confirmed by email'
    else 'New email from ' || v_cname end;
  perform public.zella_notify_owners(v_biz, 'customer_email', v_title,
    left(coalesce(nullif(v_subject, ''), '(no subject)') || ': ' || regexp_replace(v_body, '\s+', ' ', 'g'), 300) || case when v_known then '' else ' (sender is not in your customer list)' end,
    case when v_cat = 'complaint' then 'urgent' else 'info' end, 'inbox');
  return jsonb_build_object('result', 'saved', 'category', v_cat, 'known_customer', v_known, 'conversation_id', v_conv);
end $$;
revoke execute on function public.zella_receive_inbound_email(text, jsonb) from public, anon, authenticated;
grant execute on function public.zella_receive_inbound_email(text, jsonb) to service_role;

-- 4. Text delivery receipts (from the provider, through the event router)
create or replace function public.zella_record_sms_receipt(p_business_id uuid, p_external_id text, p_status text, p_error text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.sms_messages; v_st text := case when p_status in ('delivered', 'failed') then p_status else null end;
begin
  if v_st is null or nullif(p_external_id, '') is null then return jsonb_build_object('action', 'ignored'); end if;
  select * into r from public.sms_messages where business_id = p_business_id and external_message_id = left(p_external_id, 200) and direction = 'outbound' limit 1;
  if r.id is null then return jsonb_build_object('action', 'unknown_message'); end if;
  if r.status = 'delivered' then return jsonb_build_object('action', 'already_delivered'); end if;
  if v_st = 'delivered' then
    update public.sms_messages set status = 'delivered', delivered_at = now(), updated_at = now() where id = r.id;
    return jsonb_build_object('action', 'delivered');
  end if;
  update public.sms_messages set status = 'failed', metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('delivery_error', left(coalesce(p_error, 'unknown'), 200)), updated_at = now() where id = r.id;
  perform public.zella_notify_owners(p_business_id, 'sms_not_delivered', 'A text did not arrive',
    'A text to ' || coalesce(r.to_number, 'a customer') || ' could not be delivered (' || left(coalesce(nullif(p_error, ''), 'unknown reason'), 100) || '). Check the number.', 'info', 'inbox');
  return jsonb_build_object('action', 'failed');
end $$;
revoke execute on function public.zella_record_sms_receipt(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.zella_record_sms_receipt(uuid, text, text, text) to service_role;

-- 5. Business onboarding email: when a business goes live for the first time, its owners get a welcome email
--    (sent by the normal owner email lane, only when email_live is on).
do $$
declare d text; old_t text := $o$n.kind in ('daily_summary', 'weekly_review')$o$;
begin
  d := pg_get_functiondef('public.zella_claim_owner_emails'::regproc);
  if position(old_t in d) > 0 then
    execute replace(d, old_t, $n$n.kind in ('daily_summary', 'weekly_review', 'business_welcome')$n$);
  end if;
end $$;

create or replace function public.zella_business_welcome() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.onboarding_status = 'active' and old.onboarding_status is distinct from 'active'
     and not exists (select 1 from public.staff_notifications where business_id = new.id and kind = 'business_welcome') then
    perform public.zella_notify_owners(new.id, 'business_welcome', 'Welcome to Zella - ' || new.name || ' is live',
      'Your AI receptionist is now answering for ' || new.name || E'.\n\nWhat happens next:\n- Calls, texts and web enquiries are handled for you.\n- You will get an alert when something needs a person (an emergency, a complaint, a callback).\n- A short summary arrives each morning.\n\nTo change your opening hours, team or messages, open Zella and go to Settings.', 'info', 'dashboard');
  end if;
  return new;
end $$;
drop trigger if exists zella_business_welcome on public.businesses;
create trigger zella_business_welcome after update of onboarding_status on public.businesses
  for each row execute function public.zella_business_welcome();
