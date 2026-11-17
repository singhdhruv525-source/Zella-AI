-- Zella - what customers ask that the assistant cannot answer (checklist 167, 168, 169, 170, 171). Safe to run more than once.
-- Needs zella_knowledge.sql and zella_knowledge_automation.sql.
--   171 a question asked 3+ times is flagged to owners once
--   167/168 a report of the top unanswered questions, and a weekly nudge to owners
--   170 two or more unanswered questions on one call hand the call to a person (a callback is created, the call is flagged)
--   169 knowledge is already isolated per business by row security (checked below by the tenant check)
alter table public.knowledge_gaps add column if not exists repeat_notified_at timestamptz;
alter table public.knowledge_gaps add column if not exists report_notified_at timestamptz;
insert into public.platform_settings (key, value) values ('knowledge_repeat_threshold', '3'::jsonb), ('ai_low_confidence_questions', '2'::jsonb) on conflict (key) do nothing;

create or replace function public.zella_detect_repeated_questions() returns integer
language plpgsql security definer set search_path = public as $$
declare g record; n integer := 0; v_min integer := greatest(2, coalesce((public.zella_setting('knowledge_repeat_threshold', '3'::jsonb) #>> '{}')::int, 3));
begin
  for g in select id, business_id, question, times_asked from public.knowledge_gaps
            where status = 'open' and times_asked >= v_min and repeat_notified_at is null for update skip locked loop
    perform public.zella_notify_owners(g.business_id, 'knowledge_repeat', 'Customers keep asking the same thing',
      '"' || left(g.question, 140) || '" was asked ' || g.times_asked || ' times. Add an answer so the assistant can reply.', 'warning', 'knowledge');
    update public.knowledge_gaps set repeat_notified_at = now() where id = g.id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.zella_detect_repeated_questions() from public, anon, authenticated;
grant execute on function public.zella_detect_repeated_questions() to service_role;

create or replace function public.zella_knowledge_gap_report(p_business_id uuid, p_days integer default 30)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d interval := make_interval(days => greatest(1, least(coalesce(p_days, 30), 365)));
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  return jsonb_build_object(
    'open_questions', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'question', question, 'times_asked', times_asked, 'last_asked_at', last_asked_at) order by times_asked desc, last_asked_at desc)
                                  from (select * from public.knowledge_gaps where business_id = p_business_id and status = 'open' order by times_asked desc, last_asked_at desc limit 10) t), '[]'::jsonb),
    'open_count', (select count(*) from public.knowledge_gaps where business_id = p_business_id and status = 'open'),
    'answered_count', (select count(*) from public.knowledge_gaps where business_id = p_business_id and status = 'answered' and resolved_at > now() - d),
    'dismissed_count', (select count(*) from public.knowledge_gaps where business_id = p_business_id and status = 'dismissed' and resolved_at > now() - d),
    'times_asked_total', coalesce((select sum(times_asked) from public.knowledge_gaps where business_id = p_business_id and last_asked_at > now() - d), 0));
end $$;
revoke execute on function public.zella_knowledge_gap_report(uuid, integer) from public, anon;
grant execute on function public.zella_knowledge_gap_report(uuid, integer) to authenticated, service_role;

create or replace function public.zella_send_gap_reports() returns integer
language plpgsql security definer set search_path = public as $$
declare b record; n integer := 0;
begin
  for b in select business_id, count(*) as open_count, max(question) filter (where times_asked = (select max(times_asked) from public.knowledge_gaps x where x.business_id = g.business_id and x.status = 'open')) as top
             from public.knowledge_gaps g where status = 'open' group by business_id loop
    continue when exists (select 1 from public.staff_notifications where business_id = b.business_id and kind = 'knowledge_report' and created_at > now() - interval '6 days');
    perform public.zella_notify_owners(b.business_id, 'knowledge_report', b.open_count || (case when b.open_count = 1 then ' question' else ' questions' end) || ' the assistant could not answer',
      'Most asked: "' || left(coalesce(b.top, ''), 120) || '". Open Knowledge to add answers.', 'info', 'knowledge');
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.zella_send_gap_reports() from public, anon, authenticated;
grant execute on function public.zella_send_gap_reports() to service_role;

do $$
declare d text; blk text;
begin
  d := pg_get_functiondef('public.zella_report_unanswered(text,uuid,text)'::regprocedure);
  if d not like '%low_confidence%' then
    blk := $b$  v_gap := public.zella_log_knowledge_gap(v_biz, v_q, v_call_id, v_cust);
  if v_call_id is not null and (select count(*) from public.knowledge_gaps g where g.call_id = v_call_id) >= greatest(2, coalesce((public.zella_setting('ai_low_confidence_questions', '2'::jsonb) #>> '{}')::int, 2))
     and exists (select 1 from public.calls c where c.id = v_call_id and not coalesce(c.needs_human, false)) then
    update public.calls set needs_human = true, escalation_reason = coalesce(escalation_reason, 'low_confidence'), escalated_at = coalesce(escalated_at, now()), updated_at = now() where id = v_call_id returning from_number into v_from;
    if public.zella_digits(v_from) is not null then
      perform public.zella_create_callback(v_biz, v_from, 'needs_human', 'normal', 'The assistant could not answer several questions on this call.', null, v_cust, v_call_id, null, 'ai', null);
    end if;
  end if;
  return v_gap;$b$;
    d := replace(d, 'declare v_call_id uuid;', 'declare v_gap uuid; v_from text; v_call_id uuid;');
    d := replace(d, '  return public.zella_log_knowledge_gap(v_biz, v_q, v_call_id, v_cust);', blk);
    if d not like '%low_confidence%' or d not like '%v_gap uuid%' then raise exception 'PATCH_FAILED_LOWCONF'; end if;
    execute d;
  end if;
end $$;
