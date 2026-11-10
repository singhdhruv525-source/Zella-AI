-- Fix 1 for zella_automation_foundation.sql (run this if you already ran the foundation file).
-- 1) Consent records made in the same instant now keep their true order.
-- 2) "May we send marketing?" answers false (not blank) when there is no opt-in on record.

alter table public.contact_consents alter column recorded_at set default clock_timestamp();

create or replace function public.zella_can_contact(p_business_id uuid, p_customer_id uuid, p_channel text, p_purpose text default 'transactional')
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare c public.customers; v_latest text; v_digits text; v_mail text;
begin
  select * into c from public.customers where id = p_customer_id and business_id = p_business_id;
  if not found then return false; end if;
  if c.do_not_contact then return false; end if;
  if p_channel = 'sms' and c.do_not_sms then return false; end if;
  if p_channel = 'call' and c.do_not_call then return false; end if;
  if p_channel = 'email' and c.do_not_email then return false; end if;
  v_digits := public.zella_digits(c.phone); v_mail := lower(c.email);
  select status into v_latest from public.contact_consents
   where business_id = p_business_id and channel = p_channel and purpose = p_purpose
     and (customer_id = c.id or (v_digits is not null and phone_digits = v_digits) or (v_mail is not null and email_lower = v_mail))
   order by recorded_at desc limit 1;
  if v_latest = 'opted_out' then return false; end if;
  if p_purpose = 'marketing' then return coalesce(v_latest = 'opted_in', false); end if;
  return true;
end $$;

revoke all on function public.zella_can_contact(uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function public.zella_can_contact(uuid, uuid, text, text) to service_role;
