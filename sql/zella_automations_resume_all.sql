-- Zella Voice: "Resume all" for a business resumes exactly what "Pause all" paused (docs/ADMIN_AUDIT_2026-11-16.md
-- OPS-20). zella_admin_business_automations_pause set every active automation to paused and audited only a count,
-- so nothing recorded which ones it paused, and there was no way back but one at a time.
--   1. automations.bulk_paused_at: set by "Pause all" on the automations it paused. Any other change of status (the
--      business pausing or resuming one, a suspension, an admin's single change) clears it, through a trigger, so
--      "Resume all" never touches an automation someone has changed since.
--   2. zella_admin_business_automations_pause: the same checks and result, and it now marks what it paused and lists
--      their ids in the audit row. Archived first; must match production's version (16 Nov 2026).
--   3. zella_admin_business_automations_resume(business, reason): integrations.manage and a reason, refused for a
--      suspended or cancelled business (BUSINESS_NOT_AVAILABLE); resumes only automations still marked by a bulk pause
--      and not paused by a suspension; audited as automation.business_resumed with the ids.
-- Rollback: sql/rollback/zella_automations_resume_all_rollback.sql
begin;

do $$
declare s constant text := 'public.zella_admin_business_automations_pause(uuid,text)'; d text;
begin
  if to_regprocedure(s) is null or to_regclass('public.zella_function_archive') is null or to_regclass('public.automations') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  d := pg_get_functiondef(s::regprocedure);
  if md5(d) = '89d2fc68649486ca8d2cb1d2801728ae' then          -- production's version: archive it for the rollback
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_automations_resume_all', s, d, md5(d)) on conflict (migration, signature) do nothing;
  elsif md5(d) <> 'ff8907607f62387511208ac1ae03ce70' then                               -- nor exactly this file's version (already applied)
    raise exception 'VERSION_MISMATCH: % is not a version this file was written for', s;
  end if;
end $$;

alter table public.automations add column if not exists bulk_paused_at timestamptz;

-- any change of status that isn't the bulk pause itself clears the mark
create or replace function public.zella_automation_bulk_mark_trg() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.status is distinct from old.status and new.bulk_paused_at is not distinct from old.bulk_paused_at then
    new.bulk_paused_at := null;
  end if;
  return new;
end $$;
revoke all on function public.zella_automation_bulk_mark_trg() from public, anon, authenticated;
drop trigger if exists zella_automation_bulk_mark on public.automations;
create trigger zella_automation_bulk_mark before update of status on public.automations
  for each row execute function public.zella_automation_bulk_mark_trg();

CREATE OR REPLACE FUNCTION public.zella_admin_business_automations_pause(p_business_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_reason text := public.zella_admin_reason(p_reason); v_ids uuid[];
begin
  perform public.zella_admin_require('integrations.manage');
  -- bulk_paused_at marks what this pause changed, so "Resume all" can resume exactly these and nothing else
  with u as (update public.automations set status = 'paused', bulk_paused_at = now(), updated_at = now() where business_id = p_business_id and status = 'active' returning id)
  select array_agg(id order by id) into v_ids from u;
  perform public.zella_admin_audit('automation.business_paused', 'business', p_business_id, p_business_id, null,
    jsonb_build_object('paused', coalesce(cardinality(v_ids), 0), 'reason', v_reason, 'ids', to_jsonb(coalesce(v_ids, '{}'::uuid[]))));
  return jsonb_build_object('paused', coalesce(cardinality(v_ids), 0));
end $function$;

create or replace function public.zella_admin_business_automations_resume(p_business_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_reason text := public.zella_admin_reason(p_reason); v_ids uuid[]; b record;
begin
  perform public.zella_admin_require('integrations.manage');
  -- locked like a suspension locks it, so a suspension in flight finishes first and its suspended_at is read here
  select id, suspended_at, cancelled_at into b from public.businesses where id = p_business_id for update;
  if b.id is null then raise exception 'NOT_FOUND'; end if;
  if b.suspended_at is not null or b.cancelled_at is not null then raise exception 'BUSINESS_NOT_AVAILABLE'; end if;
  with u as (update public.automations set status = 'active', bulk_paused_at = null, updated_at = now()
              where business_id = p_business_id and status = 'paused' and bulk_paused_at is not null and not paused_by_suspension
              returning id)
  select array_agg(id order by id) into v_ids from u;
  perform public.zella_admin_audit('automation.business_resumed', 'business', p_business_id, p_business_id, null,
    jsonb_build_object('resumed', coalesce(cardinality(v_ids), 0), 'reason', v_reason, 'ids', to_jsonb(coalesce(v_ids, '{}'::uuid[]))));
  return jsonb_build_object('resumed', coalesce(cardinality(v_ids), 0));
end $$;
revoke all on function public.zella_admin_business_automations_resume(uuid, text) from public, anon;
grant execute on function public.zella_admin_business_automations_resume(uuid, text) to authenticated, service_role;

commit;
