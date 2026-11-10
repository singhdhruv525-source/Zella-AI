-- Zella - call intelligence. Safe to run more than once.
-- Needs zella_run_all.sql (zella_create_task, zella_notify_owners, calls) and zella_inbound_calls.sql.
-- After a call ends, an AI reads the transcript in the background and suggests: what the caller wanted (intent), mood, urgency, a short summary,
-- details they gave (name, email, service, preferred time) and anything still unresolved.
-- The AI only SUGGESTS. The database checks every field, and the only things done automatically are:
--   * tasks for the team for unresolved requests (plus an urgent alert if the call sounded like an emergency)
--   * the call's own summary, when it has none
-- Customer records are never changed by the AI: staff accept a suggestion (blank fields only) or dismiss it.
-- The AI run is OFF until call_intel_live is true. The AI box in n8n ships with no key; add it by hand at go-live.

insert into public.platform_settings (key, value) values ('call_intel_live', 'false'::jsonb) on conflict (key) do nothing;
insert into public.platform_settings (key, value) values ('call_intel_model', '"claude-haiku-5-5"'::jsonb) on conflict (key) do nothing;
insert into public.platform_settings (key, value) values ('call_intel_monthly_limit', '300'::jsonb) on conflict (key) do nothing;

create table if not exists public.call_insights (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  call_id uuid not null unique references public.calls(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'processing', 'done', 'failed', 'skipped')),
  attempts integer not null default 0,
  claimed_at timestamptz,
  intent text,
  sentiment text,
  urgency text,
  summary text,
  details jsonb not null default '{}'::jsonb,
  unresolved jsonb not null default '[]'::jsonb,
  model text,
  error text,
  review_status text not null default 'new' check (review_status in ('new', 'accepted', 'dismissed')),
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  processed_at timestamptz
);
create index if not exists call_insights_work_idx on public.call_insights (status, created_at) where status in ('pending', 'processing');
create index if not exists call_insights_business_idx on public.call_insights (business_id, created_at desc);
alter table public.call_insights enable row level security;
drop policy if exists call_insights_read on public.call_insights;
create policy call_insights_read on public.call_insights for select to authenticated using (public.zella_is_member(business_id));
revoke all on public.call_insights from anon;
revoke insert, update, delete on public.call_insights from authenticated;

-- A finished call with a real transcript waits in the queue (nothing is sent anywhere until call_intel_live is on).
create or replace function public.zella_call_insight_queue_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.ended_at is not null and length(coalesce(new.transcript, '')) >= 60 and new.business_id is not null then
    insert into public.call_insights (business_id, call_id) values (new.business_id, new.id) on conflict (call_id) do nothing;
  end if;
  return new;
exception when others then
  return new;
end $$;
drop trigger if exists zella_call_insight_queue on public.calls;
create trigger zella_call_insight_queue after insert or update of transcript, ended_at on public.calls
  for each row execute function public.zella_call_insight_queue_trg();

-- n8n claims calls to read. Claims nothing unless live. A business over its monthly limit is skipped, never billed further.
create or replace function public.zella_claim_call_insights(p_limit integer default 5)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_live boolean := coalesce(public.zella_setting('call_intel_live', 'false'::jsonb) = 'true'::jsonb, false);
  v_model text := coalesce(nullif(trim(public.zella_setting('call_intel_model', '"claude-haiku-5-5"'::jsonb) #>> '{}'), ''), 'claude-haiku-5-5');
  v_limit integer := coalesce((public.zella_setting('call_intel_monthly_limit', '300'::jsonb) #>> '{}')::integer, 300);
  v_res jsonb := '[]'::jsonb; r record; v_used integer; v_ind text;
begin
  if not v_live then return v_res; end if;
  -- a run that never came back is retried (attempts are counted when claimed)
  update public.call_insights set status = 'pending' where status = 'processing' and claimed_at < now() - interval '15 minutes';
  update public.call_insights set status = 'failed', error = 'Gave up after 3 tries.' where status = 'pending' and attempts >= 3;
  for r in select i.id, i.call_id, i.business_id from public.call_insights i
            where i.status = 'pending' and i.attempts < 3 order by i.created_at limit greatest(1, least(coalesce(p_limit, 5), 20)) for update skip locked loop
    select count(*) into v_used from public.call_insights x where x.business_id = r.business_id and x.status in ('processing', 'done') and x.claimed_at >= date_trunc('month', now());
    if v_used >= v_limit then
      update public.call_insights set status = 'skipped', error = 'Monthly limit reached.' where id = r.id;
      continue;
    end if;
    if not exists (select 1 from public.businesses b where b.id = r.business_id and b.suspended_at is null and b.cancelled_at is null) then
      update public.call_insights set status = 'skipped', error = 'Business not active.' where id = r.id;
      continue;
    end if;
    update public.call_insights set status = 'processing', claimed_at = now(), attempts = attempts + 1, model = v_model where id = r.id;
    select ind.name into v_ind from public.businesses b left join public.industries ind on ind.id = b.industry_id where b.id = r.business_id;
    v_res := v_res || jsonb_build_array((
      select jsonb_build_object('call_id', c.id, 'model', v_model, 'business', jsonb_build_object('id', b.id, 'name', b.name, 'industry', v_ind),
               'transcript', left(c.transcript, 12000), 'summary', left(coalesce(c.summary, ''), 600), 'direction', c.direction, 'caller_known', c.customer_id is not null)
        from public.calls c join public.businesses b on b.id = c.business_id where c.id = r.call_id));
  end loop;
  return v_res;
end $$;
revoke execute on function public.zella_claim_call_insights(integer) from public, anon, authenticated;
grant execute on function public.zella_claim_call_insights(integer) to service_role;

-- n8n gives the AI's answer back. Everything is checked here; anything unexpected is dropped, never trusted.
create or replace function public.zella_save_call_insight(p_call_id uuid, p_result jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  i public.call_insights; c public.calls; v_in jsonb := case when jsonb_typeof(p_result) = 'object' then p_result else null end;
  v_intent text; v_sent text; v_urg text; v_sum text; v_det jsonb := '{}'::jsonb; v_unres jsonb := '[]'::jsonb; x jsonb; k text; v text; v_kind text; v_txt text; v_prio text; n integer := 0; v_tasks integer := 0;
begin
  select * into i from public.call_insights where call_id = p_call_id for update;
  if i.id is null or i.status <> 'processing' then return jsonb_build_object('saved', false, 'reason', 'not_waiting'); end if;
  if v_in is null then
    update public.call_insights set status = case when attempts >= 3 then 'failed' else 'pending' end, error = 'Unreadable answer.' where id = i.id;
    return jsonb_build_object('saved', false, 'reason', 'unreadable');
  end if;
  v_intent := case when v_in ->> 'intent' in ('book_appointment', 'reschedule', 'cancel', 'question', 'quote_request', 'complaint', 'callback_request', 'message', 'emergency', 'sales_lead', 'other') then v_in ->> 'intent' else 'other' end;
  v_sent := case when v_in ->> 'sentiment' in ('positive', 'neutral', 'negative') then v_in ->> 'sentiment' else 'neutral' end;
  v_urg := case when v_in ->> 'urgency' in ('low', 'normal', 'high') then v_in ->> 'urgency' else 'normal' end;
  v_sum := nullif(left(regexp_replace(trim(coalesce(v_in ->> 'summary', '')), '\s+', ' ', 'g'), 600), '');
  if jsonb_typeof(v_in -> 'details') = 'object' then
    foreach k in array array['name', 'email', 'phone', 'service', 'preferred_time'] loop
      v := nullif(left(regexp_replace(trim(coalesce(v_in -> 'details' ->> k, '')), '\s+', ' ', 'g'), 120), '');
      if v is null then continue; end if;
      if k = 'email' and v !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then continue; end if;
      if k = 'phone' and public.zella_digits(v) is null then continue; end if;
      v_det := v_det || jsonb_build_object(k, v);
    end loop;
  end if;
  if jsonb_typeof(v_in -> 'unresolved') = 'array' then
    for x in select * from jsonb_array_elements(v_in -> 'unresolved') limit 5 loop
      v_txt := nullif(left(regexp_replace(trim(coalesce(x ->> 'text', '')), '\s+', ' ', 'g'), 200), '');
      v_kind := case when x ->> 'kind' in ('callback', 'question', 'quote', 'complaint', 'other') then x ->> 'kind' else 'other' end;
      if v_txt is not null then v_unres := v_unres || jsonb_build_array(jsonb_build_object('kind', v_kind, 'text', v_txt)); end if;
    end loop;
  end if;

  update public.call_insights set status = 'done', intent = v_intent, sentiment = v_sent, urgency = v_urg, summary = v_sum, details = v_det, unresolved = v_unres,
         error = null, processed_at = now() where id = i.id;

  select * into c from public.calls where id = p_call_id;
  if v_sum is not null and nullif(c.summary, '') is null then update public.calls set summary = v_sum where id = p_call_id; end if;

  -- the team hears about what is still open (one task per item, never twice for the same call)
  for x in select * from jsonb_array_elements(v_unres) loop
    -- a callback the wrap-up already created is not created again
    if x ->> 'kind' = 'callback' and c.outcome in ('callback_needed', 'left_message') then continue; end if;
    v_prio := case when x ->> 'kind' = 'complaint' or v_urg = 'high' or v_intent in ('complaint', 'emergency') then 'high' else 'normal' end;
    if not exists (select 1 from public.crm_tasks t where t.business_id = i.business_id and t.entity_id = p_call_id and t.source = 'ai' and t.title = 'Call follow-up: ' || left(x ->> 'text', 80)) then
      perform public.zella_create_task(i.business_id, c.customer_id, 'follow_up', 'Call follow-up: ' || left(x ->> 'text', 80), x ->> 'text', v_prio,
                                       now() + case when v_prio = 'high' then interval '2 hours' else interval '1 day' end, null, 'ai', p_call_id);
      v_tasks := v_tasks + 1;
    end if;
  end loop;
  if v_intent = 'emergency' then
    perform public.zella_notify_owners(i.business_id, 'call_insight', 'A call sounded like an emergency', coalesce(v_sum, 'Check the call.'), 'urgent', 'calls');
  end if;
  return jsonb_build_object('saved', true, 'tasks', v_tasks);
end $$;
revoke execute on function public.zella_save_call_insight(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.zella_save_call_insight(uuid, jsonb) to service_role;

create or replace function public.zella_fail_call_insight(p_call_id uuid, p_error text)
returns void language sql security definer set search_path = public as $$
  update public.call_insights set status = case when attempts >= 3 then 'failed' else 'pending' end, error = left(coalesce(p_error, 'AI error'), 300)
   where call_id = p_call_id and status = 'processing';
$$;
revoke execute on function public.zella_fail_call_insight(uuid, text) from public, anon, authenticated;
grant execute on function public.zella_fail_call_insight(uuid, text) to service_role;

-- Staff: see the suggestions for a business.
create or replace function public.zella_call_insights_list(p_business_id uuid, p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'call_id', i.call_id, 'intent', i.intent, 'sentiment', i.sentiment, 'urgency', i.urgency, 'summary', i.summary,
                     'details', i.details, 'unresolved', i.unresolved, 'review_status', i.review_status, 'processed_at', i.processed_at) order by i.processed_at desc)
                     from (select * from public.call_insights where business_id = p_business_id and status = 'done' order by processed_at desc limit greatest(1, least(coalesce(p_limit, 50), 200))) i), '[]'::jsonb);
end $$;
revoke execute on function public.zella_call_insights_list(uuid, integer) from public, anon;
grant execute on function public.zella_call_insights_list(uuid, integer) to authenticated, service_role;

-- Staff: accept (fills BLANK fields on the linked customer only) or dismiss a suggestion.
create or replace function public.zella_review_call_insight(p_insight_id uuid, p_action text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare i public.call_insights; c public.calls; v_name text; v_first text; v_last text; v_changed integer := 0;
begin
  select * into i from public.call_insights where id = p_insight_id for update;
  if i.id is null or not public.zella_is_member(i.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_action not in ('accept', 'dismiss') then raise exception 'BAD_ACTION'; end if;
  if i.review_status <> 'new' then return jsonb_build_object('ok', true, 'status', i.review_status); end if;
  if p_action = 'accept' then
    select * into c from public.calls where id = i.call_id;
    if c.customer_id is not null then
      v_name := nullif(i.details ->> 'name', '');
      v_first := nullif(split_part(coalesce(v_name, ''), ' ', 1), '');
      v_last := nullif(trim(substr(coalesce(v_name, ''), length(coalesce(v_first, '')) + 1)), '');
      update public.customers set
             first_name = case when nullif(first_name, '') is null then coalesce(v_first, first_name) else first_name end,
             last_name = case when nullif(last_name, '') is null then coalesce(v_last, last_name) else last_name end,
             email = case when nullif(email, '') is null then coalesce(nullif(i.details ->> 'email', ''), email) else email end,
             updated_at = now()
       where id = c.customer_id and business_id = i.business_id;
      get diagnostics v_changed = row_count;
    end if;
  end if;
  update public.call_insights set review_status = case p_action when 'accept' then 'accepted' else 'dismissed' end, reviewed_by = auth.uid(), reviewed_at = now() where id = i.id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (i.business_id, auth.uid(), 'call_insight.' || p_action, 'call_insight', i.id, jsonb_build_object('customer_updated', v_changed > 0));
  return jsonb_build_object('ok', true, 'status', case p_action when 'accept' then 'accepted' else 'dismissed' end, 'customer_updated', v_changed > 0);
end $$;
revoke execute on function public.zella_review_call_insight(uuid, text) from public, anon;
grant execute on function public.zella_review_call_insight(uuid, text) to authenticated, service_role;
