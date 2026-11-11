-- Roll voice-rules back first. Keep guard rows: unresolved outcomes must survive a reapply.
begin;
drop function if exists public.zella_store_lookup_begin(text, uuid, text);
drop function if exists public.zella_store_lookup_begin(text, uuid, text, text);
drop function if exists public.zella_store_lookup_finish(uuid, text, uuid, text, boolean, text, uuid);
commit;
