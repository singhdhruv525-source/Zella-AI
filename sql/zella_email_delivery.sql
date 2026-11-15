-- Zella Voice: emails from Zella Voice to businesses are delivered through one path, the platform outbox
-- (sql/zella_platform_emails.sql) and the platform-emails edge function, instead of the n8n Owner Emails workflow.
--
--   1. zella_claim_notification_emails   which notifications go by email, to whom: the same rules as before (daily
--                                        summary, weekly review, every warning or urgent alert; each person's own
--                                        choice per kind; a notification for one person goes to that person, the
--                                        rest to the business's owners and admins). Returns the facts; the edge
--                                        function writes the email from web/supabase/functions/_shared/businessEmails.js
--                                        (email N1) and queues it in the outbox, keyed so it is never queued twice.
--   2. zella_finish_owner_email          (existing) records the result on the notification
--   3. the n8n Owner Emails path is retired: zella_claim_owner_emails returns nothing (its definition is archived in
--      zella_function_archive for the rollback) and the n8n dispatcher stops counting work for it
--   4. zella_dispatch_platform_emails    every minute, calls the edge function only when there is work (notifications
--                                        waiting, or outbox emails due) and only when platform_emails_url is set. The
--                                        call carries a secret made here inside Vault (zella_platform_emails_secret);
--                                        it is never printed or stored anywhere else. The edge function checks it with
--                                        zella_platform_emails_check.
-- Nothing is sent by this file. Sending still needs email_live = true, a sender address (email_from_address) and the
-- provider key on the edge function (RESEND_API_KEY); until then outbox rows are marked test mode (dry_run).
-- Rollback: sql/rollback/zella_email_delivery_rollback.sql
begin;

do $$ begin
  if to_regclass('public.platform_emails') is null or to_regprocedure('public.zella_claim_platform_emails(integer)') is null
     or to_regprocedure('public.zella_claim_owner_emails(integer)') is null or to_regprocedure('public.zella_finish_owner_email(uuid,text,text)') is null
     or to_regprocedure('public.zella_dispatch_n8n()') is null or to_regprocedure('public.zella_patch_function(text,text,text,text)') is null
     or to_regclass('public.zella_function_archive') is null
     -- any vault.create_secret taking (secret, name, description) first; newer Supabase Vault adds an optional key id
     or not exists (select 1 from pg_proc p where p.pronamespace = to_regnamespace('vault') and p.proname = 'create_secret'
                     and p.pronargs - p.pronargdefaults <= 3 and p.pronargs >= 3
                     and (p.proargtypes::oid[])[0:2] = array['text'::regtype, 'text'::regtype, 'text'::regtype]::oid[]) then
    raise exception 'VERSION_MISMATCH: something this file needs is missing (apply zella_platform_emails.sql and zella_model_defaults.sql first)';
  end if;
end $$;

-- the URL of the edge function (empty means "not set up yet", and nothing is called) and the shared secret, made here
-- and kept only in Vault. What this file creates is marked in zella_function_archive, so the rollback removes only that.
do $$ begin
  if not exists (select 1 from public.platform_settings where key = 'platform_emails_url') then
    insert into public.platform_settings (key, value) values ('platform_emails_url', '""'::jsonb);
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_email_delivery', 'created: platform_settings.platform_emails_url', 'created by this migration', md5('created'))
    on conflict (migration, signature) do nothing;
  end if;
  if not exists (select 1 from vault.secrets where name = 'zella_platform_emails_secret') then
    perform vault.create_secret(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), 'zella_platform_emails_secret',
                                'Zella Voice: platform-emails edge function call secret');
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_email_delivery', 'created: vault zella_platform_emails_secret', 'created by this migration', md5('created'))
    on conflict (migration, signature) do nothing;
  end if;
end $$;

create or replace function public.zella_platform_emails_check(p_secret text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v text;
begin
  select decrypted_secret into v from vault.decrypted_secrets where name = 'zella_platform_emails_secret' limit 1;
  return v is not null and length(v) >= 32 and p_secret is not null and p_secret = v;
end $$;

-- 1. which notifications are emailed, and to whom (the rules of zella_claim_owner_emails, kept as they were)
create or replace function public.zella_claim_notification_emails(p_limit integer default 20)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n record; m record; v_res jsonb := '[]'::jsonb; v_pref boolean; v_default boolean; v_found int;
begin
  for n in select s.*, b.name as business_name from public.staff_notifications s join public.businesses b on b.id = s.business_id
            where (s.delivery_status = 'pending' or (s.delivery_status = 'sending' and s.claimed_at < now() - interval '30 minutes'))
              and b.suspended_at is null and b.cancelled_at is null
            order by s.created_at limit greatest(1, least(coalesce(p_limit, 20), 50)) for update of s skip locked loop
    v_default := n.kind in ('daily_summary', 'weekly_review') or n.severity in ('warning', 'urgent');
    v_found := 0;
    for m in select bm.user_id, bm.role, lower(trim(u.email)) as email from public.business_members bm join auth.users u on u.id = bm.user_id
              where bm.business_id = n.business_id and bm.status = 'active'
                and ((n.user_id is not null and bm.user_id = n.user_id) or (n.user_id is null and bm.role in ('owner', 'admin')))
                and coalesce(u.email, '') ~ '^[^@\s,;<>]+@[^@\s,;<>]+\.[^@\s,;<>]+$' loop
      v_pref := null;
      select np.email_enabled into v_pref from public.notification_preferences np
       where np.user_id = m.user_id and np.business_id = n.business_id and np.notification_type = n.kind limit 1;
      if coalesce(v_pref, v_default) then
        v_found := v_found + 1;
        v_res := v_res || jsonb_build_array(jsonb_build_object(
          'notification_id', n.id, 'business_id', n.business_id, 'business_name', n.business_name, 'user_id', m.user_id,
          'role', m.role, 'to', m.email, 'kind', n.kind, 'severity', n.severity, 'page_key', n.page_key,
          'title', left(regexp_replace(n.title, '[\r\n]+', ' ', 'g'), 200), 'body', n.body));
      end if;
    end loop;
    if v_found = 0 then
      update public.staff_notifications set delivery_status = 'skipped', delivery_error = 'not_emailed', claimed_at = now() where id = n.id;
    else
      update public.staff_notifications set delivery_status = 'sending', claimed_at = now() where id = n.id;
    end if;
  end loop;
  return v_res;
end $$;

-- 3. retire the n8n Owner Emails path (only the known original is replaced; it is archived first, for the rollback)
do $$ declare d text; r text; begin
  d := pg_get_functiondef('public.zella_claim_owner_emails(integer)'::regprocedure);
  if position('zella_email_delivery: retired' in d) = 0 then
    if md5(d) <> '96777d5882f740a0b0a31dcd338dc2d2' then
      raise exception 'VERSION_MISMATCH: zella_claim_owner_emails is not the version this file was written against';
    end if;
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_email_delivery', 'public.zella_claim_owner_emails(integer)', d, md5(d)) on conflict (migration, signature) do nothing;
  end if;
  r := public.zella_patch_function('public.zella_dispatch_n8n()', 'owner-emails (retired)',
         'when ''owner-emails'' then (select count(*)', 'when ''owner-emails (retired)'' then (select count(*)');
  if r not in ('patched', 'already') then raise exception 'VERSION_MISMATCH: zella_dispatch_n8n (%)', r; end if;
end $$;
create or replace function public.zella_claim_owner_emails(p_limit integer default 20)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  -- zella_email_delivery: retired. Notification emails go through zella_claim_notification_emails and the platform
  -- outbox (platform-emails edge function); this returns nothing so the old n8n workflow can never send a second copy.
  return '[]'::jsonb;
end $$;

-- 4. an email for one person is sent only while that person is still an active member of the business: at claim time,
--    an email for someone who left (or was suspended) is cancelled (suppressed), so a later reactivation never sends it.
--    Replaces zella_claim_platform_emails (sql/zella_platform_emails.sql; only the known version, archived first).
do $$ declare d text; begin
  d := pg_get_functiondef('public.zella_claim_platform_emails(integer)'::regprocedure);
  if position('zella_email_delivery: members' in d) = 0 then
    if md5(d) <> '295fdbf133c34d5baf37b84d225cf316' then
      raise exception 'VERSION_MISMATCH: zella_claim_platform_emails is not the version this file was written against';
    end if;
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_email_delivery', 'public.zella_claim_platform_emails(integer)', d, md5(d)) on conflict (migration, signature) do nothing;
  end if;
end $$;
create or replace function public.zella_claim_platform_emails(p_limit integer default 20)
returns setof public.platform_emails language plpgsql security definer set search_path = public as $$
declare v_live boolean := coalesce((select value::text = 'true' from public.platform_settings where key = 'email_live'), false);
        r record;
begin
  -- zella_email_delivery: members. An email for one person who is no longer an active member is cancelled.
  update public.platform_emails e set status = 'suppressed', last_error = 'no longer an active member of the business'
   where e.status in ('queued', 'sending') and e.user_id is not null
     and not exists (select 1 from public.business_members bm where bm.business_id = e.business_id and bm.user_id = e.user_id and bm.status = 'active');
  -- held: a send that kept failing or never answered; a person decides
  for r in update public.platform_emails set status = 'held', last_error = coalesce(last_error, 'no answer from the provider')
            where status in ('queued', 'sending') and attempts >= 5 and next_attempt_at <= now()
            returning id, business_id, code, dedupe_key loop
    perform public.zella_platform_alert('platform_email_held', 'An email to a business is held', 'Email ' || r.code || ' was tried 5 times. Check it before sending it again.',
                                        'warning', r.business_id, 'platform_email_held:' || r.dedupe_key, jsonb_build_object('email_id', r.id));
  end loop;
  if not v_live then
    update public.platform_emails set status = 'dry_run' where status = 'queued' and next_attempt_at <= now();
    return;
  end if;
  return query
    update public.platform_emails e set status = 'sending', attempts = e.attempts + 1, claimed_at = now(), claim_token = gen_random_uuid(),
           next_attempt_at = now() + interval '10 minutes'   -- not answered in 10 minutes: claimed again with the same key
     where e.id in (select id from public.platform_emails
                     where status in ('queued', 'sending') and next_attempt_at <= now() and attempts < 5
                     order by next_attempt_at limit least(greatest(coalesce(p_limit, 20), 1), 100)
                     for update skip locked)
    returning e.*;
end $$;
revoke all on function public.zella_claim_platform_emails(integer) from public, anon, authenticated;
grant execute on function public.zella_claim_platform_emails(integer) to service_role;

-- 5. wake the edge function only when there is work
create or replace function public.zella_dispatch_platform_emails() returns text
language plpgsql security definer set search_path = public as $$
declare v_url text := nullif(trim(public.zella_setting('platform_emails_url', '""'::jsonb) #>> '{}'), ''); v_secret text; n integer;
begin
  if v_url is null or v_url !~ '^https://' then return 'not_set_up'; end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'zella_platform_emails_secret' limit 1;
  if v_secret is null then return 'no_secret'; end if;
  select (select count(*) from public.staff_notifications s join public.businesses b on b.id = s.business_id
           where b.suspended_at is null and b.cancelled_at is null
             and (s.delivery_status = 'pending' or (s.delivery_status = 'sending' and s.claimed_at < now() - interval '30 minutes')))
       + (select count(*) from public.platform_emails where status in ('queued', 'sending') and next_attempt_at <= now())
    into n;
  if n = 0 then return 'nothing_due'; end if;
  perform net.http_post(url := v_url, headers := jsonb_build_object('Content-Type', 'application/json', 'X-Zella-Secret', v_secret),
                        body := '{}'::jsonb, timeout_milliseconds := 25000);
  return 'called';
end $$;

revoke all on function public.zella_platform_emails_check(text) from public, anon, authenticated;
revoke all on function public.zella_claim_notification_emails(integer) from public, anon, authenticated;
revoke all on function public.zella_dispatch_platform_emails() from public, anon, authenticated;
grant execute on function public.zella_platform_emails_check(text) to service_role;
grant execute on function public.zella_claim_notification_emails(integer) to service_role;

-- 6. event based first (like the n8n dispatcher, sql/zella_dispatcher.sql section 5): a new notification or a new email
-- in the outbox wakes the edge function at once. Once per statement, so a batch of inserts makes one call, and never
-- able to fail the insert that fired it. Created switched OFF: turning the triggers on is a live switch for the owner
--   alter table public.platform_emails enable trigger zella_kick_platform_emails;
--   alter table public.staff_notifications enable trigger zella_kick_platform_emails;
-- and even then nothing is called until platform_emails_url is set.
create or replace function public.zella_kick_platform_emails() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  begin
    perform public.zella_dispatch_platform_emails();
  exception when others then
    raise warning 'zella_kick_platform_emails: %', sqlerrm;   -- the next kick or the safety net picks the email up
  end;
  return null;
end $$;
revoke all on function public.zella_kick_platform_emails() from public, anon, authenticated;
do $$ declare t text; begin
  foreach t in array array['platform_emails', 'staff_notifications'] loop
    if not exists (select 1 from pg_trigger where tgname = 'zella_kick_platform_emails' and tgrelid = format('public.%I', t)::regclass) then
      execute format('create trigger zella_kick_platform_emails after insert on public.%I for each statement execute function public.zella_kick_platform_emails()', t);
      execute format('alter table public.%I disable trigger zella_kick_platform_emails', t);
    end if;
  end loop;
end $$;

-- 7. the safety net: every minute (pg_cron) for retries and anything a kick missed, created switched OFF like the other
-- timed jobs: turning it on is a live switch for the owner
-- (update cron.job set active = true where jobname = 'zella_platform_emails'); even then it does nothing until platform_emails_url is set
-- Supabase does not allow editing cron.job directly, so the job is switched off with cron.alter_job; the direct
-- update is only for a database whose pg_cron has no alter_job (older versions).
do $$ declare v_id bigint; begin
  if to_regnamespace('cron') is not null and not exists (select 1 from cron.job where jobname = 'zella_platform_emails') then
    v_id := cron.schedule('zella_platform_emails', '* * * * *', 'select public.zella_dispatch_platform_emails()');
    if to_regprocedure('cron.alter_job(bigint,text,text,text,text,boolean)') is not null then
      perform cron.alter_job(job_id := v_id, active := false);
    else
      update cron.job set active = false where jobid = v_id;
    end if;
  end if;
end $$;

commit;
