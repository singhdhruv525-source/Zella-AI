-- Undoes sql/zella_oauth_states.sql exactly: both functions and oauth_states are dropped (sign ins in progress can't
-- be finished; deploy the previous calendar-connect first). Safe to run twice.
begin;
drop function if exists public.zella_oauth_state_consume(text, uuid, uuid, text);
drop function if exists public.zella_oauth_state_issue(text, uuid, uuid, text, integer);
drop table if exists public.oauth_states;
commit;
