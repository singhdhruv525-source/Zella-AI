-- Batch 3 fixture: synthetic businesses Alpha and Beta, their people and large lists (ids b3…, *.b3.test, numbers
-- +1555…). Used by tests/batch3/test.sql (inside a transaction that is rolled back) and by the browser test database
-- (tests/batch3/browser.sh). Never run against production.
insert into auth.users (id, email, email_confirmed_at) values
 ('b3000000-0000-0000-0000-00000000000a', 'own-a@b3.test', now()), ('b3000000-0000-0000-0000-00000000000b', 'staff-a@b3.test', now()),
 ('b3000000-0000-0000-0000-00000000000c', 'view-a@b3.test', now()), ('b3000000-0000-0000-0000-00000000000d', 'own-b@b3.test', now()),
 ('b3000000-0000-0000-0000-00000000000e', 'outsider@b3.test', now()),
 ('b3000000-0000-0000-0000-00000000000f', 'multi@b3.test', now());
insert into public.profiles (id) select id from auth.users where email like '%@b3.test' on conflict do nothing;
insert into public.businesses (id, name, timezone, is_active, onboarding_status, industry_id) values
 ('b3000000-0000-0000-0000-0000000000a1', 'B3 Alpha', 'UTC', true, 'active', (select id from public.industries where slug = 'plumbing' limit 1)),
 ('b3000000-0000-0000-0000-0000000000b1', 'B3 Beta', 'UTC', true, 'active', (select id from public.industries where slug = 'plumbing' limit 1));
insert into public.business_members (business_id, user_id, role, status)
select b::uuid, u::uuid, r, 'active' from (values
 ('b3000000-0000-0000-0000-0000000000a1', 'b3000000-0000-0000-0000-00000000000a', 'owner'),
 ('b3000000-0000-0000-0000-0000000000a1', 'b3000000-0000-0000-0000-00000000000b', 'staff'),
 ('b3000000-0000-0000-0000-0000000000a1', 'b3000000-0000-0000-0000-00000000000c', 'viewer'),
 ('b3000000-0000-0000-0000-0000000000b1', 'b3000000-0000-0000-0000-00000000000d', 'owner'),
 -- one person in both businesses (manager in each), for switching workspaces in the browser test
 ('b3000000-0000-0000-0000-0000000000a1', 'b3000000-0000-0000-0000-00000000000f', 'manager'),
 ('b3000000-0000-0000-0000-0000000000b1', 'b3000000-0000-0000-0000-00000000000f', 'manager')) v(b, u, r);
insert into public.business_modules (business_id, module_id, enabled)
select b.id, im.id, true from public.businesses b join public.industry_modules im on im.industry_id = b.industry_id and im.slug = 'calls'
 where b.id in ('b3000000-0000-0000-0000-0000000000a1', 'b3000000-0000-0000-0000-0000000000b1') on conflict do nothing;

-- Alpha: 1,200 leads, newest first every 7 hours (the oldest ~350 days back), all stages, sources, owners
insert into public.customers (business_id, first_name, last_name, phone, email, source, lead_stage, assigned_to, created_at,
  next_follow_up_at, contact_deadline_at, last_contacted_at, do_not_sms, do_not_contact)
select 'b3000000-0000-0000-0000-0000000000a1', 'Lead' || i, 'Alpha', '+1555100' || lpad(i::text, 4, '0'), 'lead' || i || '@alpha.b3.test',
       (array['ai_call', 'website_form', 'referral', 'manual', 'phone'])[1 + i % 5],
       (array['new', 'contacted', 'qualified', 'quote_sent', 'won', 'lost', 'unqualified'])[1 + i % 7],
       case i % 3 when 0 then 'b3000000-0000-0000-0000-00000000000a'::uuid when 1 then 'b3000000-0000-0000-0000-00000000000b'::uuid end,
       now() - make_interval(hours => 7 * i),
       case when i % 4 = 0 then now() - interval '1 day' when i % 4 = 1 then now() + interval '2 days' end,
       case when i % 7 = 0 then now() - interval '1 hour' end,
       case when i % 2 = 0 then now() - interval '3 days' end,
       i % 50 = 0, i % 97 = 0
  from generate_series(1, 1200) i;
-- the one that matters: older than the 1,000 newest
insert into public.customers (id, business_id, first_name, last_name, phone, source, lead_stage, created_at, next_follow_up_at)
values ('b3000000-0000-0000-0000-0000000001aa', 'b3000000-0000-0000-0000-0000000000a1', 'Zephyrine', 'Oldest', '+15551999999', 'referral', 'qualified',
        now() - interval '400 days', now() - interval '10 days');
-- Beta: a few of its own
insert into public.customers (business_id, first_name, last_name, phone, lead_stage, created_at)
select 'b3000000-0000-0000-0000-0000000000b1', 'Beta' || i, 'Person', '+1555200' || lpad(i::text, 4, '0'), 'new', now() - make_interval(hours => i)
  from generate_series(1, 5) i;

-- records: properties, and 620 jobs that link to them (one links to a Beta record id, which must never resolve)
insert into public.crm_record_types (business_id, key, singular, plural, statuses, closed_statuses, fields, columns) values
 ('b3000000-0000-0000-0000-0000000000a1', 'b3props', 'Property', 'Properties', '[{"key":"active","label":"Active"}]', '{}', '[]', '{}'),
 ('b3000000-0000-0000-0000-0000000000a1', 'b3jobs', 'Job', 'Jobs',
  '[{"key":"open","label":"Open"},{"key":"scheduled","label":"Scheduled"},{"key":"done","label":"Done"}]', '{done}',
  '[{"key":"property","label":"Property","type":"record","target":"b3props"},{"key":"details","label":"Details","type":"longtext"}]', '{property,details}'),
 ('b3000000-0000-0000-0000-0000000000b1', 'b3jobs', 'Job', 'Jobs', '[{"key":"open","label":"Open"}]', '{}', '[]', '{}')
on conflict (business_id, key) do update set statuses = excluded.statuses, closed_statuses = excluded.closed_statuses, fields = excluded.fields, columns = excluded.columns, enabled = true;
insert into public.crm_records (business_id, type_key, title, status, data, updated_at)
select 'b3000000-0000-0000-0000-0000000000a1', 'b3props', 'Property ' || i, 'active', '{}', now() - make_interval(days => i)
  from generate_series(1, 40) i;
insert into public.crm_records (id, business_id, type_key, title, status) values
 ('b3000000-0000-0000-0000-0000000004b1', 'b3000000-0000-0000-0000-0000000000b1', 'b3jobs', 'Beta secret job', 'open');
insert into public.crm_records (business_id, type_key, title, status, data, updated_at, archived_at)
select 'b3000000-0000-0000-0000-0000000000a1', 'b3jobs', 'Job ' || i, (array['open', 'scheduled', 'done'])[1 + i % 3],
       jsonb_build_object('details', 'fix sink ' || i, 'property',
         (select id::text from public.crm_records p where p.business_id = 'b3000000-0000-0000-0000-0000000000a1' and p.type_key = 'b3props' and p.title = 'Property ' || (1 + i % 40))),
       now() - make_interval(hours => 3 * i), case when i % 61 = 0 then now() end
  from generate_series(1, 620) i;
insert into public.crm_records (id, business_id, type_key, title, status, data, updated_at) values
 ('b3000000-0000-0000-0000-0000000004aa', 'b3000000-0000-0000-0000-0000000000a1', 'b3jobs', 'Needle in the haystack', 'open',
  '{"details":"the boiler with the brass valve","property":"b3000000-0000-0000-0000-0000000004b1"}', now() - interval '900 days');

-- calls: 360 for Alpha (missed, answered, AI, three open escalations, transcripts and recordings), 5 for Beta
insert into public.calls (business_id, direction, status, from_number, started_at, created_at, ai_handled, transcript, recording_url, summary,
  needs_human, escalated_at, escalation_resolved_at, metadata, duration_seconds)
select 'b3000000-0000-0000-0000-0000000000a1', 'inbound', (array['missed', 'completed', 'answered'])[1 + i % 3], '+1555300' || lpad(i::text, 4, '0'),
       now() - make_interval(mins => 37 * i), now() - make_interval(mins => 37 * i), i % 2 = 0,
       case when i % 5 = 0 then 'Caller: secret words ' || i end, case when i % 6 = 0 then 'https://rec.invalid/a' || i end, 'Call ' || i,
       i in (17, 170, 341) or i % 90 = 0, case when i in (17, 170, 341) or i % 90 = 0 then now() end, case when i % 90 = 0 then now() end,
       case when i % 12 = 0 then '{"recording_consent": false}'::jsonb when i % 9 = 0 then jsonb_build_object('followed_up_at', now()) else '{}'::jsonb end, 60
  from generate_series(1, 360) i;
insert into public.calls (business_id, direction, status, from_number, started_at, created_at, summary, transcript)
select 'b3000000-0000-0000-0000-0000000000b1', 'inbound', 'completed', '+1555400' || i, now() - make_interval(mins => i), now() - make_interval(mins => i), 'Beta call', 'Beta transcript'
  from generate_series(1, 5) i;
-- follow-ups on a few missed calls
insert into public.callbacks (business_id, call_id, status, reason, contact_number, due_at)
select business_id, id, 'scheduled', 'missed_call', from_number, now() + interval '1 day' from public.calls
 where business_id = 'b3000000-0000-0000-0000-0000000000a1' and status = 'missed' and from_number like '+1555300%' order by created_at limit 10
on conflict do nothing;

-- conversations: 260 for Alpha (texts and emails, interleaved in time with the calls), each with messages; some
-- unread, some handed to a person; 20 belong to calls and are shown through the call
insert into public.conversations (business_id, customer_id, channel, status, ai_handled, last_message_at, created_at, last_inbound_at, last_read_at, handover_at)
select 'b3000000-0000-0000-0000-0000000000a1',
       (select id from public.customers c where c.business_id = 'b3000000-0000-0000-0000-0000000000a1' and c.first_name = 'Lead' || (1 + i % 1200)),
       case when i % 2 = 0 then 'sms' else 'email' end, case when i % 13 = 0 then 'closed' else 'open' end, i % 4 <> 0,
       now() - make_interval(mins => 41 * i), now() - make_interval(mins => 41 * i) - interval '1 day',
       case when i % 3 = 0 then now() - make_interval(mins => 41 * i) end, case when i % 6 = 0 then now() end,
       case when i % 4 = 0 then now() - make_interval(mins => 41 * i) end
  from generate_series(1, 260) i;
insert into public.conversation_messages (conversation_id, sender_type, message_type, content, created_at)
select x.id, case when g % 2 = 0 then 'customer' else 'ai' end, 'text', 'Message ' || g || ' ' || repeat('long body ', 60), x.last_message_at - make_interval(mins => 5 - g)
  from public.conversations x cross join generate_series(1, 5) g
 where x.business_id = 'b3000000-0000-0000-0000-0000000000a1';
update public.calls c set conversation_id = x.id
  from (select id, row_number() over (order by last_message_at desc) n from public.conversations where business_id = 'b3000000-0000-0000-0000-0000000000a1') x,
       (select id, row_number() over (order by created_at desc) n from public.calls where business_id = 'b3000000-0000-0000-0000-0000000000a1') y
 where c.id = y.id and x.n = y.n * 7 and x.n <= 140;
insert into public.conversations (business_id, channel, status, last_message_at)
select 'b3000000-0000-0000-0000-0000000000b1', 'sms', 'open', now() - make_interval(mins => i) from generate_series(1, 5) i;

