-- Cross-business isolation and role matrix, on a restored baseline (tests/security/run.sh). Test data only.
-- Business A has one member of every role; business B holds "secret" rows marked ZZSECRETB.
--   1. Every table and view with a business_id: no A member (any role) and no outsider sees a B row.
--   2. Direct writes into B are refused for every role; in A, viewers can't write customers.
--   3. Every database function a signed-in user may call that takes a business id is called with B's id (other
--      arguments empty) as A's owner and as an outsider: no answer may contain B's data, and B's rows must be unchanged.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

create or replace function pg_temp.act(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated', 'aal', 'aal1', 'amr', json_build_array(json_build_object('method', 'password')))::text, false);
  set role authenticated;
end $$;

insert into auth.users (id, email, email_confirmed_at)
select ('e0000000-0000-0000-0000-00000000000' || i)::uuid, 'u' || i || '@iso.test', now() from generate_series(1, 7) i;
insert into public.businesses (id, name) values ('a1000000-0000-0000-0000-00000000000a', 'Alpha'), ('b1000000-0000-0000-0000-00000000000b', 'ZZSECRETB Beta');
insert into public.business_members (business_id, user_id, role, status) values
  ('a1000000-0000-0000-0000-00000000000a', 'e0000000-0000-0000-0000-000000000001', 'owner', 'active'),
  ('a1000000-0000-0000-0000-00000000000a', 'e0000000-0000-0000-0000-000000000002', 'admin', 'active'),
  ('a1000000-0000-0000-0000-00000000000a', 'e0000000-0000-0000-0000-000000000003', 'manager', 'active'),
  ('a1000000-0000-0000-0000-00000000000a', 'e0000000-0000-0000-0000-000000000004', 'staff', 'active'),
  ('a1000000-0000-0000-0000-00000000000a', 'e0000000-0000-0000-0000-000000000005', 'viewer', 'active'),
  ('b1000000-0000-0000-0000-00000000000b', 'e0000000-0000-0000-0000-000000000006', 'owner', 'active');
-- user 7 belongs to no business
insert into public.customers (id, business_id, first_name, phone, email) values
  ('c1000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-00000000000a', 'Ana', '+15550000001', 'ana@a.test'),
  ('c1000000-0000-0000-0000-00000000000b', 'b1000000-0000-0000-0000-00000000000b', 'ZZSECRETB', '+15550000002', 'zzsecretb@b.test');
insert into public.calls (business_id, customer_id, direction, transcript, from_number) values
  ('a1000000-0000-0000-0000-00000000000a', 'c1000000-0000-0000-0000-00000000000a', 'inbound', 'hello', '+15550000001'),
  ('b1000000-0000-0000-0000-00000000000b', 'c1000000-0000-0000-0000-00000000000b', 'inbound', 'ZZSECRETB transcript', '+15550000002');
insert into public.appointments (business_id, customer_id, title, start_time, end_time) values
  ('a1000000-0000-0000-0000-00000000000a', 'c1000000-0000-0000-0000-00000000000a', 'Cut', now() + interval '1 day', now() + interval '1 day 1 hour'),
  ('b1000000-0000-0000-0000-00000000000b', 'c1000000-0000-0000-0000-00000000000b', 'ZZSECRETB visit', now() + interval '1 day', now() + interval '1 day 1 hour');
insert into public.conversations (business_id, customer_id, channel) values
  ('a1000000-0000-0000-0000-00000000000a', 'c1000000-0000-0000-0000-00000000000a', 'sms'),
  ('b1000000-0000-0000-0000-00000000000b', 'c1000000-0000-0000-0000-00000000000b', 'sms');
insert into public.callbacks (business_id, customer_id, summary, contact_number) values
  ('b1000000-0000-0000-0000-00000000000b', 'c1000000-0000-0000-0000-00000000000b', 'ZZSECRETB call back', '+15550000002');
insert into public.business_invitations (business_id, email, owner_name, invited_by, role, status) values
  ('b1000000-0000-0000-0000-00000000000b', 'zzsecretb-invitee@b.test', 'ZZSECRETB', 'e0000000-0000-0000-0000-000000000006', 'staff', 'sent');

-- B's footprint: rows per table with business_id = B, plus a digest of the seeded rows
create function pg_temp.b_footprint() returns text language plpgsql as $$
declare t record; n bigint; acc text := '';
begin
  for t in select c.table_name from information_schema.columns c join information_schema.tables x using (table_schema, table_name)
           where c.table_schema = 'public' and c.column_name = 'business_id' and x.table_type = 'BASE TABLE' order by 1 loop
    execute format('select count(*) from public.%I where business_id = %L', t.table_name, 'b1000000-0000-0000-0000-00000000000b') into n;
    if n > 0 then acc := acc || t.table_name || '=' || n || ';'; end if;
  end loop;
  return acc || md5((select string_agg(x::text, '|' order by x::text) from (
    select row(c.*)::text x from public.customers c where business_id = 'b1000000-0000-0000-0000-00000000000b'
    union all select row(c.*)::text from public.calls c where business_id = 'b1000000-0000-0000-0000-00000000000b'
    union all select row(a.*)::text from public.appointments a where business_id = 'b1000000-0000-0000-0000-00000000000b'
    union all select row(b.*)::text from public.callbacks b where business_id = 'b1000000-0000-0000-0000-00000000000b'
    union all select row(m.*)::text from public.business_members m where business_id = 'b1000000-0000-0000-0000-00000000000b'
    union all select row(i.*)::text from public.business_invitations i where business_id = 'b1000000-0000-0000-0000-00000000000b'
    union all select row(z.*)::text from public.businesses z where id = 'b1000000-0000-0000-0000-00000000000b') q));
end $$;
create table pg_temp.before as select pg_temp.b_footprint() fp;
grant select on pg_temp.before to authenticated;

-- 1. reads
reset role;
do $$ declare u int; t record; n bigint; leaks text := ''; checked int := 0;
begin
  for u in select unnest(array[1, 2, 3, 4, 5, 7]) loop
    perform pg_temp.act(('e0000000-0000-0000-0000-00000000000' || u)::uuid);
    for t in select c.table_name from information_schema.columns c where c.table_schema = 'public' and c.column_name = 'business_id' order by 1 loop
      begin
        execute format('select count(*) from public.%I where business_id is distinct from %L', t.table_name, 'a1000000-0000-0000-0000-00000000000a') into n;
        checked := checked + 1;
        if n > 0 then leaks := leaks || format('user%s:%s(%s) ', u, t.table_name, n); end if;
      exception when insufficient_privilege then checked := checked + 1;   -- no access at all is fine
      end;
    end loop;
    select count(*) into n from public.businesses where id <> 'a1000000-0000-0000-0000-00000000000a';
    if n > 0 then leaks := leaks || format('user%s:businesses ', u); end if;
    reset role;
  end loop;
  assert leaks = '', 'cross-business rows visible: ' || leaks;
  raise notice 'PASS reads: % table/view checks across owner, admin, manager, staff, viewer and an outsider; none sees business B', checked;
end $$;

-- 2. writes
reset role;
do $$ declare u int; ok int; bad text := '';
begin
  for u in select unnest(array[1, 2, 3, 4, 5, 7]) loop
    perform pg_temp.act(('e0000000-0000-0000-0000-00000000000' || u)::uuid);
    begin insert into public.customers (business_id, first_name) values ('b1000000-0000-0000-0000-00000000000b', 'x'); bad := bad || 'insertB:' || u || ' ';
    exception when insufficient_privilege then null; end;
    update public.customers set first_name = 'pwned' where business_id = 'b1000000-0000-0000-0000-00000000000b';
    get diagnostics ok = row_count; if ok > 0 then bad := bad || 'updateB:' || u || ' '; end if;
    begin delete from public.calls where business_id = 'b1000000-0000-0000-0000-00000000000b'; get diagnostics ok = row_count;
      if ok > 0 then bad := bad || 'deleteB:' || u || ' '; end if;
    exception when insufficient_privilege then null; end;
    reset role;
  end loop;
  -- role matrix inside A: viewer cannot add a customer; staff can
  perform pg_temp.act('e0000000-0000-0000-0000-000000000005');
  begin insert into public.customers (business_id, first_name) values ('a1000000-0000-0000-0000-00000000000a', 'v'); bad := bad || 'viewer-insertA ';
  exception when insufficient_privilege then null; end;
  reset role;
  perform pg_temp.act('e0000000-0000-0000-0000-000000000004');
  insert into public.customers (business_id, first_name) values ('a1000000-0000-0000-0000-00000000000a', 'staff-added');
  reset role;
  assert bad = '', 'writes allowed: ' || bad;
  raise notice 'PASS writes: no role can insert, update or delete business B rows; a viewer cannot add customers in A, staff can';
end $$;

-- 3. every callable function that takes a business id, called with B's id
reset role;
create table pg_temp.fn_results (who int, fn text, outcome text, leaked boolean);
grant all on pg_temp.fn_results to authenticated;
do $$ declare u int; f record; sql text; res text; outcome text; tried int := 0;
begin
  set local statement_timeout = '5s';
  for u in select unnest(array[1, 7]) loop
    for f in
      select p.oid, p.proname, p.proargnames, p.proargtypes::oid[] types, p.pronargs, p.proretset, p.prorettype
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.prokind = 'f' and p.provariadic = 0
        and has_function_privilege('authenticated', p.oid, 'execute')
        and p.proargnames is not null and array_length(p.proargnames, 1) >= p.pronargs
        and exists (select 1 from generate_subscripts(p.proargtypes::oid[], 1) i
                    where (p.proargtypes::oid[])[i] = 'uuid'::regtype and p.proargnames[i + 1] ~ '^p_(business_id|business|bid)$')
        and p.proname not in ('zella_pre_request')
      order by p.proname
    loop
      sql := format('select %s(%s)', f.oid::regproc, (
        select string_agg(format('%I => %s', f.proargnames[i + 1],
                 case when f.types[i] = 'uuid'::regtype and f.proargnames[i + 1] ~ '^p_(business_id|business|bid)$'
                      then quote_literal('b1000000-0000-0000-0000-00000000000b') || '::uuid'
                      else 'null::' || format_type(f.types[i], null) end), ', ' order by i)
        from generate_subscripts(f.types, 1) i));
      if f.proretset then sql := format('select string_agg(x::text, %L) from (%s) x', '|', replace(sql, 'select ', 'select * from ')); end if;
      perform pg_temp.act(('e0000000-0000-0000-0000-00000000000' || u)::uuid);
      begin
        execute 'select (' || sql || ')::text' into res;
        outcome := 'ok';
      exception when others then res := null; outcome := left(sqlstate || ' ' || sqlerrm, 120);
      end;
      reset role;
      tried := tried + 1;
      insert into pg_temp.fn_results values (u, f.proname, outcome, coalesce(res, '') ilike '%zzsecretb%');
    end loop;
  end loop;
  raise notice 'functions called: %', tried;
end $$;

reset role;
do $$ declare leaks text; changed text; n int;
begin
  select string_agg(format('user%s:%s', who, fn), ', ') into leaks from pg_temp.fn_results where leaked;
  select count(*) into n from pg_temp.fn_results;
  assert n > 50, 'too few functions exercised: ' || n;
  assert leaks is null, 'functions returned business B data: ' || leaks;
  select case when pg_temp.b_footprint() = fp then null else 'before ' || fp || ' after ' || pg_temp.b_footprint() end into changed from pg_temp.before;
  assert changed is null, 'business B changed by A owner / outsider calls: ' || changed;
  raise notice 'PASS functions: % calls with business B''s id (as A''s owner and an outsider) returned none of B''s data and changed nothing in B', n;
end $$;

-- positive control: B's own owner gets B's data from the same probe, so the probe can see a leak
reset role;
truncate pg_temp.fn_results;
do $$ declare u int; f record; sql text; res text; outcome text; tried int := 0;
begin
  set local statement_timeout = '5s';
  for u in select unnest(array[6]) loop
    for f in
      select p.oid, p.proname, p.proargnames, p.proargtypes::oid[] types, p.pronargs, p.proretset, p.prorettype
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.prokind = 'f' and p.provariadic = 0
        and has_function_privilege('authenticated', p.oid, 'execute')
        and p.proargnames is not null and array_length(p.proargnames, 1) >= p.pronargs
        and exists (select 1 from generate_subscripts(p.proargtypes::oid[], 1) i
                    where (p.proargtypes::oid[])[i] = 'uuid'::regtype and p.proargnames[i + 1] ~ '^p_(business_id|business|bid)$')
        and p.proname not in ('zella_pre_request')
      order by p.proname
    loop
      sql := format('select %s(%s)', f.oid::regproc, (
        select string_agg(format('%I => %s', f.proargnames[i + 1],
                 case when f.types[i] = 'uuid'::regtype and f.proargnames[i + 1] ~ '^p_(business_id|business|bid)$'
                      then quote_literal('b1000000-0000-0000-0000-00000000000b') || '::uuid'
                      else 'null::' || format_type(f.types[i], null) end), ', ' order by i)
        from generate_subscripts(f.types, 1) i));
      if f.proretset then sql := format('select string_agg(x::text, %L) from (%s) x', '|', replace(sql, 'select ', 'select * from ')); end if;
      perform pg_temp.act(('e0000000-0000-0000-0000-00000000000' || u)::uuid);
      begin
        execute 'select (' || sql || ')::text' into res;
        outcome := 'ok';
      exception when others then res := null; outcome := left(sqlstate || ' ' || sqlerrm, 120);
      end;
      reset role;
      tried := tried + 1;
      insert into pg_temp.fn_results values (u, f.proname, outcome, coalesce(res, '') ilike '%zzsecretb%');
    end loop;
  end loop;
  null;
end $$;

reset role;
do $$ declare n int; begin
  select count(*) into n from pg_temp.fn_results where leaked;
  assert n > 0, 'probe did not see B''s data even as B''s owner: the leak check would be blind';
  raise notice 'PASS control: as B''s own owner the same probe finds B''s data in % functions', n;
end $$;
