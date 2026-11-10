CREATE OR REPLACE FUNCTION public.zella_business_open(p_business_id uuid, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tz text; v_local timestamp; v_day date; v_dow smallint; v_t time;
  v_clo record; v_open boolean; v_next timestamptz; d integer; v_first time;
begin
  select coalesce(timezone, 'America/New_York') into v_tz from public.businesses where id = p_business_id;
  if v_tz is null then return jsonb_build_object('open', true, 'reason', 'no_hours_set'); end if;
  v_local := p_at at time zone v_tz; v_day := v_local::date; v_dow := extract(dow from v_local)::smallint; v_t := v_local::time;

  select * into v_clo from public.business_closures c
   where c.business_id = p_business_id and v_day between c.starts_on and c.ends_on order by (c.opens is null) desc limit 1;
  if found then
    v_open := v_clo.opens is not null and v_t >= v_clo.opens and v_t < v_clo.closes;
    if v_open then return jsonb_build_object('open', true, 'reason', 'open', 'label', v_clo.label); end if;
    v_next := null;
    for d in 1..60 loop
      if exists (select 1 from public.business_closures c where c.business_id = p_business_id and (v_day + d) between c.starts_on and c.ends_on and c.opens is null) then continue; end if;
      select min(h.opens) into v_first from public.business_hours h where h.business_id = p_business_id and h.weekday = extract(dow from (v_day + d))::smallint;
      if v_first is not null then v_next := ((v_day + d) + v_first) at time zone v_tz; exit; end if;
    end loop;
    return jsonb_build_object('open', false, 'reason', 'holiday', 'label', v_clo.label, 'next_open', v_next);
  end if;

  if not exists (select 1 from public.business_hours h where h.business_id = p_business_id) then
    return jsonb_build_object('open', true, 'reason', 'no_hours_set');
  end if;
  if exists (select 1 from public.business_hours h where h.business_id = p_business_id and h.weekday = v_dow and v_t >= h.opens and v_t < h.closes) then
    return jsonb_build_object('open', true, 'reason', 'open');
  end if;

  select min(h.opens) into v_first from public.business_hours h where h.business_id = p_business_id and h.weekday = v_dow and h.opens > v_t;
  if v_first is not null then
    v_next := (v_day + v_first) at time zone v_tz;
  else
    for d in 1..60 loop
      if exists (select 1 from public.business_closures c where c.business_id = p_business_id and (v_day + d) between c.starts_on and c.ends_on and c.opens is null) then continue; end if;
      select min(h.opens) into v_first from public.business_hours h where h.business_id = p_business_id and h.weekday = extract(dow from (v_day + d))::smallint;
      if v_first is not null then v_next := ((v_day + d) + v_first) at time zone v_tz; exit; end if;
    end loop;
  end if;
  return jsonb_build_object('open', false, 'reason', 'closed_hours', 'next_open', v_next);
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
