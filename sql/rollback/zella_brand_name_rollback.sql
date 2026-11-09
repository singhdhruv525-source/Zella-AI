-- Undoes sql/zella_brand_name.sql: the wording goes back to the short "Zella". Safe to run again.
do $$
declare f record; x record; v_def text;
begin
  for f in select distinct p.oid, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join public.zella_brand_name_pairs() b on b.fn = p.proname
            where n.nspname = 'public' and position(b.new_text in p.prosrc) > 0
  loop
    v_def := pg_get_functiondef(f.oid);
    for x in select b.old_text, b.new_text from public.zella_brand_name_pairs() b where b.fn = f.proname loop
      v_def := replace(v_def, x.new_text, x.old_text);
    end loop;
    execute v_def;
  end loop;
end $$;
drop function if exists public.zella_brand_name_pairs();
