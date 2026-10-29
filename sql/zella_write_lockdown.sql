-- Zella AI: signed-in users stop writing directly to tables that only the server should change.
--
-- Found in the end-to-end audit (docs/ZELLA_END_TO_END_AUDIT.md, finding H-2): business members could insert and
-- update their own rows in calls, sms_messages and email_messages directly. The usage trigger on calls recalculates
-- billable minutes from duration_seconds / ended_at / ai_handled, so a business could shorten its own calls (pay
-- less), invent calls, or record texts as "delivered" that were never sent.
--
-- Nothing in the web app or the edge functions writes these tables with a user's own token: the app changes them
-- through permission-checked functions (zella_call_update, zella_inbox_*, zella_set_automation, ...) and the
-- providers' webhooks and n8n write with the server key. Reading is unchanged (row-level security still applies).
-- Safe to run again.

revoke insert, update, delete on
  public.calls, public.sms_messages, public.email_messages, public.conversations, public.conversation_messages,
  public.notifications, public.support_tickets, public.integrations, public.automations
from authenticated, anon;

-- Pure arithmetic helper flagged by the database linter: pin its search path.
alter function public.zella_usage_billable_seconds(integer, jsonb) set search_path = '';

-- Business Settings > AI receptionist > "Test it yourself" reads the saved test questions directly, but the table
-- had no SELECT grant, so the panel failed with "permission denied" (audit finding M-1). Its row-level policy
-- already limits it to the business's owners and admins (and platform admins).
grant select on public.ai_eval_cases to authenticated;
