-- Checks after the ten migrations on staging (tests/staging/run.sh). :before is the "before" snapshot.
\set ON_ERROR_STOP on
create temp table before_snap as select (:'before')::jsonb s;

-- 1. nothing lost
do $$ declare t text; n_before bigint; n_after bigint; lost text := '';
begin
  foreach t in array array['businesses', 'business_members', 'customers', 'appointments', 'calls', 'crm_records', 'business_hours', 'automations', 'crm_tasks', 'waitlist_entries'] loop
    n_before := ((select s from before_snap) #>> array['counts', t])::bigint;
    execute format('select count(*) from public.%I', t) into n_after;
    if n_before is distinct from n_after then lost := lost || format('%s %s→%s ', t, n_before, n_after); end if;
  end loop;
  assert lost = '', 'row counts changed: ' || lost;
  assert not exists (select 1 from public.backup_20261104_types b where not exists (select 1 from public.crm_record_types t where t.id = b.id)), 'a record type disappeared';
  raise notice 'PASS nothing lost: businesses, members, customers, appointments, calls, records, hours, automations, tasks, waitlist unchanged; every record type still there';
end $$;

-- 2. every record's data is what it was, with private values moved (not changed)
do $$ declare bad int; moved int;
begin
  select count(*) into bad from public.backup_20261104_records b join public.crm_records r on r.id = b.id
   where r.data || coalesce((select jsonb_object_agg(field_key, value) from public.crm_record_secrets s where s.record_id = r.id), '{}') <> b.data;
  select count(*) into moved from public.crm_record_secrets;
  assert bad = 0, bad || ' records changed';
  assert not exists (select 1 from public.crm_record_types t join public.crm_records r on r.business_id = t.business_id and r.type_key = t.key, jsonb_array_elements(t.fields) f
                      where coalesce((f ->> 'sensitive')::boolean, false) and r.data ? (f ->> 'key')), 'a private value is still in record data';
  raise notice 'PASS every record''s data unchanged; % private values moved out of record data, none left behind', moved;
end $$;

-- 3. every live record still passes the new write path unchanged (each in its own rolled-back step)
do $$ declare r record; ok int := 0; failed text := ''; skipped int := 0;
begin
  for r in select x.*, t.enabled from public.crm_records x join public.crm_record_types t on t.business_id = x.business_id and t.key = x.type_key where x.archived_at is null loop
    if not r.enabled then skipped := skipped + 1; continue; end if;
    begin
      perform public.zella_crm_write_record(null, 'staff', r.business_id, r.type_key, r.id, r.title, r.status, r.customer_id, r.assigned_to, r.due_at,
        r.data || coalesce((select jsonb_object_agg(field_key, value) from public.crm_record_secrets s where s.record_id = r.id), '{}'));
      raise exception 'ZELLA_CHECK_ROLLBACK';
    exception when others then
      if sqlerrm = 'ZELLA_CHECK_ROLLBACK' then ok := ok + 1; else failed := failed || r.type_key || ':' || sqlerrm || ' '; end if;
    end;
  end loop;
  assert failed = '', 'records failing the write path: ' || left(failed, 400);
  raise notice 'PASS % live records re-save through the new write path unchanged (% in switched-off types skipped)', ok, skipped;
end $$;

-- 4. no type the business had on was switched off, except empty types replaced by a new industry preset
do $$ declare n int; detail text;
begin
  select count(*), string_agg(t.key, ', ') into n, detail from public.backup_20261104_types b join public.crm_record_types t on t.id = b.id
   where b.enabled and not t.enabled and exists (select 1 from public.crm_records r where r.business_id = t.business_id and r.type_key = t.key);
  assert n = 0, 'types with records switched off: ' || detail;
  select string_agg(i.slug || ':' || t.key, ', ') into detail from public.backup_20261104_types b join public.crm_record_types t on t.id = b.id
    join public.businesses x on x.id = t.business_id join public.industries i on i.id = x.industry_id where b.enabled and not t.enabled;
  raise notice 'PASS no record type holding records was switched off (empty types replaced by a new preset: %)', coalesce(detail, 'none');
  select count(*) into n from public.crm_record_types t where not exists (select 1 from public.backup_20261104_types b where b.id = t.id);
  raise notice 'INFO % record types added; existing businesses get them switched off: %', n,
    (select count(*) from public.crm_record_types t where not exists (select 1 from public.backup_20261104_types b where b.id = t.id) and not t.enabled);
end $$;

-- 5. every business: capabilities, navigation, Today, readiness and receptionist instructions build without error
do $$ declare b record; n int := 0; nav int := 0; v_owner uuid;
begin
  for b in select id from public.businesses loop
    perform public.zella_capabilities(b.id), public.zella_today_operations(b.id), public.zella_business_readiness(b.id), public.zella_brain_prompt_base(b.id);
    -- the menu is built for a signed-in member (production rule): as the business's owner, where it has one yet
    select user_id into v_owner from public.business_members where business_id = b.id and role = 'owner' and status = 'active' limit 1;
    if v_owner is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated', 'aal', 'aal1')::text, true);
      assert public.zella_workspace_navigation(b.id) ? 'capabilities', 'menu without capabilities';
      perform set_config('request.jwt.claims', '', true);
      nav := nav + 1;
    end if;
    n := n + 1;
  end loop;
  perform public.zella_run_industry_timers();
  raise notice 'PASS capabilities, Today, readiness and receptionist instructions for all % businesses; menu with capabilities for the % with an owner; industry timers run', n, nav;
end $$;

-- 6. existing bookings stay where scheduling is now off, and new ones are refused
do $$ declare e uuid := md5('stg-s-ecommerce')::uuid;
begin
  assert (select count(*) from public.appointments where business_id = e) = 2, 'e-commerce bookings kept';
  begin insert into public.appointments (business_id, title, start_time, end_time) values (e, 'x', now(), now() + interval '1 hour'); raise exception 'booked while off';
  exception when others then if sqlerrm not like 'CAPABILITY_OFF:scheduling%' then raise; end if; end;
  raise notice 'PASS e-commerce: earlier bookings kept, new bookings refused';
end $$;

-- 7. roles on real-shaped data: transcripts, private values, writes, money
set role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', md5('stg-s-plumbing-staff')::uuid, 'role', 'authenticated', 'aal', 'aal1')::text, false);
do $$ declare p uuid := (select id from public.crm_records where business_id = md5('stg-s-plumbing')::uuid and type_key = 'properties' and title = 'Property 2');
               mine uuid := (select id from public.crm_records where business_id = md5('stg-s-plumbing')::uuid and type_key = 'properties' and title = 'Property 1');
begin
  assert (public.zella_record_secrets(mine) ->> 'allowed')::boolean, 'staff assigned to the property read its code';
  begin perform transcript from public.calls limit 1; raise exception 'staff read transcripts from the table';
  exception when insufficient_privilege then null; end;
  assert (select count(*) from public.calls_view where transcript is not null) = 0, 'staff saw a transcript';
  assert (select count(*) from public.calls_view) = 2, 'staff see their business''s calls';
  assert not (public.zella_record_secrets(p) ->> 'allowed')::boolean, 'staff read an unassigned property''s access code';
  perform public.zella_save_record(md5('stg-s-plumbing')::uuid, 'properties', p, (select title from public.crm_records where id = p), null, null, null, null,
    (select data - 'access' from public.crm_records where id = p));
end $$;
select set_config('request.jwt.claims', json_build_object('sub', md5('stg-s-plumbing-manager')::uuid, 'role', 'authenticated', 'aal', 'aal1')::text, false);
do $$ declare p uuid := (select id from public.crm_records where business_id = md5('stg-s-plumbing')::uuid and type_key = 'properties' and archived_at is null order by title limit 1);
begin
  assert (select count(*) from public.calls_view where transcript is not null) = 1, 'manager reads the transcript';
  assert public.zella_record_secrets(p) #>> '{values,access}' like 'Sample Access instructions%', 'manager reads the moved access code';
  perform public.zella_create_charge(md5('stg-s-plumbing')::uuid, 'invoice', 1000);
end $$;
select set_config('request.jwt.claims', json_build_object('sub', md5('stg-s-plumbing-viewer')::uuid, 'role', 'authenticated', 'aal', 'aal1')::text, false);
do $$ begin
  begin perform public.zella_save_record(md5('stg-s-plumbing')::uuid, 'jobs', null, 'x', null); raise exception 'viewer wrote a record';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
  assert (select count(*) from public.customer_charges) = 0, 'viewer sees money';
end $$;
select set_config('request.jwt.claims', json_build_object('sub', md5('stg-s-dental-owner')::uuid, 'role', 'authenticated', 'aal', 'aal1')::text, false);
do $$ begin
  assert (select count(*) from public.customer_charges) = 0, 'another business''s owner sees plumbing money';
  assert (select count(*) from public.calls_view where business_id = md5('stg-s-plumbing')::uuid) = 0, 'another business sees plumbing calls';
  begin perform public.zella_record_secrets((select id from public.crm_records where business_id = md5('stg-s-plumbing')::uuid and type_key = 'properties' limit 1));
    raise exception 'another business read an access code';
  exception when others then if sqlerrm not like '%NOT_ALLOWED%' then raise; end if; end;
end $$;
reset role;
delete from public.customer_charges where business_id = md5('stg-s-plumbing')::uuid;
delete from public.audit_logs where business_id = md5('stg-s-plumbing')::uuid and action = 'charge_created';
do $$ begin raise notice 'PASS roles on staging data: staff no transcripts or codes, manager both, viewer no writes or money, other businesses nothing'; end $$;
