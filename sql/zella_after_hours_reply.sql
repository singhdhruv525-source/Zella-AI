-- Zella - after-hours text acknowledgement. Safe to run more than once.
-- Needs zella_reply_actions.sql and zella_reschedule.sql first (they define the current text handler).
-- A known customer who texts outside opening hours gets one short reply ("we have your message, we will reply when we open"),
-- at most once every 12 hours. The "Follow-up Texts" n8n workflow sends it (kind reply_after_hours).

insert into public.message_templates (business_id, industry_id, key, channel, purpose, locale, subject, body, version, status)
select null, null, 'reply_after_hours', 'sms', 'transactional', 'en-US', null,
       'Thanks {{first_name}}, {{business}} is closed right now. We have your message and will reply when we open.', 1, 'active'
 where not exists (select 1 from public.message_templates t
    where t.business_id is null and t.industry_id is null and t.key = 'reply_after_hours' and t.channel = 'sms' and t.locale = 'en-US' and t.status = 'active');

-- Patch the live handler in place so later changes to it are not lost.
do $$
declare v_def text;
  v_old text := $q$  return jsonb_build_object('action', 'reply_received', 'known_customer', v_cust is not null, 'urgent', v_action = 'warning');$q$;
  v_new text := $q$  if v_cust is not null
     and coalesce((public.zella_business_open(p_business_id, now()) ->> 'open')::boolean, true) = false
     and not exists (select 1 from public.followup_tasks f where f.customer_id = v_cust and f.kind = 'reply_after_hours' and f.created_at > now() - interval '12 hours') then
    insert into public.followup_tasks (business_id, customer_id, kind, channel, due_at, max_attempts) values (p_business_id, v_cust, 'reply_after_hours', 'sms', now(), 2);
    return jsonb_build_object('action', 'reply_received', 'known_customer', true, 'urgent', v_action = 'warning', 'after_hours_reply_queued', true);
  end if;
  return jsonb_build_object('action', 'reply_received', 'known_customer', v_cust is not null, 'urgent', v_action = 'warning');$q$;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'zella_handle_inbound_sms_keyword';
  if v_def is null then raise exception 'zella_handle_inbound_sms_keyword is missing'; end if;
  if v_def not like '%reply_after_hours%' then
    if position(v_old in v_def) = 0 then raise exception 'handler ending not found; update this patch'; end if;
    execute replace(v_def, v_old, v_new);
  end if;
end $$;
