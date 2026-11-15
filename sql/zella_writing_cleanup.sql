-- Zella Voice: no dashes or hyphens in the words people read, part 2 (part 1 was the app: docs/DESIGN_SYSTEM.md, Writing).
-- Changes, all checked on the isolated test copy and in production (read only) before writing this file:
--   1. 33 phrases inside 22 database functions (alert titles, automation names, admin messages, status labels, the
--      cross sell ideas). Each function is archived first (zella_function_archive); each phrase must be found exactly
--      where expected (or already be the new text), otherwise the file stops with VERSION_MISMATCH.
--   2. Stored names and descriptions people see: industries (E-commerce becomes Ecommerce), industry modules,
--      automations, automation presets, message policy reasons, and display text inside automation and CRM presets
--      (titles, messages, task text, labels, notices, record type names). Every changed value is archived first
--      (zella_text_archive) so the rollback restores it exactly.
--   Kept on purpose: values that are matched rather than read (a service name an automation matches, the option values
--   saved on records, appointment status values); changing them would break matching on existing records.
-- Rollback: sql/rollback/zella_writing_cleanup_rollback.sql
begin;

do $$ begin
  if to_regclass('public.zella_function_archive') is null or to_regclass('public.industries') is null or to_regclass('public.industry_modules') is null
     or to_regclass('public.automations') is null or to_regclass('public.industry_automation_presets') is null
     or to_regclass('public.industry_message_policy') is null or to_regclass('public.industry_crm_presets') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
end $$;

create table if not exists public.zella_text_archive (
  migration text not null, tbl text not null, row_key text not null, col text not null, old_value text,
  saved_at timestamptz not null default now(),
  primary key (migration, tbl, row_key, col)
);
alter table public.zella_text_archive enable row level security;
revoke all on table public.zella_text_archive from public, anon, authenticated;

-- the word map: a few words read better written differently, the rest lose their hyphen
create or replace function public.zella_plain_words(t text) returns text
language plpgsql immutable set search_path = public as $f$
declare r text := t; p text[];
begin
  if r is null then return null; end if;
  foreach p slice 1 in array array[
    ['E-commerce', 'Ecommerce'], ['e-commerce', 'ecommerce'], ['Pick-up', 'Pickup'], ['pick-up', 'pickup'], ['Log-in', 'Login'], ['log-in', 'login'],
    ['Pre-approved', 'Preapproved'], ['pre-approved', 'preapproved'], ['Post-purchase', 'After purchase'], ['post-purchase', 'after purchase'],
    ['Pre-arrival', 'Before arrival'], ['pre-arrival', 'before arrival'], ['Pre-departure', 'Before departure'], ['pre-departure', 'before departure']] loop
    r := replace(r, p[1], p[2]);
  end loop;
  -- a number joined to a word (10-class); dates such as 2026-11-15 are numbers on both sides and stay as they are
  r := regexp_replace(r, '([0-9])-([A-Za-z]{2,})', '\1 \2', 'g');
  -- twice, for words with two hyphens
  r := regexp_replace(r, '([A-Za-z]+)-([A-Za-z]+)', '\1 \2', 'g');
  r := regexp_replace(r, '([A-Za-z]+)-([A-Za-z]+)', '\1 \2', 'g');
  return r;
end $f$;

-- display text inside JSON: only these keys are words people read; everything else (matching values) is left alone
create or replace function public.zella_plain_json(j jsonb) returns jsonb
language plpgsql immutable set search_path = public as $f$
declare k text; v jsonb; out jsonb; i int;
begin
  if j is null then return null; end if;
  if jsonb_typeof(j) = 'object' then
    out := '{}'::jsonb;
    for k, v in select * from jsonb_each(j) loop
      if jsonb_typeof(v) = 'string' and k in ('title', 'message', 'body', 'label', 'notice', 'plural', 'singular') then
        out := out || jsonb_build_object(k, public.zella_plain_words(v #>> '{}'));
      elsif k in ('options', 'service') then
        out := out || jsonb_build_object(k, v);
      else
        out := out || jsonb_build_object(k, public.zella_plain_json(v));
      end if;
    end loop;
    return out;
  elsif jsonb_typeof(j) = 'array' then
    out := '[]'::jsonb;
    for i in 0 .. jsonb_array_length(j) - 1 loop out := out || jsonb_build_array(public.zella_plain_json(j -> i)); end loop;
    return out;
  end if;
  return j;
end $f$;
revoke all on function public.zella_plain_words(text) from public, anon;
revoke all on function public.zella_plain_json(jsonb) from public, anon;

-- 1. phrases inside database functions
do $$
declare f record; d text; sigs text[];
begin
  create temp table _p (sig text, old text, new text) on commit drop;
  insert into _p values
    ('public.zella_admin_message_retry_check(text,uuid)', $t$It isn''t linked to a reminder or follow-up Zella can resend safely$t$, $t$It isn''t linked to a reminder or follow up Zella Voice can resend safely$t$),
    ('public.zella_admin_message_retry_check(text,uuid)', $t$(no consent, opt-out or spam rule)$t$, $t$(no consent, opt out or spam rule)$t$),
    ('public.zella_admin_message_retry_check(text,uuid)', $t$'Its follow-up is '$t$, $t$'Its follow up is '$t$),
    ('public.zella_admin_message_retry_check(text,uuid)', $t$Its follow-up no longer exists.$t$, $t$Its follow up no longer exists.$t$),
    ('public.zella_admin_run_retry_check(text,uuid)', $t$In-database automation runs retry themselves$t$, $t$Automation runs inside the database retry themselves$t$),
    ('public.zella_ai_tool(text,uuid,text,jsonb,text)', $t$Ask the caller what the follow-up is for.$t$, $t$Ask the caller what the follow up is for.$t$),
    ('public.zella_apply_industry_defaults(uuid)', $t$'Missed-call follow-up'$t$, $t$'Missed call follow up'$t$),
    ('public.zella_apply_industry_defaults(uuid)', $t$'New-lead callback'$t$, $t$'New lead callback'$t$),
    ('public.zella_apply_industry_defaults(uuid)', $t$'No-show follow-up'$t$, $t$'No show follow up'$t$),
    ('public.zella_apply_industry_defaults(uuid)', $t$'Post-appointment follow-up'$t$, $t$'Follow up after the appointment'$t$),
    ('public.zella_apply_industry_defaults(uuid)', $t$'Quote follow-up'$t$, $t$'Quote follow up'$t$),
    ('public.zella_brain_tool_defs()', $t$said yes to the read-back$t$, $t$said yes after hearing it read back$t$),
    ('public.zella_business_lifecycle_trigger()', $t$Calls, texts and follow-ups are stopped.$t$, $t$Calls, texts and follow ups are stopped.$t$),
    ('public.zella_capability_catalog()', $t$"Front-desk check-ins"$t$, $t$"Front desk check ins"$t$),
    ('public.zella_check_engine_health()', $t$'Follow-ups are waiting'$t$, $t$'Follow ups are waiting'$t$),
    ('public.zella_check_kpis()', $t$'No-shows and cancellations are up'$t$, $t$'No shows and cancellations are up'$t$),
    ('public.zella_flag_unrecorded_appointments()', $t$Mark completed or no-show$t$, $t$Mark completed or no show$t$),
    ('public.zella_message_policy_trg()', $t$Booking follow-ups are off for this business.$t$, $t$Booking follow ups are off for this business.$t$),
    ('public.zella_message_policy_trg()', $t$They already had an after-visit check-in.$t$, $t$They already had a check in after their visit.$t$),
    ('public.zella_offer_problems(offers)', $t$A business-size offer needs a "business size" rule.$t$, $t$An offer for a business size needs a "business size" rule.$t$),
    ('public.zella_offer_problems(offers)', $t$A business-specific offer needs a "business" rule.$t$, $t$An offer for one business needs a "business" rule.$t$),
    ('public.zella_on_call_reminders()', $t$After-hours calls for this business will ring your phone until $t$, $t$After hours calls for this business will ring your phone until $t$),
    ('public.zella_on_call_reminders()', $t$After-hours calls go to $t$, $t$After hours calls go to $t$),
    ('public.zella_public_status()', $t$'Reminders and follow-ups'$t$, $t$'Reminders and follow ups'$t$),
    ('public.zella_reconcile()', $t$Mark them completed or no-show so reports and follow-ups are right.$t$, $t$Mark them completed or no show so reports and follow ups are right.$t$),
    ('public.zella_recover_orphaned_work()', $t$'Follow-up tasks were stuck'$t$, $t$'Follow up tasks were stuck'$t$),
    ('public.zella_sample_ai_responses()', $t$ to spot-check$t$, $t$ to check$t$),
    ('public.zella_save_call_insight(uuid,jsonb)', $t$'Call follow-up: '$t$, $t$'Call follow up: '$t$),
    ('public.zella_spam_finish_work(uuid,uuid,jsonb)', $t$'Repeated high-risk '$t$, $t$'Repeated high risk '$t$),
    ('public.zella_spam_record(uuid,text,text,text,text,uuid,text,uuid,jsonb)', $t$Automatic temporary restriction after high-risk activity$t$, $t$Automatic temporary restriction after high risk activity$t$),
    ('public.zella_verify_calls()', $t$The call-result workflow may be failing.$t$, $t$The call result workflow may be failing.$t$),
    ('public.zella_cross_sell_ideas(text)', $t$"blow-dry"$t$, $t$"blow dry"$t$),
    ('public.zella_cross_sell_ideas(text)', $t$"seasonal clean-up"$t$, $t$"seasonal clean up"$t$);
  select array_agg(distinct sig) into sigs from _p;
  for f in select unnest(sigs) as sig loop
    if to_regprocedure(f.sig) is null then raise exception 'VERSION_MISMATCH: % is missing', f.sig; end if;
    d := pg_get_functiondef(f.sig::regprocedure);
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_writing_cleanup', f.sig, d, md5(d)) on conflict (migration, signature) do nothing;
    declare r record; begin
      for r in select * from _p p where p.sig = f.sig loop
        if position(r.old in d) > 0 then d := replace(d, r.old, r.new);
        elsif position(r.new in d) = 0 then raise exception 'VERSION_MISMATCH: % does not contain the text this file expects (%)', f.sig, left(r.old, 40);
        end if;
      end loop;
    end;
    execute d;
  end loop;
end $$;

-- 2. stored text people read (each changed value archived first)
do $$
declare t record; v_changed int;
begin
  for t in select * from (values
      ('industries', 'id', 'name'), ('industry_modules', 'id', 'name'), ('industry_modules', 'id', 'description'),
      ('automations', 'id', 'name'), ('automations', 'id', 'description'),
      ('industry_automation_presets', 'id', 'name'), ('industry_automation_presets', 'id', 'description'),
      ('industry_message_policy', 'industry_key', 'reason')) x(tbl, keycol, col) loop
    execute format('lock table public.%I in share row exclusive mode', t.tbl);
    execute format('insert into public.zella_text_archive (migration, tbl, row_key, col, old_value)
                    select ''zella_writing_cleanup'', %L, %I::text, %L, %I from public.%I
                     where %I is distinct from public.zella_plain_words(%I)
                    on conflict (migration, tbl, row_key, col) do nothing', t.tbl, t.keycol, t.col, t.col, t.tbl, t.col, t.col);
    execute format('update public.%I set %I = public.zella_plain_words(%I) where %I is distinct from public.zella_plain_words(%I)',
                   t.tbl, t.col, t.col, t.col, t.col);
  end loop;
  for t in select * from (values
      ('automations', 'id', 'trigger_config'), ('industry_automation_presets', 'id', 'trigger_config'), ('industry_crm_presets', 'key', 'config')) x(tbl, keycol, col) loop
    execute format('lock table public.%I in share row exclusive mode', t.tbl);
    execute format('insert into public.zella_text_archive (migration, tbl, row_key, col, old_value)
                    select ''zella_writing_cleanup'', %L, %I::text, %L, %I::text from public.%I
                     where %I is distinct from public.zella_plain_json(%I)
                    on conflict (migration, tbl, row_key, col) do nothing', t.tbl, t.keycol, t.col, t.col, t.tbl, t.col, t.col);
    execute format('update public.%I set %I = public.zella_plain_json(%I) where %I is distinct from public.zella_plain_json(%I)',
                   t.tbl, t.col, t.col, t.col, t.col);
  end loop;
end $$;

commit;
