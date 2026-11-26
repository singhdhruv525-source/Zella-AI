-- Zella Voice: the business's own email address, part 5: connecting a Gmail or Outlook mailbox (owner, 26 Nov 2026;
-- docs/ARCHITECTURE.md §14.4). The business's owner or admin signs in with Google or Microsoft from Settings, Business
-- email (the business-email edge function, the same pattern as calendar-connect): the provider's own page, never a
-- password given to Zella Voice. Needs sql/zella_business_email.sql and sql/zella_oauth_states.sql.
--   1. oauth_states also holds mailbox sign ins: providers "gmail" and "outlook_mail", kept apart from the calendar's
--      "google" and "outlook", so a calendar sign in can never finish as a mailbox one or the other way round.
--      zella_oauth_state_issue accepts them (one exact edit, archived first; it must be sql/zella_oauth_states.sql's
--      version, 26d8f971...).
-- Who may connect a mailbox is decided by zella_business_email_mailbox_can_connect (sql/zella_business_email.sql): only
-- the business's own owner or admin, never Zella Voice staff.
-- Safe to run twice. Rollback: sql/rollback/zella_business_email_mailbox_rollback.sql
begin;

do $$
begin
  if to_regclass('public.oauth_states') is null or to_regprocedure('public.zella_oauth_state_issue(text,uuid,uuid,text,integer)') is null then
    raise exception 'VERSION_MISMATCH: apply sql/zella_oauth_states.sql first';
  end if;
  if to_regprocedure('public.zella_business_email_mailbox_can_connect(uuid,uuid)') is null or to_regclass('public.zella_function_archive') is null then
    raise exception 'VERSION_MISMATCH: apply sql/zella_business_email.sql and sql/zella_business_email_send.sql first';
  end if;
end $$;

-- 1. mailbox sign ins in oauth_states
alter table public.oauth_states drop constraint if exists oauth_states_provider_check;
alter table public.oauth_states add constraint oauth_states_provider_check check (provider in ('google', 'outlook', 'gmail', 'outlook_mail'));

do $$
declare
  d text; v_new text; n integer;
  sig constant text := 'public.zella_oauth_state_issue(text,uuid,uuid,text,integer)';
  base constant text := '26d8f9711f20f6cef0b889c5848cac16';     -- sql/zella_oauth_states.sql
  mine constant text := '3c293bb1bf7ccf7dcd378e079467d1f0';
  anchor constant text := $a$p_provider not in ('google', 'outlook')$a$;
  edit constant text := $w$p_provider not in ('google', 'outlook', 'gmail', 'outlook_mail')$w$;
begin
  d := pg_get_functiondef(sig::regprocedure);
  if md5(d) = mine then return; end if;   -- already applied
  if md5(d) <> base then raise exception 'VERSION_MISMATCH: % is not a version this file was written for', sig; end if;
  n := (length(d) - length(replace(d, anchor, ''))) / length(anchor);
  if n <> 1 then raise exception 'VERSION_MISMATCH: % anchor found % times', sig, n; end if;
  v_new := replace(d, anchor, edit);
  insert into public.zella_function_archive (migration, signature, definition, definition_md5)
  values ('zella_business_email_mailbox', sig, d, md5(d)) on conflict (migration, signature) do nothing;
  execute v_new;
  if md5(pg_get_functiondef(sig::regprocedure)) <> mine then raise exception 'VERSION_MISMATCH: % did not come out as this file''s version', sig; end if;
end $$;
comment on table public.oauth_states is 'Calendar and mailbox sign ins started by calendar-connect and business-email: single use, short lived, server only';

commit;
