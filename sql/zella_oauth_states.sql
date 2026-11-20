-- Zella Voice: a calendar sign in can be finished only once, only soon, and only by the person who started it
-- (security audit 18 Nov 2026, 2.7, M8). The calendar-connect state was signed but not stored, so it could be used
-- again within 10 minutes and was not tied to anyone's browser: an owner of business A could start "connect Google",
-- keep the provider's address and get someone else to approve it, and that person's calendar would be linked to A.
-- Now calendar-connect records a random value (only its hash) for each sign in it starts, for the person, business
-- and provider, valid 5 minutes; the provider sends the person back to the app, which finishes the sign in with the
-- person's own Zella Voice sign in; calendar-connect checks it is the same person and uses the stored value up
-- (zella_oauth_state_consume: once, unexpired, same person, business and provider) before it asks the provider for
-- the token. Both functions are for the server key only.
-- Every object is new; a function that exists already must be exactly this file's version (VERSION_MISMATCH).
-- Rollback: sql/rollback/zella_oauth_states_rollback.sql
begin;

do $$
declare f record;
  mine constant jsonb := '{"public.zella_oauth_state_issue(text,uuid,uuid,text,integer)": "26d8f9711f20f6cef0b889c5848cac16",
                           "public.zella_oauth_state_consume(text,uuid,uuid,text)": "bf0ad62b3fdbe27c508c9e836cc8d2d6"}';
begin
  for f in select key, value from jsonb_each_text(mine) loop
    if to_regprocedure(f.key) is not null and md5(pg_get_functiondef(f.key::regprocedure)) <> f.value then
      raise exception 'VERSION_MISMATCH: % already exists in another version', f.key;
    end if;
  end loop;
end $$;

create table if not exists public.oauth_states (
  nonce_hash text primary key check (nonce_hash ~ '^[0-9a-f]{64}$'),
  user_id uuid not null references auth.users (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  provider text not null check (provider in ('google', 'outlook')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz
);
comment on table public.oauth_states is 'Calendar sign ins started by calendar-connect: single use, short lived, server only';
create index if not exists oauth_states_expires_idx on public.oauth_states (expires_at);
alter table public.oauth_states enable row level security;
revoke all on public.oauth_states from public, anon, authenticated;
grant all on public.oauth_states to service_role;

create or replace function public.zella_oauth_state_issue(p_nonce_hash text, p_user_id uuid, p_business_id uuid, p_provider text, p_seconds integer default 300)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if p_nonce_hash !~ '^[0-9a-f]{64}$' or p_user_id is null or p_business_id is null or p_provider not in ('google', 'outlook') then
    raise exception 'BAD_REQUEST';
  end if;
  delete from public.oauth_states where expires_at < now() - interval '1 day';   -- keep the table small
  insert into public.oauth_states (nonce_hash, user_id, business_id, provider, expires_at)
  values (p_nonce_hash, p_user_id, p_business_id, p_provider, now() + make_interval(secs => least(greatest(coalesce(p_seconds, 300), 60), 600)));
  return true;
end $$;

-- true once: the stored sign in matches, hasn't expired and hasn't been used; it is used up in the same statement
create or replace function public.zella_oauth_state_consume(p_nonce_hash text, p_user_id uuid, p_business_id uuid, p_provider text)
returns boolean language sql security definer set search_path = '' as $$
  with u as (
    update public.oauth_states set used_at = now()
     where nonce_hash = p_nonce_hash and user_id = p_user_id and business_id = p_business_id and provider = p_provider
       and used_at is null and expires_at > now()
    returning 1)
  select exists (select 1 from u)
$$;

revoke all on function public.zella_oauth_state_issue(text,uuid,uuid,text,integer) from public, anon, authenticated;
revoke all on function public.zella_oauth_state_consume(text,uuid,uuid,text) from public, anon, authenticated;
grant execute on function public.zella_oauth_state_issue(text,uuid,uuid,text,integer) to service_role;
grant execute on function public.zella_oauth_state_consume(text,uuid,uuid,text) to service_role;

commit;
