-- Batch 3 (6 Nov 2026): server-side pages for the CRM's long lists. Safe to run twice.
-- Rollback: sql/rollback/zella_batch3_pagination_rollback.sql
--
-- B3-02 inbox, B3-03 leads, B3-04 records, B3-05 calls. Each page loaded the newest N rows (150-1,000) and filtered,
-- counted and paged them in the browser, so anything older was unreachable and counts were wrong past the cap.
--
-- Every function here is SECURITY INVOKER: it runs as the signed-in person, so row security on customers, crm_records,
-- conversations, conversation_messages and callbacks applies exactly as it does to the screens' direct reads today,
-- and calls are read only through calls_view (membership, the calls module, MFA, and the recording / transcript
-- privacy rule). Each one also refuses a business the caller doesn't belong to, so a wrong id is an error rather than
-- an empty page. No new privileges.
--
-- Paging is keyset (cursor) paging: rows are ordered by a timestamp and then the id, and the next page starts strictly
-- after the last row of this one. A row can't appear on two pages or be skipped because rows were added in front of
-- it; a cursor whose row was deleted still works (it is the values, not a lookup). Page sizes are 1 to 100.
-- Counts are computed over everything that matches, not over the loaded page.

create or replace function public.zella_b3_member(p_business_id uuid) returns void
language plpgsql stable security invoker set search_path = public as $$
begin
  if p_business_id is null or not public.is_business_member(p_business_id) then
    raise exception 'NOT_A_MEMBER' using errcode = '42501';
  end if;
end $$;

create or replace function public.zella_b3_like(p_query text) returns text
language sql immutable set search_path = public as $$
  select case when nullif(trim(coalesce(p_query, '')), '') is null then null
              else '%' || replace(replace(replace(left(trim(p_query), 100), '\', '\\'), '%', '\%'), '_', '\_') || '%' end
$$;

-- the cursor's timestamp and id, or null for the first page; a malformed cursor is refused (not treated as page 1)
create or replace function public.zella_b3_cursor(p_after jsonb, out t timestamptz, out id uuid, out k integer)
language plpgsql stable set search_path = public as $$
begin
  if p_after is null or p_after = 'null'::jsonb then return; end if;
  begin
    t := (p_after ->> 't')::timestamptz; id := (p_after ->> 'id')::uuid; k := coalesce((p_after ->> 'k')::integer, 0);
  exception when others then raise exception 'BAD_CURSOR' using errcode = '22023';
  end;
  if t is null or id is null then raise exception 'BAD_CURSOR' using errcode = '22023'; end if;
end $$;

---------------------------------------------------------------------------------------------------------------------
-- B3-03 leads
-- Same rules as the Leads page had in the browser (BusinessLeads.jsx): a lead is anyone with a lead stage, or anyone
-- added in the last 30 days; the stage of someone without one is "contacted" once contacted, else "new"; overdue is an
-- open lead past its follow-up, or a new one past its first-contact deadline; sources are grouped by the same patterns.
-- The rules are written into the query rather than called as helper functions: a function with a fixed search path
-- can't be inlined, and calling three of them per row made a 13,000-lead business take ~2 s per page.
create or replace function public.zella_leads_page(p_business_id uuid, p_filter text default 'all', p_source text default 'all',
  p_assignee text default 'all', p_query text default null, p_view text default 'list', p_limit integer default 25, p_after jsonb default null)
returns jsonb
language plpgsql stable security invoker set search_path = public as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 100);
  v_like text := public.zella_b3_like(p_query);
  v_assignee uuid;
  c record;
  v_out jsonb;
begin
  perform public.zella_b3_member(p_business_id);
  if coalesce(p_filter, '') not in ('all', 'follow', 'overdue', 'mine') or coalesce(p_source, '') not in ('all', 'ai_call', 'website', 'referral', 'manual')
     or coalesce(p_view, '') not in ('list', 'pipeline') then raise exception 'BAD_FILTER' using errcode = '22023'; end if;
  if coalesce(p_assignee, '') not in ('all', 'none') then
    begin v_assignee := p_assignee::uuid; exception when others then raise exception 'BAD_FILTER' using errcode = '22023'; end;
  end if;
  select * into c from public.zella_b3_cursor(p_after);

  with base as (
    select p.created_at, p.id,
           case when x.stage in ('qualified', 'quote_sent') then 'qualified' when x.stage = 'won' then 'converted'
                when x.stage in ('lost', 'unqualified') then 'lost' when x.stage = 'contacted' then 'contacted' else 'new' end col, x.overdue,
           (p_filter <> 'follow' or (x.stage not in ('won', 'lost', 'unqualified') and (x.stage = 'new' or p.next_follow_up_at is not null or x.overdue)))
       and (p_filter <> 'overdue' or x.overdue)
       and (p_filter <> 'mine' or p.assigned_to = auth.uid())
       and (p_source = 'all' or p_source = case when lower(coalesce(p.source, '')) ~ '(call|phone|voice|ai|receptionist)' then 'ai_call'
                                                when lower(coalesce(p.source, '')) ~ '(web|form|site|online|chat)' then 'website'
                                                when lower(coalesce(p.source, '')) ~ 'refer' then 'referral' else 'manual' end)
       and (p_assignee = 'all' or (p_assignee = 'none' and p.assigned_to is null) or p.assigned_to = v_assignee)
       and (v_like is null or concat_ws(' ', p.first_name, p.last_name) ilike v_like or p.phone ilike v_like or p.email ilike v_like
            or p.company_name ilike v_like) matches
      from public.customers p
     cross join lateral (select coalesce(p.lead_stage, case when p.last_contacted_at is not null then 'contacted' else 'new' end) stage) s
     cross join lateral (select s.stage, s.stage not in ('won', 'lost', 'unqualified')
                           and coalesce(p.next_follow_up_at < now() or (s.stage = 'new' and p.contact_deadline_at < now()), false) overdue) x
     where p.business_id = p_business_id and (p.lead_stage is not null or p.created_at > now() - interval '30 days')
  ), page as (
    select created_at, id from base
     where matches and p_view = 'list' and (c.t is null or (created_at, id) < (c.t, c.id))
     order by created_at desc, id desc limit v_limit + 1
  ), board as (
    -- pipeline: the newest of each column, up to the page size; the column totals are in "columns"
    select created_at, id from (
      select created_at, id, row_number() over (partition by col order by created_at desc, id desc) rn from base where matches and p_view = 'pipeline') q
     where rn <= v_limit
  ), shown as (
    select created_at, id from board
    union all
    select * from (select created_at, id from page order by created_at desc, id desc limit v_limit) q
  )
  select jsonb_build_object(
    -- whole rows only for what is shown
    'rows', (select coalesce(jsonb_agg(to_jsonb(p) order by s.created_at desc, s.id desc), '[]') from shown s join public.customers p on p.id = s.id),
    'next', case when p_view = 'list' and (select count(*) from page) > v_limit
                 then (select jsonb_build_object('t', created_at, 'id', id) from (select * from page order by created_at desc, id desc offset v_limit - 1 limit 1) q) end,
    'total', (select count(*) from base where matches),
    'overdue_total', (select count(*) from base where overdue),
    'columns', (select coalesce(jsonb_object_agg(col, n), '{}') from (select col, count(*) n from base where matches group by col) q))
  into v_out;
  return v_out;
end $$;

---------------------------------------------------------------------------------------------------------------------
-- B3-04 records: one record type, newest change first. Archived records stay out, as before. Sensitive values were
-- never in crm_records.data (they are in crm_record_secrets, read only through zella_record_secrets), so nothing new
-- is exposed. Row security on crm_records (membership, the type enabled) and on customers applies.
create or replace function public.zella_records_page(p_business_id uuid, p_type_key text, p_filter text default 'open',
  p_query text default null, p_limit integer default 25, p_after jsonb default null)
returns jsonb
language plpgsql stable security invoker set search_path = public as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 100);
  v_like text := public.zella_b3_like(p_query);
  v_closed text[];
  c record;
  v_out jsonb;
begin
  perform public.zella_b3_member(p_business_id);
  select t.closed_statuses into v_closed from public.crm_record_types t where t.business_id = p_business_id and t.key = p_type_key;
  if not found then raise exception 'RECORD_TYPE_NOT_FOUND' using errcode = '22023'; end if;
  if p_filter is null or length(p_filter) > 60 then raise exception 'BAD_FILTER' using errcode = '22023'; end if;
  select * into c from public.zella_b3_cursor(p_after);

  with base as (
    select r.updated_at, r.id
      from public.crm_records r
      left join public.customers p on p.id = r.customer_id
     where r.business_id = p_business_id and r.type_key = p_type_key and r.archived_at is null
       and case p_filter when 'open' then not (r.status = any (coalesce(v_closed, '{}')))
                         when 'closed' then r.status = any (coalesce(v_closed, '{}'))
                         when 'all' then true
                         else r.status = p_filter end
       and (v_like is null or r.title ilike v_like or concat_ws(' ', p.first_name, p.last_name) ilike v_like or p.company_name ilike v_like
            or exists (select 1 from jsonb_each_text(case when jsonb_typeof(r.data) = 'object' then r.data else '{}' end) d where d.value ilike v_like))
  ), page as (
    select updated_at, id from base where c.t is null or (updated_at, id) < (c.t, c.id)
     order by updated_at desc, id desc limit v_limit + 1
  )
  select jsonb_build_object(
    'rows', (select coalesce(jsonb_agg(to_jsonb(r) || jsonb_build_object('customers', case when p.id is null then null
               else jsonb_build_object('id', p.id, 'first_name', p.first_name, 'last_name', p.last_name, 'phone', p.phone, 'email', p.email) end)
               order by q.updated_at desc, q.id desc), '[]')
               from (select * from page order by updated_at desc, id desc limit v_limit) q
               join public.crm_records r on r.id = q.id left join public.customers p on p.id = r.customer_id),
    'next', case when (select count(*) from page) > v_limit
                 then (select jsonb_build_object('t', updated_at, 'id', id) from (select * from page order by updated_at desc, id desc offset v_limit - 1 limit 1) q) end,
    'total', (select count(*) from base))
  into v_out;
  return v_out;
end $$;

---------------------------------------------------------------------------------------------------------------------
-- B3-05 calls: the list without transcripts or recording links (those are read from calls_view for the one call that
-- is opened, under the same privacy rule). has_transcript / recording_allowed come from calls_view's own columns, so
-- they say no more than calls_view already does to this person.
create or replace function public.zella_call_row(c public.calls_view) returns jsonb
language sql stable set search_path = public as $$
  select (to_jsonb(c) - 'transcript' - 'recording_url')
      || jsonb_build_object('has_transcript', coalesce(c.transcript, '') <> '',
                            'has_recording', c.recording_url is not null,
                            'recording_allowed', c.recording_url is not null and (c.metadata ->> 'recording_consent') is distinct from 'false')
$$;

create or replace function public.zella_calls_page(p_business_id uuid, p_filter text default 'all', p_transcripts_only boolean default false,
  p_limit integer default 25, p_after jsonb default null)
returns jsonb
language plpgsql stable security invoker set search_path = public as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 100);
  c record;
  v_out jsonb;
begin
  perform public.zella_b3_member(p_business_id);
  if coalesce(p_filter, '') not in ('all', 'answered', 'missed', 'ai', 'human', 'recorded') then raise exception 'BAD_FILTER' using errcode = '22023'; end if;
  select * into c from public.zella_b3_cursor(p_after);

  with base as (
    select v.id, v.created_at, v.status, v.metadata, case p_filter when 'missed' then v.status = 'missed'
                              when 'ai' then coalesce(v.ai_handled, false)
                              when 'answered' then v.status in ('answered', 'completed')
                              when 'human' then coalesce(v.needs_human, false) and v.escalation_resolved_at is null
                              when 'recorded' then v.recording_url is not null and (v.metadata ->> 'recording_consent') is distinct from 'false'
                              else true end matches
      from public.calls_view v
     where v.business_id = p_business_id
       and (not coalesce(p_transcripts_only, false) or coalesce(v.transcript, '') <> ''
            or (v.recording_url is not null and (v.metadata ->> 'recording_consent') is distinct from 'false'))
  ), page as (
    select b.created_at, b.id
      from base b where b.matches and (c.t is null or (b.created_at, b.id) < (c.t, c.id))
     order by b.created_at desc, b.id desc limit v_limit + 1
  ), shown as (
    select * from page order by created_at desc, id desc limit v_limit
  )
  select jsonb_build_object(
    'rows', (select coalesce(jsonb_agg((select public.zella_call_row(v) from public.calls_view v where v.id = s.id) || jsonb_build_object('follow_ups', coalesce((
               select jsonb_agg(f order by f ->> 'due_at') from (
                 select jsonb_build_object('id', b.id, 'kind', 'callback', 'reason', b.reason, 'due_at', b.due_at, 'done', b.status in ('completed', 'cancelled')) f
                   from public.callbacks b where b.call_id = s.id
                 union all
                 select jsonb_build_object('id', t.id, 'kind', 'followup', 'due_at', t.due_at, 'done', t.status in ('completed', 'cancelled'))
                   from public.followup_tasks t where t.call_id = s.id) ff), '[]'))
             order by s.created_at desc, s.id desc), '[]') from shown s),
    'next', case when (select count(*) from page) > v_limit
                 then (select jsonb_build_object('t', created_at, 'id', id) from (select * from shown order by created_at, id limit 1) q) end,
    'total', (select count(*) from base where matches),
    -- missed calls nobody has followed up yet: not marked, and no callback or follow-up call linked
    'missed_open', (select count(*) from base b where b.status = 'missed' and (b.metadata ->> 'followed_up_at') is null
                      and not exists (select 1 from public.callbacks x where x.call_id = b.id)
                      and not exists (select 1 from public.followup_tasks x where x.call_id = b.id)))
  into v_out;
  return v_out;
end $$;

---------------------------------------------------------------------------------------------------------------------
-- B3-02 inbox: calls and conversations in one list, newest activity first. A call's time is when it started (else
-- when it was recorded); a conversation's is its last message (else when it was opened). "call" channel
-- conversations, and conversations a visible call belongs to, are shown through the call, as before. Ties are broken
-- by kind (calls first) and then id, so the order is total and the cursor exact.
create or replace function public.zella_inbox_page(p_business_id uuid, p_filter text default 'all', p_limit integer default 50, p_after jsonb default null)
returns jsonb
language plpgsql stable security invoker set search_path = public as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  c record;
  v_out jsonb;
begin
  perform public.zella_b3_member(p_business_id);
  if coalesce(p_filter, '') not in ('all', 'unread', 'calls', 'sms', 'email', 'missed', 'human') then raise exception 'BAD_FILTER' using errcode = '22023'; end if;
  select * into c from public.zella_b3_cursor(p_after);

  with calls as (
    select v.id, v.started_at, v.created_at, v.status, v.needs_human, v.escalation_resolved_at, v.conversation_id
      from public.calls_view v where v.business_id = p_business_id and coalesce(v.started_at, v.created_at) is not null
  ), base as (
    select 'call' kind, 0 k, coalesce(v.started_at, v.created_at) at, v.id, false unread,
           case p_filter when 'all' then true when 'calls' then true when 'missed' then v.status = 'missed'
                         when 'human' then coalesce(v.needs_human, false) and v.escalation_resolved_at is null else false end matches
      from calls v
    union all
    select 'convo', 1, coalesce(x.last_message_at, x.created_at), x.id, u.unread,
           case p_filter when 'all' then true when 'unread' then u.unread when 'sms' then x.channel = 'sms' when 'email' then x.channel = 'email'
                         when 'human' then not coalesce(x.ai_handled, false) and x.handover_at is not null and x.status <> 'closed' else false end
      from public.conversations x
     cross join lateral (select x.last_inbound_at is not null and (x.last_read_at is null or x.last_inbound_at > x.last_read_at) unread) u
     where x.business_id = p_business_id and x.channel <> 'call' and coalesce(x.last_message_at, x.created_at) is not null
       and not exists (select 1 from calls v where v.conversation_id = x.id)
  ), page as (
    select kind, k, at, id from base
     where matches and (c.t is null or at < c.t or (at = c.t and (k > c.k or (k = c.k and id < c.id))))
     order by at desc, k, id desc limit v_limit + 1
  ), shown as (
    select * from page order by at desc, k, id desc limit v_limit
  )
  select jsonb_build_object(
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('kind', s.kind, 'at', s.at, 'id', s.id, 'row',
               case when s.kind = 'call' then (select public.zella_call_row(v) from public.calls_view v where v.id = s.id)
                    else (select to_jsonb(x) from public.conversations x where x.id = s.id) end) order by s.at desc, s.k, s.id desc), '[]') from shown s),
    'next', case when (select count(*) from page) > v_limit
                 then (select jsonb_build_object('t', at, 'k', k, 'id', id) from (select * from shown order by at, k desc, id limit 1) q) end,
    'total', (select count(*) from base where matches),
    'unread_total', (select count(*) from base where unread))
  into v_out;
  return v_out;
end $$;

-- B3-06: the last message of each listed conversation, as a short preview (never whole message bodies). Separate
-- from the page so a failure here shows "preview unavailable" instead of hiding the inbox. At most 100 conversations.
create or replace function public.zella_inbox_previews(p_business_id uuid, p_conversation_ids uuid[])
returns table (conversation_id uuid, preview text)
language plpgsql stable security invoker set search_path = public as $$
begin
  perform public.zella_b3_member(p_business_id);
  if coalesce(array_length(p_conversation_ids, 1), 0) > 100 then raise exception 'TOO_MANY' using errcode = '22023'; end if;
  return query
    select x.id, left(regexp_replace(m.content, '\s+', ' ', 'g'), 160)
      from public.conversations x
      cross join lateral (select cm.content from public.conversation_messages cm where cm.conversation_id = x.id
                           order by cm.created_at desc limit 1) m
     where x.business_id = p_business_id and x.id = any (p_conversation_ids);
end $$;

-- indexes for the orders used above (the existing ones lead with other columns)
create index if not exists customers_business_created_idx on public.customers (business_id, created_at desc, id desc);
create index if not exists calls_business_created_idx on public.calls (business_id, created_at desc, id desc);
create index if not exists conversations_business_activity_idx on public.conversations (business_id, (coalesce(last_message_at, created_at)) desc, id desc);
create index if not exists conversation_messages_latest_idx on public.conversation_messages (conversation_id, created_at desc);
create index if not exists callbacks_call_idx on public.callbacks (call_id) where call_id is not null;
create index if not exists followup_tasks_call_idx on public.followup_tasks (call_id) where call_id is not null;

revoke execute on function public.zella_b3_member(uuid), public.zella_b3_cursor(jsonb),
  public.zella_leads_page(uuid, text, text, text, text, text, integer, jsonb), public.zella_records_page(uuid, text, text, text, integer, jsonb),
  public.zella_calls_page(uuid, text, boolean, integer, jsonb), public.zella_inbox_page(uuid, text, integer, jsonb),
  public.zella_inbox_previews(uuid, uuid[]), public.zella_call_row(public.calls_view)
  from public, anon;
grant execute on function public.zella_b3_member(uuid), public.zella_b3_cursor(jsonb),
  public.zella_leads_page(uuid, text, text, text, text, text, integer, jsonb), public.zella_records_page(uuid, text, text, text, integer, jsonb),
  public.zella_calls_page(uuid, text, boolean, integer, jsonb), public.zella_inbox_page(uuid, text, integer, jsonb),
  public.zella_inbox_previews(uuid, uuid[]), public.zella_call_row(public.calls_view)
  to authenticated, service_role;
