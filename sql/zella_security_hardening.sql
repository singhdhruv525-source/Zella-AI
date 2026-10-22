-- Security hardening. Safe to run more than once.
-- Nothing in the app deletes these records from the browser, so removing the
-- delete rights does not change what staff can do.

-- 1. Trigger helper should not be callable as an API function.
revoke all on function public.zella_conversation_touch() from public, anon, authenticated;

-- 2. Fix the mutable search_path warning.
alter function public.update_updated_at() set search_path = public;

-- 3. Conversation notes: signed-in members only (was "public").
drop policy if exists "members read conversation notes" on public.conversation_notes;
create policy "members read conversation notes" on public.conversation_notes
  for select to authenticated using (public.is_business_member(business_id));

-- 4. Records of what happened cannot be deleted from the browser.
drop policy if exists "business members can delete calls" on public.calls;
drop policy if exists "business members can delete conversations" on public.conversations;
drop policy if exists "business members can delete conversation messages" on public.conversation_messages;
drop policy if exists "business members can delete sms" on public.sms_messages;
drop policy if exists "business members can delete email" on public.email_messages;
drop policy if exists "business members can delete customers" on public.customers;
drop policy if exists "business members can delete appointments" on public.appointments;

-- 5. Sent and received messages cannot be edited from the browser.
drop policy if exists "business members can update conversation messages" on public.conversation_messages;
drop policy if exists "business members can update sms" on public.sms_messages;
drop policy if exists "business members can update email" on public.email_messages;

-- 6. Only owners, admins and managers can change the team list.
drop policy if exists staff_members_member_insert on public.staff_members;
drop policy if exists staff_members_member_update on public.staff_members;
drop policy if exists staff_members_member_delete on public.staff_members;
create policy staff_members_manager_insert on public.staff_members
  for insert to authenticated with check (public.zella_can_manage(business_id));
create policy staff_members_manager_update on public.staff_members
  for update to authenticated using (public.zella_can_manage(business_id)) with check (public.zella_can_manage(business_id));
create policy staff_members_manager_delete on public.staff_members
  for delete to authenticated using (public.zella_can_manage(business_id));

-- 7. Remove table rights that no policy allows anyway (defence in depth).
revoke insert, update, delete on public.industries from anon, authenticated;
revoke insert, update, delete on public.industry_modules from authenticated;
revoke delete on public.calls, public.conversations, public.conversation_messages,
  public.sms_messages, public.email_messages, public.customers, public.appointments from authenticated;
revoke update, delete on public.conversation_messages, public.sms_messages, public.email_messages from authenticated;
