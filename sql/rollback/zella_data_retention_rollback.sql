-- Rollback of sql/zella_data_retention.sql: removes the dry run, the hold and period functions, the guard and the purge
-- switch. The tables (data_retention_policies, legal_holds with every hold placed or released, retention_removed_files)
-- and their rows are kept (a rollback never deletes data; they stay server only) and applying the file again uses them.
-- The hold and period tables are locked against writes first, so nothing lands between the checks and the removal.
-- Safe to run twice. Refuses (ROLLBACK_DRIFT) if any function differs from that file's version, if the purge
-- switch is on, if a legal hold is active, if an owner changed a period or recorded legal approval (each would be
-- lost), or while a later migration (the purge) uses these functions. The audit trail stays in audit_logs.
begin;

do $$
declare
  f record;
  busy text := '';
    mine constant jsonb := '{
    "public.zella_retention_setting_guard()": "bb4c21aaa0137af97dd3d22e6edc9b96",
    "public.zella_retention_on_hold(uuid)": "aa38f978a7484df0cd06decf0e7b13d6",
    "public.zella_retention_candidates(text,timestamp with time zone)": "80d1a34ab624d8d4acbc882818a829c2",
    "public.zella_retention_preview(uuid,text,integer)": "1fd49ad9a112ebd390d36d13b89b80ea",
    "public.zella_retention_overview(uuid)": "c7b1717cdeaf2e725a70ec15b23fc18b",
    "public.zella_retention_policy_set(uuid,text,integer,text,text)": "dd3f7ba07966beb77b57e0354a3ad345",
    "public.zella_retention_switch_set(uuid,boolean,text)": "fce745114b992f3977beae3a74876f46",
    "public.zella_legal_hold_place(uuid,uuid,text)": "36b7984955df89696bdd811d92048c21",
    "public.zella_legal_hold_release(uuid,uuid,text)": "906697b3714e1fcebe61a7ae74cc49b0"
  }';
begin
  if to_regclass('public.legal_holds') is not null then execute 'lock table public.legal_holds in share row exclusive mode'; end if;
  if to_regclass('public.data_retention_policies') is not null then execute 'lock table public.data_retention_policies in share row exclusive mode'; end if;
  perform pg_advisory_xact_lock(hashtextextended('zella_legal_holds', 0));
  for f in select key as sig, value #>> '{}' as want from jsonb_each(mine) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'ROLLBACK_DRIFT: % has changed since zella_data_retention.sql', f.sig;
    end if;
  end loop;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'
              and (p.prosrc like '%zella_retention_candidates%' or p.prosrc like '%zella_retention_on_hold%') and not (p.oid = any (array(select to_regprocedure(k)::oid from jsonb_object_keys(mine) k where to_regprocedure(k) is not null)))) then
    raise exception 'ROLLBACK_DRIFT: other functions use these; roll back sql/zella_retention_purge.sql first';
  end if;
  if exists (select 1 from public.platform_settings where key = 'retention_purge_enabled' and value <> 'false'::jsonb) then
    raise exception 'ROLLBACK_DRIFT: the purge switch is on; a Zella Voice owner switches it off first';
  end if;
  if to_regclass('public.legal_holds') is not null then
    execute 'select case when exists (select 1 from public.legal_holds where released_at is null) then ''a legal hold is active'' else '''' end' into busy;
  end if;
  if busy = '' and to_regclass('public.retention_removed_files') is not null then
    execute 'select case when exists (select 1 from public.retention_removed_files) then ''files were removed under retention'' else '''' end' into busy;
  end if;
  if busy = '' and to_regclass('public.data_retention_policies') is not null then
    execute 'select case when exists (select 1 from public.data_retention_policies where days <> architecture_days or legal_status <> ''pending_legal_review'') then ''an owner changed a retention period or recorded legal approval'' else '''' end' into busy;
  end if;
  if busy <> '' then raise exception 'ROLLBACK_DRIFT: %; it would be lost', busy; end if;
end $$;

drop trigger if exists zella_retention_setting_guard on public.platform_settings;
drop function if exists public.zella_legal_hold_release(uuid, uuid, text);
drop function if exists public.zella_legal_hold_place(uuid, uuid, text);
drop function if exists public.zella_retention_switch_set(uuid, boolean, text);
drop function if exists public.zella_retention_policy_set(uuid, text, integer, text, text);
drop function if exists public.zella_retention_overview(uuid);
drop function if exists public.zella_retention_preview(uuid, text, integer);
drop function if exists public.zella_retention_candidates(text, timestamptz);
drop function if exists public.zella_retention_on_hold(uuid);
drop function if exists public.zella_retention_setting_guard();
delete from public.platform_settings where key = 'retention_purge_enabled';

commit;
