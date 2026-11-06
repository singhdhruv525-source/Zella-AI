-- Release 1: authorized relationships, verification and consent (6 Nov 2026).
--
-- Who may act for whom. Until now nothing linked a parent to a child, a proxy to a patient, a tenant or vendor to a
-- unit, or an authorized contact to a policy or matter, so "only a verified guardian" (the childcare preset's own rule)
-- could not be checked by anything.
--
--   * customer_relationships: a related person (a customer of the same business) for a subject, which is either a
--     person (customers) or a record (crm_records: a child, pet, unit, policy, matter ...). Each link has a kind, what
--     that person may do (permissions), verification, an optional end date, and revocation. Nothing is deleted: a
--     revoked link stays for the history.
--   * A link grants nothing until it is verified, and nothing once it has expired or been revoked. Staff verify;
--     in sensitive industries (zella_sensitive_industry) only owners, admins and managers do. Changing who the person
--     is, the kind or the permissions clears the verification.
--   * customer_consents: consent given or refused for a subject (treatment, medication, photos, recording ...), with
--     an optional expiry. Only the person themselves, a record's primary contact (crm_records.customer_id), or a
--     verified related person allowed to "approve" can give it.
--   * zella_is_authorized(...) answers "may this person do X for that subject?" for the app and, once approved, the
--     AI receptionist (server key).
--   * Writes only through these functions (staff and above, business not paused); members read. Every change is in
--     the audit log (ids, kinds and permissions; never the note text).
-- Safe to run twice. Undo: sql/rollback/zella_relationships_rollback.sql. Needs the owner's approval to apply.

create table if not exists public.customer_relationships (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete cascade,
  record_id uuid references public.crm_records(id) on delete cascade,
  related_customer_id uuid not null references public.customers(id) on delete cascade,
  kind text not null,
  permissions text[] not null default '{}',
  valid_until date,
  note text,
  verified_at timestamptz,
  verified_by uuid,
  verification_method text,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoked_by uuid,
  revoke_reason text,
  constraint customer_relationships_one_subject check ((customer_id is null) <> (record_id is null)),
  constraint customer_relationships_not_self check (customer_id is distinct from related_customer_id),
  constraint customer_relationships_kind check (kind in ('parent', 'guardian', 'proxy', 'representative', 'household',
    'emergency_contact', 'authorized_contact', 'tenant', 'owner', 'vendor', 'other')),
  constraint customer_relationships_permissions check (permissions <@ array['discuss', 'book', 'pickup', 'approve', 'receive_updates', 'documents']),
  constraint customer_relationships_method check (verification_method is null or verification_method in
    ('id_checked', 'document_on_file', 'known_to_team', 'callback_verified', 'other')),
  constraint customer_relationships_note_len check (length(coalesce(note, '')) <= 500 and length(coalesce(revoke_reason, '')) <= 300)
);
create index if not exists customer_relationships_customer on public.customer_relationships (customer_id) where customer_id is not null;
create index if not exists customer_relationships_record on public.customer_relationships (record_id) where record_id is not null;
create index if not exists customer_relationships_related on public.customer_relationships (related_customer_id);
create unique index if not exists customer_relationships_one_active_person on public.customer_relationships (customer_id, related_customer_id, kind)
  where revoked_at is null and customer_id is not null;
create unique index if not exists customer_relationships_one_active_record on public.customer_relationships (record_id, related_customer_id, kind)
  where revoked_at is null and record_id is not null;

create table if not exists public.customer_consents (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete cascade,
  record_id uuid references public.crm_records(id) on delete cascade,
  kind text not null,
  scope text,
  status text not null,
  given_by_customer_id uuid not null references public.customers(id) on delete cascade,
  given_at timestamptz not null default now(),
  expires_at date,
  evidence text,
  recorded_by uuid,
  revoked_at timestamptz,
  revoked_by uuid,
  revoke_reason text,
  constraint customer_consents_one_subject check ((customer_id is null) <> (record_id is null)),
  constraint customer_consents_kind check (kind in ('treatment', 'medication', 'photo_media', 'data_sharing', 'recording',
    'emergency_care', 'pickup_change', 'terms', 'other')),
  constraint customer_consents_status check (status in ('granted', 'refused')),
  constraint customer_consents_text_len check (length(coalesce(scope, '')) <= 300 and length(coalesce(evidence, '')) <= 500
    and length(coalesce(revoke_reason, '')) <= 300)
);
create index if not exists customer_consents_customer on public.customer_consents (customer_id) where customer_id is not null;
create index if not exists customer_consents_record on public.customer_consents (record_id) where record_id is not null;

alter table public.customer_relationships enable row level security;
alter table public.customer_consents enable row level security;
revoke all on public.customer_relationships, public.customer_consents from public, anon, authenticated;
grant select on public.customer_relationships, public.customer_consents to authenticated;
grant all on public.customer_relationships, public.customer_consents to service_role;
drop policy if exists customer_relationships_read on public.customer_relationships;
create policy customer_relationships_read on public.customer_relationships for select to authenticated using (public.is_business_member(business_id));
drop policy if exists customer_consents_read on public.customer_consents;
create policy customer_consents_read on public.customer_consents for select to authenticated using (public.is_business_member(business_id));
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'customer_relationships' and policyname = 'zella_mfa_required') then
    execute 'create policy zella_mfa_required on public.customer_relationships as restrictive for all to authenticated using (public.zella_mfa_satisfied()) with check (public.zella_mfa_satisfied())';
  end if;
  if not exists (select 1 from pg_policies where tablename = 'customer_consents' and policyname = 'zella_mfa_required') then
    execute 'create policy zella_mfa_required on public.customer_consents as restrictive for all to authenticated using (public.zella_mfa_satisfied()) with check (public.zella_mfa_satisfied())';
  end if;
end $$;

-- may this signed-in person change relationships and consents here? (staff and above, business not paused)
create or replace function public.zella_people_can_edit(p_business_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.zella_can_edit(p_business_id)
     and exists (select 1 from public.businesses b where b.id = p_business_id and b.suspended_at is null and b.cancelled_at is null) $$;

-- may they verify a relationship? staff, except in sensitive industries: owners, admins and managers only
create or replace function public.zella_people_can_verify(p_business_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.zella_people_can_edit(p_business_id)
     and (not public.zella_sensitive_industry(p_business_id) or public.zella_has_role(p_business_id, array['owner', 'admin', 'manager'])) $$;

-- the subject (a person or a record) belongs to the business; a record must not be archived
create or replace function public.zella_people_subject_ok(p_business_id uuid, p_customer_id uuid, p_record_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when (p_customer_id is null) = (p_record_id is null) then false
    when p_customer_id is not null then exists (select 1 from public.customers c where c.id = p_customer_id and c.business_id = p_business_id)
    else exists (select 1 from public.crm_records r where r.id = p_record_id and r.business_id = p_business_id and r.archived_at is null)
  end $$;

-- is a relationship row in force right now? (verified, not revoked, not past its end date)
create or replace function public.zella_relationship_in_force(r public.customer_relationships) returns boolean
language sql stable set search_path = public as $$
  select r.revoked_at is null and r.verified_at is not null and (r.valid_until is null or r.valid_until >= current_date) $$;

-- may p_actor do p_permission for the subject? The person themselves, and a record's primary contact, may; anyone
-- else needs a link in force with that permission. Members of the business and the server only.
create or replace function public.zella_is_authorized(p_business_id uuid, p_customer_id uuid, p_record_id uuid, p_actor_customer_id uuid, p_permission text)
returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_business_member(p_business_id) then return false; end if;
  if p_actor_customer_id is null or not public.zella_people_subject_ok(p_business_id, p_customer_id, p_record_id) then return false; end if;
  if p_permission is null or p_permission not in ('discuss', 'book', 'pickup', 'approve', 'receive_updates', 'documents') then return false; end if;
  if not exists (select 1 from public.customers c where c.id = p_actor_customer_id and c.business_id = p_business_id) then return false; end if;
  if p_customer_id is not null and p_actor_customer_id = p_customer_id then return true; end if;
  if p_record_id is not null and exists (select 1 from public.crm_records r where r.id = p_record_id and r.customer_id = p_actor_customer_id) then return true; end if;
  return exists (select 1 from public.customer_relationships r
                  where r.business_id = p_business_id and r.related_customer_id = p_actor_customer_id
                    and (r.customer_id = p_customer_id or r.record_id = p_record_id)
                    and p_permission = any (r.permissions) and public.zella_relationship_in_force(r));
end $$;

create or replace function public.zella_people_audit(p_business_id uuid, p_action text, p_entity text, p_id uuid, p_old jsonb, p_new jsonb) returns void
language sql security definer set search_path = public as $$
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (p_business_id, auth.uid(), p_action, p_entity, p_id, p_old, p_new) $$;

-- add or change a relationship; returns its id
create or replace function public.zella_relationship_save(p_business_id uuid, p_id uuid, p_customer_id uuid, p_record_id uuid,
  p_related_customer_id uuid, p_kind text, p_permissions text[], p_valid_until date default null, p_note text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare cur public.customer_relationships; v_id uuid; v_perms text[] := coalesce((select array_agg(distinct p order by p) from unnest(p_permissions) p), '{}');
begin
  if not public.zella_people_can_edit(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if not public.zella_people_subject_ok(p_business_id, p_customer_id, p_record_id) then raise exception 'NOT_VALID'; end if;
  if p_related_customer_id is null or not exists (select 1 from public.customers c where c.id = p_related_customer_id and c.business_id = p_business_id) then
    raise exception 'NOT_VALID';
  end if;
  if p_related_customer_id = p_customer_id then raise exception 'SAME_PERSON'; end if;
  if length(coalesce(p_note, '')) > 500 then raise exception 'NOTE_TOO_LONG'; end if;
  if p_valid_until is not null and p_valid_until < current_date then raise exception 'BAD_DATE'; end if;
  if p_id is null then
    insert into public.customer_relationships (business_id, customer_id, record_id, related_customer_id, kind, permissions, valid_until, note, created_by)
    values (p_business_id, p_customer_id, p_record_id, p_related_customer_id, p_kind, v_perms, p_valid_until, nullif(trim(coalesce(p_note, '')), ''), auth.uid())
    returning id into v_id;
    perform public.zella_people_audit(p_business_id, 'relationship_added', 'customer_relationship', v_id, null,
      jsonb_build_object('kind', p_kind, 'permissions', v_perms, 'customer_id', p_customer_id, 'record_id', p_record_id, 'related_customer_id', p_related_customer_id));
    return v_id;
  end if;
  select * into cur from public.customer_relationships where id = p_id and business_id = p_business_id for update;
  if not found or cur.revoked_at is not null then raise exception 'NOT_FOUND'; end if;
  if cur.customer_id is distinct from p_customer_id or cur.record_id is distinct from p_record_id then raise exception 'NOT_VALID'; end if;
  update public.customer_relationships set related_customer_id = p_related_customer_id, kind = p_kind, permissions = v_perms,
         valid_until = p_valid_until, note = nullif(trim(coalesce(p_note, '')), ''), updated_at = now(),
         -- a different person, kind or wider set of permissions has to be verified again
         verified_at = case when cur.related_customer_id = p_related_customer_id and cur.kind = p_kind and v_perms <@ cur.permissions then cur.verified_at end,
         verified_by = case when cur.related_customer_id = p_related_customer_id and cur.kind = p_kind and v_perms <@ cur.permissions then cur.verified_by end,
         verification_method = case when cur.related_customer_id = p_related_customer_id and cur.kind = p_kind and v_perms <@ cur.permissions then cur.verification_method end
   where id = p_id;
  perform public.zella_people_audit(p_business_id, 'relationship_updated', 'customer_relationship', p_id,
    jsonb_build_object('kind', cur.kind, 'permissions', cur.permissions, 'related_customer_id', cur.related_customer_id, 'valid_until', cur.valid_until),
    jsonb_build_object('kind', p_kind, 'permissions', v_perms, 'related_customer_id', p_related_customer_id, 'valid_until', p_valid_until));
  return p_id;
end $$;

-- Verify exactly what the verifier was shown: the person, the kind and the permissions on their screen. If the link
-- changed after they opened it (someone widened the permissions, or changed the person), nothing is verified
-- (CHANGED) and they look again. A row lock alone wouldn't catch a form opened before the change.
drop function if exists public.zella_relationship_verify(uuid, text);
create or replace function public.zella_relationship_verify(p_id uuid, p_method text, p_related_customer_id uuid, p_kind text, p_permissions text[])
returns void language plpgsql security definer set search_path = public as $$
declare cur public.customer_relationships; v_shown text[] := coalesce((select array_agg(distinct p order by p) from unnest(p_permissions) p), '{}');
begin
  select * into cur from public.customer_relationships where id = p_id for update;
  if not found or not public.zella_people_can_verify(cur.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if cur.revoked_at is not null then raise exception 'NOT_FOUND'; end if;
  if p_method is null or p_method not in ('id_checked', 'document_on_file', 'known_to_team', 'callback_verified', 'other') then raise exception 'BAD_METHOD'; end if;
  if cur.related_customer_id is distinct from p_related_customer_id or cur.kind is distinct from p_kind or cur.permissions is distinct from v_shown then
    raise exception 'CHANGED';
  end if;
  update public.customer_relationships set verified_at = now(), verified_by = auth.uid(), verification_method = p_method, updated_at = now() where id = p_id;
  perform public.zella_people_audit(cur.business_id, 'relationship_verified', 'customer_relationship', p_id, null,
    jsonb_build_object('method', p_method, 'kind', cur.kind, 'permissions', cur.permissions));
end $$;

create or replace function public.zella_relationship_revoke(p_id uuid, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
declare cur public.customer_relationships;
begin
  select * into cur from public.customer_relationships where id = p_id for update;
  if not found or not public.zella_people_can_edit(cur.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if cur.revoked_at is not null then return; end if;
  update public.customer_relationships set revoked_at = now(), revoked_by = auth.uid(), revoke_reason = left(nullif(trim(coalesce(p_reason, '')), ''), 300), updated_at = now()
   where id = p_id;
  perform public.zella_people_audit(cur.business_id, 'relationship_revoked', 'customer_relationship', p_id,
    jsonb_build_object('kind', cur.kind, 'permissions', cur.permissions), null);
end $$;

-- record consent given or refused; returns its id
create or replace function public.zella_consent_record(p_business_id uuid, p_customer_id uuid, p_record_id uuid, p_kind text, p_status text,
  p_given_by_customer_id uuid, p_scope text default null, p_expires_at date default null, p_evidence text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not public.zella_people_can_edit(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if not public.zella_people_subject_ok(p_business_id, p_customer_id, p_record_id) then raise exception 'NOT_VALID'; end if;
  if p_expires_at is not null and p_expires_at < current_date then raise exception 'BAD_DATE'; end if;
  -- only someone who may approve for this subject can give or refuse consent
  if not public.zella_is_authorized(p_business_id, p_customer_id, p_record_id, p_given_by_customer_id, 'approve') then raise exception 'NOT_AUTHORIZED_GIVER'; end if;
  insert into public.customer_consents (business_id, customer_id, record_id, kind, scope, status, given_by_customer_id, expires_at, evidence, recorded_by)
  values (p_business_id, p_customer_id, p_record_id, p_kind, nullif(trim(coalesce(p_scope, '')), ''), p_status, p_given_by_customer_id, p_expires_at,
          nullif(trim(coalesce(p_evidence, '')), ''), auth.uid())
  returning id into v_id;
  perform public.zella_people_audit(p_business_id, 'consent_recorded', 'customer_consent', v_id, null,
    jsonb_build_object('kind', p_kind, 'status', p_status, 'given_by_customer_id', p_given_by_customer_id, 'customer_id', p_customer_id, 'record_id', p_record_id, 'expires_at', p_expires_at));
  return v_id;
end $$;

create or replace function public.zella_consent_revoke(p_id uuid, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
declare cur public.customer_consents;
begin
  select * into cur from public.customer_consents where id = p_id for update;
  if not found or not public.zella_people_can_edit(cur.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if cur.revoked_at is not null then return; end if;
  update public.customer_consents set revoked_at = now(), revoked_by = auth.uid(), revoke_reason = left(nullif(trim(coalesce(p_reason, '')), ''), 300) where id = p_id;
  perform public.zella_people_audit(cur.business_id, 'consent_revoked', 'customer_consent', p_id, jsonb_build_object('kind', cur.kind, 'status', cur.status), null);
end $$;

-- everything the people panel shows for one subject (and, for a person, what they are authorized for elsewhere)
create or replace function public.zella_people_panel(p_business_id uuid, p_customer_id uuid, p_record_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_rel jsonb; v_for jsonb; v_cons jsonb; v_primary jsonb;
begin
  if not public.is_business_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if not public.zella_people_subject_ok(p_business_id, p_customer_id, p_record_id) then raise exception 'NOT_VALID'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'kind', r.kind, 'permissions', to_jsonb(r.permissions), 'valid_until', r.valid_until, 'note', r.note,
           'verified_at', r.verified_at, 'verification_method', r.verification_method, 'revoked_at', r.revoked_at, 'created_at', r.created_at,
           'state', case when r.revoked_at is not null then 'revoked' when r.valid_until is not null and r.valid_until < current_date then 'expired'
                         when r.verified_at is null then 'unverified' else 'active' end,
           'person', jsonb_build_object('id', c.id, 'first_name', c.first_name, 'last_name', c.last_name, 'phone', c.phone, 'email', c.email))
           order by (r.revoked_at is not null), r.created_at), '[]'::jsonb) into v_rel
    from public.customer_relationships r join public.customers c on c.id = r.related_customer_id
   where r.business_id = p_business_id and (r.customer_id = p_customer_id or r.record_id = p_record_id);
  select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'kind', k.kind, 'scope', k.scope, 'status', k.status, 'given_at', k.given_at, 'expires_at', k.expires_at,
           'evidence', k.evidence, 'revoked_at', k.revoked_at,
           'state', case when k.revoked_at is not null then 'revoked' when k.status = 'refused' then 'refused'
                         when k.expires_at is not null and k.expires_at < current_date then 'expired' else 'active' end,
           'given_by', jsonb_build_object('id', g.id, 'first_name', g.first_name, 'last_name', g.last_name))
           order by (k.revoked_at is not null), k.given_at desc), '[]'::jsonb) into v_cons
    from public.customer_consents k join public.customers g on g.id = k.given_by_customer_id
   where k.business_id = p_business_id and (k.customer_id = p_customer_id or k.record_id = p_record_id);
  if p_customer_id is not null then
    select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'kind', r.kind, 'permissions', to_jsonb(r.permissions), 'state',
             case when r.revoked_at is not null then 'revoked' when r.valid_until is not null and r.valid_until < current_date then 'expired'
                  when r.verified_at is null then 'unverified' else 'active' end,
             'subject', case when r.customer_id is not null then jsonb_build_object('type', 'person', 'id', s.id, 'name', trim(coalesce(s.first_name, '') || ' ' || coalesce(s.last_name, '')))
                             else jsonb_build_object('type', 'record', 'id', x.id, 'name', x.title, 'type_key', x.type_key) end)
             order by r.created_at), '[]'::jsonb) into v_for
      from public.customer_relationships r left join public.customers s on s.id = r.customer_id left join public.crm_records x on x.id = r.record_id
     where r.business_id = p_business_id and r.related_customer_id = p_customer_id and r.revoked_at is null;
  else
    select jsonb_build_object('id', c.id, 'first_name', c.first_name, 'last_name', c.last_name) into v_primary
      from public.crm_records x join public.customers c on c.id = x.customer_id where x.id = p_record_id;
  end if;
  return jsonb_build_object('relationships', v_rel, 'consents', v_cons, 'authorized_for', coalesce(v_for, '[]'::jsonb), 'primary_contact', v_primary,
    'can_edit', public.zella_people_can_edit(p_business_id), 'can_verify', public.zella_people_can_verify(p_business_id),
    'sensitive', public.zella_sensitive_industry(p_business_id));
end $$;

-- Customer merge (zella_merge_customers, zella_customer_records.sql) moves every customer_id column generically. For
-- relationships that would fail (one link per person, subject and kind; nobody linked to themselves), skip the whole
-- table, and leave authority on the archived duplicate. So merges handle relationships here instead:
--   * links about the dropped person move to the kept person (verification kept: the same authority over them);
--   * links where the dropped person had authority move to the kept person but must be verified again (a merge is
--     a decision about identity, not a verification of authority);
--   * a link that would make someone their own contact, or duplicate an active link, is revoked ("merged").
-- Consents move with the generic step (their subject); who gave them stays as history.
create or replace function public.zella_people_merge(p_business_id uuid, p_keep uuid, p_drop uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare r public.customer_relationships; v_subject uuid; v_related uuid; n integer := 0;
begin
  for r in select * from public.customer_relationships
            where business_id = p_business_id and revoked_at is null and (customer_id = p_drop or related_customer_id = p_drop)
            order by created_at for update loop
    v_subject := case when r.customer_id = p_drop then p_keep else r.customer_id end;
    v_related := case when r.related_customer_id = p_drop then p_keep else r.related_customer_id end;
    if v_subject is not null and v_subject = v_related then
      update public.customer_relationships set revoked_at = now(), revoked_by = auth.uid(), revoke_reason = 'merged: would link a person to themselves', updated_at = now() where id = r.id;
    elsif exists (select 1 from public.customer_relationships x where x.id <> r.id and x.revoked_at is null and x.kind = r.kind
                    and x.related_customer_id = v_related and x.customer_id is not distinct from v_subject and x.record_id is not distinct from r.record_id) then
      update public.customer_relationships set revoked_at = now(), revoked_by = auth.uid(), revoke_reason = 'merged: duplicate of an existing link', updated_at = now() where id = r.id;
    else
      update public.customer_relationships set customer_id = v_subject, related_customer_id = v_related, updated_at = now(),
             verified_at = case when r.related_customer_id = p_drop then null else verified_at end,
             verified_by = case when r.related_customer_id = p_drop then null else verified_by end,
             verification_method = case when r.related_customer_id = p_drop then null else verification_method end
       where id = r.id;
    end if;
    perform public.zella_people_audit(p_business_id, 'relationship_merged', 'customer_relationship', r.id,
      jsonb_build_object('customer_id', r.customer_id, 'related_customer_id', r.related_customer_id),
      jsonb_build_object('customer_id', v_subject, 'related_customer_id', v_related, 'kept', p_keep, 'merged_from', p_drop));
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.zella_people_merge(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.zella_people_merge(uuid, uuid, uuid) to service_role;

-- hook it into the merge (patched in place, like other migrations; the rollback takes it out again)
do $$
declare def text;
begin
  if to_regprocedure('public.zella_merge_customers(uuid, uuid, uuid)') is null then return; end if;
  def := pg_get_functiondef('public.zella_merge_customers(uuid, uuid, uuid)'::regprocedure);
  if position('zella_relationships_merge' in def) = 0 then
    def := replace(def, $a$  if k.id is null or d.id is null then raise exception 'NOT_FOUND'; end if;$a$,
      $a$  if k.id is null or d.id is null then raise exception 'NOT_FOUND'; end if;
  perform public.zella_people_merge(p_business_id, p_keep, p_drop); /* zella_relationships_merge */$a$);
    def := replace(def, $a$'contact_consents', 'data_rights_requests')$a$, $a$'contact_consents', 'data_rights_requests', 'customer_relationships')$a$);
    if position('zella_relationships_merge' in def) = 0 or position($a$'data_rights_requests', 'customer_relationships')$a$ in def) = 0 then
      raise exception 'zella_merge_customers has changed; review this patch';
    end if;
    execute def;
  end if;
end $$;

revoke execute on function public.zella_people_can_edit(uuid), public.zella_people_can_verify(uuid), public.zella_people_subject_ok(uuid, uuid, uuid),
  public.zella_relationship_in_force(public.customer_relationships), public.zella_is_authorized(uuid, uuid, uuid, uuid, text),
  public.zella_people_audit(uuid, text, text, uuid, jsonb, jsonb),
  public.zella_relationship_save(uuid, uuid, uuid, uuid, uuid, text, text[], date, text), public.zella_relationship_verify(uuid, text, uuid, text, text[]),
  public.zella_relationship_revoke(uuid, text), public.zella_consent_record(uuid, uuid, uuid, text, text, uuid, text, date, text),
  public.zella_consent_revoke(uuid, text), public.zella_people_panel(uuid, uuid, uuid) from public, anon;
revoke execute on function public.zella_people_audit(uuid, text, text, uuid, jsonb, jsonb), public.zella_people_subject_ok(uuid, uuid, uuid),
  public.zella_relationship_in_force(public.customer_relationships) from authenticated;
grant execute on function public.zella_people_can_edit(uuid), public.zella_people_can_verify(uuid), public.zella_is_authorized(uuid, uuid, uuid, uuid, text),
  public.zella_relationship_save(uuid, uuid, uuid, uuid, uuid, text, text[], date, text), public.zella_relationship_verify(uuid, text, uuid, text, text[]),
  public.zella_relationship_revoke(uuid, text), public.zella_consent_record(uuid, uuid, uuid, text, text, uuid, text, date, text),
  public.zella_consent_revoke(uuid, text), public.zella_people_panel(uuid, uuid, uuid) to authenticated, service_role;
grant execute on function public.zella_people_audit(uuid, text, text, uuid, jsonb, jsonb), public.zella_people_subject_ok(uuid, uuid, uuid),
  public.zella_relationship_in_force(public.customer_relationships) to service_role;
