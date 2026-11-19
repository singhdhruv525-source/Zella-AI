-- Zella Voice: the go live checklist reads whether the two platform email triggers are on
-- (docs/ADMIN_AUDIT_2026-11-16.md UI-23). sql/zella_email_delivery.sql created zella_kick_platform_emails on
-- platform_emails and staff_notifications switched off; turning them on is the owner's live switch, and nothing showed
-- their state. zella_admin_email_triggers(): businesses.view, read only, returns true (on for ordinary inserts), false (off, or replica
-- only) or null (not created) per table. It never enables or disables anything. A new function only; a different function of the same
-- name stops the file (VERSION_MISMATCH).
-- Rollback: sql/rollback/zella_go_live_reads_rollback.sql
begin;

do $$ begin
  if to_regprocedure('public.zella_admin_require(text)') is null then raise exception 'VERSION_MISMATCH: zella_admin_require is missing'; end if;
  if to_regprocedure('public.zella_admin_email_triggers()') is not null then
    if md5(pg_get_functiondef(to_regprocedure('public.zella_admin_email_triggers()'))) <> '6c0046b47d6440d8f2a52b08dd088bec' then
      raise exception 'VERSION_MISMATCH: a different zella_admin_email_triggers already exists';
    end if;
  end if;
end $$;

create or replace function public.zella_admin_email_triggers()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.zella_admin_require('businesses.view');
  -- on only when it fires for ordinary inserts: O (origin) or A (always); R (replica only) and D (disabled) are off
  return (select jsonb_object_agg(t, (select g.tgenabled in ('O', 'A') from pg_trigger g
                                       where g.tgname = 'zella_kick_platform_emails' and g.tgrelid = to_regclass('public.' || t)))
            from unnest(array['platform_emails', 'staff_notifications']) t);
end $$;
revoke all on function public.zella_admin_email_triggers() from public, anon;
grant execute on function public.zella_admin_email_triggers() to authenticated, service_role;

commit;
