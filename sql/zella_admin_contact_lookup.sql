-- Zella Voice: why one number or address gets no messages, for one business, masked and audited
-- (docs/ADMIN_AUDIT_2026-11-16.md COM-29).
-- Messaging, Consent showed totals only (zella_admin_messaging_compliance). Now
-- zella_admin_contact_lookup(p_business, p_query, p_reason), for admins with comms.manage:
--   * a business must be chosen, the query must be at least 4 digits or a full email address, and a reason is
--     required;
--   * it looks at that business only: its customers' do not contact, do not text and do not email flags and email
--     suppression, its consent records (latest per channel and purpose), block and allow list entries (the business's
--     own and platform wide blocks), and the last blocked text or email;
--   * the answer is masked: phone numbers as their last 4 digits, email addresses as first letter and domain; no
--     names, message bodies or full numbers are returned;
--   * every lookup is audited (comms.contact_lookup) with the masked query, the reason and how many matched (NN-8).
-- Nothing existing is replaced. The function must be absent or exactly this file's version, otherwise
-- VERSION_MISMATCH. Rollback: sql/rollback/zella_admin_contact_lookup_rollback.sql
begin;

do $$
begin
  if to_regprocedure('public.zella_admin_require(text)') is null or to_regprocedure('public.zella_admin_reason(text)') is null
     or to_regclass('public.contact_consents') is null or to_regclass('public.spam_list_entries') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  if to_regprocedure('public.zella_admin_contact_lookup(uuid,text,text)') is not null
     and md5(pg_get_functiondef(to_regprocedure('public.zella_admin_contact_lookup(uuid,text,text)'))) <> '4ea03aaa7e28d16f4dbc2f03e0c56bff' then
    raise exception 'VERSION_MISMATCH: zella_admin_contact_lookup is not a version this file was written for';
  end if;
end $$;

CREATE OR REPLACE FUNCTION public.zella_admin_contact_lookup(p_business uuid, p_query text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_reason text := public.zella_admin_reason(p_reason);
  v_q text := lower(trim(coalesce(p_query, '')));
  v_digits text; v_email text; v_masked text; v_out jsonb;
begin
  perform public.zella_admin_require('comms.manage');
  if p_business is null or not exists (select 1 from businesses where id = p_business) then raise exception 'BUSINESS_REQUIRED'; end if;
  if v_q ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    v_email := v_q; v_masked := left(v_q, 1) || '…@' || split_part(v_q, '@', 2);
  else
    v_digits := regexp_replace(v_q, '[^0-9]', '', 'g');
    if length(v_digits) < 4 or v_q ~ '[a-z@]' then raise exception 'QUERY_TOO_SHORT'; end if;
    v_digits := right(v_digits, 10); v_masked := '…' || right(v_digits, 4);
  end if;

  with
  dig(d) as (select v_digits),
  cust as (
    select c.id, c.phone, c.email, c.do_not_contact, c.do_not_sms, c.do_not_email, c.do_not_call, c.email_suppressed_at, c.email_suppressed_reason
      from customers c
     where c.business_id = p_business
       and ((v_digits is not null and right(regexp_replace(coalesce(c.phone, ''), '[^0-9]', '', 'g'), length(v_digits)) = v_digits)
         or (v_email is not null and lower(c.email) = v_email))
     limit 20),
  -- the latest consent per contact, channel and purpose: a short query can match several contacts, and one contact's
  -- opt out must never be hidden by another's opt in. Each carries its contact, masked, so they can be told apart.
  cons as (
    select distinct on (coalesce(k.phone_digits, k.email_lower, k.customer_id::text), k.channel, k.purpose)
           coalesce(k.phone_digits, k.email_lower, k.customer_id::text) as ident,
           case when k.phone_digits is not null then '…' || right(k.phone_digits, 4)
                when k.email_lower is not null then left(k.email_lower, 1) || '…@' || split_part(k.email_lower, '@', 2)
                else 'a customer record' end as masked,
           k.channel, k.purpose, k.status, k.source, k.recorded_at
      from contact_consents k
     where k.business_id = p_business
       and ((v_digits is not null and right(coalesce(k.phone_digits, ''), length(v_digits)) = v_digits)
         or (v_email is not null and k.email_lower = v_email)
         or k.customer_id in (select id from cust))
     order by coalesce(k.phone_digits, k.email_lower, k.customer_id::text), k.channel, k.purpose, k.recorded_at desc),
  lists as (
    select s.list, s.channel, s.value_type, s.reason, s.source, s.created_at, s.expires_at, (s.business_id is null) as platform_wide
      from spam_list_entries s
     where (s.business_id = p_business or (s.business_id is null and s.list = 'block')) and s.removed_at is null
       and (s.expires_at is null or s.expires_at > now())
       and ((v_digits is not null and s.value_type = 'phone' and right(regexp_replace(s.value, '[^0-9]', '', 'g'), length(v_digits)) = v_digits)
         or (v_email is not null and s.value_type = 'email' and lower(s.value) = v_email)
         or (v_email is not null and s.value_type = 'domain' and lower(s.value) = split_part(v_email, '@', 2)))
     limit 20),
  blocked as (
    select 'sms' as channel, m.created_at, coalesce(m.metadata ->> 'block_reason', m.metadata ->> 'blocked_reason', m.metadata ->> 'reason') as reason
      from sms_messages m
     where v_digits is not null and m.business_id = p_business and m.status = 'blocked'
       and right(regexp_replace(coalesce(m.to_number, ''), '[^0-9]', '', 'g'), length(v_digits)) = v_digits
    union all
    select 'email', e.created_at, coalesce(e.metadata ->> 'block_reason', e.metadata ->> 'blocked_reason', e.metadata ->> 'reason')
      from email_messages e
     where v_email is not null and e.business_id = p_business and e.status = 'blocked' and lower(e.to_email) = v_email)
  select jsonb_build_object(
    'query', v_masked,
    'contacts', coalesce((select jsonb_agg(jsonb_build_object(
        'contact', case when v_digits is not null then '…' || right(regexp_replace(coalesce(phone, ''), '[^0-9]', '', 'g'), 4)
                        else left(lower(email), 1) || '…@' || split_part(lower(email), '@', 2) end,
        'do_not_contact', coalesce(do_not_contact, false), 'do_not_sms', coalesce(do_not_sms, false), 'do_not_call', coalesce(do_not_call, false),
        'do_not_email', coalesce(do_not_email, false), 'email_suppressed_at', email_suppressed_at, 'email_suppressed_reason', email_suppressed_reason)) from cust), '[]'::jsonb),
    -- several contacts: numbered ("…7788, contact 2"), since their masked numbers can be the same
    'consents', coalesce((select jsonb_agg(jsonb_build_object('contact', case when (select count(distinct ident) from cons) > 1
                                                                   then x.masked || ', contact ' || x.n else x.masked end,
                                                              'channel', x.channel, 'purpose', x.purpose, 'status', x.status,
                                                              'source', x.source, 'recorded_at', x.recorded_at) order by x.n, x.channel, x.purpose)
                            from (select c.*, dense_rank() over (order by c.ident) as n from cons c) x), '[]'::jsonb),
    'lists', coalesce((select jsonb_agg(to_jsonb(lists) order by created_at desc) from lists), '[]'::jsonb),
    'last_blocked', (select to_jsonb(b) from blocked b order by created_at desc limit 1))
  into v_out;

  perform public.zella_admin_audit('comms.contact_lookup', 'business', p_business, p_business, null,
    jsonb_build_object('query', v_masked, 'reason', v_reason, 'contacts', jsonb_array_length(v_out -> 'contacts'),
                       'consents', jsonb_array_length(v_out -> 'consents'), 'lists', jsonb_array_length(v_out -> 'lists')));
  return v_out;
end
$function$;

revoke all on function public.zella_admin_contact_lookup(uuid, text, text) from public, anon;
grant execute on function public.zella_admin_contact_lookup(uuid, text, text) to authenticated;

commit;
