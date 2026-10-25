-- Zella - customer records: adding, change history, duplicates, merge, timeline (checklist 101, 102, 104, 113). Safe to run more than once.
-- Needs zella_workflows.sql (customers, matching, duplicate_reviews) and zella_ops_extras.sql.
--   101 zella_staff_add_customer: staff add a person through the same duplicate check as the assistant
--   102 changes to name, phone, email and contact choices are recorded (field names only), and a changed phone/email is checked for duplicates
--   104 a daily scan finds people who share a phone number or email; staff merge or keep them separate
--   113 zella_customer_timeline: calls, texts, emails, appointments, callbacks, tasks and changes in one list

-- 101
create or replace function public.zella_staff_add_customer(p_business_id uuid, p_first_name text, p_last_name text default null, p_phone text default null, p_email text default null, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_m record; v_id uuid;
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager', 'staff']) then raise exception 'NOT_ALLOWED'; end if;
  if nullif(trim(coalesce(p_first_name, '')), '') is null then raise exception 'NAME_REQUIRED'; end if;
  if public.zella_digits(p_phone) is null and nullif(trim(coalesce(p_email, '')), '') is null then raise exception 'NO_CONTACT'; end if;
  if nullif(trim(coalesce(p_email, '')), '') is not null and p_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'BAD_EMAIL'; end if;
  select * into v_m from public.zella_match_customer(p_business_id, p_phone, p_email);
  if v_m.certainty = 'exact' then return jsonb_build_object('result', 'exists', 'customer_id', v_m.customer_id); end if;
  if v_m.certainty = 'uncertain' then
    insert into public.duplicate_reviews (business_id, customer_id, incoming)
    values (p_business_id, v_m.customer_id, jsonb_build_object('first_name', p_first_name, 'last_name', p_last_name, 'phone', p_phone, 'email', p_email, 'source', 'staff', 'notes', left(p_notes, 1000)));
    return jsonb_build_object('result', 'needs_review', 'customer_id', v_m.customer_id);
  end if;
  insert into public.customers (business_id, first_name, last_name, phone, email, source, notes)
  values (p_business_id, left(trim(p_first_name), 100), left(nullif(trim(coalesce(p_last_name, '')), ''), 100), left(nullif(trim(coalesce(p_phone, '')), ''), 30), lower(left(nullif(trim(coalesce(p_email, '')), ''), 200)), 'staff', left(p_notes, 2000))
  returning id into v_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data) values (p_business_id, auth.uid(), 'customer.added', 'customer', v_id, jsonb_build_object('source', 'staff'));
  return jsonb_build_object('result', 'created', 'customer_id', v_id);
end $$;
revoke execute on function public.zella_staff_add_customer(uuid, text, text, text, text, text) from public, anon;
grant execute on function public.zella_staff_add_customer(uuid, text, text, text, text, text) to authenticated, service_role;

-- 102: what changed (field names only, never the old or new values)
create or replace function public.zella_customer_change_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare f text[] := '{}'; dup uuid;
begin
  if new.first_name is distinct from old.first_name then f := array_append(f, 'first_name'::text); end if;
  if new.last_name is distinct from old.last_name then f := array_append(f, 'last_name'::text); end if;
  if new.phone is distinct from old.phone then f := array_append(f, 'phone'::text); end if;
  if new.email is distinct from old.email then f := array_append(f, 'email'::text); end if;
  if new.do_not_contact is distinct from old.do_not_contact then f := array_append(f, 'do_not_contact'::text); end if;
  if new.do_not_sms is distinct from old.do_not_sms then f := array_append(f, 'do_not_sms'::text); end if;
  if new.do_not_email is distinct from old.do_not_email then f := array_append(f, 'do_not_email'::text); end if;
  if new.do_not_call is distinct from old.do_not_call then f := array_append(f, 'do_not_call'::text); end if;
  if new.preferred_channel is distinct from old.preferred_channel then f := array_append(f, 'preferred_channel'::text); end if;
  if new.status is distinct from old.status then f := array_append(f, 'status'::text); end if;
  if cardinality(f) = 0 then return new; end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (new.business_id, auth.uid(), 'customer.updated', 'customer', new.id, jsonb_build_object('fields', to_jsonb(f)));
  if (f && array['phone', 'email']) and new.status = 'active' then
    select c.id into dup from public.customers c
     where c.business_id = new.business_id and c.id <> new.id and c.status = 'active'
       and ((public.zella_digits(new.phone) is not null and public.zella_digits(c.phone) = public.zella_digits(new.phone)) or (nullif(new.email, '') is not null and lower(c.email) = lower(new.email)))
     limit 1;
    if dup is not null and not exists (select 1 from public.duplicate_reviews r where r.business_id = new.business_id and r.status = 'open'
                                         and ((r.customer_id = dup and r.incoming ->> 'duplicate_customer_id' = new.id::text) or (r.customer_id = new.id and r.incoming ->> 'duplicate_customer_id' = dup::text))) then
      insert into public.duplicate_reviews (business_id, customer_id, incoming)
      values (new.business_id, dup, jsonb_build_object('duplicate_customer_id', new.id, 'first_name', new.first_name, 'last_name', new.last_name, 'phone', new.phone, 'email', new.email, 'source', 'edit'));
    end if;
  end if;
  return new;
end $$;
drop trigger if exists zella_customer_change on public.customers;
create trigger zella_customer_change after update on public.customers for each row execute function public.zella_customer_change_trg();

-- 104: merge one record into another
create or replace function public.zella_merge_customers(p_business_id uuid, p_keep uuid, p_drop uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare k public.customers; d public.customers; t record; v_moved integer := 0; v_skipped text[] := '{}'; v_n integer;
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  if p_keep = p_drop then raise exception 'SAME_CUSTOMER'; end if;
  select * into k from public.customers where id = p_keep and business_id = p_business_id for update;
  select * into d from public.customers where id = p_drop and business_id = p_business_id for update;
  if k.id is null or d.id is null then raise exception 'NOT_FOUND'; end if;
  for t in select distinct c1.table_name from information_schema.columns c1 join information_schema.columns c2 on c2.table_schema = 'public' and c2.table_name = c1.table_name and c2.column_name = 'business_id'
            join information_schema.tables tb on tb.table_schema = 'public' and tb.table_name = c1.table_name and tb.table_type = 'BASE TABLE'
            where c1.table_schema = 'public' and c1.column_name = 'customer_id' and c1.table_name not in ('duplicate_reviews', 'email_unsubscribe_tokens', 'contact_consents', 'data_rights_requests') loop
    begin
      execute format('update public.%I set customer_id = $1 where customer_id = $2 and business_id = $3', t.table_name) using p_keep, p_drop, p_business_id;
      get diagnostics v_n = row_count; v_moved := v_moved + v_n;
    exception when others then v_skipped := v_skipped || t.table_name;
    end;
  end loop;
  update public.customers set
      first_name = coalesce(first_name, d.first_name), last_name = coalesce(last_name, d.last_name), phone = coalesce(phone, d.phone), email = coalesce(email, d.email),
      company_name = coalesce(company_name, d.company_name), date_of_birth = coalesce(date_of_birth, d.date_of_birth), address = coalesce(address, d.address),
      do_not_contact = coalesce(do_not_contact, false) or coalesce(d.do_not_contact, false), do_not_sms = coalesce(do_not_sms, false) or coalesce(d.do_not_sms, false),
      do_not_email = coalesce(do_not_email, false) or coalesce(d.do_not_email, false), do_not_call = coalesce(do_not_call, false) or coalesce(d.do_not_call, false),
      notes = case when nullif(d.notes, '') is null then notes else coalesce(notes || E'\n', '') || d.notes end,
      last_contacted_at = greatest(last_contacted_at, d.last_contacted_at), updated_at = now()
   where id = p_keep;
  update public.customers set status = 'archived', phone = null, email = null, notes = null, metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('merged_into', p_keep, 'merged_at', now()), updated_at = now() where id = p_drop;
  update public.duplicate_reviews set status = 'merged', resolved_by = auth.uid(), resolved_at = now()
   where business_id = p_business_id and status = 'open' and (customer_id in (p_keep, p_drop) and (incoming ->> 'duplicate_customer_id') in (p_keep::text, p_drop::text));
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (p_business_id, auth.uid(), 'customer.merged', 'customer', p_keep, jsonb_build_object('merged_from', p_drop, 'rows_moved', v_moved, 'tables_skipped', to_jsonb(v_skipped)));
  return jsonb_build_object('kept', p_keep, 'archived', p_drop, 'rows_moved', v_moved, 'tables_skipped', to_jsonb(v_skipped));
end $$;
revoke execute on function public.zella_merge_customers(uuid, uuid, uuid) from public, anon;
grant execute on function public.zella_merge_customers(uuid, uuid, uuid) to authenticated, service_role;

-- duplicate reviews that point at another existing record are resolved by merging (or keeping separate), never by creating a new person
do $$
declare d text; blk text;
begin
  d := pg_get_functiondef('public.zella_resolve_duplicate(uuid,text)'::regprocedure);
  if d not like '%duplicate_customer_id%' then
    blk := $b$  i := d.incoming;
  if i ? 'duplicate_customer_id' then
    if p_action = 'merge' then
      perform public.zella_merge_customers(d.business_id, d.customer_id, (i ->> 'duplicate_customer_id')::uuid);
      return d.customer_id;
    elsif p_action in ('keep_separate', 'dismiss') then
      update public.duplicate_reviews set status = case when p_action = 'dismiss' then 'dismissed' else 'kept_separate' end, resolved_by = auth.uid(), resolved_at = now() where id = p_review_id;
      return d.customer_id;
    end if;
    raise exception 'BAD_ACTION';
  end if;$b$;
    d := replace(d, '  i := d.incoming;', blk);
    if d not like '%duplicate_customer_id%' then raise exception 'PATCH_FAILED_RESOLVE'; end if;
    execute d;
  end if;
end $$;

-- daily scan
create or replace function public.zella_scan_duplicates() returns integer
language plpgsql security definer set search_path = public as $$
declare p record; n integer := 0; b uuid; v_biz uuid[] := '{}';
begin
  for p in
    select a.business_id, a.id as keep_id, o.id as other_id, o.first_name, o.last_name, o.phone, o.email
      from public.customers a join public.customers o on o.business_id = a.business_id and o.id > a.id and o.status = 'active'
     where a.status = 'active'
       and ((public.zella_digits(a.phone) is not null and length(public.zella_digits(a.phone)) >= 7 and public.zella_digits(a.phone) = public.zella_digits(o.phone))
         or (nullif(a.email, '') is not null and lower(a.email) = lower(o.email)))
       and not exists (select 1 from public.duplicate_reviews r where r.business_id = a.business_id and r.status in ('open', 'kept_separate', 'dismissed')
                         and r.incoming ->> 'duplicate_customer_id' in (a.id::text, o.id::text) and r.customer_id in (a.id, o.id))
     limit 200 loop
    insert into public.duplicate_reviews (business_id, customer_id, incoming)
    values (p.business_id, p.keep_id, jsonb_build_object('duplicate_customer_id', p.other_id, 'first_name', p.first_name, 'last_name', p.last_name, 'phone', p.phone, 'email', p.email, 'source', 'scan'));
    n := n + 1;
    if not (p.business_id = any (v_biz)) then v_biz := v_biz || p.business_id; end if;
  end loop;
  foreach b in array v_biz loop
    perform public.zella_notify_owners(b, 'duplicate_scan', 'Possible duplicate customers found', 'Some customers share a phone number or email. Review them in Customers.', 'info', 'customers');
  end loop;
  return n;
end $$;
revoke all on function public.zella_scan_duplicates() from public, anon, authenticated;
grant execute on function public.zella_scan_duplicates() to service_role;

-- 113
create or replace function public.zella_customer_timeline(p_business_id uuid, p_customer_id uuid, p_limit integer default 100)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_limit integer := greatest(1, least(coalesce(p_limit, 100), 300)); v_staff boolean;
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if not exists (select 1 from public.customers where id = p_customer_id and business_id = p_business_id) then raise exception 'NOT_FOUND'; end if;
  return coalesce((select jsonb_agg(e order by (e ->> 'at') desc) from (select e from (
    (select jsonb_build_object('type', 'call', 'at', coalesce(started_at, created_at), 'id', id, 'title', case direction when 'inbound' then 'Call from customer' else 'Call to customer' end,
            'detail', left(coalesce(summary, outcome_note, ''), 300), 'status', coalesce(outcome, status)) e
       from public.calls where business_id = p_business_id and customer_id = p_customer_id order by coalesce(started_at, created_at) desc limit v_limit)
    union all
    (select jsonb_build_object('type', 'text', 'at', created_at, 'id', id, 'title', case direction when 'inbound' then 'Text from customer' else 'Text to customer' end, 'detail', left(coalesce(message_body, ''), 200), 'status', status)
       from public.sms_messages where business_id = p_business_id and customer_id = p_customer_id order by created_at desc limit v_limit)
    union all
    (select jsonb_build_object('type', 'email', 'at', created_at, 'id', id, 'title', case direction when 'inbound' then 'Email from customer' else 'Email to customer' end, 'detail', left(coalesce(subject, ''), 200), 'status', status)
       from public.email_messages where business_id = p_business_id and customer_id = p_customer_id order by created_at desc limit v_limit)
    union all
    (select jsonb_build_object('type', 'appointment', 'at', start_time, 'id', id, 'title', coalesce(title, 'Appointment'), 'detail', '', 'status', status)
       from public.appointments where business_id = p_business_id and customer_id = p_customer_id order by start_time desc limit v_limit)
    union all
    (select jsonb_build_object('type', 'callback', 'at', created_at, 'id', id, 'title', 'Callback (' || reason || ')', 'detail', left(coalesce(summary, ''), 200), 'status', status)
       from public.callbacks where business_id = p_business_id and customer_id = p_customer_id order by created_at desc limit v_limit)
    union all
    (select jsonb_build_object('type', 'task', 'at', created_at, 'id', id, 'title', coalesce(title, kind), 'detail', '', 'status', status)
       from public.crm_tasks where business_id = p_business_id and customer_id = p_customer_id order by created_at desc limit v_limit)
    union all
    (select jsonb_build_object('type', 'change', 'at', created_at, 'id', id, 'title', 'Record ' || replace(action, 'customer.', ''), 'detail', coalesce(new_data ->> 'fields', ''), 'status', '')
       from public.audit_logs where business_id = p_business_id and entity_type = 'customer' and entity_id = p_customer_id order by created_at desc limit v_limit)
    ) x order by (e ->> 'at') desc limit v_limit) y), '[]'::jsonb);
end $$;
revoke execute on function public.zella_customer_timeline(uuid, uuid, integer) from public, anon;
grant execute on function public.zella_customer_timeline(uuid, uuid, integer) to authenticated, service_role;
