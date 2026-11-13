-- Zella Voice: a rate limit on the public unsubscribe link (SEC-6, conformance gap G-7).
-- zella_unsubscribe_lookup and zella_unsubscribe_email can be called by anyone, without signing in. The link code is
-- 32 random hex characters, so it cannot be guessed; the risk is a script hammering a known link, which costs
-- database work and, for the save, writes consent rows. Both now count calls per link (zella_rate_limit):
--   lookup  30 per 10 minutes per link; over it the answer is {ok: false, reason: "busy"} (the page asks to wait)
--   save    10 per 10 minutes per link; over it, a person already opted out is told so and nothing is written
-- Opt-out always wins (NN-8): the first opt-out from a link is always recorded, whatever the count. There is no
-- platform-wide cap, so a burst of genuine opt-outs after a large email is never refused. No per-address limit:
-- the forwarded address is set by the client and cannot be trusted here.
-- zella_unsubscribe_lookup becomes plpgsql and volatile (it now counts calls); the web page calls it with POST
-- (supabase.rpc), which a volatile function needs. Grants are kept (create or replace keeps them).
-- Version guard: each function is replaced only when it is the version production runs (md5 of pg_get_functiondef,
-- read from production on 13 Nov 2026) or already this file's version. Safe to run twice.
-- Rollback: sql/rollback/zella_unsubscribe_limit_rollback.sql

do $$
declare v text;
begin
  v := md5(pg_get_functiondef('public.zella_unsubscribe_lookup(text)'::regprocedure));
  if v not in ('6b71e36b82cc134696fdc3d57bd71fb2', '0605c81618c91fa8f23973d5f107a12d') then
    raise exception 'VERSION_MISMATCH: public.zella_unsubscribe_lookup(text) is not the version this file was written against (expected the live version or this file version)';
  end if;
  v := md5(pg_get_functiondef('public.zella_unsubscribe_email(text)'::regprocedure));
  if v not in ('2b0cbe3cdba9216fa630cf447a0153a8', 'c7eb60f1b441645e252c4f689bbfeedd') then
    raise exception 'VERSION_MISMATCH: public.zella_unsubscribe_email(text) is not the version this file was written against (expected the live version or this file version)';
  end if;
end $$;

create or replace function public.zella_unsubscribe_lookup(p_token text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_name text;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{32}$' then return jsonb_build_object('ok', false); end if;
  -- per link: a person opens their own link a few times; a script hammering one link is told to wait
  if not public.zella_rate_limit('unsub:view:' || p_token, 30, 600) then return jsonb_build_object('ok', false, 'reason', 'busy'); end if;
  select b.name into v_name from public.email_unsubscribe_tokens t join public.businesses b on b.id = t.business_id where t.token = p_token;
  if not found then return jsonb_build_object('ok', false); end if;
  return jsonb_build_object('ok', true, 'business', v_name);
end $function$;

create or replace function public.zella_unsubscribe_email(p_token text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare t public.email_unsubscribe_tokens; v_name text; v_mail text; v_within boolean;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{32}$' then return jsonb_build_object('ok', false); end if;
  select * into t from public.email_unsubscribe_tokens where token = p_token;
  if not found then return jsonb_build_object('ok', false); end if;
  select name into v_name from public.businesses where id = t.business_id;
  -- opt-out always wins (NN-8): the limit never stops the first opt-out. Over the limit, a person who is already
  -- opted out is told so and nothing more is written; one who is not yet opted out is still recorded.
  v_within := public.zella_rate_limit('unsub:save:' || p_token, 10, 600);
  if not v_within and exists (select 1 from public.contact_consents c where c.business_id = t.business_id and c.customer_id = t.customer_id
                                and c.channel = 'email' and c.purpose = 'marketing' and c.status = 'opted_out') then
    return jsonb_build_object('ok', true, 'business', v_name);
  end if;
  select lower(email) into v_mail from public.customers where id = t.customer_id;
  if not exists (select 1 from public.contact_consents c where c.business_id = t.business_id and c.customer_id = t.customer_id and c.channel = 'email'
                    and c.purpose = 'marketing' and c.status = 'opted_out' and c.recorded_at > now() - interval '1 minute') then
    insert into public.contact_consents (business_id, customer_id, email_lower, channel, purpose, status, source, evidence)
    values (t.business_id, t.customer_id, v_mail, 'email', 'marketing', 'opted_out', 'email_link', jsonb_build_object('via', 'unsubscribe_link'));
  end if;
  return jsonb_build_object('ok', true, 'business', v_name);
end $function$;
