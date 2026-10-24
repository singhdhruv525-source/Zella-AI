-- Zella - operations automation. Safe to run more than once.
-- Needs zella_knowledge.sql and zella_website_crawler.sql (knowledge_versions) first.
--   1. AI assistant settings: go back to an earlier version, and see what a new version changes.
--   2. Knowledge rollback: an older wording of an answer can be brought back (as a draft that must be approved again).
--   3. Spot checks of AI calls, and "this answer was wrong" reports that turn into a draft correction.
--   4. A short daily summary for each team member.
--   5. A daily reconciliation that finds work that got stuck and tells the owner.

-- 1. Settings versions: saving, checking and publishing versions already exists (zella_workflows.sql). This adds
--    "go back to version N" (a copy of the old version is checked and published as a new version, so history is kept)
--    and "what changed" (the fields that differ from the version that is live).
create or replace function public.zella_rollback_agent_config(p_version_id uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare v public.agent_config_versions%rowtype; v_new uuid; v_errs jsonb; v_ver integer;
begin
  select * into v from public.agent_config_versions where id = p_version_id;
  if not found or not public.zella_can_manage(v.business_id) then raise exception 'NOT_ALLOWED'; end if;
  v_new := public.zella_save_agent_config_draft(v.agent_id, v.config);
  v_errs := public.zella_validate_agent_config(v_new);
  if jsonb_array_length(v_errs) > 0 then raise exception 'OLD_VERSION_NOT_VALID_ANY_MORE'; end if;
  v_ver := public.zella_publish_agent_config(v_new);
  return v_ver;
end $$;

create or replace function public.zella_agent_config_changes(p_version_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v public.agent_config_versions%rowtype; live jsonb; k text; r jsonb := '[]'::jsonb;
begin
  select * into v from public.agent_config_versions where id = p_version_id;
  if not found or not public.zella_can_manage(v.business_id) then raise exception 'NOT_ALLOWED'; end if;
  select config into live from public.agent_config_versions where agent_id = v.agent_id and status = 'published' and id <> v.id order by version desc limit 1;
  for k in select distinct key from (select jsonb_object_keys(v.config) key union select jsonb_object_keys(coalesce(live, '{}'::jsonb))) x loop
    if (v.config -> k) is distinct from (live -> k) then r := r || jsonb_build_array(jsonb_build_object('field', k, 'was', live -> k, 'now', v.config -> k)); end if;
  end loop;
  return r;
end $$;
revoke execute on function public.zella_rollback_agent_config(uuid), public.zella_agent_config_changes(uuid) from public, anon;
grant execute on function public.zella_rollback_agent_config(uuid), public.zella_agent_config_changes(uuid) to authenticated, service_role;

-- 2. Bring back an earlier wording of a knowledge answer. A person asking for it counts as approving it; it goes through the
--    normal checks again before the assistant uses it.
create or replace function public.zella_knowledge_rollback(p_item_id uuid, p_version integer) returns boolean
language plpgsql security definer set search_path = public as $$
declare k public.knowledge_items%rowtype; v public.knowledge_versions%rowtype;
begin
  select * into k from public.knowledge_items where id = p_item_id;
  if not found or not public.zella_has_role(k.business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  select * into v from public.knowledge_versions where item_id = k.id and version = p_version order by created_at desc limit 1;
  if not found then raise exception 'NO_SUCH_VERSION'; end if;
  update public.knowledge_items set title = v.title, question = v.question, answer = v.answer where id = k.id;
  return true;
end $$;

-- 3. Spot checks and "this answer was wrong" reports ------------------------------------------------------------
insert into public.platform_settings (key, value) values ('response_sample_rate', '0.1'::jsonb) on conflict (key) do nothing;
insert into public.platform_settings (key, value) values ('team_summary_hour', '8'::jsonb) on conflict (key) do nothing;

create table if not exists public.ai_response_samples (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  call_id uuid not null references public.calls(id) on delete cascade,
  verdict text check (verdict in ('good', 'bad')),
  note text, reviewed_by uuid, reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (call_id)
);
create table if not exists public.ai_answer_reports (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  call_id uuid references public.calls(id) on delete set null,
  reported_by uuid,
  what_was_wrong text not null, correct_answer text,
  status text not null default 'open' check (status in ('open', 'fixed', 'dismissed')),
  knowledge_item_id uuid references public.knowledge_items(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists ai_answer_reports_biz_idx on public.ai_answer_reports (business_id, status, created_at desc);
alter table public.ai_response_samples enable row level security;
alter table public.ai_answer_reports enable row level security;
drop policy if exists ai_response_samples_read on public.ai_response_samples;
create policy ai_response_samples_read on public.ai_response_samples for select to authenticated using (public.zella_is_member(business_id));
drop policy if exists ai_answer_reports_read on public.ai_answer_reports;
create policy ai_answer_reports_read on public.ai_answer_reports for select to authenticated using (public.zella_is_member(business_id));
grant select on public.ai_response_samples, public.ai_answer_reports to authenticated;

-- Daily: pick a few of yesterday's AI calls for the owner to listen to.
create or replace function public.zella_sample_ai_responses() returns integer
language plpgsql security definer set search_path = public as $$
declare b record; v_rate numeric := coalesce(nullif(public.zella_setting('response_sample_rate', '0.1'::jsonb) #>> '{}', '')::numeric, 0.1); v_added integer := 0; v_n integer;
begin
  for b in select c.business_id, count(*) n from public.calls c join public.businesses bz on bz.id = c.business_id and bz.suspended_at is null and bz.cancelled_at is null
            where c.ai_handled and c.created_at > now() - interval '24 hours' and (c.summary is not null or c.transcript is not null)
              and not exists (select 1 from public.ai_response_samples s where s.call_id = c.id) group by c.business_id loop
    with pick as (
      select c.id from public.calls c
       where c.business_id = b.business_id and c.ai_handled and c.created_at > now() - interval '24 hours' and (c.summary is not null or c.transcript is not null)
         and not exists (select 1 from public.ai_response_samples s where s.call_id = c.id)
       order by random() limit least(3, greatest(1, ceil(b.n * v_rate))))
    insert into public.ai_response_samples (business_id, call_id) select b.business_id, id from pick on conflict (call_id) do nothing;
    get diagnostics v_n = row_count;
    v_added := v_added + v_n;
    if v_n > 0 and not exists (select 1 from public.staff_notifications s where s.business_id = b.business_id and s.kind = 'spot_check' and s.created_at > now() - interval '20 hours') then
      perform public.zella_notify_owners(b.business_id, 'spot_check', v_n || ' AI call' || case when v_n = 1 then '' else 's' end || ' to spot-check',
        'Listen to a few calls your AI receptionist handled and mark them good or wrong. It helps keep answers accurate.', 'info', 'calls');
    end if;
  end loop;
  return v_added;
end $$;

create or replace function public.zella_report_incorrect_answer(p_business_id uuid, p_call_id uuid, p_what_was_wrong text, p_correct_answer text default null) returns uuid
language plpgsql security definer set search_path = public as $$
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
end $$;

create or replace function public.zella_review_sample(p_sample_id uuid, p_verdict text, p_note text default null) returns boolean
language plpgsql security definer set search_path = public as $$
declare s public.ai_response_samples%rowtype;
begin
  select * into s from public.ai_response_samples where id = p_sample_id;
  if not found or not public.zella_has_role(s.business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  if p_verdict not in ('good', 'bad') then raise exception 'BAD_VERDICT'; end if;
  update public.ai_response_samples set verdict = p_verdict, note = left(p_note, 500), reviewed_by = auth.uid(), reviewed_at = now() where id = s.id;
  if p_verdict = 'bad' then
    insert into public.ai_answer_reports (business_id, call_id, reported_by, what_was_wrong) values (s.business_id, s.call_id, auth.uid(), coalesce(nullif(left(trim(p_note), 500), ''), 'Marked wrong in a spot check'));
  end if;
  return true;
end $$;

create or replace function public.zella_resolve_answer_report(p_report_id uuid, p_fixed boolean) returns boolean
language plpgsql security definer set search_path = public as $$
declare r public.ai_answer_reports%rowtype;
begin
  select * into r from public.ai_answer_reports where id = p_report_id;
  if not found or not public.zella_has_role(r.business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  update public.ai_answer_reports set status = case when p_fixed then 'fixed' else 'dismissed' end where id = r.id;
  return true;
end $$;

-- 4. A short summary for each team member, once a morning (their business's local time) -----------------------------
create or replace function public.zella_post_team_summaries() returns integer
language plpgsql security definer set search_path = public as $$
declare m record; v_hour integer := coalesce(nullif(public.zella_setting('team_summary_hour', '8'::jsonb) #>> '{}', '')::integer, 8);
        v_start timestamptz; v_end timestamptz; a integer; c integer; e integer; v_first timestamptz; v_n integer := 0; v_body text; v_tz text;
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
end $$;

-- 5. Daily reconciliation: find work that got stuck, fix what is safe to fix, tell the owner about the rest -----------
create or replace function public.zella_reconcile() returns integer
language plpgsql security definer set search_path = public as $$
declare r record; v_found integer := 0; v_ids uuid[]; v_k text;
begin
  -- a. appointments that never reached the connected calendar are queued again
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

  -- b. texts and emails stuck in the queue
  for v_k in select unnest(array['sms', 'email']) loop
    v_ids := '{}';
    for r in execute format('select business_id, count(*) n from public.%I where direction = ''outbound'' and status = ''queued'' and created_at < now() - interval ''30 minutes'' group by business_id', case v_k when 'sms' then 'sms_messages' else 'email_messages' end) loop
      perform public.zella_platform_alert('reconcile_' || v_k || '_stuck', r.n || ' ' || v_k || ' messages are stuck in the queue', 'Queued for over 30 minutes. Check the ' || v_k || ' sending workflow and the live switch.', 'warning', r.business_id, 'daily');
      v_ids := v_ids || r.business_id; v_found := v_found + 1;
    end loop;
    update public.platform_alerts set status = 'resolved', resolved_at = now(), resolution_note = 'Queue is clear' where kind = 'reconcile_' || v_k || '_stuck' and status <> 'resolved' and not (business_id = any (v_ids));
  end loop;

  -- c. knowledge waiting to be processed for over an hour
  v_ids := '{}';
  for r in select business_id, count(*) n from public.knowledge_items where status = 'processing' and updated_at < now() - interval '1 hour' group by business_id loop
    perform public.zella_platform_alert('reconcile_knowledge_stuck', r.n || ' knowledge items are not getting published', 'Processing for over an hour. Check the Knowledge workflow.', 'warning', r.business_id, 'daily');
    v_ids := v_ids || r.business_id; v_found := v_found + 1;
  end loop;
  update public.platform_alerts set status = 'resolved', resolved_at = now(), resolution_note = 'Nothing waiting' where kind = 'reconcile_knowledge_stuck' and status <> 'resolved' and not (business_id = any (v_ids));

  -- d. past appointments that still have no outcome (completed or no-show): ask the owner, at most every 3 days
  for r in select a.business_id, count(*) n from public.appointments a join public.businesses b on b.id = a.business_id and b.suspended_at is null and b.cancelled_at is null
            where a.status in ('scheduled', 'confirmed') and coalesce(a.end_time, a.start_time) < now() - interval '1 day' group by a.business_id loop
    continue when exists (select 1 from public.staff_notifications s where s.business_id = r.business_id and s.kind = 'appointments_need_outcome' and s.created_at > now() - interval '3 days');
    perform public.zella_notify_owners(r.business_id, 'appointments_need_outcome', r.n || ' past appointment' || case when r.n = 1 then ' needs' else 's need' end || ' an outcome',
      'Mark them completed or no-show so reports and follow-ups are right.', 'info', 'appointments');
    v_found := v_found + 1;
  end loop;
  return v_found;
end $$;

do $$
declare f text;
begin
  foreach f in array array['zella_sample_ai_responses()', 'zella_post_team_summaries()', 'zella_reconcile()'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
  foreach f in array array['zella_report_incorrect_answer(uuid,uuid,text,text)', 'zella_review_sample(uuid,text,text)', 'zella_resolve_answer_report(uuid,boolean)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;
