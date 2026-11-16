-- Zella Voice: a whole business export (docs/ADMIN_AUDIT_2026-11-16.md SET-DL-EXPORT, REQ-LC-20).
-- Only per customer export existed. Default (owner can change): an admin requests an export of one business, a Zella
-- Voice owner other than the requester approves it, a background worker writes it to a private bucket, and it can be
-- downloaded from the admin page for 7 days through signed links that end with it.
-- This file:
--   * business_export_jobs: one row per export (requested, approved, running, ready, failed, rejected, expired), with
--     its progress so an interrupted run resumes where it stopped. Server only (row security on, no policies);
--   * the private bucket business-exports (not public; nothing but the server key reads it);
--   * server only functions: zella_export_request, zella_export_decide (approve or reject), zella_export_claim,
--     zella_export_progress, zella_export_finish (ready for 7 days, or back to approved to resume, failed after 3
--     tries), zella_export_tables, zella_export_rows and zella_export_files. Every step is audited.
-- What an export never contains: integration_secrets, crm_record_secrets, email_unsubscribe_tokens and
-- business_export_jobs; any column whose name says token, secret, password, api key, credential or a key/token hash;
-- call recording links; and call transcripts and summaries in industries whose calls carry health, legal, financial,
-- insurance or children's information (zella_sensitive_industry, the same rule as call content privacy).
-- Nothing runs on its own: the worker is the business-export edge function, started only when the owner turns its job on.
-- Each new function must be absent or exactly this file's version, otherwise VERSION_MISMATCH.
-- Rollback: sql/rollback/zella_business_export_rollback.sql
begin;

do $$
declare f record;
begin
  if to_regclass('public.businesses') is null or to_regclass('storage.buckets') is null or to_regprocedure('public.zella_admin_reason(text)') is null
     or to_regprocedure('public.zella_sensitive_industry(uuid)') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  if to_regclass('public.business_export_jobs') is not null and not exists (
       select 1 from pg_description where objoid = to_regclass('public.business_export_jobs') and objsubid = 0 and description like 'Zella Voice whole business exports%') then
    raise exception 'VERSION_MISMATCH: a different business_export_jobs table already exists';
  end if;
  for f in select * from (values
      ('public.zella_export_request(uuid,uuid,text)', 'f47b159a55dbc664012efcc5f31a91d3'),
      ('public.zella_export_decide(uuid,uuid,boolean,text)', 'd629f795bb5d2cdbfe5f35ae7d3cc153'),
      ('public.zella_export_claim()', 'ff8042f03db758b059a9e0d195e6fb6d'),
      ('public.zella_export_progress(uuid,uuid,jsonb)', 'dd7783ebcb736ed012d29a56adfa02cd'),
      ('public.zella_export_finish(uuid,uuid,boolean,text,text)', '83b5834fc4d29a12c2e5c849c3d93877'),
      ('public.zella_export_tables()', '5a84e8a9605c8e20d1ffbfcf4537d600'),
      ('public.zella_export_rows(uuid,uuid,text,integer,integer)', 'b0da0326b04c813ccd7ddd5b443063d9'),
      ('public.zella_export_files(uuid,uuid)', '580156e5758c1d2fbbcae6e8387969c0')) as t(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(to_regprocedure(f.sig))) <> f.want then
      raise exception 'VERSION_MISMATCH: % is not a version this file was written for', f.sig;
    end if;
  end loop;
end $$;

create table if not exists public.business_export_jobs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid references public.businesses(id) on delete set null,
  business_name text not null,
  status text not null default 'requested' check (status in ('requested', 'approved', 'running', 'ready', 'failed', 'rejected', 'expired')),
  requested_by uuid not null,
  request_reason text not null check (length(request_reason) between 3 and 300),
  decided_by uuid,
  decided_at timestamptz,
  decision_reason text check (decision_reason is null or length(decision_reason) <= 300),
  progress jsonb not null default '{}'::jsonb,
  attempts integer not null default 0,
  claim_token uuid,
  claimed_at timestamptz,
  started_at timestamptz,
  finished_at timestamptz,
  manifest_path text,
  expires_at timestamptz,
  last_error text check (last_error is null or length(last_error) <= 500),
  created_at timestamptz not null default now()
);
comment on table public.business_export_jobs is 'Zella Voice whole business exports: request, owner approval, progress and the 7 day download window (sql/zella_business_export.sql)';
create index if not exists business_export_jobs_business_idx on public.business_export_jobs (business_id, created_at desc);
create unique index if not exists business_export_jobs_one_open on public.business_export_jobs (business_id) where status in ('requested', 'approved', 'running');
alter table public.business_export_jobs enable row level security;
revoke all on public.business_export_jobs from public, anon, authenticated;
grant select on public.business_export_jobs to service_role;   -- the admin server reads it; every write goes through the functions

insert into storage.buckets (id, name, public) values ('business-exports', 'business-exports', false) on conflict (id) do update set public = false;

CREATE OR REPLACE FUNCTION public.zella_export_request(p_business uuid, p_actor uuid, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_reason text := public.zella_admin_reason(p_reason); b businesses; v_id uuid;
begin
  if not exists (select 1 from platform_admins where user_id = p_actor and is_active) then raise exception 'NOT_ALLOWED'; end if;
  select * into b from businesses where id = p_business;
  if b.id is null then raise exception 'NOT_FOUND'; end if;
  if exists (select 1 from business_export_jobs where business_id = b.id and status in ('requested', 'approved', 'running')) then
    raise exception 'EXPORT_OPEN';
  end if;
  insert into business_export_jobs (business_id, business_name, requested_by, request_reason)
  values (b.id, b.name, p_actor, v_reason) returning id into v_id;
  insert into audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (b.id, p_actor, 'export.requested', 'business_export', v_id, jsonb_build_object('reason', v_reason));
  return v_id;
end
$function$;

CREATE OR REPLACE FUNCTION public.zella_export_decide(p_id uuid, p_actor uuid, p_approve boolean, p_reason text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare j business_export_jobs; v_reason text := nullif(trim(coalesce(p_reason, '')), ''); v_status text;
begin
  if not exists (select 1 from platform_admins where user_id = p_actor and is_active and role = 'zella_owner') then raise exception 'NOT_ALLOWED'; end if;
  if p_approve is null then raise exception 'DECISION_REQUIRED'; end if;
  if not p_approve then v_reason := public.zella_admin_reason(p_reason); end if;
  select * into j from business_export_jobs where id = p_id for update;
  if j.id is null then raise exception 'NOT_FOUND'; end if;
  if j.status <> 'requested' then raise exception 'NOT_REQUESTED'; end if;
  if j.requested_by = p_actor then raise exception 'OWN_REQUEST'; end if;
  v_status := case when p_approve then 'approved' else 'rejected' end;
  update business_export_jobs set status = v_status, decided_by = p_actor, decided_at = now(), decision_reason = left(v_reason, 300) where id = j.id;
  insert into audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (j.business_id, p_actor, 'export.' || v_status, 'business_export', j.id, jsonb_build_object('reason', v_reason));
  return v_status;
end
$function$;

-- The worker takes one approved export, or a running one whose worker stopped answering 30 minutes ago (it resumes
-- from its progress). Ready exports past their 7 days are marked expired here too.
CREATE OR REPLACE FUNCTION public.zella_export_claim()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare j business_export_jobs;
begin
  update business_export_jobs set status = 'expired' where status = 'ready' and expires_at < now();
  select * into j from business_export_jobs
   where business_id is not null and (status = 'approved' or (status = 'running' and claimed_at < now() - interval '30 minutes'))
   order by created_at limit 1 for update skip locked;
  if j.id is null then return null; end if;
  if j.attempts >= 3 then
    update business_export_jobs set status = 'failed', finished_at = now(), claim_token = null,
           last_error = coalesce(last_error, 'stopped three times') where id = j.id;
    insert into audit_logs (business_id, action, entity_type, entity_id, new_data)
    values (j.business_id, 'export.failed', 'business_export', j.id, jsonb_build_object('error', 'stopped three times'));
    return null;
  end if;
  update business_export_jobs set status = 'running', attempts = attempts + 1, claim_token = gen_random_uuid(), claimed_at = now(),
         started_at = coalesce(started_at, now())
   where id = j.id returning * into j;
  return jsonb_build_object('id', j.id, 'business_id', j.business_id, 'token', j.claim_token, 'progress', j.progress, 'attempts', j.attempts);
end
$function$;

CREATE OR REPLACE FUNCTION public.zella_export_progress(p_id uuid, p_token uuid, p_progress jsonb)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with u as (update business_export_jobs set progress = coalesce(p_progress, '{}'::jsonb), claimed_at = now()
              where id = p_id and status = 'running' and claim_token = p_token returning 1)
  select exists (select 1 from u)
$function$;

-- ok: ready for 7 days. Not ok: back to approved so the next claim resumes from the progress (failed after 3 tries).
CREATE OR REPLACE FUNCTION public.zella_export_finish(p_id uuid, p_token uuid, p_ok boolean, p_manifest text, p_error text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare j business_export_jobs; v_status text;
begin
  select * into j from business_export_jobs where id = p_id and status = 'running' and claim_token = p_token for update;
  if j.id is null then return 'NOT_THIS_CLAIM'; end if;
  v_status := case when p_ok then 'ready' when j.attempts >= 3 then 'failed' else 'approved' end;
  update business_export_jobs set status = v_status, claim_token = null,
         finished_at = case when v_status in ('ready', 'failed') then now() end,
         manifest_path = case when p_ok then p_manifest else manifest_path end,
         expires_at = case when p_ok then now() + interval '7 days' else expires_at end,
         last_error = case when p_ok then null else left(coalesce(p_error, 'unknown error'), 500) end
   where id = j.id;
  if v_status in ('ready', 'failed') then
    insert into audit_logs (business_id, action, entity_type, entity_id, new_data)
    values (j.business_id, 'export.' || v_status, 'business_export', j.id,
            case when p_ok then jsonb_build_object('manifest', p_manifest) else jsonb_build_object('error', left(p_error, 300)) end);
  end if;
  return v_status;
end
$function$;

-- Every table that holds a business's rows, less the ones an export never contains.
CREATE OR REPLACE FUNCTION public.zella_export_tables()
 RETURNS text[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(array_agg(c.table_name::text order by c.table_name), '{}')
    from information_schema.columns c join pg_tables t on t.schemaname = 'public' and t.tablename = c.table_name
   where c.table_schema = 'public' and c.column_name = 'business_id'
     and c.table_name not in ('integration_secrets', 'crm_record_secrets', 'email_unsubscribe_tokens', 'business_export_jobs')
$function$;

-- One page of one table for the running export, without secret columns and call content the rules keep back.
CREATE OR REPLACE FUNCTION public.zella_export_rows(p_id uuid, p_token uuid, p_table text, p_offset integer, p_limit integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare j business_export_jobs; v_drop text[]; v_rows jsonb;
begin
  select * into j from business_export_jobs where id = p_id and status = 'running' and claim_token = p_token;
  if j.id is null then raise exception 'NOT_THIS_CLAIM'; end if;
  if not (p_table = any (public.zella_export_tables())) then raise exception 'NOT_EXPORTED: %', p_table; end if;
  select coalesce(array_agg(column_name::text), '{}') into v_drop from information_schema.columns
   where table_schema = 'public' and table_name = p_table
     and column_name ~* '(token|secret|password|api_?key|credential|key_hash)';
  if p_table = 'calls' then
    v_drop := v_drop || array['recording_url'];
    if public.zella_sensitive_industry(j.business_id) then v_drop := v_drop || array['transcript', 'summary']; end if;
  end if;
  execute format('select coalesce(jsonb_agg(r), ''[]''::jsonb) from (select to_jsonb(t) - $1 as r from public.%I t where t.business_id = $2 order by to_jsonb(t)::text offset $3 limit $4) x', p_table)
    into v_rows using v_drop, j.business_id, greatest(coalesce(p_offset, 0), 0), least(greatest(coalesce(p_limit, 500), 1), 1000);
  return v_rows;
end
$function$;

-- The business's stored files: verification documents and files on records.
CREATE OR REPLACE FUNCTION public.zella_export_files(p_id uuid, p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare j business_export_jobs;
begin
  select * into j from business_export_jobs where id = p_id and status = 'running' and claim_token = p_token;
  if j.id is null then raise exception 'NOT_THIS_CLAIM'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('bucket', o.bucket_id, 'path', o.name) order by o.bucket_id, o.name)
                     from storage.objects o where o.bucket_id in ('business-documents', 'record-files') and o.name like j.business_id::text || '/%'), '[]'::jsonb);
end
$function$;

do $$ declare s text; begin
  foreach s in array array['zella_export_request(uuid,uuid,text)', 'zella_export_decide(uuid,uuid,boolean,text)', 'zella_export_claim()',
                           'zella_export_progress(uuid,uuid,jsonb)', 'zella_export_finish(uuid,uuid,boolean,text,text)', 'zella_export_tables()',
                           'zella_export_rows(uuid,uuid,text,integer,integer)', 'zella_export_files(uuid,uuid)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', s);
    execute format('grant execute on function public.%s to service_role', s);
  end loop;
end $$;

commit;
