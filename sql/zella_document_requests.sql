-- Zella Voice: Request documents (Verification, Missing documents, UI-11) in one database step.
-- Before: owner-provision-business read the last request from the audit log, queued email S4 and wrote the audit row
-- in separate calls, so two requests at once could both pass the once a day check, and a failed audit write left no
-- record for the next check.
-- Now zella_request_documents(p_business, p_actor, p_missing, p_cooldown_hours, p_to, p_subject, p_html, p_text), server
-- only, does it as one transaction under the business row lock: refuses (TOO_SOON, with the last request's time) a
-- request inside the wait, queues S4 in the platform outbox when it is installed and an address is given, and writes
-- the business.documents_requested audit row; if any part fails, none of it happens. The server renders the email.
-- Nothing existing is replaced. The function must be absent or exactly this file's version, otherwise
-- VERSION_MISMATCH. Rollback: sql/rollback/zella_document_requests_rollback.sql
begin;

do $$
begin
  if to_regclass('public.businesses') is null or to_regclass('public.audit_logs') is null then
    raise exception 'VERSION_MISMATCH: something this file needs is missing';
  end if;
  if to_regprocedure('public.zella_request_documents(uuid,uuid,text[],integer,text,text,text,text)') is not null
     and md5(pg_get_functiondef(to_regprocedure('public.zella_request_documents(uuid,uuid,text[],integer,text,text,text,text)'))) <> '2d17e7456746cc5d9796f73806e6267f' then
    raise exception 'VERSION_MISMATCH: zella_request_documents is not a version this file was written for';
  end if;
end $$;

CREATE OR REPLACE FUNCTION public.zella_request_documents(p_business uuid, p_actor uuid, p_missing text[], p_cooldown_hours integer,
  p_to text, p_subject text, p_html text, p_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_last timestamptz; v_email text := 'no_address'; v_id uuid;
begin
  if p_business is null or cardinality(coalesce(p_missing, '{}')) = 0 or coalesce(p_cooldown_hours, 0) < 1 then raise exception 'INVALID_INPUT'; end if;
  -- one request at a time per business: the next one waits here, then sees this one's audit row
  perform 1 from businesses where id = p_business and cancelled_at is null for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  select max(created_at) into v_last from audit_logs where business_id = p_business and action = 'business.documents_requested';
  if v_last is not null and v_last > now() - make_interval(hours => p_cooldown_hours) then
    raise exception using message = 'TOO_SOON', detail = to_char(v_last at time zone 'UTC', 'YYYY-MM-DD HH24:MI');
  end if;
  if nullif(btrim(coalesce(p_to, '')), '') is not null then
    if to_regprocedure('public.zella_queue_platform_email(uuid,text,text,text,text,text,text,boolean,uuid,text[])') is null then
      v_email := 'not_installed';
    else
      v_id := public.zella_queue_platform_email(p_business, 'S4', 'email:S4:' || p_business || ':' || gen_random_uuid(), lower(btrim(p_to)),
                                                p_subject, p_html, p_text, true, null, '{}');
      v_email := 'queued';
    end if;
  end if;
  insert into audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (p_business, p_actor, 'business.documents_requested', 'business', p_business,
          jsonb_build_object('missing', to_jsonb(p_missing), 'email', v_email, 'email_id', v_id));
  return jsonb_build_object('email', v_email, 'email_id', v_id, 'previous', v_last);
end
$function$;

revoke all on function public.zella_request_documents(uuid, uuid, text[], integer, text, text, text, text) from public, anon, authenticated;
grant execute on function public.zella_request_documents(uuid, uuid, text[], integer, text, text, text, text) to service_role;

commit;
