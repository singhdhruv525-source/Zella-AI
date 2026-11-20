-- Zella Voice: privacy policy and terms (drafts), 90 day automatic deletion of call recordings and transcripts, and
-- deletion at Vapi (security audit 18 Nov 2026, 12.2 and 12.3, H3 and part of H5; owner decisions 18 Nov 2026).
--   1. Drafts of the Zella Voice Privacy Policy and Terms of Service in legal_documents, status draft, marked "Draft
--      for owner and legal review" (nothing is published). zella_legal_current(kind) gives anyone the published version,
--      or the latest draft marked as a draft, for the /privacy and /terms pages. zella_owner_onboarding_legal_accept
--      records the owner's acceptance of the current versions, server side and audited (the onboarding step).
--   2. Retention, owner decision: call recordings and call transcripts are kept 90 days and deleted automatically
--      (all that is due, in batches, under lane G's legal hold lock).
--      data_retention_policies (sql/zella_data_retention.sql) now says 90 days for both; their legal status is not
--      changed. zella_retention_auto_run (server only) removes what is past 90 days, in batches of 1000, skipping
--      businesses on a legal hold, and runs in the daily job group; it does nothing while retention_purge_enabled (lane
--      G's owner only switch) is off or while the period is still pending legal review. Both are off today.
--   3. provider_deletions: a queue of calls to delete at Vapi (recording, transcript and the call itself). Filled by the
--      automatic deletion, by zella_erase_customer (changed in place, production's version only) and by the account
--      deletion purge (sql/zella_account_deletion.sql). The provider-deletions edge function sends them only while the
--      platform setting vapi_deletion_live is true (added here as false).
-- Needs sql/zella_data_retention.sql. zella_erase_customer, zella_run_schedule_group and zella_run_scheduled_job are
-- archived first and must be versions this file knows, otherwise VERSION_MISMATCH.
-- Rollback: sql/rollback/zella_privacy_retention_rollback.sql
begin;

do $$
begin
  if to_regclass('public.zella_function_archive') is null or to_regclass('public.data_retention_policies') is null
     or to_regprocedure('public.zella_retention_candidates(text,timestamptz)') is null or to_regclass('public.legal_documents') is null
     or to_regprocedure('public.zella_onboarding_authorize(uuid,boolean,boolean)') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing (lane G retention and owner onboarding first)';
  end if;
end $$;

-- 3. the Vapi deletion queue (server only)
create table if not exists public.provider_deletions (
  id uuid primary key default gen_random_uuid(),
  provider text not null check (provider in ('vapi')),
  object_kind text not null check (object_kind in ('call')),
  external_id text not null check (length(external_id) between 1 and 200),
  business_id uuid references public.businesses (id) on delete set null,
  reason text not null check (reason in ('retention', 'customer_erasure', 'business_deletion')),
  status text not null default 'queued' check (status in ('queued', 'sending', 'done', 'failed', 'not_found')),
  attempts integer not null default 0,
  last_error text,
  next_attempt_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  done_at timestamptz,
  unique (provider, object_kind, external_id)
);
comment on table public.provider_deletions is 'Calls to delete at Vapi (recording, transcript, call), sent by provider-deletions only while vapi_deletion_live is on';
create index if not exists provider_deletions_due_idx on public.provider_deletions (next_attempt_at) where status in ('queued', 'failed');
alter table public.provider_deletions enable row level security;
revoke all on public.provider_deletions from public, anon, authenticated;
grant all on public.provider_deletions to service_role;
insert into public.platform_settings (key, value) values ('vapi_deletion_live', 'false'::jsonb) on conflict (key) do nothing;

create or replace function public.zella_queue_provider_deletion(p_business_id uuid, p_external_call_id text, p_reason text)
returns boolean language sql security definer set search_path = '' as $$
  insert into public.provider_deletions (provider, object_kind, external_id, business_id, reason)
  select 'vapi', 'call', left(p_external_call_id, 200), p_business_id, p_reason where nullif(trim(coalesce(p_external_call_id, '')), '') is not null
  on conflict (provider, object_kind, external_id) do nothing
  returning true
$$;

-- the worker's two calls (server key): claim due rows, and record each result
create or replace function public.zella_provider_deletions_claim(p_limit integer default 20)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb;
begin
  if not coalesce(public.zella_setting('vapi_deletion_live', 'false'::jsonb) = 'true'::jsonb, false) then return '[]'::jsonb; end if;
  with c as (
    select id from public.provider_deletions
     where ((status in ('queued', 'failed') and next_attempt_at <= now() and attempts < 10)
        or (status = 'sending' and next_attempt_at <= now() - interval '10 minutes'))
       -- never for a business on a legal hold: those wait until the hold is released
       and (business_id is null or not public.zella_retention_on_hold(business_id))
     order by next_attempt_at limit greatest(1, least(coalesce(p_limit, 20), 100)) for update skip locked),
  u as (
    update public.provider_deletions d set status = 'sending', attempts = attempts + 1, next_attempt_at = now()
      from c where d.id = c.id returning d.id, d.provider, d.object_kind, d.external_id)
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'provider', provider, 'kind', object_kind, 'external_id', external_id)), '[]'::jsonb) into v from u;
  return v;
end $$;

create or replace function public.zella_provider_deletion_result(p_id uuid, p_outcome text, p_error text default null)
returns text language plpgsql security definer set search_path = '' as $$
begin
  if p_outcome not in ('done', 'failed', 'not_found') then raise exception 'BAD_OUTCOME'; end if;
  update public.provider_deletions set status = p_outcome, last_error = left(p_error, 300),
         done_at = case when p_outcome in ('done', 'not_found') then now() end,
         next_attempt_at = case when p_outcome = 'failed' then now() + least(interval '1 day', interval '5 minutes' * power(2, least(attempts, 8))) else next_attempt_at end
   where id = p_id and status = 'sending';
  if not found then return 'not_sending'; end if;
  if p_outcome = 'failed' and (select attempts from public.provider_deletions where id = p_id) >= 10 then
    perform public.zella_platform_alert('provider_deletion_failed', 'A call could not be deleted at Vapi', left(p_error, 300), 'warning', null, p_id::text);
  end if;
  return p_outcome;
end $$;

-- 2. 90 days for recordings and transcripts (owner, 18 Nov 2026); legal status unchanged
-- what the periods were before (once, never overwritten), so the rollback puts back exactly those
create table if not exists public.zella_migration_values (migration text not null, key text not null, value jsonb, primary key (migration, key));
alter table public.zella_migration_values enable row level security;
revoke all on public.zella_migration_values from public, anon, authenticated;
insert into public.zella_migration_values (migration, key, value)
select 'zella_privacy_retention', k || data_class, case k when 'days:' then to_jsonb(days) else to_jsonb(note) end
  from public.data_retention_policies, unnest(array['days:', 'note:']) k
 where data_class in ('call_recordings', 'call_transcripts') and coalesce(note, '') not like 'Owner decision 18 Nov 2026%'
on conflict do nothing;
update public.data_retention_policies set days = 90, updated_at = now(),
       note = 'Owner decision 18 Nov 2026: 90 days, deleted automatically (zella_retention_auto_run). ' || coalesce(note, '')
 where data_class in ('call_recordings', 'call_transcripts') and (days <> 90 or coalesce(note, '') not like 'Owner decision 18 Nov 2026%');

create or replace function public.zella_retention_auto_run()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare k text; p public.data_retention_policies; v_ids uuid[]; v_out jsonb := '{}'::jsonb; v_n integer; v_total integer; v_batch integer;
        pr public.data_retention_policies; pt public.data_retention_policies; v_q integer := 0;
begin
  if not coalesce((select value = 'true'::jsonb from public.platform_settings where key = 'retention_purge_enabled'), false) then
    return jsonb_build_object('skipped', 'switched_off');
  end if;
  -- the same lock as lane G's purges and zella_legal_hold_place: a hold never lands between the selection and the removal
  perform pg_advisory_xact_lock(hashtextextended('zella_legal_holds', 0));
  foreach k in array array['call_recordings', 'call_transcripts'] loop
    select * into p from public.data_retention_policies where data_class = k;
    if p.data_class is null or p.legal_status <> 'approved' then v_out := v_out || jsonb_build_object(k, 'legal_review_pending'); continue; end if;
    v_total := 0;
    -- batches of 1000 until nothing is due, at most 50 a run (50 000 calls), so a backlog clears within the run
    for v_batch in 1..50 loop
      select coalesce(array_agg(c.row_id), '{}') into v_ids from (
        select row_id from public.zella_retention_candidates(k, now() - make_interval(days => p.days)) where source = 'calls' order by dated limit 1000) c;
      exit when cardinality(v_ids) = 0;
      if k = 'call_recordings' then
        update public.calls set recording_url = null where id = any (v_ids);
      else
        update public.calls set transcript = 'Removed under the retention policy.' where id = any (v_ids);
      end if;
      get diagnostics v_n = row_count;
      v_total := v_total + v_n;
    end loop;
    v_out := v_out || jsonb_build_object(k, v_total);
    if v_total > 0 then
      insert into public.audit_logs (business_id, user_id, action, entity_type, new_data)
      values (null, null, 'retention.auto_purge', 'data_retention_policy', jsonb_build_object('data_class', k, 'days', p.days, 'removed', v_total));
    end if;
  end loop;
  -- the copy at Vapi holds the recording and the transcript together, so the whole call is queued for deletion only when
  -- both kinds are approved and the call is past both periods with neither left here (whoever removed them: this job
  -- or a manual purge run); a business on a legal hold is left out
  select * into pr from public.data_retention_policies where data_class = 'call_recordings';
  select * into pt from public.data_retention_policies where data_class = 'call_transcripts';
  if pr.legal_status = 'approved' and pt.legal_status = 'approved' then
    with q as (
      select public.zella_queue_provider_deletion(c.business_id, c.external_call_id, 'retention') as queued from public.calls c
       where c.external_call_id is not null and c.recording_url is null
         and (c.transcript is null or c.transcript = 'Removed under the retention policy.')
         and coalesce(c.ended_at, c.created_at) < now() - make_interval(days => greatest(pr.days, pt.days))
         and not public.zella_retention_on_hold(c.business_id)
         and not exists (select 1 from public.provider_deletions d where d.provider = 'vapi' and d.object_kind = 'call' and d.external_id = c.external_call_id)
       limit 50000)
    select count(*) filter (where queued) into v_q from q;
    v_out := v_out || jsonb_build_object('vapi_queued', v_q);
  end if;
  return v_out;
end $$;

-- 1. the drafts
insert into public.legal_documents (kind, version, title, body, status, requires_acceptance) values
  ('privacy', '0.1', 'Zella Voice Privacy Policy (Draft for owner and legal review)', $doc$DRAFT FOR OWNER AND LEGAL REVIEW. This text is not yet in effect.

Zella Voice Privacy Policy

1. Who we are
Zella Voice provides an AI receptionist and customer tools to businesses. A business that uses Zella Voice (our customer) decides how it uses them. For the calls, messages and records of a business's own customers, that business is responsible and Zella Voice processes the information on its behalf. For the people who sign in to Zella Voice to run a business, Zella Voice is responsible.

2. What we collect
a. Account information: name, email address, phone number, role, sign in and two step sign in records.
b. Business information: business name, address, opening hours, services, staff, phone numbers and settings.
c. Calls: the calling and called numbers, time and length of the call, what the AI receptionist did, a written summary, the transcript, and a recording only when the business has turned recording on. Callers are told at the start of every call that they are speaking with an AI receptionist, and that the call is recorded when it is.
d. Messages: texts and emails sent or received for the business, and appointment details.
e. Customer records the business keeps: names, contact details, appointments, notes and requests.
f. Identity checks for business owners, when the owner completes them.
g. Payment records for the business's plan. Card details are handled by our payment provider and never reach Zella Voice.
h. Technical records: the address and browser of people who sign in, and security logs.

3. Why we use it
To answer and route calls, book and change appointments, send the messages a business has set up, keep the business's records, verify business owners, bill for the service, keep the service secure, prevent abuse, and meet legal duties. We do not sell personal information and we do not use it for advertising.

4. Who processes it for us
a. Supabase: our database, sign in and file storage.
b. Vapi: runs the phone calls, the voice and the transcript.
c. Anthropic: the AI model that writes the receptionist's answers and summaries.
d. Telnyx: phone numbers and texts.
e. Resend: sending emails.
f. Stripe: payments.
g. n8n: runs our scheduled and automatic tasks.
h. Persona: identity checks for business owners.
Each one receives only what it needs to do its part and is bound by a written agreement.

5. How long we keep it
a. Call recordings and transcripts: 90 days after the call, then deleted automatically.
b. Text and email contents: 2 years, then the words are removed and only the record that a message was sent stays.
c. Audit and security logs: 7 years.
d. Owner identity files: 90 days after the check. The result of the check is kept.
e. When a business cancels, its records are kept for 90 days and then removed.
f. When a business owner asks to delete the account and Zella Voice confirms the request, the account is frozen at once and everything is deleted 30 days later unless the request is cancelled. Audit history is kept without the business's details.
g. When a business erases one of its customers, that customer's details, messages and calls are removed, and a request to delete the call at our phone provider is sent.

6. Your choices and rights
You can ask to see, correct, export or delete your information. Customers of a business can ask that business, which handles the request in Zella Voice within 30 days. You can stop marketing messages at any time with the link or by replying STOP.

7. Security
Information is encrypted in transit and at rest. Every Zella Voice staff member uses two step sign in. Access is limited to people who need it, and every access by our staff is logged.

8. Contact
privacy@zellavoice.com (owner to confirm the address and the company's legal name and postal address).

9. Changes
We will post any change here and tell business owners before it takes effect.$doc$, 'draft', true),
  ('terms', '0.1', 'Zella Voice Terms of Service (Draft for owner and legal review)', $doc$DRAFT FOR OWNER AND LEGAL REVIEW. This text is not yet in effect.

Zella Voice Terms of Service

1. The service
Zella Voice gives a business an AI receptionist that answers its calls, books appointments, takes messages and sends messages the business sets up, together with tools to keep its customer records.

2. Your account
You must give accurate details, keep your sign in safe, use two step sign in where asked, and make sure everyone you invite follows these terms. You are responsible for what is done in your account.

3. Your responsibilities to your callers and customers
a. You must have the right to contact the people you message or call, and you must honour requests to stop.
b. Callers are told at the start of each call that they are speaking with an AI receptionist. You may change the greeting but not remove that disclosure.
c. If you turn call recording on, you must make sure recording is lawful where you and your callers are. Callers are told when a call is recorded.
d. You must not use Zella Voice for anything unlawful, harmful, deceptive or abusive.

4. The AI receptionist
The receptionist works from the information you approve. It can make mistakes. It will not give medical, legal or financial advice, and it hands a call to a person or takes a message when it cannot help. Check what it books and records.

5. Plans, minutes and payment
Your plan sets your price and your allowances. When your minutes run out, calls are forwarded to your own number if you have one, or the caller is told the call can't be taken right now, unless you have chosen a paid option to continue. Prices and renewal terms are shown before you pay.

6. Your data
You own your business's data. We process it to provide the service as described in our Privacy Policy. You can export it, and you can ask us to delete your account: it is frozen at once and deleted 30 days after we confirm the request, unless you cancel it.

7. Availability
We work to keep Zella Voice available, and our status page says when something is not working. We are not responsible for failures of phone networks or of services outside our control.

8. Ending the service
You can cancel at any time. We may suspend an account that breaks these terms or puts others at risk, and we will tell you why.

9. Liability
To the extent the law allows, our total liability is limited to what you paid us in the 12 months before the claim. (Owner and counsel to confirm.)

10. Contact
support@zellavoice.com (owner to confirm the address and the company's legal name).$doc$, 'draft', true)
on conflict (kind, version) do nothing;

-- the version in effect for a page anyone can open: published if there is one, otherwise the latest draft, marked
create or replace function public.zella_legal_current(p_kind text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select jsonb_build_object('id', d.id, 'kind', d.kind, 'version', d.version, 'title', d.title, 'body', d.body, 'draft', false, 'effective_at', d.effective_at)
       from public.legal_documents d where d.kind = p_kind and d.status = 'published' order by d.published_at desc nulls last limit 1),
    (select jsonb_build_object('id', d.id, 'kind', d.kind, 'version', d.version, 'title', d.title, 'body', d.body, 'draft', true, 'effective_at', null)
       from public.legal_documents d where d.kind = p_kind and d.status in ('draft', 'in_review') order by d.created_at desc limit 1))
   where p_kind in ('privacy', 'terms')
$$;

-- the owner onboarding step: the owner accepts the current privacy policy and terms (recorded with their version)
create or replace function public.zella_owner_onboarding_legal_accept(p_business_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare k text; d jsonb; v_out jsonb := '[]'::jsonb;
begin
  perform public.zella_onboarding_authorize(p_business_id, true, false);
  foreach k in array array['privacy', 'terms'] loop
    d := public.zella_legal_current(k);
    if d is null then raise exception 'LEGAL_DOCUMENT_MISSING'; end if;
    insert into public.legal_acceptances (document_id, business_id, user_id) values ((d ->> 'id')::uuid, p_business_id, auth.uid())
    on conflict do nothing;
    v_out := v_out || jsonb_build_array(jsonb_build_object('kind', k, 'version', d ->> 'version', 'draft', (d ->> 'draft')::boolean));
  end loop;
  perform public.zella_onboarding_audit(p_business_id, auth.uid(), 'onboarding.legal_accepted', null, jsonb_build_object('documents', v_out));
  return jsonb_build_object('accepted', v_out);
end $$;

-- erasing a customer also queues their calls for deletion at Vapi; the daily group runs the automatic deletion
do $$
declare
  f record; d text; n integer;
  plan constant jsonb := jsonb_build_array(
    jsonb_build_object('sig', 'public.zella_erase_customer(uuid,uuid)', 'known', jsonb_build_array('3e070f982d65afbe1bf78ea4af835fe8'), 'marker', 'zella_privacy_retention',
      'anchor', $a$  update public.calls set transcript = null, recording_url = null, summary = null, from_number = null, to_number = null where customer_id = p_customer_id and business_id = p_business_id;
$a$,
      'with', $w$  -- zella_privacy_retention: the copies at Vapi are deleted too (sent while vapi_deletion_live is on)
  perform public.zella_queue_provider_deletion(p_business_id, c.external_call_id, 'customer_erasure') from public.calls c where c.customer_id = p_customer_id and c.business_id = p_business_id;
  update public.calls set transcript = null, recording_url = null, summary = null, from_number = null, to_number = null where customer_id = p_customer_id and business_id = p_business_id;
$w$),
    -- production's version, or main's with every pending migration before this file applied (weekly report, business
    -- moments, job intent, voice admin)
    jsonb_build_object('sig', 'public.zella_run_scheduled_job(text)', 'known', jsonb_build_array('671ec3ca5b53cc2d660f054b837d67d1', '0b2182d27e25e8dbf49041120fafee29'), 'marker', 'zella_retention_auto_run',
      'anchor', $a$  if p_job not in ('$a$, 'with', $w$  if p_job not in ('zella_retention_auto_run', '$w$),
    -- production's version, with sql/zella_cancellations_scheduled.sql applied, or main's with every pending migration
    jsonb_build_object('sig', 'public.zella_run_schedule_group(text)', 'known', jsonb_build_array('78b7fdfea58e49d1dfb594e7acc9b808', '5a9bc8c34841edd1ad3d66ff4156a006', '7e119dba5056dde8ffa8247419743808'), 'marker', 'zella_retention_auto_run',
      'anchor', $a$'zella_run_permission_check']$a$, 'with', $w$'zella_run_permission_check', 'zella_retention_auto_run']$w$));
begin
  for f in select x from jsonb_array_elements(plan) x loop
    if to_regprocedure(f.x ->> 'sig') is null then raise exception 'VERSION_MISMATCH: % is missing', f.x ->> 'sig'; end if;
    d := pg_get_functiondef((f.x ->> 'sig')::regprocedure);
    continue when position(f.x ->> 'marker' in d) > 0;   -- already applied
    if not (f.x -> 'known') ? md5(d) then raise exception 'VERSION_MISMATCH: % is not a version this file was written for', f.x ->> 'sig'; end if;
    n := (length(d) - length(replace(d, f.x ->> 'anchor', ''))) / length(f.x ->> 'anchor');
    if n <> 1 then raise exception 'VERSION_MISMATCH: % anchor found % times', f.x ->> 'sig', n; end if;
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_privacy_retention', f.x ->> 'sig', d, md5(d)) on conflict (migration, signature) do nothing;
    execute replace(d, f.x ->> 'anchor', f.x ->> 'with');
  end loop;
end $$;

revoke all on function public.zella_queue_provider_deletion(uuid, text, text), public.zella_provider_deletions_claim(integer),
  public.zella_provider_deletion_result(uuid, text, text), public.zella_retention_auto_run() from public, anon, authenticated;
grant execute on function public.zella_queue_provider_deletion(uuid, text, text), public.zella_provider_deletions_claim(integer),
  public.zella_provider_deletion_result(uuid, text, text), public.zella_retention_auto_run() to service_role;
revoke all on function public.zella_legal_current(text) from public;
grant execute on function public.zella_legal_current(text) to anon, authenticated, service_role;
revoke all on function public.zella_owner_onboarding_legal_accept(uuid) from public, anon;
grant execute on function public.zella_owner_onboarding_legal_accept(uuid) to authenticated, service_role;

commit;
