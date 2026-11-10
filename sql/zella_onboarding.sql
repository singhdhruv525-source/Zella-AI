-- Zella - onboarding: verification documents and real opening hours for bookings (2026-10-26).
-- Safe to re-run. Adds one table, one private storage bucket and replaces one function (built from its live body,
-- checked 2026-10-26; only the lines marked "hours" are new). Changes and deletes no existing rows.
--
-- 1. business_verification_documents: the documents an admin collects in the Create Business wizard to verify the
--    business (registration, tax, licence) and the person registering it (photo ID).
--    - Files live in the private storage bucket "business-documents" under <business id>/<kind>/<random>.<ext>.
--      The bucket has no public access and no storage policies, so no browser can list, read or write it directly.
--      The admin function hands out a one-time upload link and 60-second viewing links, to platform admins only.
--    - Rows: platform admins write them through the admin function (service role). A business's owner and admins
--      can see their own documents' status (not the files); nobody else can see anything.
--    - status: pending_review -> verified | rejected; a newer upload of the same kind marks the older one replaced.
-- 2. zella_available_slots: a business with no team members (or a team member with no hours of their own) used to
--    be offered Monday to Friday, 9 to 5, whatever its real hours. It now uses the business's opening hours
--    (business_hours, which the wizard now fills) and falls back to Mon-Fri 9-5 only when none are set.
--    Also fixed: asking for slots in whole-hour steps (60, 120 minutes) failed with "division by zero".
--
-- Rollback: drop table public.business_verification_documents; delete from storage.buckets where id = 'business-documents'
--   (only when empty); re-run the previous zella_available_slots (sql/zella_ai_booking.sql or the live copy).

create table if not exists public.business_verification_documents (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  kind text not null check (kind in ('business_registration', 'owner_identity', 'tax_registration', 'professional_license')),
  file_path text not null unique,
  file_name text not null check (length(file_name) between 1 and 200),
  mime_type text not null check (mime_type in ('application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic')),
  size_bytes integer not null check (size_bytes between 1 and 10485760),
  status text not null default 'pending_review' check (status in ('pending_review', 'verified', 'rejected', 'replaced')),
  review_note text check (review_note is null or length(review_note) <= 500),
  uploaded_by uuid,
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists business_verification_documents_business_idx on public.business_verification_documents (business_id, kind, created_at desc);

alter table public.business_verification_documents enable row level security;
revoke all on public.business_verification_documents from anon, authenticated;
grant select (id, business_id, kind, file_name, status, review_note, reviewed_at, created_at) on public.business_verification_documents to authenticated;

drop policy if exists business_verification_documents_owner_read on public.business_verification_documents;
create policy business_verification_documents_owner_read on public.business_verification_documents
  for select to authenticated using (public.zella_has_role(business_id, array['owner', 'admin']));

-- Private bucket: 10 MB, PDF and images only. No storage policies on purpose (see above).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('business-documents', 'business-documents', false, 10485760,
        array['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

create or replace function public.zella_available_slots(p_business_id uuid, p_from timestamp with time zone DEFAULT now(), p_to timestamp with time zone DEFAULT (now() + '7 days'::interval), p_duration_minutes integer DEFAULT 30, p_staff_id uuid DEFAULT NULL::uuid, p_step_minutes integer DEFAULT 30, p_limit integer DEFAULT 12, p_ignore_appointment uuid DEFAULT NULL::uuid)
 RETURNS TABLE(slot_start timestamp with time zone, slot_end timestamp with time zone, staff_id uuid, staff_name text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tz text;
  v_duration interval := make_interval(mins => greatest(5, coalesce(p_duration_minutes, 30)));
  v_step interval := make_interval(mins => greatest(5, coalesce(p_step_minutes, 30)));
  v_has_staff boolean;
  v_has_hours boolean;  -- hours: the business has opening hours of its own
begin
  if auth.uid() is not null and not exists (
    select 1 from public.business_members m
     where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active'
  ) then
    raise exception 'NOT_ALLOWED';
  end if;

  select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = p_business_id;
  if v_tz is null then
    raise exception 'BUSINESS_NOT_FOUND';
  end if;
  select exists (select 1 from public.staff_members s where s.business_id = p_business_id and s.is_active) into v_has_staff;
  select exists (select 1 from public.business_hours h where h.business_id = p_business_id) into v_has_hours;  -- hours

  return query
  with people as (
    select s.id as sid, s.name as sname, s.working_hours as hours
      from public.staff_members s
     where s.business_id = p_business_id and s.is_active and (p_staff_id is null or s.id = p_staff_id)
    union all
    select null::uuid, null::text, '{}'::jsonb
     where not v_has_staff
  ),
  candidates as (
    select p.sid, p.sname, p.hours, g.t as t
      from people p,
           generate_series(
             date_trunc('hour', greatest(p_from, now())) + (ceil(extract(minute from greatest(p_from, now())) / (extract(epoch from v_step) / 60)) * v_step),  -- hours: whole-hour steps divided by 0
             p_to, v_step) as g(t)
  ),
  checked as (
    select c.*,
           (c.t at time zone v_tz) as lstart,
           ((c.t + v_duration) at time zone v_tz) as lend,
           to_char(c.t at time zone v_tz, 'dy') as dow
      from candidates c
  ),
  resolved as (
    select k.*,
           coalesce(k.hours -> lower(k.dow), '{}'::jsonb) as d
      from checked k
  )
  select r.t, r.t + v_duration, r.sid, r.sname
    from resolved r
   where r.lstart::date = r.lend::date
     and (
       case
         when r.hours = '{}'::jsonb and v_has_hours then  -- hours: no hours of their own, so the business's
           exists (select 1 from public.business_hours h
                    where h.business_id = p_business_id and h.weekday = extract(dow from r.lstart)::smallint
                      and r.lstart::time >= h.opens and r.lend::time <= h.closes)
         when r.hours = '{}'::jsonb then
           r.dow not in ('sat', 'sun') and r.lstart::time >= time '09:00' and r.lend::time <= time '17:00'
         else
           coalesce((r.d ->> 'on')::boolean, false)
           and r.lstart::time >= coalesce(nullif(r.d ->> 'start', '')::time, time '09:00')
           and r.lend::time <= coalesce(nullif(r.d ->> 'end', '')::time, time '17:00')
           and not (
             nullif(r.d ->> 'break_start', '') is not null and nullif(r.d ->> 'break_end', '') is not null
             and r.lstart::time < (r.d ->> 'break_end')::time and r.lend::time > (r.d ->> 'break_start')::time
           )
       end
     )
     and not exists (
       select 1 from public.blocked_times bt
        where bt.business_id = p_business_id
          and (bt.staff_id is null or bt.staff_id = r.sid)
          and bt.start_time < r.t + v_duration and bt.end_time > r.t
     )
     and not exists (
       select 1 from public.appointments a
        where a.business_id = p_business_id
          and a.status not in ('cancelled', 'no_show', 'completed')
          and (p_ignore_appointment is null or a.id <> p_ignore_appointment)
          and coalesce(to_jsonb(a) ->> 'booking_state', 'confirmed') <> 'requested'
          and not (coalesce(to_jsonb(a) ->> 'booking_state', '') = 'tentative' and coalesce((to_jsonb(a) ->> 'hold_expires_at')::timestamptz, now() + interval '1 minute') < now())
          and (r.sid is null or a.staff_id = r.sid)
          and a.start_time < r.t + v_duration and a.end_time > r.t
     )
   order by r.t, r.sname nulls last
   limit greatest(1, least(coalesce(p_limit, 12), 50));
end;
$function$;

-- Check: select * from public.zella_available_slots('<business id>', now(), now() + interval '3 days', 30, null, 30, 20);
