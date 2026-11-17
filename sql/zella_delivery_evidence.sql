-- Rollback baseline is captured on first apply of this version, never on reruns.
-- An older deployment needs its original backup; this cannot reconstruct already-overwritten state.
create table if not exists public.zella_delivery_evidence_undo (seq bigint generated always as identity, command text not null);
revoke all on public.zella_delivery_evidence_undo from public, anon, authenticated, service_role;
do $capture$
declare f text; p oid; r record; g record; ddl text; cols text[];
begin
 if not exists (select 1 from public.zella_delivery_evidence_undo) then
  insert into public.zella_delivery_evidence_undo(command) values ('select 1');
  foreach f in array array['public.zella_assistant_for_call(text,text,text)','public.zella_assistant_delivery_status(uuid)'] loop
    p := to_regprocedure(f);
    if p is null then
      insert into public.zella_delivery_evidence_undo(command) values ('drop function if exists ' || f);
    else
      insert into public.zella_delivery_evidence_undo(command) values (pg_get_functiondef(p));
      -- Only these roles' permissions are modified by the migrations.
      insert into public.zella_delivery_evidence_undo(command) values ('revoke all on function ' || f || ' from public, anon, authenticated, service_role');
      for g in select a.* from pg_proc x, lateral aclexplode(coalesce(x.proacl, acldefault('f',x.proowner))) a
        where x.oid=p and (a.grantee=0 or a.grantee in (select oid from pg_roles where rolname in ('anon','authenticated','service_role'))) loop
        insert into public.zella_delivery_evidence_undo(command) values ('grant execute on function ' || f || ' to ' ||
          case when g.grantee=0 then 'public' else quote_ident(pg_get_userbyid(g.grantee)) end ||
          case when g.is_grantable then ' with grant option' else '' end);
      end loop;
    end if;
  end loop;
  if not exists (select 1 from pg_attribute where attrelid='public.assistant_deliveries'::regclass and attname='config_hash' and not attisdropped) then
    insert into public.zella_delivery_evidence_undo(command) values ('alter table public.assistant_deliveries drop column if exists config_hash');
  end if;
  if to_regclass('public.assistant_deliveries_business_outcome_id_idx') is null then insert into public.zella_delivery_evidence_undo(command) values ('drop index if exists public.assistant_deliveries_business_outcome_id_idx'); end if;
  if to_regclass('public.calls_business_external_delivery_idx') is null then insert into public.zella_delivery_evidence_undo(command) values ('drop index if exists public.calls_business_external_delivery_idx'); end if;
 end if;
end $capture$;

-- Which exact settings each call received, and how far a change has got. Safe to run twice.
-- Rollback: sql/rollback/zella_delivery_evidence_rollback.sql.
--
-- E2  Hours, prices, languages and greetings are saved straight from their Settings pages, outside the receptionist's
--     draft/publish versions. A call's delivery record therefore said "version: none" for them, and nothing tied a call
--     to the settings it got. Now every assistant handed to a call is fingerprinted (config_hash, md5 of exactly what
--     was sent). The same settings give the same fingerprint; any change gives a new one.
-- E3  The status shown in the CRM separates the five stages:
--       draft           a version saved but not published (receptionist editor)
--       published       the published version, and whether a call has used it (sync_status: pending / live / failed)
--       delivery        provider delivery configured: Vapi has asked for this business's assistant at least once
--                       (only a number switched to assistant-request does that)
--       verified_call   a call that received the current settings and then completed (status completed, with a
--                       duration), which only a real call through the phone line produces
--     Knowledge is separate: items are draft, processing (being checked), ready (in use), failed or archived, and are
--     read live on every search, not delivered with the assistant.

alter table public.assistant_deliveries add column if not exists config_hash text;

do $$
declare def text;
begin
  def := pg_get_functiondef('public.zella_assistant_for_call(text, text, text)'::regprocedure);
  if position('zella_delivery_evidence' in def) = 0 then
    def := replace(def, $a$    insert into assistant_deliveries (business_id, version_id, provider_call_id, outcome) values (v_biz, v_version, left(p_provider_call_id, 120), 'served');
    return jsonb_build_object('ok', true, 'outcome', 'served', 'version_id', v_version, 'assistant', v_cfg - 'ready_to_send' - 'problems');$a$,
                        $a$    insert into assistant_deliveries (business_id, version_id, provider_call_id, outcome, config_hash)   /* zella_delivery_evidence */
    values (v_biz, v_version, left(p_provider_call_id, 120), 'served', md5((v_cfg - 'ready_to_send' - 'problems')::text));
    return jsonb_build_object('ok', true, 'outcome', 'served', 'version_id', v_version, 'config_hash', md5((v_cfg - 'ready_to_send' - 'problems')::text), 'assistant', v_cfg - 'ready_to_send' - 'problems');$a$);
    if position('zella_delivery_evidence' in def) = 0 then raise exception 'zella_assistant_for_call has changed; review this patch'; end if;
    execute def;
  end if;
end $$;

create or replace function public.zella_assistant_delivery_status(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_current text;
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  -- zella_delivery_evidence: what a call would get now, to compare with what calls last got
  begin
    v_current := md5((public.zella_assistant_config(p_business_id) - 'ready_to_send' - 'problems')::text);
  exception when others then v_current := null;
  end;
  return jsonb_build_object(
    'draft', (select jsonb_build_object('id', v.id, 'version', v.version, 'status', v.status, 'saved_at', v.created_at)
                from agent_config_versions v where v.business_id = p_business_id and v.status in ('draft', 'valid', 'invalid') order by v.version desc limit 1),
    'version', (select jsonb_build_object('id', v.id, 'version', v.version, 'published_at', v.published_at, 'sync_status', v.sync_status, 'sync_error', v.sync_error)
                  from agent_config_versions v where v.business_id = p_business_id and v.status = 'published' order by v.published_at desc nulls last limit 1),
    'current_config_hash', v_current,
    'delivery', jsonb_build_object(
      'configured', exists (select 1 from assistant_deliveries where business_id = p_business_id and outcome = 'served'),
      'first_served_at', (select min(created_at) from assistant_deliveries where business_id = p_business_id and outcome = 'served'),
      'last_served', (select jsonb_build_object('at', d.created_at, 'call_id', d.provider_call_id, 'config_hash', d.config_hash, 'is_current', d.config_hash = v_current)
                        from assistant_deliveries d where d.business_id = p_business_id and d.outcome = 'served' order by d.id desc limit 1)),
    'verified_call', (select jsonb_build_object('at', d.created_at, 'call_id', d.provider_call_id, 'config_hash', d.config_hash, 'is_current', d.config_hash = v_current, 'duration_seconds', c.duration_seconds)
                        from assistant_deliveries d join calls c on c.business_id = d.business_id and c.external_call_id = d.provider_call_id
                       where d.business_id = p_business_id and d.outcome = 'served' and c.status = 'completed' and coalesce(c.duration_seconds, 0) > 0
                       order by d.id desc limit 1),
    'last_served_at', (select max(created_at) from assistant_deliveries where business_id = p_business_id and outcome = 'served'),
    'last_problem', (select jsonb_build_object('at', d.created_at, 'problems', d.problems) from assistant_deliveries d
                      where d.business_id = p_business_id and d.outcome = 'not_ready' order by d.created_at desc limit 1));
end $$;

create index if not exists assistant_deliveries_business_outcome_id_idx on public.assistant_deliveries (business_id, outcome, id desc);
do $$ begin
  if not exists (
    select 1 from pg_index i where i.indrelid='public.calls'::regclass and i.indisvalid and i.indpred is null
      and i.indnkeyatts >= 2 and
      (select array_agg(a.attname::text order by k.ordinality) from unnest(i.indkey::smallint[]) with ordinality k(attnum,ordinality)
       join pg_attribute a on a.attrelid=i.indrelid and a.attnum=k.attnum where k.ordinality <= 2) = array['business_id','external_call_id']
  ) then create index if not exists calls_business_external_delivery_idx on public.calls (business_id, external_call_id); end if;
end $$;
