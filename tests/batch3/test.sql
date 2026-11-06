-- Batch 3 pagination checks (sql/zella_batch3_pagination.sql) on an ISOLATED copy of the production schema
-- (tests/batch3/run.sh). Synthetic data only (ids b3…, *.b3.test, numbers +1555…); everything is rolled back.
-- Fixture: business Alpha with 1,200 leads, 620 job records (plus 40 properties they link to), 360 calls and 260
-- conversations, opt-outs, open escalations, transcripts and recordings; business Beta with a handful of each.
-- People: Alpha owner, Alpha staff (may not read call content), Alpha viewer, Beta owner, and a signed-in outsider.
\set ON_ERROR_STOP on
\timing off
begin;
\ir fixture.sql
create or replace function pg_temp.as_user(u text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'aal', 'aal1')::text, true) $$;
create temp table expect (k text primary key, n bigint) on commit drop;
grant all on expect to authenticated;
-- the expected answers, computed directly (as the database owner) from the same rules the browser used
insert into expect
select 'leads', count(*) from public.customers p where business_id = 'b3000000-0000-0000-0000-0000000000a1' and (lead_stage is not null or created_at > now() - interval '30 days')
union all select 'overdue', count(*) from public.customers p where business_id = 'b3000000-0000-0000-0000-0000000000a1'
   and (lead_stage is not null or created_at > now() - interval '30 days') and coalesce(lead_stage, 'new') not in ('won', 'lost', 'unqualified')
   and (next_follow_up_at < now() or (coalesce(lead_stage, 'new') = 'new' and contact_deadline_at < now()))
union all select 'staff_mine', count(*) from public.customers where business_id = 'b3000000-0000-0000-0000-0000000000a1' and (lead_stage is not null or created_at > now() - interval '30 days') and assigned_to = 'b3000000-0000-0000-0000-00000000000b'
union all select 'referral', count(*) from public.customers where business_id = 'b3000000-0000-0000-0000-0000000000a1' and source ~* 'refer'
union all select 'jobs_open', count(*) from public.crm_records where business_id = 'b3000000-0000-0000-0000-0000000000a1' and type_key = 'b3jobs' and archived_at is null and status <> 'done'
union all select 'jobs_all', count(*) from public.crm_records where business_id = 'b3000000-0000-0000-0000-0000000000a1' and type_key = 'b3jobs' and archived_at is null
union all select 'jobs_done', count(*) from public.crm_records where business_id = 'b3000000-0000-0000-0000-0000000000a1' and type_key = 'b3jobs' and archived_at is null and status = 'done'
union all select 'calls', count(*) from public.calls where business_id = 'b3000000-0000-0000-0000-0000000000a1'
union all select 'missed', count(*) from public.calls where business_id = 'b3000000-0000-0000-0000-0000000000a1' and status = 'missed'
union all select 'human', count(*) from public.calls where business_id = 'b3000000-0000-0000-0000-0000000000a1' and needs_human and escalation_resolved_at is null
union all select 'recorded', count(*) from public.calls where business_id = 'b3000000-0000-0000-0000-0000000000a1' and recording_url is not null and (metadata ->> 'recording_consent') is distinct from 'false'
union all select 'missed_open', count(*) from public.calls c where business_id = 'b3000000-0000-0000-0000-0000000000a1' and status = 'missed' and metadata ->> 'followed_up_at' is null
   and not exists (select 1 from public.callbacks b where b.call_id = c.id)
union all select 'convos_shown', count(*) from public.conversations x where business_id = 'b3000000-0000-0000-0000-0000000000a1'
   and not exists (select 1 from public.calls c where c.conversation_id = x.id)
union all select 'unread', count(*) from public.conversations x where business_id = 'b3000000-0000-0000-0000-0000000000a1'
   and not exists (select 1 from public.calls c where c.conversation_id = x.id) and last_inbound_at is not null and (last_read_at is null or last_inbound_at > last_read_at)
union all select 'sms', count(*) from public.conversations x where business_id = 'b3000000-0000-0000-0000-0000000000a1' and channel = 'sms'
   and not exists (select 1 from public.calls c where c.conversation_id = x.id)
union all select 'convo_human', count(*) from public.conversations x where business_id = 'b3000000-0000-0000-0000-0000000000a1' and not ai_handled and handover_at is not null and status <> 'closed'
   and not exists (select 1 from public.calls c where c.conversation_id = x.id);
select 'FIXTURE leads=' || (select n from expect where k = 'leads') || ' jobs=' || (select n from expect where k = 'jobs_all')
    || ' calls=' || (select n from expect where k = 'calls') || ' conversations shown=' || (select n from expect where k = 'convos_shown');

-- walk every page of a function, as the signed-in person, and return every row's id in order
create or replace function pg_temp.walk(fn text, args text, page_size int) returns table (n int, id uuid, at text, kind text)
language plpgsql as $$
declare cur jsonb := null; res jsonb; r jsonb; i int := 0; pages int := 0;
begin
  loop
    execute format('select public.%s(%s, p_limit => %s, p_after => $1)', fn, args, page_size) into res using cur;
    for r in select * from jsonb_array_elements(res -> 'rows') loop
      i := i + 1; n := i; id := (r ->> 'id')::uuid; kind := r ->> 'kind';
      at := coalesce(r ->> 'at', r ->> 'updated_at', r ->> 'created_at'); return next;
    end loop;
    pages := pages + 1;
    exit when res -> 'next' is null or res -> 'next' = 'null'::jsonb or pages > 500;
    cur := res -> 'next';
  end loop;
end $$;
grant execute on function pg_temp.walk(text, text, int) to authenticated;

set local role authenticated;
select pg_temp.as_user('b3000000-0000-0000-0000-00000000000a');

-- ===================================================================== B3-03 leads
do $$ declare total bigint; distinct_n bigint; ordered boolean; r jsonb; s jsonb; begin
  select count(*), count(distinct id), bool_and(ok) into total, distinct_n, ordered from (
    select id, coalesce(lag(at) over (order by n) >= at, true) ok from pg_temp.walk('zella_leads_page', '''b3000000-0000-0000-0000-0000000000a1''', 25)) q;
  if total <> (select n from expect where k = 'leads') or distinct_n <> total or not ordered then
    raise exception 'leads walk: % rows, % distinct, ordered %, expected %', total, distinct_n, ordered, (select n from expect where k = 'leads'); end if;
  if total <= 1000 then raise exception 'fixture too small'; end if;
  r := public.zella_leads_page('b3000000-0000-0000-0000-0000000000a1');
  if (r ->> 'total')::int <> total or (r ->> 'overdue_total')::int <> (select n from expect where k = 'overdue') then raise exception 'lead counts %', r - 'rows'; end if;
  if (select sum(value::int) from jsonb_each_text(r -> 'columns')) <> total then raise exception 'stage totals do not add up: %', r -> 'columns'; end if;
  if jsonb_array_length(r -> 'rows') <> 25 then raise exception 'page size'; end if;
end $$;
select 'PASS leads: all ' || (select n from expect where k = 'leads') || ' leads reachable in pages of 25, each once, newest first; total, overdue and stage totals match the whole set';

do $$ declare r jsonb; b jsonb; begin
  r := public.zella_leads_page('b3000000-0000-0000-0000-0000000000a1', p_query => 'zephyr');
  if (r ->> 'total')::int <> 1 or r -> 'rows' -> 0 ->> 'id' <> 'b3000000-0000-0000-0000-0000000001aa' then raise exception 'search for the oldest lead: %', r; end if;
  r := public.zella_leads_page('b3000000-0000-0000-0000-0000000000a1', p_filter => 'overdue');
  if (r ->> 'total')::int <> (select n from expect where k = 'overdue') then raise exception 'overdue filter %', r ->> 'total'; end if;
  if not exists (select 1 from pg_temp.walk('zella_leads_page', '''b3000000-0000-0000-0000-0000000000a1'', p_filter => ''overdue''', 100) where id = 'b3000000-0000-0000-0000-0000000001aa')
    then raise exception 'oldest overdue lead missing from the overdue pages'; end if;
  r := public.zella_leads_page('b3000000-0000-0000-0000-0000000000a1', p_source => 'referral');
  if (r ->> 'total')::int <> (select n from expect where k = 'referral') then raise exception 'source filter % vs %', r ->> 'total', (select n from expect where k = 'referral'); end if;
  r := public.zella_leads_page('b3000000-0000-0000-0000-0000000000a1', p_filter => 'mine');
  if (r ->> 'total')::int <> (select count(*) from public.customers where business_id = 'b3000000-0000-0000-0000-0000000000a1' and (lead_stage is not null or created_at > now() - interval '30 days') and assigned_to = 'b3000000-0000-0000-0000-00000000000a') then raise exception 'mine %', r ->> 'total'; end if;
  r := public.zella_leads_page('b3000000-0000-0000-0000-0000000000a1', p_assignee => 'none');
  if (r ->> 'total')::int <> (select count(*) from public.customers where business_id = 'b3000000-0000-0000-0000-0000000000a1' and (lead_stage is not null or created_at > now() - interval '30 days') and assigned_to is null) then raise exception 'unassigned %', r ->> 'total'; end if;
  r := public.zella_leads_page('b3000000-0000-0000-0000-0000000000a1', p_assignee => 'b3000000-0000-0000-0000-00000000000b');
  if (r ->> 'total')::int <> (select count(*) from public.customers where business_id = 'b3000000-0000-0000-0000-0000000000a1' and (lead_stage is not null or created_at > now() - interval '30 days') and assigned_to = 'b3000000-0000-0000-0000-00000000000b') then raise exception 'assignee %', r ->> 'total'; end if;
  b := public.zella_leads_page('b3000000-0000-0000-0000-0000000000a1', p_view => 'pipeline', p_limit => 40);
  if jsonb_array_length(b -> 'rows') <> 200 or b -> 'columns' <> (public.zella_leads_page('b3000000-0000-0000-0000-0000000000a1')) -> 'columns' then
    raise exception 'pipeline: % rows, columns %', jsonb_array_length(b -> 'rows'), b -> 'columns'; end if;
  begin perform public.zella_leads_page('b3000000-0000-0000-0000-0000000000a1', p_after => '{"t":"x"}'); raise exception 'bad cursor accepted';
  exception when sqlstate '22023' then null; end;
  begin perform public.zella_leads_page('b3000000-0000-0000-0000-0000000000a1', p_filter => 'drop table'); raise exception 'bad filter accepted';
  exception when sqlstate '22023' then null; end;
end $$;
select 'PASS leads: search, overdue, source, mine, unassigned and assignee filters count the whole set (the lead older than the newest 1,000 is found); pipeline totals equal list totals; bad cursors and filters are refused';

-- ===================================================================== B3-04 records and B3-07 links
do $$ declare total bigint; distinct_n bigint; ordered boolean; r jsonb; begin
  select count(*), count(distinct id), bool_and(ok) into total, distinct_n, ordered from (
    select id, coalesce(lag(at) over (order by n) >= at, true) ok
      from pg_temp.walk('zella_records_page', '''b3000000-0000-0000-0000-0000000000a1'', ''b3jobs'', ''all''', 25)) q;
  if total <> (select n from expect where k = 'jobs_all') or distinct_n <> total or not ordered or total <= 500 then
    raise exception 'records walk % / % / %', total, distinct_n, ordered; end if;
  r := public.zella_records_page('b3000000-0000-0000-0000-0000000000a1', 'b3jobs', 'open');
  if (r ->> 'total')::int <> (select n from expect where k = 'jobs_open') then raise exception 'open %', r ->> 'total'; end if;
  r := public.zella_records_page('b3000000-0000-0000-0000-0000000000a1', 'b3jobs', 'closed');
  if (r ->> 'total')::int <> (select n from expect where k = 'jobs_done') then raise exception 'closed %', r ->> 'total'; end if;
  r := public.zella_records_page('b3000000-0000-0000-0000-0000000000a1', 'b3jobs', 'scheduled');
  if exists (select 1 from jsonb_array_elements(r -> 'rows') x where x ->> 'status' <> 'scheduled') then raise exception 'status filter'; end if;
  r := public.zella_records_page('b3000000-0000-0000-0000-0000000000a1', 'b3jobs', 'open', 'brass valve');
  if (r ->> 'total')::int <> 1 or r -> 'rows' -> 0 ->> 'id' <> 'b3000000-0000-0000-0000-0000000004aa' then raise exception 'search the oldest record: %', r ->> 'total'; end if;
  if exists (select 1 from pg_temp.walk('zella_records_page', '''b3000000-0000-0000-0000-0000000000a1'', ''b3jobs'', ''all''', 100) w
              join public.crm_records x on x.id = w.id where x.archived_at is not null) then raise exception 'archived record listed'; end if;
  -- B3-07: titles for the links on one page resolve under row security; the Beta record id resolves to nothing
  if (select count(*) from public.crm_records where id in (select (x -> 'data' ->> 'property')::uuid from jsonb_array_elements(
        public.zella_records_page('b3000000-0000-0000-0000-0000000000a1', 'b3jobs', 'all', p_limit => 25) -> 'rows') x)) <> 25 then
    raise exception 'linked titles on a page do not resolve'; end if;
  if exists (select 1 from public.crm_records where id = 'b3000000-0000-0000-0000-0000000004b1') then raise exception 'Beta record title visible to Alpha'; end if;
end $$;
select 'PASS records: all ' || (select n from expect where k = 'jobs_all') || ' jobs reachable (more than 500), each once, in order; open, finished and status filters and search count the whole set; archived stay out; linked titles resolve per page and another business''s record never does';

-- ===================================================================== B3-05 calls
do $$ declare total bigint; distinct_n bigint; ordered boolean; r jsonb; f text; begin
  select count(*), count(distinct id), bool_and(ok) into total, distinct_n, ordered from (
    select id, coalesce(lag(at) over (order by n) >= at, true) ok from pg_temp.walk('zella_calls_page', '''b3000000-0000-0000-0000-0000000000a1''', 25)) q;
  if total <> (select n from expect where k = 'calls') or distinct_n <> total or not ordered or total <= 300 then raise exception 'calls walk % / % / %', total, distinct_n, ordered; end if;
  foreach f in array array['missed', 'human', 'recorded'] loop
    r := public.zella_calls_page('b3000000-0000-0000-0000-0000000000a1', f);
    if (r ->> 'total')::int <> (select n from expect where k = f) then raise exception '% filter: % vs %', f, r ->> 'total', (select n from expect where k = f); end if;
  end loop;
  r := public.zella_calls_page('b3000000-0000-0000-0000-0000000000a1');
  if (r ->> 'missed_open')::int <> (select n from expect where k = 'missed_open') then raise exception 'missed_open %', r ->> 'missed_open'; end if;
  if exists (select 1 from jsonb_array_elements(r -> 'rows') x where x ? 'transcript' or x ? 'recording_url') then raise exception 'list carries call content'; end if;
  if (select count(*) from pg_temp.walk('zella_calls_page', '''b3000000-0000-0000-0000-0000000000a1'', p_filter => ''human''', 2)) <> (select n from expect where k = 'human') then
    raise exception 'needs-a-person pages'; end if;
  -- follow-ups ride along with their calls
  r := public.zella_calls_page('b3000000-0000-0000-0000-0000000000a1', 'missed', p_limit => 100);
  if (select count(*) from jsonb_array_elements(r -> 'rows') x where jsonb_array_length(x -> 'follow_ups') > 0) < 1 then raise exception 'follow-ups missing'; end if;
  r := public.zella_calls_page('b3000000-0000-0000-0000-0000000000a1', p_transcripts_only => true);
  if (r ->> 'total')::int <> (select count(*) from public.calls_view where business_id = 'b3000000-0000-0000-0000-0000000000a1' and (coalesce(transcript, '') <> '' or (recording_url is not null and (metadata ->> 'recording_consent') is distinct from 'false'))) then
    raise exception 'transcripts-only %', r ->> 'total'; end if;
end $$;
select 'PASS calls: all ' || (select n from expect where k = 'calls') || ' calls reachable (more than 300), each once, newest first; missed, needs-a-person and recordings filters and the open missed-call count cover the whole history; the list carries no transcripts or recording links; follow-ups attach to their calls';

-- ===================================================================== B3-02 inbox and B3-06 previews
do $$ declare total bigint; distinct_n bigint; ordered boolean; calls_n bigint; convos_n bigint; r jsonb; pv record; begin
  select count(*), count(distinct kind || id), bool_and(ok), count(*) filter (where kind = 'call'), count(*) filter (where kind = 'convo')
    into total, distinct_n, ordered, calls_n, convos_n from (
    select id, kind, coalesce(lag(at::timestamptz) over (order by n) >= at::timestamptz, true) ok
      from pg_temp.walk('zella_inbox_page', '''b3000000-0000-0000-0000-0000000000a1''', 50)) q;
  if calls_n <> (select n from expect where k = 'calls') or convos_n <> (select n from expect where k = 'convos_shown') or distinct_n <> total or not ordered then
    raise exception 'inbox walk: calls % convos % distinct % of % ordered %', calls_n, convos_n, distinct_n, total, ordered; end if;
  if total <= 200 then raise exception 'fixture too small'; end if;
  r := public.zella_inbox_page('b3000000-0000-0000-0000-0000000000a1');
  if (r ->> 'unread_total')::int <> (select n from expect where k = 'unread') then raise exception 'unread %', r ->> 'unread_total'; end if;
  if (public.zella_inbox_page('b3000000-0000-0000-0000-0000000000a1', 'unread') ->> 'total')::int <> (select n from expect where k = 'unread') then raise exception 'unread filter'; end if;
  if (public.zella_inbox_page('b3000000-0000-0000-0000-0000000000a1', 'sms') ->> 'total')::int <> (select n from expect where k = 'sms') then raise exception 'sms filter'; end if;
  if (public.zella_inbox_page('b3000000-0000-0000-0000-0000000000a1', 'missed') ->> 'total')::int <> (select n from expect where k = 'missed') then raise exception 'missed filter'; end if;
  if (public.zella_inbox_page('b3000000-0000-0000-0000-0000000000a1', 'human') ->> 'total')::int <> (select n from expect where k = 'human') + (select n from expect where k = 'convo_human') then raise exception 'human filter'; end if;
  if (public.zella_inbox_page('b3000000-0000-0000-0000-0000000000a1', 'calls') ->> 'total')::int <> (select n from expect where k = 'calls') then raise exception 'calls filter'; end if;
  -- previews: one short line per listed conversation, never the whole body
  for pv in select * from public.zella_inbox_previews('b3000000-0000-0000-0000-0000000000a1',
      (select array_agg((x ->> 'id')::uuid) from jsonb_array_elements(r -> 'rows') x where x ->> 'kind' = 'convo')) loop
    if length(pv.preview) > 160 or pv.preview not like 'Message 5 %' then raise exception 'preview %', pv.preview; end if;
  end loop;
end $$;
select 'PASS inbox: all ' || (select n from expect where k = 'calls') || ' calls and ' || (select n from expect where k = 'convos_shown') || ' conversations in one list, interleaved by time, each once; unread, texts, missed, calls and needs-a-person filters count the whole set; previews are the latest message, at most 160 characters';

-- a row added in front of the list between two page loads doesn't repeat or skip anything
do $$ declare p1 jsonb; p2 jsonb; ids uuid[]; ids2 uuid[]; begin
  p1 := public.zella_inbox_page('b3000000-0000-0000-0000-0000000000a1', p_limit => 30);
  reset role;
  insert into public.conversations (business_id, channel, status, last_message_at) values ('b3000000-0000-0000-0000-0000000000a1', 'sms', 'open', now() + interval '1 minute');
  set local role authenticated;
  p2 := public.zella_inbox_page('b3000000-0000-0000-0000-0000000000a1', p_limit => 30, p_after => p1 -> 'next');
  select array_agg((x ->> 'id')::uuid) into ids from jsonb_array_elements(p1 -> 'rows') x;
  select array_agg((x ->> 'id')::uuid) into ids2 from jsonb_array_elements(p2 -> 'rows') x;
  if ids && ids2 then raise exception 'a row repeated across pages'; end if;
  if (public.zella_inbox_page('b3000000-0000-0000-0000-0000000000a1', p_limit => 60)) -> 'rows' -> 31 ->> 'id' <> (p2 -> 'rows' -> 0 ->> 'id') then
    raise exception 'the second page does not continue where the first ended'; end if;
end $$;
select 'PASS cursors: a conversation arriving between page loads is not repeated and nothing is skipped (keyset cursor)';

-- ===================================================================== roles and tenants
-- staff: no call content (calls_view hides it); the list says no transcript or recording exists to them
select pg_temp.as_user('b3000000-0000-0000-0000-00000000000b');
do $$ declare r jsonb; begin
  r := public.zella_calls_page('b3000000-0000-0000-0000-0000000000a1', p_limit => 100);
  if exists (select 1 from jsonb_array_elements(r -> 'rows') x where (x ->> 'has_transcript')::boolean or (x ->> 'has_recording')::boolean) then raise exception 'staff learn of call content'; end if;
  if (public.zella_calls_page('b3000000-0000-0000-0000-0000000000a1', 'recorded') ->> 'total')::int <> 0 then raise exception 'staff see recordings'; end if;
  if (public.zella_calls_page('b3000000-0000-0000-0000-0000000000a1', p_transcripts_only => true) ->> 'total')::int <> 0 then raise exception 'staff see transcripts'; end if;
  if (r ->> 'total')::int <> (select n from expect where k = 'calls') then raise exception 'staff call total'; end if;
  if (public.zella_leads_page('b3000000-0000-0000-0000-0000000000a1', p_filter => 'mine') ->> 'total')::int <> (select n from expect where k = 'staff_mine') then raise exception 'staff mine'; end if;
end $$;
select 'PASS roles: Alpha staff (no call-content permission) page every call but see no transcript, recording, or sign that one exists; "Mine" is their own leads';
select pg_temp.as_user('b3000000-0000-0000-0000-00000000000c');
do $$ begin
  if (public.zella_leads_page('b3000000-0000-0000-0000-0000000000a1') ->> 'total')::int <> (select n from expect where k = 'leads') then raise exception 'viewer leads'; end if;
  if (public.zella_records_page('b3000000-0000-0000-0000-0000000000a1', 'b3jobs', 'all') ->> 'total')::int <> (select n from expect where k = 'jobs_all') then raise exception 'viewer records'; end if;
end $$;
select 'PASS roles: Alpha viewer reads the same lists (read-only access is unchanged)';

-- Alpha people can't page Beta, Beta's owner sees only Beta, an outsider and the anonymous role see nothing
select pg_temp.as_user('b3000000-0000-0000-0000-00000000000a');
do $$ declare fn text; begin
  foreach fn in array array[
    'select public.zella_leads_page(''b3000000-0000-0000-0000-0000000000b1'')',
    'select public.zella_records_page(''b3000000-0000-0000-0000-0000000000b1'', ''b3jobs'')',
    'select public.zella_calls_page(''b3000000-0000-0000-0000-0000000000b1'')',
    'select public.zella_inbox_page(''b3000000-0000-0000-0000-0000000000b1'')',
    'select public.zella_inbox_previews(''b3000000-0000-0000-0000-0000000000b1'', array[(select id from public.conversations limit 1)])'] loop
    begin execute fn; raise exception 'cross-tenant allowed: %', fn; exception when sqlstate '42501' then null; end;
  end loop;
  -- Alpha's own call asking for Beta conversation previews gets nothing back
  if exists (select 1 from public.zella_inbox_previews('b3000000-0000-0000-0000-0000000000a1',
       array(select id from public.conversations where business_id = 'b3000000-0000-0000-0000-0000000000b1'))) then raise exception 'Beta previews leaked'; end if;
end $$;
select pg_temp.as_user('b3000000-0000-0000-0000-00000000000d');
do $$ declare r jsonb; begin
  r := public.zella_inbox_page('b3000000-0000-0000-0000-0000000000b1');
  if (r ->> 'total')::int <> 10 then raise exception 'Beta inbox %', r ->> 'total'; end if;
  if (public.zella_leads_page('b3000000-0000-0000-0000-0000000000b1') ->> 'total')::int <> 5 then raise exception 'Beta leads'; end if;
  begin perform public.zella_calls_page('b3000000-0000-0000-0000-0000000000a1'); raise exception 'Beta reads Alpha'; exception when sqlstate '42501' then null; end;
end $$;
select pg_temp.as_user('b3000000-0000-0000-0000-00000000000e');
do $$ begin
  begin perform public.zella_leads_page('b3000000-0000-0000-0000-0000000000a1'); raise exception 'outsider allowed'; exception when sqlstate '42501' then null; end;
end $$;
reset role;
set local role anon;
do $$ begin
  begin perform public.zella_inbox_page('b3000000-0000-0000-0000-0000000000a1'); raise exception 'anon allowed'; exception when insufficient_privilege then null; end;
end $$;
reset role;
select 'PASS tenants: Alpha''s owner is refused on all five Beta functions and gets no Beta previews; Beta''s owner sees only Beta and is refused on Alpha; an outsider and the anonymous role are refused';

-- every new function runs as the caller (no new SECURITY DEFINER) and has a fixed search path
do $$ declare bad text; begin
  select string_agg(proname, ', ') into bad from pg_proc where pronamespace = 'public'::regnamespace
     and proname in ('zella_b3_member', 'zella_b3_like', 'zella_b3_cursor',
                     'zella_leads_page', 'zella_records_page', 'zella_call_row', 'zella_calls_page', 'zella_inbox_page', 'zella_inbox_previews')
     and (prosecdef or proconfig is null);
  if bad is not null then raise exception 'definer or no search path: %', bad; end if;
end $$;
select 'PASS functions: all eight new functions are SECURITY INVOKER with a fixed search path';

-- performance, as Alpha's owner, first page of each (milliseconds; the fixture is ~2,500 rows across the lists)
set local role authenticated;
select pg_temp.as_user('b3000000-0000-0000-0000-00000000000a');
do $$ declare t0 timestamptz; ms text := ''; q text; begin
  foreach q in array array[
    'select public.zella_leads_page(''b3000000-0000-0000-0000-0000000000a1'')',
    'select public.zella_leads_page(''b3000000-0000-0000-0000-0000000000a1'', p_query => ''zephyr'')',
    'select public.zella_records_page(''b3000000-0000-0000-0000-0000000000a1'', ''b3jobs'', ''open'', ''brass'')',
    'select public.zella_calls_page(''b3000000-0000-0000-0000-0000000000a1'')',
    'select public.zella_inbox_page(''b3000000-0000-0000-0000-0000000000a1'')'] loop
    t0 := clock_timestamp(); execute q; ms := ms || ' ' || round(extract(epoch from clock_timestamp() - t0) * 1000) || 'ms';
  end loop;
  raise notice 'PERF leads / leads search / records search / calls / inbox:%', ms;
end $$;
rollback;
