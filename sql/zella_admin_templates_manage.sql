-- Zella Voice: platform message templates can be created and retired, audited (docs/ADMIN_AUDIT_2026-11-16.md UI-20,
-- COM-27).
-- Messaging, Templates could only edit: zella_admin_template_save archives a version and adds the next. Now, for admins
-- with comms.manage, a reason required and every change audited:
--   * zella_admin_template_create(p_key, p_channel, p_industry, p_locale, p_subject, p_body, p_reason) makes an
--     industry version or another language version of a key that already has a platform version, because senders
--     only ever send existing keys (business, then industry, then platform: zella_resolve_template). Same checks as
--     saving: length, email subject, script guard, STOP for marketing texts, known variables (comms.template_created);
--   * zella_admin_template_retire(p_id, p_reason) archives an industry or other language version, so senders fall back
--     to the platform version; the English platform version a sender uses can't be retired (comms.template_retired);
--   * zella_admin_template_save's script guard is case insensitive and covers the subject too (COM-27: <SCRIPT got
--     through); nothing else in it changes.
-- zella_admin_template_save is archived first and must match production's version (the same before and after every
-- merged migration), otherwise VERSION_MISMATCH. Rollback: sql/rollback/zella_admin_templates_manage_rollback.sql
begin;

do $$
declare s constant text := 'public.zella_admin_template_save(uuid,text,text,text)'; d text; f record;
begin
  if to_regprocedure(s) is null or to_regclass('public.zella_function_archive') is null
     or to_regprocedure('public.zella_admin_template_variables(text,text)') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  d := pg_get_functiondef(s::regprocedure);
  if md5(d) = 'bab3d1281f36ad1f5da6c31fd4ac5008' then
    insert into public.zella_function_archive (migration, signature, definition, definition_md5)
    values ('zella_admin_templates_manage', s, d, md5(d)) on conflict (migration, signature) do nothing;
  elsif md5(d) <> 'f450f6f47333d8198151ae5c5d33523c' then
    raise exception 'VERSION_MISMATCH: % is not a version this file was written for', s;
  end if;
  for f in select * from (values
      ('public.zella_admin_template_create(text,text,uuid,text,text,text,text)', 'f28fd02113f908cd6f5fee54f274ca19'),
      ('public.zella_admin_template_retire(uuid,text)', '22bbf6bbbb86b0d57932599e220f9171')) as t(sig, want) loop
    if to_regprocedure(f.sig) is not null and md5(pg_get_functiondef(to_regprocedure(f.sig))) <> f.want then
      raise exception 'VERSION_MISMATCH: % is not a version this file was written for', f.sig;
    end if;
  end loop;
end $$;

CREATE OR REPLACE FUNCTION public.zella_admin_template_save(p_id uuid, p_subject text, p_body text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare t public.message_templates; v_reason text := public.zella_admin_reason(p_reason); v_allowed text[]; v_bad text[]; v_new uuid;
        v_body text := trim(coalesce(p_body, '')); v_subject text := nullif(trim(coalesce(p_subject, '')), '');
begin
  perform public.zella_admin_require('comms.manage');
  select * into t from public.message_templates where id = p_id for update;
  if t.id is null or t.status <> 'active' then raise exception 'NOT_FOUND'; end if;
  if t.business_id is not null then raise exception 'BUSINESS_TEMPLATE'; end if;
  if length(v_body) < 1 or length(v_body) > 1600 then raise exception 'BODY_LENGTH'; end if;
  if t.channel = 'email' and v_subject is null then raise exception 'SUBJECT_REQUIRED'; end if;
  -- zella_admin_templates_manage: any case, in the subject too (COM-27)
  if (v_body || ' ' || coalesce(v_subject, '')) ~* '<script|javascript:' then raise exception 'BODY_TEXT'; end if;
  if t.channel = 'sms' and t.purpose = 'marketing' and v_body !~* 'stop' then raise exception 'SMS_NEEDS_STOP'; end if;
  v_allowed := public.zella_admin_template_variables(t.key, t.channel);
  select array_agg(distinct v) into v_bad from (select (regexp_matches(v_body || ' ' || coalesce(v_subject, ''), '\{\{\s*([^}]*?)\s*\}\}', 'g'))[1] v) x
   where not (v = any (v_allowed));
  if v_bad is not null then raise exception 'UNKNOWN_VARIABLES: %', array_to_string(v_bad, ', '); end if;
  if v_body = t.body and v_subject is not distinct from t.subject then raise exception 'NO_CHANGE'; end if;
  update public.message_templates set status = 'archived' where id = t.id;
  insert into public.message_templates (business_id, industry_id, key, channel, purpose, locale, subject, body, version, status, created_by)
  values (null, t.industry_id, t.key, t.channel, t.purpose, t.locale, case when t.channel = 'email' then v_subject end, v_body,
          (select coalesce(max(version), 0) + 1 from public.message_templates where business_id is null and industry_id is not distinct from t.industry_id
             and key = t.key and channel = t.channel and locale = t.locale), 'active', auth.uid())
  returning id into v_new;
  perform public.zella_admin_audit('comms.template_updated', 'message_template', v_new, null,
    jsonb_build_object('id', t.id, 'key', t.key, 'channel', t.channel, 'version', t.version, 'subject', t.subject, 'body', t.body),
    jsonb_build_object('key', t.key, 'channel', t.channel, 'subject', v_subject, 'body', v_body, 'reason', v_reason));
  return jsonb_build_object('id', v_new, 'key', t.key, 'channel', t.channel);
end $function$;

CREATE OR REPLACE FUNCTION public.zella_admin_template_create(p_key text, p_channel text, p_industry uuid, p_locale text, p_subject text, p_body text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare base public.message_templates; v_reason text := public.zella_admin_reason(p_reason); v_allowed text[]; v_bad text[]; v_new uuid;
        v_locale text := coalesce(nullif(trim(p_locale), ''), 'en-US');
        v_body text := trim(coalesce(p_body, '')); v_subject text := nullif(trim(coalesce(p_subject, '')), '');
begin
  perform public.zella_admin_require('comms.manage');
  if v_locale not in ('en-US', 'es-US') then raise exception 'LOCALE'; end if;
  -- only a key senders already use: it must have an active platform version on this channel
  select * into base from public.message_templates where key = p_key and channel = p_channel and business_id is null and industry_id is null
     and status = 'active' order by (locale = 'en-US') desc, version desc limit 1;
  if base.id is null then raise exception 'NO_PLATFORM_VERSION'; end if;
  if p_industry is null and v_locale = base.locale then raise exception 'ALREADY_EXISTS'; end if;
  if p_industry is not null and not exists (select 1 from public.industries where id = p_industry) then raise exception 'INDUSTRY_NOT_FOUND'; end if;
  if exists (select 1 from public.message_templates where business_id is null and industry_id is not distinct from p_industry and key = p_key
               and channel = p_channel and locale = v_locale and status = 'active') then
    raise exception 'ALREADY_EXISTS';
  end if;
  if length(v_body) < 1 or length(v_body) > 1600 then raise exception 'BODY_LENGTH'; end if;
  if p_channel = 'email' and v_subject is null then raise exception 'SUBJECT_REQUIRED'; end if;
  if (v_body || ' ' || coalesce(v_subject, '')) ~* '<script|javascript:' then raise exception 'BODY_TEXT'; end if;
  if p_channel = 'sms' and base.purpose = 'marketing' and v_body !~* 'stop' then raise exception 'SMS_NEEDS_STOP'; end if;
  v_allowed := public.zella_admin_template_variables(p_key, p_channel);
  select array_agg(distinct v) into v_bad from (select (regexp_matches(v_body || ' ' || coalesce(v_subject, ''), '\{\{\s*([^}]*?)\s*\}\}', 'g'))[1] v) x
   where not (v = any (v_allowed));
  if v_bad is not null then raise exception 'UNKNOWN_VARIABLES: %', array_to_string(v_bad, ', '); end if;
  insert into public.message_templates (business_id, industry_id, key, channel, purpose, locale, subject, body, version, status, created_by)
  values (null, p_industry, p_key, p_channel, base.purpose, v_locale, case when p_channel = 'email' then v_subject end, v_body,
          (select coalesce(max(version), 0) + 1 from public.message_templates where business_id is null and industry_id is not distinct from p_industry
             and key = p_key and channel = p_channel and locale = v_locale), 'active', auth.uid())
  returning id into v_new;
  perform public.zella_admin_audit('comms.template_created', 'message_template', v_new, null, null,
    jsonb_build_object('key', p_key, 'channel', p_channel, 'industry_id', p_industry, 'locale', v_locale, 'subject', v_subject, 'body', v_body, 'reason', v_reason));
  return jsonb_build_object('id', v_new, 'key', p_key, 'channel', p_channel, 'locale', v_locale, 'industry_id', p_industry);
end
$function$;

CREATE OR REPLACE FUNCTION public.zella_admin_template_retire(p_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare t public.message_templates; v_reason text := public.zella_admin_reason(p_reason);
begin
  perform public.zella_admin_require('comms.manage');
  select * into t from public.message_templates where id = p_id for update;
  if t.id is null or t.status <> 'active' then raise exception 'NOT_FOUND'; end if;
  if t.business_id is not null then raise exception 'BUSINESS_TEMPLATE'; end if;
  -- the English platform version is what every sender falls back to
  if t.industry_id is null and t.locale = 'en-US' then raise exception 'PLATFORM_BASE'; end if;
  update public.message_templates set status = 'archived' where id = t.id;
  perform public.zella_admin_audit('comms.template_retired', 'message_template', t.id, null,
    jsonb_build_object('key', t.key, 'channel', t.channel, 'industry_id', t.industry_id, 'locale', t.locale, 'version', t.version, 'subject', t.subject, 'body', t.body),
    jsonb_build_object('status', 'archived', 'reason', v_reason));
  return jsonb_build_object('id', t.id, 'key', t.key, 'channel', t.channel, 'status', 'archived');
end
$function$;

revoke all on function public.zella_admin_template_create(text, text, uuid, text, text, text, text) from public, anon;
revoke all on function public.zella_admin_template_retire(uuid, text) from public, anon;
grant execute on function public.zella_admin_template_create(text, text, uuid, text, text, text, text) to authenticated;
grant execute on function public.zella_admin_template_retire(uuid, text) to authenticated;

commit;
