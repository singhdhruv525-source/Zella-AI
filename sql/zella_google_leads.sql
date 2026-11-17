-- Google Ads lead forms → Zella leads (5 Nov 2026). The setup wizard already offers "Google Ads lead forms and Business
-- Profile" as a lead source and production's salon switched it on, but nothing received Google leads.
--
-- How it works (Google's lead form webhook; no Google login or API access needed):
--   * An owner or admin creates the business's Google key (Settings / Integrations). It is shown once, with the webhook
--     address, to paste into each Google Ads lead form; Zella keeps only its SHA-256 hash and the last 4 characters.
--   * Google posts each lead to the google-lead edge function, which passes it to zella_capture_google_lead (server
--     only). The key finds the business; a wrong or revoked key is refused.
--   * Google retries: the same lead id is accepted once and acknowledged after that. Google's "Send test data" is
--     acknowledged and shown as "test received" without creating anyone.
--   * A real lead goes through the same path as a website enquiry: matched to an existing customer by phone or email,
--     or created as a new lead (source google_ads, with the campaign / ad group / form ids); a callback for the team when
--     there is a phone number, a notification otherwise; logged in Lead sources. Marketing consent is never assumed.
--   * At most 120 leads a minute per business; anything that fails is logged and raises a platform alert, and Google is
--     told to retry.
-- Needs zella_viewer_read_only.sql. Safe to run twice. Needs the owner's approval, and the edge function deployed.

create table if not exists public.google_lead_keys (
  business_id uuid primary key references public.businesses(id) on delete cascade,
  key_hash text not null unique,
  key_hint text not null,
  enabled boolean not null default true,
  created_by uuid,
  created_at timestamptz not null default now(),
  last_lead_at timestamptz,
  test_received_at timestamptz
);
create table if not exists public.google_lead_events (
  business_id uuid not null references public.businesses(id) on delete cascade,
  lead_id text not null,
  submission_id uuid,
  received_at timestamptz not null default now(),
  primary key (business_id, lead_id)
);
alter table public.google_lead_keys enable row level security;
alter table public.google_lead_events enable row level security;
revoke all on public.google_lead_keys, public.google_lead_events from anon, authenticated;
grant select, insert, update, delete on public.google_lead_keys, public.google_lead_events to service_role;

-- owners and admins: create (or replace) the key; shown once
create or replace function public.zella_google_lead_key_create(p_business_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_key text := 'zg_' || replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  insert into public.google_lead_keys (business_id, key_hash, key_hint, enabled, created_by)
  values (p_business_id, encode(sha256(convert_to(v_key, 'UTF8')), 'hex'), right(v_key, 4), true, auth.uid())
  on conflict (business_id) do update set key_hash = excluded.key_hash, key_hint = excluded.key_hint, enabled = true, created_by = excluded.created_by,
    created_at = now(), test_received_at = null;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (p_business_id, auth.uid(), 'google_lead_key_created', 'business', p_business_id, jsonb_build_object('hint', right(v_key, 4)));
  return jsonb_build_object('key', v_key, 'hint', right(v_key, 4));
end $$;

create or replace function public.zella_google_lead_key_revoke(p_business_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  update public.google_lead_keys set enabled = false where business_id = p_business_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id) values (p_business_id, auth.uid(), 'google_lead_key_revoked', 'business', p_business_id);
  return jsonb_build_object('enabled', false);
end $$;

-- the team (manager and above): is it connected, and is anything arriving?
create or replace function public.zella_google_lead_status(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare k record;
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  select * into k from public.google_lead_keys where business_id = p_business_id;
  return jsonb_build_object('has_key', k.business_id is not null, 'enabled', coalesce(k.enabled, false), 'hint', k.key_hint,
    'created_at', k.created_at, 'last_lead_at', k.last_lead_at, 'test_received_at', k.test_received_at,
    'leads_30d', (select count(*) from public.lead_submissions s where s.business_id = p_business_id and s.channel = 'google_ads' and s.status = 'accepted'
                   and s.created_at > now() - interval '30 days'));
end $$;

-- server only: one lead from Google
create or replace function public.zella_capture_google_lead(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  k record; b record; col jsonb; v_id text; v_first text; v_last text; v_full text; v_phone text; v_email text; v_digits text;
  v_answers text := ''; v_src jsonb; v_cust uuid; v_cb uuid; v_sub uuid; v_summary text;
begin
  if jsonb_typeof(p_payload) <> 'object' or nullif(p_payload ->> 'google_key', '') is null then return jsonb_build_object('ok', false, 'error', 'bad_key'); end if;
  select * into k from public.google_lead_keys where key_hash = encode(sha256(convert_to(p_payload ->> 'google_key', 'UTF8')), 'hex') and enabled;
  if not found then return jsonb_build_object('ok', false, 'error', 'bad_key'); end if;
  select id, suspended_at, cancelled_at, is_active into b from public.businesses where id = k.business_id;
  if b.suspended_at is not null or b.cancelled_at is not null then return jsonb_build_object('ok', false, 'error', 'business_unavailable'); end if;

  if coalesce((p_payload ->> 'is_test')::boolean, false) then
    update public.google_lead_keys set test_received_at = now() where business_id = k.business_id;
    return jsonb_build_object('ok', true, 'test', true);
  end if;
  v_id := left(nullif(p_payload ->> 'lead_id', ''), 200);
  if v_id is null then return jsonb_build_object('ok', false, 'error', 'bad_payload'); end if;
  if exists (select 1 from public.google_lead_events where business_id = k.business_id and lead_id = v_id) then
    return jsonb_build_object('ok', true, 'duplicate', true);
  end if;
  if not public.zella_rate_limit('google_lead:' || k.business_id::text, 120, 60) then
    insert into public.lead_submissions (business_id, kind, channel, status) values (k.business_id, 'google_lead_form', 'google_ads', 'rate_limited');
    return jsonb_build_object('ok', false, 'error', 'too_many_requests');
  end if;

  for col in select * from jsonb_array_elements(case when jsonb_typeof(p_payload -> 'user_column_data') = 'array' then p_payload -> 'user_column_data' else '[]' end) loop
    case upper(coalesce(col ->> 'column_id', ''))
      when 'FULL_NAME' then v_full := left(col ->> 'string_value', 120);
      when 'FIRST_NAME' then v_first := left(col ->> 'string_value', 80);
      when 'LAST_NAME' then v_last := left(col ->> 'string_value', 80);
      when 'PHONE_NUMBER' then v_phone := left(col ->> 'string_value', 40);
      when 'EMAIL' then v_email := lower(left(col ->> 'string_value', 254));
      when 'WORK_EMAIL' then v_email := coalesce(v_email, lower(left(col ->> 'string_value', 254)));
      when 'WORK_PHONE' then v_phone := coalesce(v_phone, left(col ->> 'string_value', 40));
      else
        if nullif(col ->> 'string_value', '') is not null then
          v_answers := v_answers || E'\n' || left(coalesce(nullif(col ->> 'column_name', ''), initcap(replace(lower(col ->> 'column_id'), '_', ' ')), 'Answer'), 80)
                       || ': ' || left(col ->> 'string_value', 300);
        end if;
    end case;
  end loop;
  if v_first is null and v_full is not null then
    v_first := split_part(v_full, ' ', 1); v_last := coalesce(v_last, nullif(trim(substr(v_full, length(v_first) + 1)), ''));
  end if;
  v_digits := nullif(regexp_replace(coalesce(v_phone, ''), '\D', '', 'g'), '');
  if v_digits is not null and (length(v_digits) < 7 or length(v_digits) > 15) then v_phone := null; v_digits := null; end if;
  -- stored in one form (+ and digits), so matching, duplicates and texts all see the same number
  if v_digits is not null then
    v_phone := case when v_phone like '+%' then '+' || v_digits when length(v_digits) = 10 then '+1' || v_digits
                    when length(v_digits) = 11 and left(v_digits, 1) = '1' then '+' || v_digits else v_digits end;
  end if;
  if v_email is not null and not public.zella_valid_email(v_email) then v_email := null; end if;
  if v_phone is null and v_email is null then
    insert into public.lead_submissions (business_id, kind, channel, status, source) values (k.business_id, 'google_lead_form', 'google_ads', 'invalid', jsonb_build_object('google_lead_id', v_id));
    insert into public.google_lead_events (business_id, lead_id) values (k.business_id, v_id);
    return jsonb_build_object('ok', true, 'ignored', 'no_contact');
  end if;
  v_src := jsonb_strip_nulls(jsonb_build_object('google_lead_id', v_id, 'form_id', p_payload ->> 'form_id', 'campaign_id', p_payload ->> 'campaign_id',
            'adgroup_id', p_payload ->> 'adgroup_id', 'creative_id', p_payload ->> 'creative_id', 'gcl_id', left(p_payload ->> 'gcl_id', 200)));
  v_summary := left('Google Ads lead form' || coalesce(':' || nullif(v_answers, ''), ''), 600);

  begin
    select m.customer_id into v_cust from public.zella_match_customer(k.business_id, v_phone, v_email) m where m.certainty = 'exact' limit 1;
    if v_cust is null then
      insert into public.customers (business_id, first_name, last_name, phone, email, status, source, lead_stage, priority, notes, metadata)
      values (k.business_id, coalesce(nullif(v_first, ''), 'Google lead'), v_last, v_phone, v_email, 'active', 'google_ads', 'new', 'normal',
              nullif(trim(v_answers), ''), jsonb_build_object('attribution', jsonb_build_object('first_touch', v_src || jsonb_build_object('channel', 'google_ads', 'at', now()))))
      returning id into v_cust;
    else
      update public.customers set metadata = jsonb_set(coalesce(metadata, '{}'::jsonb), '{attribution,last_touch}', v_src || jsonb_build_object('channel', 'google_ads', 'at', now()), true),
             updated_at = now() where id = v_cust;
    end if;
    if v_digits is not null then
      v_cb := public.zella_create_callback(k.business_id, v_phone, 'new_lead', 'normal', v_summary, null, v_cust, null, null, 'system', 'new_lead_callback');
    else
      perform public.zella_notify(k.business_id, 'website_lead', 'New Google lead', v_summary || ' (email only: ' || v_email || ')', 'info', 'customers', v_cust);
    end if;
    insert into public.lead_submissions (business_id, kind, channel, status, customer_id, callback_id, source, summary)
    values (k.business_id, 'google_lead_form', 'google_ads', 'accepted', v_cust, v_cb, v_src, v_summary) returning id into v_sub;
    insert into public.google_lead_events (business_id, lead_id, submission_id) values (k.business_id, v_id, v_sub);
    update public.google_lead_keys set last_lead_at = now() where business_id = k.business_id;
    return jsonb_build_object('ok', true, 'customer_id', v_cust, 'submission_id', v_sub);
  exception when others then
    insert into public.lead_submissions (business_id, kind, channel, status, source) values (k.business_id, 'google_lead_form', 'google_ads', 'failed', v_src);
    perform public.zella_platform_alert('lead_capture_failed', 'A Google lead could not be saved', left(sqlerrm, 200), 'warning', k.business_id, 'lead_capture_failed:' || k.business_id::text);
    return jsonb_build_object('ok', false, 'error', 'try_again');
  end;
end $$;

revoke execute on function public.zella_google_lead_key_create(uuid), public.zella_google_lead_key_revoke(uuid), public.zella_google_lead_status(uuid),
  public.zella_capture_google_lead(jsonb) from public, anon;
grant execute on function public.zella_google_lead_key_create(uuid), public.zella_google_lead_key_revoke(uuid), public.zella_google_lead_status(uuid) to authenticated, service_role;
revoke execute on function public.zella_capture_google_lead(jsonb) from authenticated;
grant execute on function public.zella_capture_google_lead(jsonb) to service_role;
