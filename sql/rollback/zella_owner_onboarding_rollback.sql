-- Undoes sql/zella_owner_onboarding.sql exactly: zella_activation_report and zella_request_activation come back from
-- zella_function_archive (each must be exactly this file's version first, otherwise ROLLBACK_DRIFT and nothing
-- changes); the trigger, the new functions and the four new tables are removed. Grants are kept (same signatures).
-- No data is deleted: if the onboarding tables hold any rows, every row is first copied into
-- public.zella_owner_onboarding_archive (server only), which is then the only thing left behind. The verification
-- documents, plans and payments the journey read are never touched. Safe to run twice.
begin;
do $$
declare a record; s text; n bigint := 0;
  mine constant jsonb := jsonb_build_object(
    'public.zella_activation_report(uuid)', 'c66daff16bc3b13d5ff33542c1f43277',
    'public.zella_request_activation(uuid)', '41ab61c937ec1fd0b05b7fbd91b8353f');
begin
  if to_regclass('public.zella_function_archive') is null
     or not exists (select 1 from public.zella_function_archive where migration = 'zella_owner_onboarding') then
    return;   -- not applied, or already rolled back
  end if;
  for s in select jsonb_object_keys(mine) loop
    if md5(pg_get_functiondef(s::regprocedure)) <> mine ->> s then
      raise exception 'ROLLBACK_DRIFT: % has changed since this migration', s;
    end if;
  end loop;
  for a in select definition from public.zella_function_archive where migration = 'zella_owner_onboarding' loop
    execute a.definition;
  end loop;

  drop trigger if exists zella_onboarding_document_rejected on public.business_verification_documents;
  drop function if exists public.zella_owner_onboarding_list(), public.zella_owner_onboarding_get(uuid),
    public.zella_owner_onboarding_identity_status(uuid), public.zella_owner_onboarding_payment_status(uuid),
    public.zella_owner_onboarding_complete_step(uuid, text), public.zella_owner_onboarding_section(uuid, text, text, text),
    public.zella_owner_onboarding_plan_accept(uuid, integer), public.zella_owner_onboarding_finish_later(uuid),
    public.zella_owner_onboarding_resume(uuid), public.zella_owner_identity_upload_check(uuid, text),
    public.zella_owner_identity_document_add(uuid, uuid, text, text, text, text, integer),
    public.zella_identity_provider_event(text, text, text, text, timestamptz),
    public.zella_onboarding_document_rejected_trg(), public.zella_admin_onboarding_overview(),
    public.zella_admin_onboarding_progress(uuid), public.zella_admin_onboarding_change_done(uuid, text, text),
    public.zella_onboarding_admin_check(text), public.zella_activation_checks(uuid),
    public.zella_onboarding_state(uuid, boolean), public.zella_onboarding_sections(uuid), public.zella_onboarding_plan(uuid),
    public.zella_onboarding_payment(uuid), public.zella_onboarding_payment_confirmed_at(uuid),
    public.zella_onboarding_identity_passed(uuid), public.zella_onboarding_identity(uuid),
    public.zella_onboarding_section_data(uuid, text), public.zella_onboarding_config(uuid),
    public.zella_onboarding_audit(uuid, uuid, text, jsonb, jsonb), public.zella_onboarding_authorize(uuid, boolean, boolean),
    public.zella_onboarding_ensure(uuid, uuid), public.zella_onboarding_advance(uuid, text, uuid),
    public.zella_onboarding_step_done(uuid, text, text), public.zella_onboarding_rules(),
    public.zella_onboarding_step_keys(), public.zella_onboarding_section_keys();

  -- keep every row before the tables go (DB-4: a rollback never deletes data)
  select (select count(*) from public.owner_onboarding) + (select count(*) from public.owner_onboarding_steps)
       + (select count(*) from public.owner_onboarding_sections) + (select count(*) from public.identity_verification_events) into n;
  if n > 0 then
    create table if not exists public.zella_owner_onboarding_archive (
      table_name text not null, row_data jsonb not null, archived_at timestamptz not null default now());
    alter table public.zella_owner_onboarding_archive enable row level security;
    revoke all on table public.zella_owner_onboarding_archive from public, anon, authenticated;
    grant all on table public.zella_owner_onboarding_archive to service_role;
    insert into public.zella_owner_onboarding_archive (table_name, row_data)
    select 'owner_onboarding', to_jsonb(t) from public.owner_onboarding t
    union all select 'owner_onboarding_steps', to_jsonb(t) from public.owner_onboarding_steps t
    union all select 'owner_onboarding_sections', to_jsonb(t) from public.owner_onboarding_sections t
    union all select 'identity_verification_events', to_jsonb(t) from public.identity_verification_events t;
  end if;
  drop table if exists public.owner_onboarding_sections, public.owner_onboarding_steps, public.identity_verification_events, public.owner_onboarding;

  delete from public.zella_function_archive where migration = 'zella_owner_onboarding';
end $$;
commit;
