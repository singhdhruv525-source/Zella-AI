-- Zella - social reply window and WhatsApp templates (checklist 118, 119, 120). Safe to run more than once. Needs zella_meta.sql.
-- Facebook, Instagram and WhatsApp only let a business send free-form replies within 24 hours of the customer's last message.
--   * An automatic reply that arrives after the window closes is dropped, and the team is told (instead of silence).
--   * On WhatsApp a team member can still reach the customer with an approved template (zella_meta_staff_template).
alter table public.meta_outbox add column if not exists template_language text;

-- 1. Tell the team when a reply could not go out because the window closed.
do $$
declare d text;
begin
  d := pg_get_functiondef('public.zella_meta_claim_outbox(integer)'::regprocedure);
  if d not like '%window_closed_notice%' then
    d := replace(d, E'case when o.channel = ''whatsapp'' then ''template_required'' else ''window_closed'' end where id = o.id; continue;',
      E'case when o.channel = ''whatsapp'' then ''template_required'' else ''window_closed'' end where id = o.id;\n        perform public.zella_notify_owners(o.business_id, ''social_window_closed'', ''A reply could not be sent'',\n          case when o.channel = ''whatsapp'' then ''The 24-hour WhatsApp window has closed. Send an approved template, or call the customer.'' else ''The 24-hour reply window has closed. Contact the customer another way.'' end, ''info'', ''inbox''); -- window_closed_notice\n        continue;');
    d := replace(d, '''whatsapp_phone_id'', c.whatsapp_phone_id));', '''whatsapp_phone_id'', c.whatsapp_phone_id, ''template_name'', o.template_name, ''template_language'', o.template_language));');
    if d not like '%window_closed_notice%' or d not like '%template_language%' then raise exception 'PATCH_FAILED_CLAIM'; end if;
    execute d;
  end if;
end $$;

-- 2. A team member sends an approved WhatsApp template (no fill-in values) when the window is closed.
create or replace function public.zella_meta_staff_template(p_conversation_id uuid, p_template_name text) returns uuid
language plpgsql security definer set search_path = public as $$
declare cv public.conversations%rowtype; ct public.meta_contacts%rowtype; c public.meta_connections%rowtype; t public.meta_templates%rowtype; v_id uuid;
begin
  select * into cv from public.conversations where id = p_conversation_id;
  if not found or not public.zella_has_role(cv.business_id, array['owner','admin','manager','staff']) then raise exception 'NOT_ALLOWED'; end if;
  if cv.channel <> 'whatsapp' then raise exception 'NOT_A_WHATSAPP_CONVERSATION'; end if;
  select * into t from public.meta_templates where business_id = cv.business_id and name = p_template_name and upper(status) = 'APPROVED' order by synced_at desc limit 1;
  if t.id is null then raise exception 'TEMPLATE_NOT_APPROVED'; end if;
  if t.body is null or t.body ~ '\{\{' or t.name !~ '^[a-z0-9_]{1,200}$' or t.language !~ '^[a-z]{2}(_[A-Z]{2})?$' then raise exception 'TEMPLATE_HAS_VALUES'; end if;
  select * into ct from public.meta_contacts where conversation_id = cv.id limit 1;
  select * into c from public.meta_connections where business_id = cv.business_id and status = 'connected' order by created_at limit 1;
  if ct.id is null or c.id is null then raise exception 'NOT_CONNECTED'; end if;
  insert into public.meta_outbox (business_id, page_id, channel, kind, recipient, text_body, template_name, template_language, conversation_id)
  values (cv.business_id, c.page_id, 'whatsapp', 'template', ct.external_id, left(t.body, 1000), t.name, t.language, cv.id) returning id into v_id;
  insert into public.conversation_messages (conversation_id, sender_type, message_type, content, metadata)
  values (cv.id, 'agent', 'text', left(t.body, 1000), jsonb_build_object('channel', 'whatsapp', 'template', t.name, 'user_id', auth.uid()));
  update public.conversations set assigned_to = coalesce(assigned_to, auth.uid()), ai_handled = false, handover_at = coalesce(handover_at, now()), updated_at = now() where id = cv.id;
  return v_id;
end $$;
revoke execute on function public.zella_meta_staff_template(uuid, text) from public, anon;
grant execute on function public.zella_meta_staff_template(uuid, text) to authenticated, service_role;
