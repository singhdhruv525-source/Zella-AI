-- Zella Voice: the brand was "Zella AI". New businesses' default receptionist (create_zella_ai_agent, called by
-- create_business) is now named and introduced as Zella Voice. Function bodies only; no table data changes
-- (no existing receptionist uses the old name). Safe to run again.

do $$
declare f record; v_def text;
begin
  for f in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('create_zella_ai_agent', 'create_business')
             and p.prosrc like '%Zella AI%'
  loop
    v_def := replace(pg_get_functiondef(f.oid), 'Zella AI', 'Zella Voice');
    execute v_def;
  end loop;
end $$;
