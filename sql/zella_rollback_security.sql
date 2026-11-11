-- zella_rollback_security: CodeRabbit review #44, finding 1. New inbound email tokens are 32 random hex characters
-- (gen_random_bytes) instead of 12 characters of md5(random()); existing addresses keep working, because
-- zella_receive_inbound_email matches either form, and only at the start of an address.
-- Finding 2 (direct reads of call recordings and transcripts) is already fixed in production by
-- sql/zella_call_content_privacy.sql; the schema baseline predates it, so nothing changes here for calls.
-- Depends on: the production baseline. Verify: tests/rollback_security/run.sh on an isolated copy.
-- Roll back: sql/rollback/zella_rollback_security_rollback.sql (exact; deletes no data).
-- Version guard: stops unless zella_receive_inbound_email is the definition this was written against
-- (or this migration's own, so it is safe to run twice).
begin;
do $guard$
begin
  if not md5(pg_get_functiondef('public.zella_receive_inbound_email(text,jsonb)'::regprocedure)) = any(array['04781d76406f3f6a8adb4d90ec837f0f','1f3faa7e6a9fe868b8fd87c4cf22c880']) then
    raise exception 'VERSION_MISMATCH: zella_receive_inbound_email is not the definition this migration was written against';
  end if;
end $guard$;
alter table public.businesses alter column inbound_email_token set default encode(extensions.gen_random_bytes(16), 'hex');
CREATE OR REPLACE FUNCTION public.zella_receive_inbound_email(p_key text, p_message jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_secret text; m jsonb := p_message;
  v_mid text; v_from text; v_to text; v_biz uuid; v_name text; v_subject text; v_body text; v_irt text;
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

  select b.id, b.name, lower(a) into v_biz, v_name, v_to
    from jsonb_array_elements_text(case when jsonb_typeof(m -> 'to') = 'array' then m -> 'to' when jsonb_typeof(m -> 'to') = 'string' then jsonb_build_array(m ->> 'to') else '[]'::jsonb end) a
    join public.businesses b on b.inbound_email_token = substring(lower(a) from '(?:^|[<[:space:]])([a-z0-9]{12}|[a-f0-9]{32})@')
   where b.suspended_at is null and b.cancelled_at is null limit 1;
  if v_biz is null then return jsonb_build_object('result', 'no_business'); end if;

  if exists (select 1 from public.email_messages e where e.business_id = v_biz and e.direction = 'inbound' and e.external_message_id = v_mid) then
    return jsonb_build_object('result', 'duplicate');
  end if;
  if not public.zella_rate_limit('inbound_email:' || v_biz::text, 300, 3600) then return jsonb_build_object('result', 'rate_limited'); end if;

  select m2.customer_id into v_cust from public.zella_match_customer(v_biz, null, v_from) m2 where m2.certainty = 'exact' limit 1;
  v_known := v_cust is not null;
  if v_known then select trim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')) into v_cname from public.customers where id = v_cust; end if;
  v_cname := coalesce(nullif(v_cname, ''), v_from);

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
end $function$
;
commit;
