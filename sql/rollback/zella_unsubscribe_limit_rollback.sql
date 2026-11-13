-- Undoes sql/zella_unsubscribe_limit.sql: both functions get back production's definitions of 13 Nov 2026 exactly.
-- Stops (VERSION_MISMATCH) if either has changed since that file, so a later change is never overwritten.
-- Counts already stored in rate_limits expire on their own. Safe to run again.
begin;
do $$
declare v text;
begin
  v := md5(pg_get_functiondef('public.zella_unsubscribe_lookup(text)'::regprocedure));
  if v not in ('6b71e36b82cc134696fdc3d57bd71fb2', '0605c81618c91fa8f23973d5f107a12d') then
    raise exception 'VERSION_MISMATCH: public.zella_unsubscribe_lookup(text) has changed since zella_unsubscribe_limit; not restored';
  end if;
  v := md5(pg_get_functiondef('public.zella_unsubscribe_email(text)'::regprocedure));
  if v not in ('2b0cbe3cdba9216fa630cf447a0153a8', 'c7eb60f1b441645e252c4f689bbfeedd') then
    raise exception 'VERSION_MISMATCH: public.zella_unsubscribe_email(text) has changed since zella_unsubscribe_limit; not restored';
  end if;
end $$;

CREATE OR REPLACE FUNCTION public.zella_unsubscribe_lookup(p_token text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((select jsonb_build_object('ok', true, 'business', b.name)
                     from public.email_unsubscribe_tokens t join public.businesses b on b.id = t.business_id
                    where p_token ~ '^[0-9a-f]{32}$' and t.token = p_token), jsonb_build_object('ok', false));
$function$;

CREATE OR REPLACE FUNCTION public.zella_unsubscribe_email(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare t public.email_unsubscribe_tokens; v_name text; v_mail text;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{32}$' then return jsonb_build_object('ok', false); end if;
  select * into t from public.email_unsubscribe_tokens where token = p_token;
  if not found then return jsonb_build_object('ok', false); end if;
  select name into v_name from public.businesses where id = t.business_id;
  select lower(email) into v_mail from public.customers where id = t.customer_id;
  if not exists (select 1 from public.contact_consents c where c.business_id = t.business_id and c.customer_id = t.customer_id and c.channel = 'email'
                    and c.purpose = 'marketing' and c.status = 'opted_out' and c.recorded_at > now() - interval '1 minute') then
    insert into public.contact_consents (business_id, customer_id, email_lower, channel, purpose, status, source, evidence)
    values (t.business_id, t.customer_id, v_mail, 'email', 'marketing', 'opted_out', 'email_link', jsonb_build_object('via', 'unsubscribe_link'));
  end if;
  return jsonb_build_object('ok', true, 'business', v_name);
end $function$;
commit;
