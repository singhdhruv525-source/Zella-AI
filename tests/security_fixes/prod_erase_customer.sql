-- Production's zella_erase_customer (read only catalog read, 18 Nov 2026; function code only, no data), so the suite
-- can apply sql/zella_privacy_retention.sql to exactly what production runs. The isolated copy holds an older version.
CREATE OR REPLACE FUNCTION public.zella_erase_customer(p_business_id uuid, p_customer_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_column text;
begin
  if not public.zella_has_role(p_business_id, array['owner','admin']) then raise exception 'NOT_ALLOWED'; end if;
  if not exists (select 1 from public.customers where id = p_customer_id and business_id = p_business_id) then raise exception 'NOT_FOUND'; end if;
  if not public.zella_approval_ok(p_business_id, 'erase_customer', p_customer_id) then raise exception 'APPROVAL_REQUIRED'; end if;
  update public.sms_messages set message_body = '[removed]' where customer_id = p_customer_id and business_id = p_business_id;
  update public.email_messages set subject = '[removed]', body_text = '[removed]', body_html = null where customer_id = p_customer_id and business_id = p_business_id;
  update public.calls set transcript = null, recording_url = null, summary = null, from_number = null, to_number = null where customer_id = p_customer_id and business_id = p_business_id;
  update public.callbacks set contact_number = null, summary = null, note = null where customer_id = p_customer_id and business_id = p_business_id;
  update public.appointments set description = null where customer_id = p_customer_id and business_id = p_business_id;
  update public.crm_tasks set title = '[removed]', body = null where customer_id = p_customer_id and business_id = p_business_id;
  -- The base customer_requests DDL is external to this migration set. Scrub its
  -- descriptive fields when present without changing workflow keys or links.
  for v_column in select column_name from information_schema.columns
    where table_schema = 'public' and table_name = 'customer_requests'
      and column_name in ('title','subject','description','summary','body','notes','details','metadata','resolution','contact_name','contact_email','contact_phone')
  loop
    execute format('update public.customer_requests set %I = %s where customer_id = $1 and business_id = $2',
      v_column, case when v_column in ('details','metadata') then quote_literal('{}') else quote_literal('[removed]') end)
      using p_customer_id, p_business_id;
  end loop;
  -- Consent history is append-only (docs/ARCHITECTURE.md section 7.2). Keep
  -- phone_digits and email_lower for all channels/purposes: SMS opt-out readers
  -- match phone_digits and voice checks use the latest consent by that number.
  -- Do not erase/rewrite history or suppression identifiers when the profile is cleared.
  update public.followup_tasks set status = 'cancelled', updated_at = now() where customer_id = p_customer_id and business_id = p_business_id and status in ('pending','in_progress');
  update public.customers set first_name = 'Deleted', last_name = null, phone = null, email = null, address = null, notes = null, date_of_birth = null, company_name = null,
         tags = '{}', metadata = '{}'::jsonb, qualification = null, do_not_contact = true, status = 'archived', updated_at = now()
   where id = p_customer_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id) values (p_business_id, auth.uid(), 'customer_erased', 'customer', p_customer_id);
  return 'erased';
end $function$;
