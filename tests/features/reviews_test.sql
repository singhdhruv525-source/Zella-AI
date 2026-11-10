-- Review replies (staging only).
\i ../voice-reliability/fixture.sql
delete from public.reviews; delete from public.review_sources; delete from public.business_members; delete from public.staff_notifications;
update businesses set phone = '+15550001000' where id = 'aaaaaaaa-0000-4000-8000-000000000001';
update businesses set industry_id = (select id from industries where slug = 'dental') where id = 'aaaaaaaa-0000-4000-8000-000000000001';
insert into platform_settings (key, value) values ('reviews_live', 'false'), ('review_ai_live', 'false') on conflict (key) do update set value = excluded.value;
insert into business_members (business_id, user_id, role, status) values
  ('aaaaaaaa-0000-4000-8000-000000000001', '0aaaaaaa-0000-4000-8000-000000000001', 'owner', 'active'),
  ('aaaaaaaa-0000-4000-8000-000000000001', '0aaaaaaa-0000-4000-8000-000000000002', 'staff', 'active'),
  ('aaaaaaaa-0000-4000-8000-000000000001', '0aaaaaaa-0000-4000-8000-000000000003', 'manager', 'active'),
  ('bbbbbbbb-0000-4000-8000-000000000002', '0bbbbbbb-0000-4000-8000-000000000001', 'owner', 'active');

do $$
declare A uuid := 'aaaaaaaa-0000-4000-8000-000000000001'; v uuid; r jsonb; t text; v_err text;
begin
  -- standard drafts by stars, with nothing from the review in them
  perform set_config('request.jwt.claim.sub', '0aaaaaaa-0000-4000-8000-000000000001', true);
  v := zella_review_add(A, 'Yelp', 'Ana Lopez', 5, 'Dr. Kim fixed my root canal, so much less pain now!');
  select draft into t from reviews where id = v;
  assert t like 'Hi Ana, thank you so much for the kind review!%' and t not ilike '%root canal%' and t not ilike '%Kim%' and t not ilike '%pain%', t;
  v := zella_review_add(A, null, 'anonymous', 1, 'Billing charged me twice for my HIV test');
  select draft into t from reviews where id = v;
  assert t like 'We''re sorry to hear%' and t like '%at +15550001000%' and t !~* '(hiv|billing|test|twice)', t;
  raise notice 'PASS standard drafts follow the stars, use only a real first name and the business phone, and repeat nothing from the review';
  assert (select count(*) from staff_notifications where business_id = A and kind = 'low_review') = 1;
  raise notice 'PASS a 1-star review alerts the owners at once; a 5-star one does not';

  r := zella_reviews_list(A, null);
  assert (r #>> '{counts,to_reply}')::int = 2 and jsonb_array_length(r -> 'reviews') = 2 and not (r ->> 'live')::boolean, r::text;

  -- approve with edited words; a manual review is copied by the owner
  t := zella_review_decide(v, 'approve', E'We''re sorry. Please call us so we can help.\n- The team');
  assert t = 'copy_and_post';
  assert (select status from reviews where id = v) = 'approved';
  begin perform zella_review_decide(v, 'approve', 'again'); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'ALREADY_DECIDED';
  t := zella_review_decide(v, 'reopen');
  assert t = 'reopened' and (select status from reviews where id = v) = 'drafted';
  begin perform zella_review_decide(v, 'approve', '<script>x</script>'); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'REPLY_TEXT';
  begin perform zella_review_decide(v, 'approve', ' '); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'REPLY_LENGTH';
  assert zella_review_decide(v, 'skip') = 'skipped';
  raise notice 'PASS owners approve the exact words (or skip, or reopen); empty replies and HTML are refused; a decision can''t be made twice';

  -- permissions
  perform set_config('request.jwt.claim.sub', '0aaaaaaa-0000-4000-8000-000000000002', true);
  begin perform zella_reviews_list(A, null); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'NOT_ALLOWED', 'staff list';
  begin perform zella_review_decide(v, 'reopen'); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'NOT_ALLOWED', 'staff decide';
  perform set_config('request.jwt.claim.sub', '0bbbbbbb-0000-4000-8000-000000000001', true);
  begin perform zella_review_decide(v, 'reopen'); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'NOT_ALLOWED', 'other business';
  perform set_config('request.jwt.claim.sub', '0aaaaaaa-0000-4000-8000-000000000003', true);
  assert jsonb_array_length(zella_reviews_list(A, null) -> 'reviews') = 2;
  begin perform zella_review_source_save(A, '123', '456', true); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'NOT_ALLOWED', 'manager connects google';
  perform set_config('request.jwt.claim.sub', '0aaaaaaa-0000-4000-8000-000000000001', true);
  begin perform zella_review_source_save(A, '12/3', '456', true); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'INVALID_GOOGLE_IDS';
  begin perform zella_review_add(A, null, null, 6, 'x'); v_err := null; exception when others then v_err := sqlerrm; end;
  assert v_err = 'INVALID_RATING';
  perform zella_review_source_save(A, '123', '456', true);
  perform set_config('request.jwt.claim.sub', '', true);
  raise notice 'PASS owners, admins and managers handle reviews; staff and other businesses cannot; only owners/admins connect Google; bad ids and stars refused';
end $$;

-- the workflow side: nothing is claimed while switched off; then fetch, AI draft, post
do $$
declare A uuid := 'aaaaaaaa-0000-4000-8000-000000000001'; r jsonb; v uuid; t text;
begin
  assert zella_review_work_waiting() = 0 and zella_review_claim_fetch(10) = '[]'::jsonb and zella_review_claim_posts(10) = '[]'::jsonb and zella_review_claim_ai(5) = '[]'::jsonb;
  raise notice 'PASS while reviews_live and review_ai_live are off, nothing is waiting and nothing can be claimed';

  update platform_settings set value = 'true' where key in ('reviews_live', 'review_ai_live');
  assert zella_review_work_waiting() >= 1;
  r := zella_review_claim_fetch(10);
  assert jsonb_array_length(r) = 1 and r #>> '{0,location_id}' = '456', r::text;
  assert zella_review_claim_fetch(10) = '[]'::jsonb, 'claimed twice';
  r := zella_review_ingest(A, 200, '[
    {"external_id": "g1", "author_name": "Ben Ray", "rating": 4, "body": "Friendly front desk", "reviewed_at": "2026-10-20T10:00:00Z"},
    {"external_id": "g2", "author_name": "Cy", "rating": 5, "body": "Already thanked", "existing_reply": "Thanks Cy!"},
    {"external_id": "g3", "rating": 9},
    {"author_name": "no id", "rating": 3}]');
  assert r ->> 'seen' = '2' and r ->> 'new' = '2', r::text;
  r := zella_review_ingest(A, 200, '[{"external_id": "g1", "author_name": "Ben Ray", "rating": 4, "body": "Friendly front desk", "reviewed_at": "2026-10-20T10:00:00Z"}]');
  assert r ->> 'new' = '0' and (select count(*) from reviews where provider = 'google') = 2, 'dedupe ' || r::text;
  assert (select status from reviews where external_id = 'g2') = 'replied_elsewhere' and (select ai_status from reviews where external_id = 'g1') = 'pending';
  assert (select next_fetch_at > now() + interval '5 hours' from review_sources where business_id = A);
  raise notice 'PASS Google reviews are stored once; already-answered ones are left alone; bad entries are dropped; the next read is in 6 hours';

  r := zella_review_claim_ai(5);
  assert jsonb_array_length(r) = 1 and r #>> '{0,industry}' = 'dental' and r #>> '{0,author_first_name}' = 'Ben', r::text;
  v := (r #>> '{0,review_id}')::uuid;
  assert zella_review_save_ai_draft(v, 'Visit https://spam.example for a deal') = 'kept_standard';
  assert (select draft_source from reviews where id = v) = 'template';
  assert zella_review_save_ai_draft(v, 'Thank you, Ben! We are so glad our front desk team made you feel welcome.') = 'saved';
  assert (select draft_source || '/' || ai_status from reviews where id = v) = 'ai/done';
  raise notice 'PASS AI rewrites replace the standard draft only when usable (no links, sensible length) and only before anyone decided';

  perform set_config('request.jwt.claim.sub', '0aaaaaaa-0000-4000-8000-000000000001', true);
  t := zella_review_decide(v, 'approve', 'Thank you, Ben! We are so glad you felt welcome.');
  perform set_config('request.jwt.claim.sub', '', true);
  assert t = 'will_post', t;
  r := zella_review_claim_posts(10);
  assert jsonb_array_length(r) = 1 and r #>> '{0,external_id}' = 'g1' and r #>> '{0,reply}' = 'Thank you, Ben! We are so glad you felt welcome.', r::text;
  assert zella_review_claim_posts(10) = '[]'::jsonb;
  t := zella_review_post_result(v, 503);
  assert t = 'will_retry' and (select status from reviews where id = v) = 'approved';
  perform zella_review_claim_posts(10);
  t := zella_review_post_result(v, 200);
  assert t = 'posted' and (select status from reviews where id = v) = 'posted';
  raise notice 'PASS only approved replies are claimed for posting, exactly as approved; a Google error is retried; success marks it posted';

  -- five failures in a row stop the sync and tell the owners
  update review_sources set next_fetch_at = now() - interval '1 minute', claimed_at = null where business_id = A;
  for i in 1..5 loop perform zella_review_ingest(A, 401, null); end loop;
  assert (select status from review_sources where business_id = A) = 'error' and (select count(*) from staff_notifications where kind = 'reviews_disconnected') = 1;
  raise notice 'PASS after 5 failed reads in a row the Google connection is marked broken and the owners are told once';
  update platform_settings set value = 'false' where key in ('reviews_live', 'review_ai_live');
  assert (zella_reviews_status() ->> 'tables')::boolean;
end $$;
