-- Zella Voice: support replies the business can read and answer, alerts for urgent, cancellation and plan change
-- requests, and the time of the first reply (docs/ADMIN_AUDIT_2026-11-16.md OPS-25; REQ-CRM-26 open and reply,
-- REQ-BIL-47 first response within 4 business hours).
--   1. support_ticket_messages: the conversation the business sees. Kept apart from support_ticket_notes (internal,
--      server only, sql/zella_support_notes.sql): a note is never shown to the business. Members of the business read
--      their tickets' messages (row security); nobody writes the table directly, only the two functions below.
--   2. support_tickets.first_response_at: when Zella Voice first replied. Set once.
--   3. zella_admin_ticket_reply(ticket, author, body): server only (owner-provision-business ticket_update, which
--      checks support.manage and audits). Adds the reply, sets first_response_at once, and tells the person who opened
--      the ticket in the app (staff_notifications, marked skipped for email and text: in app only).
--   4. zella_business_ticket_reply(ticket, body): the business's owner, admins and managers (the same people who may
--      update tickets); reopens a resolved ticket.
--   5. A trigger raises a platform alert when a business asks to cancel, asks for a plan change, or reports an urgent
--      issue from Settings (zella_business_request creates those tickets; it is not replaced here).
--   6. platform_settings.support_business_hours: Monday to Friday 9:00 to 17:00 America/New_York unless already set
--      (the owner can change it); owner-provision-business reads it for the ticket age and the overdue filter.
-- Every function is new; each must be absent or exactly this file's version, otherwise the file stops with
-- VERSION_MISMATCH. Running it twice changes nothing.
-- Rollback: sql/rollback/zella_support_replies_rollback.sql (refuses on drift; keeps the messages only if asked).
begin;

do $$
declare f record;
begin
  if to_regclass('public.support_tickets') is null or to_regclass('public.staff_notifications') is null
     or to_regclass('public.platform_settings') is null or to_regprocedure('public.is_business_member(uuid)') is null
     or to_regprocedure('public.zella_platform_alert(text,text,text,text,uuid,text,jsonb)') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  -- a table already there must be exactly this file's (same columns and types), or nothing is installed against it
  if to_regclass('public.support_ticket_messages') is not null and (
       select string_agg(column_name || ' ' || data_type, ', ' order by column_name) from information_schema.columns
        where table_schema = 'public' and table_name = 'support_ticket_messages')
     is distinct from 'author_id uuid, author_side text, body text, business_id uuid, created_at timestamp with time zone, id uuid, ticket_id uuid' then
    raise exception 'VERSION_MISMATCH: a different support_ticket_messages table already exists';
  end if;
  for f in select * from (values
      ('public.zella_admin_ticket_reply(uuid,uuid,text)', '4cfcb7b1370b215f3c58ba007890aba8'),
      ('public.zella_business_ticket_reply(uuid,text)', '74292f8c7c40bb7035c6606a86fc6d89'),
      ('public.zella_support_ticket_alert_trg()', '7c1e68b078a07f8f175eaf593ec52eb2')) v(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'VERSION_MISMATCH: % already exists in a version this file was not written for', f.sig;
    end if;
  end loop;
end $$;

create table if not exists public.support_ticket_messages (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.support_tickets(id) on delete cascade,
  business_id uuid not null,
  author_id uuid,
  author_side text not null check (author_side in ('zella', 'business')),
  body text not null check (length(btrim(body)) between 1 and 4000),
  created_at timestamptz not null default now()
);
create index if not exists support_ticket_messages_ticket_idx on public.support_ticket_messages (ticket_id, created_at);
create index if not exists support_ticket_messages_business_idx on public.support_ticket_messages (business_id);
alter table public.support_ticket_messages enable row level security;
revoke all on table public.support_ticket_messages from public, anon, authenticated;
grant select on table public.support_ticket_messages to authenticated;
grant all on table public.support_ticket_messages to service_role;
drop policy if exists "business members read their ticket messages" on public.support_ticket_messages;
create policy "business members read their ticket messages" on public.support_ticket_messages
  for select to authenticated using (public.is_business_member(business_id));
-- the two step sign in rule every table has (sql/zella_mfa_enforcement.sql)
drop policy if exists zella_mfa_required on public.support_ticket_messages;
create policy zella_mfa_required on public.support_ticket_messages as restrictive for all to authenticated
  using ((select public.zella_mfa_satisfied())) with check ((select public.zella_mfa_satisfied()));

alter table public.support_tickets add column if not exists first_response_at timestamptz;

create or replace function public.zella_admin_ticket_reply(p_ticket uuid, p_author uuid, p_body text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t record; v_id uuid; v_body text := btrim(coalesce(p_body, ''));
begin
  if length(v_body) not between 1 and 4000 then raise exception 'BAD_INPUT'; end if;
  select id, business_id, created_by, subject, status into t from public.support_tickets where id = p_ticket for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  insert into public.support_ticket_messages (ticket_id, business_id, author_id, author_side, body)
  values (t.id, t.business_id, p_author, 'zella', v_body) returning id into v_id;
  update public.support_tickets set first_response_at = coalesce(first_response_at, now()), updated_at = now(),
         status = case when status = 'open' then 'in_progress' else status end
   where id = t.id;
  if t.created_by is not null then
    insert into public.staff_notifications (business_id, user_id, kind, severity, title, body, page_key, entity_id, delivery_status, sms_status)
    values (t.business_id, t.created_by, 'support_reply', 'info', 'Zella Voice support replied', left(t.subject, 200), 'settings', t.id, 'skipped', 'skipped');
  end if;
  return jsonb_build_object('message_id', v_id, 'business_id', t.business_id);
end $$;
revoke all on function public.zella_admin_ticket_reply(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.zella_admin_ticket_reply(uuid, uuid, text) to service_role;

create or replace function public.zella_business_ticket_reply(p_ticket uuid, p_body text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t record; v_id uuid; v_body text := btrim(coalesce(p_body, ''));
begin
  if auth.uid() is null then raise exception 'NOT_SIGNED_IN'; end if;
  if length(v_body) not between 1 and 4000 then raise exception 'BAD_INPUT'; end if;
  select id, business_id, status into t from public.support_tickets where id = p_ticket for update;
  -- the same people who may update their business's tickets; anyone else learns nothing about the ticket
  if not found or not exists (select 1 from public.business_members bm where bm.business_id = t.business_id and bm.user_id = auth.uid()
       and bm.status = 'active' and bm.role = any (array['owner', 'admin', 'manager'])) then
    raise exception 'NOT_ALLOWED';
  end if;
  insert into public.support_ticket_messages (ticket_id, business_id, author_id, author_side, body)
  values (t.id, t.business_id, auth.uid(), 'business', v_body) returning id into v_id;
  update public.support_tickets set updated_at = now(), status = case when status in ('resolved', 'closed') then 'open' else status end, resolved_at = case when status in ('resolved', 'closed') then null else resolved_at end
   where id = t.id;
  return jsonb_build_object('message_id', v_id);
end $$;
revoke all on function public.zella_business_ticket_reply(uuid, text) from public, anon;
grant execute on function public.zella_business_ticket_reply(uuid, text) to authenticated;

create or replace function public.zella_support_ticket_alert_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_kind text := new.metadata ->> 'kind'; v_alert text; v_title text; v_name text;
begin
  if coalesce(new.metadata ->> 'source', '') <> 'business_settings' then return new; end if;
  select name into v_name from public.businesses where id = new.business_id;
  if v_kind = 'cancellation' then v_alert := 'support_cancellation_request'; v_title := 'A business asked to cancel';
  elsif v_kind = 'plan_change' then v_alert := 'support_plan_change_request'; v_title := 'A business asked for a plan change';
  elsif new.priority = 'urgent' then v_alert := 'support_urgent_ticket'; v_title := 'Urgent support request';
  else return new; end if;
  perform public.zella_platform_alert(v_alert, v_title, coalesce(v_name, 'A business') || ': ' || left(new.subject, 160),
    case when v_alert = 'support_plan_change_request' then 'info' else 'urgent' end, new.business_id, new.id::text, jsonb_build_object('ticket_id', new.id));
  return new;
end $$;
revoke all on function public.zella_support_ticket_alert_trg() from public, anon, authenticated;
drop trigger if exists zella_support_ticket_alert on public.support_tickets;
create trigger zella_support_ticket_alert after insert on public.support_tickets
  for each row execute function public.zella_support_ticket_alert_trg();

insert into public.platform_settings (key, value)
values ('support_business_hours', '{"days": [1, 2, 3, 4, 5], "start": "09:00", "end": "17:00", "timezone": "America/New_York", "first_response_hours": 4}'::jsonb)
on conflict (key) do nothing;

commit;
