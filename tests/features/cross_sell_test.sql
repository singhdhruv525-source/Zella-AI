-- "You might also need" follow-ups (staging only).
\i ../voice-reliability/fixture.sql
delete from public.cross_sell_rules; delete from public.followup_tasks; delete from public.business_members; delete from public.contact_consents;
update businesses set industry_id = (select id from industries where slug = 'dental') where id = 'aaaaaaaa-0000-4000-8000-000000000001';
insert into business_members (business_id, user_id, role, status) values
  ('aaaaaaaa-0000-4000-8000-000000000001', '0aaaaaaa-0000-4000-8000-000000000001', 'owner', 'active'),
  ('aaaaaaaa-0000-4000-8000-000000000001', '0aaaaaaa-0000-4000-8000-000000000002', 'staff', 'active');
insert into appointments (id, business_id, customer_id, title, status, start_time, end_time) values
  ('dddddddd-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000001', 'Teeth Cleaning', 'confirmed', now() - interval '1 hour', now() - interval '30 minutes'),
  ('dddddddd-0000-4000-8000-000000000002', 'aaaaaaaa-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000002', 'Filling', 'confirmed', now() - interval '1 hour', now() - interval '30 minutes'),
  ('dddddddd-0000-4000-8000-000000000003', 'aaaaaaaa-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000002', 'Cleaning', 'confirmed', now() - interval '1 hour', now() - interval '30 minutes');

do $$
declare A uuid := 'aaaaaaaa-0000-4000-8000-000000000001'; r jsonb; v_rule uuid; v_err text; f record; p jsonb;
begin
  perform set_config('request.jwt.claim.sub', '0aaaaaaa-0000-4000-8000-000000000001', true);
  r := zella_cross_sell_list(A);
  assert r #>> '{ideas,0,suggestion}' = 'teeth whitening' and jsonb_array_length(r -> 'rules') = 0, r::text;
  v_rule := zella_cross_sell_save(A, '{"after_service": "cleaning", "suggestion": "teeth whitening", "delay_days": 14}');
  assert jsonb_array_length(zella_cross_sell_list(A) -> 'ideas') = 0, 'idea hidden once added';
  raise notice 'PASS a dental business sees "cleaning -> teeth whitening" as an idea, and adds it as a rule';
  perform set_config('request.jwt.claim.sub', '', true);

  update appointments set status = 'completed' where id = 'dddddddd-0000-4000-8000-000000000001';
  select * into f from followup_tasks where kind = 'cross_sell' and customer_id = 'cccccccc-0000-4000-8000-000000000001';
  assert f.id is not null and f.channel = 'sms' and f.due_at between now() + interval '13 days 23 hours' and now() + interval '14 days 1 hour'
     and f.vars ->> 'service' = 'Teeth Cleaning' and f.vars ->> 'suggestion' = 'teeth whitening', row_to_json(f)::text;
  update appointments set status = 'completed' where id = 'dddddddd-0000-4000-8000-000000000002';
  assert (select count(*) from followup_tasks where kind = 'cross_sell' and customer_id = 'cccccccc-0000-4000-8000-000000000002') = 0;
  raise notice 'PASS completing a cleaning queues one suggestion for 14 days later; a filling queues nothing';

  -- marketing: the message is refused without an opt-in, and allowed with one (production prepare_sms)
  update platform_settings set value = 'true' where key = 'sms_marketing_allowed';
  insert into platform_settings (key, value) values ('sms_marketing_allowed', 'true') on conflict (key) do update set value = 'true';
  p := zella_prepare_sms(A, f.customer_id, 'cross_sell', jsonb_build_object('service', f.vars ->> 'service', 'suggestion', f.vars ->> 'suggestion'), 'marketing');
  assert p ->> 'reason' = 'no_consent', p::text;
  insert into contact_consents (business_id, customer_id, channel, purpose, status, source, recorded_at)
    values (A, f.customer_id, 'sms', 'marketing', 'opted_in', 'test', now());
  p := zella_prepare_sms(A, f.customer_id, 'cross_sell', jsonb_build_object('service', f.vars ->> 'service', 'suggestion', f.vars ->> 'suggestion'), 'marketing');
  assert p ->> 'reason' = 'quiet_hours' or (p ->> 'allowed')::boolean, p::text;
  if (p ->> 'allowed')::boolean then
    assert p ->> 'body' = 'Hi Ana, thanks for choosing Bright Smile Dental for your Teeth Cleaning. Many customers also book teeth whitening. Reply here if you''d like a time. Reply STOP to opt out.', p::text;
  end if;
  update platform_settings set value = 'false' where key = 'sms_marketing_allowed';
  p := zella_prepare_sms(A, f.customer_id, 'cross_sell', jsonb_build_object('service', 'x', 'suggestion', 'y'), 'marketing');
  assert p ->> 'reason' = 'sms_marketing_off', p::text;
  raise notice 'PASS it is a marketing message: refused without an opt-in or while marketing texts are off; with an opt-in the text reads naturally (outside quiet hours)';

  -- booking the suggestion anyway cancels it; the same rule doesn't repeat within 90 days; any suggestion at most every 14 days
  insert into appointments (business_id, customer_id, title, status, start_time, end_time)
    values (A, 'cccccccc-0000-4000-8000-000000000001', 'Teeth whitening', 'scheduled', now() + interval '3 days', now() + interval '3 days 1 hour');
  assert (select status || '/' || outcome from followup_tasks where id = f.id) = 'cancelled/already_booked';
  update appointments set status = 'confirmed' where id = 'dddddddd-0000-4000-8000-000000000001';
  update appointments set status = 'completed' where id = 'dddddddd-0000-4000-8000-000000000001';
  assert (select count(*) from followup_tasks where kind = 'cross_sell' and customer_id = 'cccccccc-0000-4000-8000-000000000001') = 1;
  raise notice 'PASS booking the suggested service cancels the pending suggestion; it is not suggested again soon after';

  -- already has the suggestion booked: nothing queued
  insert into appointments (business_id, customer_id, title, status, start_time, end_time)
    values (A, 'cccccccc-0000-4000-8000-000000000002', 'Whitening - teeth whitening', 'scheduled', now() + interval '5 days', now() + interval '5 days 1 hour');
  update appointments set status = 'completed' where id = 'dddddddd-0000-4000-8000-000000000003';
  assert (select count(*) from followup_tasks where kind = 'cross_sell' and customer_id = 'cccccccc-0000-4000-8000-000000000002') = 0;
  raise notice 'PASS a customer who already has the suggested service booked gets no suggestion';

  -- do-not-contact customers get nothing
  delete from followup_tasks;
  update customers set do_not_contact = true where id = 'cccccccc-0000-4000-8000-000000000001';
  update appointments set status = 'confirmed' where id = 'dddddddd-0000-4000-8000-000000000001';
  update appointments set status = 'completed' where id = 'dddddddd-0000-4000-8000-000000000001';
  assert (select count(*) from followup_tasks where kind = 'cross_sell') = 0;
  update customers set do_not_contact = false where id = 'cccccccc-0000-4000-8000-000000000001';
  raise notice 'PASS do-not-contact customers are never queued';

  -- input checks and permissions
  perform set_config('request.jwt.claim.sub', '0aaaaaaa-0000-4000-8000-000000000001', true);
  begin perform zella_cross_sell_save(A, '{"after_service": "cleaning", "suggestion": "Teeth Whitening"}'); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'DUPLICATE_RULE', coalesce(v_err, 'saved');
  begin perform zella_cross_sell_save(A, '{"after_service": "cut", "suggestion": "visit www.x.com"}'); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'RULE_TEXT';
  begin perform zella_cross_sell_save(A, '{"after_service": "cut", "suggestion": "{{first_name}}"}'); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'RULE_TEXT';
  begin perform zella_cross_sell_save(A, '{"after_service": "cut", "suggestion": "Cut"}'); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'SAME_SERVICE';
  begin perform zella_cross_sell_save(A, '{"after_service": "cut", "suggestion": "colour", "delay_days": 400}'); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'INVALID_DELAY';
  perform set_config('request.jwt.claim.sub', '0aaaaaaa-0000-4000-8000-000000000002', true);
  begin perform zella_cross_sell_save(A, '{"after_service": "cut", "suggestion": "colour"}'); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'NOT_ALLOWED';
  assert not (zella_cross_sell_list(A) ->> 'can_edit')::boolean;
  perform set_config('request.jwt.claim.sub', '0bbbbbbb-0000-4000-8000-000000000001', true);
  begin perform zella_cross_sell_list(A); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'NOT_ALLOWED';
  perform set_config('request.jwt.claim.sub', '', true);
  raise notice 'PASS duplicates, links, placeholders, same-service and out-of-range delays are refused; staff can look but not change; other businesses can''t see';

  -- deleting a rule cancels what it had queued
  update appointments set status = 'cancelled' where title = 'Teeth whitening';
  update appointments set status = 'confirmed' where id = 'dddddddd-0000-4000-8000-000000000001';
  update appointments set status = 'completed' where id = 'dddddddd-0000-4000-8000-000000000001';
  assert (select count(*) from followup_tasks where kind = 'cross_sell' and status = 'pending') = 1;
  perform set_config('request.jwt.claim.sub', '0aaaaaaa-0000-4000-8000-000000000001', true);
  perform zella_cross_sell_delete(A, v_rule);
  perform set_config('request.jwt.claim.sub', '', true);
  assert (select count(*) from followup_tasks where kind = 'cross_sell' and status = 'pending') = 0;
  raise notice 'PASS deleting a rule cancels the suggestions it queued';
  assert (zella_cross_sell_status() ->> 'templates')::boolean;
  raise notice 'PASS both message templates (text and email) are in place, marked marketing';
end $$;
