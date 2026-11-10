CREATE OR REPLACE FUNCTION public.zella_meta_token(p_page_id text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_sec text; v_tok text;
begin
  select token_secret into v_sec from public.meta_connections where page_id = p_page_id and status in ('connected', 'error');
  if v_sec is null then return null; end if;
  select decrypted_secret into v_tok from vault.decrypted_secrets where name = v_sec limit 1;
  return v_tok;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_meta_verify_token(p_token text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v text;
begin
  select decrypted_secret into v from vault.decrypted_secrets where name = 'zella_meta_verify_token' limit 1;
  if v is null or v = '' or p_token is null then return false; end if;
  return encode(sha256(convert_to(p_token, 'utf8')), 'hex') = encode(sha256(convert_to(v, 'utf8')), 'hex');
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_milestone_once(p_business_id uuid, p_key text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  insert into public.zella_milestones (business_id, key) values (p_business_id, p_key) on conflict do nothing;
  return found;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_module_on(p_business_id uuid, p_slug text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1
      from public.business_modules bm
      join public.industry_modules im on im.id = bm.module_id
      join public.businesses b on b.id = bm.business_id
     where bm.business_id = p_business_id
       and bm.enabled
       and im.slug = p_slug
       and im.is_active
       and im.industry_id = b.industry_id   -- a module of another industry never counts
  );
$function$
;
CREATE OR REPLACE FUNCTION public.zella_move_open_work(p_business_id uuid, p_from uuid, p_to uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a int; b int; c int;
begin
  update public.customers set assigned_to = p_to, updated_at = now()
   where business_id = p_business_id and assigned_to = p_from and lead_stage in ('new','contacted','qualified','quote_sent');
  get diagnostics a = row_count;
  update public.callbacks set assigned_to = p_to, updated_at = now()
   where business_id = p_business_id and assigned_to = p_from and status not in ('completed','done','reached','cancelled','failed');
  get diagnostics b = row_count;
  update public.customer_requests set assigned_to = p_to, updated_at = now()
   where business_id = p_business_id and assigned_to = p_from and status not in ('resolved','closed','cancelled');
  get diagnostics c = row_count;
  return jsonb_build_object('leads', a, 'callbacks', b, 'requests', c);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_my_admin_alert_email(p_enabled boolean DEFAULT NULL::boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v boolean;
begin
  if public.zella_admin_role() is null then raise exception 'NOT_ALLOWED'; end if;
  if p_enabled is not null then
    insert into public.admin_alert_prefs (user_id, email_enabled) values (auth.uid(), p_enabled)
    on conflict (user_id) do update set email_enabled = excluded.email_enabled, updated_at = now();
  end if;
  select email_enabled into v from public.admin_alert_prefs where user_id = auth.uid();
  return coalesce(v, true);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_my_notification_prefs(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((select jsonb_object_agg(np.notification_type, np.email_enabled) from public.notification_preferences np
                    where np.business_id = p_business_id and np.user_id = auth.uid()), '{}'::jsonb);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_my_profile()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object('first_name', p.first_name, 'last_name', p.last_name, 'phone', p.phone, 'avatar_url', p.avatar_url)
    from public.profiles p where p.id = auth.uid();
$function$
;
CREATE OR REPLACE FUNCTION public.zella_my_sessions()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', s.id, 'created_at', s.created_at, 'last_active_at', coalesce(s.refreshed_at::timestamptz, s.updated_at, s.created_at),
      'user_agent', left(s.user_agent, 300), 'ip', host(s.ip), 'aal', s.aal,
      'current', s.id::text = coalesce(auth.jwt() ->> 'session_id', '')) order by coalesce(s.refreshed_at::timestamptz, s.updated_at, s.created_at) desc), '[]'::jsonb)
  from auth.sessions s where s.user_id = auth.uid();
$function$
;
CREATE OR REPLACE FUNCTION public.zella_my_workspaces()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(w order by w->>'name'), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'id', b.id,
      'name', b.name,
      'timezone', coalesce(b.timezone, 'America/New_York'),
      'industry', i.name,
      'role', m.role,
      'is_active', b.is_active,
      'onboarding_status', b.onboarding_status,
      'suspended_at', b.suspended_at,
      'cancel_at', b.cancel_at,
      'cancelled_at', b.cancelled_at,
      'terminology', coalesce(ic.terminology, '{}'::jsonb)
                     || coalesce(b.terminology_overrides, '{}'::jsonb),
      'modules', coalesce((
        select jsonb_agg(im.slug order by im.slug)
        from business_modules bm
        join industry_modules im on im.id = bm.module_id
        where bm.business_id = b.id and bm.enabled
      ), '[]'::jsonb),
      'receptionist', (
        select jsonb_build_object('name', a.name, 'status', a.status)
        from ai_agents a
        where a.business_id = b.id and a.agent_type = 'receptionist'
        order by a.is_default desc, a.created_at
        limit 1
      ),
      'phone_connected', exists (
        select 1 from integrations x
        where x.business_id = b.id and lower(x.provider) = 'telnyx' and x.status = 'active'
      ),
      'voice_connected', exists (
        select 1 from integrations x
        where x.business_id = b.id and lower(x.provider) = 'vapi' and x.status = 'active'
      )
    ) as w
    from business_members m
    join businesses b on b.id = m.business_id
    left join industries i on i.id = b.industry_id
    left join industry_configurations ic on ic.industry_id = b.industry_id
    where m.user_id = auth.uid()
      and m.status = 'active'
  ) workspaces;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_next_call_time(p_at timestamp with time zone, p_timezone text, p_start time without time zone DEFAULT '09:00:00'::time without time zone, p_end time without time zone DEFAULT '19:00:00'::time without time zone)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
declare
  v_tz text := coalesce(nullif(p_timezone, ''), 'America/New_York');
  v_local timestamp := p_at at time zone v_tz;
  v_time time := v_local::time;
begin
  if v_time >= p_start and v_time < p_end then
    return p_at;
  end if;
  if v_time < p_start then
    return (v_local::date + p_start) at time zone v_tz;
  end if;
  return ((v_local::date + 1) + p_start) at time zone v_tz;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_normalize_e164(p_number text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  select case
    when p_number is null then null
    when regexp_replace(p_number, '[^0-9]', '', 'g') ~ '^[0-9]{10}$' then '+1' || regexp_replace(p_number, '[^0-9]', '', 'g')
    when regexp_replace(p_number, '[^0-9]', '', 'g') ~ '^1[0-9]{10}$' then '+' || regexp_replace(p_number, '[^0-9]', '', 'g')
    when p_number ~ '^\+[1-9][0-9]{7,14}$' then p_number
    else null end;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_notify(p_business_id uuid, p_kind text, p_title text, p_body text DEFAULT NULL::text, p_severity text DEFAULT 'info'::text, p_page_key text DEFAULT NULL::text, p_entity_id uuid DEFAULT NULL::uuid, p_user_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid;
begin
  insert into public.staff_notifications (business_id, user_id, kind, severity, title, body, page_key, entity_id)
  values (p_business_id, p_user_id, p_kind, p_severity, p_title, p_body, p_page_key, p_entity_id) returning id into v_id;
  return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_notify_message_failures()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; n integer := 0;
begin
  for r in
    select business_id, sum(k)::int as failed from (
      select business_id, count(*) k from public.sms_messages where direction = 'outbound' and status = 'failed' and created_at > now() - interval '24 hours' group by business_id
      union all
      select business_id, count(*) from public.email_messages where direction = 'outbound' and status = 'failed' and created_at > now() - interval '24 hours' group by business_id) x
    group by business_id loop
    continue when exists (select 1 from public.staff_notifications where business_id = r.business_id and kind = 'messages_failed' and created_at > now() - interval '20 hours');
    perform public.zella_notify_owners(r.business_id, 'messages_failed', r.failed || (case when r.failed = 1 then ' message' else ' messages' end) || ' could not be sent',
      'Check the phone number and email address on the customer, or ask for help if this keeps happening.', 'warning', 'inbox');
    n := n + 1;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_notify_owners(p_business_id uuid, p_kind text, p_title text, p_body text, p_severity text DEFAULT 'warning'::text, p_page_key text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform public.zella_notify(p_business_id, p_kind, p_title, p_body, p_severity, p_page_key, null, null);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offboard_member(p_business_id uuid, p_user_id uuid, p_reassign_to uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_role text; v_moved jsonb := '{}'::jsonb;
begin
  if auth.uid() is not null and not exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active' and m.role in ('owner','admin')) then
    raise exception 'NOT_ALLOWED';
  end if;
  select role into v_role from public.business_members where business_id = p_business_id and user_id = p_user_id;
  if v_role is null then raise exception 'NOT_A_MEMBER'; end if;
  if v_role = 'owner' and not exists (select 1 from public.business_members m where m.business_id = p_business_id and m.role = 'owner' and m.status = 'active' and m.user_id <> p_user_id) then
    raise exception 'LAST_OWNER';
  end if;
  update public.business_members set status = 'suspended', accepts_work = false where business_id = p_business_id and user_id = p_user_id;
  if p_reassign_to is not null then
    v_moved := public.zella_move_open_work(p_business_id, p_user_id, p_reassign_to);
  else
    update public.customers set assigned_to = null where business_id = p_business_id and assigned_to = p_user_id;
    update public.callbacks set assigned_to = null where business_id = p_business_id and assigned_to = p_user_id and status not in ('completed','done','reached','cancelled','failed');
    update public.customer_requests set assigned_to = null where business_id = p_business_id and assigned_to = p_user_id and status not in ('resolved','closed','cancelled');
  end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (p_business_id, auth.uid(), 'member_offboarded', 'business_member', p_user_id, jsonb_build_object('reassigned_to', p_reassign_to, 'moved', v_moved));
  return v_moved;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_apply_admin(p_offer_id uuid, p_business_id uuid, p_note text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_res jsonb;
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  v_res := public.zella_offer_redeem_core(p_offer_id, p_business_id, 'admin', p_idempotency_key, p_note);
  return v_res || case when v_res ? 'reason' then jsonb_build_object('message', public.zella_offer_reason_text(v_res ->> 'reason')) else '{}'::jsonb end;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_audience(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o public.offers;
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  select * into o from public.offers where id = p_id;
  if not found then raise exception 'OFFER_NOT_FOUND'; end if;
  return (
    with e as (select b.id, b.name, b.business_size, public.zella_offer_is_eligible(o, b.id) ok from public.businesses b)
    select jsonb_build_object(
      'eligible', count(*) filter (where ok),
      'total', count(*),
      'missing_size', count(*) filter (where business_size is null),
      'names', coalesce((select jsonb_agg(x.name) from (select name from e where ok order by name limit 8) x), '[]'::jsonb))
    from e);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_cancel_claim(p_redemption_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.offer_redemptions;
begin
  select * into r from public.offer_redemptions where id = p_redemption_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if auth.uid() is null or not (public.zella_has_role(r.business_id, array['owner']) or public.is_platform_admin()) then raise exception 'NOT_ALLOWED'; end if;
  if r.status <> 'pending' then raise exception 'NOT_PENDING'; end if;
  update public.offer_redemptions set status = 'cancelled', ended_at = now(), updated_at = now() where id = r.id;
  perform public.zella_offer_log(r.offer_id, 'claim_cancelled', 'pending', 'cancelled', jsonb_build_object('redemption_id', r.id), r.business_id);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_capabilities()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'billing', exists (select 1 from public.billing_events where status = 'processed'),
    'checkout', false,
    'referral_tracking', false,
    'promo_sending', false
  );
$function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_channel_requires(p_channel text)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select case p_channel
    when 'dashboard' then array[]::text[]
    when 'sales' then array[]::text[]
    when 'pricing_page' then array['checkout']
    when 'signup' then array['checkout']
    when 'checkout' then array['checkout', 'billing']
    when 'email' then array['promo_sending']
    when 'referral' then array['referral_tracking']
    else array['unknown'] end;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_check_code(p_business_id uuid, p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o public.offers; v_tries int; v_reason text;
begin
  if auth.uid() is null or not public.zella_has_role(p_business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  select count(*) into v_tries from public.offer_events
  where business_id = p_business_id and kind = 'code_rejected' and created_at > now() - interval '1 hour';
  if v_tries >= 10 then return jsonb_build_object('ok', false, 'reason', 'too_many_attempts', 'message', public.zella_offer_reason_text('too_many_attempts')); end if;
  o := public.zella_offer_find_code(left(coalesce(p_code, ''), 60));
  if o.id is null then v_reason := 'not_found';
  elsif o.status = 'paused' then v_reason := 'paused';
  elsif o.status in ('expired', 'archived') or o.ends_at <= now() then v_reason := 'expired';
  elsif o.status <> 'active' or o.starts_at > now() then v_reason := 'not_found';
  elsif not ('dashboard' = any (o.channels)) then v_reason := 'not_found';
  elsif not public.zella_offer_is_eligible(o, p_business_id) then v_reason := 'not_eligible';
  end if;
  if v_reason is not null then
    insert into public.offer_events (offer_id, business_id, kind, actor, detail)
    values (case when v_reason <> 'not_found' then o.id end, p_business_id, 'code_rejected', auth.uid(), jsonb_build_object('reason', v_reason));
    return jsonb_build_object('ok', false, 'reason', v_reason, 'message', public.zella_offer_reason_text(v_reason));
  end if;
  return jsonb_build_object('ok', true, 'offer', jsonb_build_object('id', o.id, 'name', o.name, 'description', o.description,
    'summary', public.zella_offer_summary(o), 'ends_at', o.ends_at, 'timezone', o.timezone));
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_claim(p_business_id uuid, p_offer_id uuid, p_code text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o public.offers; v_res jsonb; v_source text := case when nullif(btrim(p_code), '') is not null then 'code' else 'dashboard' end;
begin
  if auth.uid() is null or not public.zella_has_role(p_business_id, array['owner']) then raise exception 'OWNER_ONLY'; end if;
  if v_source = 'code' then
    o := public.zella_offer_find_code(left(p_code, 60));
    if o.id is null or (p_offer_id is not null and o.id <> p_offer_id) then
      return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', public.zella_offer_reason_text('not_found'));
    end if;
  else
    o.id := p_offer_id;
  end if;
  v_res := public.zella_offer_redeem_core(o.id, p_business_id, v_source, p_idempotency_key);
  return v_res || case when v_res ? 'reason' then jsonb_build_object('message', public.zella_offer_reason_text(v_res ->> 'reason')) else '{}'::jsonb end;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_detail(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o public.offers;
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  select * into o from public.offers where id = p_id;
  if not found then raise exception 'OFFER_NOT_FOUND'; end if;
  return jsonb_build_object(
    'offer', to_jsonb(o) || jsonb_build_object(
      'start_local', to_char(o.starts_at at time zone o.timezone, 'YYYY-MM-DD"T"HH24:MI'),
      'end_local', to_char(o.ends_at at time zone o.timezone, 'YYYY-MM-DD"T"HH24:MI'),
      'summary', public.zella_offer_summary(o),
      'problems', to_jsonb(public.zella_offer_problems(o)),
      'needs_approval_now', public.zella_offer_needs_approval(o)),
    'events', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'kind', e.kind, 'from', e.from_status, 'to', e.to_status,
        'detail', e.detail, 'created_at', e.created_at, 'business', b.name,
        'actor', (select u.email from auth.users u where u.id = e.actor)) order by e.created_at desc)
      from (select * from public.offer_events where offer_id = o.id order by created_at desc limit 100) e
      left join public.businesses b on b.id = e.business_id), '[]'::jsonb),
    'redemptions', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'business_id', r.business_id, 'business', b.name,
        'status', r.status, 'source', r.source, 'created_at', r.created_at, 'confirmed_at', r.confirmed_at, 'hold_until', r.hold_until,
        'discount_cents', r.discount_cents, 'note', r.note) order by r.created_at desc)
      from public.offer_redemptions r join public.businesses b on b.id = r.business_id where r.offer_id = o.id), '[]'::jsonb));
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_explain(p_id uuid, p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o public.offers; facts jsonb;
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  select * into o from public.offers where id = p_id;
  facts := public.zella_offer_facts(p_business_id);
  return jsonb_build_object('eligible', public.zella_offer_is_eligible(o, p_business_id), 'match', coalesce(o.eligibility ->> 'match', 'all'),
    'facts', facts, 'rules', public.zella_offer_rule_results(o.eligibility, facts));
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_facts(p_business uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare b public.businesses; s public.subscriptions; v_paid boolean; v_had boolean; v_redeemed boolean;
begin
  select * into b from public.businesses where id = p_business;
  if not found then return null; end if;
  select * into s from public.subscriptions where business_id = p_business order by created_at desc limit 1;
  select exists (select 1 from public.payments where business_id = p_business and status = 'succeeded') into v_paid;
  select exists (select 1 from public.subscriptions where business_id = p_business) into v_had;
  select exists (select 1 from public.offer_redemptions where business_id = p_business and status in ('pending', 'confirmed')) into v_redeemed;
  return jsonb_build_object(
    'business', b.id::text,
    'business_size', b.business_size,
    'industry', b.industry_id::text,
    'country', upper(coalesce(b.country, '')),
    'plan', s.plan_id::text,
    'billing_interval', s.billing_interval,
    'subscription_status', coalesce(s.status, 'none'),
    'customer_status', case
      when s.status in ('trial', 'active', 'renewal_due', 'past_due', 'grace_period') then 'existing'
      when v_had then 'former'
      else 'new' end,
    'first_purchase', not v_paid,
    'never_redeemed', not v_redeemed,
    'cancelled', b.cancelled_at is not null,
    'suspended', b.suspended_at is not null);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_find_code(p_code text)
 RETURNS offers
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select o.* from public.offers o
  where o.code is not null and case when o.code_case_sensitive then o.code = btrim(p_code) else lower(o.code) = lower(btrim(p_code)) end
  limit 1;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_is_eligible(p_offer offers, p_business uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare facts jsonb := public.zella_offer_facts(p_business); res jsonb;
begin
  if facts is null or (facts ->> 'cancelled')::boolean or (facts ->> 'suspended')::boolean then return false; end if;
  res := public.zella_offer_rule_results(p_offer.eligibility, facts);
  if jsonb_array_length(res) = 0 then return true; end if;
  if coalesce(p_offer.eligibility ->> 'match', 'all') = 'any' then
    return exists (select 1 from jsonb_array_elements(res) x where (x ->> 'ok')::boolean);
  end if;
  return not exists (select 1 from jsonb_array_elements(res) x where not (x ->> 'ok')::boolean);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_log(p_offer uuid, p_kind text, p_from text, p_to text, p_detail jsonb DEFAULT '{}'::jsonb, p_business uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  insert into public.offer_events (offer_id, business_id, kind, from_status, to_status, actor, detail)
  values (p_offer, p_business, p_kind, p_from, p_to, auth.uid(), coalesce(p_detail, '{}'::jsonb));
  if auth.uid() is not null and p_kind not like 'claim%' then
    insert into public.audit_logs (user_id, business_id, action, entity_type, entity_id, old_data, new_data)
    values (auth.uid(), p_business, 'offer.' || p_kind, 'offer', p_offer,
            case when p_from is not null then jsonb_build_object('status', p_from) end,
            jsonb_strip_nulls(jsonb_build_object('status', p_to)) || coalesce(p_detail, '{}'::jsonb));
  end if;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_missing(p_requires text[])
 RETURNS text[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(array_agg(r) filter (where coalesce((public.zella_offer_capabilities() ->> r)::boolean, false) is not true), array[]::text[])
  from unnest(coalesce(p_requires, array[]::text[])) r;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_monitor(p_filter text DEFAULT 'all'::text, p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  return jsonb_build_object(
    'runs', coalesce((select jsonb_agg(to_jsonb(j) order by j.started_at desc) from (
        select id, job, trigger, status, processed, failures, error, detail, started_at, finished_at,
               (select u.email from auth.users u where u.id = started_by) as started_by
        from public.offer_job_runs
        where p_filter = 'all' or (p_filter = 'failed' and status in ('failed', 'partial')) or (p_filter = 'succeeded' and status = 'succeeded')
           or (p_filter = 'retried' and trigger = 'retry') or (p_filter = 'pending' and status = 'running')
        order by started_at desc limit least(greatest(p_limit, 1), 500)) j), '[]'::jsonb),
    'failures', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'kind', e.kind, 'offer_id', e.offer_id, 'offer', o.name,
        'detail', e.detail, 'created_at', e.created_at) order by e.created_at desc)
      from (select * from public.offer_events where kind in ('activation_failed', 'activation_error') order by created_at desc limit 50) e
      left join public.offers o on o.id = e.offer_id), '[]'::jsonb),
    'rejections', coalesce((select jsonb_agg(jsonb_build_object('reason', reason, 'count', n)) from (
        select detail ->> 'reason' reason, count(*) n from public.offer_events
        where kind in ('claim_rejected', 'code_rejected') and created_at > now() - interval '7 days' group by 1 order by 2 desc) x), '[]'::jsonb));
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_needs_approval(o offers)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c jsonb := public.zella_offer_rule_config('approval_thresholds');
begin
  if c is null then return false; end if;
  return o.offer_type = any (coalesce(array(select jsonb_array_elements_text(c -> 'always_types')), array[]::text[]))
      or (o.discount_kind = 'percent' and coalesce(o.percent_off_bp, 0) >= coalesce((c ->> 'percent_bp')::int, 10001))
      or (o.discount_kind = 'fixed' and coalesce(o.amount_off_cents, 0) >= coalesce((c ->> 'amount_cents')::bigint, 9223372036854775807))
      or (o.max_redemptions is null or o.max_redemptions > coalesce((c ->> 'max_redemptions')::int, 2147483647));
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_on_payment()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.offer_redemptions; v_price numeric; v_cents bigint;
begin
  if new.status = 'succeeded' and (tg_op = 'INSERT' or old.status is distinct from 'succeeded') then
    for r in select * from public.offer_redemptions where business_id = new.business_id and status = 'pending' order by created_at for update loop
      select case when s.billing_interval = 'yearly' then pl.price_yearly else pl.price_monthly end into v_price
      from public.subscriptions s join public.plans pl on pl.id = s.plan_id where s.id = new.subscription_id;
      v_cents := case when r.terms ->> 'discount_kind' = 'fixed' then (r.terms ->> 'amount_off_cents')::bigint
                      when v_price is not null and v_price > 0 then round(v_price * 100 * (r.terms ->> 'percent_off_bp')::int / 10000) end;
      update public.offer_redemptions set status = 'confirmed', payment_id = new.id, confirmed_at = now(), discount_cents = v_cents, updated_at = now() where id = r.id;
      insert into public.offer_events (offer_id, business_id, kind, from_status, to_status, detail)
      values (r.offer_id, r.business_id, 'claim_confirmed', 'pending', 'confirmed', jsonb_build_object('redemption_id', r.id, 'payment_id', new.id));
    end loop;
  elsif new.status = 'refunded' and tg_op = 'UPDATE' and old.status is distinct from 'refunded' then
    for r in select * from public.offer_redemptions where payment_id = new.id and status = 'confirmed' for update loop
      update public.offer_redemptions set status = 'reversed', ended_at = now(), updated_at = now() where id = r.id;
      insert into public.offer_events (offer_id, business_id, kind, from_status, to_status, detail)
      values (r.offer_id, r.business_id, 'claim_reversed', 'confirmed', 'reversed', jsonb_build_object('redemption_id', r.id, 'payment_id', new.id));
    end loop;
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_on_subscription()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.status in ('cancelled', 'expired') and old.status is distinct from new.status then
    with c as (
      update public.offer_redemptions set status = 'cancelled', ended_at = now(), note = 'Subscription ended before payment', updated_at = now()
      where business_id = new.business_id and status = 'pending' returning id, offer_id, business_id)
    insert into public.offer_events (offer_id, business_id, kind, from_status, to_status, detail)
    select offer_id, business_id, 'claim_cancelled', 'pending', 'cancelled', jsonb_build_object('redemption_id', id, 'why', 'subscription_ended') from c;
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_problems(o offers)
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p text[] := array[]::text[]; r jsonb; f text; ch text; miss text[];
begin
  if o.name is null or btrim(o.name) = '' then p := p || text 'Give the offer a name.'; end if;
  miss := public.zella_offer_missing(public.zella_offer_type_requires(o.offer_type));
  if cardinality(miss) > 0 then p := p || format('This offer type is not available yet (needs %s).', array_to_string(miss, ', ')); end if;
  if o.discount_kind = 'percent' and o.percent_off_bp is null then p := p || text 'Set the percentage off.'; end if;
  if o.discount_kind = 'fixed' and o.amount_off_cents is null then p := p || text 'Set the amount off.'; end if;
  if o.duration = 'repeating' and o.duration_months is null then p := p || text 'Say for how many months the discount applies.'; end if;
  if o.starts_at is null then p := p || text 'Set a start date.'; end if;
  if o.ends_at is null then p := p || text 'Set an end date.'; end if;
  if o.ends_at is not null and o.ends_at <= now() then p := p || text 'The end date has already passed.'; end if;
  if not exists (select 1 from pg_timezone_names where name = o.timezone) then p := p || text 'Choose a valid time zone.'; end if;
  if o.offer_type = 'promo_code' and o.code is null then p := p || text 'A promotional code offer needs a code.'; end if;
  if cardinality(o.channels) = 0 then p := p || text 'Choose at least one place the offer can appear.'; end if;
  foreach ch in array o.channels loop
    miss := public.zella_offer_missing(public.zella_offer_channel_requires(ch));
    if cardinality(miss) > 0 then p := p || format('"%s" is not available yet (needs %s).', ch, array_to_string(miss, ', ')); end if;
  end loop;
  if coalesce(o.eligibility ->> 'match', 'all') not in ('all', 'any') then p := p || text 'Eligibility must match all or any rules.'; end if;
  for r in select * from jsonb_array_elements(coalesce(o.eligibility -> 'rules', '[]'::jsonb)) loop
    f := r ->> 'field';
    if f not in ('business_size', 'industry', 'plan', 'business', 'customer_status', 'country', 'billing_interval',
                 'subscription_status', 'first_purchase', 'never_redeemed') then
      p := p || format('Unknown eligibility rule "%s".', coalesce(f, '?'));
    elsif f in ('first_purchase', 'never_redeemed') then
      if jsonb_typeof(r -> 'value') <> 'boolean' then p := p || format('Rule "%s" needs yes or no.', f); end if;
    elsif jsonb_typeof(r -> 'values') <> 'array' or jsonb_array_length(r -> 'values') = 0 then
      p := p || format('Rule "%s" needs at least one value.', f);
    elsif f = 'business_size' and exists (select 1 from jsonb_array_elements_text(r -> 'values') v where v not in ('small', 'medium', 'large')) then
      p := p || text 'Business size must be small, medium or large.';
    elsif f = 'industry' and exists (select 1 from jsonb_array_elements_text(r -> 'values') v
                                     where v !~* '^[0-9a-f-]{36}$' or not exists (select 1 from public.industries i where i.id = v::uuid)) then
      p := p || text 'One of the chosen industries no longer exists.';
    elsif f = 'plan' and exists (select 1 from jsonb_array_elements_text(r -> 'values') v
                                 where v !~* '^[0-9a-f-]{36}$' or not exists (select 1 from public.plans pl where pl.id = v::uuid)) then
      p := p || text 'One of the chosen plans no longer exists.';
    elsif f = 'business' and exists (select 1 from jsonb_array_elements_text(r -> 'values') v
                                     where v !~* '^[0-9a-f-]{36}$' or not exists (select 1 from public.businesses b where b.id = v::uuid)) then
      p := p || text 'One of the chosen businesses no longer exists.';
    elsif f = 'customer_status' and exists (select 1 from jsonb_array_elements_text(r -> 'values') v where v not in ('new', 'existing', 'former')) then
      p := p || text 'Customer status must be new, existing or former.';
    elsif f = 'billing_interval' and exists (select 1 from jsonb_array_elements_text(r -> 'values') v where v not in ('monthly', 'yearly')) then
      p := p || text 'Billing interval must be monthly or yearly.';
    end if;
  end loop;
  if o.offer_type = 'business_specific' and not exists (select 1 from jsonb_array_elements(coalesce(o.eligibility -> 'rules', '[]'::jsonb)) r2 where r2 ->> 'field' = 'business') then
    p := p || text 'A business-specific offer needs a "business" rule.';
  end if;
  if o.offer_type = 'industry_specific' and not exists (select 1 from jsonb_array_elements(coalesce(o.eligibility -> 'rules', '[]'::jsonb)) r2 where r2 ->> 'field' = 'industry') then
    p := p || text 'An industry offer needs an "industry" rule.';
  end if;
  if o.offer_type = 'size_specific' and not exists (select 1 from jsonb_array_elements(coalesce(o.eligibility -> 'rules', '[]'::jsonb)) r2 where r2 ->> 'field' = 'business_size') then
    p := p || text 'A business-size offer needs a "business size" rule.';
  end if;
  if o.offer_type = 'annual_promo' and not exists (select 1 from jsonb_array_elements(coalesce(o.eligibility -> 'rules', '[]'::jsonb)) r2
                                                   where r2 ->> 'field' = 'billing_interval' and r2 -> 'values' ? 'yearly') then
    p := p || text 'An annual promotion needs a "billing interval: yearly" rule.';
  end if;
  return p;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_reason_text(p_reason text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select case p_reason
    when 'not_found' then 'That offer or code is not valid.'
    when 'paused' then 'This offer is paused at the moment.'
    when 'expired' then 'This offer has ended.'
    when 'not_started' then 'This offer has not started yet.'
    when 'not_available_here' then 'This offer is not available here.'
    when 'code_required' then 'This offer needs a code.'
    when 'not_eligible' then 'This offer is not available for your business.'
    when 'already_claimed' then 'Your business has already claimed this offer.'
    when 'limit_reached' then 'This offer has been fully claimed.'
    when 'cannot_combine' then 'You already have another offer waiting to be applied, and this one can''t be combined with it.'
    when 'too_many_attempts' then 'Too many codes were tried. Please wait an hour and try again.'
    else 'This offer can''t be claimed right now.' end;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_redeem_core(p_offer uuid, p_business uuid, p_source text, p_key text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o public.offers; r public.offer_redemptions; v_reason text; v_hold jsonb := public.zella_offer_rule_config('claim_hold');
        v_total int; v_mine int; v_recent int; v_unusual jsonb := public.zella_offer_rule_config('unusual_activity'); v_limit jsonb;
begin
  if p_key is null or length(p_key) < 8 then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;
  select * into r from public.offer_redemptions where idempotency_key = p_key;
  if found then
    if r.offer_id <> p_offer or r.business_id <> p_business then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
    return jsonb_build_object('ok', r.status in ('pending', 'confirmed'), 'status', r.status, 'redemption_id', r.id, 'repeat', true);
  end if;

  select * into o from public.offers where id = p_offer for update;
  if not found then v_reason := 'not_found';
  elsif o.status = 'paused' then v_reason := 'paused';
  elsif o.status in ('expired', 'archived') or (o.ends_at is not null and o.ends_at <= now()) then v_reason := 'expired';
  elsif o.status <> 'active' or o.starts_at is null or o.starts_at > now() then v_reason := 'not_started';
  elsif p_source in ('dashboard', 'code') and not ('dashboard' = any (o.channels)) then v_reason := 'not_available_here';
  elsif p_source = 'admin' and not ('sales' = any (o.channels)) and not ('dashboard' = any (o.channels)) then v_reason := 'not_available_here';
  elsif p_source = 'dashboard' and o.code is not null then v_reason := 'code_required';
  elsif not public.zella_offer_is_eligible(o, p_business) then v_reason := 'not_eligible';
  end if;

  if v_reason is null then
    select count(*) filter (where status in ('pending', 'confirmed')),
           count(*) filter (where status in ('pending', 'confirmed') and business_id = p_business)
      into v_total, v_mine from public.offer_redemptions where offer_id = o.id;
    if v_mine >= o.max_per_business then v_reason := 'already_claimed';
    elsif o.max_redemptions is not null and v_total >= o.max_redemptions then v_reason := 'limit_reached';
    elsif not o.stackable and exists (
      select 1 from public.offer_redemptions x join public.offers xo on xo.id = x.offer_id
      where x.business_id = p_business and x.status = 'pending' and x.offer_id <> o.id and not xo.stackable) then
      v_reason := 'cannot_combine';
    end if;
  end if;

  if v_reason is not null then
    perform public.zella_offer_log(case when o.id is not null then o.id end, 'claim_rejected', null, null,
                                   jsonb_build_object('reason', v_reason, 'source', p_source), p_business);
    return jsonb_build_object('ok', false, 'reason', v_reason);
  end if;

  insert into public.offer_redemptions (offer_id, business_id, status, source, idempotency_key, terms, hold_until, claimed_by, note)
  values (o.id, p_business, 'pending', p_source, p_key, public.zella_offer_terms(o),
          now() + make_interval(days => coalesce((v_hold ->> 'days')::int, 14)), auth.uid(), left(nullif(btrim(p_note), ''), 500))
  returning * into r;
  perform public.zella_offer_log(o.id, 'claimed', null, null, jsonb_build_object('source', p_source, 'redemption_id', r.id), p_business);

  v_total := v_total + 1;
  v_limit := public.zella_offer_rule_config('limit_warning');
  if o.max_redemptions is not null then
    if v_total >= o.max_redemptions then
      perform public.zella_platform_alert('offer_limit_reached', 'Offer limit reached: ' || o.name,
        format('All %s claims for this offer have been used.', o.max_redemptions), 'info', null, 'limit:' || o.id);
    elsif v_limit is not null and v_total * 100 >= o.max_redemptions * coalesce((v_limit ->> 'percent')::int, 80) then
      perform public.zella_platform_alert('offer_limit_near', 'Offer nearly used up: ' || o.name,
        format('%s of %s claims used.', v_total, o.max_redemptions), 'info', null, 'limitnear:' || o.id);
    end if;
  end if;
  if v_unusual is not null then
    select count(*) into v_recent from public.offer_redemptions where offer_id = o.id and created_at > now() - interval '1 hour';
    if v_recent >= coalesce((v_unusual ->> 'claims_per_hour')::int, 20) then
      perform public.zella_platform_alert('offer_unusual_activity', 'Unusual number of claims: ' || o.name,
        format('%s claims in the last hour. Consider pausing the offer to review.', v_recent), 'warning', null,
        'unusual:' || o.id || ':' || to_char(now(), 'YYYYMMDDHH24'));
    end if;
  end if;
  return jsonb_build_object('ok', true, 'status', r.status, 'redemption_id', r.id, 'hold_until', r.hold_until);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_report(p_from timestamp with time zone, p_to timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  return (
    with r as (
      select x.*, o.name offer_name, b.business_size, i.name industry, p.amount paid_amount, p.status pay_status
      from public.offer_redemptions x
      join public.offers o on o.id = x.offer_id
      join public.businesses b on b.id = x.business_id
      left join public.industries i on i.id = b.industry_id
      left join public.payments p on p.id = x.payment_id
      where x.created_at >= p_from and x.created_at < p_to),
    agg as (
      select r.*, (status in ('confirmed', 'reversed')) as paid from r)
    select jsonb_build_object(
      'from', p_from, 'to', p_to,
      'totals', (select jsonb_build_object('claims', count(*), 'paid', count(*) filter (where paid),
          'reversed', count(*) filter (where status = 'reversed'), 'pending', count(*) filter (where status = 'pending'),
          'lapsed', count(*) filter (where status in ('lapsed', 'cancelled')),
          'gross_paid_cents', coalesce((select sum(round(p.amount * 100)) from public.payments p where p.id in (select payment_id from agg where paid)), 0),
          'refunded_cents', coalesce((select sum(round(p.amount * 100)) from public.payments p where p.status = 'refunded' and p.id in (select payment_id from agg where paid)), 0),
          'discount_cents', coalesce(sum(discount_cents) filter (where status = 'confirmed'), 0),
          'discount_unknown', count(*) filter (where status = 'confirmed' and discount_cents is null)) from agg),
      'by_offer', coalesce((select jsonb_agg(row_to_json(t)) from (
          select offer_id, offer_name, count(*) claims, count(*) filter (where paid) paid,
                 coalesce(sum(round(paid_amount * 100)) filter (where paid), 0) gross_paid_cents,
                 coalesce(sum(discount_cents) filter (where status = 'confirmed'), 0) discount_cents
          from agg group by 1, 2 order by 3 desc) t), '[]'::jsonb),
      'by_size', coalesce((select jsonb_agg(row_to_json(t)) from (
          select coalesce(business_size, 'not set') size, count(*) claims, count(*) filter (where paid) paid from agg group by 1 order by 2 desc) t), '[]'::jsonb),
      'by_industry', coalesce((select jsonb_agg(row_to_json(t)) from (
          select coalesce(industry, 'Unassigned') industry, count(*) claims, count(*) filter (where paid) paid from agg group by 1 order by 2 desc) t), '[]'::jsonb),
      'by_source', coalesce((select jsonb_agg(row_to_json(t)) from (
          select source, count(*) claims, count(*) filter (where paid) paid from agg group by 1 order by 2 desc) t), '[]'::jsonb))
  );
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_retry()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  return public.zella_offers_tick('retry');
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_rule_config(p_key text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when enabled then config else null end from public.offer_rules where key = p_key;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_rule_requires(p_key text)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select case p_key
    when 'abandoned_checkout' then array['checkout', 'promo_sending']
    when 'intro_renewal' then array['billing']
    when 'referral' then array['referral_tracking', 'billing']
    when 'win_back' then array['promo_sending']
    when 'promo_email' then array['promo_sending']
    else array[]::text[] end;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_rule_results(p_eligibility jsonb, p_facts jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r jsonb; f text; fact text; ok boolean; out jsonb := '[]'::jsonb;
begin
  for r in select * from jsonb_array_elements(coalesce(p_eligibility -> 'rules', '[]'::jsonb)) loop
    f := r ->> 'field';
    fact := p_facts ->> f;
    if f in ('first_purchase', 'never_redeemed') then
      ok := (p_facts -> f) = (r -> 'value');
    elsif f = 'country' then
      ok := fact is not null and exists (select 1 from jsonb_array_elements_text(r -> 'values') v where upper(v) = fact);
    else
      ok := fact is not null and exists (select 1 from jsonb_array_elements_text(r -> 'values') v where v = fact);
    end if;
    out := out || jsonb_build_array(jsonb_build_object('field', f, 'ok', coalesce(ok, false), 'actual', p_facts -> f));
  end loop;
  return out;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_rule_save(p_key text, p_enabled boolean, p_config jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_old public.offer_rules; v_miss text[] := public.zella_offer_missing(public.zella_offer_rule_requires(p_key)); k text; v jsonb;
begin
  if not public.zella_is_zella_owner() then raise exception 'OWNER_ONLY'; end if;
  select * into v_old from public.offer_rules where key = p_key for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_enabled and cardinality(v_miss) > 0 then raise exception 'RULE_UNAVAILABLE'; end if;
  if jsonb_typeof(coalesce(p_config, '{}'::jsonb)) <> 'object' then raise exception 'BAD_CONFIG'; end if;
  for k, v in select * from jsonb_each(coalesce(p_config, '{}'::jsonb)) loop
    if not (v_old.config ? k) then raise exception 'BAD_CONFIG'; end if;
    if k = 'always_types' then
      if jsonb_typeof(v) <> 'array' then raise exception 'BAD_CONFIG'; end if;
    elsif jsonb_typeof(v) <> 'number' or (v #>> '{}')::numeric < 0 or (v #>> '{}')::numeric > 100000000 or (v #>> '{}')::numeric <> trunc((v #>> '{}')::numeric) then
      raise exception 'BAD_CONFIG';
    end if;
  end loop;
  update public.offer_rules set enabled = p_enabled, config = v_old.config || coalesce(p_config, '{}'::jsonb), updated_by = auth.uid(), updated_at = now() where key = p_key;
  insert into public.audit_logs (user_id, action, entity_type, old_data, new_data)
  values (auth.uid(), 'offer_rule.updated', 'offer_rule', jsonb_build_object('key', p_key, 'enabled', v_old.enabled, 'config', v_old.config),
          jsonb_build_object('key', p_key, 'enabled', p_enabled, 'config', v_old.config || coalesce(p_config, '{}'::jsonb)));
  if p_key = 'approval_thresholds' then
    update public.offers o set needs_approval = public.zella_offer_needs_approval(o) where o.status = 'draft';
  end if;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_rules_list()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  return jsonb_build_object(
    'rules', coalesce((select jsonb_agg(jsonb_build_object('key', r.key, 'enabled', r.enabled, 'config', r.config, 'updated_at', r.updated_at,
        'requires', to_jsonb(public.zella_offer_rule_requires(r.key)),
        'missing', to_jsonb(public.zella_offer_missing(public.zella_offer_rule_requires(r.key))),
        'updated_by', (select u.email from auth.users u where u.id = r.updated_by)) order by r.key)
      from public.offer_rules r), '[]'::jsonb),
    'last_run', (select to_jsonb(j) from (select status, trigger, started_at, finished_at, processed, failures, error from public.offer_job_runs
                 where job = 'offers_tick' and status <> 'skipped' order by started_at desc limit 1) j),
    'last_success', (select max(finished_at) from public.offer_job_runs where job = 'offers_tick' and status = 'succeeded'),
    'scheduler_on', public.zella_offer_scheduler_on(),
    'capabilities', public.zella_offer_capabilities(),
    'is_owner', public.zella_is_zella_owner());
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_save(p_id uuid, p_data jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o public.offers; v_tz text; v_start timestamptz; v_end timestamptz; v_channels text[]; v_new boolean := p_id is null;
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  if v_new then
    insert into public.offers (name, created_by) values (coalesce(nullif(btrim(p_data ->> 'name'), ''), 'Untitled offer'), auth.uid()) returning * into o;
  else
    select * into o from public.offers where id = p_id for update;
    if not found then raise exception 'OFFER_NOT_FOUND'; end if;
  end if;

  update public.offers set
    name = coalesce(nullif(btrim(p_data ->> 'name'), ''), name),
    description = case when p_data ? 'description' then nullif(btrim(p_data ->> 'description'), '') else description end,
    internal_note = case when p_data ? 'internal_note' then nullif(btrim(p_data ->> 'internal_note'), '') else internal_note end,
    updated_at = now()
  where id = o.id;

  if o.status = 'draft' then
    v_tz := coalesce(nullif(p_data ->> 'timezone', ''), o.timezone);
    if not exists (select 1 from pg_timezone_names where name = v_tz) then raise exception 'BAD_TIMEZONE'; end if;
    v_start := case when nullif(p_data ->> 'start_local', '') is null then case when p_data ? 'start_local' then null else o.starts_at end
                    else ((p_data ->> 'start_local')::timestamp at time zone v_tz) end;
    v_end := case when nullif(p_data ->> 'end_local', '') is null then case when p_data ? 'end_local' then null else o.ends_at end
                  else ((p_data ->> 'end_local')::timestamp at time zone v_tz) end;
    if v_start is not null and v_end is not null and v_end <= v_start then raise exception 'END_BEFORE_START'; end if;
    v_channels := case when jsonb_typeof(p_data -> 'channels') = 'array'
                       then array(select distinct jsonb_array_elements_text(p_data -> 'channels')) else o.channels end;
    update public.offers set
      offer_type = coalesce(p_data ->> 'offer_type', offer_type),
      discount_kind = coalesce(p_data ->> 'discount_kind', discount_kind),
      percent_off_bp = case when coalesce(p_data ->> 'discount_kind', discount_kind) = 'percent'
                            then coalesce((p_data ->> 'percent_off_bp')::int, percent_off_bp) else null end,
      amount_off_cents = case when coalesce(p_data ->> 'discount_kind', discount_kind) = 'fixed'
                              then coalesce((p_data ->> 'amount_off_cents')::bigint, amount_off_cents) else null end,
      currency = lower(coalesce(nullif(p_data ->> 'currency', ''), currency)),
      duration = coalesce(p_data ->> 'duration', duration),
      duration_months = case when coalesce(p_data ->> 'duration', duration) = 'repeating'
                             then coalesce((p_data ->> 'duration_months')::int, duration_months) else null end,
      timezone = v_tz,
      starts_at = v_start,
      ends_at = v_end,
      eligibility = case when jsonb_typeof(p_data -> 'eligibility') = 'object' then p_data -> 'eligibility' else eligibility end,
      max_redemptions = case when p_data ? 'max_redemptions' then nullif(p_data ->> 'max_redemptions', '')::int else max_redemptions end,
      max_per_business = coalesce(nullif(p_data ->> 'max_per_business', '')::int, max_per_business),
      code = case when p_data ? 'code' then nullif(btrim(p_data ->> 'code'), '') else code end,
      code_case_sensitive = coalesce((p_data ->> 'code_case_sensitive')::boolean, code_case_sensitive),
      stackable = coalesce((p_data ->> 'stackable')::boolean, stackable),
      channels = v_channels,
      version = version + case when v_new then 0 else 1 end
    where id = o.id;
  elsif p_data ?| array['offer_type', 'discount_kind', 'percent_off_bp', 'amount_off_cents', 'duration', 'duration_months', 'start_local',
                        'end_local', 'eligibility', 'max_redemptions', 'max_per_business', 'code', 'channels', 'stackable', 'currency'] then
    raise exception 'TERMS_LOCKED';
  end if;

  select * into o from public.offers where id = o.id;
  update public.offers set needs_approval = public.zella_offer_needs_approval(o) where id = o.id;
  perform public.zella_offer_log(o.id, case when v_new then 'created' else 'edited' end, null, null, jsonb_build_object('version', o.version));
  return o.id;
exception when unique_violation then
  raise exception 'CODE_TAKEN';
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_scheduler_on()
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v boolean;
begin
  execute 'select exists (select 1 from cron.job where command ilike ''%zella_run_schedule_group%every5%'' and active)' into v;
  return coalesce(v, false);
exception when others then
  return false;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_set_redemption(p_id uuid, p_status text, p_note text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.offer_redemptions;
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  if p_status not in ('cancelled', 'reversed') then raise exception 'BAD_STATUS'; end if;
  if nullif(btrim(p_note), '') is null then raise exception 'NOTE_REQUIRED'; end if;
  select * into r from public.offer_redemptions where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_status = 'cancelled' and r.status <> 'pending' then raise exception 'NOT_PENDING'; end if;
  if p_status = 'reversed' and r.status <> 'confirmed' then raise exception 'NOT_CONFIRMED'; end if;
  update public.offer_redemptions set status = p_status, ended_at = now(), note = left(p_note, 500), updated_at = now() where id = r.id;
  perform public.zella_offer_log(r.offer_id, 'claim_' || p_status, r.status, p_status, jsonb_build_object('redemption_id', r.id, 'note', p_note), r.business_id);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_slot(p_business_id uuid, p_start timestamp with time zone, p_end timestamp with time zone, p_staff_id uuid, p_exclude_customer uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_auto record; w record; v_n integer := 0; v_max integer; v_tz text; v_mins integer;
begin
  select a.* into v_auto from public.automations a where a.business_id = p_business_id and a.trigger_type = 'waitlist_offer' and a.status = 'active' limit 1;
  if v_auto.id is null or p_start <= now() then return 0; end if;
  v_max := coalesce((v_auto.trigger_config ->> 'offers')::integer, 1);
  v_mins := coalesce((v_auto.trigger_config ->> 'offer_minutes')::integer, 30);
  select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = p_business_id and b.suspended_at is null and b.cancelled_at is null;
  if v_tz is null then return 0; end if;
  for w in
    select e.* from public.waitlist_entries e join public.customers c on c.id = e.customer_id
     where e.business_id = p_business_id and e.status = 'waiting'
       and (p_exclude_customer is null or e.customer_id <> p_exclude_customer)
       and (e.earliest_at is null or e.earliest_at <= p_start) and (e.latest_at is null or e.latest_at >= p_end)
       and (e.staff_id is null or p_staff_id is null or e.staff_id = p_staff_id)
       and e.duration_minutes <= extract(epoch from (p_end - p_start)) / 60
       and not coalesce(c.do_not_contact, false) and public.zella_digits(c.phone) is not null
     order by e.created_at limit v_max for update of e skip locked
  loop
    update public.waitlist_entries set status = 'offered', offered_start = p_start, offered_end = p_start + make_interval(mins => w.duration_minutes),
           offered_staff_id = p_staff_id, offer_expires_at = now() + make_interval(mins => v_mins) where id = w.id;
    -- the customer is only asked; nothing is reserved until they say yes
    insert into public.followup_tasks (business_id, customer_id, kind, channel, due_at, max_attempts, entity_ref)
    values (p_business_id, w.customer_id, 'waitlist_offer', 'sms', public.zella_next_call_time(now(), v_tz), 1, w.id);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_summary(o offers)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select case when o.discount_kind = 'percent'
              then rtrim(to_char(o.percent_off_bp / 100.0, 'FM990.99'), '.') || '% off'
              else upper(o.currency) || ' ' || trim(to_char(o.amount_off_cents / 100.0, 'FM999999990.00')) || ' off' end
      || case o.duration when 'once' then ' your next bill'
                         when 'repeating' then ' for ' || o.duration_months || case when o.duration_months = 1 then ' month' else ' months' end
                         else ' for as long as you stay subscribed' end;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_terms(o offers)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select jsonb_build_object('offer_name', o.name, 'offer_type', o.offer_type, 'discount_kind', o.discount_kind,
    'percent_off_bp', o.percent_off_bp, 'amount_off_cents', o.amount_off_cents, 'currency', o.currency,
    'duration', o.duration, 'duration_months', o.duration_months, 'offer_version', o.version, 'ends_at', o.ends_at);
$function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_transition(p_id uuid, p_action text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o public.offers; v_to text; v_problems text[]; v_other_owner boolean;
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  select * into o from public.offers where id = p_id for update;
  if not found then raise exception 'OFFER_NOT_FOUND'; end if;

  if p_action = 'submit' then
    if o.status <> 'draft' then raise exception 'BAD_TRANSITION'; end if;
    v_problems := public.zella_offer_problems(o);
    if cardinality(v_problems) > 0 then return jsonb_build_object('ok', false, 'problems', to_jsonb(v_problems)); end if;
    v_to := case when public.zella_offer_needs_approval(o) then 'pending_approval' else 'scheduled' end;
    update public.offers set status = v_to, needs_approval = (v_to = 'pending_approval'), submitted_by = auth.uid(), submitted_at = now(),
           approved_by = null, approved_at = null, updated_at = now() where id = o.id;
  elsif p_action in ('approve', 'reject') then
    if o.status <> 'pending_approval' then raise exception 'BAD_TRANSITION'; end if;
    if not public.zella_is_zella_owner() then raise exception 'OWNER_ONLY'; end if;
    select exists (select 1 from public.platform_admins where is_active and role = 'zella_owner' and user_id <> auth.uid()) into v_other_owner;
    if p_action = 'approve' and o.submitted_by = auth.uid() and v_other_owner then raise exception 'SECOND_PERSON_NEEDED'; end if;
    if p_action = 'reject' and nullif(btrim(p_note), '') is null then raise exception 'NOTE_REQUIRED'; end if;
    if p_action = 'approve' then
      v_problems := public.zella_offer_problems(o);
      if cardinality(v_problems) > 0 then return jsonb_build_object('ok', false, 'problems', to_jsonb(v_problems)); end if;
    end if;
    v_to := case when p_action = 'approve' then 'scheduled' else 'draft' end;
    update public.offers set status = v_to, approved_by = case when p_action = 'approve' then auth.uid() end,
           approved_at = case when p_action = 'approve' then now() end, updated_at = now() where id = o.id;
  elsif p_action = 'pause' then
    if o.status not in ('scheduled', 'active') then raise exception 'BAD_TRANSITION'; end if;
    v_to := 'paused';
    update public.offers set status = 'paused', paused_at = now(), updated_at = now() where id = o.id;
  elsif p_action = 'resume' then
    if o.status <> 'paused' then raise exception 'BAD_TRANSITION'; end if;
    if o.ends_at <= now() then
      v_to := 'expired';
      update public.offers set status = 'expired', expired_at = now(), updated_at = now() where id = o.id;
    else
      v_problems := public.zella_offer_problems(o);
      if cardinality(v_problems) > 0 then return jsonb_build_object('ok', false, 'problems', to_jsonb(v_problems)); end if;
      v_to := case when o.starts_at <= now() then 'active' else 'scheduled' end;
      update public.offers set status = v_to, paused_at = null, activated_at = coalesce(activated_at, case when v_to = 'active' then now() end),
             updated_at = now() where id = o.id;
    end if;
  elsif p_action = 'back_to_draft' then
    if o.status not in ('scheduled', 'pending_approval') then raise exception 'BAD_TRANSITION'; end if;
    if exists (select 1 from public.offer_redemptions where offer_id = o.id) then raise exception 'HAS_REDEMPTIONS'; end if;
    v_to := 'draft';
    update public.offers set status = 'draft', approved_by = null, approved_at = null, updated_at = now() where id = o.id;
  elsif p_action = 'archive' then
    if o.status not in ('draft', 'paused', 'expired') then raise exception 'BAD_TRANSITION'; end if;
    v_to := 'archived';
    update public.offers set status = 'archived', archived_at = now(), updated_at = now() where id = o.id;
  elsif p_action = 'end_now' then
    if o.status not in ('active', 'paused', 'scheduled') then raise exception 'BAD_TRANSITION'; end if;
    v_to := 'expired';
    update public.offers set status = 'expired', expired_at = now(), ends_at = least(ends_at, now()), updated_at = now() where id = o.id;
  else
    raise exception 'BAD_ACTION';
  end if;

  perform public.zella_offer_log(o.id, p_action, o.status, v_to, jsonb_strip_nulls(jsonb_build_object('note', nullif(btrim(p_note), ''))));
  if v_to = 'scheduled' and o.starts_at <= now() then perform public.zella_offers_tick('manual'); end if;
  return jsonb_build_object('ok', true, 'status', (select status from public.offers where id = o.id));
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offer_type_requires(p_type text)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select case p_type
    when 'intro_pricing' then array['billing']
    when 'referral' then array['referral_tracking', 'billing']
    when 'win_back' then array['promo_sending']
    when 'free_trial' then array['billing', 'checkout']
    else array[]::text[] end;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_offers_for_business(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is null or not public.zella_has_role(p_business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  return jsonb_build_object(
    'available', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'description', o.description,
        'summary', public.zella_offer_summary(o), 'ends_at', o.ends_at, 'timezone', o.timezone) order by o.ends_at)
      from public.offers o
      where o.status = 'active' and o.starts_at <= now() and o.ends_at > now() and 'dashboard' = any (o.channels) and o.code is null
        and public.zella_offer_is_eligible(o, p_business_id)
        and not exists (select 1 from public.offer_redemptions x where x.offer_id = o.id and x.business_id = p_business_id and x.status in ('pending', 'confirmed'))
        and (o.max_redemptions is null or (select count(*) from public.offer_redemptions x where x.offer_id = o.id and x.status in ('pending', 'confirmed')) < o.max_redemptions)
    ), '[]'::jsonb),
    'claimed', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'name', r.terms ->> 'offer_name', 'status', r.status,
        'summary', public.zella_offer_summary(o), 'created_at', r.created_at, 'hold_until', r.hold_until, 'confirmed_at', r.confirmed_at) order by r.created_at desc)
      from public.offer_redemptions r join public.offers o on o.id = r.offer_id
      where r.business_id = p_business_id and r.status in ('pending', 'confirmed')), '[]'::jsonb),
    'billing_connected', (public.zella_offer_capabilities() ->> 'billing')::boolean);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offers_list()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  return jsonb_build_object(
    'offers', coalesce((select jsonb_agg(jsonb_build_object(
        'id', o.id, 'name', o.name, 'offer_type', o.offer_type, 'status', o.status, 'summary', public.zella_offer_summary(o),
        'starts_at', o.starts_at, 'ends_at', o.ends_at, 'timezone', o.timezone, 'code', o.code, 'channels', o.channels,
        'max_redemptions', o.max_redemptions, 'needs_approval', o.needs_approval, 'updated_at', o.updated_at,
        'claims', (select count(*) from public.offer_redemptions r where r.offer_id = o.id and r.status in ('pending', 'confirmed')),
        'confirmed', (select count(*) from public.offer_redemptions r where r.offer_id = o.id and r.status = 'confirmed'),
        'problems', case when o.status in ('draft', 'pending_approval', 'scheduled', 'paused') then to_jsonb(public.zella_offer_problems(o)) else '[]'::jsonb end
      ) order by case o.status when 'active' then 0 when 'pending_approval' then 1 when 'scheduled' then 2 when 'paused' then 3 when 'draft' then 4 when 'expired' then 5 else 6 end, o.updated_at desc)
      from public.offers o), '[]'::jsonb),
    'capabilities', public.zella_offer_capabilities(),
    'is_owner', public.zella_is_zella_owner(),
    'me', auth.uid());
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_offers_tick(p_trigger text DEFAULT 'schedule'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_run uuid; o public.offers; v_problems text[]; v_done int := 0; v_fail int := 0; v_lapsed int := 0; v_warn jsonb; v_counts jsonb;
begin
  if auth.uid() is not null and not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  if not pg_try_advisory_xact_lock(hashtext('zella_offers_tick')) then
    insert into public.offer_job_runs (job, trigger, status, started_by, finished_at, detail)
    values ('offers_tick', p_trigger, 'skipped', auth.uid(), now(), '{"why": "another run was in progress"}');
    return jsonb_build_object('status', 'skipped');
  end if;
  insert into public.offer_job_runs (job, trigger, started_by) values ('offers_tick', p_trigger, auth.uid()) returning id into v_run;

  if public.zella_offer_rule_config('auto_activate') is not null or p_trigger <> 'schedule' then
    for o in select * from public.offers where status = 'scheduled' and starts_at <= now() and ends_at > now() order by starts_at for update skip locked loop
      begin
        v_problems := public.zella_offer_problems(o);
        if cardinality(v_problems) > 0 then
          v_fail := v_fail + 1;
          insert into public.offer_events (offer_id, kind, from_status, to_status, detail)
          values (o.id, 'activation_failed', 'scheduled', 'scheduled', jsonb_build_object('problems', to_jsonb(v_problems), 'run_id', v_run));
          perform public.zella_platform_alert('offer_activation_failed', 'Offer could not go live: ' || o.name,
            array_to_string(v_problems, ' '), 'warning', null, 'activate:' || o.id);
        else
          update public.offers set status = 'active', activated_at = now(), updated_at = now() where id = o.id;
          insert into public.offer_events (offer_id, kind, from_status, to_status, detail)
          values (o.id, 'activated', 'scheduled', 'active', jsonb_build_object('run_id', v_run));
          perform public.zella_resolve_platform_alerts('offer_activation_failed', null, 'activate:' || o.id, 'Went live');
          v_done := v_done + 1;
        end if;
      exception when others then
        v_fail := v_fail + 1;
        insert into public.offer_events (offer_id, kind, detail) values (o.id, 'activation_error', jsonb_build_object('error', sqlerrm, 'run_id', v_run));
      end;
    end loop;
  end if;

  if public.zella_offer_rule_config('auto_expire') is not null or p_trigger <> 'schedule' then
    for o in select * from public.offers where status in ('scheduled', 'active', 'paused', 'pending_approval') and ends_at <= now() for update skip locked loop
      update public.offers set status = 'expired', expired_at = now(), updated_at = now() where id = o.id;
      select jsonb_build_object('claims', count(*), 'confirmed', count(*) filter (where status = 'confirmed'), 'pending', count(*) filter (where status = 'pending'))
        into v_counts from public.offer_redemptions where offer_id = o.id;
      insert into public.offer_events (offer_id, kind, from_status, to_status, detail)
      values (o.id, 'expired', o.status, 'expired', jsonb_build_object('run_id', v_run) || v_counts);
      if public.zella_offer_rule_config('completion_report') is not null then
        perform public.zella_platform_alert('offer_completed', 'Offer ended: ' || o.name,
          format('%s claims, %s paid, %s still waiting for payment.', v_counts ->> 'claims', v_counts ->> 'confirmed', v_counts ->> 'pending'),
          'info', null, 'completed:' || o.id);
      end if;
      v_done := v_done + 1;
    end loop;
  end if;

  with l as (
    update public.offer_redemptions set status = 'lapsed', ended_at = now(), updated_at = now()
    where status = 'pending' and hold_until < now() returning id, offer_id, business_id)
  insert into public.offer_events (offer_id, business_id, kind, from_status, to_status, detail)
  select offer_id, business_id, 'claim_lapsed', 'pending', 'lapsed', jsonb_build_object('redemption_id', id) from l;
  get diagnostics v_lapsed = row_count;

  v_warn := public.zella_offer_rule_config('expiry_warning');
  if v_warn is not null then
    for o in select * from public.offers x where x.status = 'active'
               and x.ends_at <= now() + make_interval(days => coalesce((v_warn ->> 'days_before')::int, 3))
               and not exists (select 1 from public.offer_events e where e.offer_id = x.id and e.kind = 'expiry_warning') loop
      insert into public.offer_events (offer_id, kind, detail) values (o.id, 'expiry_warning', jsonb_build_object('ends_at', o.ends_at));
      perform public.zella_platform_alert('offer_ending_soon', 'Offer ending soon: ' || o.name,
        'Ends ' || to_char(o.ends_at at time zone o.timezone, 'Mon DD, YYYY HH12:MI AM') || ' (' || o.timezone || ').', 'info', null, 'ending:' || o.id);
    end loop;
  end if;

  update public.offer_job_runs set status = case when v_fail > 0 then case when v_done > 0 then 'partial' else 'failed' end else 'succeeded' end,
         processed = v_done + v_lapsed, failures = v_fail, finished_at = now(),
         detail = jsonb_build_object('changed', v_done, 'lapsed', v_lapsed, 'failed', v_fail)
  where id = v_run;
  return jsonb_build_object('status', case when v_fail > 0 then 'partial' else 'succeeded' end, 'changed', v_done, 'lapsed', v_lapsed, 'failed', v_fail);
exception when others then
  insert into public.offer_job_runs (job, trigger, status, failures, error, started_by, finished_at)
  values ('offers_tick', p_trigger, 'failed', 1, left(sqlerrm, 500), auth.uid(), now());
  perform public.zella_platform_alert('offer_job_failed', 'Offer schedule job failed', left(sqlerrm, 500), 'warning', null, 'offers_tick');
  return jsonb_build_object('status', 'failed', 'error', left(sqlerrm, 200));
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_on_call_delete(p_business_id uuid, p_shift_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is null or not public.zella_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  delete from public.on_call_shifts where id = p_shift_id and business_id = p_business_id;
  return found;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_on_call_list(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_now jsonb;
begin
  if auth.uid() is null or not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  v_now := public.zella_on_call_now(p_business_id);
  return jsonb_build_object(
    'settings', coalesce((select jsonb_build_object('enabled', s.enabled, 'scope', s.scope, 'updated_at', s.updated_at)
                            from public.on_call_settings s where s.business_id = p_business_id),
                         jsonb_build_object('enabled', false, 'scope', 'after_hours')),
    'can_edit', public.zella_can_manage(p_business_id),
    'now', case when v_now ? 'staff_id' then jsonb_build_object('staff_id', v_now -> 'staff_id', 'name', v_now -> 'name', 'via', v_now -> 'via') end,
    'shifts', coalesce((select jsonb_agg(jsonb_build_object('id', sh.id, 'staff_id', sh.staff_id, 'staff_name', sm.name, 'kind', sh.kind,
                         'weekday', sh.weekday, 'starts', to_char(sh.starts, 'HH24:MI'), 'ends', to_char(sh.ends, 'HH24:MI'),
                         'starts_at', sh.starts_at, 'ends_at', sh.ends_at, 'note', sh.note,
                         'has_phone', public.zella_normalize_e164(sm.phone) is not null, 'staff_active', sm.is_active)
                         order by sh.kind desc, sh.weekday, sh.starts, sh.starts_at)
                        from public.on_call_shifts sh join public.staff_members sm on sm.id = sh.staff_id
                       where sh.business_id = p_business_id and (sh.kind = 'weekly' or sh.ends_at > now() - interval '1 day')), '[]'::jsonb),
    'staff', coalesce((select jsonb_agg(jsonb_build_object('id', sm.id, 'name', sm.name, 'has_phone', public.zella_normalize_e164(sm.phone) is not null)
                         order by sm.sort_order, sm.name)
                        from public.staff_members sm where sm.business_id = p_business_id and sm.is_active), '[]'::jsonb));
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_on_call_now(p_business_id uuid, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tz text; v_local timestamp; v_dow smallint; v_t time; r record; v_scope text; v_on boolean;
begin
  select s.enabled, s.scope into v_on, v_scope from public.on_call_settings s where s.business_id = p_business_id;
  if not coalesce(v_on, false) then return '{}'::jsonb; end if;
  select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = p_business_id;
  if v_tz is null then return '{}'::jsonb; end if;
  v_local := p_at at time zone v_tz; v_dow := extract(dow from v_local)::smallint; v_t := v_local::time;

  select sh.id, sm.id as staff_id, sm.name, public.zella_normalize_e164(sm.phone) as phone, 'cover' as via into r
    from public.on_call_shifts sh join public.staff_members sm on sm.id = sh.staff_id and sm.business_id = sh.business_id
   where sh.business_id = p_business_id and sh.kind = 'cover' and p_at >= sh.starts_at and p_at < sh.ends_at
     and sm.is_active and public.zella_normalize_e164(sm.phone) is not null
   order by sh.created_at desc limit 1;
  if r.staff_id is null then
    select sh.id, sm.id as staff_id, sm.name, public.zella_normalize_e164(sm.phone) as phone, 'weekly' as via into r
      from public.on_call_shifts sh join public.staff_members sm on sm.id = sh.staff_id and sm.business_id = sh.business_id
     where sh.business_id = p_business_id and sh.kind = 'weekly' and sm.is_active and public.zella_normalize_e164(sm.phone) is not null
       and ((sh.weekday = v_dow and ((sh.ends > sh.starts and v_t >= sh.starts and v_t < sh.ends) or (sh.ends < sh.starts and v_t >= sh.starts)))
         or (sh.weekday = (v_dow + 6) % 7 and sh.ends < sh.starts and v_t < sh.ends))
     order by case when sh.weekday = v_dow then 0 else 1 end, sh.starts desc limit 1;
  end if;
  if r.staff_id is null then return '{}'::jsonb; end if;
  return jsonb_build_object('staff_id', r.staff_id, 'name', r.name, 'phone', r.phone, 'via', r.via, 'scope', coalesce(v_scope, 'after_hours'));
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_on_call_reminders()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s record; v_start timestamptz; v_local timestamp; v_user uuid; n integer := 0; v_name text; v_until text;
begin
  for s in select sh.*, sm.name, sm.phone, coalesce(b.timezone, 'America/New_York') as tz
             from public.on_call_shifts sh
             join public.on_call_settings st on st.business_id = sh.business_id and st.enabled
             join public.staff_members sm on sm.id = sh.staff_id and sm.is_active
             join public.businesses b on b.id = sh.business_id and b.suspended_at is null and b.cancelled_at is null loop
    v_start := null;
    if s.kind = 'cover' then
      v_start := s.starts_at;
    else
      v_local := (now() at time zone s.tz);
      v_start := ((v_local::date + ((s.weekday - extract(dow from v_local)::int + 7) % 7)) + s.starts) at time zone s.tz;
      if v_start < now() then v_start := v_start + interval '7 days'; end if;
    end if;
    continue when v_start is null or v_start < now() or v_start > now() + interval '60 minutes';
    insert into public.on_call_reminders_sent (shift_id, starts_at) values (s.id, v_start) on conflict do nothing;
    continue when not found;
    v_name := s.name;
    v_until := case when s.kind = 'cover' then to_char(s.ends_at at time zone s.tz, 'FMDy FMHH12:MI AM') else to_char(s.ends, 'FMHH12:MI AM') end;
    perform public.zella_notify(s.business_id, 'on_call_starting', v_name || ' is on call from ' || to_char(v_start at time zone s.tz, 'FMHH12:MI AM'),
      'After-hours calls go to ' || v_name || ' until ' || v_until || '.', 'info', 'team');
    select bm.user_id into v_user from public.business_members bm join public.profiles p on p.id = bm.user_id
     where bm.business_id = s.business_id and bm.status = 'active' and public.zella_digits(p.phone) is not null
       and public.zella_digits(p.phone) = public.zella_digits(s.phone) limit 1;
    if v_user is not null then
      perform public.zella_notify(s.business_id, 'on_call_starting', 'You''re on call from ' || to_char(v_start at time zone s.tz, 'FMHH12:MI AM'),
        'After-hours calls for this business will ring your phone until ' || v_until || '.', 'warning', 'team', s.id, v_user);
    end if;
    n := n + 1;
  end loop;
  delete from public.on_call_reminders_sent where starts_at < now() - interval '14 days';
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_on_call_save(p_business_id uuid, p_shift jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid; v_staff uuid; v_kind text; v_note text; v_count integer;
begin
  if auth.uid() is null or not public.zella_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if jsonb_typeof(p_shift) <> 'object' then raise exception 'INVALID_SHIFT'; end if;
  v_kind := p_shift ->> 'kind';
  if coalesce(v_kind, '') not in ('weekly', 'cover') then raise exception 'INVALID_KIND'; end if;
  begin v_staff := (p_shift ->> 'staff_id')::uuid; exception when others then raise exception 'INVALID_STAFF'; end;
  if not exists (select 1 from public.staff_members sm where sm.id = v_staff and sm.business_id = p_business_id and sm.is_active) then raise exception 'INVALID_STAFF'; end if;
  if not exists (select 1 from public.staff_members sm where sm.id = v_staff and public.zella_normalize_e164(sm.phone) is not null) then raise exception 'STAFF_NEEDS_PHONE'; end if;
  v_note := nullif(trim(left(coalesce(p_shift ->> 'note', ''), 200)), '');
  if p_shift ? 'id' and nullif(p_shift ->> 'id', '') is not null then
    begin v_id := (p_shift ->> 'id')::uuid; exception when others then raise exception 'NOT_FOUND'; end;
    if not exists (select 1 from public.on_call_shifts where id = v_id and business_id = p_business_id) then raise exception 'NOT_FOUND'; end if;
  end if;
  select count(*) into v_count from public.on_call_shifts where business_id = p_business_id;
  if v_id is null and v_count >= 200 then raise exception 'TOO_MANY_SHIFTS'; end if;

  begin
    if v_kind = 'weekly' then
      if v_id is null then
        insert into public.on_call_shifts (business_id, staff_id, kind, weekday, starts, ends, note, created_by)
        values (p_business_id, v_staff, 'weekly', (p_shift ->> 'weekday')::smallint, (p_shift ->> 'starts')::time, (p_shift ->> 'ends')::time, v_note, auth.uid())
        returning id into v_id;
      else
        update public.on_call_shifts set staff_id = v_staff, kind = 'weekly', weekday = (p_shift ->> 'weekday')::smallint, starts = (p_shift ->> 'starts')::time,
               ends = (p_shift ->> 'ends')::time, starts_at = null, ends_at = null, note = v_note where id = v_id;
      end if;
    else
      if v_id is null then
        insert into public.on_call_shifts (business_id, staff_id, kind, starts_at, ends_at, note, created_by)
        values (p_business_id, v_staff, 'cover', (p_shift ->> 'starts_at')::timestamptz, (p_shift ->> 'ends_at')::timestamptz, v_note, auth.uid())
        returning id into v_id;
      else
        update public.on_call_shifts set staff_id = v_staff, kind = 'cover', weekday = null, starts = null, ends = null,
               starts_at = (p_shift ->> 'starts_at')::timestamptz, ends_at = (p_shift ->> 'ends_at')::timestamptz, note = v_note where id = v_id;
      end if;
    end if;
  exception
    when check_violation or invalid_datetime_format or datetime_field_overflow or invalid_text_representation or numeric_value_out_of_range then
      raise exception 'INVALID_TIMES';
  end;
  return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_on_call_settings_save(p_business_id uuid, p_enabled boolean, p_scope text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is null or not public.zella_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if coalesce(p_scope, '') not in ('after_hours', 'emergencies_only') then raise exception 'INVALID_SCOPE'; end if;
  insert into public.on_call_settings (business_id, enabled, scope, updated_by, updated_at)
  values (p_business_id, coalesce(p_enabled, false), p_scope, auth.uid(), now())
  on conflict (business_id) do update set enabled = excluded.enabled, scope = excluded.scope, updated_by = excluded.updated_by, updated_at = now();
  return true;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_on_call_status()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'tables', to_regclass('public.on_call_shifts') is not null and to_regclass('public.on_call_settings') is not null,
    'ai_voice', pg_get_functiondef('public.zella_ai_voice(text,uuid,text,jsonb)'::regprocedure) like '%zella_on_call%',
    'transfer_destination', pg_get_functiondef('public.zella_transfer_destination(text,text,text,text)'::regprocedure) like '%zella_on_call%');
$function$
;
CREATE OR REPLACE FUNCTION public.zella_open_incident(p_title text, p_detail text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid; b record; n integer := 0;
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  if length(trim(coalesce(p_title, ''))) < 3 then raise exception 'TITLE_REQUIRED'; end if;
  insert into public.platform_incidents (title, detail, created_by) values (left(trim(p_title), 200), left(p_detail, 1000), auth.uid()) returning id into v_id;
  for b in select id from public.businesses where suspended_at is null and cancelled_at is null and coalesce(is_active, true) loop
    perform public.zella_notify_owners(b.id, 'incident_open', left(trim(p_title), 120), coalesce(left(p_detail, 300), 'We are working on it and will tell you when it is fixed.'), 'warning', 'home');
    n := n + 1;
  end loop;
  update public.platform_incidents set notified_businesses = n where id = v_id;
  return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_open_workload(p_business_id uuid, p_user_id uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select (select count(*) from public.customers c where c.business_id = p_business_id and c.assigned_to = p_user_id and c.lead_stage in ('new', 'contacted', 'qualified', 'quote_sent'))::int
       + (select count(*) from public.callbacks b where b.business_id = p_business_id and b.assigned_to = p_user_id and b.status not in ('completed', 'cancelled'))::int
       + (select count(*) from public.crm_tasks t where t.business_id = p_business_id and t.assigned_to = p_user_id and t.status = 'open')::int;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_owner_continue_plan(p_business_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user uuid := auth.uid();
  v_cancel_at timestamptz;
begin
  if not exists (
    select 1 from business_members
    where business_id = p_business_id and user_id = v_user
      and status = 'active' and role = 'owner'
  ) then
    raise exception 'NOT_OWNER';
  end if;

  update businesses
  set cancel_at = null, cancel_requested_at = null, cancellation_reason = null, updated_at = now()
  where id = p_business_id and cancel_at is not null and cancelled_at is null
  returning cancel_at into v_cancel_at;

  if not found then
    return false;
  end if;

  insert into audit_logs (user_id, action, business_id, entity_type, entity_id, new_data)
  values (v_user, 'business.continued_by_owner', p_business_id, 'business', p_business_id,
          jsonb_build_object('via', 'business app'));
  return true;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_patch_function(p_signature text, p_marker text, p_anchor text, p_replacement text)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare d text; n integer;
begin
  if to_regprocedure(p_signature) is null then return 'missing'; end if;
  d := pg_get_functiondef(p_signature::regprocedure);
  if position(p_marker in d) > 0 then return 'already'; end if;
  n := (length(d) - length(replace(d, p_anchor, ''))) / greatest(length(p_anchor), 1);
  if n <> 1 then raise exception 'PATCH_ANCHOR % found % times in %', left(p_anchor, 60), n, p_signature; end if;
  execute replace(d, p_anchor, p_replacement);
  return 'patched';
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_pending_approvals(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'action', action, 'details', details, 'requested_by', requested_by, 'created_at', created_at, 'expires_at', expires_at,
                     'mine', requested_by = auth.uid()) order by created_at) from public.sensitive_approvals where business_id = p_business_id and status = 'pending' and expires_at > now()), '[]'::jsonb);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_performance_review(p_business_id uuid, p_days integer DEFAULT 7)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_since timestamptz := now() - make_interval(days => greatest(1, least(coalesce(p_days, 7), 90)));
        v_calls integer; v_missed integer; v_ai integer; v_tf integer; v_fail integer; v_gaps integer; v_booked integer; v_cb_open integer; v_cb_review integer; v_noshow integer; v_issues jsonb := '[]'::jsonb;
begin
  if auth.uid() is not null and not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select count(*), count(*) filter (where status = 'missed'), count(*) filter (where coalesce(ai_handled, false)),
         count(*) filter (where transfer_status in ('failed', 'no_one_available')), count(*) filter (where failure_reason is not null)
    into v_calls, v_missed, v_ai, v_tf, v_fail from public.calls where business_id = p_business_id and created_at >= v_since;
  select count(*) into v_gaps from public.knowledge_gaps where business_id = p_business_id and status = 'open';
  select count(*) into v_booked from public.appointments where business_id = p_business_id and created_at >= v_since and coalesce(booking_state, 'confirmed') = 'confirmed';
  select count(*) filter (where status not in ('completed', 'cancelled', 'needs_review')), count(*) filter (where status = 'needs_review') into v_cb_open, v_cb_review from public.callbacks where business_id = p_business_id;
  select count(*) into v_noshow from public.appointments where business_id = p_business_id and status = 'no_show' and start_time >= v_since;
  if v_calls > 0 and v_missed::numeric / v_calls > 0.2 then v_issues := v_issues || to_jsonb(v_missed || ' of ' || v_calls || ' calls were missed.'); end if;
  if v_tf > 0 then v_issues := v_issues || to_jsonb(v_tf || ' transfer(s) to a person failed.'); end if;
  if v_fail > 0 then v_issues := v_issues || to_jsonb(v_fail || ' call(s) could not be completed.'); end if;
  if v_gaps > 0 then v_issues := v_issues || to_jsonb(v_gaps || ' question(s) Zella could not answer need your review.'); end if;
  if v_cb_review > 0 then v_issues := v_issues || to_jsonb(v_cb_review || ' callback(s) need a person.'); end if;
  if v_noshow > 0 then v_issues := v_issues || to_jsonb(v_noshow || ' no-show(s).'); end if;
  return jsonb_build_object('days', p_days, 'calls', v_calls, 'missed', v_missed, 'ai_handled', v_ai, 'transfers_failed', v_tf, 'failed_calls', v_fail,
    'unanswered_questions', v_gaps, 'appointments_booked', v_booked, 'callbacks_open', v_cb_open, 'callbacks_needing_review', v_cb_review, 'no_shows', v_noshow, 'issues', v_issues);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_permission_check()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_fn text[]; v_pol text[]; v_allowed text[] := array['zella_unsubscribe_email', 'zella_unsubscribe_lookup', 'zella_digits', 'zella_valid_email'];
begin
  select coalesce(array_agg(p.proname order by p.proname), '{}') into v_fn from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and has_function_privilege('anon', p.oid, 'execute')
     and pg_get_function_result(p.oid) <> 'trigger' and p.proname <> all (v_allowed);
  select coalesce(array_agg(tablename || '.' || policyname order by tablename), '{}') into v_pol from pg_policies
   where schemaname = 'public' and (qual = 'true' or with_check = 'true') and (roles && array['anon'::name, 'public'::name] or cmd <> 'SELECT')
     and tablename not in ('plans', 'industries');
  return jsonb_build_object('anon_functions', to_jsonb(v_fn), 'open_policies', to_jsonb(v_pol), 'ok', cardinality(v_fn) = 0 and cardinality(v_pol) = 0);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_phone_capacity_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.status = 'active' and (tg_op = 'INSERT' or old.status is distinct from 'active')
     and not public.zella_entitlement_allows(new.business_id, 'phone_numbers', 1) then
    raise exception 'PHONE_NUMBER_LIMIT_REACHED';
  end if;
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_pick_assignee(p_business_id uuid, p_exclude uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_mode text := 'round_robin'; v_roles text[] := array['owner', 'admin', 'manager', 'staff']; v_user uuid;
begin
  select r.mode, r.roles into v_mode, v_roles from public.assignment_rules r where r.business_id = p_business_id;
  if not found then v_mode := 'round_robin'; v_roles := array['owner', 'admin', 'manager', 'staff']; end if;
  if v_mode = 'off' then return null; end if;
  select m.user_id into v_user
    from public.business_members m
   where m.business_id = p_business_id and m.status = 'active' and m.role = any (v_roles) and m.accepts_work
     and (m.away_until is null or m.away_until <= now()) and (p_exclude is null or m.user_id <> p_exclude)
   order by case when v_mode = 'least_busy' then public.zella_open_workload(p_business_id, m.user_id) else 0 end,
            m.last_assigned_at nulls first, m.created_at, m.user_id
   limit 1;
  return v_user;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_platform_admin_audit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    declare v_action text;
    begin
      if tg_op = 'INSERT' and new.is_active then v_action := 'platform_admin_granted';
      elsif tg_op = 'UPDATE' and new.is_active and not old.is_active then v_action := 'platform_admin_reactivated';
      elsif tg_op = 'UPDATE' and not new.is_active and old.is_active then v_action := 'platform_admin_removed';
      elsif tg_op = 'UPDATE' and new.role is distinct from old.role then v_action := 'platform_admin_role_changed';
      else return new; end if;
      insert into public.audit_logs (user_id, action, entity_type, entity_id, old_data, new_data)
      values (auth.uid(), v_action, 'platform_admin', new.user_id, case when tg_op = 'UPDATE' then jsonb_build_object('role', old.role, 'is_active', old.is_active) end, jsonb_build_object('role', new.role, 'is_active', new.is_active));
      perform public.zella_platform_alert('platform_admin_change', replace(v_action, '_', ' '), 'Role: ' || new.role, 'info', null, new.user_id::text || ':' || v_action || ':' || to_char(now(), 'YYYYMMDDHH24MISS'));
      return new;
    end $function$
;
CREATE OR REPLACE FUNCTION public.zella_platform_admin_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    begin
      if tg_op in ('INSERT', 'UPDATE') then
        if new.role not in ('super_admin', 'zella_owner') then raise exception 'INVALID_ADMIN_ROLE'; end if;
      end if;
      return new;
    end $function$
;
CREATE OR REPLACE FUNCTION public.zella_platform_alert(p_kind text, p_title text, p_detail text DEFAULT NULL::text, p_severity text DEFAULT 'warning'::text, p_business_id uuid DEFAULT NULL::uuid, p_dedupe_key text DEFAULT ''::text, p_meta jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid;
begin
  insert into public.platform_alerts (kind, title, detail, severity, business_id, dedupe_key, meta)
  values (p_kind, p_title, left(p_detail, 1000), case when p_severity in ('info','urgent') then p_severity else 'warning' end, p_business_id, coalesce(p_dedupe_key, ''), coalesce(p_meta, '{}'::jsonb))
  on conflict (kind, coalesce(business_id, '00000000-0000-0000-0000-000000000000'::uuid), dedupe_key) where status <> 'resolved'
  do update set occurrences = platform_alerts.occurrences + 1, last_seen_at = now(), detail = coalesce(excluded.detail, platform_alerts.detail), meta = platform_alerts.meta || excluded.meta
  returning id into v_id;
  return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_platform_health_summary()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  return jsonb_build_object(
    'providers', coalesce((select jsonb_agg(jsonb_build_object('provider', provider, 'ok', ok, 'detail', detail, 'checked_at', checked_at, 'failures_in_a_row', consecutive_failures)) from public.provider_health), '[]'::jsonb),
    'open_alerts', coalesce((select jsonb_object_agg(severity, c) from (select severity, count(*) c from public.platform_alerts where status = 'open' group by severity) x), '{}'::jsonb),
    'failed_events_24h', (select count(*) from public.automation_events where status = 'failed' and received_at > now() - interval '24 hours'),
    'businesses_active', (select count(*) from public.businesses where suspended_at is null and cancelled_at is null),
    'businesses_with_failed_messages_24h', (select count(distinct business_id) from public.sms_messages where direction = 'outbound' and status = 'failed' and created_at > now() - interval '24 hours'));
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_platform_metrics(p_from timestamp with time zone DEFAULT (now() - '7 days'::interval), p_to timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'automation_runs', (select jsonb_build_object('total', count(*), 'succeeded', count(*) filter (where status in ('completed','success')),
        'failed', count(*) filter (where status in ('failed','error')), 'waiting', count(*) filter (where status in ('running','pending','waiting')))
        from automation_runs where created_at >= p_from and created_at < p_to),
    'integrations', (select jsonb_build_object('total', count(*), 'with_errors', count(*) filter (where coalesce(error_count, 0) > 0 or status in ('error','failed','expired'))) from integrations),
    'usage', (select coalesce(jsonb_object_agg(usage_type, total), '{}'::jsonb)
        from (select usage_type, sum(quantity) total from usage_records where created_at >= p_from and created_at < p_to group by 1) u),
    'knowledge_sync', (select jsonb_build_object('items', count(*), 'updated_in_period', count(*) filter (where updated_at >= p_from and updated_at < p_to)) from knowledge_items),
    'businesses', (select jsonb_build_object('active', count(*) filter (where suspended_at is null and cancelled_at is null), 'suspended', count(*) filter (where suspended_at is not null)) from businesses)
  );
$function$
;
CREATE OR REPLACE FUNCTION public.zella_platform_public_info()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with p as (select coalesce((select value from public.platform_settings where key = 'platform_profile'), '{}'::jsonb) v),
       b as (select coalesce((select value from public.platform_settings where key = 'platform_branding'), '{}'::jsonb) v),
       m as (select coalesce((select value from public.platform_settings where key = 'maintenance'), '{}'::jsonb) v)
  select jsonb_strip_nulls(jsonb_build_object(
    'display_name', p.v ->> 'display_name', 'support_email', p.v ->> 'support_email', 'support_phone', p.v ->> 'support_phone',
    'website', p.v ->> 'website', 'logo_url', b.v ->> 'logo_url', 'login_headline', b.v ->> 'login_headline',
    'maintenance', case
      when coalesce((m.v ->> 'active')::boolean, false)
           and coalesce((m.v ->> 'ends_at')::timestamptz > now(), true)
        then jsonb_build_object('state', case when coalesce((m.v ->> 'starts_at')::timestamptz <= now(), true) then 'now' else 'scheduled' end,
                                'message', m.v ->> 'message', 'starts_at', m.v ->> 'starts_at', 'ends_at', m.v ->> 'ends_at')
    end))
  from p, b, m;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_post_callback_digests()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare b record; v_open int; v_over int; n int := 0;
begin
  for b in select id, coalesce(timezone, 'America/New_York') tz from public.businesses where suspended_at is null and cancelled_at is null loop
    continue when extract(hour from now() at time zone b.tz) <> 8;
    continue when exists (select 1 from public.staff_notifications s where s.business_id = b.id and s.kind = 'callback_digest' and s.created_at > now() - interval '20 hours');
    select count(*), count(*) filter (where due_at < now()) into v_open, v_over from public.callbacks
     where business_id = b.id and status not in ('completed','done','reached','cancelled','failed');
    continue when v_open = 0;
    perform public.zella_notify_owners(b.id, 'callback_digest', 'Callbacks for today', v_open || ' open' || case when v_over > 0 then ', ' || v_over || ' overdue' else '' end || '. Open Callbacks to work through them.', case when v_over > 0 then 'warning' else 'info' end, 'callbacks');
    n := n + 1;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_post_daily_summaries()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  b record; v_tz text; v_rev jsonb; v_leads int; v_today int; v_overdue int; v_issues text; v_body text; v_day_start timestamptz; n integer := 0;
begin
  for b in select id, name, coalesce(timezone, 'America/New_York') as tz from public.businesses
            where onboarding_status = 'active' and suspended_at is null and cancelled_at is null loop
    v_tz := b.tz;
    begin
      if extract(hour from (now() at time zone v_tz)) <> 8 then continue; end if;
    exception when others then continue; end;
    if exists (select 1 from public.staff_notifications where business_id = b.id and kind = 'daily_summary' and created_at > now() - interval '20 hours') then continue; end if;

    v_rev := public.zella_performance_review(b.id, 1);
    select count(*) into v_leads from public.customers where business_id = b.id and created_at >= now() - interval '24 hours';
    v_day_start := date_trunc('day', now() at time zone v_tz) at time zone v_tz;
    select count(*) into v_today from public.appointments
     where business_id = b.id and start_time >= v_day_start and start_time < v_day_start + interval '1 day'
       and status in ('scheduled', 'confirmed') and coalesce(booking_state, 'confirmed') = 'confirmed';
    select count(*) into v_overdue from public.callbacks
     where business_id = b.id and status not in ('completed', 'cancelled', 'needs_review') and due_at < now();

    v_issues := (select string_agg(x, ' ') from jsonb_array_elements_text(v_rev -> 'issues') x);
    if v_overdue > 0 then v_issues := concat_ws(' ', v_issues, v_overdue || ' callback(s) are overdue.'); end if;

    if (v_rev ->> 'calls')::int = 0 and v_leads = 0 and v_today = 0 and (v_rev ->> 'appointments_booked')::int = 0 and v_issues is null then continue; end if;

    v_body := 'Yesterday: ' || (v_rev ->> 'calls') || ' call(s), ' || (v_rev ->> 'missed') || ' missed, '
           || (v_rev ->> 'appointments_booked') || ' booked, ' || v_leads || ' new customer(s) or lead(s). '
           || 'Today: ' || v_today || ' appointment(s). '
           || case when v_issues is not null then 'To look at: ' || v_issues else 'Nothing needs attention.' end;
    perform public.zella_notify_owners(b.id, 'daily_summary', 'Your day with Zella - ' || b.name, v_body,
      case when v_issues is not null then 'warning' else 'info' end, 'reports');
    n := n + 1;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_post_team_summaries()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare m record; v_hour integer := coalesce(nullif(public.zella_setting('team_summary_hour', '8'::jsonb) #>> '{}', '')::integer, 8);
        v_start timestamptz; v_end timestamptz; a integer; c integer; e integer; v_first timestamptz; v_n integer := 0; v_body text;
begin
  for m in select bm.business_id, bm.user_id, coalesce(b.timezone, 'America/New_York') tz from public.business_members bm
            join public.businesses b on b.id = bm.business_id and b.suspended_at is null and b.cancelled_at is null
           where bm.status = 'active' and bm.role in ('owner', 'admin', 'manager', 'staff') and (bm.away_until is null or bm.away_until < now()) loop
    continue when extract(hour from (now() at time zone m.tz))::integer <> v_hour;
    continue when exists (select 1 from public.staff_notifications s where s.user_id = m.user_id and s.business_id = m.business_id and s.kind = 'team_summary' and s.created_at > now() - interval '20 hours');
    v_start := date_trunc('day', now() at time zone m.tz) at time zone m.tz;
    v_end := v_start + interval '1 day';
    select count(*), min(start_time) into a, v_first from public.appointments where business_id = m.business_id and assigned_to = m.user_id and status in ('scheduled', 'confirmed') and start_time >= v_start and start_time < v_end;
    select count(*) into c from public.callbacks where business_id = m.business_id and assigned_to = m.user_id and status in ('scheduled', 'retry_scheduled', 'due') and due_at < v_end;
    select count(*) into e from public.calls where business_id = m.business_id and assigned_to = m.user_id and needs_human and escalation_resolved_at is null;
    continue when a + c + e = 0;
    v_body := array_to_string(array_remove(array[
      case when a > 0 then a || ' appointment' || case when a = 1 then '' else 's' end || ' today' || case when v_first is not null then ', the first at ' || to_char(v_first at time zone m.tz, 'HH12:MI AM') else '' end end,
      case when c > 0 then c || ' callback' || case when c = 1 then '' else 's' end || ' to make' end,
      case when e > 0 then e || ' call' || case when e = 1 then '' else 's' end || ' waiting for you' end], null), '. ') || '.';
    perform public.zella_notify(m.business_id, 'team_summary', 'Your day', v_body, 'info', 'today', null, m.user_id);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_post_weekly_reviews()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare b record; v_rev jsonb; n integer := 0;
begin
  for b in select id from public.businesses where onboarding_status = 'active' and suspended_at is null and cancelled_at is null loop
    v_rev := public.zella_performance_review(b.id, 7);
    if (v_rev ->> 'calls')::int > 0 or jsonb_array_length(v_rev -> 'issues') > 0 then
      perform public.zella_notify_owners(b.id, 'weekly_review', 'Your week with Zella',
        (v_rev ->> 'calls') || ' calls, ' || (v_rev ->> 'appointments_booked') || ' booked.' || case when jsonb_array_length(v_rev -> 'issues') > 0 then ' To look at: ' || (select string_agg(x, ' ') from jsonb_array_elements_text(v_rev -> 'issues') x) else ' Nothing needs attention.' end,
        case when jsonb_array_length(v_rev -> 'issues') > 0 then 'warning' else 'info' end, 'reports');
      n := n + 1;
    end if;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_prepare_email(p_business_id uuid, p_customer_id uuid, p_template_key text, p_vars jsonb DEFAULT '{}'::jsonb, p_purpose text DEFAULT 'transactional'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  b public.businesses; c public.customers; t public.message_templates;
  v_body text; v_subject text; v_to text; v_html text; kv record; v_val text; v_base text; v_unsub text;
  v_live boolean := coalesce(public.zella_setting('email_live', 'false'::jsonb) = 'true'::jsonb, false);
  v_from text := nullif(trim(public.zella_setting('email_from_address', '""'::jsonb) #>> '{}'), '');
  v_purpose text := case when p_purpose = 'marketing' then 'marketing' else 'transactional' end;
begin
  select * into b from public.businesses where id = p_business_id;
  if not found then return jsonb_build_object('allowed', false, 'reason', 'unknown_business', 'live', v_live); end if;
  if b.suspended_at is not null or b.cancelled_at is not null then
    return jsonb_build_object('allowed', false, 'reason', 'business_not_available', 'live', v_live);
  end if;
  select * into c from public.customers where id = p_customer_id and business_id = p_business_id;
  if not found then return jsonb_build_object('allowed', false, 'reason', 'unknown_customer', 'live', v_live); end if;
  if v_purpose = 'marketing' then
    v_base := regexp_replace(coalesce(nullif(trim(public.zella_setting('app_base_url', '""'::jsonb) #>> '{}'), ''), ''), '/+$', '');
    if v_base = '' then return jsonb_build_object('allowed', false, 'reason', 'marketing_email_not_ready', 'live', v_live); end if;
  end if;
  if not public.zella_can_contact(p_business_id, p_customer_id, 'email', v_purpose) then
    return jsonb_build_object('allowed', false, 'reason', 'no_consent', 'live', v_live);
  end if;

  v_to := lower(trim(coalesce(c.email, '')));
  if v_to !~ '^[^@\s,;<>]+@[^@\s,;<>]+\.[^@\s,;<>]+$' or length(v_to) > 254 then
    return jsonb_build_object('allowed', false, 'reason', 'no_valid_email', 'live', v_live);
  end if;

  select * into t from public.zella_resolve_template(p_business_id, p_template_key, 'email', 'en-US');
  if t.id is null then return jsonb_build_object('allowed', false, 'reason', 'no_template', 'live', v_live); end if;

  v_body := t.body;
  v_subject := coalesce(t.subject, '');
  -- Values go in with line breaks removed, so a customer name can never add email headers or extra paragraphs.
  v_val := coalesce(nullif(trim(regexp_replace(c.first_name, '[\r\n]+', ' ', 'g')), ''), 'there');
  v_body := replace(v_body, '{{first_name}}', v_val);     v_subject := replace(v_subject, '{{first_name}}', v_val);
  v_val := regexp_replace(b.name, '[\r\n]+', ' ', 'g');
  v_body := replace(v_body, '{{business}}', v_val);       v_subject := replace(v_subject, '{{business}}', v_val);
  for kv in select key, value from jsonb_each_text(coalesce(p_vars, '{}'::jsonb)) loop
    v_val := left(regexp_replace(kv.value, '[\r\n]+', ' ', 'g'), 200);
    v_body := replace(v_body, '{{' || kv.key || '}}', v_val);
    v_subject := replace(v_subject, '{{' || kv.key || '}}', v_val);
  end loop;
  if v_body ~ '\{\{[^}]*\}\}' or v_subject ~ '\{\{[^}]*\}\}' then
    return jsonb_build_object('allowed', false, 'reason', 'unfilled_placeholder', 'live', v_live);
  end if;
  v_subject := left(trim(v_subject), 200);
  if v_subject = '' then return jsonb_build_object('allowed', false, 'reason', 'no_subject', 'live', v_live); end if;

  -- Plain text body is kept as written; the HTML copy has every special character escaped.
  v_html := replace(replace(replace(replace(replace(v_body, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;');
  v_html := '<p>' || replace(replace(v_html, E'\n\n', '</p><p>'), E'\n', '<br>') || '</p>';

  if v_purpose = 'marketing' then
    v_unsub := v_base || '/u/' || public.zella_unsubscribe_token(p_business_id, p_customer_id);
    v_body := v_body || E'\n\nTo stop marketing emails from ' || regexp_replace(b.name, '[\r\n]+', ' ', 'g') || ', open: ' || v_unsub;
    v_html := v_html || '<p><a href="' || v_unsub || '">Unsubscribe</a></p>';
  end if;
  return jsonb_build_object('allowed', true, 'unsubscribe_url', v_unsub, 'reason', null, 'live', v_live, 'to', v_to, 'from', v_from,
    'from_name', left(regexp_replace(b.name, '[\r\n"<>]+', ' ', 'g'), 80),
    'reply_to', coalesce(public.zella_inbound_email_address(b.id), nullif(lower(trim(coalesce(to_jsonb(b) ->> 'email', ''))), '')),
    'subject', v_subject, 'body_text', v_body, 'body_html', v_html,
    'template_id', t.id, 'template_version', t.version, 'purpose', v_purpose);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_prepare_sms(p_business_id uuid, p_customer_id uuid, p_template_key text, p_vars jsonb DEFAULT '{}'::jsonb, p_purpose text DEFAULT 'transactional'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  b public.businesses; c public.customers; t public.message_templates;
  v_body text; v_to text; v_digits text; v_raw text; kv record; v_hour int;
  v_live boolean := coalesce(public.zella_setting('sms_live', 'false'::jsonb) = 'true'::jsonb, false);
  v_from text := nullif(public.zella_setting('sms_from_number', '""'::jsonb) #>> '{}', '');
  v_purpose text := case when p_purpose = 'marketing' then 'marketing' else 'transactional' end;
begin
  select * into b from public.businesses where id = p_business_id;
  if not found then return jsonb_build_object('allowed', false, 'reason', 'unknown_business', 'live', v_live); end if;
  if b.suspended_at is not null or b.cancelled_at is not null then
    return jsonb_build_object('allowed', false, 'reason', 'business_not_available', 'live', v_live);
  end if;
  select * into c from public.customers where id = p_customer_id and business_id = p_business_id;
  if not found then return jsonb_build_object('allowed', false, 'reason', 'unknown_customer', 'live', v_live); end if;
  if not public.zella_can_contact(p_business_id, p_customer_id, 'sms', v_purpose) then
    return jsonb_build_object('allowed', false, 'reason', 'no_consent', 'live', v_live);
  end if;

  v_raw := coalesce(c.phone, '');
  v_digits := regexp_replace(v_raw, '\D', '', 'g');
  if v_raw like '+%' and length(v_digits) between 8 and 15 then v_to := '+' || v_digits;
  elsif length(v_digits) = 10 then v_to := '+1' || v_digits;
  elsif length(v_digits) = 11 and left(v_digits, 1) = '1' then v_to := '+' || v_digits;
  end if;
  if v_to is null then return jsonb_build_object('allowed', false, 'reason', 'no_valid_phone', 'live', v_live); end if;

  if v_purpose = 'marketing' and coalesce(public.zella_setting('sms_marketing_allowed', 'false'::jsonb) = 'true'::jsonb, false) = false then
    return jsonb_build_object('allowed', false, 'reason', 'sms_marketing_off', 'live', v_live);
  end if;
  if v_purpose = 'marketing' then
    v_hour := extract(hour from (now() at time zone coalesce(b.timezone, 'America/New_York')));
    if v_hour < 8 or v_hour >= 21 then
      return jsonb_build_object('allowed', false, 'reason', 'quiet_hours', 'live', v_live);
    end if;
  end if;

  select * into t from public.zella_resolve_template(p_business_id, p_template_key, 'sms', 'en-US');
  if t.id is null then return jsonb_build_object('allowed', false, 'reason', 'no_template', 'live', v_live); end if;

  v_body := t.body;
  v_body := replace(v_body, '{{first_name}}', coalesce(nullif(trim(c.first_name), ''), 'there'));
  v_body := replace(v_body, '{{business}}', b.name);
  for kv in select key, value from jsonb_each_text(coalesce(p_vars, '{}'::jsonb)) loop
    v_body := replace(v_body, '{{' || kv.key || '}}', left(kv.value, 200));
  end loop;
  if v_body ~ '\{\{[^}]*\}\}' then
    return jsonb_build_object('allowed', false, 'reason', 'unfilled_placeholder', 'live', v_live);
  end if;

  return jsonb_build_object('allowed', true, 'reason', null, 'live', v_live, 'to', v_to, 'from', v_from,
    'body', v_body, 'template_id', t.id, 'template_version', t.version, 'purpose', v_purpose);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_preview_template(p_business_id uuid, p_key text, p_channel text, p_vars jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_process_billing_event(p_provider text, p_event_id text, p_type text, p_external_subscription_id text DEFAULT NULL::text, p_business_id uuid DEFAULT NULL::uuid, p_amount numeric DEFAULT NULL::numeric, p_currency text DEFAULT NULL::text, p_external_payment_id text DEFAULT NULL::text, p_period_start timestamp with time zone DEFAULT NULL::timestamp with time zone, p_period_end timestamp with time zone DEFAULT NULL::timestamp with time zone, p_plan_slug text DEFAULT NULL::text, p_reason text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s record; v_biz uuid; v_plan uuid; v_res text := 'processed'; v_ins uuid;
begin
  insert into public.billing_events (provider, external_event_id, type, business_id, data)
  values (left(p_provider, 40), left(p_event_id, 200), left(p_type, 60), p_business_id,
          jsonb_build_object('external_subscription_id', p_external_subscription_id, 'external_payment_id', p_external_payment_id, 'amount', p_amount, 'currency', p_currency, 'plan', p_plan_slug))
  on conflict (provider, external_event_id) do nothing returning id into v_ins;
  if v_ins is null then return 'duplicate'; end if;

  begin
    -- A refund or dispute names a payment, not a subscription: find the business from that payment.
    if p_type = 'payment_reversed' and p_external_subscription_id is null and p_business_id is null then
      select pm.business_id into p_business_id from public.payments pm where pm.external_payment_id = p_external_payment_id limit 1;
    end if;
    select * into s from public.subscriptions
     where (p_external_subscription_id is not null and external_subscription_id = p_external_subscription_id)
        or (p_external_subscription_id is null and p_business_id is not null and business_id = p_business_id)
     order by created_at desc limit 1;
    if s.id is null then
      update public.billing_events set status = 'ignored', error = 'no_matching_subscription' where id = v_ins;
      return 'ignored';
    end if;
    v_biz := s.business_id;
    update public.billing_events set business_id = v_biz, subscription_id = s.id where id = v_ins;

    if p_type = 'payment_succeeded' then
      insert into public.payments (business_id, subscription_id, amount, currency, status, provider, external_payment_id, paid_at)
      values (v_biz, s.id, coalesce(p_amount, 0), coalesce(lower(p_currency), 'usd'), 'succeeded', p_provider, p_external_payment_id, now());
      perform public.zella_record_payment_result(v_biz, true, p_external_payment_id, null);
      if p_period_end is not null then
        update public.subscriptions set current_period_start = coalesce(p_period_start, current_period_start), current_period_end = p_period_end where id = s.id;
      end if;
      perform public.zella_notify_owners(v_biz, 'payment_received', 'Payment received', 'Thank you. Your payment went through and your account is up to date.', 'info', 'settings');
    elsif p_type = 'payment_failed' then
      insert into public.payments (business_id, subscription_id, amount, currency, status, provider, external_payment_id, failure_reason)
      values (v_biz, s.id, coalesce(p_amount, 0), coalesce(lower(p_currency), 'usd'), 'failed', p_provider, p_external_payment_id, left(p_reason, 300));
      perform public.zella_record_payment_result(v_biz, false, p_external_payment_id, coalesce(p_reason, 'Payment failed'));
      perform public.zella_notify_owners(v_biz, 'payment_failed', 'Your payment did not go through', 'Please update your billing details so your service is not interrupted.', 'urgent', 'settings');
    elsif p_type = 'subscription_renewed' then
      update public.subscriptions set status = 'active', current_period_start = coalesce(p_period_start, current_period_start),
             current_period_end = coalesce(p_period_end, current_period_end) where id = s.id;
    elsif p_type = 'subscription_cancelled' then
      update public.subscriptions set status = 'cancelled', cancelled_at = coalesce(cancelled_at, now()) where id = s.id and status <> 'cancelled';
      perform public.zella_notify_owners(v_biz, 'subscription_cancelled', 'Your subscription was cancelled', 'Your plan has been cancelled. Contact support if this is a mistake.', 'warning', 'settings');
    elsif p_type = 'payment_reversed' then
      update public.payments set status = 'refunded', updated_at = now() where business_id = v_biz and external_payment_id = p_external_payment_id;
      perform public.zella_platform_alert('payment_reversed', 'A payment was refunded or disputed', left(p_reason, 300), 'warning', v_biz, 'payment_reversed:' || coalesce(p_external_payment_id, ''));
    elsif p_type = 'plan_changed' then
      select id into v_plan from public.plans where slug = p_plan_slug and is_active;
      if v_plan is null then
        update public.billing_events set status = 'ignored', error = 'unknown_plan' where id = v_ins; v_res := 'ignored';
      else
        update public.subscriptions set plan_id = v_plan where id = s.id;
      end if;
    else
      update public.billing_events set status = 'ignored', error = 'unknown_type' where id = v_ins; v_res := 'ignored';
    end if;
    return v_res;
  exception when others then
    delete from public.billing_events where id = v_ins;
    perform public.zella_platform_alert('billing_event_failed', 'A billing event could not be applied', left(sqlerrm, 200), 'urgent', p_business_id, 'billing_event_failed');
    return 'failed';
  end;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_process_call_usage(p_call_id uuid, p_source text DEFAULT 'event'::text, p_event_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c public.calls; v_cat jsonb; v_policy jsonb; v_bill integer; v_rec public.usage_records; v_period jsonb;
        v_current integer; v_delta integer; v_delta_bill integer; v_id uuid; v_at timestamptz; v_hours integer;
begin
  select * into c from public.calls where id = p_call_id for update;
  if c.id is null then return jsonb_build_object('result', 'not_found'); end if;
  if nullif(c.external_call_id, '') is null then return jsonb_build_object('result', 'no_provider_call_id'); end if;
  v_cat := public.zella_call_usage_category(c);
  if not (v_cat ->> 'counted')::boolean then return jsonb_build_object('result', 'not_counted', 'reason', v_cat ->> 'rule', 'category', v_cat ->> 'category'); end if;
  -- the call has to be over, with the report in (or reconciled), before its length is final
  if c.ended_at is null or coalesce(c.metadata ->> 'awaiting_report', 'false') = 'true' then return jsonb_build_object('result', 'pending'); end if;
  v_at := coalesce(c.started_at, c.answered_at, c.created_at);
  if c.duration_seconds is null then
    v_hours := coalesce((public.zella_setting('call_usage_missing_duration_hours', '6'::jsonb) #>> '{}')::int, 6);
    if c.ended_at < now() - make_interval(hours => v_hours) then
      perform public.zella_usage_open_issue(c.business_id, c.id, 'missing_duration', 'The provider has not reported a duration for this call.');
    end if;
    return jsonb_build_object('result', 'missing_duration');
  end if;
  if c.duration_seconds < 0 or c.duration_seconds > 86400 then
    perform public.zella_usage_open_issue(c.business_id, c.id, 'invalid_duration', 'Reported duration ' || c.duration_seconds || ' s is not plausible.');
    return jsonb_build_object('result', 'invalid_duration');
  end if;

  select * into v_rec from public.usage_records where usage_type = 'ai_call' and call_id = c.id and entry_kind = 'usage';
  if v_rec.id is null then
    v_policy := public.zella_usage_policy() || jsonb_build_object('category_rule', v_cat ->> 'rule', 'industry', v_cat ->> 'industry');
    v_bill := public.zella_usage_billable_seconds(c.duration_seconds, v_policy);
    v_period := public.zella_usage_period_for(c.business_id, v_at);
    insert into public.usage_records (business_id, subscription_id, usage_type, quantity, unit, period_start, period_end, source_id, metadata,
        call_id, provider_call_id, provider_event_id, idempotency_key, entry_kind, usage_category, occurred_at, duration_seconds, billable_seconds,
        policy, period_source, processed_by)
    values (c.business_id, (v_period ->> 'subscription_id')::uuid, 'ai_call', round(v_bill / 60.0, 4), 'minute', (v_period ->> 'from')::timestamptz,
        (v_period ->> 'to')::timestamptz, c.id, jsonb_build_object('ended_at_source', c.metadata ->> 'ended_at_source'),
        c.id, c.external_call_id, nullif(left(p_event_id, 200), ''), 'ai_call:' || c.external_call_id, 'usage', v_cat ->> 'category', v_at,
        c.duration_seconds, v_bill, v_policy, v_period ->> 'source', left(coalesce(p_source, 'event'), 40))
    on conflict do nothing
    returning id into v_id;
    update public.usage_processing_issues set status = 'resolved', resolved_at = now(), resolution = 'recorded', updated_at = now()
     where call_id = c.id and status <> 'resolved' and kind in ('missing_duration', 'invalid_duration', 'processing_failed');
    begin perform public.zella_evaluate_call_usage_thresholds(c.business_id); exception when others then null; end;
    return jsonb_build_object('result', case when v_id is null then 'unchanged' else 'recorded' end, 'usage_record_id', coalesce(v_id, (select id from public.usage_records where usage_type = 'ai_call' and call_id = c.id and entry_kind = 'usage')));
  end if;

  -- already recorded: a later, different provider duration becomes an adjustment (history kept), using the original policy
  select v_rec.duration_seconds + coalesce(sum(a.duration_seconds), 0) into v_current
    from public.usage_records a where a.adjusts_record_id = v_rec.id and a.entry_kind = 'adjustment';
  if v_current = c.duration_seconds then return jsonb_build_object('result', 'unchanged', 'usage_record_id', v_rec.id); end if;
  v_delta := c.duration_seconds - v_current;
  v_delta_bill := public.zella_usage_billable_seconds(c.duration_seconds, v_rec.policy)
                  - (v_rec.billable_seconds + coalesce((select sum(a.billable_seconds) from public.usage_records a where a.adjusts_record_id = v_rec.id and a.entry_kind = 'adjustment'), 0));
  insert into public.usage_records (business_id, subscription_id, usage_type, quantity, unit, period_start, period_end, source_id, metadata,
      call_id, provider_call_id, idempotency_key, entry_kind, adjusts_record_id, usage_category, occurred_at, duration_seconds, billable_seconds,
      policy, period_source, reconciliation_status, processed_by)
  values (v_rec.business_id, v_rec.subscription_id, 'ai_call', round(v_delta_bill / 60.0, 4), 'minute', v_rec.period_start, v_rec.period_end, c.id,
      jsonb_build_object('previous_seconds', v_current, 'new_seconds', c.duration_seconds, 'ended_at_source', c.metadata ->> 'ended_at_source'),
      -- numbered per call: the same state retried gives the same key (no duplicate); a new change gets the next number
      c.id, c.external_call_id, 'ai_call:' || c.external_call_id || ':adj' || (select count(*) + 1 from public.usage_records a where a.adjusts_record_id = v_rec.id)
                                 || ':' || v_current || '>' || c.duration_seconds, 'adjustment', v_rec.id,
      v_rec.usage_category, v_rec.occurred_at, v_delta, v_delta_bill, v_rec.policy, v_rec.period_source, 'adjusted', left(coalesce(p_source, 'event'), 40))
  on conflict do nothing returning id into v_id;
  update public.usage_records set reconciliation_status = 'adjusted', updated_at = now() where id = v_rec.id;
  update public.usage_processing_issues set status = 'resolved', resolved_at = now(), resolution = 'adjusted', updated_at = now()
   where call_id = c.id and status <> 'resolved' and kind in ('duration_changed', 'processing_failed');
  begin perform public.zella_evaluate_call_usage_thresholds(c.business_id); exception when others then null; end;
  return jsonb_build_object('result', 'adjusted', 'usage_record_id', v_rec.id, 'adjustment_id', v_id, 'delta_seconds', v_delta);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_process_cancellations()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_ids uuid[];
begin
  select coalesce(array_agg(id), '{}') into v_ids
  from businesses
  where cancel_at is not null and cancel_at <= now() and cancelled_at is null;

  if cardinality(v_ids) = 0 then return 0; end if;

  update ai_agents set status = 'disabled', updated_at = now()
  where business_id = any(v_ids) and status <> 'disabled';

  update automations set status = 'disabled', updated_at = now()
  where business_id = any(v_ids) and status <> 'disabled';

  update subscriptions set status = 'cancelled'
  where business_id = any(v_ids)
    and status in ('trial', 'active', 'renewal_due', 'past_due', 'grace_period');

  update businesses
  set cancelled_at = now(),
      is_active = false,
      updated_at = now()
  where id = any(v_ids);

  insert into audit_logs (action, business_id, entity_type, entity_id, new_data)
  select 'business.cancelled', id, 'business', id,
         jsonb_build_object('cancel_at', cancel_at, 'reason', cancellation_reason)
  from businesses where id = any(v_ids);

  return cardinality(v_ids);
end;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_provider_checks_live()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(public.zella_setting('provider_checks_live', 'false'::jsonb) = 'true'::jsonb, false);
$function$
;
CREATE OR REPLACE FUNCTION public.zella_public_status()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_checks boolean := public.zella_provider_checks_live();
  v_n8n boolean := nullif(trim(public.zella_setting('n8n_base_url', '""'::jsonb) #>> '{}'), '') is not null
                   and coalesce(public.zella_setting('n8n_dispatch_enabled', 'true'::jsonb) = 'true'::jsonb, true);
  v_components jsonb := '[]'::jsonb; v_incidents jsonb; v_state text; h record; c record; v_rank int := 0;
  rank_of constant jsonb := '{"operational": 0, "unknown": 0, "degraded": 1, "outage": 2}';
begin
  for c in select * from (values ('phone', 'Phone assistant', 'vapi'), ('texts', 'Text messages', 'telnyx'), ('email', 'Email', 'resend')) as t(key, label, provider) loop
    select * into h from public.provider_health where provider = c.provider;
    v_state := case
      when not v_checks or h.provider is null or h.checked_at is null or h.checked_at < now() - interval '6 hours' then 'unknown'
      when h.ok then 'operational'
      when h.consecutive_failures >= 2 then 'outage'
      else 'degraded' end;
    v_components := v_components || jsonb_build_object('key', c.key, 'label', c.label, 'state', v_state,
      'checked_at', case when v_state <> 'unknown' then h.checked_at end);
  end loop;
  v_state := case
    when exists (select 1 from public.platform_alerts a where a.status <> 'resolved' and a.kind in ('automation_heartbeat', 'automation_stalled')) then 'outage'
    when exists (select 1 from public.platform_alerts a where a.status <> 'resolved' and a.kind = 'queue_backlog') then 'degraded'
    when v_n8n then 'operational' else 'unknown' end;
  v_components := v_components || jsonb_build_object('key', 'automations', 'label', 'Reminders and follow-ups', 'state', v_state);
  v_components := v_components || jsonb_build_object('key', 'app', 'label', 'Zella app', 'state', 'operational');

  for c in select distinct i.component from public.platform_incidents i where i.is_public and i.status = 'open' and i.component is not null loop
    select coalesce(jsonb_agg(case when x ->> 'key' = c.component and x ->> 'state' in ('operational', 'unknown') then x || '{"state": "degraded"}'::jsonb else x end), '[]'::jsonb)
      into v_components from jsonb_array_elements(v_components) x;
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object('title', i.title, 'message', i.public_message, 'status', i.status, 'component', i.component,
           'started_at', i.created_at, 'resolved_at', i.resolved_at) order by (i.status = 'open') desc, i.created_at desc), '[]'::jsonb) into v_incidents
    from (select * from public.platform_incidents where is_public and (status = 'open' or resolved_at > now() - interval '14 days')
           order by created_at desc limit 20) i;

  select max((rank_of ->> (x ->> 'state'))::int) into v_rank from jsonb_array_elements(v_components) x;
  if exists (select 1 from public.platform_incidents where is_public and status = 'open') then v_rank := greatest(v_rank, 1); end if;
  return jsonb_build_object('overall', case v_rank when 2 then 'outage' when 1 then 'degraded' else 'operational' end,
    'components', v_components, 'incidents', v_incidents, 'generated_at', now());
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_publish_agent_config(p_version_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v record; c jsonb;
begin
  select * into v from public.agent_config_versions where id = p_version_id for update;
  if not found or not public.zella_can_manage(v.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if v.status <> 'valid' then raise exception 'NOT_VALID'; end if;   -- only a validated version can go live
  c := v.config;
  update public.ai_agent_configs set system_prompt = coalesce(c ->> 'system_prompt', system_prompt), personality = coalesce(c ->> 'personality', personality), tone = coalesce(c ->> 'tone', tone),
         goals = coalesce(c -> 'goals', goals), capabilities = coalesce(c -> 'capabilities', capabilities), knowledge_base = coalesce(c -> 'knowledge_base', knowledge_base),
         escalation_rules = coalesce(c -> 'escalation_rules', escalation_rules), appointment_rules = coalesce(c -> 'appointment_rules', appointment_rules),
         voice_config = coalesce(c -> 'voice_config', voice_config), business_context = coalesce(c -> 'business_context', business_context), updated_at = now()
   where agent_id = v.agent_id;
  update public.agent_config_versions set status = 'superseded' where agent_id = v.agent_id and status = 'published';
  update public.agent_config_versions set status = 'published', published_by = auth.uid(), published_at = now(), sync_status = 'pending' where id = p_version_id;
  perform public.zella_notify_owners(v.business_id, 'agent_config_published', 'AI receptionist updated', 'Version ' || v.version || ' was published. It goes live once it has synced.', 'info', 'receptionist');
  return v.version;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_queue_calendar_sync()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_action text; v_state text := coalesce(to_jsonb(new) ->> 'booking_state', 'confirmed');
begin
  if not exists (select 1 from public.calendar_connections c where c.business_id = new.business_id and c.status = 'active') then return new; end if;
  if new.status in ('cancelled', 'no_show') or v_state = 'requested' then
    if new.external_event_id is null then return new; end if;
    v_action := 'delete';
  elsif v_state = 'tentative' or new.status not in ('scheduled', 'confirmed', 'completed') then
    return new;
  else
    v_action := 'upsert';
  end if;
  insert into public.calendar_sync_queue (business_id, appointment_id, action) values (new.business_id, new.id, v_action)
  on conflict (appointment_id) where status = 'pending' do update set action = excluded.action, due_at = now();
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_queue_customer_message(p_business_id uuid, p_customer_id uuid, p_kind text, p_vars jsonb DEFAULT '{}'::jsonb, p_delay interval DEFAULT '00:00:00'::interval, p_appointment_id uuid DEFAULT NULL::uuid, p_dedupe interval DEFAULT '30 days'::interval)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c record; v_channel text; v_id uuid;
begin
  if p_kind not in ('welcome_new_customer','feedback_request','cancellation_confirmation','record_status_update','service_due','no_response_follow_up','reschedule_confirmation','booking_follow_up','service_completed','lead_follow_up','lead_final_follow_up') then
    raise exception 'BAD_KIND';
  end if;
  if coalesce(public.zella_setting('customer_touches', '{}'::jsonb) -> p_kind, 'true'::jsonb) = 'false'::jsonb then return null; end if;
  select x.id, x.phone, x.email, coalesce(x.do_not_contact,false) dnc, coalesce(x.do_not_sms,false) dns, coalesce(x.do_not_email,false) dne, x.preferred_channel pref
    into c from public.customers x where x.id = p_customer_id and x.business_id = p_business_id;
  if c.id is null or c.dnc then return null; end if;
  if c.pref = 'email' and public.zella_valid_email(c.email) and not c.dne then v_channel := 'email';
  elsif public.zella_digits(c.phone) is not null and not c.dns then v_channel := 'sms';
  elsif public.zella_valid_email(c.email) and not c.dne then v_channel := 'email';
  else return null; end if;
  if p_kind <> 'record_status_update' and exists (
       select 1 from public.followup_tasks f where f.customer_id = p_customer_id and f.kind = p_kind
          and (f.status in ('pending','in_progress') or f.created_at > now() - p_dedupe)
          and (p_appointment_id is null or f.appointment_id is not distinct from p_appointment_id)) then
    return null;
  end if;
  insert into public.followup_tasks (business_id, customer_id, appointment_id, kind, channel, due_at, max_attempts, vars)
  values (p_business_id, p_customer_id, p_appointment_id, p_kind, v_channel, now() + p_delay, 2, coalesce(p_vars, '{}'::jsonb))
  on conflict do nothing
  returning id into v_id;
  return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_queue_customer_touches(p_limit integer DEFAULT 50)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a record; c record; n integer := 0; v_days integer;
begin
  for a in select * from public.automations x where x.trigger_type = 'service_due' and x.status = 'active' loop
    v_days := greatest(7, coalesce((a.trigger_config ->> 'days')::integer, 180));
    for c in select x.id from public.customers x
              where x.business_id = a.business_id and not coalesce(x.do_not_contact, false)
                and exists (select 1 from public.appointments p where p.customer_id = x.id and p.status = 'completed' and p.start_time < now() - make_interval(days => v_days))
                and not exists (select 1 from public.appointments p where p.customer_id = x.id and p.status not in ('cancelled','no_show') and p.start_time > now() - make_interval(days => v_days))
              limit greatest(1, least(coalesce(p_limit, 50), 200)) loop
      if public.zella_queue_customer_message(a.business_id, c.id, 'service_due',
           jsonb_build_object('service', coalesce(nullif(a.trigger_config ->> 'service', ''), 'visit')), interval '0', null, make_interval(days => v_days)) is not null then
        n := n + 1;
      end if;
    end loop;
  end loop;
  for c in select x.id, x.business_id from public.customers x
            where x.lead_stage = 'new' and coalesce(x.last_contacted_at, x.created_at) < now() - interval '3 days'
              and coalesce(x.last_contacted_at, x.created_at) > now() - interval '14 days'
              and not coalesce(x.do_not_contact, false)
              and exists (select 1 from public.followup_tasks f where f.customer_id = x.id and f.status = 'done' and f.created_at > now() - interval '14 days')
            limit greatest(1, least(coalesce(p_limit, 50), 200)) loop
    if public.zella_queue_customer_message(c.business_id, c.id, 'no_response_follow_up', '{}'::jsonb, interval '0', null, interval '14 days') is not null then
      n := n + 1;
    end if;
  end loop;
  -- lead sequence: day 1 for a lead nobody has reached, day 7 as the last note
  for c in select x.id, x.business_id, case when x.created_at < now() - interval '7 days' then 'lead_final_follow_up' else 'lead_follow_up' end as kind
             from public.customers x
            where x.lead_stage in ('new', 'contacted') and not coalesce(x.do_not_contact, false)
              and x.created_at < now() - interval '1 day' and x.created_at > now() - interval '14 days'
              and coalesce(x.last_contacted_at, x.created_at) < now() - interval '1 day'
              and coalesce(lower(x.source), '') not in ('import', 'csv', 'migration')
              and not exists (select 1 from public.appointments p where p.customer_id = x.id and p.status <> 'cancelled')
            limit greatest(1, least(coalesce(p_limit, 50), 200)) loop
    if public.zella_queue_customer_message(c.business_id, c.id, c.kind, '{}'::jsonb, interval '0', null, interval '14 days') is not null then
      n := n + 1;
    end if;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_queue_lead_reactivation(p_limit integer DEFAULT 25)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c record; v_auto record; n integer := 0; v_tz text; v_days integer;
begin
  for v_auto in select * from public.automations a where a.trigger_type = 'lead_reactivation' and a.status = 'active' loop
    v_days := coalesce(coalesce((v_auto.trigger_config ->> 'days_inactive')::integer, (v_auto.trigger_config ->> 'inactive_days')::integer), 60);
    select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b
     where b.id = v_auto.business_id and b.suspended_at is null and b.cancelled_at is null;
    if v_tz is null then continue; end if;
    for c in select x.* from public.customers x
              where x.business_id = v_auto.business_id and not coalesce(x.do_not_contact, false) and (public.zella_digits(x.phone) is not null or (v_auto.trigger_config ->> 'channel' = 'email' and public.zella_valid_email(x.email)))
                and ((x.lead_stage = 'lost' and x.reactivate_after is not null and x.reactivate_after <= now())
                  or (x.lead_stage in ('new','contacted','qualified','unqualified') and coalesce(x.last_contacted_at, x.created_at) < now() - make_interval(days => v_days)))
                and not exists (select 1 from public.followup_tasks f where f.customer_id = x.id and f.kind = 'lead_reactivation' and f.created_at > now() - interval '90 days')
              limit greatest(1, least(coalesce(p_limit, 25), 100)) loop
      insert into public.followup_tasks (business_id, customer_id, kind, channel, due_at, max_attempts)
      values (c.business_id, c.id, 'lead_reactivation', case v_auto.trigger_config ->> 'channel' when 'call' then 'call' when 'email' then 'email' else 'sms' end, public.zella_next_call_time(now(), v_tz), 1);
      update public.customers set reactivate_after = null where id = c.id and reactivate_after is not null;
      n := n + 1;
    end loop;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_queue_no_show_followup()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_auto record;
  v_tz text;
  v_minutes integer;
  v_channel text;
  v_cust record;
begin
  if new.status is not distinct from old.status then
    return new;
  end if;

  -- No longer a no-show (rescheduled, marked done...): drop any waiting call.
  if old.status = 'no_show' and new.status <> 'no_show' then
    update public.followup_tasks
       set status = 'cancelled', outcome = coalesce(outcome, 'appointment_changed'),
           completed_at = now(), updated_at = now()
     where appointment_id = new.id and kind = 'no_show_follow_up' and status = 'pending';
    return new;
  end if;

  if new.status <> 'no_show' or new.customer_id is null then
    return new;
  end if;

  -- Only for businesses with this automation live ("active").
  select a.* into v_auto
    from public.automations a
   where a.business_id = new.business_id
     and a.trigger_type = 'no_show_follow_up'
     and a.status = 'active'
   limit 1;
  if not found then
    return new;
  end if;

  select c.phone, c.do_not_contact into v_cust from public.customers c where c.id = new.customer_id;
  if not found or coalesce(v_cust.do_not_contact, false) or nullif(trim(coalesce(v_cust.phone, '')), '') is null then
    return new;
  end if;

  select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = new.business_id;
  v_minutes := coalesce((v_auto.trigger_config ->> 'minutes_after')::integer, 15);
  v_channel := case when v_auto.trigger_config ->> 'channel' = 'sms' then 'sms' else 'call' end;

  insert into public.followup_tasks (business_id, customer_id, appointment_id, kind, channel, due_at, max_attempts)
  values (
    new.business_id, new.customer_id, new.id, 'no_show_follow_up', v_channel,
    public.zella_next_call_time(
      now() + make_interval(mins => v_minutes), v_tz,
      coalesce((v_auto.trigger_config ->> 'window_start')::time, '09:00'),
      coalesce((v_auto.trigger_config ->> 'window_end')::time, '19:00')
    ),
    coalesce((v_auto.trigger_config ->> 'max_attempts')::integer, 2)
  )
  on conflict do nothing;

  return new;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_queue_quote_followups()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare q record; v_tz text; n integer := 0; c record; v_auto record;
begin
  for q in select * from public.quotes where status = 'issued' and next_follow_up_at is not null and next_follow_up_at <= now() for update skip locked loop
    if q.expires_at is not null and q.expires_at < now() then
      update public.quotes set status = 'expired', closed_at = now(), next_follow_up_at = null where id = q.id; continue;
    end if;
    select * into c from public.customers where id = q.customer_id;
    select a.* into v_auto from public.automations a where a.business_id = q.business_id and a.trigger_type = 'quote_follow_up' and a.status = 'active' limit 1;
    if c.id is null or coalesce(c.do_not_contact, false) or c.lead_stage in ('won', 'lost') or v_auto.id is null then
      update public.quotes set next_follow_up_at = null where id = q.id; continue;
    end if;
    if q.follow_ups_sent >= q.max_follow_ups then
      update public.quotes set next_follow_up_at = null where id = q.id;
      perform public.zella_create_task(q.business_id, q.customer_id, 'quote_review', 'Quote still open after ' || q.follow_ups_sent || ' follow-ups: ' || q.title, 'Decide whether to close it.', 'normal', now(), c.assigned_to, 'automation', q.id);
      continue;
    end if;
    select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = q.business_id;
    insert into public.followup_tasks (business_id, customer_id, kind, channel, due_at, max_attempts, entity_ref)
    values (q.business_id, q.customer_id, 'quote_follow_up', case when v_auto.trigger_config ->> 'channel' = 'call' then 'call' else 'sms' end, public.zella_next_call_time(now(), v_tz), 1, q.id);
    update public.quotes set follow_ups_sent = follow_ups_sent + 1, next_follow_up_at = now() + make_interval(days => q.follow_up_every_days) where id = q.id;
    n := n + 1;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_rate_limit(p_key text, p_max integer, p_window_seconds integer DEFAULT 60)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare w timestamptz; h integer;
begin
  w := to_timestamp(floor(extract(epoch from now()) / greatest(p_window_seconds, 1)) * greatest(p_window_seconds, 1));
  insert into public.rate_limits as r (key, window_start, hits) values (left(p_key, 200), w, 1)
    on conflict (key, window_start) do update set hits = r.hits + 1 returning hits into h;
  if random() < 0.01 then delete from public.rate_limits where window_start < now() - interval '1 day'; end if;
  return h <= p_max;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_reactivate_business(p_business_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_business businesses%rowtype;
  v_state jsonb;
begin
  select * into v_business from businesses where id = p_business_id for update;
  if not found then raise exception 'BUSINESS_NOT_FOUND'; end if;
  if v_business.cancelled_at is not null then raise exception 'BUSINESS_CANCELLED'; end if;
  if v_business.suspended_at is null then raise exception 'NOT_SUSPENDED'; end if;

  v_state := coalesce(v_business.setup_data->'suspended_state', '{}'::jsonb);

  update ai_agents set status = 'active', updated_at = now()
  where business_id = p_business_id and status = 'paused'
    and id::text in (select jsonb_array_elements_text(coalesce(v_state->'agents', '[]')));

  update automations set status = 'active', updated_at = now()
  where business_id = p_business_id and status = 'paused'
    and id::text in (select jsonb_array_elements_text(coalesce(v_state->'automations', '[]')));

  update businesses
  set suspended_at = null,
      suspension_reason = null,
      is_active = coalesce((v_state->>'was_active')::boolean, true),
      setup_data = setup_data - 'suspended_state',
      updated_at = now()
  where id = p_business_id;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_ready_knowledge(p_business_id uuid)
 RETURNS TABLE(id uuid, kind text, title text, question text, answer text, version integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select k.id, k.kind, k.title, k.question, k.answer, k.version
    from public.knowledge_items k
   where k.business_id = p_business_id and k.status = 'ready'
     and (auth.uid() is null or exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active'))
   order by k.kind, k.title;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_reassign_callback(p_callback_id uuid, p_to_user uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare cb record;
begin
  select * into cb from public.callbacks where id = p_callback_id;
  if cb.id is null then return 'not_found'; end if;
  if not public.zella_has_role(cb.business_id, array['owner','admin','manager','staff']) then raise exception 'NOT_ALLOWED'; end if;
  if p_to_user is not null and not exists (select 1 from public.business_members m where m.business_id = cb.business_id and m.user_id = p_to_user and m.status = 'active') then raise exception 'TARGET_NOT_ACTIVE'; end if;
  update public.callbacks set assigned_to = p_to_user, updated_at = now() where id = p_callback_id and status not in ('completed','cancelled');
  if p_to_user is not null then
    perform public.zella_notify(cb.business_id, 'callback', 'A callback was assigned to you', coalesce(cb.summary, 'Please call them back.'), 'info', 'callbacks', cb.id, p_to_user);
  end if;
  return 'reassigned';
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_rebalance_assignments()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare w record; v_user uuid; v_moved integer := 0;
begin
  for w in
    select 'lead' kind, c.id, c.business_id, c.assigned_to from public.customers c
      join public.business_members m on m.business_id = c.business_id and m.user_id = c.assigned_to
     where c.lead_stage in ('new', 'contacted', 'qualified', 'quote_sent')
       and (m.status <> 'active' or not m.accepts_work or (m.away_until is not null and m.away_until > now()))
    union all
    select 'callback', b.id, b.business_id, b.assigned_to from public.callbacks b
      join public.business_members m on m.business_id = b.business_id and m.user_id = b.assigned_to
     where b.status not in ('completed', 'cancelled')
       and (m.status <> 'active' or not m.accepts_work or (m.away_until is not null and m.away_until > now()))
    limit 200
  loop
    v_user := public.zella_pick_assignee(w.business_id, w.assigned_to);
    if v_user is null then continue; end if;
    if w.kind = 'lead' then update public.customers set assigned_to = v_user, updated_at = now() where id = w.id;
    else update public.callbacks set assigned_to = v_user, updated_at = now() where id = w.id; end if;
    perform public.zella_mark_assigned(w.business_id, v_user);
    perform public.zella_notify(w.business_id, 'work_reassigned', 'Work moved to you', case w.kind when 'lead' then 'A lead was reassigned to you because its owner is away.' else 'A callback was reassigned to you because its owner is away.' end, 'info', case w.kind when 'lead' then 'customers' else 'callbacks' end, w.id, v_user);
    v_moved := v_moved + 1;
  end loop;

  for w in
    select 'lead' kind, c.id, c.business_id from public.customers c join public.assignment_rules a on a.business_id = c.business_id and a.mode <> 'off'
     where c.assigned_to is null and c.lead_stage in ('new', 'contacted', 'qualified', 'quote_sent')
    union all
    select 'callback', b.id, b.business_id from public.callbacks b join public.assignment_rules a on a.business_id = b.business_id and a.mode <> 'off'
     where b.assigned_to is null and b.status not in ('completed', 'cancelled')
    limit 200
  loop
    v_user := public.zella_pick_assignee(w.business_id);
    if v_user is null then continue; end if;
    if w.kind = 'lead' then update public.customers set assigned_to = v_user, updated_at = now() where id = w.id;
    else update public.callbacks set assigned_to = v_user, updated_at = now() where id = w.id; end if;
    perform public.zella_mark_assigned(w.business_id, v_user);
    v_moved := v_moved + 1;
  end loop;
  return v_moved;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_rebook_line(p_appointment_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_base text := regexp_replace(coalesce(nullif(trim(public.zella_setting('app_base_url', '""'::jsonb) #>> '{}'), ''), ''), '/+$', '');
  v_token text; a record;
begin
  if v_base = '' or v_base !~ '^https://[^\s]+$' then return ''; end if;
  select id, business_id, status into a from public.appointments where id = p_appointment_id;
  if a.id is null or a.status <> 'no_show' then return ''; end if;
  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into public.appointment_reschedule_links (appointment_id, business_id, token_hash, purpose, expires_at)
  values (a.id, a.business_id, encode(sha256(convert_to(v_token, 'utf8')), 'hex'), 'rebook', now() + interval '14 days');
  return ' Book a new time: ' || v_base || '/r/' || v_token;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_receive_inbound_email(p_key text, p_message jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_secret text; m jsonb := p_message;
  v_mid text; v_from text; v_to text; v_biz uuid; v_name text; v_subject text; v_body text; v_irt text;
  v_cust uuid; v_cname text; v_conv uuid; v_prev uuid; v_cat text; v_auto boolean; v_emid uuid; v_known boolean;
  v_prio text; v_title text;
begin
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'zella_resend_webhook_key' limit 1;
  if v_secret is null or v_secret = '' then return jsonb_build_object('result', 'not_configured'); end if;
  if p_key is null or encode(sha256(convert_to(p_key, 'utf8')), 'hex') <> encode(sha256(convert_to(v_secret, 'utf8')), 'hex') then return jsonb_build_object('result', 'unauthorized'); end if;
  if m is null or jsonb_typeof(m) <> 'object' then return jsonb_build_object('result', 'ignored'); end if;

  v_mid := nullif(left(trim(coalesce(m ->> 'message_id', '')), 300), '');
  v_from := lower(substring(coalesce(m ->> 'from', '') from '([A-Za-z0-9._%+''-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})'));
  v_irt := nullif(left(trim(coalesce(m ->> 'in_reply_to', '')), 300), '');
  v_subject := left(regexp_replace(coalesce(m ->> 'subject', ''), '[\r\n]+', ' ', 'g'), 300);
  v_body := left(coalesce(m ->> 'text', ''), 20000);
  v_auto := coalesce((m ->> 'auto_submitted')::boolean, false);
  if v_mid is null or v_from is null then return jsonb_build_object('result', 'ignored'); end if;

  select b.id, b.name, lower(a) into v_biz, v_name, v_to
    from jsonb_array_elements_text(case when jsonb_typeof(m -> 'to') = 'array' then m -> 'to' when jsonb_typeof(m -> 'to') = 'string' then jsonb_build_array(m ->> 'to') else '[]'::jsonb end) a
    join public.businesses b on b.inbound_email_token = substring(lower(a) from '(?:^|[<[:space:]])([a-z0-9]{12}|[a-f0-9]{32})@')
   where b.suspended_at is null and b.cancelled_at is null limit 1;
  if v_biz is null then return jsonb_build_object('result', 'no_business'); end if;

  if exists (select 1 from public.email_messages e where e.business_id = v_biz and e.direction = 'inbound' and e.external_message_id = v_mid) then
    return jsonb_build_object('result', 'duplicate');
  end if;
  if not public.zella_rate_limit('inbound_email:' || v_biz::text, 300, 3600) then return jsonb_build_object('result', 'rate_limited'); end if;

  select m2.customer_id into v_cust from public.zella_match_customer(v_biz, null, v_from) m2 where m2.certainty = 'exact' limit 1;
  v_known := v_cust is not null;
  if v_known then select trim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')) into v_cname from public.customers where id = v_cust; end if;
  v_cname := coalesce(nullif(v_cname, ''), v_from);

  if v_irt is not null then
    select e.conversation_id into v_prev from public.email_messages e where e.business_id = v_biz and e.external_message_id = v_irt and e.conversation_id is not null limit 1;
  end if;
  v_conv := v_prev;
  if v_conv is null and v_cust is not null then
    select c.id into v_conv from public.conversations c where c.business_id = v_biz and c.customer_id = v_cust and c.channel = 'email' and c.status <> 'closed' order by c.last_message_at desc nulls last limit 1;
  end if;
  if v_conv is null then
    insert into public.conversations (business_id, customer_id, channel, status, subject, ai_handled)
    values (v_biz, v_cust, 'email', 'open', nullif(v_subject, ''), false) returning id into v_conv;
  end if;

  v_cat := public.zella_classify_email(v_subject, v_body, v_auto);

  insert into public.email_messages (business_id, customer_id, conversation_id, direction, status, from_email, to_email, subject, body_text, external_message_id, sent_at, metadata)
  values (v_biz, v_cust, v_conv, 'inbound', 'received', v_from, v_to, nullif(v_subject, ''), v_body, v_mid, now(),
          jsonb_build_object('category', v_cat, 'known_customer', v_known)) returning id into v_emid;
  insert into public.conversation_messages (conversation_id, sender_type, message_type, content, external_message_id, metadata)
  values (v_conv, 'customer', 'text', left(v_body, 5000), v_mid, jsonb_build_object('category', v_cat, 'subject', v_subject, 'email_message_id', v_emid));

  if v_cat = 'auto_reply' then
    return jsonb_build_object('result', 'saved', 'category', v_cat);
  end if;
  if v_cat = 'unsubscribe' then
    perform public.zella_record_consent(v_biz, 'email', 'opted_out', 'email_link', v_cust, null, v_from, 'marketing', 'reply');
    if v_cust is not null then
      update public.customers set do_not_email = true, email_suppressed_at = now(), email_suppressed_reason = 'unsubscribed', updated_at = now() where id = v_cust and (not coalesce(do_not_email, false) or email_suppressed_reason is null);
    end if;
    perform public.zella_notify_owners(v_biz, 'email_unsubscribed', v_cname || ' unsubscribed', 'They will not get marketing emails any more.', 'info', 'inbox');
    return jsonb_build_object('result', 'saved', 'category', v_cat, 'unsubscribed', true);
  end if;

  v_prio := case when v_cat in ('complaint', 'cancel') then 'high' else 'normal' end;
  update public.conversations set status = 'open', priority = case when v_prio = 'high' then 'high' else priority end, updated_at = now() where id = v_conv;
  v_title := case v_cat
    when 'complaint' then 'Complaint by email from ' || v_cname
    when 'cancel' then v_cname || ' wants to cancel'
    when 'reschedule' then v_cname || ' wants a different time'
    when 'confirm' then v_cname || ' confirmed by email'
    else 'New email from ' || v_cname end;
  perform public.zella_notify_owners(v_biz, 'customer_email', v_title,
    left(coalesce(nullif(v_subject, ''), '(no subject)') || ': ' || regexp_replace(v_body, '\s+', ' ', 'g'), 300) || case when v_known then '' else ' (sender is not in your customer list)' end,
    case when v_cat = 'complaint' then 'urgent' else 'info' end, 'inbox');
  return jsonb_build_object('result', 'saved', 'category', v_cat, 'known_customer', v_known, 'conversation_id', v_conv);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_receive_inbound_email_signed(p_key text, p_message jsonb, p_sig jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
begin
  if public.zella_resend_signature_ok(p_sig ->> 'id', p_sig ->> 'timestamp', p_sig ->> 'signature', p_sig ->> 'raw') = 'bad' then
    return jsonb_build_object('result', 'unauthorized');
  end if;
  return public.zella_receive_inbound_email(p_key, p_message);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_reconcile()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; v_found integer := 0; v_ids uuid[]; v_k text;
begin
  v_ids := '{}';
  for r in select a.business_id, count(*) n from public.appointments a
            where a.status in ('scheduled', 'confirmed') and a.start_time > now() and a.created_at < now() - interval '1 hour' and a.external_event_id is null
              and exists (select 1 from public.calendar_connections cc where cc.business_id = a.business_id and cc.status = 'active')
              and not exists (select 1 from public.calendar_sync_queue q where q.appointment_id = a.id and q.status in ('pending', 'in_progress'))
              and not exists (select 1 from public.calendar_sync_queue q where q.appointment_id = a.id and q.status = 'failed' and q.created_at > now() - interval '1 day')
            group by a.business_id loop
    insert into public.calendar_sync_queue (business_id, appointment_id, action, status, due_at)
    select a.business_id, a.id, 'upsert', 'pending', now() from public.appointments a
     where a.business_id = r.business_id and a.status in ('scheduled', 'confirmed') and a.start_time > now() and a.created_at < now() - interval '1 hour' and a.external_event_id is null
       and not exists (select 1 from public.calendar_sync_queue q where q.appointment_id = a.id and q.status in ('pending', 'in_progress'))
       and not exists (select 1 from public.calendar_sync_queue q where q.appointment_id = a.id and q.status = 'failed' and q.created_at > now() - interval '1 day');
    perform public.zella_platform_alert('reconcile_calendar', 'Appointments were missing from the calendar', r.n || ' appointments were sent to the calendar again.', 'info', r.business_id, 'daily');
    v_ids := v_ids || r.business_id; v_found := v_found + 1;
  end loop;
  update public.platform_alerts set status = 'resolved', resolved_at = now(), resolution_note = 'Nothing missing now' where kind = 'reconcile_calendar' and status <> 'resolved' and not (business_id = any (v_ids));

  for v_k in select unnest(array['sms', 'email']) loop
    v_ids := '{}';
    for r in execute format('select business_id, count(*) n from public.%I where direction = ''outbound'' and status = ''queued'' and created_at < now() - interval ''30 minutes'' group by business_id', case v_k when 'sms' then 'sms_messages' else 'email_messages' end) loop
      perform public.zella_platform_alert('reconcile_' || v_k || '_stuck', r.n || ' ' || v_k || ' messages are stuck in the queue', 'Queued for over 30 minutes. Check the ' || v_k || ' sending workflow and the live switch.', 'warning', r.business_id, 'daily');
      v_ids := v_ids || r.business_id; v_found := v_found + 1;
    end loop;
    update public.platform_alerts set status = 'resolved', resolved_at = now(), resolution_note = 'Queue is clear' where kind = 'reconcile_' || v_k || '_stuck' and status <> 'resolved' and not (business_id = any (v_ids));
  end loop;

  v_ids := '{}';
  for r in select business_id, count(*) n from public.knowledge_items where status = 'processing' and updated_at < now() - interval '1 hour' group by business_id loop
    perform public.zella_platform_alert('reconcile_knowledge_stuck', r.n || ' knowledge items are not getting published', 'Processing for over an hour. Check the Knowledge workflow.', 'warning', r.business_id, 'daily');
    v_ids := v_ids || r.business_id; v_found := v_found + 1;
  end loop;
  update public.platform_alerts set status = 'resolved', resolved_at = now(), resolution_note = 'Nothing waiting' where kind = 'reconcile_knowledge_stuck' and status <> 'resolved' and not (business_id = any (v_ids));

  for r in select a.business_id, count(*) n from public.appointments a join public.businesses b on b.id = a.business_id and b.suspended_at is null and b.cancelled_at is null
            where a.status in ('scheduled', 'confirmed') and coalesce(a.end_time, a.start_time) < now() - interval '1 day' group by a.business_id loop
    continue when exists (select 1 from public.staff_notifications s where s.business_id = r.business_id and s.kind = 'appointments_need_outcome' and s.created_at > now() - interval '3 days');
    perform public.zella_notify_owners(r.business_id, 'appointments_need_outcome', r.n || ' past appointment' || case when r.n = 1 then ' needs' else 's need' end || ' an outcome',
      'Mark them completed or no-show so reports and follow-ups are right.', 'info', 'appointments');
    v_found := v_found + 1;
  end loop;
  return v_found;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_reconcile_call(p_provider_call_id text, p_status_code integer, p_call jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c public.calls; j jsonb := case when jsonb_typeof(p_call) = 'object' then p_call else '{}'::jsonb end;
  v_start timestamptz; v_end timestamptz; v_secs integer; v_res text;
  ts text;
begin
  select * into c from public.calls where external_call_id = p_provider_call_id;
  if c.id is null then return 'unknown_call'; end if;
  if c.outcome_at is not null then return 'already_final'; end if;
  if p_status_code = 404 then
    update public.calls set metadata = metadata || jsonb_build_object('reconcile_status',
             case when coalesce((metadata ->> 'reconcile_attempts')::integer, 0) >= 6 then 'not_found' else 'retry' end) where id = c.id;
    return 'not_found';
  end if;
  if p_status_code is null or p_status_code < 200 or p_status_code >= 300 then
    update public.calls set metadata = metadata || jsonb_build_object('reconcile_status', 'provider_error', 'reconcile_error', p_status_code) where id = c.id;
    return 'provider_error';
  end if;
  if j ->> 'id' is distinct from p_provider_call_id then return 'mismatch'; end if;     -- never apply another call's data
  if j ->> 'status' is distinct from 'ended' then
    update public.calls set metadata = metadata || jsonb_build_object('reconcile_status', 'not_ended', 'provider_status_seen', left(j ->> 'status', 30)) where id = c.id;
    return 'not_ended';
  end if;
  begin v_start := nullif(j ->> 'startedAt', '')::timestamptz; exception when others then v_start := null; end;
  begin v_end := nullif(j ->> 'endedAt', '')::timestamptz; exception when others then v_end := null; end;
  v_secs := case when v_start is not null and v_end is not null and v_end >= v_start then extract(epoch from (v_end - v_start))::integer end;
  v_res := public.zella_record_inbound_call(p_provider_call_id,
    j #>> '{phoneNumber,number}', left(j ->> 'phoneNumberId', 100), j #>> '{customer,number}', v_start, v_end, v_secs,
    left(coalesce(j ->> 'endedReason', ''), 80),
    left(coalesce(j #>> '{analysis,summary}', j ->> 'summary', ''), 1500),
    case when coalesce(j #>> '{artifact,recordingUrl}', j ->> 'recordingUrl', '') ~ '^https://' then left(coalesce(j #>> '{artifact,recordingUrl}', j ->> 'recordingUrl'), 1000) end,
    left(coalesce(j #>> '{artifact,transcript}', j ->> 'transcript', ''), 60000),
    coalesce((j #>> '{analysis,structuredData,callback_requested}')::boolean, false));
  update public.calls set metadata = metadata || jsonb_build_object('reconcile_status', 'reconciled', 'reconciled_at', now()) where id = c.id;
  return v_res;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_reconcile_call_usage(p_limit integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; v jsonb; n_new integer := 0; n_adj integer := 0; n_retry integer := 0; n_esc integer := 0; n_missing integer := 0; n_mismatch integer := 0;
        v_lim integer := greatest(1, least(coalesce(p_limit, 200), 1000));
begin
  -- a. ended AI calls with no usage yet, and recorded calls whose provider duration changed since
  for r in select c.id from public.calls c
            where c.ai_handled and c.ended_at is not null and c.ended_at < now() - interval '10 minutes' and coalesce(c.metadata ->> 'awaiting_report', 'false') <> 'true'
              and (not exists (select 1 from public.usage_records u where u.usage_type = 'ai_call' and u.call_id = c.id and u.entry_kind = 'usage')
                   or c.duration_seconds is distinct from (select sum(u.duration_seconds)::int from public.usage_records u where u.usage_type = 'ai_call' and u.call_id = c.id))
              and not exists (select 1 from public.usage_processing_issues i where i.call_id = c.id and i.status = 'escalated')
            order by c.ended_at limit v_lim loop
    begin
      v := public.zella_process_call_usage(r.id, 'reconcile');
      if v ->> 'result' = 'recorded' then n_new := n_new + 1; elsif v ->> 'result' = 'adjusted' then n_adj := n_adj + 1;
      elsif v ->> 'result' = 'missing_duration' then n_missing := n_missing + 1; end if;
    exception when others then
      perform public.zella_usage_open_issue((select business_id from public.calls where id = r.id), r.id, 'processing_failed', sqlerrm);
    end;
  end loop;
  -- b. failed processing: retried with a growing wait, at most 5 times, then escalated once
  for r in select * from public.usage_processing_issues i where i.status = 'open' and i.kind = 'processing_failed' and i.next_attempt_at <= now()
            order by i.next_attempt_at limit v_lim for update skip locked loop
    if r.attempts >= 5 then
      update public.usage_processing_issues set status = 'escalated', escalated_at = now(), updated_at = now() where id = r.id;
      perform public.zella_platform_alert('usage_processing_failed', 'Calling usage could not be recorded', 'A call''s usage failed 5 times: ' || left(coalesce(r.last_error, ''), 200),
                                          'warning', r.business_id, 'usage-failed:' || to_char(now(), 'YYYY-MM-DD'));
      n_esc := n_esc + 1; continue;
    end if;
    update public.usage_processing_issues set attempts = attempts + 1, next_attempt_at = now() + make_interval(mins => 15 * power(2, r.attempts)::int), updated_at = now() where id = r.id;
    begin
      v := public.zella_process_call_usage(r.call_id, 'retry');
      n_retry := n_retry + 1;
    exception when others then
      update public.usage_processing_issues set last_error = left(sqlerrm, 300) where id = r.id;
    end;
  end loop;
  -- c. calls the provider never sent a duration for: listed (not estimated), escalated once after a day
  for r in select i.* from public.usage_processing_issues i where i.status = 'open' and i.kind in ('missing_duration', 'invalid_duration') and i.created_at < now() - interval '24 hours' loop
    update public.usage_processing_issues set status = 'escalated', escalated_at = now(), updated_at = now() where id = r.id;
    perform public.zella_platform_alert('usage_missing_duration', 'Calls without a provider duration', 'At least one call has had no usable duration for a day and is not counted.',
                                        'warning', r.business_id, 'usage-duration:' || to_char(now(), 'YYYY-MM-DD'));
    n_esc := n_esc + 1;
  end loop;
  -- d. ledger vs calls over the last 35 days, per business, for calls that have usage recorded (calls with none are
  --    handled by a.; calls with an issue are tracked one by one): one open issue per business until it matches again
  for r in select c.business_id, sum(c.duration_seconds) as call_secs,
                  sum((select coalesce(sum(u.duration_seconds), 0) from public.usage_records u where u.usage_type = 'ai_call' and u.status = 'recorded' and u.call_id = c.id)) as ledger_secs
             from public.calls c
            where c.ai_handled and c.ended_at >= now() - interval '35 days' and c.ended_at < now() - interval '1 hour' and c.duration_seconds is not null
              and exists (select 1 from public.usage_records u where u.usage_type = 'ai_call' and u.call_id = c.id and u.entry_kind = 'usage')
            group by c.business_id loop
    if r.call_secs is distinct from r.ledger_secs then
      perform public.zella_usage_open_issue(r.business_id, null, 'summary_mismatch', 'Calls total ' || r.call_secs || ' s, ledger ' || r.ledger_secs || ' s (last 35 days).',
                                            jsonb_build_object('call_seconds', r.call_secs, 'ledger_seconds', r.ledger_secs));
      n_mismatch := n_mismatch + 1;
    else
      update public.usage_processing_issues set status = 'resolved', resolved_at = now(), resolution = 'matches', updated_at = now()
       where business_id = r.business_id and call_id is null and kind = 'summary_mismatch' and status <> 'resolved';
    end if;
  end loop;
  return jsonb_build_object('recorded', n_new, 'adjusted', n_adj, 'retried', n_retry, 'escalated', n_esc, 'missing_duration', n_missing, 'mismatches', n_mismatch);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_record_activation_test(p_business_id uuid, p_ok boolean, p_detail text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  insert into public.activation_tests (business_id, ok, detail) values (p_business_id, p_ok, left(p_detail, 300));
$function$
;
CREATE OR REPLACE FUNCTION public.zella_record_call_result(p_source text, p_id uuid, p_outcome text, p_provider_call_id text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_status text;
begin
  if p_source = 'callback' then
    select status into v_status from public.callbacks where id = p_id for update;
    if v_status is null then return 'not_found'; end if;
    if v_status <> 'in_progress' then return 'ignored'; end if;
    perform public.zella_record_callback_attempt(p_id, p_outcome, left(p_provider_call_id, 200), null, left(p_notes, 300));
    return 'recorded';
  elsif p_source = 'task' then
    select status into v_status from public.followup_tasks where id = p_id for update;
    if v_status is null then return 'not_found'; end if;
    if v_status <> 'in_progress' then return 'ignored'; end if;
    perform public.zella_complete_followup_task(p_id, p_outcome, left(p_notes, 300), left(p_provider_call_id, 200));
    return 'recorded';
  end if;
  raise exception 'BAD_SOURCE';
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_record_call_status(p_provider_call_id text, p_status text, p_called_number text, p_vapi_phone_number_id text, p_from_number text, p_direction text, p_event_at timestamp with time zone, p_ended_reason text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c public.calls; v_biz uuid;
  v_rank integer := case p_status when 'ringing' then 2 when 'in-progress' then 3 when 'forwarding' then 4 when 'ended' then 5 end;
  v_cur integer;
begin
  if nullif(p_provider_call_id, '') is null or length(p_provider_call_id) > 200 then return 'ignored'; end if;
  if v_rank is null then return 'ignored_status'; end if;                 -- scheduled / queued: nothing to record yet
  if coalesce(p_direction, 'inbound') <> 'inbound' then return 'ignored_outbound'; end if;   -- outbound has its own record
  if p_event_at is not null and (p_event_at > now() + interval '5 minutes' or p_event_at < now() - interval '30 days') then p_event_at := null; end if;

  select * into c from public.calls where external_call_id = p_provider_call_id for update;
  if not found then
    v_biz := public.zella_business_for_number(p_called_number, p_vapi_phone_number_id, null);
    if v_biz is null then return 'unknown_business'; end if;
    insert into public.calls (business_id, direction, status, from_number, to_number, external_call_id, started_at, ai_handled, metadata)
    values (v_biz, 'inbound', 'ringing', nullif(left(coalesce(p_from_number, ''), 30), ''), nullif(left(coalesce(p_called_number, ''), 30), ''),
            p_provider_call_id, p_event_at, true, jsonb_build_object('created_from', 'status_update'))
    on conflict (external_call_id) where external_call_id is not null do nothing;
    select * into c from public.calls where external_call_id = p_provider_call_id for update;
  end if;

  v_cur := coalesce((c.metadata ->> 'provider_status_rank')::integer, 0);
  if v_rank <= v_cur then return 'duplicate'; end if;
  if c.outcome_at is not null and c.ended_at is not null then return 'already_final'; end if;

  update public.calls set
      status = case when p_status = 'ringing' and status = 'initiated' then 'ringing'
                    when p_status in ('in-progress', 'forwarding') and status in ('initiated', 'ringing') then 'answered'
                    else status end,
      started_at = coalesce(started_at, p_event_at),
      answered_at = case when p_status in ('in-progress', 'forwarding') then coalesce(answered_at, p_event_at) else answered_at end,
      transfer_status = case when p_status = 'forwarding' and transfer_status is null then 'attempted' else transfer_status end,
      ended_at = case when p_status = 'ended' then coalesce(ended_at, p_event_at) else ended_at end,
      from_number = coalesce(from_number, nullif(left(coalesce(p_from_number, ''), 30), '')),
      metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('provider_status', p_status, 'provider_status_rank', v_rank,
                   'provider_status_at', p_event_at, 'awaiting_report', p_status = 'ended')
                 || case when p_status = 'ended' and nullif(p_ended_reason, '') is not null then jsonb_build_object('ended_reason', left(p_ended_reason, 80)) else '{}'::jsonb end,
      updated_at = now()
   where id = c.id;
  return 'recorded';
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_record_callback_attempt(p_callback_id uuid, p_outcome text, p_provider_ref text DEFAULT NULL::text, p_error text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_cb record; v_tz text; v_next timestamptz; v_status text; v_by text; v_uid uuid := auth.uid();
begin
  select * into v_cb from public.callbacks where id = p_callback_id for update;
  if not found then raise exception 'CALLBACK_NOT_FOUND'; end if;
  if v_uid is not null and not public.zella_is_member(v_cb.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_outcome not in ('connected','no_answer','busy','voicemail','invalid_number','failed_connection','declined') then raise exception 'BAD_OUTCOME'; end if;
  if v_cb.status in ('completed','cancelled') then raise exception 'ALREADY_CLOSED'; end if;
  v_by := case when v_uid is null then 'system' else v_uid::text end;
  -- staff calling by hand count as an attempt too
  if v_cb.status <> 'in_progress' then v_cb.attempts := v_cb.attempts + 1; end if;

  select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = v_cb.business_id;
  if p_outcome in ('no_answer','busy','voicemail','failed_connection') and v_cb.attempts < v_cb.max_attempts then
    v_status := 'retry_scheduled';
    v_next := public.zella_next_call_time(now() + make_interval(mins => greatest(5, v_cb.retry_delay_minutes)), v_tz);
  elsif p_outcome in ('no_answer','busy','voicemail','failed_connection','invalid_number') then
    v_status := 'needs_review';       -- attempt limit reached (or bad number): stop automatic calling, hand to staff
  elsif p_outcome = 'connected' then v_status := 'contacted';
  else v_status := 'completed';       -- declined
  end if;

  insert into public.callback_attempts (callback_id, business_id, attempt_no, outcome, provider_ref, error, notes, next_attempt_at, initiated_by)
  values (p_callback_id, v_cb.business_id, v_cb.attempts, p_outcome, p_provider_ref, left(p_error, 300), p_notes, v_next, v_by);

  update public.callbacks set status = v_status, attempts = v_cb.attempts, due_at = coalesce(v_next, due_at), locked_at = null,
      outcome = case when v_status in ('contacted','completed','needs_review') then p_outcome else outcome end,
      completed_at = case when v_status = 'completed' then now() else completed_at end,
      auto_call = case when v_status = 'needs_review' then false else auto_call end,
      note = coalesce(nullif(p_notes, ''), note), updated_at = now()
   where id = p_callback_id;

  if v_status = 'needs_review' and p_outcome <> 'invalid_number' and v_cb.reason in ('missed_call', 'new_lead') then
    -- the business allowed a text as a last resort
    if exists (select 1 from public.automations a where a.business_id = v_cb.business_id and a.status = 'active'
                 and a.trigger_type = case when v_cb.reason = 'new_lead' then 'new_lead_callback' else 'missed_call_follow_up' end
                 and coalesce((a.trigger_config ->> 'fallback_sms')::boolean, false))
       and v_cb.customer_id is not null
       and exists (select 1 from public.customers c where c.id = v_cb.customer_id and not coalesce(c.do_not_contact, false) and public.zella_digits(c.phone) is not null) then
      insert into public.followup_tasks (business_id, customer_id, kind, channel, due_at, max_attempts, entity_ref)
      values (v_cb.business_id, v_cb.customer_id, 'callback_sms', 'sms', public.zella_next_call_time(now(), v_tz), 1, v_cb.id) on conflict do nothing;
    end if;
  end if;
  if v_status = 'needs_review' then
    perform public.zella_notify(v_cb.business_id, 'callback_review', 'A callback needs a person',
      case when p_outcome = 'invalid_number' then 'The phone number could not be reached.' else 'Zella tried ' || v_cb.attempts || ' times without reaching them.' end,
      'warning', 'callbacks', p_callback_id);
  end if;
  return v_status;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_record_consent(p_business_id uuid, p_channel text, p_status text, p_source text, p_customer_id uuid DEFAULT NULL::uuid, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_purpose text DEFAULT 'marketing'::text, p_keyword text DEFAULT NULL::text, p_evidence jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid(); v_id uuid; v_cust uuid := p_customer_id; v_digits text := public.zella_digits(p_phone);
begin
  if v_uid is not null and not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if v_uid is not null and p_source = 'inbound_sms_keyword' then raise exception 'NOT_ALLOWED'; end if;
  if not exists (select 1 from public.businesses where id = p_business_id) then raise exception 'INVALID_BUSINESS'; end if;
  if v_cust is not null and not exists (select 1 from public.customers where id = v_cust and business_id = p_business_id) then raise exception 'TENANT_MISMATCH'; end if;
  if v_cust is null and v_digits is not null then
    select id into v_cust from public.customers where business_id = p_business_id and public.zella_digits(phone) = v_digits order by created_at limit 1;
  end if;
  if v_cust is null and p_email is not null then
    select id into v_cust from public.customers where business_id = p_business_id and lower(email) = lower(p_email) order by created_at limit 1;
  end if;
  insert into public.contact_consents (business_id, customer_id, phone_digits, email_lower, channel, purpose, status, source, keyword, evidence, recorded_by)
  values (p_business_id, v_cust, v_digits, nullif(lower(trim(coalesce(p_email, ''))), ''), p_channel, coalesce(p_purpose, 'marketing'), p_status, p_source, upper(left(p_keyword, 20)), coalesce(p_evidence, '{}'::jsonb), v_uid)
  returning id into v_id;
  if v_cust is not null and p_status = 'opted_out' then
    update public.customers set
      do_not_sms = do_not_sms or p_channel = 'sms',
      do_not_call = do_not_call or p_channel = 'call',
      do_not_email = do_not_email or p_channel = 'email',
      updated_at = now()
     where id = v_cust;
  elsif v_cust is not null and p_status = 'opted_in' and p_source in ('inbound_sms_keyword','email_link') then
    update public.customers set
      do_not_sms = do_not_sms and p_channel <> 'sms',
      do_not_email = do_not_email and p_channel <> 'email',
      updated_at = now()
     where id = v_cust;
  end if;
  return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_record_due(p_due timestamp with time zone, p_data jsonb, p_cfg jsonb, p_tz text)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare v text;
begin
  if p_due is not null then return p_due; end if;
  v := nullif(p_data ->> (p_cfg ->> 'due_field'), '');
  if v is null then return null; end if;
  if v ~ '^\d{4}-\d{2}-\d{2}$' then
    return ((v || ' 12:00:00')::timestamp) at time zone coalesce(nullif(p_tz, ''), 'America/New_York');
  end if;
  return v::timestamptz;
exception when others then
  return null;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_record_email_event(p_key text, p_event jsonb, p_event_id text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_secret text; v_type text; v_data jsonb; v_ext text; v_to text; v_msg record; v_bounce text; v_n integer; v_cust record;
begin
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'zella_resend_webhook_key' limit 1;
  if v_secret is null or v_secret = '' then return 'not_configured'; end if;
  if p_key is null or encode(sha256(convert_to(p_key, 'utf8')), 'hex') <> encode(sha256(convert_to(v_secret, 'utf8')), 'hex') then return 'unauthorized'; end if;
  if p_event is null or jsonb_typeof(p_event) <> 'object' or nullif(p_event_id, '') is null then return 'ignored'; end if;

  v_type := left(coalesce(p_event ->> 'type', ''), 60);
  v_data := case when jsonb_typeof(p_event -> 'data') = 'object' then p_event -> 'data' else '{}'::jsonb end;
  v_ext := nullif(left(coalesce(v_data ->> 'email_id', ''), 200), '');
  v_to := lower(nullif(trim(left(coalesce(case when jsonb_typeof(v_data -> 'to') = 'array' then v_data -> 'to' ->> 0 else v_data ->> 'to' end, ''), 300)), ''));
  v_bounce := lower(coalesce(v_data -> 'bounce' ->> 'type', ''));

  select m.id, m.business_id, m.customer_id, m.to_email into v_msg from public.email_messages m
   where v_ext is not null and m.external_message_id = v_ext and m.direction = 'outbound' limit 1;
  v_to := coalesce(v_to, lower(v_msg.to_email));

  insert into public.email_events (provider_event_id, type, email_message_id, business_id, to_email, detail)
  values (left(p_event_id, 200), v_type, v_msg.id, v_msg.business_id, v_to,
          jsonb_build_object('bounce_type', nullif(v_bounce, ''), 'bounce_sub_type', v_data -> 'bounce' ->> 'subType'))
  on conflict (provider_event_id) do nothing;
  if not found then return 'duplicate'; end if;
  if v_msg.id is null and v_to is null then return 'ignored'; end if;

  if v_type = 'email.delivered' then
    update public.email_messages set status = 'delivered', delivered_at = now(), updated_at = now() where id = v_msg.id and status in ('sent', 'queued');
    return 'delivered';
  end if;

  if v_type = 'email.bounced' and v_bounce in ('permanent', 'hard') then
    if v_msg.id is not null then
      update public.email_messages set status = 'failed', metadata = metadata || jsonb_build_object('bounced', true), updated_at = now() where id = v_msg.id;
    end if;
    if v_to is not null then
      for v_cust in
        update public.customers c set do_not_email = true, email_suppressed_at = now(), email_suppressed_reason = 'bounced', updated_at = now()
         where lower(c.email) = v_to and not coalesce(c.do_not_email, false)
        returning c.business_id, c.id
      loop
        perform public.zella_notify(v_cust.business_id, 'email_bounced', 'An email address does not work',
          'An email to ' || v_to || ' could not be delivered, so we will not email that address again. Please check the address with the customer.', 'info', 'customers', v_cust.id);
      end loop;
    end if;
    return 'bounced';
  end if;

  if v_type = 'email.complained' then
    if v_msg.business_id is not null and v_to is not null then
      for v_cust in
        update public.customers c set do_not_email = true, email_suppressed_at = now(), email_suppressed_reason = 'complained', updated_at = now()
         where c.business_id = v_msg.business_id and lower(c.email) = v_to and not coalesce(c.do_not_email, false)
        returning c.business_id, c.id
      loop
        perform public.zella_notify(v_cust.business_id, 'email_complaint', 'A customer marked an email as spam',
          v_to || ' marked an email as spam, so we will not email them again.', 'warning', 'customers', v_cust.id);
      end loop;
    end if;
    return 'complained';
  end if;

  return 'recorded';
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_record_email_event_signed(p_key text, p_event jsonb, p_event_id text, p_sig jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
begin
  if public.zella_resend_signature_ok(p_sig ->> 'id', p_sig ->> 'timestamp', p_sig ->> 'signature', p_sig ->> 'raw') = 'bad' then return 'unauthorized'; end if;
  return public.zella_record_email_event(p_key, p_event, p_event_id);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_record_inbound_call(p_provider_call_id text, p_called_number text, p_vapi_phone_number_id text, p_from_number text, p_started_at timestamp with time zone, p_ended_at timestamp with time zone, p_seconds integer, p_reason text, p_summary text, p_recording_url text, p_transcript text, p_wants_callback boolean DEFAULT false)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c public.calls; v_biz uuid; v_cust uuid; v_out text; v_note text; v_secs integer := greatest(coalesce(p_seconds, 0), 0);
  v_phone text := nullif(left(coalesce(p_from_number, ''), 30), '');
  v_booked boolean := false; v_msg boolean := false; v_cb boolean := false; v_lead jsonb;
begin
  if nullif(p_provider_call_id, '') is null then return 'ignored'; end if;
  select * into c from public.calls where external_call_id = p_provider_call_id for update;
  if found and c.outcome_at is not null and c.ended_at is not null then return 'ignored'; end if;
  v_biz := c.business_id;
  if v_biz is null then v_biz := public.zella_business_for_number(p_called_number, p_vapi_phone_number_id, null); end if;
  if v_biz is null then return 'unknown_business'; end if;
  if not found then
    insert into public.calls (business_id, direction, status, from_number, to_number, external_call_id, started_at, ai_handled)
    values (v_biz, 'inbound', 'answered', v_phone, left(p_called_number, 30), p_provider_call_id, coalesce(p_started_at, now() - make_interval(secs => v_secs)), true)
    on conflict (external_call_id) where external_call_id is not null do nothing -- zella_one_call_row
    returning * into c;
    if c.id is null then select * into c from public.calls where external_call_id = p_provider_call_id for update; end if;
  end if;
  v_phone := coalesce(v_phone, c.from_number);

  v_cust := c.customer_id;
  if v_cust is null and public.zella_digits(v_phone) is not null then
    begin select m.customer_id into v_cust from public.zella_match_customer(v_biz, v_phone, null) m where m.certainty = 'exact' limit 1;
    exception when others then v_cust := null; end;
  end if;

  v_msg := exists (select 1 from public.call_messages where call_id = c.id);
  v_cb := exists (select 1 from public.callbacks where call_id = c.id);
  v_booked := v_cust is not null and exists (select 1 from public.appointments a where a.customer_id = v_cust and a.business_id = v_biz
                 and a.created_at between coalesce(c.started_at, now() - interval '3 hours') - interval '1 minute' and coalesce(p_ended_at, now()) + interval '3 minutes' and a.status <> 'cancelled');

  if coalesce(p_wants_callback, false) and not v_cb and public.zella_digits(v_phone) is not null then
    perform public.zella_create_callback(v_biz, v_phone, 'requested', 'normal', left(coalesce(nullif(trim(p_summary), ''), 'Caller asked for a call back.'), 500), null, v_cust, c.id, null, 'phone_assistant', null);
    v_cb := true;
  end if;

  if c.outcome is null then
    v_out := case
      when v_booked then 'booked'
      when v_msg then 'left_message'
      when v_cb or c.needs_human then 'callback_needed'
      when v_secs < 6 then 'other'
      when nullif(trim(p_summary), '') is not null then 'resolved'
      else 'other' end;
    v_note := case v_out when 'booked' then 'Booked during the call.' when 'left_message' then 'The caller left a message.' when 'callback_needed' then 'Needs a call back.'
                         when 'resolved' then 'Handled on the call.' else case when v_secs < 6 then 'Caller hung up quickly.' else 'No summary was returned.' end end;
  end if;

  if v_cust is null and v_out in ('booked', 'left_message', 'callback_needed') and public.zella_digits(v_phone) is not null then
    v_lead := public.zella_capture_lead(v_biz, null, null, v_phone, null, 'phone_call', left(p_summary, 500), null);
    v_cust := nullif(v_lead ->> 'customer_id', '')::uuid;
  end if;

  update public.calls set
      status = case when v_secs = 0 and p_reason ~* 'did-not-answer|no-answer|busy' then 'missed' else 'completed' end,
      customer_id = coalesce(customer_id, v_cust), to_number = coalesce(to_number, left(p_called_number, 30)), from_number = coalesce(from_number, v_phone),
      ended_at = coalesce(p_ended_at, ended_at, now()), duration_seconds = case when p_seconds is null then duration_seconds else v_secs end, -- zella_real_times
      transfer_status = case when p_reason = 'assistant-forwarded-call' then 'connected' when transfer_status = 'attempted' then 'failed' else transfer_status end,
      summary = coalesce(nullif(left(trim(p_summary), 1500), ''), summary),
      transcript = coalesce(nullif(left(p_transcript, 60000), ''), transcript),
      recording_url = coalesce(nullif(left(p_recording_url, 1000), ''), recording_url),
      metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('ended_reason', left(p_reason, 80), 'ended_at_source', case when p_ended_at is not null then 'provider' when ended_at is not null then 'status_update' else 'received_time' end, 'awaiting_report', false),
      outcome = coalesce(outcome, v_out), outcome_note = coalesce(outcome_note, v_note), outcome_at = coalesce(outcome_at, case when v_out is not null then now() end),
      updated_at = now()
   where id = c.id;
  if v_cust is not null then update public.customers set last_contacted_at = greatest(coalesce(last_contacted_at, '-infinity'), coalesce(p_ended_at, now())) where id = v_cust; end if;
  return 'recorded';
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_record_payment_result(p_business_id uuid, p_ok boolean, p_provider_ref text DEFAULT NULL::text, p_error text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s record;
begin
  select * into s from public.subscriptions where business_id = p_business_id order by created_at desc limit 1 for update;
  if not found then raise exception 'SUBSCRIPTION_NOT_FOUND'; end if;
  if p_ok then update public.subscriptions set status = 'active' where id = s.id and status in ('past_due', 'grace_period', 'renewal_due', 'trial'); return 'active'; end if;
  update public.subscriptions set status = 'past_due' where id = s.id and status in ('active', 'renewal_due', 'trial', 'past_due');
  perform public.zella_platform_alert('payment_failed', 'A payment failed', left(p_error, 300), 'urgent', p_business_id, 'payment', jsonb_build_object('provider_ref', p_provider_ref));
  return 'past_due';
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_record_provider_check(p_provider text, p_ok boolean, p_detail text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare h public.provider_health;
begin
  if p_provider not in ('telnyx', 'vapi', 'resend') then raise exception 'UNKNOWN_PROVIDER'; end if;
  insert into public.provider_health (provider) values (p_provider) on conflict do nothing;
  select * into h from public.provider_health where provider = p_provider for update;
  update public.provider_health set ok = p_ok, detail = left(p_detail, 120), checked_at = now(), claimed_at = null,
         consecutive_failures = case when p_ok then 0 else consecutive_failures + 1 end,
         last_ok_at = case when p_ok then now() else last_ok_at end
   where provider = p_provider;
  if not p_ok and h.consecutive_failures + 1 = 2 then
    perform public.zella_platform_alert('provider_down', initcap(p_provider) || ' is not responding', left(p_detail, 120), 'urgent', null, 'provider_down:' || p_provider);
  elsif p_ok and h.consecutive_failures >= 2 then
    perform public.zella_platform_alert('provider_recovered', initcap(p_provider) || ' is working again', null, 'info', null, 'provider_recovered:' || p_provider);
  end if;
  return case when p_ok then 'ok' else 'failed' end;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_record_sms_receipt(p_business_id uuid, p_external_id text, p_status text, p_error text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.sms_messages; v_st text := case when p_status in ('delivered', 'failed') then p_status else null end;
begin
  if v_st is null or nullif(p_external_id, '') is null then return jsonb_build_object('action', 'ignored'); end if;
  select * into r from public.sms_messages where business_id = p_business_id and external_message_id = left(p_external_id, 200) and direction = 'outbound' limit 1;
  if r.id is null then return jsonb_build_object('action', 'unknown_message'); end if;
  if r.status = 'delivered' then return jsonb_build_object('action', 'already_delivered'); end if;
  if v_st = 'delivered' then
    update public.sms_messages set status = 'delivered', delivered_at = now(), updated_at = now() where id = r.id;
    return jsonb_build_object('action', 'delivered');
  end if;
  update public.sms_messages set status = 'failed', metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('delivery_error', left(coalesce(p_error, 'unknown'), 200)), updated_at = now() where id = r.id;
  perform public.zella_notify_owners(p_business_id, 'sms_not_delivered', 'A text did not arrive',
    'A text to ' || coalesce(r.to_number, 'a customer') || ' could not be delivered (' || left(coalesce(nullif(p_error, ''), 'unknown reason'), 100) || '). Check the number.', 'info', 'inbox');
  return jsonb_build_object('action', 'failed');
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_record_status_touches_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a record; v_line text;
begin
  if new.status is distinct from old.status and new.customer_id is not null then
    for a in select * from public.automations x
              where x.business_id = new.business_id and x.trigger_type = 'record_status_update' and x.status = 'active'
                and (x.trigger_config ->> 'type_key' is null or x.trigger_config ->> 'type_key' = new.type_key) loop
      v_line := left(nullif(trim(a.trigger_config -> 'messages' ->> new.status), ''), 300);
      if v_line is not null then
        perform public.zella_queue_customer_message(new.business_id, new.customer_id, 'record_status_update',
          jsonb_build_object('status_line', v_line, 'status', new.status, 'record_title', new.title), interval '1 minute', null, interval '0');
      end if;
    end loop;
    if new.status = 'completed' and new.type_key in ('jobs', 'work_orders') and not exists (
         select 1 from public.automations x where x.business_id = new.business_id and x.trigger_type = 'record_status_update' and x.status = 'active'
            and nullif(trim(x.trigger_config -> 'messages' ->> 'completed'), '') is not null) then
      perform public.zella_queue_customer_message(new.business_id, new.customer_id, 'service_completed', jsonb_build_object('record_title', new.title), interval '5 minutes', null, interval '1 day');
    end if;
  end if;
  return new;
exception when others then
  return new;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_recover_failed_texts(p_limit integer DEFAULT 50)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_recover_knowledge()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare k record; n integer := 0;
begin
  for k in select id, business_id, title, sync_attempts from public.knowledge_items
            where status = 'processing' and updated_at < now() - interval '30 minutes' for update skip locked loop
    if k.sync_attempts >= 3 then
      update public.knowledge_items set status = 'failed', error = 'The assistant did not confirm this update after several tries.', updated_at = now() where id = k.id;
      perform public.zella_notify_owners(k.business_id, 'knowledge_failed', 'We could not update what your assistant knows',
        left(coalesce(k.title, 'One of your answers'), 100) || ' did not go through. Open Knowledge and try saving it again.', 'warning', 'knowledge');
    else
      update public.knowledge_items set sync_attempts = sync_attempts + 1, updated_at = now() where id = k.id;
    end if;
    n := n + 1;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_recover_orphaned_work()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a int; b int; c int; d int; e int;
begin
  update public.followup_tasks set status = 'pending', updated_at = now()
   where status = 'in_progress' and claimed_at < now() - interval '30 minutes' and attempts < max_attempts;
  get diagnostics a = row_count;
  update public.followup_tasks set status = 'failed', outcome = 'stuck', completed_at = now(), updated_at = now()
   where status = 'in_progress' and claimed_at < now() - interval '30 minutes' and attempts >= max_attempts;
  get diagnostics b = row_count;
  update public.customers x set assigned_to = null
   where x.assigned_to is not null and not exists (select 1 from public.business_members m where m.business_id = x.business_id and m.user_id = x.assigned_to and m.status = 'active');
  get diagnostics c = row_count;
  update public.callbacks x set assigned_to = null
   where x.assigned_to is not null and x.status not in ('completed','done','reached','cancelled','failed')
     and not exists (select 1 from public.business_members m where m.business_id = x.business_id and m.user_id = x.assigned_to and m.status = 'active');
  get diagnostics d = row_count;
  update public.customer_requests x set assigned_to = null
   where x.assigned_to is not null and x.status not in ('resolved','closed','cancelled')
     and not exists (select 1 from public.business_members m where m.business_id = x.business_id and m.user_id = x.assigned_to and m.status = 'active');
  get diagnostics e = row_count;
  if a + b > 0 then
    perform public.zella_platform_alert('stuck_followups', 'Follow-up tasks were stuck', (a + b) || ' tasks were claimed but never finished and were reset or failed.', 'warning', null, 'stuck_followups');
  end if;
  return a + b + c + d + e;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_recover_provisioning()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; n integer := 0;
begin
  for r in select business_id, step from public.provisioning_steps where status = 'pending' and updated_at < now() - interval '30 minutes' loop
    perform public.zella_track_provisioning(r.business_id, r.step, 'failed', 'Stuck for over 30 minutes');
    n := n + 1;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_redact(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  select left(regexp_replace(coalesce(p, ''), '[A-Za-z0-9_\-\.]{32,}', '[redacted]', 'g'), 500)
$function$
;
CREATE OR REPLACE FUNCTION public.zella_register_phone_number(p_business_id uuid, p_number text, p_vapi_phone_number_id text DEFAULT NULL::text, p_label text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_e text := public.zella_normalize_e164(p_number); v_existing record; v_id uuid;
begin
  if v_e is null then raise exception 'INVALID_NUMBER'; end if;
  if not exists (select 1 from public.businesses where id = p_business_id and suspended_at is null and cancelled_at is null) then raise exception 'BUSINESS_NOT_AVAILABLE'; end if;
  select * into v_existing from public.business_phone_numbers where e164 = v_e or (nullif(p_vapi_phone_number_id, '') is not null and vapi_phone_number_id = p_vapi_phone_number_id) limit 1;
  if found and v_existing.business_id <> p_business_id then raise exception 'NUMBER_IN_USE'; end if;
  if found then
    update public.business_phone_numbers set e164 = v_e, vapi_phone_number_id = coalesce(nullif(p_vapi_phone_number_id, ''), vapi_phone_number_id),
      label = coalesce(left(p_label, 80), label), status = 'active' where id = v_existing.id returning id into v_id;
  else
    insert into public.business_phone_numbers (business_id, e164, vapi_phone_number_id, label)
    values (p_business_id, v_e, nullif(p_vapi_phone_number_id, ''), left(p_label, 80)) returning id into v_id;
  end if;
  return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_reject_data_rights_request(p_request_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.data_rights_requests;
begin
  select * into r from public.data_rights_requests where id = p_request_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not public.zella_has_role(r.business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  if r.status <> 'open' then raise exception 'ALREADY_HANDLED'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'REASON_REQUIRED'; end if;
  update public.data_rights_requests set status = 'rejected', handled_by = auth.uid(), handled_at = now(), note = left(p_reason, 1000) where id = r.id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data) values (r.business_id, auth.uid(), 'data_rights_rejected', 'data_rights_request', r.id, jsonb_build_object('kind', r.kind));
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_release_call(p_source text, p_id uuid, p_reason text DEFAULT 'dry_run'::text, p_defer_minutes integer DEFAULT 720)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_due timestamptz := now() + make_interval(mins => greatest(5, coalesce(p_defer_minutes, 720)));
begin
  if p_source = 'task' then
    update public.followup_tasks set status = 'pending', attempts = greatest(0, attempts - 1), due_at = v_due, outcome_notes = left(coalesce(p_reason, 'released'), 300), updated_at = now()
     where id = p_id and status = 'in_progress';
  elsif p_source = 'callback' then
    update public.callbacks set status = 'scheduled', attempts = greatest(0, attempts - 1), due_at = v_due, locked_at = null, updated_at = now()
     where id = p_id and status = 'in_progress';
  else
    raise exception 'BAD_SOURCE';
  end if;
  if not found then return 'not_in_progress'; end if;
  return 'released';
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_remind_integrations()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare b record; v_missing text[]; n integer := 0;
begin
  for b in select id from public.businesses where onboarding_status = 'active' and suspended_at is null and cancelled_at is null loop
    v_missing := '{}';
    if not exists (select 1 from public.business_phone_numbers p where p.business_id = b.id and p.status = 'active') then v_missing := array_append(v_missing, 'a phone number for your assistant'::text); end if;
    if not exists (select 1 from public.calendar_connections c where c.business_id = b.id and c.status = 'active') then v_missing := array_append(v_missing, 'your calendar'::text); end if;
    continue when cardinality(v_missing) = 0;
    continue when exists (select 1 from public.staff_notifications where business_id = b.id and kind = 'integration_reminder' and created_at > now() - interval '7 days');
    perform public.zella_notify_owners(b.id, 'integration_reminder', 'Connect ' || array_to_string(v_missing, ' and '), 'Zella works best when these are connected. Open Settings to finish.', 'info', 'settings');
    n := n + 1;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_remind_reconnects()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; n integer := 0;
begin
  for r in
    select business_id, string_agg(label, ' and ') as what from (
      select business_id, 'calendar' as label from public.calendar_connections
       where status = 'error' and coalesce(last_pushed_at, last_pulled_at, connected_at) < now() - interval '1 day'
      union
      select business_id, 'Facebook/Instagram' from public.meta_connections
       where status = 'needs_reconnect' and coalesce(last_checked_at, now()) < now() - interval '1 day') x
     group by business_id loop
    perform public.zella_notify_owners(r.business_id, 'reconnect_reminder', 'Still not connected: ' || r.what,
      'Reconnect in Settings so bookings, messages and leads keep flowing.', 'warning', 'settings');
    n := n + 1;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_remind_upcoming_callbacks()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; n integer := 0;
begin
  for r in select cb.id, cb.business_id, cb.assigned_to, cb.customer_id, coalesce(cb.preferred_at, cb.due_at) as at_time
             from public.callbacks cb
            where cb.status in ('new', 'scheduled', 'due', 'retry_scheduled') and cb.reminder_sent_at is null
              and coalesce(cb.preferred_at, cb.due_at) between now() and now() + interval '15 minutes' for update skip locked loop
    if r.assigned_to is not null then
      perform public.zella_notify(r.business_id, 'callback_soon', 'A callback is due soon', 'Call back within the next 15 minutes.', 'warning', 'calls', r.id, r.assigned_to);
    else
      perform public.zella_notify_owners(r.business_id, 'callback_soon', 'A callback is due soon', 'Nobody has taken it yet. Call back within the next 15 minutes.', 'warning', 'calls');
    end if;
    update public.callbacks set reminder_sent_at = now() where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_reminder_response(p_appointment_id uuid, p_response text, p_note text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a record;
begin
  select * into a from public.appointments where id = p_appointment_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_response = 'confirm' then
    update public.appointments set status = 'confirmed', updated_at = now() where id = p_appointment_id and status = 'scheduled'; return 'confirmed';
  elsif p_response = 'cancel' then
    update public.appointments set status = 'cancelled', cancel_reason = coalesce(nullif(p_note, ''), 'Customer cancelled'), updated_at = now() where id = p_appointment_id and status in ('scheduled', 'confirmed'); return 'cancelled';
  elsif p_response = 'reschedule' then
    perform public.zella_create_callback(a.business_id, null, 'appointment_request', 'normal', coalesce(nullif(p_note, ''), 'Customer asked to reschedule.'), null, a.customer_id, null, a.id, 'ai'); return 'reschedule_requested';
  end if;
  return 'no_change';
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_remove_waitlist_entry(p_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_b uuid;
begin
  select business_id into v_b from public.waitlist_entries where id = p_id;
  if v_b is null or not public.zella_is_member(v_b) then raise exception 'NOT_ALLOWED'; end if;
  update public.waitlist_entries set status = 'removed' where id = p_id and status in ('waiting', 'offered');
  return found;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_replace_calendar_busy(p_connection_id uuid, p_events jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c record; e jsonb; n integer := 0; v_s timestamptz; v_e timestamptz;
begin
  select * into c from public.calendar_connections where id = p_connection_id and status = 'active';
  if c.id is null then return 0; end if;
  if jsonb_typeof(p_events) <> 'array' then raise exception 'BAD_EVENTS'; end if;
  delete from public.blocked_times where connection_id = c.id and source = 'google' and end_time >= now() - interval '1 day';
  for e in select * from jsonb_array_elements(p_events) limit 500 loop
    begin v_s := (e ->> 'start')::timestamptz; v_e := (e ->> 'end')::timestamptz; exception when others then continue; end;
    if v_s is null or v_e is null or v_e <= v_s or (e ->> 'id') is null then continue; end if;
    if exists (select 1 from public.appointments a where a.business_id = c.business_id and a.external_event_id = e ->> 'id') then continue; end if;
    insert into public.blocked_times (business_id, title, reason, start_time, end_time, all_day, source, external_id, connection_id)
    values (c.business_id, 'Busy (Google Calendar)', 'Busy in the business calendar', v_s, v_e, coalesce((e ->> 'all_day')::boolean, false), 'google', left(e ->> 'id', 200), c.id)
    on conflict (connection_id, external_id) where external_id is not null do update set start_time = excluded.start_time, end_time = excluded.end_time, all_day = excluded.all_day;
    n := n + 1;
  end loop;
  update public.calendar_connections set last_pulled_at = now(), busy_refresh_due_at = null, last_error = null where id = c.id;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_replace_reminders(p_appointment_id uuid, p_send_confirmation boolean DEFAULT false, p_reason text DEFAULT 'booked'::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a record; v_rem record; v_conf record; v_hours numeric[]; h numeric;
begin
  update public.appointment_reminders set status = 'cancelled', error = 'replaced' where appointment_id = p_appointment_id and status in ('pending');
  select * into a from public.appointments where id = p_appointment_id;
  if not found or a.status not in ('scheduled', 'confirmed') or coalesce(a.booking_state, 'confirmed') <> 'confirmed' or a.start_time <= now() then return; end if;

  select x.* into v_rem from public.automations x where x.business_id = a.business_id and x.trigger_type = 'appointment_reminder' and x.status = 'active' limit 1;
  if v_rem.id is not null then
    v_hours := case when v_rem.trigger_config ? 'hours_before' and jsonb_typeof(v_rem.trigger_config -> 'hours_before') = 'array'
                    then array(select jsonb_array_elements_text(v_rem.trigger_config -> 'hours_before')::numeric) else array[24]::numeric[] end;
    foreach h in array v_hours loop
      if a.start_time - make_interval(secs => h * 3600) > now() then
        insert into public.appointment_reminders (business_id, appointment_id, customer_id, kind, hours_before, reason, due_at, channel)
        values (a.business_id, a.id, a.customer_id, 'reminder', h, p_reason, a.start_time - make_interval(secs => h * 3600), coalesce(v_rem.trigger_config ->> 'channel', 'sms')) on conflict do nothing;
      end if;
    end loop;
  end if;
  -- the booking message. No "please confirm" message follows it: the customer only ever has the Reschedule button.
  select x.* into v_conf from public.automations x where x.business_id = a.business_id and x.trigger_type = 'appointment_confirmation' and x.status = 'active' limit 1;
  if v_conf.id is not null and p_send_confirmation then
    insert into public.appointment_reminders (business_id, appointment_id, customer_id, kind, reason, due_at, channel)
    values (a.business_id, a.id, a.customer_id, 'confirmation', p_reason, now(), coalesce(v_conf.trigger_config ->> 'channel', 'sms')) on conflict do nothing;
  end if;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_report_call_failure(p_business_id uuid, p_call_id uuid, p_error text, p_context jsonb DEFAULT '{}'::jsonb, p_phone text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_phone text := p_phone; v_cb uuid; v_cust uuid; v_recent integer;
begin
  if p_call_id is not null then
    update public.calls set failure_reason = left(p_error, 300), failure_context = p_context where id = p_call_id and business_id = p_business_id
      returning customer_id, coalesce(v_phone, (to_jsonb(calls) ->> 'from_number')) into v_cust, v_phone;
  end if;
  -- fallback: a person follows up, with the error and context kept on the call
  if nullif(trim(coalesce(v_phone, '')), '') is not null then
    v_cb := public.zella_create_callback(p_business_id, v_phone, 'needs_human', 'high', 'The call could not be completed normally. Please call them back.', null, v_cust, p_call_id, null, 'system');
  end if;
  select count(*) into v_recent from public.calls where business_id = p_business_id and failure_reason is not null and created_at > now() - interval '1 hour';
  if v_recent >= 3 then
    perform public.zella_platform_alert('agent_failures', 'The AI receptionist keeps failing calls', v_recent || ' calls failed in the last hour. Last error: ' || left(p_error, 200), 'urgent', p_business_id, to_char(now(), 'YYYY-MM-DD-HH24'));
    perform public.zella_notify_owners(p_business_id, 'agent_failures', 'Some calls could not be handled', 'Several calls failed in the last hour. Zella has queued callbacks for them.', 'urgent', 'callbacks');
  end if;
  return v_cb;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_report_incorrect_answer(p_business_id uuid, p_call_id uuid, p_what_was_wrong text, p_correct_answer text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid; v_wrong text := left(trim(coalesce(p_what_was_wrong, '')), 500); v_ok text := left(trim(coalesce(p_correct_answer, '')), 1500); v_item uuid;
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager', 'staff']) then raise exception 'NOT_ALLOWED'; end if;
  if length(v_wrong) < 3 then raise exception 'EMPTY'; end if;
  if p_call_id is not null and not exists (select 1 from public.calls where id = p_call_id and business_id = p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if length(v_ok) >= 8 then
    insert into public.knowledge_items (business_id, kind, title, question, answer, status)
    values (p_business_id, 'faq', left(v_wrong, 100), left(v_wrong, 300), v_ok, 'draft') returning id into v_item;
  end if;
  insert into public.ai_answer_reports (business_id, call_id, reported_by, what_was_wrong, correct_answer, knowledge_item_id)
  values (p_business_id, p_call_id, auth.uid(), v_wrong, nullif(v_ok, ''), v_item) returning id into v_id;
  if not public.zella_has_role(p_business_id, array['owner']) then
    perform public.zella_notify_owners(p_business_id, 'wrong_answer_reported', 'A team member reported a wrong AI answer', left(v_wrong, 200), 'warning', 'calls');
  end if;
  return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_report_service_health(p_service text, p_ok boolean, p_detail text DEFAULT NULL::text, p_verified boolean DEFAULT false)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid;
begin
  if p_ok then
    perform public.zella_resolve_platform_alerts('service_incident', null, p_service, 'Service healthy again');
    return null;
  end if;
  if not coalesce(p_verified, false) then return null; end if;   -- a single unverified blip is not an incident
  v_id := public.zella_platform_alert('service_incident', initcap(p_service) || ' is having problems', p_detail, 'urgent', null, p_service);
  return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_report_telephony_event(p_business_id uuid, p_provider text, p_state text, p_error text DEFAULT NULL::text, p_retryable boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_i record; v_retry boolean := false;
begin
  if p_state not in ('connected', 'error', 'disconnected') then raise exception 'BAD_STATE'; end if;
  select * into v_i from public.integrations where business_id = p_business_id and provider = p_provider limit 1;
  if v_i.id is null then raise exception 'INTEGRATION_NOT_FOUND'; end if;
  if p_state = 'connected' then
    update public.integrations set status = 'active', last_error = null, error_count = 0, last_checked_at = now() where id = v_i.id;
    perform public.zella_resolve_platform_alerts('integration_disconnected', p_business_id, p_provider, 'Reconnected');
    return jsonb_build_object('status', 'active', 'retry', false);
  end if;
  update public.integrations set status = case when p_state = 'error' then 'error' else 'disconnected' end, last_error = left(p_error, 300), error_count = error_count + 1, last_checked_at = now() where id = v_i.id;
  -- retry only where it is safe: transient errors, a few times
  v_retry := coalesce(p_retryable, false) and v_i.error_count + 1 <= 3;
  if not v_retry then
    perform public.zella_platform_alert('integration_disconnected', initcap(p_provider) || ' connection problem', p_error, 'urgent', p_business_id, p_provider, jsonb_build_object('state', p_state));
    perform public.zella_notify_owners(p_business_id, 'integration_down', initcap(p_provider) || ' needs reconnecting', 'Your ' || p_provider || ' connection is ' || p_state || '. Open Integrations to reconnect it.', 'urgent', 'integrations');
  end if;
  return jsonb_build_object('status', p_state, 'retry', v_retry, 'retry_in_minutes', case when v_retry then 5 * (v_i.error_count + 1) end);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_report_unanswered(p_provider_call_id text, p_business_id uuid, p_question text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_gap uuid; v_from text; v_call_id uuid; v_call_biz uuid; v_cust uuid; v_biz uuid; v_q text := left(regexp_replace(trim(coalesce(p_question, '')), '\s+', ' ', 'g'), 500);
begin
  if length(v_q) < 3 then raise exception 'EMPTY_QUESTION'; end if;
  if nullif(p_provider_call_id, '') is not null then
    select c.id, c.business_id, c.customer_id into v_call_id, v_call_biz, v_cust from public.calls c where c.external_call_id = p_provider_call_id limit 1;
  end if;
  v_biz := coalesce(v_call_biz, p_business_id);
  if v_biz is null or not exists (select 1 from public.businesses b where b.id = v_biz and b.suspended_at is null and b.cancelled_at is null and coalesce(b.is_active, true)) then
    raise exception 'UNKNOWN_BUSINESS';
  end if;
  if v_call_id is not null and (select count(*) from public.knowledge_gaps g where g.call_id = v_call_id) >= 5 then return null; end if;
  v_gap := public.zella_log_knowledge_gap(v_biz, v_q, v_call_id, v_cust);
  if v_call_id is not null and (select count(*) from public.knowledge_gaps g where g.call_id = v_call_id) >= greatest(2, coalesce((public.zella_setting('ai_low_confidence_questions', '2'::jsonb) #>> '{}')::int, 2))
     and exists (select 1 from public.calls c where c.id = v_call_id and not coalesce(c.needs_human, false)) then
    update public.calls set needs_human = true, escalation_reason = coalesce(escalation_reason, 'low_confidence'), escalated_at = coalesce(escalated_at, now()), updated_at = now() where id = v_call_id returning from_number into v_from;
    if public.zella_digits(v_from) is not null then
      perform public.zella_create_callback(v_biz, v_from, 'needs_human', 'normal', 'The assistant could not answer several questions on this call.', null, v_cust, v_call_id, null, 'ai', null);
    end if;
  end if;
  return v_gap;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_request_activation(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rep jsonb;
begin
  if not public.zella_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if exists (select 1 from public.businesses where id = p_business_id and (suspended_at is not null or cancelled_at is not null)) then raise exception 'BUSINESS_NOT_AVAILABLE'; end if;
  v_rep := public.zella_activation_report(p_business_id);
  if (v_rep ->> 'ready')::boolean then
    update public.businesses set onboarding_status = 'active', is_active = true, updated_at = now() where id = p_business_id;
    update public.automations set status = 'active', updated_at = now() where business_id = p_business_id and status = 'paused';
    perform public.zella_resolve_platform_alerts('setup_incomplete', p_business_id, null, 'Went live');
    perform public.zella_notify_owners(p_business_id, 'went_live', 'You are live', 'Your AI receptionist is now answering calls.', 'info', 'today');
  end if;
  return v_rep;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_request_appointment(p_business_id uuid, p_customer_id uuid, p_phone text, p_title text, p_preferred_start timestamp with time zone DEFAULT NULL::timestamp with time zone, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tz text; v_id uuid; v_start timestamptz := coalesce(p_preferred_start, now() + interval '1 day');
begin
  select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = p_business_id and b.suspended_at is null and b.cancelled_at is null;
  if v_tz is null then raise exception 'BUSINESS_NOT_AVAILABLE'; end if;
  insert into public.appointments (business_id, customer_id, title, start_time, end_time, timezone, status, description, booking_state)
  values (p_business_id, p_customer_id, coalesce(nullif(trim(p_title), ''), 'Appointment request'), v_start, v_start + interval '30 minutes', v_tz, 'scheduled', p_notes, 'requested')
  returning id into v_id;
  perform public.zella_create_callback(p_business_id, p_phone, 'appointment_request', 'normal',
    'Appointment request: ' || coalesce(p_title, 'a visit') || coalesce('. ' || p_notes, '') || '. Not booked yet.', p_preferred_start, p_customer_id, null, v_id, 'ai');
  return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_request_approval(p_business_id uuid, p_action text, p_entity_id uuid DEFAULT NULL::uuid, p_details jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid;
begin
  if not public.zella_has_role(p_business_id, array['owner','admin','manager']) then raise exception 'NOT_ALLOWED'; end if;
  insert into public.sensitive_approvals (business_id, action, entity_id, details, requested_by) values (p_business_id, left(p_action, 80), p_entity_id, coalesce(p_details, '{}'), auth.uid()) returning id into v_id;
  perform public.zella_notify_owners(p_business_id, 'approval_requested', 'An action needs your approval', 'Someone asked to: ' || left(p_action, 80) || '. Open Approvals to decide.', 'warning', 'settings');
  return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_request_time_off(p_business_id uuid, p_staff_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_reason text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid; v_name text; v_reason text := nullif(left(trim(coalesce(p_reason, '')), 200), '');
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select name into v_name from public.staff_members where id = p_staff_id and business_id = p_business_id and is_active;
  if v_name is null then raise exception 'UNKNOWN_STAFF'; end if;
  if p_from is null or p_to is null or p_to <= p_from or p_to < now() or p_to - p_from > interval '60 days' then raise exception 'BAD_DATES'; end if;
  insert into public.time_off_requests (business_id, staff_id, requested_by, from_at, to_at, reason)
  values (p_business_id, p_staff_id, auth.uid(), p_from, p_to, v_reason) returning id into v_id;
  perform public.zella_notify_owners(p_business_id, 'time_off_request', 'Time off requested: ' || v_name, coalesce(v_reason, 'Open the calendar to approve or decline.'), 'info', 'calendar');
  return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_reschedule_appointment(p_appointment_id uuid, p_start timestamp with time zone, p_staff_id uuid DEFAULT NULL::uuid, p_requested_by text DEFAULT 'customer'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a record; v_dur integer; v_slot record;
begin
  perform public.zella_booking_lock((select x.business_id from public.appointments x where x.id = p_appointment_id)); -- zella_booking_lock
  select * into a from public.appointments where id = p_appointment_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if auth.uid() is not null and not public.zella_is_member(a.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if a.status in ('cancelled', 'completed') then raise exception 'NOT_RESCHEDULABLE'; end if;
  if extract(minute from p_start)::int % 5 <> 0 then raise exception 'BAD_TIME'; end if;
  v_dur := greatest(5, (extract(epoch from (a.end_time - a.start_time)) / 60)::int);
  select * into v_slot from public.zella_available_slots(a.business_id, p_start, p_start, v_dur, coalesce(p_staff_id, a.staff_id), 5, 1, p_appointment_id) limit 1;
  if v_slot.slot_start is null or v_slot.slot_start <> p_start then raise exception 'SLOT_TAKEN'; end if;
  update public.appointments set start_time = v_slot.slot_start, end_time = v_slot.slot_end, staff_id = coalesce(v_slot.staff_id, staff_id),
         status = case when status in ('no_show') then 'scheduled' else status end,
         reschedule_requested_by = case when p_requested_by in ('customer', 'staff', 'ai') then p_requested_by else 'staff' end, updated_at = now()
   where id = p_appointment_id;
  return jsonb_build_object('appointment_id', p_appointment_id, 'original_start', a.start_time, 'new_start', v_slot.slot_start);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_reschedule_callback(p_callback_id uuid, p_new_time timestamp with time zone)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare cb record; v_tz text; v_due timestamptz;
begin
  select * into cb from public.callbacks where id = p_callback_id;
  if cb.id is null then raise exception 'NOT_FOUND'; end if;
  if not public.zella_has_role(cb.business_id, array['owner','admin','manager','staff']) then raise exception 'NOT_ALLOWED'; end if;
  select coalesce(timezone, 'America/New_York') into v_tz from public.businesses where id = cb.business_id;
  v_due := public.zella_next_call_time(greatest(p_new_time, now()), v_tz);
  update public.callbacks set due_at = v_due, preferred_at = p_new_time, status = 'scheduled', locked_at = null, overdue_notified_at = null, overdue_escalated_at = null, updated_at = now()
   where id = p_callback_id and status not in ('completed','cancelled');
  return v_due;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_reschedule_confirm(p_token text, p_start timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare l record; v_info jsonb; v_res jsonb;
begin
  v_info := public.zella_reschedule_lookup(p_token);
  if not coalesce((v_info ->> 'ok')::boolean, false) then return v_info; end if;
  select * into l from public.appointment_reschedule_links where token_hash = encode(sha256(convert_to(p_token, 'utf8')), 'hex');
  begin
    v_res := public.zella_reschedule_appointment(l.appointment_id, p_start, null, 'customer');
  exception when others then
    if sqlerrm in ('SLOT_TAKEN', 'BAD_TIME') then return jsonb_build_object('ok', false, 'reason', 'slot_taken'); end if;
    if sqlerrm = 'NOT_RESCHEDULABLE' then return jsonb_build_object('ok', false, 'reason', 'not_available'); end if;
    raise;
  end;
  update public.appointment_reschedule_links set last_used_at = now(), uses = uses + 1 where id = l.id;
  return jsonb_build_object('ok', true, 'new_start', v_res ->> 'new_start');
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_reschedule_line(p_appointment_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_base text := regexp_replace(coalesce(nullif(trim(public.zella_setting('app_base_url', '""'::jsonb) #>> '{}'), ''), ''), '/+$', '');
  v_token text; a record;
begin
  if v_base = '' or v_base !~ '^https://[^\s]+$' then return ''; end if;
  select id, business_id into a from public.appointments where id = p_appointment_id;
  if a.id is null then return ''; end if;
  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into public.appointment_reschedule_links (appointment_id, business_id, token_hash)
  values (a.id, a.business_id, encode(sha256(convert_to(v_token, 'utf8')), 'hex'));
  return ' Need a new time? ' || v_base || '/r/' || v_token;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_reschedule_lookup(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare l record; a record; b record; c record; v_dur integer; v_rebook boolean;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then return jsonb_build_object('ok', false, 'reason', 'invalid'); end if;
  select * into l from public.appointment_reschedule_links where token_hash = encode(sha256(convert_to(p_token, 'utf8')), 'hex');
  if l.id is null then return jsonb_build_object('ok', false, 'reason', 'invalid'); end if;
  select * into a from public.appointments where id = l.appointment_id;
  select id, name, coalesce(timezone, 'America/New_York') as tz, suspended_at, cancelled_at into b from public.businesses where id = l.business_id;
  if a.id is null or b.id is null or b.suspended_at is not null or b.cancelled_at is not null then
    return jsonb_build_object('ok', false, 'reason', 'invalid');
  end if;
  -- rebook: a link sent after a no-show opens only while the appointment is still a no-show and the link is fresh.
  v_rebook := coalesce(l.purpose, 'reschedule') = 'rebook';
  if v_rebook then
    if l.expires_at is not null and l.expires_at < now() then return jsonb_build_object('ok', false, 'reason', 'past', 'business', b.name); end if;
    if a.status <> 'no_show' then return jsonb_build_object('ok', false, 'reason', 'not_available', 'business', b.name); end if;
  else
    if a.status in ('cancelled', 'no_show', 'completed') then
      return jsonb_build_object('ok', false, 'reason', 'not_available', 'business', b.name);
    end if;
    if coalesce(a.booking_state, 'confirmed') <> 'confirmed' then
      return jsonb_build_object('ok', false, 'reason', 'not_available', 'business', b.name);
    end if;
    if a.start_time <= now() then
      return jsonb_build_object('ok', false, 'reason', 'past', 'business', b.name);
    end if;
  end if;
  select nullif(trim(coalesce(first_name, '')), '') as first_name into c from public.customers where id = a.customer_id;
  v_dur := greatest(5, (extract(epoch from (a.end_time - a.start_time)) / 60)::int);
  return jsonb_build_object('ok', true, 'business', b.name, 'timezone', b.tz, 'first_name', c.first_name, 'missed', v_rebook,
    'appointment', jsonb_build_object('title', a.title, 'start', a.start_time, 'end', a.end_time, 'minutes', v_dur));
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_reschedule_slots(p_token text, p_days integer DEFAULT 14)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare l record; a record; v_info jsonb; v_dur integer; v_res jsonb;
begin
  v_info := public.zella_reschedule_lookup(p_token);
  if not coalesce((v_info ->> 'ok')::boolean, false) then return v_info; end if;
  select * into l from public.appointment_reschedule_links where token_hash = encode(sha256(convert_to(p_token, 'utf8')), 'hex');
  select * into a from public.appointments where id = l.appointment_id;
  v_dur := greatest(5, (extract(epoch from (a.end_time - a.start_time)) / 60)::int);
  select coalesce(jsonb_agg(jsonb_build_object('start', s.slot_start, 'end', s.slot_end) order by s.slot_start), '[]'::jsonb) into v_res
    from public.zella_available_slots(a.business_id, now() + interval '30 minutes', now() + make_interval(days => greatest(1, least(coalesce(p_days, 14), 30))),
                                      v_dur, a.staff_id, 30, 200, a.id) s;
  return jsonb_build_object('ok', true, 'slots', v_res);
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_resend_invitation(p_invitation_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare i public.business_invitations;
begin
  select * into i from public.business_invitations where id = p_invitation_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not public.zella_has_role(i.business_id, array['owner', 'admin']) then raise exception 'NOT_ALLOWED'; end if;
  if i.status not in ('pending', 'sent', 'failed', 'expired') then raise exception 'CANNOT_RESEND'; end if;
  update public.business_invitations set status = 'pending', reminder_count = 0, last_reminded_at = null, last_error = null, invited_at = now(), expires_at = now() + interval '14 days', updated_at = now() where id = i.id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_resend_signature_ok(p_id text, p_timestamp text, p_signature text, p_raw text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_secret text; v_key bytea; v_expect text; v_part text; v_ts bigint;
begin
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'zella_resend_signing_secret' limit 1;
  if v_secret is null or v_secret = '' then return 'off'; end if;
  if coalesce(p_id, '') = '' or coalesce(p_timestamp, '') !~ '^[0-9]{9,12}$' or coalesce(p_signature, '') = '' or p_raw is null then return 'bad'; end if;
  v_ts := p_timestamp::bigint;
  if abs(extract(epoch from now())::bigint - v_ts) > 300 then return 'bad'; end if;
  begin
    v_key := decode(regexp_replace(v_secret, '^whsec_', ''), 'base64');
  exception when others then return 'bad'; end;
  v_expect := encode(hmac(convert_to(p_id || '.' || p_timestamp || '.' || p_raw, 'utf8'), v_key, 'sha256'), 'base64');
  foreach v_part in array regexp_split_to_array(trim(left(p_signature, 500)), '\s+') loop
    if split_part(v_part, ',', 1) = 'v1'
       and encode(sha256(convert_to(split_part(v_part, ',', 2), 'utf8')), 'hex') = encode(sha256(convert_to(v_expect, 'utf8')), 'hex') then
      return 'ok';
    end if;
  end loop;
  return 'bad';
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_resolve_answer_report(p_report_id uuid, p_fixed boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.ai_answer_reports%rowtype;
begin
  select * into r from public.ai_answer_reports where id = p_report_id;
  if not found or not public.zella_has_role(r.business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  update public.ai_answer_reports set status = case when p_fixed then 'fixed' else 'dismissed' end where id = r.id;
  return true;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_resolve_duplicate(p_review_id uuid, p_action text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d record; v_id uuid := null; i jsonb;
begin
  select * into d from public.duplicate_reviews where id = p_review_id for update;
  if not found or not public.zella_is_member(d.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if d.status <> 'open' then raise exception 'ALREADY_RESOLVED'; end if;
  i := d.incoming;
  if i ? 'duplicate_customer_id' then
    if p_action = 'merge' then
      perform public.zella_merge_customers(d.business_id, d.customer_id, (i ->> 'duplicate_customer_id')::uuid);
      return d.customer_id;
    elsif p_action in ('keep_separate', 'dismiss') then
      update public.duplicate_reviews set status = case when p_action = 'dismiss' then 'dismissed' else 'kept_separate' end, resolved_by = auth.uid(), resolved_at = now() where id = p_review_id;
      return d.customer_id;
    end if;
    raise exception 'BAD_ACTION';
  end if;
  if p_action = 'merge' and d.customer_id is not null then
    update public.customers set first_name = coalesce(first_name, nullif(i ->> 'first_name', '')), last_name = coalesce(last_name, nullif(i ->> 'last_name', '')),
           phone = coalesce(phone, nullif(i ->> 'phone', '')), email = coalesce(email, lower(nullif(i ->> 'email', ''))),
           notes = case when nullif(i ->> 'notes', '') is null then notes else coalesce(notes || E'\n', '') || (i ->> 'notes') end, updated_at = now()
     where id = d.customer_id;
    v_id := d.customer_id;
    update public.duplicate_reviews set status = 'merged', resolved_by = auth.uid(), resolved_at = now() where id = p_review_id;
  elsif p_action = 'keep_separate' then
    insert into public.customers (business_id, first_name, last_name, phone, email, source, notes, lead_stage)
    values (d.business_id, nullif(i ->> 'first_name', ''), nullif(i ->> 'last_name', ''), nullif(i ->> 'phone', ''), lower(nullif(i ->> 'email', '')), coalesce(nullif(i ->> 'source', ''), 'website'), nullif(i ->> 'notes', ''), 'new')
    returning id into v_id;
    perform public.zella_apply_lead_rules(v_id);
    update public.duplicate_reviews set status = 'kept_separate', resolved_by = auth.uid(), resolved_at = now() where id = p_review_id;
  elsif p_action = 'dismiss' then
    update public.duplicate_reviews set status = 'dismissed', resolved_by = auth.uid(), resolved_at = now() where id = p_review_id;
  else raise exception 'BAD_ACTION'; end if;
  update public.crm_tasks set status = 'done', completed_at = now() where business_id = d.business_id and kind = 'duplicate_review' and status = 'open' and customer_id is not distinct from d.customer_id;
  return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_resolve_incident(p_incident_id uuid, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare i public.platform_incidents; b record;
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  select * into i from public.platform_incidents where id = p_incident_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if i.status <> 'open' then raise exception 'ALREADY_RESOLVED'; end if;
  update public.platform_incidents set status = 'resolved', resolved_at = now(), resolution_note = left(p_note, 500) where id = i.id;
  for b in select id from public.businesses where suspended_at is null and cancelled_at is null and coalesce(is_active, true) loop
    perform public.zella_notify_owners(b.id, 'incident_resolved', 'Fixed: ' || left(i.title, 110), coalesce(left(p_note, 300), 'Everything is working again.'), 'info', 'home');
  end loop;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_resolve_platform_alerts(p_kind text, p_business_id uuid, p_dedupe_key text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare n integer;
begin
  update public.platform_alerts set status = 'resolved', resolved_at = now(), resolution_note = left(p_note, 300)
   where kind = p_kind and business_id is not distinct from p_business_id and status <> 'resolved' and (p_dedupe_key is null or dedupe_key = p_dedupe_key);
  get diagnostics n = row_count; return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_resolve_template(p_business_id uuid, p_key text, p_channel text, p_locale text DEFAULT 'en-US'::text)
 RETURNS message_templates
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select t.* from public.message_templates t
   join public.businesses b on b.id = p_business_id
   where t.key = p_key and t.channel = p_channel and t.status = 'active' and t.locale = coalesce(p_locale, 'en-US')
     and (t.business_id = p_business_id or (t.business_id is null and (t.industry_id = b.industry_id or t.industry_id is null)))
   order by (t.business_id is not null) desc, (t.industry_id is not null) desc, t.version desc
   limit 1;
$function$
;
CREATE OR REPLACE FUNCTION public.zella_response_time_report(p_business_id uuid, p_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d interval := make_interval(days => greatest(1, least(coalesce(p_days, 30), 365))); v_res jsonb;
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  with first_reply as (
    select m.id, m.created_at,
           (select min(o.created_at) from public.sms_messages o where o.business_id = m.business_id and o.direction = 'outbound' and o.created_at > m.created_at
               and (o.customer_id = m.customer_id and m.customer_id is not null or o.to_number = m.from_number)) as replied_at
      from public.sms_messages m
     where m.business_id = p_business_id and m.direction = 'inbound' and m.status = 'received' and m.created_at > now() - d)
  select jsonb_build_object(
    'texts_received', count(*),
    'replied', count(replied_at),
    'waiting', count(*) filter (where replied_at is null and created_at < now() - interval '15 minutes'),
    'median_minutes', round((percentile_cont(0.5) within group (order by extract(epoch from (replied_at - created_at)) / 60) filter (where replied_at is not null))::numeric, 1),
    'average_minutes', round((avg(extract(epoch from (replied_at - created_at)) / 60) filter (where replied_at is not null))::numeric, 1),
    'replied_within_hour', count(*) filter (where replied_at is not null and replied_at < created_at + interval '1 hour'))
    into v_res from first_reply;
  return v_res;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_retention_due()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object('business_id', id, 'name', name, 'retention_until', retention_until)), '[]'::jsonb)
    from public.businesses where cancelled_at is not null and retention_until is not null and retention_until < now();
$function$
;
CREATE OR REPLACE FUNCTION public.zella_retention_scan(p_limit integer DEFAULT 50)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; n integer := 0; v_name text;
begin
  for r in
    select c.business_id, c.id as customer_id, c.assigned_to, c.first_name, c.last_name,
           count(*) as visits, max(a.start_time) as last_visit, min(a.start_time) as first_visit
      from public.customers c
      join public.appointments a on a.customer_id = c.id and a.business_id = c.business_id and a.status = 'completed'
      join public.businesses b on b.id = c.business_id and b.suspended_at is null and b.cancelled_at is null
     where coalesce(c.status, 'active') = 'active' and not coalesce(c.do_not_contact, false)
     group by c.business_id, c.id, c.assigned_to, c.first_name, c.last_name
    having count(*) >= 3
       and max(a.start_time) < now() - greatest(interval '30 days', 1.5 * ((max(a.start_time) - min(a.start_time)) / (count(*) - 1)))
       and max(a.start_time) > now() - interval '2 years'
     limit greatest(1, least(coalesce(p_limit, 50), 200))
  loop
    continue when exists (select 1 from public.crm_tasks t where t.customer_id = r.customer_id and t.kind = 'retention_check'
                            and (t.status = 'open' or t.created_at > now() - interval '90 days'));
    v_name := trim(coalesce(r.first_name, '') || ' ' || coalesce(r.last_name, ''));
    insert into public.crm_tasks (business_id, customer_id, kind, title, body, priority, due_at, assigned_to, source)
    values (r.business_id, r.customer_id, 'retention_check', 'Regular customer is overdue: ' || coalesce(nullif(v_name, ''), 'a customer'),
            r.visits || ' visits, usually about every ' || round(extract(epoch from (r.last_visit - r.first_visit)) / 86400 / (r.visits - 1))::int
              || ' days. Last visit ' || to_char(r.last_visit, 'Mon FMDD, YYYY') || '. A personal call or message usually works best.',
            'normal', now() + interval '3 days', r.assigned_to, 'automation');
    n := n + 1;
  end loop;
  return n;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_retention_summary(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v jsonb;
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select jsonb_build_object(
    'regulars', count(*) filter (where visits >= 3),
    'at_risk', count(*) filter (where visits >= 3 and last_visit < now() - greatest(interval '30 days', 1.5 * gap) and last_visit > now() - interval '2 years'),
    'returning_customers', count(*) filter (where visits >= 2),
    'customers_with_visits', count(*),
    'open_retention_tasks', (select count(*) from public.crm_tasks t where t.business_id = p_business_id and t.kind = 'retention_check' and t.status = 'open'))
  into v
  from (select a.customer_id, count(*) visits, max(a.start_time) last_visit,
               case when count(*) > 1 then (max(a.start_time) - min(a.start_time)) / (count(*) - 1) else interval '0' end gap
          from public.appointments a where a.business_id = p_business_id and a.status = 'completed' and a.customer_id is not null group by a.customer_id) x;
  return v;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_retry_automation_run(p_run_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.automation_runs; a public.automations;
begin
  select * into r from public.automation_runs where id = p_run_id for update;
  if not found or not public.zella_can_manage(r.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if r.status <> 'failed' then raise exception 'NOT_FAILED'; end if;
  select * into a from public.automations where id = r.automation_id;
  if not found or a.status <> 'active' then raise exception 'AUTOMATION_OFF'; end if;
  update public.automation_runs
     set status = 'queued', next_run_at = now(), completed_at = null,
         execution_log = coalesce(execution_log, '[]'::jsonb) || jsonb_build_array(jsonb_build_object('at', now(), 'event', 'retry_requested', 'by', auth.uid()))
   where id = p_run_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (r.business_id, auth.uid(), 'automation.run_retried', 'automation', r.automation_id,
          jsonb_build_object('run_id', p_run_id, 'status', 'failed', 'error', r.error_message), jsonb_build_object('status', 'queued'));
  return 'queued';
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_retry_dead_letter(p_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d public.automation_dead_letters;
begin
  select * into d from public.automation_dead_letters where id = p_id for update;
  if not found or d.business_id is null or not public.zella_can_manage(d.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if d.status <> 'open' then raise exception 'ALREADY_RESOLVED'; end if;
  if d.source_table <> 'automation_events' then raise exception 'MANUAL_ONLY'; end if;
  update public.automation_events set status = 'received', attempts = 0, next_attempt_at = null, error_category = null, error_message = null, processed_at = null where id = d.source_id;
  update public.automation_dead_letters set status = 'retried', resolved_by = auth.uid(), resolved_at = now() where id = d.id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (d.business_id, auth.uid(), 'automation.dead_letter_retried', 'automation_event', d.source_id, jsonb_build_object('reason', d.reason), '{}'::jsonb);
  return true;
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_retry_event(p_event_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_platform_admin() then raise exception 'NOT_ALLOWED'; end if;
  update public.automation_events set status = 'received', attempts = 0, next_attempt_at = now(), claimed_at = null, error_category = null, error_message = null
   where id = p_event_id and status = 'failed';
  if not found then raise exception 'NOT_RETRYABLE'; end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  select business_id, auth.uid(), 'event_retried', 'automation_event', id, '{}'::jsonb from public.automation_events where id = p_event_id;
  return 'queued';
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_retry_failed(p_business_id uuid, p_kind text, p_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_n integer;
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  if p_kind = 'task' then
    update public.followup_tasks set status = 'pending', attempts = 0, due_at = now(), claimed_at = null, updated_at = now() where id = p_id and business_id = p_business_id and status = 'failed';
  elsif p_kind = 'reminder' then
    update public.appointment_reminders set status = 'pending', attempts = 0, error = null where id = p_id and business_id = p_business_id and status = 'failed'
       and exists (select 1 from public.appointments a where a.id = appointment_id and a.start_time > now());
  elsif p_kind = 'social' then
    update public.meta_outbox set status = 'queued', attempts = 0, next_try_at = now(), last_error = null where id = p_id and business_id = p_business_id and status = 'failed';
  else raise exception 'BAD_KIND'; end if;
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'NOT_RETRYABLE'; end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data) values (p_business_id, auth.uid(), 'failed_work_retried', p_kind, p_id, jsonb_build_object('kind', p_kind));
  return 'queued';
end $function$
;
CREATE OR REPLACE FUNCTION public.zella_review_add(p_business_id uuid, p_site text, p_author text, p_rating integer, p_body text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid;
begin
  if auth.uid() is null or not public.zella_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'INVALID_RATING'; end if;
  if length(trim(coalesce(p_body, ''))) > 5000 then raise exception 'REVIEW_TOO_LONG'; end if;
  if (select count(*) from public.reviews where business_id = p_business_id and provider = 'manual' and created_at > now() - interval '1 day') >= 50 then
    raise exception 'TOO_MANY_REVIEWS';
  end if;
  insert into public.reviews (business_id, provider, external_id, site, author_name, rating, body)
  values (p_business_id, 'manual', gen_random_uuid()::text, nullif(trim(left(coalesce(p_site, ''), 40)), ''), nullif(trim(left(coalesce(p_author, ''), 120)), ''),
          p_rating, nullif(trim(p_body), ''))
  returning id into v_id;
  return v_id;
end $function$
;
