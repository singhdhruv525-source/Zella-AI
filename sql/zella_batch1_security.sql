-- Batch 1 security review (6 Nov 2026): the one schema change the review found worth making.
--
-- zella_appointment_holds_time (Supabase advisory "function_search_path_mutable"). It is SECURITY INVOKER, executes
-- only built-in operators and now(), and reads no table, so a caller's search path could only ever affect that caller:
-- no privilege escalation was possible. It was also declared IMMUTABLE although it reads now(); STABLE is the correct
-- label. Nothing indexes it or uses it in a policy, default, view or constraint (checked on the live database), so the
-- change is safe. Side effect: with a SET clause the planner no longer inlines it; it is called per appointment row in
-- the four table / conflict-guard functions, which is negligible at these row counts.
--
-- Safe to run twice. Undo: sql/rollback/zella_batch1_security_rollback.sql. Needs the owner's approval to apply.

alter function public.zella_appointment_holds_time(text, text, timestamptz) stable;
alter function public.zella_appointment_holds_time(text, text, timestamptz) set search_path = '';
