-- Rollback for sql/zella_assistant_delivery.sql (hand-written). Switch the Vapi numbers back to a fixed assistant
-- FIRST: after this, voice-rules answers assistant-request with a spoken refusal.
-- Versions already marked live or failed keep that status. The delivery log is kept (renamed).
\set ON_ERROR_STOP on
begin;
drop function if exists public.zella_assistant_delivery_status(uuid);
drop function if exists public.zella_assistant_for_call(text, text, text);
alter table if exists public.assistant_deliveries rename to assistant_deliveries_rolled_back;
commit;
