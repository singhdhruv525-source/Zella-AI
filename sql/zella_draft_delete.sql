-- Zella Voice: a never finished draft business can be deleted, and its audit history survives the delete
-- (docs/ADMIN_AUDIT_2026-11-16.md BIZ-13a, ACC-10).
-- Before: there was no way to delete a draft, and two things made a delete unsafe or impossible:
--   * audit_logs.business_id was ON DELETE CASCADE, so deleting a business erased every audit row about it, the
--     deletion's own entry included;
--   * zella_audit_privileged (the trigger on businesses, ai_agents, automations and business_members) writes a
--     "privileged_delete" row for each deleted row with business_id set to the business being deleted, which fails
--     the audit_logs foreign key, so any delete of a business with a receptionist failed.
-- Now:
--   * audit_logs.business_id becomes ON DELETE SET NULL (ACC-10; the owner's decision, 16 Nov 2026: audit history is
--     never deleted along with a business). Deleting a business now keeps its audit rows, with business_id empty. The
--     constraint must be exactly production's CASCADE first, otherwise VERSION_MISMATCH. This changes what every
--     future delete of a business does to its audit rows;
--   * the deletion's own entry (business.draft_deleted) is written after the delete with business_id null; old_data
--     keeps the business id, name, industry, setup step, dates and the ids of its earlier audit rows (audit_logs has
--     no name column), so they can still be found together;
--   * zella_audit_privileged writes business_id null for a business being deleted in the same statement (before, any
--     delete of a business with a receptionist failed the audit foreign key) and keeps the id in new_data as
--     deleted_business_id. Nothing else in it changes;
--   * zella_delete_draft_business(p_business_id, p_actor, p_confirm_name, p_reason), server only: the actor must be an
--     active Zella Voice owner or super admin, the typed name must match, a reason is required. Under FOR UPDATE it
--     refuses a business that is live, active, in testing or ready, cancelled, has an accepted owner invitation or
--     an active member, or has calls, phone numbers, subscriptions, payments, assistant deliveries or offer history.
--     A pending owner invitation goes with the business (cascade), so its link stops working. It returns the
--     business-documents storage paths, which the server then removes.
-- zella_audit_privileged is archived first and must match production's version (the same on zprod3 and after every
-- merged migration, which don't touch it), otherwise VERSION_MISMATCH. Re-running needs this file's exact versions.
-- Rollback: sql/rollback/zella_draft_delete_rollback.sql
begin;

do $$
declare s constant text := 'public.zella_audit_privileged()'; d text; f record; v_applied boolean;
begin
  if to_regprocedure(s) is null or to_regclass('public.zella_function_archive') is null or to_regclass('public.audit_logs') is null
     or to_regprocedure('public.zella_admin_reason(text)') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  d := pg_get_functiondef(s::regprocedure);
  v_applied := md5(d) = '8f2909322446a24d4880c17a0bab98b9';
  if md5(d) = '0df0acdb83754ec20a082bdc6f48c50a' then          -- production's version: archive it for the rollback
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_draft_delete', s, d, md5(d)) on conflict (migration, signature) do nothing;
  elsif md5(d) <> '8f2909322446a24d4880c17a0bab98b9' then                         -- nor exactly this file's version (already applied)
    raise exception 'VERSION_MISMATCH: % is not a version this file was written for', s;
  end if;
  if to_regprocedure('public.zella_delete_draft_business(uuid,uuid,text,text)') is not null
     and md5(pg_get_functiondef(to_regprocedure('public.zella_delete_draft_business(uuid,uuid,text,text)'))) <> 'd6bedb36457b54e476f5a0f214f2abc3' then
    raise exception 'VERSION_MISMATCH: zella_delete_draft_business is not a version this file was written for';
  end if;
  -- the audit foreign key must be exactly production's CASCADE (or this file's SET NULL when it is already applied)
  select confdeltype into f from pg_constraint where conrelid = 'public.audit_logs'::regclass and conname = 'audit_logs_business_id_fkey'
     and pg_get_constraintdef(oid) in ('FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE',
                                       'FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE SET NULL');
  if f is null or f.confdeltype::text <> (case when v_applied then 'n' else 'c' end) then
    raise exception 'VERSION_MISMATCH: audit_logs_business_id_fkey is not a version this file was written for';
  end if;
end $$;

alter table public.audit_logs drop constraint audit_logs_business_id_fkey;
alter table public.audit_logs add constraint audit_logs_business_id_fkey
  foreign key (business_id) references public.businesses(id) on delete set null;

CREATE OR REPLACE FUNCTION public.zella_audit_privileged()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_biz uuid; v_id uuid; v_old jsonb := '{}'::jsonb; v_new jsonb := '{}'::jsonb; v_changed text[] := '{}'; k text; o jsonb; n jsonb;
begin
  o := case when TG_OP = 'INSERT' then '{}'::jsonb else to_jsonb(OLD) end;
  n := case when TG_OP = 'DELETE' then '{}'::jsonb else to_jsonb(NEW) end;
  v_biz := nullif(coalesce(n ->> 'business_id', o ->> 'business_id', case when TG_TABLE_NAME = 'businesses' then coalesce(n ->> 'id', o ->> 'id') end), '')::uuid;
  v_id := nullif(coalesce(n ->> 'id', o ->> 'id'), '')::uuid;
  if TG_TABLE_NAME in ('business_members', 'platform_admins') then
    v_old := jsonb_build_object('role', o ->> 'role', 'status', o ->> 'status', 'user_id', o ->> 'user_id');
    v_new := jsonb_build_object('role', n ->> 'role', 'status', n ->> 'status', 'user_id', n ->> 'user_id');
    if TG_OP = 'UPDATE' and v_old = v_new then return NEW; end if;
  elsif TG_TABLE_NAME = 'businesses' then
    foreach k in array array['suspended_at', 'cancelled_at', 'cancel_at', 'is_active', 'onboarding_status'] loop
      if o -> k is distinct from n -> k then v_changed := array_append(v_changed, k); v_old := v_old || jsonb_build_object(k, o -> k); v_new := v_new || jsonb_build_object(k, n -> k); end if;
    end loop;
    if cardinality(v_changed) = 0 then return NEW; end if;
  else
    select coalesce(array_agg(key order by key), '{}') into v_changed from jsonb_each(n) e(key, value)
     where key not in ('updated_at', 'last_run_at', 'last_assigned_at') and o -> key is distinct from n -> key;
    if TG_OP = 'UPDATE' and cardinality(v_changed) = 0 then return NEW; end if;
    v_new := jsonb_build_object('changed_fields', to_jsonb(v_changed), 'name', coalesce(n ->> 'name', n ->> 'key', o ->> 'name', o ->> 'key'));
  end if;
  -- zella_draft_delete: the business is being deleted in this statement, so the row can't point at it
  if TG_OP = 'DELETE' and v_biz is not null and not exists (select 1 from public.businesses where id = v_biz) then
    v_new := v_new || jsonb_build_object('deleted_business_id', v_biz);
    v_biz := null;
  end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (v_biz, auth.uid(), 'privileged_' || lower(TG_OP), TG_TABLE_NAME, v_id, nullif(v_old, '{}'::jsonb), v_new);
  return coalesce(NEW, OLD);
end $function$;

CREATE OR REPLACE FUNCTION public.zella_delete_draft_business(p_business_id uuid, p_actor uuid, p_confirm_name text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  b public.businesses;
  v_reason text := public.zella_admin_reason(p_reason);
  v_blockers text[] := '{}';
  v_paths text[];
  v_earlier jsonb;
  v_industry text;
begin
  if not exists (select 1 from platform_admins where user_id = p_actor and is_active and role in ('zella_owner', 'super_admin')) then
    raise exception 'NOT_ALLOWED';
  end if;
  select * into b from businesses where id = p_business_id for update;
  if b.id is null then raise exception 'NOT_FOUND'; end if;
  if lower(trim(coalesce(p_confirm_name, ''))) <> lower(trim(b.name)) then raise exception 'NAME_MISMATCH'; end if;

  if b.onboarding_status in ('testing', 'ready', 'active') then v_blockers := array_append(v_blockers, 'setup_finished'); end if;
  if b.is_active then v_blockers := array_append(v_blockers, 'active'); end if;
  if b.cancelled_at is not null or b.cancel_at is not null then v_blockers := array_append(v_blockers, 'cancelled'); end if;
  if exists (select 1 from business_invitations where business_id = b.id and status = 'accepted') then v_blockers := array_append(v_blockers, 'owner_accepted'); end if;
  if exists (select 1 from business_members where business_id = b.id and status = 'active') then v_blockers := array_append(v_blockers, 'members'); end if;
  if exists (select 1 from calls where business_id = b.id) then v_blockers := array_append(v_blockers, 'calls'); end if;
  if exists (select 1 from business_phone_numbers where business_id = b.id) then v_blockers := array_append(v_blockers, 'phone_numbers'); end if;
  if exists (select 1 from subscriptions where business_id = b.id) then v_blockers := array_append(v_blockers, 'subscriptions'); end if;
  if exists (select 1 from payments where business_id = b.id) then v_blockers := array_append(v_blockers, 'payments'); end if;
  if exists (select 1 from assistant_deliveries where business_id = b.id) then v_blockers := array_append(v_blockers, 'assistant_deliveries'); end if;
  if exists (select 1 from offer_redemptions where business_id = b.id) or exists (select 1 from offer_events where business_id = b.id) then
    v_blockers := array_append(v_blockers, 'offers');
  end if;
  if cardinality(v_blockers) > 0 then
    raise exception 'NOT_A_DRAFT: %', array_to_string(v_blockers, ',');
  end if;

  select coalesce(array_agg(distinct p), '{}') into v_paths from (
    select file_path as p from business_verification_documents where business_id = b.id and file_path is not null
    union select name from storage.objects where bucket_id = 'business-documents' and name like b.id::text || '/%') x;
  -- the business's audit rows stay (business_id becomes empty): their ids go in the deletion entry
  select coalesce(jsonb_agg(id order by created_at), '[]'::jsonb) into v_earlier from (
    select id, created_at from audit_logs where business_id = b.id order by created_at limit 1000) a;
  select name into v_industry from industries where id = b.industry_id;

  delete from businesses where id = b.id;

  -- after the delete, with business_id null; it keeps what audit_logs can't (no name column)
  insert into audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (null, p_actor, 'business.draft_deleted', 'business', b.id,
    jsonb_build_object('business_id', b.id, 'name', b.name, 'industry', v_industry, 'onboarding_status', b.onboarding_status,
                       'created_at', b.created_at, 'updated_at', b.updated_at, 'earlier_audit_ids', v_earlier),
    jsonb_build_object('reason', v_reason, 'files_to_remove', cardinality(v_paths)));

  return jsonb_build_object('business_id', b.id, 'name', b.name, 'paths', to_jsonb(v_paths));
end
$function$;

revoke all on function public.zella_delete_draft_business(uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function public.zella_delete_draft_business(uuid, uuid, text, text) to service_role;

commit;
