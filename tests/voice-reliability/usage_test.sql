-- Calling usage on the staging copy (live functions + production triggers + all migrations). Test fixtures only:
-- the plan and allowance below exist only in this throwaway database.
delete from usage_records; delete from usage_processing_issues; delete from usage_threshold_events; delete from usage_thresholds;
delete from subscriptions; delete from plans; delete from business_usage_preferences; delete from staff_notifications; delete from platform_alerts;
delete from audit_logs; delete from business_members; delete from platform_admins; delete from platform_role_permissions; delete from business_phone_numbers;
delete from platform_settings where key in ('call_usage_policy', 'call_usage_rules');
insert into platform_settings (key, value) values ('call_usage_policy', '{"increment_seconds": 1, "rounding": "up", "minimum_billable_seconds": 0, "ignore_under_seconds": 0}'),
  ('call_usage_rules', '{"counted_categories": ["inbound_ai", "outbound_ai"], "industries": {}}');
insert into business_phone_numbers (business_id, e164, vapi_phone_number_id) values ('aaaaaaaa-0000-4000-8000-000000000001', '+15550001000', 'pn-A'), ('bbbbbbbb-0000-4000-8000-000000000002', '+15550002000', 'pn-B');

do $$
declare A uuid := 'aaaaaaaa-0000-4000-8000-000000000001'; B uuid := 'bbbbbbbb-0000-4000-8000-000000000002';
        t0 timestamptz := now() - interval '3 hours'; r jsonb; n int; c1 uuid; c2 uuid; x uuid; u_a uuid := '11111111-0000-4000-8000-0000000000a1'; u_b uuid := '11111111-0000-4000-8000-0000000000b1';
        adm uuid := '22222222-0000-4000-8000-0000000000a9'; ro uuid := '22222222-0000-4000-8000-0000000000b9'; v numeric; p uuid; s uuid;
begin
  -- 1 + 4: the real path. "ended" arrives before the report: nothing counted yet; the report records exactly one usage row
  perform zella_record_call_status('u-1', 'in-progress', '+15550001000', 'pn-A', '+15551230001', 'inbound', t0, null);
  perform zella_record_call_status('u-1', 'ended', '+15550001000', 'pn-A', '+15551230001', 'inbound', t0 + interval '95 seconds', 'customer-ended-call');
  select id into c1 from calls where external_call_id = 'u-1';
  assert not exists (select 1 from usage_records where call_id = c1), 'counted before the report';
  perform zella_record_inbound_call('u-1', '+15550001000', 'pn-A', '+15551230001', t0, t0 + interval '95 seconds', 95, 'customer-ended-call', 'Asked about hours.', null, 'AI: hi', false);
  select count(*) into n from usage_records where call_id = c1;
  select quantity into v from usage_records where call_id = c1;
  assert n = 1 and v = 1.5833 and (select duration_seconds || '/' || billable_seconds || '/' || usage_category || '/' || period_source from usage_records where call_id = c1) = '95/95/inbound_ai/call', 'recorded';
  raise notice 'PASS 1+4 completed call: one usage row (95 s raw, 95 s billable, 1.5833 min, inbound_ai); nothing counted while the report was on the way';
  -- 2 + 4: the same report again, and a late status event: unchanged
  perform zella_record_inbound_call('u-1', '+15550001000', 'pn-A', '+15551230001', t0, t0 + interval '95 seconds', 95, 'customer-ended-call', 'Asked about hours.', null, 'AI: hi', false);
  perform zella_record_call_status('u-1', 'in-progress', '+15550001000', 'pn-A', '+15551230001', 'inbound', t0, null);
  assert zella_process_call_usage(c1, 'event') ->> 'result' = 'unchanged' and (select count(*) from usage_records where call_id = c1) = 1, 'duplicate';
  raise notice 'PASS 2+4 repeated report, late event and repeated processing: still one row';
  -- 3: a duplicate provider event id never adds a second row
  insert into calls (business_id, direction, status, external_call_id, from_number, started_at, answered_at, ended_at, duration_seconds, ai_handled)
  values (A, 'inbound', 'completed', 'u-3', '+15551230003', t0, t0, t0 + interval '30 seconds', null, true) returning id into c2;
  update calls set duration_seconds = 30 where id = c2;
  r := zella_process_call_usage(c2, 'event', 'evt-u3');
  assert (select count(*) from usage_records where call_id = c2) = 1 and zella_process_call_usage(c2, 'event', 'evt-u3') ->> 'result' = 'unchanged', 'event id';
  raise notice 'PASS 3 duplicate provider event: one row';
  -- 5: missing duration: never estimated; listed as an issue once the call is old enough
  insert into calls (business_id, direction, status, external_call_id, started_at, ended_at, duration_seconds, ai_handled)
  values (A, 'inbound', 'completed', 'u-5', now() - interval '10 hours', now() - interval '9 hours', null, true) returning id into x;
  assert not exists (select 1 from usage_records where call_id = x) and exists (select 1 from usage_processing_issues where call_id = x and kind = 'missing_duration' and status = 'open'), 'missing';
  raise notice 'PASS 5 missing duration: no usage row invented, issue opened';
  -- 6: invalid duration
  insert into calls (business_id, direction, status, external_call_id, started_at, ended_at, duration_seconds, ai_handled)
  values (A, 'inbound', 'completed', 'u-6', t0, t0 + interval '1 minute', 999999, true) returning id into x;
  assert not exists (select 1 from usage_records where call_id = x) and exists (select 1 from usage_processing_issues where call_id = x and kind = 'invalid_duration'), 'invalid';
  raise notice 'PASS 6 implausible duration (999999 s): not counted, issue opened';
  -- 7: missing call record
  assert zella_process_call_usage(gen_random_uuid()) ->> 'result' = 'not_found', 'not found';
  raise notice 'PASS 7 unknown call id: not_found, nothing written';
  -- 8 + 9: calculation and configurable rounding (the policy in force is kept on each row)
  assert zella_usage_billable_seconds(61, '{"increment_seconds": 60, "rounding": "up"}') = 120 and zella_usage_billable_seconds(61, '{"increment_seconds": 60, "rounding": "down"}') = 60
     and zella_usage_billable_seconds(91, '{"increment_seconds": 60, "rounding": "nearest"}') = 120 and zella_usage_billable_seconds(10, '{"increment_seconds": 1, "minimum_billable_seconds": 30}') = 30
     and zella_usage_billable_seconds(3, '{"increment_seconds": 1, "ignore_under_seconds": 5}') = 0 and zella_usage_billable_seconds(0, '{}') = 0 and zella_usage_billable_seconds(null, '{}') is null, 'calc';
  update platform_settings set value = '{"increment_seconds": 60, "rounding": "up", "minimum_billable_seconds": 0, "ignore_under_seconds": 0}' where key = 'call_usage_policy';
  insert into calls (business_id, direction, status, external_call_id, started_at, ended_at, duration_seconds, ai_handled)
  values (A, 'inbound', 'completed', 'u-9', t0, t0 + interval '61 seconds', 61, true) returning id into x;
  assert (select billable_seconds || '/' || quantity || '/' || (policy ->> 'increment_seconds') from usage_records where call_id = x) = '120/2.0000/60', 'policy';
  assert (select quantity from usage_records where call_id = c1) = 1.5833, 'old rows keep their policy';
  update platform_settings set value = '{"increment_seconds": 1, "rounding": "up", "minimum_billable_seconds": 0, "ignore_under_seconds": 0}' where key = 'call_usage_policy';
  raise notice 'PASS 8+9 calculation (up / down / nearest / minimum / ignore-under) and a policy change applies to new calls only (61 s -> 2 min at 60 s up; the earlier call keeps 1.5833)';
  -- 10: a later provider duration becomes an adjustment; the history stays
  update calls set duration_seconds = 120 where id = c1;
  select count(*) into n from usage_records where call_id = c1;
  assert n = 2 and (select duration_seconds || '/' || quantity || '/' || entry_kind from usage_records where call_id = c1 and entry_kind = 'adjustment') = '25/0.4167/adjustment'
     and (select duration_seconds from usage_records where call_id = c1 and entry_kind = 'usage') = 95 and (select reconciliation_status from usage_records where call_id = c1 and entry_kind = 'usage') = 'adjusted', 'adjust';
  update calls set duration_seconds = 120 where id = c1;
  assert zella_process_call_usage(c1) ->> 'result' = 'unchanged' and (select count(*) from usage_records where call_id = c1) = 2, 'adjust once';
  raise notice 'PASS 10 provider duration changed 95 -> 120 s: one adjustment (+25 s, +0.4167 min), original row kept, not repeated';

  -- 11 + 22: a processing failure is retried with a growing wait, at most 5 times, then escalated once
  update platform_settings set value = '{"rounding": "sideways"}' where key = 'call_usage_policy';
  insert into calls (business_id, direction, status, external_call_id, started_at, ended_at, duration_seconds, ai_handled)
  values (A, 'inbound', 'completed', 'u-11', now() - interval '2 hours', now() - interval '2 hours' + interval '40 seconds', 40, true) returning id into x;
  assert exists (select 1 from usage_processing_issues where call_id = x and kind = 'processing_failed' and status = 'open') and not exists (select 1 from usage_records where call_id = x), 'failure recorded';
  for n in 1..5 loop update usage_processing_issues set next_attempt_at = now() - interval '1 second' where call_id = x; perform zella_reconcile_call_usage(); end loop;
  assert (select attempts from usage_processing_issues where call_id = x) = 5, 'attempts';
  update usage_processing_issues set next_attempt_at = now() - interval '1 second' where call_id = x;
  perform zella_reconcile_call_usage(); perform zella_reconcile_call_usage();
  assert (select status from usage_processing_issues where call_id = x) = 'escalated' and (select count(*) from platform_alerts where kind = 'usage_processing_failed') = 1, 'escalated once';
  raise notice 'PASS 11 failing processing: 5 bounded retries, then escalated with one platform alert (not repeated)';
  update platform_settings set value = '{"increment_seconds": 1, "rounding": "up", "minimum_billable_seconds": 0, "ignore_under_seconds": 0}' where key = 'call_usage_policy';

  -- 13 + 14: isolation and permissions
  insert into business_members (business_id, user_id, role, status) values (A, u_a, 'owner', 'active'), (B, u_b, 'owner', 'active');
  perform set_config('request.jwt.claim.sub', u_a::text, true);
  r := zella_call_usage_summary(A, now() - interval '1 day', now() + interval '1 day');
  assert (r #>> '{totals,calls}')::int >= 3, 'own ' || r::text;
  perform set_config('request.jwt.claim.sub', u_b::text, true);
  begin perform zella_call_usage_summary(A, now() - interval '1 day', now()); raise exception 'B read A'; exception when others then assert sqlerrm = 'NOT_ALLOWED', sqlerrm; end;
  begin perform zella_call_usage_records(A, now() - interval '1 day', now(), 10, 0); raise exception 'B read A rows'; exception when others then assert sqlerrm = 'NOT_ALLOWED', sqlerrm; end;
  begin perform zella_admin_call_usage(); raise exception 'member used admin'; exception when others then assert sqlerrm = 'NOT_ALLOWED', sqlerrm; end;
  perform set_config('request.jwt.claim.sub', '', true);
  assert not has_function_privilege('authenticated', 'public.zella_process_call_usage(uuid, text, text)', 'execute')
     and not has_function_privilege('anon', 'public.zella_call_usage_summary(uuid, timestamptz, timestamptz)', 'execute')
     and not has_function_privilege('authenticated', 'public.zella_reconcile_call_usage(integer)', 'execute')
     and not has_table_privilege('authenticated', 'public.usage_records', 'insert') and not has_table_privilege('authenticated', 'public.usage_records', 'update')
     and not has_table_privilege('authenticated', 'public.usage_processing_issues', 'select'), 'grants';
  raise notice 'PASS 13+14 a member sees their own business only; another business''s owner is refused; members can''t use admin tools, write the ledger or run processing';

  -- 15 + 16: periods and the entitlement interface with nothing configured
  r := zella_call_usage_summary(A) ;
  assert r #>> '{period,available}' = 'false' and r #>> '{allowance,configured}' = 'false' and r #>> '{allowance,reason}' = 'no_active_subscription', 'no period ' || r::text;
  r := zella_call_entitlement_check(A);
  assert r ->> 'status' = 'not_configured' and r ->> 'would_permit' is null and r ->> 'enforced' = 'false', 'not configured ' || r::text;
  raise notice 'PASS 15+16 no subscription: no period invented (a date range is required), allowance "not configured" (not zero, not exhausted), entitlement not_configured and not enforced';

  -- 17 + 18 + 19 + 20: TEST-ONLY plan with 10 minutes, in this staging database
  insert into plans (name, slug, limits) values ('TEST ONLY', 'test-only', '{"voice_minutes": 10}') returning id into p;
  insert into subscriptions (business_id, plan_id, status, current_period_start, current_period_end) values (A, p, 'active', now() - interval '10 days', now() + interval '20 days') returning id into s;
  r := zella_call_entitlement_check(A);
  assert r ->> 'status' = 'active' and r ->> 'would_permit' = 'true' and r ->> 'enforced' = 'false' and (r ->> 'limit_minutes')::numeric = 10, 'active ' || r::text;
  r := zella_call_usage_summary(A);
  assert r #>> '{period,source}' = 'subscription' and r #>> '{allowance,configured}' = 'true', 'sub period';
  raise notice 'PASS 17 active entitlement (test fixture, 10 min): within allowance, would permit, not enforced; summary uses the subscription''s own period';
  insert into calls (business_id, direction, status, external_call_id, started_at, ended_at, duration_seconds, ai_handled)
  values (A, 'inbound', 'completed', 'u-19', now() - interval '1 hour', now() - interval '1 hour' + interval '330 seconds', 330, true);
  assert (select count(*) from usage_threshold_events where business_id = A) = 1 and (select event_type from usage_threshold_events where business_id = A) = 'approaching'
     and (select count(*) from staff_notifications where business_id = A and kind = 'usage_threshold') = 1, 'threshold ' || (select count(*) from usage_threshold_events)::text;
  perform zella_check_usage_thresholds(); perform zella_evaluate_call_usage_thresholds(A);
  assert (select count(*) from usage_threshold_events where business_id = A) = 1 and (select count(*) from staff_notifications where business_id = A and kind = 'usage_threshold') = 1, 'dup threshold';
  raise notice 'PASS 19+20 usage passes 70%% of the test allowance: one event and one notice; the hourly job and re-evaluation add none';
  insert into calls (business_id, direction, status, external_call_id, started_at, ended_at, duration_seconds, ai_handled)
  values (A, 'inbound', 'completed', 'u-18', now() - interval '50 minutes', now() - interval '50 minutes' + interval '300 seconds', 300, true);
  r := zella_call_entitlement_check(A);
  assert r ->> 'status' = 'exhausted' and r ->> 'would_permit' = 'false' and r ->> 'enforced' = 'false' and r ->> 'fallback' = 'take_message', 'exhausted ' || r::text;
  assert (select count(*) from usage_threshold_events where business_id = A and event_type = 'allowance_limit') = 1, 'limit event';
  raise notice 'PASS 18 allowance used up (test fixture): exhausted, would deny, NOT enforced (calls unchanged), fallback take_message; one allowance-limit event';
  -- 21: delivery status is visible to admins
  update staff_notifications set delivery_status = 'failed', delivery_error = 'test: provider down' where business_id = A and kind = 'usage_threshold';
  insert into platform_admins (user_id, role) values (adm, 'billing_admin'), (ro, 'read_only_admin');
  insert into platform_role_permissions (role, permission) values ('billing_admin', 'billing.view'), ('billing_admin', 'billing.manage'), ('read_only_admin', 'billing.view');
  perform set_config('request.jwt.claim.sub', ro::text, true);
  r := zella_admin_call_usage(A);
  assert jsonb_array_length(r -> 'records') >= 4 and exists (select 1 from jsonb_array_elements(r -> 'threshold_events') e where e ->> 'delivery_status' = 'failed') and r ->> 'can_retry' = 'false', 'admin view';
  raise notice 'PASS 21 admin (billing.view) sees usage records, threshold events and the failed notice delivery';
  -- 22: only billing.manage can retry, and it is audited
  select id into x from usage_processing_issues where kind = 'missing_duration' limit 1;
  begin perform zella_admin_retry_usage(x); raise exception 'read-only retried'; exception when others then assert sqlerrm = 'NOT_ALLOWED', sqlerrm; end;
  perform set_config('request.jwt.claim.sub', adm::text, true);
  r := zella_admin_retry_usage(x);
  assert r ->> 'result' = 'missing_duration' and exists (select 1 from audit_logs where action = 'billing.usage_retry' and user_id = adm and entity_id = x), 'retry audited';
  perform set_config('request.jwt.claim.sub', '', true);
  raise notice 'PASS 22 retry: read-only admin refused; billing admin''s retry runs (still no duration, so still nothing invented) and is in the audit log';

  -- 23: summaries agree with the ledger, and reconciliation finds what is missing or different
  r := zella_call_usage_totals(A, now() - interval '400 days', now() + interval '1 day');
  assert round((r ->> 'usage_minutes')::numeric, 1) = (zella_usage_counts(A, now() - interval '400 days', now() + interval '1 day') ->> 'voice_minutes')::numeric, 'counts vs ledger';
  delete from usage_records where call_id = c2;
  r := zella_reconcile_call_usage();
  assert (r ->> 'recorded')::int >= 1 and (select count(*) from usage_records where call_id = c2) = 1, 'reconcile recorded ' || r::text;
  update usage_records set duration_seconds = duration_seconds + 7 where call_id = c2;   -- a ledger edited behind the system's back
  update calls set ended_at = ended_at where id = c2;
  perform zella_reconcile_call_usage();
  assert exists (select 1 from usage_processing_issues where business_id = A and kind = 'summary_mismatch' and status = 'open'), 'mismatch';
  perform zella_reconcile_call_usage();
  assert (select count(*) from usage_processing_issues where business_id = A and kind = 'summary_mismatch' and status <> 'resolved') = 1, 'one mismatch';
  update usage_records set duration_seconds = duration_seconds - 7 where call_id = c2;
  perform zella_reconcile_call_usage();
  assert not exists (select 1 from usage_processing_issues where business_id = A and kind = 'summary_mismatch' and status <> 'resolved'), 'mismatch resolved';
  raise notice 'PASS 23 Billing > Usage reads the ledger; reconciliation records a call that lost its usage, flags a ledger that disagrees (once) and clears it when it matches';

  -- 24: every industry uses the same ledger; an explicit industry rule can leave a category out, and it is recorded
  update businesses set industry_id = (select id from industries where slug = 'dental') where id = B;
  update platform_settings set value = '{"counted_categories": ["inbound_ai", "outbound_ai"], "industries": {"dental": {"counted_categories": ["inbound_ai"]}}}' where key = 'call_usage_rules';
  insert into calls (business_id, direction, status, external_call_id, started_at, ended_at, duration_seconds, ai_handled) values
    (B, 'inbound', 'completed', 'u-24a', t0, t0 + interval '50 seconds', 50, true), (B, 'outbound', 'completed', 'u-24b', t0, t0 + interval '50 seconds', 50, true),
    (A, 'outbound', 'completed', 'u-24c', t0, t0 + interval '50 seconds', 50, true);
  assert exists (select 1 from usage_records u join calls c on c.id = u.call_id where c.external_call_id = 'u-24a' and u.policy ->> 'category_rule' = 'industry:dental')
     and not exists (select 1 from usage_records u join calls c on c.id = u.call_id where c.external_call_id = 'u-24b')
     and exists (select 1 from usage_records u join calls c on c.id = u.call_id where c.external_call_id = 'u-24c' and u.usage_category = 'outbound_ai'), 'industry';
  insert into calls (business_id, direction, status, external_call_id, started_at, ended_at, duration_seconds, ai_handled) values (A, 'inbound', 'completed', 'u-24d', t0, t0 + interval '50 seconds', 50, false);
  assert not exists (select 1 from usage_records u join calls c on c.id = u.call_id where c.external_call_id = 'u-24d'), 'not ai';
  update platform_settings set value = '{"counted_categories": ["inbound_ai", "outbound_ai"], "industries": {}}' where key = 'call_usage_rules';
  raise notice 'PASS 24 one ledger for every industry; an explicit dental rule leaves outbound AI calls out (rule recorded on the row); calls not handled by AI are not counted';
  -- usage history: last four digits only
  perform set_config('request.jwt.claim.sub', u_a::text, true);
  r := zella_call_usage_records(A, now() - interval '400 days', now() + interval '1 day', 2, 0);
  assert (r ->> 'total')::int >= 5 and jsonb_array_length(r -> 'rows') = 2 and position('5551230001' in r::text) = 0, 'history';
  perform set_config('request.jwt.claim.sub', '', true);
  raise notice 'PASS history: paginated (2 per page of % rows), caller numbers masked to the last four digits', r ->> 'total';
end $$;
