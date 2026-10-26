-- Zella - database advisor fixes (2026-10-26). Safe to re-run. Adds indexes, rewrites one policy the same way,
-- and removes one exact duplicate policy. No data is changed; who can read or write anything is unchanged.
--
-- 1. Foreign keys without an index (Supabase performance advisor): deletes and joins on these scan the table.
-- 2. legal_acceptances_read re-evaluated auth.uid() for every row; (select auth.uid()) evaluates it once.
-- 3. agent_config_versions had two identical permissive SELECT policies (agent_config_versions_read, created in the
--    live project only, and agent_config_versions_select from zella_workflows.sql). The extra one is dropped only
--    when the other exists with the same rule, so access stays exactly the same.
-- Rollback: drop the three indexes; re-run the policy statements from zella_settings_system.sql section 7.

do $$
begin
  if to_regclass('public.legal_acceptances') is not null then create index if not exists legal_acceptances_business_idx on public.legal_acceptances (business_id); end if;
  if to_regclass('public.offer_events') is not null then create index if not exists offer_events_business_idx on public.offer_events (business_id); end if;
  if to_regclass('public.offer_redemptions') is not null then create index if not exists offer_redemptions_payment_idx on public.offer_redemptions (payment_id); end if;
end $$;

drop policy if exists legal_acceptances_read on public.legal_acceptances;
create policy legal_acceptances_read on public.legal_acceptances for select to authenticated
  using (user_id = (select auth.uid()) or (business_id is not null and public.zella_has_role(business_id, array['owner', 'admin'])));

do $$
begin
  if exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'agent_config_versions' and policyname = 'agent_config_versions_select'
               and cmd = 'SELECT' and qual = 'zella_is_member(business_id)')
     and exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'agent_config_versions' and policyname = 'agent_config_versions_read'
               and cmd = 'SELECT' and qual = 'zella_is_member(business_id)') then
    drop policy agent_config_versions_read on public.agent_config_versions;
  end if;
end $$;
