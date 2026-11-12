-- Synthetic local fixtures only. No provider calls; roll back all email settings and claims.
\set ON_ERROR_STOP on
begin;
insert into auth.users (id, email, email_confirmed_at) values ('fb000000-0000-0000-0000-000000000001', 'admin@example.test', now());
insert into auth.identities (user_id, provider, email, identity_data) values
 ('fb000000-0000-0000-0000-000000000001', 'email', 'admin@example.test', '{"email":"admin@example.test","email_verified":true}');
insert into public.platform_admins (user_id, role) values ('fb000000-0000-0000-0000-000000000001', 'zella_owner');
insert into public.platform_settings (key, value) values ('email_live', 'true'), ('email_from_address', '"sender@example.test"')
on conflict (key) do update set value = excluded.value;
-- Discard the synthetic admin-granted alert before testing the exact claim set.
delete from public.platform_alerts;
insert into public.platform_alerts (kind, title, dedupe_key, notified_at, meta) values
 ('workflow_failed', 'Fresh workflow failure', 'fresh', null, '{}'),
 ('workflow_failed', 'Stale workflow failure', 'stale', now() - interval '20 minutes', '{"email_claimed_at": "2026-01-01"}'),
 ('test_other', 'Fresh other alert', 'fresh', null, '{}'),
 ('test_other', 'Stale other alert', 'stale', now() - interval '20 minutes', '{"email_claimed_at": "2026-01-01"}'),
 ('test_other', 'Already emailed', 'sent', now() - interval '20 minutes', '{"email_claimed_at": "2026-01-01", "emailed_at": "2026-01-01"}'),
 ('test_other', 'Retries exhausted', 'exhausted', now() - interval '20 minutes', '{"email_claimed_at": "2026-01-01", "email_attempts": 2}');
do $$ declare result jsonb; begin
  result := public.zella_claim_admin_alert_email(1);
  assert jsonb_array_length(result -> 'alerts') = 1, 'claim limit is honored';
  assert result -> 'alerts' -> 0 ->> 'kind' = 'test_other', 'workflow failures must not be emailed';
  result := public.zella_claim_admin_alert_email(25);
  assert jsonb_array_length(result -> 'alerts') = 1, 'remaining eligible other alert is claimed';
  assert result -> 'alerts' -> 0 ->> 'kind' = 'test_other';
  assert (select notified_at is null from public.platform_alerts where kind = 'workflow_failed' and dedupe_key = 'fresh');
  assert (select notified_at = now() - interval '20 minutes' from public.platform_alerts where kind = 'workflow_failed' and dedupe_key = 'stale');
  assert (select (meta ->> 'email_attempts')::int = 1 from public.platform_alerts where kind = 'test_other' and dedupe_key = 'stale'), 'stale claim retries increment as before';
  assert jsonb_array_length(public.zella_claim_admin_alert_email(25) -> 'alerts') = 0, 'no immediate reclaim or exhausted/sent alerts';
end $$;
select 'PASS workflow failures stay in dashboard; other claims, limit and retries preserved';
rollback;
