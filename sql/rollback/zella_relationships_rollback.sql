-- Undoes sql/zella_relationships.sql. One transaction: all or nothing.
-- The two tables are kept, renamed (customer_relationships_rolled_back, customer_consents_rolled_back), so no
-- relationship, verification or consent that was recorded is lost; re-applying the migration starts new, empty tables.
begin;
-- take the relationship step out of the customer merge again (exactly the text the migration added)
do $$
declare def text;
begin
  if to_regprocedure('public.zella_merge_customers(uuid, uuid, uuid)') is null then return; end if;
  def := pg_get_functiondef('public.zella_merge_customers(uuid, uuid, uuid)'::regprocedure);
  if position('zella_relationships_merge' in def) > 0 then
    def := replace(def, E'\n  perform public.zella_people_merge(p_business_id, p_keep, p_drop); /* zella_relationships_merge */', '');
    def := replace(def, $a$'contact_consents', 'data_rights_requests', 'customer_relationships')$a$, $a$'contact_consents', 'data_rights_requests')$a$);
    if position('zella_relationships_merge' in def) > 0 then raise exception 'could not take the merge step out; review'; end if;
    execute def;
  end if;
end $$;
drop function if exists public.zella_people_merge(uuid, uuid, uuid);
drop function if exists public.zella_people_merge_install();
drop function if exists public.zella_people_panel(uuid, uuid, uuid);
drop function if exists public.zella_consent_revoke(uuid, text);
drop function if exists public.zella_consent_record(uuid, uuid, uuid, text, text, uuid, text, date, text);
drop function if exists public.zella_relationship_revoke(uuid, text);
drop function if exists public.zella_relationship_verify(uuid, text, uuid, text, text[], date, timestamptz);
drop function if exists public.zella_relationship_verify(uuid, text, uuid, text, text[], date);
drop function if exists public.zella_relationship_verify(uuid, text, uuid, text, text[]);
drop function if exists public.zella_relationship_verify(uuid, text);
drop function if exists public.zella_relationship_save(uuid, uuid, uuid, uuid, uuid, text, text[], date, text, timestamptz);
drop function if exists public.zella_relationship_save(uuid, uuid, uuid, uuid, uuid, text, text[], date, text);
drop function if exists public.zella_people_audit(uuid, text, text, uuid, jsonb, jsonb);
drop function if exists public.zella_is_authorized(uuid, uuid, uuid, uuid, text);
drop function if exists public.zella_relationship_in_force(public.customer_relationships);
drop function if exists public.zella_people_subject_ok(uuid, uuid, uuid);
drop function if exists public.zella_people_can_verify(uuid);
drop function if exists public.zella_people_can_edit(uuid);
do $$
declare i record; v_suffix text := '_rb' || to_char(now(), 'YYYYMMDDHH24MISS');
begin
  -- free the index names, so applying the migration again creates its own indexes
  for i in select ix.relname from pg_index x join pg_class ix on ix.oid = x.indexrelid
            where x.indrelid in (coalesce(to_regclass('public.customer_relationships'), 0::regclass), coalesce(to_regclass('public.customer_consents'), 0::regclass))
              and not x.indisprimary loop
    execute format('alter index public.%I rename to %I', i.relname, left(i.relname, 40) || v_suffix);
  end loop;
  if to_regclass('public.customer_consents') is not null then
    if to_regclass('public.customer_consents_rolled_back') is not null then
      execute format('alter table public.customer_consents_rolled_back rename to %I', 'customer_consents_rolled_back_' || to_char(now(), 'YYYYMMDDHH24MISS'));
    end if;
    alter table public.customer_consents rename to customer_consents_rolled_back;
    revoke all on public.customer_consents_rolled_back from authenticated;
  end if;
  if to_regclass('public.customer_relationships') is not null then
    if to_regclass('public.customer_relationships_rolled_back') is not null then
      execute format('alter table public.customer_relationships_rolled_back rename to %I', 'customer_relationships_rolled_back_' || to_char(now(), 'YYYYMMDDHH24MISS'));
    end if;
    alter table public.customer_relationships rename to customer_relationships_rolled_back;
    revoke all on public.customer_relationships_rolled_back from authenticated;
  end if;
end $$;
commit;
