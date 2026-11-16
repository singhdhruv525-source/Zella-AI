-- Undoes sql/zella_support_notes.sql: every note goes back into its ticket's metadata.notes, oldest first, in the old
-- shape ({ text, author_id, created_at }), then the guard, the helper and the table go. Safe to run twice.
begin;
drop trigger if exists zella_support_notes_guard on public.support_tickets;
drop trigger if exists zella_support_notes_guard_new on public.support_tickets;
do $$ begin
  if to_regclass('public.support_ticket_notes') is not null then
    update public.support_tickets t
       set metadata = coalesce(t.metadata, '{}'::jsonb) || jsonb_build_object('notes', coalesce(t.metadata -> 'notes', '[]'::jsonb) || n.notes)
      from (select ticket_id, jsonb_agg(jsonb_strip_nulls(jsonb_build_object('text', body, 'author_id', author_id, 'created_at', created_at)) order by created_at, id) notes
              from public.support_ticket_notes group by ticket_id) n
     where n.ticket_id = t.id;
    drop table public.support_ticket_notes;
  end if;
end $$;
drop function if exists public.zella_support_notes_guard_trg();
drop function if exists public.zella_take_ticket_notes(uuid, jsonb);
drop function if exists public.zella_try_timestamptz(text);
commit;
