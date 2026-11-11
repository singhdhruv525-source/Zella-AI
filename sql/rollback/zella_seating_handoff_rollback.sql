-- Rollback for sql/zella_seating_handoff.sql: large-party requests stop recording the caller's seating requirement in
-- the appointment's metadata again. Deletes no data: seating already saved on existing requests stays. One
-- transaction; a second run changes nothing.
begin;
do $$
declare
  def text := pg_get_functiondef('public.zella_ai_booking(text,uuid,text,jsonb)'::regprocedure);
  old_line text := $a$update appointments set party_size = v_party, metadata = coalesce(metadata, '{}') || jsonb_build_object('source', 'ai_call') where id = v_appt;$a$;
  new_line text := $a$update appointments set party_size = v_party, metadata = coalesce(metadata, '{}') || jsonb_build_object('source', 'ai_call', 'seating', v_args ->> 'seating') where id = v_appt;$a$;
begin
  if position(new_line in def) = 0 then
    if position(old_line in def) > 0 then return; end if;
    raise exception 'zella_ai_booking has changed; review the seating handoff rollback';
  end if;
  if (length(def) - length(replace(def, new_line, ''))) / length(new_line) <> 1 then
    raise exception 'zella_ai_booking holds the seating line more than once; review the rollback';
  end if;
  execute replace(def, new_line, old_line);
end $$;
commit;
