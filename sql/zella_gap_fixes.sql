-- Zella - gap fixes found in the 2026-10-25 deep check. Safe to re-run.
-- The Inbox reads internal notes straight from conversation_notes (the row rule already limits it to the business's own team),
-- but signed-in users had no SELECT right on the table, so notes never showed up.
grant select on public.conversation_notes to authenticated;
