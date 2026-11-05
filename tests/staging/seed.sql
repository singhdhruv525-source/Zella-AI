-- Synthetic staging data (no production data). Two parts:
--   P: four businesses shaped like production on 5 Nov 2026 (read-only profile: counts and statuses only):
--      salon in testing (3 owners, 1 customer, 4 scheduled + 1 cancelled appointments, 4 calls, 6 opening hours,
--      2 preset record types, no records), restaurant at automation setup, dental and restaurant at business info.
--      Two of the salon's calls get transcripts so the privacy change has something to hide (production has none yet).
--   S: one active business per industry (28) with every role, customers, appointments, calls with transcripts, and two
--      records in every preset record type with every field filled (plain access codes included), one archived and
--      one closed where the type has a closed status: the shapes production will reach as customers use the CRM.
\set ON_ERROR_STOP on
create or replace function pg_temp.u(t text) returns uuid language sql immutable as $$ select md5(t)::uuid $$;
create or replace function pg_temp.val(f jsonb, n int) returns jsonb language sql as $$
  select case f ->> 'type'
    when 'number' then to_jsonb(3 + n) when 'bool' then 'true'::jsonb
    when 'date' then to_jsonb((current_date + 7 + n)::text) when 'datetime' then to_jsonb((now() + make_interval(days => 2 + n))::text)
    when 'select' then f -> 'options' -> 0 when 'email' then to_jsonb('person' || n || '@example.test')
    when 'phone' then to_jsonb('+1555555010' || n)
    else to_jsonb('Sample ' || (f ->> 'label') || ' ' || n || case when coalesce((f ->> 'unique')::boolean, false) then ' u' || md5(random()::text) else '' end) end
$$;

do $$
declare
  spec record; b uuid; n int := 0; r text; t record; f jsonb; d jsonb; i int; c uuid; rec uuid; roles text[] := array['owner','admin','manager','staff','viewer'];
begin
  -- P: production-shaped
  for spec in select * from (values (1, 'beauty-salon', 'testing', true), (2, 'restaurant', 'automation_setup', false),
                                    (3, 'dental', 'business_info', false), (4, 'restaurant', 'business_info', false)) v(k, slug, st, active) loop
    b := pg_temp.u('stg-p-' || spec.k);
    insert into public.businesses (id, name, timezone, is_active, onboarding_status, industry_id, country)
    values (b, 'Staging P' || spec.k, 'America/New_York', spec.active, spec.st, (select id from public.industries where slug = spec.slug), 'US');
  end loop;
  b := pg_temp.u('stg-p-1');
  for i in 1..3 loop
    insert into auth.users (id, email, email_confirmed_at) values (pg_temp.u('stg-p-1-owner' || i), 'p1owner' || i || '@staging.test', now());
    insert into public.business_members (business_id, user_id, role, status) values (b, pg_temp.u('stg-p-1-owner' || i), 'owner', 'active');
  end loop;
  insert into public.customers (id, business_id, first_name, last_name, phone) values (pg_temp.u('stg-p-1-c1'), b, 'Pat', 'Sample', '+15555550199');
  for i in 1..5 loop
    insert into public.appointments (business_id, customer_id, title, status, start_time, end_time)
    values (b, pg_temp.u('stg-p-1-c1'), 'Visit ' || i, case when i = 5 then 'cancelled' else 'scheduled' end, now() + make_interval(days => i), now() + make_interval(days => i, mins => 45));
  end loop;
  for i in 1..4 loop
    insert into public.calls (business_id, customer_id, direction, status, from_number, transcript, recording_url)
    values (b, pg_temp.u('stg-p-1-c1'), 'inbound', 'completed', '+15555550199', case when i <= 2 then 'Caller: synthetic words ' || i end, case when i <= 2 then 'https://recording.example.test/' || i end);
  end loop;
  for i in 1..6 loop insert into public.business_hours (business_id, weekday, opens, closes) values (b, i, '09:00', '17:00'); end loop;
  perform public.zella_apply_crm_preset(b);

  -- S: one per industry
  for spec in select id, slug from public.industries order by slug loop
    n := n + 1;
    b := pg_temp.u('stg-s-' || spec.slug);
    insert into public.businesses (id, name, timezone, is_active, onboarding_status, industry_id, country)
    values (b, 'Staging ' || spec.slug, 'America/New_York', true, 'active', spec.id, 'US');
    foreach r in array roles loop
      insert into auth.users (id, email, email_confirmed_at) values (pg_temp.u('stg-s-' || spec.slug || '-' || r), r || '.' || spec.slug || '@staging.test', now());
      insert into public.business_members (business_id, user_id, role, status) values (b, pg_temp.u('stg-s-' || spec.slug || '-' || r), r, 'active');
    end loop;
    for i in 1..3 loop
      insert into public.customers (id, business_id, first_name, last_name, phone) values (pg_temp.u('stg-s-' || spec.slug || '-c' || i), b, 'Sam' || i, 'Synthetic', '+1555555020' || i);
    end loop;
    for i in 1..5 loop insert into public.business_hours (business_id, weekday, opens, closes) values (b, i, '08:00', '18:00'); end loop;
    insert into public.appointments (business_id, customer_id, title, status, start_time, end_time)
    values (b, pg_temp.u('stg-s-' || spec.slug || '-c1'), 'Booked', 'scheduled', now() + interval '1 day', now() + interval '1 day 1 hour'),
           (b, pg_temp.u('stg-s-' || spec.slug || '-c2'), 'Done', 'completed', now() - interval '1 day', now() - interval '23 hours');
    insert into public.calls (business_id, customer_id, direction, status, from_number, transcript, recording_url)
    values (b, pg_temp.u('stg-s-' || spec.slug || '-c1'), 'inbound', 'completed', '+15555550201', 'Caller: synthetic transcript', 'https://recording.example.test/s'),
           (b, null, 'inbound', 'missed', '+15555550299', null, null);
    perform public.zella_apply_crm_preset(b);
    for t in select * from public.crm_record_types where business_id = b loop
      for i in 1..2 loop
        d := '{}';
        for f in select * from jsonb_array_elements(t.fields) loop d := d || jsonb_build_object(f ->> 'key', pg_temp.val(f, i)); end loop;
        insert into public.crm_records (business_id, type_key, title, status, customer_id, assigned_to, data, created_by,
                                        archived_at, closed_at)
        values (b, t.key, t.singular || ' ' || i, case when i = 2 and cardinality(t.closed_statuses) > 0 then t.closed_statuses[1] else t.statuses -> 0 ->> 'key' end,
                case when t.link_person then pg_temp.u('stg-s-' || spec.slug || '-c' || i) end,
                case when i = 1 then pg_temp.u('stg-s-' || spec.slug || '-staff') end, d, pg_temp.u('stg-s-' || spec.slug || '-owner'),
                null, case when i = 2 and cardinality(t.closed_statuses) > 0 then now() end);
      end loop;
      -- a third, archived record
      insert into public.crm_records (business_id, type_key, title, status, data, archived_at) values (b, t.key, t.singular || ' archived', t.statuses -> 0 ->> 'key', '{}', now());
    end loop;
  end loop;
  -- as in production (5 Nov): every business has all of its industry's modules switched on
  insert into public.business_modules (business_id, module_id, enabled)
  select x.id, im.id, true from public.businesses x join public.industry_modules im on im.industry_id = x.industry_id
  where x.id in (select pg_temp.u('stg-p-' || k) from generate_series(1, 4) k) or x.name like 'Staging %'
  on conflict do nothing;
  raise notice 'staging seed: % industry businesses + 4 production-shaped', n;
end $$;
