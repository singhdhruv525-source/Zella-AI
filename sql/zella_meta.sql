-- Zella - Meta (Facebook, Instagram Messenger/DMs, WhatsApp Business). Safe to run more than once.
-- Needs zella_run_all.sql, zella_inbox.sql, zella_assignment.sql, zella_lead_capture.sql, zella_ops_extras.sql (zella_has_role).
-- Supabase makes every decision; n8n only answers Meta's webhook, fetches a lead's details, sends replies and checks the connection.
--   * Meta's webhook signature is checked here (app secret in Vault: zella_meta_app_secret). A wrong signature changes nothing.
--   * A lead ad form submission becomes a customer + a "new lead" callback (the AI receptionist calls it with the normal
--     retry rules) ONLY when the form carries consent, or the owner confirmed their form has it. Otherwise the team is told.
--   * Messenger / Instagram / WhatsApp messages land in the inbox on the customer's record, are assigned, and the team is
--     alerted. Replies are queued and sent within Meta's 24 hour window (WhatsApp needs an approved template after that).
--   * Comments that match the owner's own keywords get one private reply.
--   * The page token lives in Vault; connection health, permissions and failed fetches raise alerts and retry.

create table if not exists public.meta_connections (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  page_id text not null unique,
  page_name text,
  instagram_id text,
  whatsapp_phone_id text,
  waba_id text,
  status text not null default 'connected' check (status in ('connected','needs_reconnect','error','disconnected')),
  token_secret text,
  granted_permissions text[] not null default '{}',
  call_consent_confirmed boolean not null default false,
  auto_acknowledge boolean not null default true,
  comment_keywords text[] not null default '{}',
  last_checked_at timestamptz,
  next_check_at timestamptz not null default now(),
  last_error text,
  created_at timestamptz not null default now()
);
create index if not exists meta_connections_biz_idx on public.meta_connections (business_id);
alter table public.meta_connections enable row level security;
drop policy if exists meta_connections_read on public.meta_connections;
create policy meta_connections_read on public.meta_connections for select to authenticated using (public.zella_is_member(business_id));

create table if not exists public.meta_contacts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  channel text not null check (channel in ('messenger','instagram','whatsapp')),
  external_id text not null,
  display_name text,
  customer_id uuid references public.customers(id) on delete set null,
  conversation_id uuid references public.conversations(id) on delete set null,
  last_ack_at timestamptz,
  created_at timestamptz not null default now(),
  unique (business_id, channel, external_id)
);
alter table public.meta_contacts enable row level security;
revoke all on public.meta_contacts from anon, authenticated;

create table if not exists public.meta_events (
  id uuid primary key default gen_random_uuid(),
  event_key text not null unique,
  kind text not null check (kind in ('lead','message','comment')),
  page_id text,
  business_id uuid references public.businesses(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','processing','done','failed','ignored')),
  payload jsonb not null default '{}'::jsonb,
  attempts integer not null default 0,
  next_try_at timestamptz not null default now(),
  last_error text,
  claimed_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists meta_events_due_idx on public.meta_events (status, next_try_at);
alter table public.meta_events enable row level security;
revoke all on public.meta_events from anon, authenticated;

create table if not exists public.meta_outbox (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  page_id text not null,
  channel text not null check (channel in ('messenger','instagram','whatsapp')),
  kind text not null default 'message' check (kind in ('message','private_reply','template')),
  recipient text not null,
  text_body text not null,
  template_name text,
  conversation_id uuid references public.conversations(id) on delete set null,
  status text not null default 'queued' check (status in ('queued','sending','sent','failed','cancelled')),
  attempts integer not null default 0,
  next_try_at timestamptz not null default now(),
  claimed_at timestamptz,
  external_id text,
  last_error text,
  created_at timestamptz not null default now()
);
create index if not exists meta_outbox_due_idx on public.meta_outbox (status, next_try_at);
alter table public.meta_outbox enable row level security;
revoke all on public.meta_outbox from anon, authenticated;

create table if not exists public.meta_templates (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  name text not null,
  language text not null default 'en_US',
  category text,
  body text,
  status text not null default 'unknown',
  synced_at timestamptz not null default now(),
  unique (business_id, name, language)
);
alter table public.meta_templates enable row level security;
drop policy if exists meta_templates_read on public.meta_templates;
create policy meta_templates_read on public.meta_templates for select to authenticated using (public.zella_is_member(business_id));

-- ---------------------------------------------------------------------------------------------------------
-- 2. Social conversations use their own channels
-- ---------------------------------------------------------------------------------------------------------
do $$
declare c text;
begin
  select conname into c from pg_constraint where conrelid = 'public.conversations'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%webchat%';
  if c is not null then execute format('alter table public.conversations drop constraint %I', c); end if;
  alter table public.conversations add constraint conversations_channel_check
    check (channel in ('sms','email','call','webchat','other','messenger','instagram','whatsapp'));
end $$;

-- ---------------------------------------------------------------------------------------------------------
-- 3. Meta's secrets live in Vault: zella_meta_app_secret (signs every webhook) and zella_meta_verify_token
--    (the word Meta sends when the webhook is first connected). Nothing here ever returns them.
-- ---------------------------------------------------------------------------------------------------------
create or replace function public.zella_meta_verify_token(p_token text) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare v text;
begin
  select decrypted_secret into v from vault.decrypted_secrets where name = 'zella_meta_verify_token' limit 1;
  if v is null or v = '' or p_token is null then return false; end if;
  return encode(sha256(convert_to(p_token, 'utf8')), 'hex') = encode(sha256(convert_to(v, 'utf8')), 'hex');
end $$;
revoke execute on function public.zella_meta_verify_token(text) from public, anon, authenticated;
grant execute on function public.zella_meta_verify_token(text) to service_role;

-- The page token for one connection (n8n needs it to call Meta). Service role only.
create or replace function public.zella_meta_token(p_page_id text) returns text
language plpgsql security definer set search_path = public as $$
declare v_sec text; v_tok text;
begin
  select token_secret into v_sec from public.meta_connections where page_id = p_page_id and status in ('connected', 'error');
  if v_sec is null then return null; end if;
  select decrypted_secret into v_tok from vault.decrypted_secrets where name = v_sec limit 1;
  return v_tok;
end $$;
revoke execute on function public.zella_meta_token(text) from public, anon, authenticated;
grant execute on function public.zella_meta_token(text) to service_role;

-- Connect (or reconnect) a page. Called by the connect flow after the owner approves access; service role only.
create or replace function public.zella_meta_store_connection(p_business_id uuid, p_page_id text, p_page_name text, p_token text,
  p_instagram_id text default null, p_whatsapp_phone_id text default null, p_waba_id text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_name text := 'meta_token_' || p_page_id; v_id uuid; v_exist uuid;
begin
  if p_page_id !~ '^[0-9]{5,30}$' or coalesce(length(p_token), 0) < 20 then raise exception 'BAD_INPUT'; end if;
  if not exists (select 1 from public.businesses where id = p_business_id and cancelled_at is null) then raise exception 'UNKNOWN_BUSINESS'; end if;
  if exists (select 1 from public.meta_connections where page_id = p_page_id and business_id <> p_business_id and status <> 'disconnected') then raise exception 'PAGE_IN_USE'; end if;
  select id into v_exist from vault.secrets where name = v_name;
  if v_exist is null then perform vault.create_secret(p_token, v_name); else perform vault.update_secret(v_exist, p_token, v_name); end if;
  insert into public.meta_connections (business_id, page_id, page_name, instagram_id, whatsapp_phone_id, waba_id, token_secret, status, last_error, next_check_at)
  values (p_business_id, p_page_id, left(p_page_name, 200), nullif(p_instagram_id, ''), nullif(p_whatsapp_phone_id, ''), nullif(p_waba_id, ''), v_name, 'connected', null, now())
  on conflict (page_id) do update set business_id = excluded.business_id, page_name = excluded.page_name, instagram_id = excluded.instagram_id,
     whatsapp_phone_id = excluded.whatsapp_phone_id, waba_id = excluded.waba_id, token_secret = excluded.token_secret, status = 'connected', last_error = null, next_check_at = now()
  returning id into v_id;
  perform public.zella_resolve_platform_alerts('meta_disconnected', p_business_id, p_page_id, 'Reconnected');
  return v_id;
end $$;
revoke execute on function public.zella_meta_store_connection(uuid, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.zella_meta_store_connection(uuid, text, text, text, text, text, text) to service_role;

-- The owner's own switches for a connection.
create or replace function public.zella_meta_settings(p_business_id uuid, p_page_id text, p_call_consent boolean default null, p_auto_ack boolean default null, p_keywords text[] default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.zella_has_role(p_business_id, array['owner','admin','manager']) then raise exception 'NOT_ALLOWED'; end if;
  update public.meta_connections set
      call_consent_confirmed = coalesce(p_call_consent, call_consent_confirmed),
      auto_acknowledge = coalesce(p_auto_ack, auto_acknowledge),
      comment_keywords = coalesce((select array_agg(lower(trim(k))) filter (where length(trim(k)) between 2 and 40) from unnest(p_keywords) k), comment_keywords)
   where business_id = p_business_id and page_id = p_page_id;
end $$;
revoke execute on function public.zella_meta_settings(uuid, text, boolean, boolean, text[]) from public, anon;
grant execute on function public.zella_meta_settings(uuid, text, boolean, boolean, text[]) to authenticated, service_role;
-- ---------------------------------------------------------------------------------------------------------
-- 4. Messages and comments (handled the moment they arrive; no outside call is needed)
-- ---------------------------------------------------------------------------------------------------------
create or replace function public.zella_meta_process_event(p_event_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  e public.meta_events%rowtype; c public.meta_connections%rowtype; p jsonb; v_biz text;
  v_ch text; v_sender text; v_name text; v_text text; v_phone text; v_contact public.meta_contacts%rowtype;
  v_cust uuid; v_conv uuid; v_assignee uuid; v_intent text; v_label text; v_email text; v_digits text; v_first text;
begin
  select * into e from public.meta_events where id = p_event_id;
  if not found then return 'missing'; end if;
  select * into c from public.meta_connections where page_id = e.page_id and business_id = e.business_id and status <> 'disconnected' limit 1;
  if c.id is null then
    update public.meta_events set status = 'ignored', last_error = 'no_connection' where id = p_event_id; return 'no_connection';
  end if;
  p := e.payload;
  select name into v_biz from public.businesses where id = e.business_id and suspended_at is null and cancelled_at is null;
  if v_biz is null then
    update public.meta_events set status = 'ignored', last_error = 'business_inactive' where id = p_event_id; return 'business_inactive';
  end if;

  -- ---- a comment on a post: a private reply only when it matches the owner's own keywords
  if e.kind = 'comment' then
    v_text := lower(coalesce(p ->> 'text', ''));
    if coalesce((p ->> 'from_page')::boolean, false) or cardinality(c.comment_keywords) = 0
       or not exists (select 1 from unnest(c.comment_keywords) k where position(k in v_text) > 0) then
      update public.meta_events set status = 'ignored' where id = p_event_id; return 'ignored';
    end if;
    insert into public.meta_outbox (business_id, page_id, channel, kind, recipient, text_body)
    values (e.business_id, e.page_id, case when p ->> 'platform' = 'instagram' then 'instagram' else 'messenger' end, 'private_reply', p ->> 'comment_id',
            'Hi! Thanks for your comment. This is ' || v_biz || '. How can we help? Reply here and our team will get back to you.');
    perform public.zella_notify_owners(e.business_id, 'social_comment', 'A comment got a private reply', left(coalesce(p ->> 'text', ''), 200), 'info', 'inbox');
    update public.meta_events set status = 'done' where id = p_event_id;
    return 'private_reply_queued';
  end if;

  -- ---- a message
  v_ch := p ->> 'channel'; v_sender := left(p ->> 'sender_id', 100); v_name := nullif(left(coalesce(p ->> 'sender_name', ''), 120), '');
  v_text := coalesce(nullif(left(trim(coalesce(p ->> 'text', '')), 2000), ''), '(attachment)'); v_phone := nullif(left(coalesce(p ->> 'phone', ''), 30), '');
  if v_ch not in ('messenger', 'instagram', 'whatsapp') or v_sender is null then
    update public.meta_events set status = 'ignored', last_error = 'bad_message' where id = p_event_id; return 'bad_message';
  end if;
  v_label := case v_ch when 'whatsapp' then 'WhatsApp' when 'instagram' then 'Instagram' else 'Messenger' end;

  insert into public.meta_contacts (business_id, channel, external_id, display_name) values (e.business_id, v_ch, v_sender, v_name)
  on conflict (business_id, channel, external_id) do update set display_name = coalesce(excluded.display_name, public.meta_contacts.display_name)
  returning * into v_contact;

  v_cust := v_contact.customer_id;
  -- the same person on another channel: a WhatsApp number that matches a customer exactly is the same customer
  if v_cust is null and v_phone is not null then
    select m.customer_id into v_cust from public.zella_match_customer(e.business_id, v_phone, null) m where m.certainty = 'exact' limit 1;
  end if;

  v_intent := case
    when v_text ~* '\m(human|real person|agent|speak to (someone|a person)|talk to (someone|a person)|call me)\M' then 'human'
    when v_text ~* '\m(complain|complaint|unhappy|terrible|refund|disappointed)\M' then 'complaint'
    when v_text ~* '\m(book|booking|appointment|available|availability|schedule|reserve)\M' then 'booking'
    when v_text ~* '\m(price|prices|cost|quote|how much|estimate)\M' then 'price'
    else 'message' end;

  -- a likely customer who left a phone number or email in the chat becomes a lead
  if v_cust is null and v_intent in ('booking', 'price', 'human') then
    v_email := lower(substring(v_text from '([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})'));
    v_digits := substring(v_text from '(\+?[0-9][0-9 ().-]{7,18}[0-9])');
    v_phone := coalesce(v_phone, v_digits);
    if public.zella_digits(v_phone) is not null or v_email is not null then
      select m.customer_id into v_cust from public.zella_match_customer(e.business_id, v_phone, v_email) m where m.certainty = 'exact' limit 1;
      if v_cust is null then
        v_first := coalesce(split_part(v_name, ' ', 1), v_label || ' contact');
        insert into public.customers (business_id, first_name, last_name, phone, email, status, source, lead_stage, priority, qualification, metadata)
        values (e.business_id, coalesce(nullif(v_first, ''), v_label || ' contact'), nullif(trim(substr(coalesce(v_name, ''), length(split_part(coalesce(v_name, ''), ' ', 1)) + 1)), ''),
                case when public.zella_digits(v_phone) is not null then v_phone end, v_email, 'active', lower(v_label), 'new', case when v_intent = 'human' then 'high' else 'normal' end,
                jsonb_build_object('intent', v_intent, 'has_phone', public.zella_digits(v_phone) is not null, 'has_email', v_email is not null),
                jsonb_build_object('attribution', jsonb_build_object('first_touch', jsonb_build_object('utm_source', lower(v_label), 'channel', lower(v_label), 'at', now()))))
        returning id into v_cust;
      end if;
    end if;
  end if;

  -- the conversation
  v_conv := v_contact.conversation_id;
  if v_conv is not null and not exists (select 1 from public.conversations where id = v_conv and status <> 'closed') then v_conv := null; end if;
  if v_conv is null then
    insert into public.conversations (business_id, customer_id, channel, status, subject, ai_handled)
    values (e.business_id, v_cust, v_ch, 'open', v_label || ' conversation' || coalesce(' with ' || v_name, ''), false) returning id into v_conv;
  elsif v_cust is not null then
    update public.conversations set customer_id = coalesce(customer_id, v_cust) where id = v_conv;
  end if;
  update public.meta_contacts set conversation_id = v_conv, customer_id = coalesce(customer_id, v_cust) where id = v_contact.id;
  update public.conversations set status = 'open', priority = case when v_intent in ('human', 'complaint') then 'high' else priority end where id = v_conv;
  insert into public.conversation_messages (conversation_id, sender_type, message_type, content, external_message_id, metadata)
  values (v_conv, 'customer', 'text', v_text, left(p ->> 'message_id', 200), jsonb_build_object('channel', v_ch, 'intent', v_intent));

  -- who looks after it
  if (select assigned_to from public.conversations where id = v_conv) is null then
    v_assignee := public.zella_pick_assignee(e.business_id);
    if v_assignee is not null then
      update public.conversations set assigned_to = v_assignee where id = v_conv;
      perform public.zella_mark_assigned(e.business_id, v_assignee);
    end if;
  end if;

  perform public.zella_notify_owners(e.business_id, 'social_message',
    case v_intent when 'human' then v_label || ': ' || coalesce(v_name, 'someone') || ' wants a person' when 'complaint' then v_label || ' complaint from ' || coalesce(v_name, 'a customer')
      else 'New ' || v_label || ' message' || coalesce(' from ' || v_name, '') end,
    left(v_text, 300), case when v_intent in ('human', 'complaint') then 'urgent' else 'info' end, 'inbox');

  -- a polite first reply, once a day, only if no person has answered yet
  if c.auto_acknowledge and (v_contact.last_ack_at is null or v_contact.last_ack_at < now() - interval '24 hours')
     and not exists (select 1 from public.conversation_messages m where m.conversation_id = v_conv and m.sender_type = 'agent') then
    insert into public.meta_outbox (business_id, page_id, channel, kind, recipient, text_body, conversation_id)
    values (e.business_id, e.page_id, v_ch, 'message', v_sender, 'Thanks for messaging ' || v_biz || '! We have your message and the team will reply soon.', v_conv);
    update public.meta_contacts set last_ack_at = now() where id = v_contact.id;
  end if;

  update public.meta_events set status = 'done' where id = p_event_id;
  return 'processed:' || v_intent;
end $$;
revoke execute on function public.zella_meta_process_event(uuid) from public, anon, authenticated;
grant execute on function public.zella_meta_process_event(uuid) to service_role;

-- ---------------------------------------------------------------------------------------------------------
-- 5. Everything Meta sends us comes through here. The signature is checked first; a wrong one changes nothing.
--    Leads wait for n8n to fetch their details; messages and comments are handled at once.
-- ---------------------------------------------------------------------------------------------------------
create or replace function public.zella_meta_receive(p_raw text, p_signature text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_secret text; j jsonb; en jsonb; ch jsonb; msg jsonb; v_obj text; v_id uuid; v_conn public.meta_connections%rowtype; v_val jsonb;
  n_leads integer := 0; n_msgs integer := 0; v_key text; v_from text; v_name text;
begin
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'zella_meta_app_secret' limit 1;
  if v_secret is null or v_secret = '' then return jsonb_build_object('result', 'not_configured'); end if;
  if p_signature is null or p_raw is null or
     encode(sha256(convert_to(p_signature, 'utf8')), 'hex') <> encode(sha256(convert_to('sha256=' || encode(hmac(convert_to(p_raw, 'utf8'), convert_to(v_secret, 'utf8'), 'sha256'), 'hex'), 'utf8')), 'hex') then
    return jsonb_build_object('result', 'unauthorized');
  end if;
  begin j := p_raw::jsonb; exception when others then return jsonb_build_object('result', 'ignored'); end;
  v_obj := j ->> 'object';
  if v_obj not in ('page', 'instagram', 'whatsapp_business_account') or jsonb_typeof(j -> 'entry') <> 'array' then return jsonb_build_object('result', 'ignored'); end if;

  for en in select * from jsonb_array_elements(j -> 'entry') loop
    v_conn := null;
    if v_obj = 'whatsapp_business_account' then
      select * into v_conn from public.meta_connections where status <> 'disconnected' and (waba_id = en ->> 'id'
         or whatsapp_phone_id in (select x #>> '{value,metadata,phone_number_id}' from jsonb_array_elements(coalesce(en -> 'changes', '[]'::jsonb)) x)) limit 1;
    else
      select * into v_conn from public.meta_connections where status <> 'disconnected' and (page_id = en ->> 'id' or instagram_id = en ->> 'id') limit 1;
    end if;
    if v_conn.id is null then continue; end if;

    for msg in select * from jsonb_array_elements(case when jsonb_typeof(en -> 'messaging') = 'array' then en -> 'messaging' else '[]'::jsonb end) loop
      if msg #>> '{message,mid}' is null or coalesce((msg #>> '{message,is_echo}')::boolean, false) then continue; end if;
      v_from := msg #>> '{sender,id}';
      if v_from is null or v_from in (v_conn.page_id, coalesce(v_conn.instagram_id, '-')) then continue; end if;
      v_key := 'msg:' || (msg #>> '{message,mid}');
      v_id := null;
      insert into public.meta_events (event_key, kind, page_id, business_id, payload)
      values (v_key, 'message', v_conn.page_id, v_conn.business_id, jsonb_build_object('channel', case when v_obj = 'instagram' then 'instagram' else 'messenger' end,
              'sender_id', v_from, 'text', left(coalesce(msg #>> '{message,text}', ''), 2000), 'message_id', msg #>> '{message,mid}'))
      on conflict (event_key) do nothing returning id into v_id;
      if v_id is not null then
        begin perform public.zella_meta_process_event(v_id); n_msgs := n_msgs + 1;
        exception when others then update public.meta_events set status = 'failed', last_error = left(sqlerrm, 200) where id = v_id; end;
      end if;
    end loop;

    for ch in select * from jsonb_array_elements(case when jsonb_typeof(en -> 'changes') = 'array' then en -> 'changes' else '[]'::jsonb end) loop
      v_val := case when jsonb_typeof(ch -> 'value') = 'object' then ch -> 'value' else '{}'::jsonb end;
      v_id := null;
      if ch ->> 'field' = 'leadgen' and v_val ->> 'leadgen_id' ~ '^[0-9]{5,30}$' then
        insert into public.meta_events (event_key, kind, page_id, business_id, payload)
        values ('lead:' || (v_val ->> 'leadgen_id'), 'lead', v_conn.page_id, v_conn.business_id,
                jsonb_build_object('leadgen_id', v_val ->> 'leadgen_id', 'form_id', v_val ->> 'form_id', 'ad_id', v_val ->> 'ad_id', 'adgroup_id', v_val ->> 'adgroup_id',
                                   'platform', case when v_obj = 'instagram' then 'instagram' else 'facebook' end))
        on conflict (event_key) do nothing returning id into v_id;
        if v_id is not null then n_leads := n_leads + 1; end if;
      elsif ch ->> 'field' = 'feed' and v_val ->> 'item' = 'comment' and v_val ->> 'verb' = 'add' and v_val ->> 'comment_id' is not null then
        insert into public.meta_events (event_key, kind, page_id, business_id, payload)
        values ('comment:' || (v_val ->> 'comment_id'), 'comment', v_conn.page_id, v_conn.business_id,
                jsonb_build_object('comment_id', v_val ->> 'comment_id', 'text', left(coalesce(v_val ->> 'message', ''), 1000), 'from_id', v_val #>> '{from,id}',
                                   'from_page', (v_val #>> '{from,id}') = v_conn.page_id, 'platform', 'facebook'))
        on conflict (event_key) do nothing returning id into v_id;
        if v_id is not null then
          begin perform public.zella_meta_process_event(v_id); n_msgs := n_msgs + 1;
          exception when others then update public.meta_events set status = 'failed', last_error = left(sqlerrm, 200) where id = v_id; end;
        end if;
      elsif ch ->> 'field' = 'comments' and v_val ->> 'id' is not null then
        insert into public.meta_events (event_key, kind, page_id, business_id, payload)
        values ('comment:' || (v_val ->> 'id'), 'comment', v_conn.page_id, v_conn.business_id,
                jsonb_build_object('comment_id', v_val ->> 'id', 'text', left(coalesce(v_val ->> 'text', ''), 1000), 'from_id', v_val #>> '{from,id}',
                                   'from_page', (v_val #>> '{from,id}') = coalesce(v_conn.instagram_id, '-'), 'platform', 'instagram'))
        on conflict (event_key) do nothing returning id into v_id;
        if v_id is not null then
          begin perform public.zella_meta_process_event(v_id); n_msgs := n_msgs + 1;
          exception when others then update public.meta_events set status = 'failed', last_error = left(sqlerrm, 200) where id = v_id; end;
        end if;
      elsif ch ->> 'field' = 'messages' and jsonb_typeof(v_val -> 'messages') = 'array' then
        for msg in select * from jsonb_array_elements(v_val -> 'messages') loop
          if msg ->> 'id' is null or msg ->> 'from' is null then continue; end if;
          v_name := null; v_id := null;
          select c2 #>> '{profile,name}' into v_name from jsonb_array_elements(coalesce(v_val -> 'contacts', '[]'::jsonb)) c2 where c2 ->> 'wa_id' = msg ->> 'from' limit 1;
          insert into public.meta_events (event_key, kind, page_id, business_id, payload)
          values ('msg:' || (msg ->> 'id'), 'message', v_conn.page_id, v_conn.business_id,
                  jsonb_build_object('channel', 'whatsapp', 'sender_id', msg ->> 'from', 'sender_name', v_name, 'phone', '+' || regexp_replace(msg ->> 'from', '[^0-9]', '', 'g'),
                                     'text', case when msg ->> 'type' = 'text' then left(coalesce(msg #>> '{text,body}', ''), 2000) else '' end, 'message_id', msg ->> 'id'))
          on conflict (event_key) do nothing returning id into v_id;
          if v_id is not null then
            begin perform public.zella_meta_process_event(v_id); n_msgs := n_msgs + 1;
            exception when others then update public.meta_events set status = 'failed', last_error = left(sqlerrm, 200) where id = v_id; end;
          end if;
        end loop;
      end if;
    end loop;
  end loop;
  return jsonb_build_object('result', 'ok', 'leads', n_leads, 'messages', n_msgs);
end $$;
revoke execute on function public.zella_meta_receive(text, text) from public, anon, authenticated;
grant execute on function public.zella_meta_receive(text, text) to service_role;

-- ---------------------------------------------------------------------------------------------------------
-- 6. Leads: n8n claims pending lead events, fetches each lead from Meta, and hands the answers back.
-- ---------------------------------------------------------------------------------------------------------
create or replace function public.zella_meta_claim_leads(p_limit integer default 10) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  update public.meta_events set status = 'failed', last_error = 'stuck' where kind = 'lead' and status = 'processing' and claimed_at < now() - interval '10 minutes' and attempts >= 5;
  with c as (
    select id from public.meta_events
     where kind = 'lead' and ((status = 'pending' and next_try_at <= now()) or (status = 'processing' and claimed_at < now() - interval '10 minutes'))
     order by created_at limit greatest(1, least(coalesce(p_limit, 10), 25)) for update skip locked),
  u as (update public.meta_events e set status = 'processing', attempts = e.attempts + 1, claimed_at = now() from c where e.id = c.id
        returning e.id, e.page_id, e.payload)
  select coalesce(jsonb_agg(jsonb_build_object('event_id', id, 'page_id', page_id, 'leadgen_id', payload ->> 'leadgen_id', 'form_id', payload ->> 'form_id', 'ad_id', payload ->> 'ad_id')), '[]'::jsonb) into v from u;
  return v;
end $$;
revoke execute on function public.zella_meta_claim_leads(integer) from public, anon, authenticated;
grant execute on function public.zella_meta_claim_leads(integer) to service_role;

create or replace function public.zella_meta_fail_event(p_event_id uuid, p_error text, p_permanent boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare e public.meta_events%rowtype;
begin
  select * into e from public.meta_events where id = p_event_id;
  if not found then return; end if;
  if p_permanent or e.attempts >= 5 then
    update public.meta_events set status = 'failed', last_error = left(coalesce(p_error, 'unknown'), 200) where id = p_event_id;
    perform public.zella_platform_alert('meta_lead_failed', 'A Facebook or Instagram lead could not be fetched', left(coalesce(p_error, 'unknown'), 200), 'warning', e.business_id, 'meta_lead_failed:' || e.business_id::text);
    perform public.zella_notify_owners(e.business_id, 'meta_lead_failed', 'A social lead could not be fetched', 'Open your Meta leads page in Facebook to see it, and check the Meta connection in Zella.', 'warning', 'integrations');
  else
    update public.meta_events set status = 'pending', last_error = left(coalesce(p_error, 'unknown'), 200), next_try_at = now() + (power(2, e.attempts) || ' minutes')::interval where id = p_event_id;
  end if;
end $$;
revoke execute on function public.zella_meta_fail_event(uuid, text, boolean) from public, anon, authenticated;
grant execute on function public.zella_meta_fail_event(uuid, text, boolean) to service_role;

create or replace function public.zella_meta_capture_lead(p_event_id uuid, p_fields jsonb, p_campaign text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  e public.meta_events%rowtype; c public.meta_connections%rowtype; f jsonb; k text; v text;
  v_name text; v_first text; v_last text; v_phone text; v_email text; v_consent boolean := false; v_notes text := '';
  v_digits text; v_cust uuid; v_cb uuid; v_platform text; v_src jsonb; v_ok boolean; v_summary text; v_label text; v_camp text;
begin
  select * into e from public.meta_events where id = p_event_id and kind = 'lead';
  if not found then return jsonb_build_object('result', 'missing'); end if;
  select * into c from public.meta_connections where page_id = e.page_id and business_id = e.business_id and status <> 'disconnected' limit 1;
  if c.id is null or not exists (select 1 from public.businesses b where b.id = e.business_id and b.suspended_at is null and b.cancelled_at is null) then
    update public.meta_events set status = 'ignored', last_error = 'no_connection' where id = p_event_id; return jsonb_build_object('result', 'ignored');
  end if;
  if jsonb_typeof(p_fields) <> 'array' then raise exception 'BAD_FIELDS'; end if;
  v_platform := coalesce(e.payload ->> 'platform', 'facebook'); v_label := initcap(v_platform);

  for f in select * from jsonb_array_elements(p_fields) loop
    k := lower(coalesce(f ->> 'name', '')); v := nullif(trim(coalesce(f -> 'values' ->> 0, '')), '');
    continue when v is null;
    if k ~ 'email' then v_email := lower(left(v, 254));
    elsif k ~ 'phone' then v_phone := left(v, 40);
    elsif k = 'full_name' then v_name := left(v, 120);
    elsif k = 'first_name' then v_first := left(v, 60);
    elsif k = 'last_name' then v_last := left(v, 60);
    elsif k ~ '(consent|agree|permission|contact_me|opt_in)' then v_consent := v_consent or lower(v) ~ '^(yes|true|agree|i agree|1|ok|sure)';
    elsif length(v_notes) < 400 then v_notes := v_notes || case when v_notes = '' then '' else '; ' end || left(replace(k, '_', ' '), 40) || ': ' || left(v, 100);
    end if;
  end loop;
  if v_first is null then v_first := nullif(split_part(coalesce(v_name, ''), ' ', 1), ''); end if;
  if v_last is null and v_name is not null then v_last := nullif(trim(substr(v_name, length(split_part(v_name, ' ', 1)) + 1)), ''); end if;
  v_digits := public.zella_digits(v_phone);
  if v_digits is not null and (length(v_digits) < 7 or length(v_digits) > 15) then v_phone := null; v_digits := null; end if;
  if v_email is not null and not public.zella_valid_email(v_email) then v_email := null; end if;
  if v_digits is null and v_email is null then
    update public.meta_events set status = 'done', last_error = 'no_contact_details' where id = p_event_id;
    perform public.zella_notify_owners(e.business_id, 'meta_lead_incomplete', 'A ' || v_label || ' lead had no phone or email', 'Check the lead in Facebook Leads Center.', 'info', 'customers');
    return jsonb_build_object('result', 'no_contact');
  end if;

  v_camp := coalesce(nullif(left(p_campaign, 120), ''), 'form ' || coalesce(e.payload ->> 'form_id', '?'));
  v_src := jsonb_build_object('utm_source', v_platform, 'utm_medium', 'paid_social', 'utm_campaign', v_camp, 'meta_form_id', e.payload ->> 'form_id', 'meta_ad_id', e.payload ->> 'ad_id');
  select m.customer_id into v_cust from public.zella_match_customer(e.business_id, v_phone, v_email) m where m.certainty = 'exact' limit 1;
  if v_cust is null then
    insert into public.customers (business_id, first_name, last_name, phone, email, status, source, lead_stage, priority, qualification, metadata)
    values (e.business_id, coalesce(v_first, v_label || ' lead'), v_last, v_phone, v_email, 'active', v_platform, 'new', 'normal',
            jsonb_build_object('kind', 'social_lead', 'has_phone', v_digits is not null, 'has_email', v_email is not null, 'form_answers', nullif(v_notes, '')),
            jsonb_build_object('attribution', jsonb_build_object('first_touch', v_src || jsonb_build_object('channel', v_platform, 'at', now()))))
    returning id into v_cust;
  else
    update public.customers set metadata = jsonb_set(coalesce(metadata, '{}'::jsonb), '{attribution,last_touch}', v_src || jsonb_build_object('channel', v_platform, 'at', now()), true), updated_at = now() where id = v_cust;
  end if;

  v_ok := v_consent or c.call_consent_confirmed;
  if v_ok then
    if v_digits is not null then
      perform public.zella_record_consent(e.business_id, 'call', 'opted_in', 'web_form', v_cust, v_phone, null, 'transactional', null, jsonb_build_object('meta_lead', e.payload ->> 'leadgen_id'));
      perform public.zella_record_consent(e.business_id, 'sms', 'opted_in', 'web_form', v_cust, v_phone, null, 'transactional', null, jsonb_build_object('meta_lead', e.payload ->> 'leadgen_id'));
    end if;
    if v_email is not null then
      perform public.zella_record_consent(e.business_id, 'email', 'opted_in', 'web_form', v_cust, null, v_email, 'transactional', null, jsonb_build_object('meta_lead', e.payload ->> 'leadgen_id'));
    end if;
  end if;

  v_summary := left(v_label || ' lead (' || v_camp || ')' || case when v_notes <> '' then ': ' || v_notes else '' end, 600);
  if v_digits is not null and v_ok then
    v_cb := public.zella_create_callback(e.business_id, v_phone, 'new_lead', 'normal', v_summary, null, v_cust, null, null, 'system', 'new_lead_callback');
  else
    perform public.zella_notify(e.business_id, 'social_lead', 'New ' || v_label || ' lead',
      v_summary || case when v_digits is not null and not v_ok then ' (not called: the form has no consent to be contacted)' when v_digits is null then ' (email only: ' || v_email || ')' else '' end,
      'info', 'customers', v_cust);
  end if;
  insert into public.lead_submissions (business_id, kind, channel, status, customer_id, callback_id, source, summary)
  values (e.business_id, 'social_lead', v_platform, 'accepted', v_cust, v_cb, v_src, v_summary);
  update public.meta_events set status = 'done', last_error = null where id = p_event_id;
  return jsonb_build_object('result', 'captured', 'customer_id', v_cust, 'called', v_cb is not null);
end $$;
revoke execute on function public.zella_meta_capture_lead(uuid, jsonb, text) from public, anon, authenticated;
grant execute on function public.zella_meta_capture_lead(uuid, jsonb, text) to service_role;

-- ---------------------------------------------------------------------------------------------------------
-- 7. Replies (n8n sends them), staff replies, connection health, WhatsApp templates, and a status view.
-- ---------------------------------------------------------------------------------------------------------
create or replace function public.zella_meta_claim_outbox(p_limit integer default 10) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o record; v_out jsonb := '[]'::jsonb; v_last timestamptz; c public.meta_connections%rowtype;
begin
  for o in select * from public.meta_outbox
            where (status = 'queued' and next_try_at <= now()) or (status = 'sending' and claimed_at < now() - interval '10 minutes')
            order by created_at limit greatest(1, least(coalesce(p_limit, 10), 25)) for update skip locked loop
    select * into c from public.meta_connections where page_id = o.page_id and business_id = o.business_id;
    if c.id is null or c.status = 'disconnected' then
      update public.meta_outbox set status = 'cancelled', last_error = 'no_connection' where id = o.id; continue;
    end if;
    -- a free-form message is only allowed within 24 hours of the customer's last message
    if o.kind = 'message' and o.conversation_id is not null then
      select last_inbound_at into v_last from public.conversations where id = o.conversation_id;
      if v_last is null or v_last < now() - interval '24 hours' then
        update public.meta_outbox set status = 'cancelled', last_error = case when o.channel = 'whatsapp' then 'template_required' else 'window_closed' end where id = o.id; continue;
      end if;
    end if;
    update public.meta_outbox set status = 'sending', attempts = attempts + 1, claimed_at = now() where id = o.id;
    v_out := v_out || jsonb_build_array(jsonb_build_object('id', o.id, 'page_id', o.page_id, 'channel', o.channel, 'kind', o.kind, 'recipient', o.recipient,
      'text', o.text_body, 'instagram_id', c.instagram_id, 'whatsapp_phone_id', c.whatsapp_phone_id));
  end loop;
  return v_out;
end $$;
revoke execute on function public.zella_meta_claim_outbox(integer) from public, anon, authenticated;
grant execute on function public.zella_meta_claim_outbox(integer) to service_role;

create or replace function public.zella_meta_record_send(p_id uuid, p_ok boolean, p_external_id text default null, p_error text default null, p_auth_failed boolean default false, p_retry boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare o public.meta_outbox%rowtype;
begin
  select * into o from public.meta_outbox where id = p_id;
  if not found then return; end if;
  if p_ok then
    update public.meta_outbox set status = 'sent', external_id = left(p_external_id, 200), last_error = null where id = p_id;
  elsif p_retry and o.attempts < 4 then
    update public.meta_outbox set status = 'queued', last_error = left(coalesce(p_error, 'error'), 200), next_try_at = now() + (power(2, o.attempts) * 2 || ' minutes')::interval where id = p_id;
  else
    update public.meta_outbox set status = 'failed', last_error = left(coalesce(p_error, 'error'), 200) where id = p_id;
    if p_auth_failed then
      perform public.zella_meta_record_check(o.page_id, false, null, true, left(p_error, 200));
    else
      perform public.zella_platform_alert('meta_send_failed', 'A Facebook, Instagram or WhatsApp reply could not be sent', left(coalesce(p_error, 'error'), 200), 'warning', o.business_id, 'meta_send_failed:' || o.business_id::text);
    end if;
  end if;
end $$;
revoke execute on function public.zella_meta_record_send(uuid, boolean, text, text, boolean, boolean) from public, anon, authenticated;
grant execute on function public.zella_meta_record_send(uuid, boolean, text, text, boolean, boolean) to service_role;

-- A staff member answers a social conversation. Taking over also marks it as handled by a person.
create or replace function public.zella_meta_staff_reply(p_conversation_id uuid, p_text text) returns uuid
language plpgsql security definer set search_path = public as $$
declare cv public.conversations%rowtype; ct public.meta_contacts%rowtype; c public.meta_connections%rowtype; v_id uuid; v_txt text := left(trim(coalesce(p_text, '')), 1000);
begin
  select * into cv from public.conversations where id = p_conversation_id;
  if not found or not public.zella_has_role(cv.business_id, array['owner','admin','manager','staff']) then raise exception 'NOT_ALLOWED'; end if;
  if cv.channel not in ('messenger','instagram','whatsapp') then raise exception 'NOT_A_SOCIAL_CONVERSATION'; end if;
  if length(v_txt) < 1 then raise exception 'EMPTY'; end if;
  select * into ct from public.meta_contacts where conversation_id = cv.id limit 1;
  select * into c from public.meta_connections where business_id = cv.business_id and status = 'connected' order by created_at limit 1;
  if ct.id is null or c.id is null then raise exception 'NOT_CONNECTED'; end if;
  if cv.last_inbound_at is null or cv.last_inbound_at < now() - interval '24 hours' then
    raise exception '%', case when cv.channel = 'whatsapp' then 'TEMPLATE_REQUIRED' else 'WINDOW_CLOSED' end;
  end if;
  insert into public.meta_outbox (business_id, page_id, channel, kind, recipient, text_body, conversation_id)
  values (cv.business_id, c.page_id, cv.channel, 'message', ct.external_id, v_txt, cv.id) returning id into v_id;
  insert into public.conversation_messages (conversation_id, sender_type, message_type, content, metadata)
  values (cv.id, 'agent', 'text', v_txt, jsonb_build_object('channel', cv.channel, 'user_id', auth.uid()));
  update public.conversations set assigned_to = coalesce(assigned_to, auth.uid()), ai_handled = false, handover_at = coalesce(handover_at, now()), updated_at = now() where id = cv.id;
  return v_id;
end $$;
revoke execute on function public.zella_meta_staff_reply(uuid, text) from public, anon;
grant execute on function public.zella_meta_staff_reply(uuid, text) to authenticated, service_role;

create or replace function public.zella_meta_claim_checks(p_limit integer default 10) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  with c as (select id from public.meta_connections where status in ('connected', 'error') and next_check_at <= now() order by next_check_at limit greatest(1, least(coalesce(p_limit, 10), 25)) for update skip locked),
  u as (update public.meta_connections m set next_check_at = now() + interval '6 hours', last_checked_at = now() from c where m.id = c.id returning m.page_id, m.waba_id, m.whatsapp_phone_id)
  select coalesce(jsonb_agg(jsonb_build_object('page_id', page_id, 'waba_id', waba_id, 'whatsapp_phone_id', whatsapp_phone_id)), '[]'::jsonb) into v from u;
  return v;
end $$;
revoke execute on function public.zella_meta_claim_checks(integer) from public, anon, authenticated;
grant execute on function public.zella_meta_claim_checks(integer) to service_role;

create or replace function public.zella_meta_record_check(p_page_id text, p_ok boolean, p_permissions text[] default null, p_auth_failed boolean default false, p_error text default null)
returns void language plpgsql security definer set search_path = public as $$
declare c public.meta_connections%rowtype; v_missing text[]; v_need text[] := array['pages_messaging','pages_show_list','leads_retrieval','pages_manage_metadata','pages_read_engagement'];
begin
  select * into c from public.meta_connections where page_id = p_page_id;
  if not found then return; end if;
  if p_ok then
    update public.meta_connections set status = 'connected', last_error = null, last_checked_at = now(), granted_permissions = coalesce(p_permissions, granted_permissions) where id = c.id;
    perform public.zella_resolve_platform_alerts('meta_disconnected', c.business_id, p_page_id, 'Connection works again');
    if p_permissions is not null then
      select array_agg(x) into v_missing from unnest(v_need) x where not (x = any (p_permissions));
      if v_missing is not null then
        perform public.zella_platform_alert('meta_permissions_missing', 'Facebook/Instagram access is missing permissions', 'Missing: ' || array_to_string(v_missing, ', '), 'warning', c.business_id, p_page_id);
        perform public.zella_notify_owners(c.business_id, 'meta_permissions_missing', 'Facebook/Instagram needs more access', 'Reconnect your page and approve all the requested permissions so leads and messages keep working.', 'warning', 'integrations');
      else
        perform public.zella_resolve_platform_alerts('meta_permissions_missing', c.business_id, p_page_id, 'All permissions granted');
      end if;
    end if;
  elsif p_auth_failed then
    update public.meta_connections set status = 'needs_reconnect', last_error = left(coalesce(p_error, 'access token rejected'), 200), last_checked_at = now() where id = c.id;
    if c.status <> 'needs_reconnect' then
      perform public.zella_platform_alert('meta_disconnected', 'Facebook/Instagram needs to be reconnected', left(coalesce(p_error, 'access token rejected'), 200), 'urgent', c.business_id, p_page_id);
      perform public.zella_notify_owners(c.business_id, 'meta_disconnected', 'Reconnect Facebook/Instagram', 'Zella lost access to your page, so new leads and messages are not coming in. Reconnect it in Settings > Integrations.', 'urgent', 'integrations');
    end if;
  else
    update public.meta_connections set status = 'error', last_error = left(coalesce(p_error, 'unknown'), 200), last_checked_at = now(), next_check_at = now() + interval '30 minutes' where id = c.id;
  end if;
end $$;
revoke execute on function public.zella_meta_record_check(text, boolean, text[], boolean, text) from public, anon, authenticated;
grant execute on function public.zella_meta_record_check(text, boolean, text[], boolean, text) to service_role;

create or replace function public.zella_meta_record_templates(p_page_id text, p_templates jsonb) returns integer
language plpgsql security definer set search_path = public as $$
declare c public.meta_connections%rowtype; t jsonb; n integer := 0;
begin
  select * into c from public.meta_connections where page_id = p_page_id;
  if not found or jsonb_typeof(p_templates) <> 'array' then return 0; end if;
  for t in select * from jsonb_array_elements(p_templates) loop
    continue when nullif(t ->> 'name', '') is null;
    insert into public.meta_templates (business_id, name, language, category, body, status, synced_at)
    values (c.business_id, left(t ->> 'name', 100), coalesce(nullif(t ->> 'language', ''), 'en_US'), left(t ->> 'category', 40), left(t ->> 'body', 1024), lower(coalesce(t ->> 'status', 'unknown')), now())
    on conflict (business_id, name, language) do update set category = excluded.category, body = excluded.body, status = excluded.status, synced_at = now();
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.zella_meta_record_templates(text, jsonb) from public, anon, authenticated;
grant execute on function public.zella_meta_record_templates(text, jsonb) to service_role;

create or replace function public.zella_meta_status(p_business_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('page_id', page_id, 'page_name', page_name, 'instagram', instagram_id is not null, 'whatsapp', whatsapp_phone_id is not null,
    'status', status, 'permissions', granted_permissions, 'call_consent_confirmed', call_consent_confirmed, 'auto_acknowledge', auto_acknowledge,
    'comment_keywords', comment_keywords, 'last_checked_at', last_checked_at, 'last_error', last_error) order by created_at) from public.meta_connections where business_id = p_business_id), '[]'::jsonb);
end $$;
revoke execute on function public.zella_meta_status(uuid) from public, anon;
grant execute on function public.zella_meta_status(uuid) to authenticated, service_role;
