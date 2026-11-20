-- Zella Voice: a retry of "Create business" never makes a second business (docs/ADMIN_AUDIT_2026-11-16.md BIZ-14,
-- REQ-LC-03, REQ-LC-05).
-- The wizard learnt the new business's id only from the reply, so a retry after a timeout called
-- zella_create_business_draft again and made a second draft. Now:
--   * businesses.creation_key (uuid, unique when set): the wizard makes one key per session and sends it with the
--     first save;
--   * zella_create_business_draft(p_fields, p_creation_key) returns the business already made with that key
--     ("existing": true) and otherwise makes it through the one argument function, which is unchanged and keeps
--     working for the web app and server already deployed;
--   * zella_business_duplicates(p_name, p_phone, p_website, p_exclude, p_creation_key) lists businesses that are not
--     cancelled and share the normalised name, phone number (last 10 digits) or web domain, so the wizard can warn
--     before creating. The business itself and the one already made with this session's key are left out.
-- Both new functions are server only (service_role). Nothing existing is replaced, so no function is archived. Each
-- new function must be absent or exactly this file's version, otherwise VERSION_MISMATCH.
-- Rollback: sql/rollback/zella_business_creation_key_rollback.sql
begin;

do $$
declare
  f record;
begin
  if to_regprocedure('public.zella_create_business_draft(jsonb)') is null or to_regclass('public.businesses') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  for f in select * from (values
      ('public.zella_create_business_draft(jsonb,uuid)', '9a8eecb43decf5cf400010631027c208'),
      ('public.zella_business_duplicates(text,text,text,uuid,uuid)', '59e78ac5dcdb883c0b7bf59256f0de5c')) as t(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'VERSION_MISMATCH: % is not a version this file was written for', f.sig;
    end if;
  end loop;
end $$;

alter table public.businesses add column if not exists creation_key uuid;
comment on column public.businesses.creation_key is
  'One key per Create business session: a retry with the same key returns this business instead of making another (BIZ-14).';
create unique index if not exists businesses_creation_key_key on public.businesses (creation_key) where creation_key is not null;

CREATE OR REPLACE FUNCTION public.zella_create_business_draft(p_fields jsonb, p_creation_key uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_existing uuid;
  v_result jsonb;
begin
  if p_creation_key is null then
    raise exception 'CREATION_KEY_REQUIRED';
  end if;
  -- two saves with the same key at once: the second waits here, then finds the first one's business
  perform pg_advisory_xact_lock(hashtextextended('zella_create_business_draft:' || p_creation_key::text, 0));
  select id into v_existing from businesses where creation_key = p_creation_key;
  if v_existing is not null then
    return jsonb_build_object('business_id', v_existing, 'existing', true);
  end if;
  v_result := zella_create_business_draft(p_fields);
  update businesses set creation_key = p_creation_key where id = (v_result ->> 'business_id')::uuid;
  return v_result || jsonb_build_object('existing', false);
end;
$function$;

CREATE OR REPLACE FUNCTION public.zella_business_duplicates(p_name text, p_phone text, p_website text, p_exclude uuid, p_creation_key uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- name: letters and digits only, lower case; phone: the last 10 digits (at least 7 given);
  -- web domain: no scheme, no www., no path or port
  with wanted as (
    select nullif(regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9]', '', 'g'), '') as name,
           nullif(right(regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g'), 10), '') as phone,
           nullif(regexp_replace(regexp_replace(lower(trim(coalesce(p_website, ''))), '^[a-z]+://', ''), '^www\.|[/:?#].*$', '', 'g'), '') as domain
  ), found as (
    select b.id, b.name, b.onboarding_status, b.is_active, b.created_at,
           array_remove(array[
             case when w.name is not null and regexp_replace(lower(b.name), '[^a-z0-9]', '', 'g') = w.name then 'name' end,
             case when w.phone is not null and length(w.phone) >= 7
                       and right(regexp_replace(coalesce(b.phone, ''), '[^0-9]', '', 'g'), 10) = w.phone then 'phone' end,
             case when w.domain is not null and position('.' in w.domain) > 0
                       and regexp_replace(regexp_replace(lower(trim(coalesce(b.website, ''))), '^[a-z]+://', ''), '^www\.|[/:?#].*$', '', 'g') = w.domain then 'website' end
           ], null) as matched
    from businesses b cross join wanted w
    where b.cancelled_at is null and (p_exclude is null or b.id <> p_exclude)
      and (p_creation_key is null or b.creation_key is distinct from p_creation_key)   -- a retry's own first try
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'onboarding_status', onboarding_status,
                                               'is_active', is_active, 'created_at', created_at, 'matched', to_jsonb(matched))
                            order by created_at desc), '[]'::jsonb)
  from (select * from found where cardinality(matched) > 0 order by created_at desc limit 10) m
$function$;

revoke all on function public.zella_create_business_draft(jsonb, uuid) from public, anon, authenticated;
revoke all on function public.zella_business_duplicates(text, text, text, uuid, uuid) from public, anon, authenticated;
grant execute on function public.zella_create_business_draft(jsonb, uuid) to service_role;
grant execute on function public.zella_business_duplicates(text, text, text, uuid, uuid) to service_role;

commit;
