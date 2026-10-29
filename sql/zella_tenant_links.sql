-- Zella AI: every link from a business's record to a customer, a staff member or a team member must stay inside
-- that business.
--
-- Found in the end-to-end audit (docs/ZELLA_END_TO_END_AUDIT.md, finding H-1): row-level security checks the
-- row's own business_id, but not the ids it points at. A member of business A could save an appointment or
-- conversation that points at business B's customer, or assign work to a user of business B (directly, or through
-- zella_staff_create_callback, zella_staff_create_task and zella_update_callback). Functions that later read the
-- linked customer by id (for example the inbox reply) would then act on the other business's customer.
--
-- This adds one guard trigger to each such table. It runs last among the BEFORE triggers (name starts with zz_), only
-- checks a link when it is set or changed, and raises TENANT_MISMATCH. Existing rows were checked first: none
-- break the rule. Additive and safe to run again.

create or replace function public.zella_tenant_link_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  n jsonb := to_jsonb(new);
  o jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) end;
  v_business uuid := (n ->> 'business_id')::uuid;
  spec text; col text; kind text; v uuid;
begin
  foreach spec in array tg_argv loop
    col := split_part(spec, ':', 1);
    kind := split_part(spec, ':', 2);
    v := nullif(n ->> col, '')::uuid;
    continue when v is null;
    -- Unchanged links on an update are not re-checked (a member who later leaves keeps their old assignments).
    continue when o is not null and (o ->> col) is not distinct from (n ->> col) and (o ->> 'business_id') is not distinct from (n ->> 'business_id');
    if kind = 'customer' and not exists (select 1 from public.customers c where c.id = v and c.business_id = v_business) then
      raise exception 'TENANT_MISMATCH: % is not a customer of this business', col using errcode = '23514';
    elsif kind = 'staff' and not exists (select 1 from public.staff_members s where s.id = v and s.business_id = v_business) then
      raise exception 'TENANT_MISMATCH: % is not a staff member of this business', col using errcode = '23514';
    elsif kind = 'member' and not exists (select 1 from public.business_members m where m.user_id = v and m.business_id = v_business) then
      raise exception 'TENANT_MISMATCH: % is not a member of this business', col using errcode = '23514';
    end if;
  end loop;
  return new;
end $$;

revoke all on function public.zella_tenant_link_guard() from public, anon, authenticated;

do $$
declare t record;
begin
  for t in select * from (values
    ('appointment_reminders', array['customer_id:customer']),
    ('appointments',          array['customer_id:customer', 'assigned_to:member', 'staff_id:staff']),
    ('automation_runs',       array['customer_id:customer']),
    ('blocked_times',         array['staff_id:staff']),
    ('call_messages',         array['customer_id:customer']),
    ('callbacks',             array['customer_id:customer', 'assigned_to:member']),
    ('calls',                 array['customer_id:customer', 'assigned_to:member']),
    ('contact_consents',      array['customer_id:customer']),
    ('conversations',         array['customer_id:customer', 'assigned_to:member']),
    ('crm_records',           array['customer_id:customer', 'assigned_to:member']),
    ('crm_tasks',             array['customer_id:customer', 'assigned_to:member']),
    ('customer_requests',     array['customer_id:customer', 'assigned_to:member']),
    ('customers',             array['assigned_to:member']),
    ('data_rights_requests',  array['customer_id:customer']),
    ('duplicate_reviews',     array['customer_id:customer']),
    ('email_messages',        array['customer_id:customer']),
    ('email_unsubscribe_tokens', array['customer_id:customer']),
    ('followup_tasks',        array['customer_id:customer']),
    ('lead_submissions',      array['customer_id:customer']),
    ('message_drafts',        array['customer_id:customer']),
    ('meta_contacts',         array['customer_id:customer']),
    ('on_call_shifts',        array['staff_id:staff']),
    ('quotes',                array['customer_id:customer']),
    ('sms_messages',          array['customer_id:customer']),
    ('spam_incidents',        array['customer_id:customer', 'assigned_to:member']),
    ('staff_handovers',       array['to_user:member', 'from_user:member']),
    ('time_off_requests',     array['staff_id:staff']),
    ('waitlist_entries',      array['customer_id:customer', 'staff_id:staff'])
  ) as x(tbl, specs) loop
    if to_regclass('public.' || t.tbl) is null then continue; end if;
    execute format('drop trigger if exists zz_tenant_links on public.%I', t.tbl);
    execute format('create trigger zz_tenant_links before insert or update on public.%I for each row execute function public.zella_tenant_link_guard(%s)',
                   t.tbl, (select string_agg(quote_literal(s), ', ') from unnest(t.specs) s));
  end loop;
end $$;
