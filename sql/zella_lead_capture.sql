-- Zella - lead capture from websites and chat widgets. Safe to run more than once.
-- One public entry point (zella_capture_web_lead) used by the website-intake edge function. It validates, blocks spam,
-- matches an existing person, records where the lead came from, creates the callback or notice, and records consent.
-- The existing assignment, callback and notification rules then take over. Nothing here sends a message by itself.

create table if not exists public.website_forms (
  id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
  name text not null default 'Website', public_key text not null unique default replace(gen_random_uuid()::text, '-', ''),
  allowed_origins text[] not null default '{}', enabled boolean not null default true, created_at timestamptz not null default now());
alter table public.website_forms enable row level security;
drop policy if exists website_forms_read on public.website_forms;
create policy website_forms_read on public.website_forms for select to authenticated using (public.zella_is_member(business_id));

create table if not exists public.lead_submissions (
  id uuid primary key default gen_random_uuid(), business_id uuid not null, form_id uuid, kind text not null, channel text not null default 'website',
  status text not null check (status in ('accepted','duplicate','spam','invalid','rate_limited','failed')),
  customer_id uuid, callback_id uuid, source jsonb not null default '{}'::jsonb, summary text, urgent boolean not null default false,
  created_at timestamptz not null default now());
create index if not exists lead_submissions_biz_idx on public.lead_submissions (business_id, created_at desc);
alter table public.lead_submissions enable row level security;
drop policy if exists lead_submissions_read on public.lead_submissions;
create policy lead_submissions_read on public.lead_submissions for select to authenticated using (public.zella_is_member(business_id));

-- A business admin creates (or lists) the form key their website uses.
create or replace function public.zella_create_website_form(p_business_id uuid, p_name text default 'Website', p_allowed_origins text[] default '{}')
returns text language plpgsql security definer set search_path = public as $$
declare v_key text;
begin
  if auth.uid() is not null and not exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active' and m.role in ('owner','admin','manager')) then
    raise exception 'NOT_ALLOWED';
  end if;
  insert into public.website_forms (business_id, name, allowed_origins) values (p_business_id, left(coalesce(nullif(trim(p_name), ''), 'Website'), 80), coalesce(p_allowed_origins, '{}'))
  returning public_key into v_key;
  return v_key;
end $$;

create or replace function public.zella_capture_web_lead(
  p_public_key text, p_kind text, p_name text default null, p_phone text default null, p_email text default null, p_message text default null,
  p_source jsonb default '{}'::jsonb, p_marketing_consent boolean default false, p_origin text default null, p_ip text default null,
  p_honeypot text default null, p_channel text default 'website')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  f public.website_forms; v_kind text; v_channel text; v_name text; v_phone text; v_email text; v_msg text; v_src jsonb := '{}'::jsonb;
  v_cust uuid; v_cb uuid; v_sub uuid; v_urgent boolean; v_first text; v_last text; k text; v_summary text; v_reason text; v_ack text;
  v_digits text;
begin
  select * into f from public.website_forms where public_key = p_public_key and enabled;
  if f.id is null then return jsonb_build_object('ok', false, 'error', 'unknown_form'); end if;
  if cardinality(f.allowed_origins) > 0 and (p_origin is null or not (lower(p_origin) = any (select lower(x) from unnest(f.allowed_origins) x))) then
    return jsonb_build_object('ok', false, 'error', 'origin_not_allowed');
  end if;

  v_kind := case when p_kind in ('contact_form','quote_request','appointment_request','callback_request','chat','newsletter_signup') then p_kind else null end;
  v_channel := case when p_channel in ('website','website_chat') then p_channel else 'website' end;
  if v_kind is null then return jsonb_build_object('ok', false, 'error', 'unknown_kind'); end if;

  if not public.zella_rate_limit('form:' || f.id::text || ':' || coalesce(left(p_ip, 64), 'x'), 5, 60) or not public.zella_rate_limit('form:' || f.id::text, 60, 60) then
    insert into public.lead_submissions (business_id, form_id, kind, channel, status) values (f.business_id, f.id, v_kind, v_channel, 'rate_limited');
    return jsonb_build_object('ok', false, 'error', 'too_many_requests');
  end if;

  v_name := left(nullif(trim(coalesce(p_name, '')), ''), 120);
  v_phone := left(nullif(trim(coalesce(p_phone, '')), ''), 40);
  v_email := left(nullif(lower(trim(coalesce(p_email, ''))), ''), 254);
  v_msg := left(nullif(trim(coalesce(p_message, '')), ''), 2000);
  v_digits := public.zella_digits(v_phone);
  v_ack := 'Thank you. We have your details and will be in touch soon.';

  -- Spam: hidden field filled in, or a message stuffed with links. Look successful so bots learn nothing.
  if nullif(trim(coalesce(p_honeypot, '')), '') is not null or (length(coalesce(v_msg, '')) - length(replace(lower(coalesce(v_msg, '')), 'http', ''))) / 4 > 2 then
    insert into public.lead_submissions (business_id, form_id, kind, channel, status) values (f.business_id, f.id, v_kind, v_channel, 'spam');
    return jsonb_build_object('ok', true, 'message', v_ack);
  end if;

  -- Validation, with messages a visitor can act on.
  if v_phone is not null and (v_digits is null or length(v_digits) < 7 or length(v_digits) > 15) then
    return jsonb_build_object('ok', false, 'error', 'invalid_phone', 'message', 'Please enter a valid phone number.');
  end if;
  if v_email is not null and not public.zella_valid_email(v_email) then
    return jsonb_build_object('ok', false, 'error', 'invalid_email', 'message', 'Please enter a valid email address.');
  end if;
  if v_phone is null and v_email is null then
    return jsonb_build_object('ok', false, 'error', 'no_contact', 'message', 'Please give a phone number or an email address so we can reply.');
  end if;
  if v_kind = 'newsletter_signup' and v_email is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_email', 'message', 'Please enter your email address.');
  end if;

  -- Where it came from. Only known keys, trimmed.
  foreach k in array array['utm_source','utm_medium','utm_campaign','utm_term','utm_content','referrer','page_url'] loop
    if nullif(trim(coalesce(p_source ->> k, '')), '') is not null then v_src := v_src || jsonb_build_object(k, left(p_source ->> k, 300)); end if;
  end loop;

  v_urgent := coalesce(v_msg ~* '(emergency|urgent|asap|right now|immediately|flood|leak|no heat|no power|burst)', false);

  begin
    -- Match an existing person by phone or email, otherwise add a new lead.
    select m.customer_id into v_cust from public.zella_match_customer(f.business_id, v_phone, v_email) m where m.certainty = 'exact' limit 1;
    if v_cust is null then
      v_first := split_part(coalesce(v_name, ''), ' ', 1);
      v_last := nullif(trim(substr(coalesce(v_name, ''), length(v_first) + 1)), '');
      insert into public.customers (business_id, first_name, last_name, phone, email, status, source, lead_stage, priority, qualification, metadata)
      values (f.business_id, coalesce(nullif(v_first, ''), 'Website visitor'), v_last, v_phone, v_email, 'active', v_channel, 'new',
              case when v_urgent then 'high' else 'normal' end,
              jsonb_build_object('kind', v_kind, 'urgent', v_urgent, 'has_phone', v_phone is not null, 'has_email', v_email is not null),
              jsonb_build_object('attribution', jsonb_build_object('first_touch', v_src || jsonb_build_object('channel', v_channel, 'at', now()))))
      returning id into v_cust;
    else
      update public.customers set
          metadata = jsonb_set(coalesce(metadata, '{}'::jsonb), '{attribution,last_touch}', v_src || jsonb_build_object('channel', v_channel, 'at', now()), true),
          priority = case when v_urgent then 'high' else priority end, updated_at = now()
        where id = v_cust;
      -- Same person, same kind, last 10 minutes: count it once.
      if exists (select 1 from public.lead_submissions s where s.customer_id = v_cust and s.kind = v_kind and s.status = 'accepted' and s.created_at > now() - interval '10 minutes') then
        insert into public.lead_submissions (business_id, form_id, kind, channel, status, customer_id, source) values (f.business_id, f.id, v_kind, v_channel, 'duplicate', v_cust, v_src);
        return jsonb_build_object('ok', true, 'message', v_ack);
      end if;
    end if;

    -- Consent to marketing messages, recorded as given on the form.
    if v_kind = 'newsletter_signup' or p_marketing_consent then
      if v_email is not null then
        insert into public.contact_consents (business_id, customer_id, email_lower, channel, purpose, status, source, evidence)
        values (f.business_id, v_cust, v_email, 'email', 'marketing', 'opted_in', 'web_form', jsonb_build_object('form_id', f.id, 'origin', left(p_origin, 200), 'at', now()));
      end if;
      if v_digits is not null and p_marketing_consent then
        insert into public.contact_consents (business_id, customer_id, phone_digits, channel, purpose, status, source, evidence)
        values (f.business_id, v_cust, v_digits, 'sms', 'marketing', 'opted_in', 'web_form', jsonb_build_object('form_id', f.id, 'origin', left(p_origin, 200), 'at', now()));
      end if;
    end if;

    v_summary := left(case v_kind
        when 'quote_request' then 'Quote request' when 'appointment_request' then 'Wants an appointment'
        when 'callback_request' then 'Asked for a call back' when 'chat' then 'Website chat enquiry'
        when 'newsletter_signup' then 'Newsletter signup' else 'Website enquiry' end
      || coalesce(': ' || v_msg, ''), 600);
    v_reason := case v_kind when 'appointment_request' then 'appointment_request' when 'callback_request' then 'requested' else 'new_lead' end;

    -- Something for the team to act on: a callback when there is a phone, otherwise a notice.
    if v_kind <> 'newsletter_signup' then
      if v_digits is not null then
        v_cb := public.zella_create_callback(f.business_id, v_phone, v_reason, case when v_urgent then 'high' else 'normal' end, v_summary, null, v_cust, null, null, 'system',
                                             case when v_reason = 'new_lead' then 'new_lead_callback' else 'missed_call_follow_up' end);
      else
        perform public.zella_notify(f.business_id, 'website_lead', 'New website enquiry', v_summary || ' (email only: ' || v_email || ')', case when v_urgent then 'urgent' else 'info' end, 'customers', v_cust);
      end if;
    end if;

    insert into public.lead_submissions (business_id, form_id, kind, channel, status, customer_id, callback_id, source, summary, urgent)
    values (f.business_id, f.id, v_kind, v_channel, 'accepted', v_cust, v_cb, v_src, v_summary, v_urgent) returning id into v_sub;
    return jsonb_build_object('ok', true, 'message', v_ack, 'submission_id', v_sub);
  exception when others then
    insert into public.lead_submissions (business_id, form_id, kind, channel, status, source) values (f.business_id, f.id, v_kind, v_channel, 'failed', v_src);
    perform public.zella_platform_alert('lead_capture_failed', 'A website lead could not be saved', left(sqlerrm, 200), 'warning', f.business_id, 'lead_capture_failed:' || f.business_id::text);
    return jsonb_build_object('ok', false, 'error', 'try_again', 'message', 'Something went wrong. Please try again or call us.');
  end;
end $$;

-- Which sources and campaigns bring leads, and how many become customers.
create or replace function public.zella_lead_source_report(p_business_id uuid, p_from timestamptz default now() - interval '30 days', p_to timestamptz default now())
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((select jsonb_agg(r order by r.leads desc) from (
    select coalesce(s.source ->> 'utm_source', s.channel) as source, coalesce(s.source ->> 'utm_campaign', '(none)') as campaign,
           count(distinct s.customer_id) as leads, count(*) as submissions,
           count(distinct s.customer_id) filter (where c.lead_stage = 'won') as won
      from public.lead_submissions s left join public.customers c on c.id = s.customer_id
     where s.business_id = p_business_id and s.status = 'accepted' and s.created_at >= p_from and s.created_at < p_to
     group by 1, 2) r), '[]'::jsonb);
end $$;

do $$
begin
  revoke execute on function public.zella_capture_web_lead(text,text,text,text,text,text,jsonb,boolean,text,text,text,text) from public, anon, authenticated;
  grant execute on function public.zella_capture_web_lead(text,text,text,text,text,text,jsonb,boolean,text,text,text,text) to service_role;
  revoke execute on function public.zella_create_website_form(uuid,text,text[]), public.zella_lead_source_report(uuid,timestamptz,timestamptz) from public, anon;
  grant execute on function public.zella_create_website_form(uuid,text,text[]), public.zella_lead_source_report(uuid,timestamptz,timestamptz) to authenticated, service_role;
end $$;
