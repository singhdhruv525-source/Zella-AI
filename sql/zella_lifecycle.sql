-- Zella - business lifecycle (checklist 301, 305, 308). Safe to run more than once. Run AFTER zella_run_all.sql.
--   308 owners are told when their account is paused or switched back on
--   305 a cancellation that was scheduled for a date takes effect on that date; owners get a reminder 3 days before;
--       when a business is cancelled, what must stop (automations, callbacks, follow-ups, reminders) stops, and every record is kept
--   301 setup steps stuck for over 30 minutes are marked failed, so they show up for an admin to retry
create or replace function public.zella_business_lifecycle_trigger() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.suspended_at is not null and old.suspended_at is null then
    perform public.zella_notify_owners(new.id, 'account_suspended', 'Your account is paused',
      coalesce('Reason: ' || left(new.suspension_reason, 200) || '. ', '') || 'Calls, texts and follow-ups are stopped. Your records are safe. Contact support to switch it back on.', 'urgent', 'home');
  elsif new.suspended_at is null and old.suspended_at is not null then
    perform public.zella_notify_owners(new.id, 'account_reactivated', 'Your account is back on', 'Automations are running again. Check Settings if anything looks off.', 'info', 'home');
  end if;
  if new.cancelled_at is not null and old.cancelled_at is null then
    update public.automations set status = 'paused', paused_by_suspension = true where business_id = new.id and status = 'active';
    update public.callbacks set status = 'needs_review', outcome = 'business_cancelled', auto_call = false, updated_at = now()
     where business_id = new.id and status in ('scheduled', 'retry_scheduled', 'due');
    update public.followup_tasks set status = 'cancelled', outcome = 'business_cancelled', completed_at = now(), updated_at = now() where business_id = new.id and status = 'pending';
    update public.appointment_reminders set status = 'cancelled', error = 'business_cancelled' where business_id = new.id and status = 'pending';
    perform public.zella_notify_owners(new.id, 'account_cancelled', 'Your account is cancelled',
      'Everything is stopped. Your records are kept until ' || to_char(coalesce(new.retention_until, now() + interval '90 days'), 'Mon DD, YYYY') || ' so you can ask for an export or come back.', 'warning', 'home');
    perform public.zella_platform_alert('business_cancelled', 'Business cancelled', new.cancellation_reason, 'info', new.id, to_char(new.cancelled_at, 'YYYY-MM-DD'));
  end if;
  return new;
end $$;
drop trigger if exists zella_business_lifecycle_trg on public.businesses;
create trigger zella_business_lifecycle_trg after update of suspended_at, cancelled_at on public.businesses for each row execute function public.zella_business_lifecycle_trigger();

-- daily
create or replace function public.zella_apply_scheduled_cancellations() returns integer
language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0;
begin
  for r in select id, cancel_at from public.businesses where cancelled_at is null and cancel_at is not null and cancel_at <= now() loop
    update public.businesses set cancelled_at = now(), is_active = false, updated_at = now() where id = r.id and cancelled_at is null;
    n := n + 1;
  end loop;
  for r in select id, cancel_at from public.businesses
            where cancelled_at is null and cancel_at is not null and cancel_at > now() and cancel_at <= now() + interval '3 days'
              and not exists (select 1 from public.staff_notifications s where s.business_id = businesses.id and s.kind = 'cancellation_coming' and s.created_at > now() - interval '3 days') loop
    perform public.zella_notify_owners(r.id, 'cancellation_coming', 'Your account will be cancelled on ' || to_char(r.cancel_at, 'Mon DD'),
      'Changed your mind? Open Settings and keep your plan before then.', 'warning', 'settings');
  end loop;
  return n;
end $$;
revoke all on function public.zella_apply_scheduled_cancellations() from public, anon, authenticated;
grant execute on function public.zella_apply_scheduled_cancellations() to service_role;

-- hourly
create or replace function public.zella_recover_provisioning() returns integer
language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0;
begin
  for r in select business_id, step from public.provisioning_steps where status = 'pending' and updated_at < now() - interval '30 minutes' loop
    perform public.zella_track_provisioning(r.business_id, r.step, 'failed', 'Stuck for over 30 minutes');
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.zella_recover_provisioning() from public, anon, authenticated;
grant execute on function public.zella_recover_provisioning() to service_role;
