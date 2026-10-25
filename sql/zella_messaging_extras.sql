-- Zella - messaging extras (checklist 64, 65, 73, 80, 94, 100). Safe to run more than once.
-- Needs zella_message_types.sql, zella_email_sender.sql, zella_lead_capture.sql.
--   64  unsubscribe links in marketing email, and the public page's two functions (web/src/Unsubscribe.jsx, /u/<code>)
--   65  preview a template before saving, and a count of what was sent
--   73  a text that could not be sent falls back to email; a burst of failed texts alerts the platform
--   80  a customer's preferred channel (text or email), respected by every customer message
--   94  stale-lead reactivation can use email
--   100 campaign report: leads, qualified, booked and won by source and campaign

-- 1. Unsubscribe (64). One private code per person per business. Marketing email needs app_base_url set.
create table if not exists public.email_unsubscribe_tokens (
  token text primary key default encode(gen_random_bytes(16), 'hex'),
  business_id uuid not null references public.businesses(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (business_id, customer_id)
);
alter table public.email_unsubscribe_tokens enable row level security;
revoke all on public.email_unsubscribe_tokens from anon, authenticated;

create or replace function public.zella_unsubscribe_token(p_business_id uuid, p_customer_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v text;
begin
  select token into v from public.email_unsubscribe_tokens where business_id = p_business_id and customer_id = p_customer_id;
  if v is null then
    insert into public.email_unsubscribe_tokens (business_id, customer_id) values (p_business_id, p_customer_id)
    on conflict (business_id, customer_id) do nothing;
    select token into v from public.email_unsubscribe_tokens where business_id = p_business_id and customer_id = p_customer_id;
  end if;
  return v;
end $$;
revoke execute on function public.zella_unsubscribe_token(uuid, uuid) from public, anon, authenticated;
grant execute on function public.zella_unsubscribe_token(uuid, uuid) to service_role;

create or replace function public.zella_unsubscribe_lookup(p_token text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_build_object('ok', true, 'business', b.name)
                     from public.email_unsubscribe_tokens t join public.businesses b on b.id = t.business_id
                    where p_token ~ '^[0-9a-f]{32}$' and t.token = p_token), jsonb_build_object('ok', false));
$$;

-- Only marketing email is stopped. Messages about the person's own bookings can still reach them.
create or replace function public.zella_unsubscribe_email(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
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
end $$;
revoke execute on function public.zella_unsubscribe_lookup(text), public.zella_unsubscribe_email(text) from public;
grant execute on function public.zella_unsubscribe_lookup(text), public.zella_unsubscribe_email(text) to anon, authenticated, service_role;

-- Marketing email now goes out when app_base_url is set, the person opted in, and every message ends with the link.
do $$
declare d text;
begin
  d := pg_get_functiondef('public.zella_prepare_email(uuid,uuid,text,jsonb,text)'::regprocedure);
  if d not like '%unsubscribe_url%' then
    d := replace(d, 'v_val text;', 'v_val text; v_base text; v_unsub text;');
    d := replace(d, E'  if v_purpose = ''marketing'' then\n    return jsonb_build_object(''allowed'', false, ''reason'', ''marketing_email_not_ready'', ''live'', v_live);\n  end if;',
      E'  if v_purpose = ''marketing'' then\n    v_base := regexp_replace(coalesce(nullif(trim(public.zella_setting(''app_base_url'', ''""''::jsonb) #>> ''{}''), ''''), ''''), ''/+$'', '''');\n    if v_base = '''' then return jsonb_build_object(''allowed'', false, ''reason'', ''marketing_email_not_ready'', ''live'', v_live); end if;\n  end if;');
    d := replace(d, E'  return jsonb_build_object(''allowed'', true,',
      E'  if v_purpose = ''marketing'' then\n    v_unsub := v_base || ''/u/'' || public.zella_unsubscribe_token(p_business_id, p_customer_id);\n    v_body := v_body || E''\\n\\nTo stop marketing emails from '' || regexp_replace(b.name, ''[\\r\\n]+'', '' '', ''g'') || '', open: '' || v_unsub;\n    v_html := v_html || ''<p><a href="'' || v_unsub || ''">Unsubscribe</a></p>'';\n  end if;\n  return jsonb_build_object(''allowed'', true, ''unsubscribe_url'', v_unsub,');
    d := replace(d, ' STABLE SECURITY DEFINER', ' SECURITY DEFINER');
    if d not like '%unsubscribe_url%' or d not like '%v_base text%' or d not like '%/u/%' then raise exception 'PATCH_FAILED_PREPARE_EMAIL'; end if;
    execute d;
  end if;
end $$;

-- 2. Wording for the email version of the reactivation message (94), marketing, so it carries the unsubscribe link.
insert into public.message_templates (business_id, industry_id, key, channel, purpose, locale, subject, body, version, status)
select null, null, 'lead_reactivation', 'email', 'marketing', 'en-US', 'It has been a while - {{business}}',
       E'Hi {{first_name}},\n\nIt has been a while since we last spoke. If you would still like help from {{business}}, just reply to this email.', 1, 'active'
 where not exists (select 1 from public.message_templates t where t.business_id is null and t.industry_id is null and t.key = 'lead_reactivation' and t.channel = 'email' and t.locale = 'en-US');

-- 3. Stale-lead reactivation by email (94): the automation's channel can be 'email' as well as 'sms' or 'call'.
do $$
declare d text;
begin
  d := pg_get_functiondef('public.zella_queue_lead_reactivation(integer)'::regprocedure);
  if d not like '%public.zella_valid_email(x.email)%' then
    d := replace(d, 'public.zella_digits(x.phone) is not null', '(public.zella_digits(x.phone) is not null or (v_auto.trigger_config ->> ''channel'' = ''email'' and public.zella_valid_email(x.email)))');
    d := replace(d, 'case when v_auto.trigger_config ->> ''channel'' = ''call'' then ''call'' else ''sms'' end', 'case v_auto.trigger_config ->> ''channel'' when ''call'' then ''call'' when ''email'' then ''email'' else ''sms'' end');
    if d not like '%public.zella_valid_email(x.email)%' or d not like '%when ''email'' then ''email''%' then raise exception 'PATCH_FAILED_REACTIVATION'; end if;
    execute d;
  end if;
end $$;

-- 4. Preferred channel (80). Staff can set it; every customer message respects it when that channel works.
alter table public.customers add column if not exists preferred_channel text;
do $$ begin
  alter table public.customers add constraint customers_preferred_channel_chk check (preferred_channel is null or preferred_channel in ('sms', 'email'));
exception when duplicate_object then null; end $$;

create or replace function public.zella_set_customer_channel(p_business_id uuid, p_customer_id uuid, p_channel text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.zella_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_channel is not null and p_channel not in ('sms', 'email') then raise exception 'BAD_CHANNEL'; end if;
  update public.customers set preferred_channel = p_channel, updated_at = now() where id = p_customer_id and business_id = p_business_id;
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;
revoke execute on function public.zella_set_customer_channel(uuid, uuid, text) from public, anon;
grant execute on function public.zella_set_customer_channel(uuid, uuid, text) to authenticated, service_role;

do $$
declare d text;
begin
  d := pg_get_functiondef('public.zella_queue_customer_message(uuid,uuid,text,jsonb,interval,uuid,interval)'::regprocedure);
  if d not like '%preferred_channel%' then
    d := replace(d, 'coalesce(x.do_not_email,false) dne', 'coalesce(x.do_not_email,false) dne, x.preferred_channel pref');
    d := replace(d, E'  if public.zella_digits(c.phone) is not null and not c.dns then v_channel := ''sms'';',
      E'  if c.pref = ''email'' and public.zella_valid_email(c.email) and not c.dne then v_channel := ''email'';\n  elsif public.zella_digits(c.phone) is not null and not c.dns then v_channel := ''sms'';');
    if d not like '%c.pref = ''email''%' or d not like '%x.preferred_channel pref%' then raise exception 'PATCH_FAILED_PREF'; end if;
    execute d;
  end if;
end $$;

-- 5. Failed texts (73): a text that could not be sent goes by email instead, once. A burst of failures tells the platform team.
create or replace function public.zella_recover_failed_texts(p_limit integer default 50)
returns integer language plpgsql security definer set search_path = public as $$
declare t record; n integer := 0; r record;
begin
  for t in select f.* from public.followup_tasks f
            where f.channel = 'sms' and f.status = 'failed' and f.updated_at > now() - interval '48 hours'
              and f.kind in ('no_show_follow_up','post_appointment_follow_up','quote_follow_up','welcome_new_customer','feedback_request','cancellation_confirmation',
                             'service_due','no_response_follow_up','reschedule_confirmation','booking_follow_up','service_completed','lead_follow_up','lead_final_follow_up')
            order by f.updated_at limit greatest(1, least(coalesce(p_limit, 50), 200)) loop
    continue when not exists (select 1 from public.customers c where c.id = t.customer_id and not coalesce(c.do_not_contact, false) and not coalesce(c.do_not_email, false) and public.zella_valid_email(c.email));
    continue when exists (select 1 from public.followup_tasks e where e.customer_id = t.customer_id and e.kind = t.kind and e.channel = 'email'
                             and e.appointment_id is not distinct from t.appointment_id and e.created_at >= t.created_at);
    insert into public.followup_tasks (business_id, customer_id, appointment_id, kind, channel, due_at, max_attempts, vars)
    values (t.business_id, t.customer_id, t.appointment_id, t.kind, 'email', now(), 2, t.vars);
    n := n + 1;
  end loop;
  for r in select business_id, count(*) as failed from public.sms_messages
            where direction = 'outbound' and status = 'failed' and created_at > now() - interval '1 hour' group by business_id having count(*) >= 5 loop
    perform public.zella_platform_alert('sms_failures', 'Many texts are failing', r.failed || ' texts failed in the last hour. Check the Telnyx connection and the sender number.', 'warning', r.business_id, 'sms_failures:' || r.business_id, '{}'::jsonb);
  end loop;
  return n;
end $$;
revoke all on function public.zella_recover_failed_texts(integer) from public, anon, authenticated;
grant execute on function public.zella_recover_failed_texts(integer) to service_role;

-- 6. Wording preview and a count of what was sent (65).
create or replace function public.zella_preview_template(p_business_id uuid, p_key text, p_channel text, p_vars jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare t public.message_templates; b text; v_body text; v_subject text; kv record; v_missing text[];
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_channel not in ('sms', 'email') then raise exception 'BAD_CHANNEL'; end if;
  select name into b from public.businesses where id = p_business_id;
  select * into t from public.zella_resolve_template(p_business_id, p_key, p_channel, 'en-US');
  if t.id is null then return jsonb_build_object('found', false); end if;
  v_body := replace(replace(t.body, '{{first_name}}', 'Alex'), '{{business}}', coalesce(b, 'Your business'));
  v_subject := replace(replace(coalesce(t.subject, ''), '{{first_name}}', 'Alex'), '{{business}}', coalesce(b, 'Your business'));
  for kv in select key, value from jsonb_each_text(coalesce(p_vars, '{}'::jsonb)) loop
    v_body := replace(v_body, '{{' || kv.key || '}}', left(kv.value, 200)); v_subject := replace(v_subject, '{{' || kv.key || '}}', left(kv.value, 200));
  end loop;
  select array_agg(distinct m[1]) into v_missing from regexp_matches(v_body || ' ' || v_subject, '\{\{([^}]*)\}\}', 'g') m;
  return jsonb_build_object('found', true, 'subject', nullif(v_subject, ''), 'body', v_body, 'missing', coalesce(to_jsonb(v_missing), '[]'::jsonb), 'version', t.version, 'own_wording', t.business_id is not null);
end $$;
revoke execute on function public.zella_preview_template(uuid, text, text, jsonb) from public, anon;
grant execute on function public.zella_preview_template(uuid, text, text, jsonb) to authenticated, service_role;

create or replace function public.zella_message_summary(p_business_id uuid, p_days integer default 30)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d interval := make_interval(days => greatest(1, least(coalesce(p_days, 30), 365)));
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  return jsonb_build_object(
    'texts', coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from public.sms_messages where business_id = p_business_id and direction = 'outbound' and created_at > now() - d group by status) x), '{}'::jsonb),
    'emails', coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from public.email_messages where business_id = p_business_id and direction = 'outbound' and created_at > now() - d group by status) x), '{}'::jsonb),
    'replies', (select count(*) from public.sms_messages where business_id = p_business_id and direction = 'inbound' and created_at > now() - d),
    'unsubscribed', (select count(*) from public.contact_consents where business_id = p_business_id and status = 'opted_out' and recorded_at > now() - d));
end $$;
revoke execute on function public.zella_message_summary(uuid, integer) from public, anon;
grant execute on function public.zella_message_summary(uuid, integer) to authenticated, service_role;

-- 7. Campaign report (100): from first touch to booked and won, for every source (website, Meta, calls).
create or replace function public.zella_campaign_report(p_business_id uuid, p_from timestamptz default now() - interval '30 days', p_to timestamptz default now())
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((select jsonb_agg(r order by r.leads desc) from (
    select coalesce(nullif(c.qualification #>> '{attribution,first_touch,utm_source}', ''), nullif(lower(c.source), ''), 'unknown') as source,
           coalesce(nullif(c.qualification #>> '{attribution,first_touch,utm_campaign}', ''), '(none)') as campaign,
           count(*) as leads,
           count(*) filter (where c.lead_stage in ('qualified', 'quote_sent', 'won') or c.qualification ? 'need') as qualified,
           count(*) filter (where exists (select 1 from public.appointments a where a.customer_id = c.id and a.status <> 'cancelled')) as booked,
           count(*) filter (where c.lead_stage = 'won') as won
      from public.customers c
     where c.business_id = p_business_id and c.created_at >= p_from and c.created_at <= p_to
       and c.lead_stage is not null
     group by 1, 2) r), '[]'::jsonb);
end $$;
revoke execute on function public.zella_campaign_report(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.zella_campaign_report(uuid, timestamptz, timestamptz) to authenticated, service_role;
