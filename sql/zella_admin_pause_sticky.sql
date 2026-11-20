-- Zella Voice: a pause Zella Voice staff put on a business's automations can only be lifted by Zella Voice staff
-- (security audit 18 Nov 2026, 3.2, M7). zella_request_activation (owners, admins and managers of the business) sets
-- every paused automation back to active, and zella_admin_business_automations_pause used the same plain 'paused',
-- so a business manager could undo a pause staff put on after abuse.
-- Now:
--   * automations.paused_by_admin marks a pause by Zella Voice staff (both admin functions set it: the business wide
--     pause marks the business's active and paused automations; pausing or archiving one automation marks it;
--     resuming it as an admin clears it);
--   * a trigger keeps an automation with the mark from becoming active, whoever updates it (zella_request_activation,
--     either version, the lifecycle trigger when a suspension ends, any owner tool), and only the two admin
--     functions can set or clear the mark (they switch a setting on for their own statement only). The status simply
--     stays as it was, so a go live still goes ahead for everything else.
--   * "Resume all" (zella_admin_business_automations_resume, sql/zella_automations_resume_all.sql) is a staff action
--     too: it clears the mark on what it resumes. The guard keeps the "Pause all" mark (bulk_paused_at) when it keeps an
--     automation off, so a refused attempt doesn't stop "Resume all" from finding it later.
-- zella_request_activation is not changed, so this file works with production's version and with
-- sql/zella_owner_onboarding.sql's, in either order. Needs sql/zella_automations_resume_all.sql applied first.
-- The three admin functions are archived first and must be the versions on main (production's set_status, and the
-- pause and resume of sql/zella_automations_resume_all.sql), otherwise VERSION_MISMATCH.
-- Rollback: sql/rollback/zella_admin_pause_sticky_rollback.sql
begin;

do $$
declare
  s text; d text;
  known constant jsonb := jsonb_build_object(
    'public.zella_admin_business_automations_pause(uuid,text)', jsonb_build_array('ff8907607f62387511208ac1ae03ce70', '80fc3ae370fda10aab743a23aef4624d'),
    'public.zella_admin_automation_set_status(uuid,text,text)',  jsonb_build_array('9c9b73eaee0135de5b9599723b698e4b', 'e9790abcd9bd30a51ef180caa0444739'),
    'public.zella_admin_business_automations_resume(uuid,text)', jsonb_build_array('42531e1b1249ea39adae2374a45671cf', 'f54e8b67f946cd489599224baa3364b9'));
begin
  if to_regclass('public.zella_function_archive') is null or to_regclass('public.automations') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  for s in select jsonb_object_keys(known) loop
    if to_regprocedure(s) is null then raise exception 'VERSION_MISMATCH: % is missing', s; end if;
    d := pg_get_functiondef(s::regprocedure);
    if md5(d) = known -> s ->> 0 then          -- production's version: archive it for the rollback
      insert into public.zella_function_archive (migration, signature, definition, definition_md5)
      values ('zella_admin_pause_sticky', s, d, md5(d)) on conflict (migration, signature) do nothing;
    elsif md5(d) <> known -> s ->> 1 then      -- nor this file's version (already applied)
      raise exception 'VERSION_MISMATCH: % is not a version this file was written for', s;
    end if;
  end loop;
end $$;

alter table public.automations add column if not exists paused_by_admin boolean not null default false;
comment on column public.automations.paused_by_admin is
  'Paused or archived by Zella Voice staff: stays off until staff resume it (zella_admin_automation_set_status)';

create or replace function public.zella_automations_admin_pause_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  -- only the admin functions may set or clear the mark
  if new.paused_by_admin is distinct from old.paused_by_admin
     and coalesce(current_setting('zella.admin_automation', true), '') <> 'on' then
    new.paused_by_admin := old.paused_by_admin;
  end if;
  -- while marked, nothing turns the automation back on
  if new.paused_by_admin and new.status = 'active' then
    new.status := old.status;
    -- keep the "Pause all" mark too (zella_automation_bulk_mark clears it on any status change it saw)
    if to_jsonb(old) ? 'bulk_paused_at' then
      new := jsonb_populate_record(new, jsonb_build_object('bulk_paused_at', to_jsonb(old) -> 'bulk_paused_at'));
    end if;
  end if;
  return new;
end $$;
revoke all on function public.zella_automations_admin_pause_guard() from public, anon, authenticated;

drop trigger if exists zella_automations_admin_pause_guard_trg on public.automations;
create trigger zella_automations_admin_pause_guard_trg before update on public.automations
  for each row execute function public.zella_automations_admin_pause_guard();

CREATE OR REPLACE FUNCTION public.zella_admin_business_automations_pause(p_business_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_reason text := public.zella_admin_reason(p_reason); v_ids uuid[];
begin
  perform public.zella_admin_require('integrations.manage');
  perform set_config('zella.admin_automation', 'on', true);
  -- bulk_paused_at marks what this pause changed, so "Resume all" can resume exactly these and nothing else
  with u as (update public.automations set status = 'paused', bulk_paused_at = now(), paused_by_admin = true, updated_at = now() where business_id = p_business_id and status = 'active' returning id)
  select array_agg(id order by id) into v_ids from u;
  -- automations already paused stay off too, until staff resume them
  update public.automations set paused_by_admin = true where business_id = p_business_id and status = 'paused' and not paused_by_admin;
  perform set_config('zella.admin_automation', '', true);
  perform public.zella_admin_audit('automation.business_paused', 'business', p_business_id, p_business_id, null,
    jsonb_build_object('paused', coalesce(cardinality(v_ids), 0), 'reason', v_reason, 'ids', to_jsonb(coalesce(v_ids, '{}'::uuid[]))));
  return jsonb_build_object('paused', coalesce(cardinality(v_ids), 0));
end $function$;

CREATE OR REPLACE FUNCTION public.zella_admin_automation_set_status(p_id uuid, p_status text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a public.automations; v_reason text := public.zella_admin_reason(p_reason); b public.businesses;
begin
  perform public.zella_admin_require('integrations.manage');
  if p_status not in ('active', 'paused', 'disabled') then raise exception 'INVALID_STATUS'; end if;
  select * into a from public.automations where id = p_id for update;
  if a.id is null then raise exception 'NOT_FOUND'; end if;
  if a.status = p_status then raise exception 'NO_CHANGE'; end if;
  select * into b from public.businesses where id = a.business_id;
  if p_status = 'active' and (b.suspended_at is not null or b.cancelled_at is not null) then raise exception 'BUSINESS_NOT_AVAILABLE'; end if;
  if p_status = 'active' and not coalesce(b.is_active, false) then raise exception 'BUSINESS_NOT_LIVE'; end if;
  perform set_config('zella.admin_automation', 'on', true);
  update public.automations set status = p_status, paused_by_suspension = false, paused_by_admin = (p_status <> 'active'), updated_at = now() where id = a.id;
  perform set_config('zella.admin_automation', '', true);
  perform public.zella_admin_audit('automation.' || case p_status when 'active' then 'resumed' when 'paused' then 'paused' else 'archived' end,
    'automation', a.id, a.business_id, jsonb_build_object('status', a.status), jsonb_build_object('status', p_status, 'reason', v_reason));
  return jsonb_build_object('id', a.id, 'status', p_status);
end $function$;

-- "Resume all" is staff resuming: it clears the mark on what it resumes (changed in place, archived above)
do $$
declare s constant text := 'public.zella_admin_business_automations_resume(uuid,text)'; d text;
  a constant text := $a$  with u as (update public.automations set status = 'active', bulk_paused_at = null, updated_at = now()$a$;
  w constant text := $w$  perform set_config('zella.admin_automation', 'on', true);   -- zella_admin_pause_sticky
  with u as (update public.automations set status = 'active', bulk_paused_at = null, paused_by_admin = false, updated_at = now()$w$;
begin
  d := pg_get_functiondef(s::regprocedure);
  if position('zella_admin_pause_sticky' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'VERSION_MISMATCH: % anchor', s; end if;
  execute replace(d, a, w);
end $$;

commit;
