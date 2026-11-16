-- Zella Voice: internal support notes stay with Zella Voice (docs/ADMIN_AUDIT_2026-11-16.md OPS-06, OPS-26).
-- Admins' internal notes were kept in support_tickets.metadata.notes, and every member of the business may read its
-- tickets (including metadata) through the API, although the admin page says only Zella Voice admins see them.
--   1. A server only table, support_ticket_notes (row security on, no policies, no grants to signed in people): only
--      the admin function (server key) reads and writes it.
--   2. Notes already in metadata are moved there and removed from metadata (production had none on 16 Nov 2026).
--   3. A guard on support_tickets moves any notes written into metadata later (for example by an older admin
--      function still deployed) into the table, so they never stay readable by the business, whatever the deploy order.
-- Rollback: sql/rollback/zella_support_notes_rollback.sql (puts every note back into metadata, oldest first).
begin;

do $$ begin
  if to_regclass('public.support_tickets') is null then raise exception 'VERSION_MISMATCH: support_tickets is missing'; end if;
  if to_regclass('public.support_ticket_notes') is not null and not exists (
       select 1 from information_schema.columns where table_schema = 'public' and table_name = 'support_ticket_notes' and column_name = 'moved_from_metadata') then
    raise exception 'VERSION_MISMATCH: a different support_ticket_notes table already exists';
  end if;
end $$;

create table if not exists public.support_ticket_notes (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.support_tickets(id) on delete cascade,
  author_id uuid,
  body text not null check (length(btrim(body)) between 1 and 4000),
  created_at timestamptz not null default now(),
  moved_from_metadata boolean not null default false
);
create index if not exists support_ticket_notes_ticket_idx on public.support_ticket_notes (ticket_id, created_at);
alter table public.support_ticket_notes enable row level security;
revoke all on table public.support_ticket_notes from public, anon, authenticated;
grant all on table public.support_ticket_notes to service_role;

-- moves notes out of a metadata value into the table; returns the metadata without them
create or replace function public.zella_take_ticket_notes(p_ticket uuid, p_metadata jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if p_metadata is null or not (p_metadata ? 'notes') then return p_metadata; end if;
  if jsonb_typeof(p_metadata -> 'notes') = 'array' then
    insert into public.support_ticket_notes (ticket_id, author_id, body, created_at, moved_from_metadata)
    select p_ticket,
           case when n ->> 'author_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then (n ->> 'author_id')::uuid end,
           left(btrim(n ->> 'text'), 4000),
           coalesce(case when (n ->> 'created_at') ~ '^\d{4}-\d{2}-\d{2}' then (n ->> 'created_at')::timestamptz end, now()),
           true
      from jsonb_array_elements(p_metadata -> 'notes') n
     where jsonb_typeof(n) = 'object' and length(btrim(coalesce(n ->> 'text', ''))) > 0;
  end if;
  return p_metadata - 'notes';
end $$;
revoke all on function public.zella_take_ticket_notes(uuid, jsonb) from public, anon, authenticated;

create or replace function public.zella_support_notes_guard_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    if new.metadata ? 'notes' then new.metadata := public.zella_take_ticket_notes(new.id, new.metadata); end if;
    return new;
  end if;
  -- AFTER INSERT: the ticket row exists now, so its notes can be moved; the update runs the BEFORE UPDATE branch
  if new.metadata ? 'notes' then update public.support_tickets set metadata = metadata where id = new.id; end if;
  return null;
end $$;
revoke all on function public.zella_support_notes_guard_trg() from public, anon, authenticated;

-- existing notes (the guard isn't on yet, so this is the only move)
update public.support_tickets set metadata = public.zella_take_ticket_notes(id, metadata) where metadata ? 'notes';

drop trigger if exists zella_support_notes_guard on public.support_tickets;
create trigger zella_support_notes_guard before update of metadata on public.support_tickets
  for each row execute function public.zella_support_notes_guard_trg();
drop trigger if exists zella_support_notes_guard_new on public.support_tickets;
create trigger zella_support_notes_guard_new after insert on public.support_tickets
  for each row execute function public.zella_support_notes_guard_trg();

commit;
