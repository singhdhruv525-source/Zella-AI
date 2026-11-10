-- Zella - after-hours text acknowledgement. Safe to run more than once.
-- Needs the inbound handler, zella_match_customer, zella_business_open and followup_tasks.
-- A known customer who texts outside opening hours gets one short reply ("we have your message, we will reply when we open"),
-- at most once every 12 hours. The "Follow-up Texts" n8n workflow sends it (kind reply_after_hours).

insert into public.message_templates (business_id, industry_id, key, channel, purpose, locale, subject, body, version, status)
select null, null, 'reply_after_hours', 'sms', 'transactional', 'en-US', null,
       'Thanks {{first_name}}, {{business}} is closed right now. We have your message and will reply when we open.', 1, 'active'
 where not exists (select 1 from public.message_templates t
    where t.business_id is null and t.industry_id is null and t.key = 'reply_after_hours' and t.channel = 'sms' and t.locale = 'en-US' and t.status = 'active');

-- Apply after zella_automation_foundation.sql or zella_inbound_replies.sql, and after
-- any later handler replacement. Re-run this file after reapplying zella_inbound_replies.sql.
-- Patch only the ordinary-message return; keyword handling and reply metadata stay intact.
do $$
declare
  v_def text;
  v_old text;
  v_new text;
begin
  v_def := pg_get_functiondef('public.zella_handle_inbound_sms_keyword(uuid,text,text)'::regprocedure);
  if position('after_hours_reply_queued' in v_def) > 0 then return; end if;
  foreach v_old in array array[
    $q$return jsonb_build_object('action', 'none');$q$,
    $q$return jsonb_build_object('action', 'reply_received', 'known_customer', v_cust is not null);$q$
  ] loop
    if position(v_old in v_def) = 0 then continue; end if;
    v_new := $patch$declare v_after_cust uuid; v_after_queued boolean := false;
  begin
    select m.customer_id into v_after_cust
      from public.zella_match_customer(p_business_id, p_from, null) m where m.certainty = 'exact' limit 1;
    if v_after_cust is not null
       and coalesce((public.zella_business_open(p_business_id, now()) ->> 'open')::boolean, true) = false
       and not exists (select 1 from public.followup_tasks f
         where f.business_id = p_business_id and f.customer_id = v_after_cust
           and f.kind = 'reply_after_hours' and f.created_at > now() - interval '12 hours') then
      insert into public.followup_tasks (business_id, customer_id, kind, channel, due_at, max_attempts)
      values (p_business_id, v_after_cust, 'reply_after_hours', 'sms', now(), 2);
      v_after_queued := true;
    end if;
    $patch$ || replace(v_old, ';', ' || case when v_after_queued then jsonb_build_object(''after_hours_reply_queued'', true) else ''{}''::jsonb end;') || E'\n  end;';
    execute replace(v_def, v_old, v_new);
    return;
  end loop;
  raise exception 'handler ending not found; update this patch';
end $$;
