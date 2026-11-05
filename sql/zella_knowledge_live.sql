-- Zella - knowledge an owner adds or edits goes live when it is saved, after the same check (5 Nov 2026). Safe to run
-- twice. Not applied. Audit: docs/CRM_UPDATES_AUDIT_2026-11-05.md (K1, K2). Class V.
--
-- K1  Added or edited answers wait in "processing" for the Zella - Knowledge workflow to check them (title and answer
--     present, answer at most 4,000 characters) and mark them ready. That workflow is not active in production (n8n,
--     read 5 Nov) and no scheduled job runs, so an owner's answers would never become answerable.
-- K2  Editing an answer that is live took it out of use until the check ran, so the receptionist had neither the old
--     nor the new answer meanwhile ("Zella keeps using nothing for this until the new version is checked").
-- Now the database runs that check as the item is saved: a passing item is ready at once (new answer replaces the old
-- in the same save); a failing one is refused with the reason, and the item keeps its previous version and status, so
-- a bad edit never takes a good answer offline. Drafts are not checked until they are sent. The workflow stays usable:
-- platform setting knowledge_check = "external" leaves items in "processing" for it, as before.

create or replace function public.zella_knowledge_check_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status <> 'processing' then return new; end if;
  if coalesce(public.zella_setting('knowledge_check', '"database"'::jsonb) #>> '{}', 'database') = 'external' then return new; end if;
  if nullif(trim(coalesce(new.title, '')), '') is null then raise exception 'KNOWLEDGE_TITLE_EMPTY' using hint = 'Give it a title.'; end if;
  if nullif(trim(coalesce(new.answer, '')), '') is null then raise exception 'KNOWLEDGE_ANSWER_EMPTY' using hint = 'Write the answer.'; end if;
  if length(trim(new.answer)) > 4000 then raise exception 'KNOWLEDGE_ANSWER_TOO_LONG' using hint = 'Keep the answer under 4,000 characters.'; end if;
  new.status := 'ready'; new.ready_at := now(); new.error := null; new.sync_attempts := 0;
  return new;
end $$;
revoke execute on function public.zella_knowledge_check_trg() from public, anon, authenticated;
-- named to run after zella_knowledge_guard_trg and zella_knowledge_source_guard_trg (BEFORE triggers run by name)
drop trigger if exists zella_knowledge_zcheck_trg on public.knowledge_items;
create trigger zella_knowledge_zcheck_trg before insert or update on public.knowledge_items
  for each row execute function public.zella_knowledge_check_trg();

-- items already waiting (none in production on 5 Nov) are checked now; any that fail are marked failed with the reason
do $$
declare k record; n_ok int := 0; n_bad int := 0;
begin
  if coalesce(public.zella_setting('knowledge_check', '"database"'::jsonb) #>> '{}', 'database') = 'external' then return; end if;
  for k in select id, title, answer from public.knowledge_items where status = 'processing' for update loop
    if nullif(trim(coalesce(k.title, '')), '') is null or nullif(trim(coalesce(k.answer, '')), '') is null or length(trim(k.answer)) > 4000 then
      update public.knowledge_items set status = 'failed', error = 'The title or answer is empty, or the answer is over 4,000 characters.' where id = k.id;
      n_bad := n_bad + 1;
    else
      update public.knowledge_items set status = 'ready', ready_at = now(), error = null where id = k.id;   -- service write: the guard leaves status alone
      n_ok := n_ok + 1;
    end if;
  end loop;
  raise notice 'zella_knowledge_live: % waiting items made ready, % failed', n_ok, n_bad;
end $$;
