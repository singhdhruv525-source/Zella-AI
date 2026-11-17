-- Zella - call integrity and recovery (checklist 2, 4, 6, 13, 180, 188). Safe to run more than once.
-- Run AFTER zella_run_all.sql, zella_knowledge.sql and zella_customer_touches.sql.
--   6   a call that connects for a moment and ends with nothing said is a missed call (callback follows from the existing trigger)
--   13  a call that ends because the assistant or phone system errored is handed to a person: urgent callback, and the platform is alerted
--   4   calls left open too long are closed, and calls that finished without a summary are flagged
--   2   the above are the decision rules for what happens to every call, in one place, on top of the call-result plan and voice rules
--   180 knowledge updates the assistant never confirmed are retried, then reported to the owner
--   188 a customer is told when staff move their appointment
insert into public.platform_settings (key, value) values ('missed_call_max_seconds', '6'::jsonb) on conflict (key) do nothing;
alter table public.knowledge_items add column if not exists sync_attempts integer not null default 0;

-- 6 and 13: look at every inbound call as it is written
create or replace function public.zella_call_integrity_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_reason text := lower(coalesce(new.metadata ->> 'ended_reason', '')); v_max integer := coalesce((public.zella_setting('missed_call_max_seconds', '6'::jsonb) #>> '{}')::int, 6);
begin
  if coalesce(new.direction, 'inbound') <> 'inbound' then return new; end if;
  -- ended almost at once with nothing said: nobody was helped
  if new.status in ('completed', 'answered') and new.ended_at is not null and coalesce(new.duration_seconds, 0) <= v_max
     and nullif(trim(coalesce(new.transcript, '')), '') is null and nullif(trim(coalesce(new.summary, '')), '') is null
     and not coalesce(new.needs_human, false) and v_reason !~ '(error|failed|exceeded)' then
    new.status := 'missed';
  end if;
  -- the assistant or phone system broke
  if v_reason ~ '(error|failed|exceeded)' and v_reason !~ '(customer|silence|voicemail|did-not-answer)'
     and coalesce(new.metadata ->> 'ai_failure_handled', '') = '' then
    new.needs_human := true;
    new.escalation_reason := coalesce(new.escalation_reason, 'The assistant could not finish this call properly.');
    new.metadata := coalesce(new.metadata, '{}'::jsonb) || jsonb_build_object('ai_failure_handled', true);
    perform public.zella_platform_alert('ai_call_failure', 'The assistant failed during a call', left(v_reason, 120), 'warning', new.business_id, to_char(now(), 'YYYY-MM-DD-HH24'));
  end if;
  return new;
exception when others then
  return new;
end $$;
drop trigger if exists zella_call_integrity on public.calls;
create trigger zella_call_integrity before insert or update on public.calls for each row execute function public.zella_call_integrity_trg();

-- 4: every 5 minutes close calls that never reported an end; hourly flag calls with no summary
create or replace function public.zella_sweep_open_calls() returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  update public.calls set status = case when status = 'answered' then 'completed' else 'missed' end, ended_at = coalesce(ended_at, now()),
         metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('closed_by_sweep', true)
   where coalesce(direction, 'inbound') = 'inbound' and status in ('initiated', 'ringing', 'answered')
     and coalesce(answered_at, started_at, created_at) < now() - interval '2 hours';
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.zella_sweep_open_calls() from public, anon, authenticated;
grant execute on function public.zella_sweep_open_calls() to service_role;

create or replace function public.zella_verify_calls() returns integer
language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0;
begin
  for r in select business_id, count(*) c from public.calls
            where coalesce(direction, 'inbound') = 'inbound' and status = 'completed' and ai_handled and coalesce(duration_seconds, 0) > 20
              and ended_at between now() - interval '24 hours' and now() - interval '30 minutes'
              and nullif(trim(coalesce(summary, '')), '') is null and coalesce(metadata ->> 'summary_flagged', '') = ''
            group by business_id loop
    perform public.zella_platform_alert('call_not_summarized', r.c || ' finished call(s) have no summary', 'The call-result workflow may be failing.', 'warning', r.business_id, to_char(now(), 'YYYY-MM-DD'));
    update public.calls set metadata = coalesce(metadata, '{}'::jsonb) || '{"summary_flagged": true}'::jsonb
     where business_id = r.business_id and coalesce(direction, 'inbound') = 'inbound' and status = 'completed' and ai_handled and coalesce(duration_seconds, 0) > 20
       and ended_at between now() - interval '24 hours' and now() - interval '30 minutes' and nullif(trim(coalesce(summary, '')), '') is null;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.zella_verify_calls() from public, anon, authenticated;
grant execute on function public.zella_verify_calls() to service_role;

-- 180: knowledge the assistant never confirmed
create or replace function public.zella_recover_knowledge() returns integer
language plpgsql security definer set search_path = public as $$
declare k record; n integer := 0;
begin
  for k in select id, business_id, title, sync_attempts from public.knowledge_items
            where status = 'processing' and updated_at < now() - interval '30 minutes' for update skip locked loop
    if k.sync_attempts >= 3 then
      update public.knowledge_items set status = 'failed', error = 'The assistant did not confirm this update after several tries.', updated_at = now() where id = k.id;
      perform public.zella_notify_owners(k.business_id, 'knowledge_failed', 'We could not update what your assistant knows',
        left(coalesce(k.title, 'One of your answers'), 100) || ' did not go through. Open Knowledge and try saving it again.', 'warning', 'knowledge');
    else
      update public.knowledge_items set sync_attempts = sync_attempts + 1, updated_at = now() where id = k.id;   -- stays 'processing' so the next sync picks it up
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.zella_recover_knowledge() from public, anon, authenticated;
grant execute on function public.zella_recover_knowledge() to service_role;

-- 188: staff moved an appointment -> tell the customer (customer-requested changes already send their own confirmation)
create or replace function public.zella_appointment_moved_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_tz text; v_when text;
begin
  if new.customer_id is null or new.status in ('cancelled', 'completed', 'no_show') or new.start_time is not distinct from old.start_time then return new; end if;
  if old.start_time <= now() or abs(extract(epoch from (new.start_time - old.start_time))) < 60 then return new; end if;
  if coalesce(new.reschedule_requested_by, '') in ('customer', 'ai') then return new; end if;
  -- a business that sends appointment confirmations already re-confirms the new time
  if exists (select 1 from public.automations x where x.business_id = new.business_id and x.trigger_type = 'appointment_confirmation' and x.status = 'active') then return new; end if;
  select coalesce(timezone, 'America/New_York') into v_tz from public.businesses where id = new.business_id;
  v_when := to_char(new.start_time at time zone coalesce(new.timezone, v_tz), 'FMDay, FMMon FMDD "at" FMHH12:MI AM');
  perform public.zella_queue_customer_message(new.business_id, new.customer_id, 'record_status_update',
    jsonb_build_object('status_line', 'Your appointment has been moved to ' || v_when || '. Reply here if that does not suit you.', 'status', 'moved', 'record_title', coalesce(new.title, 'appointment')),
    interval '1 minute', new.id, interval '0');
  return new;
exception when others then
  return new;
end $$;
drop trigger if exists zella_appointment_moved on public.appointments;
create trigger zella_appointment_moved after update of start_time on public.appointments for each row execute function public.zella_appointment_moved_trg();
