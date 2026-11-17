-- Rollback baseline is captured on first apply of this version, never on reruns.
-- An older deployment needs its original backup; this cannot reconstruct already-overwritten state.
create table if not exists public.zella_db_fixes_undo (seq bigint generated always as identity, command text not null);
revoke all on public.zella_db_fixes_undo from public, anon, authenticated, service_role;
do $capture$
declare f text; p oid; r record; g record; ddl text; cols text[];
begin
 if not exists (select 1 from public.zella_db_fixes_undo) then
  insert into public.zella_db_fixes_undo(command) values ('select 1');
  if to_regclass('public.legal_acceptances') is not null then
    select * into r from pg_policies where schemaname='public' and tablename='legal_acceptances' and policyname='legal_acceptances_read';
    insert into public.zella_db_fixes_undo(command) values ('drop policy if exists legal_acceptances_read on public.legal_acceptances');
    if found and r.policyname is not null then
      select string_agg(case when x='public' then 'public' else quote_ident(x) end, ',') into ddl from unnest(r.roles) x;
      insert into public.zella_db_fixes_undo(command) values ('create policy legal_acceptances_read on public.legal_acceptances as ' || r.permissive || ' for ' || r.cmd || ' to ' || ddl ||
        case when r.qual is null then '' else ' using (' || r.qual || ')' end || case when r.with_check is null then '' else ' with check (' || r.with_check || ')' end);
    end if;
  end if;
  if to_regclass('public.agent_config_versions') is not null then
    select * into r from pg_policies where schemaname='public' and tablename='agent_config_versions' and policyname='agent_config_versions_read';
    insert into public.zella_db_fixes_undo(command) values ('drop policy if exists agent_config_versions_read on public.agent_config_versions');
    if found and r.policyname is not null then
      select string_agg(case when x='public' then 'public' else quote_ident(x) end, ',') into ddl from unnest(r.roles) x;
      insert into public.zella_db_fixes_undo(command) values ('create policy agent_config_versions_read on public.agent_config_versions as ' || r.permissive || ' for ' || r.cmd || ' to ' || ddl ||
        case when r.qual is null then '' else ' using (' || r.qual || ')' end || case when r.with_check is null then '' else ' with check (' || r.with_check || ')' end);
    end if;
  end if;
  if to_regclass('public.legal_acceptances_business_idx') is null then insert into public.zella_db_fixes_undo(command) values ('drop index if exists public.legal_acceptances_business_idx'); end if;
  if to_regclass('public.offer_events_business_idx') is null then insert into public.zella_db_fixes_undo(command) values ('drop index if exists public.offer_events_business_idx'); end if;
  if to_regclass('public.offer_redemptions_payment_idx') is null then insert into public.zella_db_fixes_undo(command) values ('drop index if exists public.offer_redemptions_payment_idx'); end if;
 end if;
end $capture$;

-- Zella - database advisor fixes (2026-10-26). Safe to re-run. Adds indexes, rewrites one policy the same way,
-- and removes one exact duplicate policy. No data is changed; who can read or write anything is unchanged.
--
-- 1. Foreign keys without an index (Supabase performance advisor): deletes and joins on these scan the table.
-- 2. legal_acceptances_read re-evaluated auth.uid() for every row; (select auth.uid()) evaluates it once.
-- 3. agent_config_versions had two identical permissive SELECT policies (agent_config_versions_read, created in the
--    live project only, and agent_config_versions_select from zella_workflows.sql). The extra one is dropped only
--    when the other exists with the same rule, so access stays exactly the same.
-- Rollback: sql/rollback/zella_db_fixes_rollback.sql (captured definitions and object provenance).

do $$
begin
  if to_regclass('public.legal_acceptances') is not null then create index if not exists legal_acceptances_business_idx on public.legal_acceptances (business_id); end if;
  if to_regclass('public.offer_events') is not null then create index if not exists offer_events_business_idx on public.offer_events (business_id); end if;
  if to_regclass('public.offer_redemptions') is not null then create index if not exists offer_redemptions_payment_idx on public.offer_redemptions (payment_id); end if;
end $$;

do $$ begin
  if to_regclass('public.legal_acceptances') is not null then
drop policy if exists legal_acceptances_read on public.legal_acceptances;
create policy legal_acceptances_read on public.legal_acceptances for select to authenticated
  using (user_id = (select auth.uid()) or (business_id is not null and public.zella_has_role(business_id, array['owner', 'admin'])));

  end if;
end $$;

do $$
begin
  if exists (select 1 from pg_policies a join pg_policies b on b.schemaname=a.schemaname and b.tablename=a.tablename
    where a.schemaname='public' and a.tablename='agent_config_versions'
      and a.policyname='agent_config_versions_select' and b.policyname='agent_config_versions_read'
      and a.cmd=b.cmd and a.qual is not distinct from b.qual and a.with_check is not distinct from b.with_check
      and a.roles=b.roles and a.permissive=b.permissive) then
    drop policy agent_config_versions_read on public.agent_config_versions;
  end if;
end $$;
