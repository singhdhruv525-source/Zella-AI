-- Unified inbox: unread tracking, priority, internal notes, AI-to-human
-- handover, and staff replies. Replies are saved as queued messages and
-- are only accepted when the person hasn't opted out of that channel.
-- The browser calls these functions; it never writes message tables directly.

alter table public.conversations add column if not exists priority text not null default 'normal';
alter table public.conversations add column if not exists last_read_at timestamptz;
alter table public.conversations add column if not exists last_inbound_at timestamptz;
alter table public.conversations add column if not exists handover_at timestamptz;
do $$ begin
  alter table public.conversations add constraint conversations_priority_chk check (priority in ('normal', 'high', 'urgent'));
exception when duplicate_object then null; end $$;

-- Keep the conversation's "last message" and "last customer message" current.
create or replace function public.zella_conversation_touch() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.conversations
     set last_message_at = greatest(coalesce(last_message_at, new.created_at), new.created_at),
         last_inbound_at = case when new.sender_type = 'customer' then greatest(coalesce(last_inbound_at, new.created_at), new.created_at) else last_inbound_at end,
         updated_at = now()
   where id = new.conversation_id;
  return new;
end $$;
drop trigger if exists zella_conversation_touch on public.conversation_messages;
create trigger zella_conversation_touch after insert on public.conversation_messages
  for each row execute function public.zella_conversation_touch();

create table if not exists public.conversation_notes (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  author_id uuid,
  author_name text,
  body text not null check (length(trim(body)) > 0),
  created_at timestamptz not null default now()
);
create index if not exists conversation_notes_conv_idx on public.conversation_notes (conversation_id, created_at);
alter table public.conversation_notes enable row level security;
drop policy if exists "members read conversation notes" on public.conversation_notes;
create policy "members read conversation notes" on public.conversation_notes for select using (public.is_business_member(business_id));

create or replace function public.zella_inbox_conv(p_id uuid) returns public.conversations
language plpgsql stable security definer set search_path = public as $$
declare c public.conversations;
begin
  select * into c from public.conversations where id = p_id;
  if not found or not public.zella_is_member(c.business_id) then raise exception 'NOT_ALLOWED'; end if;
  return c;
end $$;

create or replace function public.zella_inbox_mark_read(p_conversation_id uuid, p_read boolean default true) returns boolean
language plpgsql security definer set search_path = public as $$
declare c public.conversations;
begin
  c := public.zella_inbox_conv(p_conversation_id);
  update public.conversations
     set last_read_at = case when p_read then now() else null end
   where id = p_conversation_id;
  return true;
end $$;

-- Assign, set priority, or open/close. Pass p_unassign to clear the owner.
create or replace function public.zella_inbox_update(p_conversation_id uuid, p_assign_to uuid default null, p_priority text default null, p_status text default null, p_unassign boolean default false) returns boolean
language plpgsql security definer set search_path = public as $$
declare c public.conversations;
begin
  c := public.zella_inbox_conv(p_conversation_id);
  if p_priority is not null and p_priority not in ('normal', 'high', 'urgent') then raise exception 'BAD_PRIORITY'; end if;
  if p_status is not null and p_status not in ('open', 'pending', 'closed') then raise exception 'BAD_STATUS'; end if;
  if p_assign_to is not null and not exists (select 1 from public.business_members where business_id = c.business_id and user_id = p_assign_to and status = 'active') then
    raise exception 'NOT_A_MEMBER';
  end if;
  update public.conversations
     set assigned_to = case when p_unassign then null else coalesce(p_assign_to, assigned_to) end,
         priority = coalesce(p_priority, priority),
         status = coalesce(p_status, status),
         updated_at = now()
   where id = p_conversation_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, old_data, new_data)
  values (c.business_id, auth.uid(), 'inbox.updated', 'conversation', p_conversation_id,
          jsonb_build_object('assigned_to', c.assigned_to, 'priority', c.priority, 'status', c.status),
          jsonb_build_object('assigned_to', case when p_unassign then null else coalesce(p_assign_to, c.assigned_to) end, 'priority', coalesce(p_priority, c.priority), 'status', coalesce(p_status, c.status)));
  return true;
end $$;

create or replace function public.zella_inbox_add_note(p_conversation_id uuid, p_body text) returns boolean
language plpgsql security definer set search_path = public as $$
declare c public.conversations; v_name text;
begin
  c := public.zella_inbox_conv(p_conversation_id);
  if nullif(trim(coalesce(p_body, '')), '') is null then raise exception 'NOTE_REQUIRED'; end if;
  select coalesce(nullif(trim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')), ''), 'Team member') into v_name from public.profiles where id = auth.uid();
  insert into public.conversation_notes (business_id, conversation_id, author_id, author_name, body)
  values (c.business_id, p_conversation_id, auth.uid(), coalesce(v_name, 'Team member'), trim(p_body));
  return true;
end $$;

-- A person takes over from the AI receptionist (or hands the conversation back).
create or replace function public.zella_inbox_handover(p_conversation_id uuid, p_to_ai boolean default false, p_assign_to uuid default null) returns boolean
language plpgsql security definer set search_path = public as $$
declare c public.conversations;
begin
  c := public.zella_inbox_conv(p_conversation_id);
  if p_assign_to is not null and not exists (select 1 from public.business_members where business_id = c.business_id and user_id = p_assign_to and status = 'active') then
    raise exception 'NOT_A_MEMBER';
  end if;
  if p_to_ai then
    update public.conversations set ai_handled = true, handover_at = null, updated_at = now() where id = p_conversation_id;
  else
    update public.conversations set ai_handled = false, handover_at = now(), status = 'open',
           assigned_to = coalesce(p_assign_to, assigned_to, auth.uid()), updated_at = now() where id = p_conversation_id;
  end if;
  insert into public.conversation_messages (conversation_id, sender_type, message_type, content)
  values (p_conversation_id, 'system', 'text', case when p_to_ai then 'Handed back to the AI receptionist.' else 'A team member took over from the AI receptionist.' end);
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (c.business_id, auth.uid(), case when p_to_ai then 'inbox.returned_to_ai' else 'inbox.handover' end, 'conversation', p_conversation_id, jsonb_build_object('assigned_to', p_assign_to));
  return true;
end $$;

-- A team member's reply. It is queued for sending; opt-outs are respected.
create or replace function public.zella_inbox_reply(p_conversation_id uuid, p_body text, p_subject text default null) returns text
language plpgsql security definer set search_path = public as $$
declare c public.conversations; p public.customers; v_biz public.businesses; v_msg uuid;
begin
  c := public.zella_inbox_conv(p_conversation_id);
  if nullif(trim(coalesce(p_body, '')), '') is null then raise exception 'MESSAGE_REQUIRED'; end if;
  if c.channel not in ('sms', 'email') then raise exception 'CHANNEL_NOT_SUPPORTED'; end if;
  if c.customer_id is null then raise exception 'NO_RECIPIENT'; end if;
  select * into p from public.customers where id = c.customer_id;
  if coalesce(p.do_not_contact, false) or (c.channel = 'sms' and coalesce(p.do_not_sms, false)) or (c.channel = 'email' and coalesce(p.do_not_email, false)) then
    raise exception 'OPTED_OUT';
  end if;
  if c.channel = 'sms' then
    if nullif(trim(coalesce(p.phone, '')), '') is null then raise exception 'NO_RECIPIENT'; end if;
    select * into v_biz from public.businesses where id = c.business_id;
    insert into public.sms_messages (business_id, customer_id, conversation_id, direction, status, from_number, to_number, message_body)
    values (c.business_id, p.id, c.id, 'outbound', 'queued', coalesce(v_biz.phone, ''), p.phone, trim(p_body));
  else
    if nullif(trim(coalesce(p.email, '')), '') is null then raise exception 'NO_RECIPIENT'; end if;
    insert into public.email_messages (business_id, customer_id, conversation_id, direction, status, from_email, to_email, subject, body_text)
    values (c.business_id, p.id, c.id, 'outbound', 'queued', '', p.email, coalesce(nullif(trim(p_subject), ''), c.subject, 'Re: your message'), trim(p_body));
  end if;
  insert into public.conversation_messages (conversation_id, sender_type, message_type, content, metadata)
  values (c.id, 'agent', 'text', trim(p_body), jsonb_build_object('sent_by', auth.uid(), 'delivery', 'queued'))
  returning id into v_msg;
  update public.conversations set ai_handled = false, handover_at = coalesce(handover_at, now()), last_read_at = now(),
         assigned_to = coalesce(assigned_to, auth.uid()), status = 'open', updated_at = now() where id = c.id;
  return 'queued';
end $$;

revoke all on function public.zella_inbox_conv(uuid) from public, anon, authenticated;
revoke all on function public.zella_inbox_mark_read(uuid, boolean) from public, anon;
revoke all on function public.zella_inbox_update(uuid, uuid, text, text, boolean) from public, anon;
revoke all on function public.zella_inbox_add_note(uuid, text) from public, anon;
revoke all on function public.zella_inbox_handover(uuid, boolean, uuid) from public, anon;
revoke all on function public.zella_inbox_reply(uuid, text, text) from public, anon;
grant execute on function public.zella_inbox_mark_read(uuid, boolean) to authenticated, service_role;
grant execute on function public.zella_inbox_update(uuid, uuid, text, text, boolean) to authenticated, service_role;
grant execute on function public.zella_inbox_add_note(uuid, text) to authenticated, service_role;
grant execute on function public.zella_inbox_handover(uuid, boolean, uuid) to authenticated, service_role;
grant execute on function public.zella_inbox_reply(uuid, text, text) to authenticated, service_role;
