-- Undoes sql/zella_writing_cleanup.sql exactly: every changed function comes back from zella_function_archive and every
-- changed value from zella_text_archive (only values this migration changed), then the helpers go. Safe to run twice.
begin;
do $$
declare a record; v_jsonb boolean; v_restored int;
begin
  if to_regclass('public.zella_function_archive') is not null then
    for a in select signature, definition from public.zella_function_archive where migration = 'zella_writing_cleanup' loop
      execute a.definition;
    end loop;
    delete from public.zella_function_archive where migration = 'zella_writing_cleanup';
  end if;
  if to_regclass('public.zella_text_archive') is not null then
    for a in select * from public.zella_text_archive where migration = 'zella_writing_cleanup' loop
      select data_type = 'jsonb' into v_jsonb from information_schema.columns where table_schema = 'public' and table_name = a.tbl and column_name = a.col;
      execute format('update public.%I set %I = %L::%s where %I::text = %L and %I is not distinct from public.%I(%L::%s)', a.tbl, a.col, a.old_value, case when v_jsonb then 'jsonb' else 'text' end,
                     case a.tbl when 'industry_crm_presets' then 'key' when 'industry_message_policy' then 'industry_key' else 'id' end, a.row_key, a.col,
                     case when v_jsonb then 'zella_plain_json' else 'zella_plain_words' end, a.old_value, case when v_jsonb then 'jsonb' else 'text' end);
      get diagnostics v_restored = row_count;
      if v_restored <> 1 then
        raise exception 'ROLLBACK_CONFLICT: %.% row % changed or is missing; archive retained', a.tbl, a.col, a.row_key;
      end if;
    end loop;
    delete from public.zella_text_archive where migration = 'zella_writing_cleanup';
    if not exists (select 1 from public.zella_text_archive) then drop table public.zella_text_archive; end if;
  end if;
end $$;
drop function if exists public.zella_plain_json(jsonb);
drop function if exists public.zella_plain_words(text);
commit;
