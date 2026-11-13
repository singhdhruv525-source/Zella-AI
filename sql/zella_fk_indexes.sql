-- Zella Voice: an index for every foreign key that has none (DB-15, conformance gap G-2).
-- 38 foreign keys on existing tables had no index starting with their columns (checked against production read-only
-- on 13 Nov 2026: the same 38). Without one, deleting or updating the parent row scans the whole child table, and
-- per-business reads on these columns scan too.
-- Plain CREATE INDEX, not CONCURRENTLY: production holds 6 rows across these tables (13 Nov 2026), so each index takes
-- milliseconds, and CONCURRENTLY cannot run inside the SQL editor's transaction. Run it when the tables are this small.
-- Each index is created only when no existing index already starts with exactly those columns, so nothing is
-- duplicated and a re-run is a no-op. Indexes change no data and no permissions.
-- Rollback: sql/rollback/zella_fk_indexes_rollback.sql (drops only the indexes this file creates, by name)
-- Check (expect 0 rows): the query in tests/fk_indexes/run.sh "unindexed".

create or replace function public.zella_fk_index_list()
returns table (tbl text, cols text, index_name text) language sql immutable set search_path = public as $$
  values
    ('appointments', 'record_suggested_id', 'zella_fk_appointments_record_suggested_id_idx'),
    ('assistant_deliveries', 'version_id', 'zella_fk_assistant_deliveries_version_id_idx'),
    ('blocked_times', 'resource_id', 'zella_fk_blocked_times_resource_id_idx'),
    ('config_migration_snapshots', 'business_id', 'zella_fk_config_migration_snapshots_business_id_idx'),
    ('crm_record_files', 'business_id', 'zella_fk_crm_record_files_business_id_idx'),
    ('crm_record_secrets', 'business_id', 'zella_fk_crm_record_secrets_business_id_idx'),
    ('customer_charges', 'appointment_id', 'zella_fk_customer_charges_appointment_id_idx'),
    ('customer_consents', 'business_id', 'zella_fk_customer_consents_business_id_idx'),
    ('customer_consents', 'given_by_customer_id', 'zella_fk_customer_consents_given_by_customer_id_idx'),
    ('customer_relationships', 'business_id', 'zella_fk_customer_relationships_business_id_idx'),
    ('legal_acceptances', 'business_id', 'zella_fk_legal_acceptances_business_id_idx'),
    ('offer_events', 'business_id', 'zella_fk_offer_events_business_id_idx'),
    ('offer_redemptions', 'payment_id', 'zella_fk_offer_redemptions_payment_id_idx'),
    ('record_approvals', 'approver_customer_id', 'zella_fk_record_approvals_approver_customer_id_idx'),
    ('record_approvals', 'approver_relationship_id', 'zella_fk_record_approvals_approver_relationship_id_idx'),
    ('record_approvals', 'charge_id', 'zella_fk_record_approvals_charge_id_idx'),
    ('record_approvals', 'file_id', 'zella_fk_record_approvals_file_id_idx'),
    ('record_credits', 'appointment_id', 'zella_fk_record_credits_appointment_id_idx'),
    ('record_credits', 'business_id', 'zella_fk_record_credits_business_id_idx'),
    ('record_exceptions', 'business_id', 'zella_fk_record_exceptions_business_id_idx'),
    ('record_exceptions', 'inspection_id', 'zella_fk_record_exceptions_inspection_id_idx'),
    ('record_inspections', 'appointment_id', 'zella_fk_record_inspections_appointment_id_idx'),
    ('record_inspections', 'business_id', 'zella_fk_record_inspections_business_id_idx'),
    ('record_inspections', 'staff_id', 'zella_fk_record_inspections_staff_id_idx'),
    ('record_milestones', 'staff_id', 'zella_fk_record_milestones_staff_id_idx'),
    ('recurring_plans', 'customer_id', 'zella_fk_recurring_plans_customer_id_idx'),
    ('recurring_plans', 'record_id', 'zella_fk_recurring_plans_record_id_idx'),
    ('recurring_plans', 'staff_id', 'zella_fk_recurring_plans_staff_id_idx'),
    ('recurring_visits', 'appointment_id', 'zella_fk_recurring_visits_appointment_id_idx'),
    ('recurring_visits', 'business_id', 'zella_fk_recurring_visits_business_id_idx'),
    ('table_blocks', 'business_id', 'zella_fk_table_blocks_business_id_idx'),
    ('table_combinations', 'business_id', 'zella_fk_table_combinations_business_id_idx'),
    ('table_events', 'business_id', 'zella_fk_table_events_business_id_idx'),
    ('table_states', 'business_id', 'zella_fk_table_states_business_id_idx'),
    ('usage_processing_issues', 'business_id', 'zella_fk_usage_processing_issues_business_id_idx'),
    ('usage_processing_issues', 'call_id', 'zella_fk_usage_processing_issues_call_id_idx'),
    ('usage_records', 'adjusts_record_id', 'zella_fk_usage_records_adjusts_record_id_idx'),
    ('usage_thresholds', 'business_id', 'zella_fk_usage_thresholds_business_id_idx')
$$;
revoke all on function public.zella_fk_index_list() from public, anon, authenticated;

do $$
declare r record; v_rel regclass; v_cols int2[];
begin
  for r in select * from public.zella_fk_index_list() loop
    v_rel := to_regclass('public.' || r.tbl);
    if v_rel is null then raise exception 'VERSION_MISMATCH: table % is missing', r.tbl; end if;
    select array_agg(a.attnum order by x.ord) into v_cols
      from unnest(string_to_array(r.cols, ',')) with ordinality x(col, ord)
      join pg_attribute a on a.attrelid = v_rel and a.attname = x.col and not a.attisdropped;
    if v_cols is null or array_length(v_cols, 1) <> array_length(string_to_array(r.cols, ','), 1) then
      raise exception 'VERSION_MISMATCH: %.% is missing', r.tbl, r.cols;
    end if;
    -- the foreign key must still exist on exactly these columns
    if not exists (select 1 from pg_constraint c where c.conrelid = v_rel and c.contype = 'f' and c.conkey = v_cols) then
      raise exception 'VERSION_MISMATCH: %(%) is no longer a foreign key', r.tbl, r.cols;
    end if;
    continue when exists (select 1 from pg_index i where i.indrelid = v_rel
                            and (i.indkey::int2[])[0:array_length(v_cols, 1) - 1] = v_cols);
    execute format('create index if not exists %I on public.%I (%s)', r.index_name, r.tbl,
                   (select string_agg(format('%I', c), ', ') from unnest(string_to_array(r.cols, ',')) c));
  end loop;
end $$;
