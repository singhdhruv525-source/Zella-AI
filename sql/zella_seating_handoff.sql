-- Apply after zella_tables.sql and zella_review_sql_fixes.sql (if used).
-- Keep the caller's seating requirement on large-party requests for the team.
-- No table is assigned and the request still needs confirmation by the team.
begin;
do $$
declare
  def text := pg_get_functiondef('public.zella_ai_booking(text,uuid,text,jsonb)'::regprocedure);
  old_line text := $a$update appointments set party_size = v_party, metadata = coalesce(metadata, '{}') || jsonb_build_object('source', 'ai_call') where id = v_appt;$a$;
  new_line text := $a$update appointments set party_size = v_party, metadata = coalesce(metadata, '{}') || jsonb_build_object('source', 'ai_call', 'seating', v_args ->> 'seating') where id = v_appt;$a$;
begin
  if position(new_line in def) > 0 then return; end if;
  if position('a large party is the team''s to arrange' in def) = 0
     or position(old_line in def) = 0 then
    raise exception 'zella_ai_booking has changed; review the seating handoff patch';
  end if;
  execute replace(def, old_line, new_line);
end $$;
commit;
