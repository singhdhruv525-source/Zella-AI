-- Zella Voice: usage alert emails, the billing emails that need no Stripe event (docs/BILLING_EMAILS.md F1, F2;
-- owner, 16 Nov 2026: build both sets now, held until email and payments are live), built switched off.
--   - Each minutes threshold event the usage rules already record (usage_threshold_events, once per period and
--     threshold) decides one billing notice: F1 at 80% (minutes used, included, days left), F2 at 100% (the business's
--     pay as you go rate and monthly limit). Only while payments_live is true; the platform outbox then holds the email
--     itself until email_live is on. A fact the email needs and the business doesn't have (no rate or no limit set)
--     holds that notice for a person (the worker renders strictly); nothing is invented.
-- Rollback: sql/rollback/zella_stripe_usage_emails_rollback.sql. Tests: tests/stripe_usage_emails/run.sh.
begin;

do $$
declare s text;
  owned constant jsonb := '{
    "public.zella_billing_usage_email_trg()": "d7655706d1a394d07f654b5f3c1f7333"
  }';
begin
  if to_regprocedure('public.zella_billing_email(uuid,text,text,text,jsonb)') is null or to_regprocedure('public.zella_onboarding_payment_passed(uuid)') is null then
    raise exception 'VERSION_MISMATCH: needs zella_stripe_emails.sql and zella_stripe_payment_gate.sql';
  end if;
  for s in select jsonb_object_keys(owned) loop
    if to_regprocedure(s) is not null and md5(pg_get_functiondef(s::regprocedure)) <> owned ->> s then
      raise exception 'VERSION_MISMATCH: % is not the version this file makes', s;
    end if;
  end loop;
end $$;

create or replace function public.zella_billing_usage_email_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_pct int := nullif(split_part(new.threshold_key, ':pct:', 2), '')::int; p public.business_plans; u public.business_usage_preferences; v_end timestamptz;
begin
  if new.resource <> 'minutes' or v_pct is null or not public.zella_payments_live() then return null; end if;
  begin   -- never fails the usage entry that recorded the threshold
    -- the plan the usage's period is billed on (its bound version), never a newer version saved since; no period found:
    -- no rate, so the F2 notice is held for a person rather than quoting a guess
    select bp.* into p from public.billing_periods per join public.business_plans bp on bp.id = per.business_plan_id
     where per.business_id = new.business_id and per.period_start <= now() and now() < per.period_end order by per.period_start desc limit 1;
    select * into u from public.business_usage_preferences where business_id = new.business_id;
    select current_period_end into v_end from public.subscriptions where business_id = new.business_id;
    if v_pct >= 100 then
      perform public.zella_billing_email(new.business_id, 'F2', new.business_id::text || ':' || new.period_key, '100', jsonb_strip_nulls(jsonb_build_object(
        'rate', public.zella_usd_text(p.overage_cents_per_minute), 'limit', public.zella_usd_text(u.spend_limit_cents))));
    elsif v_pct >= 80 then
      perform public.zella_billing_email(new.business_id, 'F1', new.business_id::text || ':' || new.period_key, v_pct::text, jsonb_strip_nulls(jsonb_build_object(
        'minutesUsed', floor(new.usage_minutes)::int, 'minutesIncluded', floor(new.limit_minutes)::int,
        'daysLeft', case when v_end is not null then greatest(0, ceil(extract(epoch from v_end - now()) / 86400))::int end)));
    end if;
  exception when others then
    perform public.zella_platform_alert('billing_email_failed', 'A usage email could not be decided', left(sqlerrm, 200), 'info', new.business_id, 'usage_email');
  end;
  return null;
end $$;
drop trigger if exists zella_billing_usage_email on public.usage_threshold_events;
create trigger zella_billing_usage_email after insert on public.usage_threshold_events for each row execute function public.zella_billing_usage_email_trg();
revoke execute on function public.zella_billing_usage_email_trg() from public, anon, authenticated;

commit;
