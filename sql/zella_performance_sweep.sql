-- Zella - performance sweep (2026-10-25). Safe to re-run.
-- 1. An index for every foreign key that has none (faster joins and deletes as data grows).
-- 2. auth.uid() inside row rules is wrapped as (select auth.uid()) so it runs once per query, not once per row.
do $$
declare c record; idx text; cols text;
begin
  for c in
    select con.oid, con.conname, con.conrelid, con.conkey, cl.relname
      from pg_constraint con join pg_class cl on cl.oid = con.conrelid
     where con.contype = 'f' and cl.relnamespace = 'public'::regnamespace
       and not exists (select 1 from pg_index i where i.indrelid = con.conrelid and i.indisvalid
                        and (i.indkey::int2[])[0:array_length(con.conkey, 1) - 1] = con.conkey)
  loop
    select string_agg(quote_ident(a.attname), ', ' order by k.ord) into cols
      from unnest(c.conkey) with ordinality k(attnum, ord) join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum;
    idx := left('fkx_' || c.relname || '_' || c.conname, 63);
    execute format('create index if not exists %I on public.%I (%s)', idx, c.relname, cols);
  end loop;
end $$;

do $$
declare p record; q text; w text; cmd text;
begin
  for p in
    select pol.polname, cl.relname, pol.polqual, pol.polwithcheck, pol.polrelid
      from pg_policy pol join pg_class cl on cl.oid = pol.polrelid
     where cl.relnamespace = 'public'::regnamespace
       and (pg_get_expr(pol.polqual, pol.polrelid) ~ 'auth\.uid\(\)' or pg_get_expr(pol.polwithcheck, pol.polrelid) ~ 'auth\.uid\(\)')
  loop
    q := pg_get_expr(p.polqual, p.polrelid);
    w := pg_get_expr(p.polwithcheck, p.polrelid);
    -- already wrapped: "( SELECT auth.uid() AS uid)" stays as it is
    if q is not null then q := regexp_replace(q, '(?<!SELECT )auth\.uid\(\)', '(select auth.uid())', 'g'); end if;
    if w is not null then w := regexp_replace(w, '(?<!SELECT )auth\.uid\(\)', '(select auth.uid())', 'g'); end if;
    cmd := format('alter policy %I on public.%I', p.polname, p.relname);
    if q is not null then cmd := cmd || ' using (' || q || ')'; end if;
    if w is not null then cmd := cmd || ' with check (' || w || ')'; end if;
    execute cmd;
  end loop;
end $$;
