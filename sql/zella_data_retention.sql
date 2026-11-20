-- Zella Voice: retention periods per kind of data, legal holds and a dry run of what a purge would remove
-- (docs/ADMIN_AUDIT_2026-11-16.md SET-RETENTION, BIZ-18b; ARCHITECTURE.md REQ-PRV-01, D-13, D-27). Only one period
-- existed (retention_days, for a cancelled business's records) and nothing listed what is past its period.
--   1. A server only table, data_retention_policies: one row per kind of data with its period in days, the
--      architecture's proposed period, and its legal status. Every row starts as the architecture's value and
--      "pending_legal_review": call recordings 30 days, call transcripts 90, message bodies 730 (2 years), audit and
--      security logs 2555 (7 years), replaced verification documents 30 days after they were replaced, owner identity
--      files 90 days after they were verified (the outcome is kept), a cancelled business's verification documents and
--      the cancelled business itself 30 days after cancellation. Only a Zella Voice owner changes a period or records
--      legal approval, with a reason, audited (zella_retention_policy_set).
--   2. A server only table, legal_holds: a business on hold is never listed for removal. security.manage places a
--      hold; only a Zella Voice owner releases one. Audited.
--   3. zella_retention_preview(admin, kind, limit): the DRY RUN. It counts and lists (ids, business, date: never any
--      content) what is past its period, leaving out businesses on hold, and deletes nothing. security.view.
--      zella_retention_candidates(kind, cutoff) is the one definition of "past its period" that the purge (a later
--      migration) uses too.
--   4. A server only table, retention_removed_files: verification files a purge removed (the row and its outcome stay).
--      Filled by sql/zella_retention_purge.sql; files listed there are not listed again.
--   5. retention_purge_enabled = false: the switch a real purge will need (sql/zella_retention_purge.sql). Only a
--      Zella Voice owner can change it (zella_retention_switch_set, a guard refuses any other change). No job is
--      scheduled, here or anywhere.
-- Nothing here deletes or changes any call, message, audit row or document.
-- Every function here is new. If one already exists it must be exactly this file's version (VERSION_MISMATCH otherwise).
-- Needs sql/zella_number_orders.sql (the zella_actor_* helpers). Rollback: sql/rollback/zella_data_retention_rollback.sql
begin;

do $$
declare
  f record;
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
  if to_regprocedure('public.zella_actor_can(uuid,text)') is null or to_regprocedure('public.zella_actor_audit(uuid,text,text,uuid,uuid,jsonb,jsonb)') is null
     or to_regclass('public.business_verification_documents') is null or to_regclass('public.calls') is null or to_regclass('public.sms_messages') is null
     or to_regclass('public.email_messages') is null or to_regclass('public.conversation_messages') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing (apply sql/zella_number_orders.sql first)';
  end if;
  if (to_regclass('public.data_retention_policies') is not null and not exists (select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'data_retention_policies' and column_name = 'architecture_days'))
     or (to_regclass('public.retention_removed_files') is not null and not exists (select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'retention_removed_files' and column_name = 'run_id'))
     or (to_regclass('public.legal_holds') is not null and not exists (select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'legal_holds' and column_name = 'released_at')) then
    raise exception 'VERSION_MISMATCH: a different data_retention_policies or legal_holds table already exists';
  end if;
  for f in select key as sig, value #>> '{}' as want from jsonb_each(mine) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(f.sig::regprocedure)) <> f.want then
      raise exception 'VERSION_MISMATCH: % exists and is not this file''s version', f.sig;
    end if;
  end loop;
end $$;

create table if not exists public.data_retention_policies (
  data_class text primary key check (data_class in ('call_recordings', 'call_transcripts', 'message_bodies', 'audit_logs',
    'documents_replaced', 'documents_owner_id_verified', 'documents_cancelled_business', 'cancelled_business')),
  days integer not null check (days between 1 and 36500),
  architecture_days integer not null,
  legal_status text not null default 'pending_legal_review' check (legal_status in ('pending_legal_review', 'approved')),
  note text check (note is null or length(note) <= 300),
  updated_by uuid,
  updated_at timestamptz not null default now()
);
alter table public.data_retention_policies enable row level security;
revoke all on table public.data_retention_policies from public, anon, authenticated;
grant all on table public.data_retention_policies to service_role;

insert into public.data_retention_policies (data_class, days, architecture_days, note) values
  ('call_recordings', 30, 30, 'D-13, D-27. Recording is off until legal review, so there are none yet.'),
  ('call_transcripts', 90, 90, 'D-13.'),
  ('message_bodies', 730, 730, 'Texts, emails and conversation messages: the words are removed, the record of the message stays.'),
  ('audit_logs', 2555, 2555, 'Audit and security logs, 7 years unless the legal policy requires otherwise.'),
  ('documents_replaced', 30, 30, 'Files of verification documents replaced by a newer copy, counted from the replacement.'),
  ('documents_owner_id_verified', 90, 90, 'Owner identity files, counted from verification. The outcome (status, reviewer, date) is kept.'),
  ('documents_cancelled_business', 30, 30, 'Every verification file of a cancelled business, counted from cancellation.'),
  ('cancelled_business', 30, 30, 'The whole business, after a final export offer. Never earlier than its retention date (retention_days, 90 today).')
on conflict (data_class) do nothing;

-- Verification files removed under retention (by sql/zella_retention_purge.sql): the document row and its outcome stay,
-- and the dry run doesn't list the file again.
create table if not exists public.retention_removed_files (
  document_id uuid primary key,
  file_path text not null,
  run_id uuid,
  removed_at timestamptz not null default now()
);
alter table public.retention_removed_files enable row level security;
revoke all on table public.retention_removed_files from public, anon, authenticated;
grant all on table public.retention_removed_files to service_role;

create table if not exists public.legal_holds (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  reason text not null check (length(btrim(reason)) between 3 and 300),
  placed_by uuid not null,
  placed_at timestamptz not null default now(),
  released_by uuid,
  released_at timestamptz,
  release_reason text check (release_reason is null or length(release_reason) <= 300)
);
create unique index if not exists legal_holds_one_active on public.legal_holds (business_id) where released_at is null;
alter table public.legal_holds enable row level security;
revoke all on table public.legal_holds from public, anon, authenticated;
grant all on table public.legal_holds to service_role;

-- Only zella_retention_switch_set (which sets zella.retention_switch for its own transaction) may change the switch.
create or replace function public.zella_retention_setting_guard()
returns trigger language plpgsql set search_path = public as $$
begin
  -- the old and the new key both count, so an update can't rename the switch away
  if 'retention_purge_enabled' in (new.key, old.key) and coalesce(current_setting('zella.retention_switch', true), '') <> 'on' then
    raise exception 'RETENTION_SWITCH_OWNER_ONLY: only a Zella Voice owner changes this, from Data retention';
  end if;
  return coalesce(new, old);
end $$;

select set_config('zella.retention_switch', 'on', true);
insert into public.platform_settings (key, value) values ('retention_purge_enabled', 'false'::jsonb) on conflict (key) do nothing;
select set_config('zella.retention_switch', '', true);
drop trigger if exists zella_retention_setting_guard on public.platform_settings;
create trigger zella_retention_setting_guard before insert or update or delete on public.platform_settings
  for each row execute function public.zella_retention_setting_guard();

create or replace function public.zella_retention_on_hold(p_business uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.legal_holds where business_id = p_business and released_at is null);
$$;

-- What is past its period for one kind of data, as (table, id, business, date). Never any content. Businesses on a
-- legal hold are left out. The single definition used by the dry run and by the purge.
-- A purged transcript is replaced by 'Removed under the retention policy.', not emptied: an empty transcript on a short
-- call would make zella_call_integrity re-mark the old call as missed and start a missed call callback.
create or replace function public.zella_retention_candidates(p_class text, p_cutoff timestamptz)
returns table (source text, row_id uuid, business_id uuid, dated timestamptz)
language sql stable security definer set search_path = public as $$
  select 'calls', c.id, c.business_id, coalesce(c.ended_at, c.created_at) from public.calls c
   where p_class = 'call_recordings' and c.recording_url is not null and coalesce(c.ended_at, c.created_at) < p_cutoff
     and not public.zella_retention_on_hold(c.business_id)
  union all
  select 'calls', c.id, c.business_id, coalesce(c.ended_at, c.created_at) from public.calls c
   where p_class = 'call_transcripts' and c.transcript is not null and c.transcript <> 'Removed under the retention policy.'
     and coalesce(c.ended_at, c.created_at) < p_cutoff
     and not public.zella_retention_on_hold(c.business_id)
  union all
  select 'sms_messages', m.id, m.business_id, m.created_at from public.sms_messages m
   where p_class = 'message_bodies' and m.message_body is not null and m.created_at < p_cutoff and not public.zella_retention_on_hold(m.business_id)
  union all
  select 'email_messages', m.id, m.business_id, m.created_at from public.email_messages m
   where p_class = 'message_bodies' and (m.body_text is not null or m.body_html is not null) and m.created_at < p_cutoff
     and not public.zella_retention_on_hold(m.business_id)
  union all
  select 'conversation_messages', m.id, m.business_id, m.created_at from public.conversation_messages m
   where p_class = 'message_bodies' and m.content is not null and m.created_at < p_cutoff and not public.zella_retention_on_hold(m.business_id)
  union all
  select 'audit_logs', a.id, a.business_id, a.created_at from public.audit_logs a
   where p_class = 'audit_logs' and a.created_at < p_cutoff and (a.business_id is null or not public.zella_retention_on_hold(a.business_id))
  union all
  select 'business_verification_documents', d.id, d.business_id, d.updated_at from public.business_verification_documents d
   where p_class = 'documents_replaced' and d.status = 'replaced' and d.updated_at < p_cutoff and not public.zella_retention_on_hold(d.business_id)
     and not exists (select 1 from public.retention_removed_files f where f.document_id = d.id)
  union all
  select 'business_verification_documents', d.id, d.business_id, d.reviewed_at from public.business_verification_documents d
   where p_class = 'documents_owner_id_verified' and d.kind = 'owner_identity' and d.status = 'verified' and d.reviewed_at < p_cutoff
     and not public.zella_retention_on_hold(d.business_id) and not exists (select 1 from public.retention_removed_files f where f.document_id = d.id)
  union all
  select 'business_verification_documents', d.id, d.business_id, b.cancelled_at from public.business_verification_documents d
    join public.businesses b on b.id = d.business_id
   where p_class = 'documents_cancelled_business' and b.cancelled_at is not null and b.cancelled_at < p_cutoff
     and not public.zella_retention_on_hold(d.business_id) and not exists (select 1 from public.retention_removed_files f where f.document_id = d.id)
  union all
  select 'businesses', b.id, b.id, b.cancelled_at from public.businesses b
   where p_class = 'cancelled_business' and b.cancelled_at is not null and b.cancelled_at < p_cutoff
     and (b.retention_until is null or b.retention_until < now()) and not public.zella_retention_on_hold(b.id);
$$;

-- The dry run: how many, and the first ones, oldest first. Deletes nothing.
create or replace function public.zella_retention_preview(p_actor uuid, p_class text, p_limit integer default 25)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare p public.data_retention_policies; v_cutoff timestamptz;
begin
  if not public.zella_actor_can(p_actor, 'security.view') then raise exception 'NOT_ALLOWED'; end if;
  select * into p from public.data_retention_policies where data_class = p_class;
  if p.data_class is null then raise exception 'UNKNOWN_CLASS'; end if;
  v_cutoff := now() - make_interval(days => p.days);
  return jsonb_build_object('data_class', p.data_class, 'days', p.days, 'cutoff', v_cutoff, 'legal_status', p.legal_status, 'dry_run', true,
    'count', (select count(*) from public.zella_retention_candidates(p.data_class, v_cutoff)),
    'by_source', coalesce((select jsonb_object_agg(source, n) from (select source, count(*) n from public.zella_retention_candidates(p.data_class, v_cutoff) group by source) s), '{}'::jsonb),
    'held_businesses', (select count(*) from public.legal_holds where released_at is null),
    'sample', coalesce((select jsonb_agg(jsonb_build_object('source', c.source, 'id', c.row_id, 'business_id', c.business_id, 'business_name', b.name, 'dated', c.dated) order by c.dated)
       from (select * from public.zella_retention_candidates(p.data_class, v_cutoff) order by dated limit least(greatest(coalesce(p_limit, 25), 1), 100)) c
       left join public.businesses b on b.id = c.business_id), '[]'::jsonb));
end $$;

create or replace function public.zella_retention_overview(p_actor uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.zella_actor_can(p_actor, 'security.view') then raise exception 'NOT_ALLOWED'; end if;
  return jsonb_build_object(
    'policies', (select jsonb_agg(to_jsonb(p) - 'updated_by' order by array_position(array['call_recordings', 'call_transcripts', 'message_bodies', 'audit_logs',
        'documents_replaced', 'documents_owner_id_verified', 'documents_cancelled_business', 'cancelled_business'], p.data_class)) from public.data_retention_policies p),
    'purge_enabled', coalesce((select value = 'true'::jsonb from public.platform_settings where key = 'retention_purge_enabled'), false),
    'retention_days', (select value from public.platform_settings where key = 'retention_days'),
    'holds', coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'business_id', h.business_id, 'business_name', b.name, 'reason', h.reason,
        'placed_at', h.placed_at, 'placed_by_email', u.email) order by h.placed_at desc)
      from public.legal_holds h join public.businesses b on b.id = h.business_id left join auth.users u on u.id = h.placed_by where h.released_at is null), '[]'::jsonb),
    'scheduled', false);
end $$;

-- The owner sets a period and its legal status. Only after legal review should the status be "approved".
create or replace function public.zella_retention_policy_set(p_actor uuid, p_class text, p_days integer, p_status text, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_reason text := left(btrim(coalesce(p_reason, '')), 300); o public.data_retention_policies; n public.data_retention_policies;
begin
  if public.zella_actor_role(p_actor) is distinct from 'zella_owner' then raise exception 'OWNER_REQUIRED'; end if;
  if length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  if p_status is null or p_status not in ('pending_legal_review', 'approved') then raise exception 'INVALID_STATUS'; end if;
  if p_days is null or p_days < 1 or p_days > 36500 then raise exception 'INVALID_DAYS'; end if;
  select * into o from public.data_retention_policies where data_class = p_class for update;
  if o.data_class is null then raise exception 'UNKNOWN_CLASS'; end if;
  update public.data_retention_policies set days = p_days, legal_status = p_status, updated_by = p_actor, updated_at = now()
   where data_class = p_class returning * into n;
  perform public.zella_actor_audit(p_actor, 'platform.retention_policy_set', 'data_retention_policy', null, null,
    jsonb_build_object('data_class', o.data_class, 'days', o.days, 'legal_status', o.legal_status),
    jsonb_build_object('data_class', n.data_class, 'days', n.days, 'legal_status', n.legal_status, 'reason', v_reason));
  return to_jsonb(n) - 'updated_by';
end $$;

create or replace function public.zella_retention_switch_set(p_actor uuid, p_on boolean, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_reason text := left(btrim(coalesce(p_reason, '')), 300); v_was boolean;
begin
  if public.zella_actor_role(p_actor) is distinct from 'zella_owner' then raise exception 'OWNER_REQUIRED'; end if;
  if length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  if p_on is null then raise exception 'DECISION_REQUIRED'; end if;
  v_was := coalesce((select value = 'true'::jsonb from public.platform_settings where key = 'retention_purge_enabled'), false);
  perform set_config('zella.retention_switch', 'on', true);
  insert into public.platform_settings (key, value, updated_at) values ('retention_purge_enabled', to_jsonb(p_on), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  perform set_config('zella.retention_switch', '', true);
  perform public.zella_actor_audit(p_actor, 'platform.retention_purge_switch', 'platform_setting', null, null,
    jsonb_build_object('enabled', v_was), jsonb_build_object('enabled', p_on, 'reason', v_reason));
  return jsonb_build_object('purge_enabled', p_on);
end $$;

create or replace function public.zella_legal_hold_place(p_actor uuid, p_business uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_reason text := left(btrim(coalesce(p_reason, '')), 300); h public.legal_holds;
begin
  if not public.zella_actor_can(p_actor, 'security.manage') then raise exception 'NOT_ALLOWED'; end if;
  if length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  if not exists (select 1 from public.businesses where id = p_business) then raise exception 'BUSINESS_NOT_FOUND'; end if;
  -- the same lock as a purge's removal, so a hold never lands in the middle of one
  perform pg_advisory_xact_lock(hashtextextended('zella_legal_holds', 0));
  if public.zella_retention_on_hold(p_business) then raise exception 'ALREADY_ON_HOLD'; end if;
  -- refused while a purge run is removing this business's files (sql/zella_retention_purge.sql); once it stops, the
  -- remaining files of a business on hold are never removed
  if to_regclass('public.retention_purge_runs') is not null then
    if (select exists (select 1 from public.retention_purge_runs r join public.business_verification_documents d on d.file_path = any (r.file_paths)
                        where r.status in ('running', 'files_pending') and d.business_id = p_business)) then
      raise exception 'PURGE_IN_PROGRESS';
    end if;
  end if;
  insert into public.legal_holds (business_id, reason, placed_by) values (p_business, v_reason, p_actor) returning * into h;
  perform public.zella_actor_audit(p_actor, 'business.legal_hold_placed', 'legal_hold', h.id, p_business, null, jsonb_build_object('reason', v_reason));
  return to_jsonb(h);
end $$;

create or replace function public.zella_legal_hold_release(p_actor uuid, p_hold uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_reason text := left(btrim(coalesce(p_reason, '')), 300); h public.legal_holds;
begin
  if public.zella_actor_role(p_actor) is distinct from 'zella_owner' then raise exception 'OWNER_REQUIRED'; end if;
  if length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  update public.legal_holds set released_by = p_actor, released_at = now(), release_reason = v_reason
   where id = p_hold and released_at is null returning * into h;
  if h.id is null then raise exception 'NOT_FOUND'; end if;
  perform public.zella_actor_audit(p_actor, 'business.legal_hold_released', 'legal_hold', h.id, h.business_id,
    jsonb_build_object('reason', h.reason), jsonb_build_object('reason', v_reason));
  return to_jsonb(h);
end $$;

revoke all on function public.zella_retention_setting_guard(), public.zella_retention_on_hold(uuid),
  public.zella_retention_candidates(text, timestamptz), public.zella_retention_preview(uuid, text, integer), public.zella_retention_overview(uuid),
  public.zella_retention_policy_set(uuid, text, integer, text, text), public.zella_retention_switch_set(uuid, boolean, text),
  public.zella_legal_hold_place(uuid, uuid, text), public.zella_legal_hold_release(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.zella_retention_on_hold(uuid), public.zella_retention_preview(uuid, text, integer), public.zella_retention_overview(uuid),
  public.zella_retention_policy_set(uuid, text, integer, text, text), public.zella_retention_switch_set(uuid, boolean, text),
  public.zella_legal_hold_place(uuid, uuid, text), public.zella_legal_hold_release(uuid, uuid, text) to service_role;

commit;
