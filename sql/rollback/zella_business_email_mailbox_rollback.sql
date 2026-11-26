-- Undoes sql/zella_business_email_mailbox.sql exactly: zella_oauth_state_issue gets back sql/zella_oauth_states.sql's
-- version (26d8f971...) and oauth_states its calendar only providers. Mailbox sign ins still in progress can't be
-- finished: their rows (a hash, a person, a business, five minutes; no customer data) are deleted first, so the old
-- rule fits. Mailboxes already connected stay connected (sql/zella_business_email.sql's rollback handles those).
-- Refuses (ROLLBACK_DRIFT) when the function is not this file's version. Safe to run twice.
begin;
do $$
declare
  d text; v_new text;
  sig constant text := 'public.zella_oauth_state_issue(text,uuid,uuid,text,integer)';
  base constant text := '26d8f9711f20f6cef0b889c5848cac16';
  mine constant text := '3c293bb1bf7ccf7dcd378e079467d1f0';
begin
  if to_regclass('public.zella_function_archive') is null
     or not exists (select 1 from public.zella_function_archive where migration = 'zella_business_email_mailbox') then
    return;   -- not applied, or already rolled back
  end if;
  d := pg_get_functiondef(sig::regprocedure);
  if md5(d) <> mine then raise exception 'ROLLBACK_DRIFT: % has changed since this migration', sig; end if;
  v_new := replace(d, $w$p_provider not in ('google', 'outlook', 'gmail', 'outlook_mail')$w$, $a$p_provider not in ('google', 'outlook')$a$);
  if md5(v_new) <> base then raise exception 'ROLLBACK_DRIFT: % would not come back as the version it was', sig; end if;
  delete from public.oauth_states where provider in ('gmail', 'outlook_mail');
  alter table public.oauth_states drop constraint if exists oauth_states_provider_check;
  alter table public.oauth_states add constraint oauth_states_provider_check check (provider in ('google', 'outlook'));
  execute v_new;
  if md5(pg_get_functiondef(sig::regprocedure)) <> base then raise exception 'ROLLBACK_DRIFT: % did not come back as the version it was', sig; end if;
  comment on table public.oauth_states is 'Calendar sign ins started by calendar-connect: single use, short lived, server only';
  delete from public.zella_function_archive where migration = 'zella_business_email_mailbox';
end $$;
commit;
