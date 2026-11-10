create policy activation_tests_select on public.activation_tests as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy agent_config_versions_read on public.agent_config_versions as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy agent_config_versions_select on public.agent_config_versions as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy "business members can view ai agent configs" on public.ai_agent_configs as PERMISSIVE for SELECT to authenticated using ((EXISTS ( SELECT 1
   FROM ai_agents a
  WHERE ((a.id = ai_agent_configs.agent_id) AND is_business_member(a.business_id)))));
create policy "business members can view ai agents" on public.ai_agents as PERMISSIVE for SELECT to authenticated using (is_business_member(business_id));
create policy ai_answer_reports_read on public.ai_answer_reports as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy ai_eval_cases_all on public.ai_eval_cases as PERMISSIVE for ALL to authenticated using ((is_platform_admin() OR zella_has_role(business_id, ARRAY['owner'::text, 'admin'::text]))) with check ((is_platform_admin() OR zella_has_role(business_id, ARRAY['owner'::text, 'admin'::text])));
create policy ai_response_samples_read on public.ai_response_samples as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy ai_tool_calls_read on public.ai_tool_calls as PERMISSIVE for SELECT to authenticated using ((is_platform_admin() OR zella_has_role(business_id, ARRAY['owner'::text, 'admin'::text])));
create policy appointment_reminders_select on public.appointment_reminders as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy "business members can create appointments" on public.appointments as PERMISSIVE for INSERT to authenticated with check (is_business_member(business_id));
create policy "business members can update appointments" on public.appointments as PERMISSIVE for UPDATE to authenticated using (is_business_member(business_id)) with check (is_business_member(business_id));
create policy "business members can view appointments" on public.appointments as PERMISSIVE for SELECT to authenticated using (is_business_member(business_id));
create policy zella_viewer_no_delete on public.appointments as RESTRICTIVE for DELETE to authenticated using ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy zella_viewer_no_insert on public.appointments as RESTRICTIVE for INSERT to authenticated with check ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy zella_viewer_no_update on public.appointments as RESTRICTIVE for UPDATE to authenticated using ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy assignment_rules_member_read on public.assignment_rules as PERMISSIVE for SELECT to authenticated using ((EXISTS ( SELECT 1
   FROM business_members m
  WHERE ((m.business_id = assignment_rules.business_id) AND (m.user_id = ( SELECT auth.uid() AS uid)) AND (m.status = 'active'::text)))));
create policy "business members can view audit logs" on public.audit_logs as PERMISSIVE for SELECT to authenticated using (((business_id IS NOT NULL) AND is_business_member(business_id)));
create policy "managers read dead letters" on public.automation_dead_letters as PERMISSIVE for SELECT to authenticated using (((business_id IS NOT NULL) AND zella_can_manage(business_id)));
create policy "managers read events" on public.automation_events as PERMISSIVE for SELECT to authenticated using (zella_can_manage(business_id));
create policy "business members can view automation runs" on public.automation_runs as PERMISSIVE for SELECT to authenticated using (is_business_member(business_id));
create policy "authorized managers can create automations" on public.automations as PERMISSIVE for INSERT to authenticated with check ((EXISTS ( SELECT 1
   FROM business_members bm
  WHERE ((bm.business_id = automations.business_id) AND (bm.user_id = ( SELECT auth.uid() AS uid)) AND (bm.status = 'active'::text) AND (bm.role = ANY (ARRAY['owner'::text, 'admin'::text, 'manager'::text]))))));
create policy "authorized managers can delete automations" on public.automations as PERMISSIVE for DELETE to authenticated using ((EXISTS ( SELECT 1
   FROM business_members bm
  WHERE ((bm.business_id = automations.business_id) AND (bm.user_id = ( SELECT auth.uid() AS uid)) AND (bm.status = 'active'::text) AND (bm.role = ANY (ARRAY['owner'::text, 'admin'::text, 'manager'::text]))))));
create policy "authorized managers can update automations" on public.automations as PERMISSIVE for UPDATE to authenticated using ((EXISTS ( SELECT 1
   FROM business_members bm
  WHERE ((bm.business_id = automations.business_id) AND (bm.user_id = ( SELECT auth.uid() AS uid)) AND (bm.status = 'active'::text) AND (bm.role = ANY (ARRAY['owner'::text, 'admin'::text, 'manager'::text])))))) with check ((EXISTS ( SELECT 1
   FROM business_members bm
  WHERE ((bm.business_id = automations.business_id) AND (bm.user_id = ( SELECT auth.uid() AS uid)) AND (bm.status = 'active'::text) AND (bm.role = ANY (ARRAY['owner'::text, 'admin'::text, 'manager'::text]))))));
create policy "business members can view automations" on public.automations as PERMISSIVE for SELECT to authenticated using (is_business_member(business_id));
create policy zella_module_automations_delete on public.automations as RESTRICTIVE for DELETE to authenticated using (zella_module_on(business_id, 'automations'::text));
create policy zella_module_automations_insert on public.automations as RESTRICTIVE for INSERT to authenticated with check (zella_module_on(business_id, 'automations'::text));
create policy zella_module_automations_read on public.automations as RESTRICTIVE for SELECT to authenticated using (zella_module_on(business_id, 'automations'::text));
create policy zella_module_automations_update on public.automations as RESTRICTIVE for UPDATE to authenticated using (zella_module_on(business_id, 'automations'::text)) with check (zella_module_on(business_id, 'automations'::text));
create policy blocked_times_member_delete on public.blocked_times as PERMISSIVE for DELETE to authenticated using ((EXISTS ( SELECT 1
   FROM business_members m
  WHERE ((m.business_id = blocked_times.business_id) AND (m.user_id = ( SELECT auth.uid() AS uid)) AND (m.status = 'active'::text)))));
create policy blocked_times_member_insert on public.blocked_times as PERMISSIVE for INSERT to authenticated with check ((EXISTS ( SELECT 1
   FROM business_members m
  WHERE ((m.business_id = blocked_times.business_id) AND (m.user_id = ( SELECT auth.uid() AS uid)) AND (m.status = 'active'::text)))));
create policy blocked_times_member_select on public.blocked_times as PERMISSIVE for SELECT to authenticated using ((EXISTS ( SELECT 1
   FROM business_members m
  WHERE ((m.business_id = blocked_times.business_id) AND (m.user_id = ( SELECT auth.uid() AS uid)) AND (m.status = 'active'::text)))));
create policy blocked_times_member_update on public.blocked_times as PERMISSIVE for UPDATE to authenticated using ((EXISTS ( SELECT 1
   FROM business_members m
  WHERE ((m.business_id = blocked_times.business_id) AND (m.user_id = ( SELECT auth.uid() AS uid)) AND (m.status = 'active'::text))))) with check ((EXISTS ( SELECT 1
   FROM business_members m
  WHERE ((m.business_id = blocked_times.business_id) AND (m.user_id = ( SELECT auth.uid() AS uid)) AND (m.status = 'active'::text)))));
create policy zella_viewer_no_delete on public.blocked_times as RESTRICTIVE for DELETE to authenticated using ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy zella_viewer_no_insert on public.blocked_times as RESTRICTIVE for INSERT to authenticated with check ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy zella_viewer_no_update on public.blocked_times as RESTRICTIVE for UPDATE to authenticated using ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy business_closures_read on public.business_closures as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy business_hours_read on public.business_hours as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy business_languages_read on public.business_languages as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy "Users can view their memberships" on public.business_members as PERMISSIVE for SELECT to authenticated using ((user_id = ( SELECT auth.uid() AS uid)));
create policy "Members can view enabled business modules" on public.business_modules as PERMISSIVE for SELECT to authenticated using (is_business_member(business_id));
create policy business_phone_numbers_member_read on public.business_phone_numbers as PERMISSIVE for SELECT to authenticated using ((EXISTS ( SELECT 1
   FROM business_members m
  WHERE ((m.business_id = business_phone_numbers.business_id) AND (m.user_id = ( SELECT auth.uid() AS uid)) AND (m.status = 'active'::text)))));
create policy business_verification_documents_owner_read on public.business_verification_documents as PERMISSIVE for SELECT to authenticated using (zella_has_role(business_id, ARRAY['owner'::text, 'admin'::text]));
create policy "Members can view their business" on public.businesses as PERMISSIVE for SELECT to authenticated using (is_business_member(id));
create policy calendar_connections_member_read on public.calendar_connections as PERMISSIVE for SELECT to authenticated using ((EXISTS ( SELECT 1
   FROM business_members m
  WHERE ((m.business_id = calendar_connections.business_id) AND (m.user_id = ( SELECT auth.uid() AS uid)) AND (m.status = 'active'::text)))));
create policy call_insights_read on public.call_insights as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy zella_module_calls_read on public.call_insights as RESTRICTIVE for SELECT to authenticated using (zella_module_on(business_id, 'calls'::text));
create policy call_messages_read on public.call_messages as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy callback_attempts_select on public.callback_attempts as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy callbacks_select on public.callbacks as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy "business members can create calls" on public.calls as PERMISSIVE for INSERT to authenticated with check (is_business_member(business_id));
create policy "business members can update calls" on public.calls as PERMISSIVE for UPDATE to authenticated using (is_business_member(business_id)) with check (is_business_member(business_id));
create policy "business members can view calls" on public.calls as PERMISSIVE for SELECT to authenticated using (is_business_member(business_id));
create policy zella_module_calls_read on public.calls as RESTRICTIVE for SELECT to authenticated using (zella_module_on(business_id, 'calls'::text));
create policy zella_viewer_no_delete on public.calls as RESTRICTIVE for DELETE to authenticated using ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy zella_viewer_no_insert on public.calls as RESTRICTIVE for INSERT to authenticated with check ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy zella_viewer_no_update on public.calls as RESTRICTIVE for UPDATE to authenticated using ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy "members read consents" on public.contact_consents as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy "business members can create conversation messages" on public.conversation_messages as PERMISSIVE for INSERT to authenticated with check ((EXISTS ( SELECT 1
   FROM conversations c
  WHERE ((c.id = conversation_messages.conversation_id) AND is_business_member(c.business_id)))));
create policy "business members can view conversation messages" on public.conversation_messages as PERMISSIVE for SELECT to authenticated using ((EXISTS ( SELECT 1
   FROM conversations c
  WHERE ((c.id = conversation_messages.conversation_id) AND is_business_member(c.business_id)))));
create policy "members read conversation notes" on public.conversation_notes as PERMISSIVE for SELECT to authenticated using (is_business_member(business_id));
create policy "business members can create conversations" on public.conversations as PERMISSIVE for INSERT to authenticated with check (is_business_member(business_id));
create policy "business members can update conversations" on public.conversations as PERMISSIVE for UPDATE to authenticated using (is_business_member(business_id)) with check (is_business_member(business_id));
create policy "business members can view conversations" on public.conversations as PERMISSIVE for SELECT to authenticated using (is_business_member(business_id));
create policy zella_viewer_no_delete on public.conversations as RESTRICTIVE for DELETE to authenticated using ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy zella_viewer_no_insert on public.conversations as RESTRICTIVE for INSERT to authenticated with check ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy zella_viewer_no_update on public.conversations as RESTRICTIVE for UPDATE to authenticated using ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy crm_record_events_select on public.crm_record_events as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy crm_record_types_select on public.crm_record_types as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy crm_records_select on public.crm_records as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy zella_record_type_enabled_read on public.crm_records as RESTRICTIVE for SELECT to authenticated using ((EXISTS ( SELECT 1
   FROM crm_record_types t
  WHERE ((t.business_id = crm_records.business_id) AND (t.key = crm_records.type_key) AND t.enabled))));
create policy crm_tasks_select on public.crm_tasks as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy cross_sell_rules_read on public.cross_sell_rules as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy customer_requests_member_read on public.customer_requests as PERMISSIVE for SELECT to authenticated using ((EXISTS ( SELECT 1
   FROM business_members m
  WHERE ((m.business_id = customer_requests.business_id) AND (m.user_id = ( SELECT auth.uid() AS uid)) AND (m.status = 'active'::text)))));
create policy "business members can create customers" on public.customers as PERMISSIVE for INSERT to authenticated with check (is_business_member(business_id));
create policy "business members can update customers" on public.customers as PERMISSIVE for UPDATE to authenticated using (is_business_member(business_id)) with check (is_business_member(business_id));
create policy "business members can view customers" on public.customers as PERMISSIVE for SELECT to authenticated using (is_business_member(business_id));
create policy zella_viewer_no_delete on public.customers as RESTRICTIVE for DELETE to authenticated using ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy zella_viewer_no_insert on public.customers as RESTRICTIVE for INSERT to authenticated with check ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy zella_viewer_no_update on public.customers as RESTRICTIVE for UPDATE to authenticated using ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy data_rights_read on public.data_rights_requests as PERMISSIVE for SELECT to authenticated using (zella_has_role(business_id, ARRAY['owner'::text, 'admin'::text, 'manager'::text]));
create policy duplicate_reviews_select on public.duplicate_reviews as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy "business members can create email" on public.email_messages as PERMISSIVE for INSERT to authenticated with check (is_business_member(business_id));
create policy "business members can view email" on public.email_messages as PERMISSIVE for SELECT to authenticated using (is_business_member(business_id));
create policy followup_tasks_member_select on public.followup_tasks as PERMISSIVE for SELECT to authenticated using ((EXISTS ( SELECT 1
   FROM business_members m
  WHERE ((m.business_id = followup_tasks.business_id) AND (m.user_id = ( SELECT auth.uid() AS uid)) AND (m.status = 'active'::text)))));
create policy "Anyone can view active industries" on public.industries as PERMISSIVE for SELECT to anon using ((is_active = true));
create policy "Authenticated users can view active industries" on public.industries as PERMISSIVE for SELECT to authenticated using ((is_active = true));
create policy "signed in read industry defaults" on public.industry_automation_defaults as PERMISSIVE for SELECT to authenticated using (true);
create policy "Authenticated users can view industry configurations" on public.industry_configurations as PERMISSIVE for SELECT to authenticated using ((EXISTS ( SELECT 1
   FROM businesses b
  WHERE ((b.industry_id = industry_configurations.industry_id) AND is_business_member(b.id)))));
create policy "Authenticated users can view active industry modules" on public.industry_modules as PERMISSIVE for SELECT to authenticated using ((is_active = true));
create policy "authorized managers can create integrations" on public.integrations as PERMISSIVE for INSERT to authenticated with check ((EXISTS ( SELECT 1
   FROM business_members bm
  WHERE ((bm.business_id = integrations.business_id) AND (bm.user_id = ( SELECT auth.uid() AS uid)) AND (bm.status = 'active'::text) AND (bm.role = ANY (ARRAY['owner'::text, 'admin'::text, 'manager'::text]))))));
create policy "authorized managers can update integrations" on public.integrations as PERMISSIVE for UPDATE to authenticated using ((EXISTS ( SELECT 1
   FROM business_members bm
  WHERE ((bm.business_id = integrations.business_id) AND (bm.user_id = ( SELECT auth.uid() AS uid)) AND (bm.status = 'active'::text) AND (bm.role = ANY (ARRAY['owner'::text, 'admin'::text, 'manager'::text])))))) with check ((EXISTS ( SELECT 1
   FROM business_members bm
  WHERE ((bm.business_id = integrations.business_id) AND (bm.user_id = ( SELECT auth.uid() AS uid)) AND (bm.status = 'active'::text) AND (bm.role = ANY (ARRAY['owner'::text, 'admin'::text, 'manager'::text]))))));
create policy "business members can view integrations" on public.integrations as PERMISSIVE for SELECT to authenticated using (is_business_member(business_id));
create policy knowledge_gaps_member_select on public.knowledge_gaps as PERMISSIVE for SELECT to authenticated using ((EXISTS ( SELECT 1
   FROM business_members m
  WHERE ((m.business_id = knowledge_gaps.business_id) AND (m.user_id = ( SELECT auth.uid() AS uid)) AND (m.status = 'active'::text)))));
create policy knowledge_items_member_insert on public.knowledge_items as PERMISSIVE for INSERT to authenticated with check ((EXISTS ( SELECT 1
   FROM business_members m
  WHERE ((m.business_id = knowledge_items.business_id) AND (m.user_id = ( SELECT auth.uid() AS uid)) AND (m.status = 'active'::text)))));
create policy knowledge_items_member_select on public.knowledge_items as PERMISSIVE for SELECT to authenticated using ((EXISTS ( SELECT 1
   FROM business_members m
  WHERE ((m.business_id = knowledge_items.business_id) AND (m.user_id = ( SELECT auth.uid() AS uid)) AND (m.status = 'active'::text)))));
create policy knowledge_items_member_update on public.knowledge_items as PERMISSIVE for UPDATE to authenticated using ((EXISTS ( SELECT 1
   FROM business_members m
  WHERE ((m.business_id = knowledge_items.business_id) AND (m.user_id = ( SELECT auth.uid() AS uid)) AND (m.status = 'active'::text))))) with check ((EXISTS ( SELECT 1
   FROM business_members m
  WHERE ((m.business_id = knowledge_items.business_id) AND (m.user_id = ( SELECT auth.uid() AS uid)) AND (m.status = 'active'::text)))));
create policy zella_viewer_no_delete on public.knowledge_items as RESTRICTIVE for DELETE to authenticated using ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy zella_viewer_no_insert on public.knowledge_items as RESTRICTIVE for INSERT to authenticated with check ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy zella_viewer_no_update on public.knowledge_items as RESTRICTIVE for UPDATE to authenticated using ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy knowledge_versions_read on public.knowledge_versions as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy lead_questions_all on public.lead_questions as PERMISSIVE for ALL to authenticated using (zella_is_member(business_id)) with check (zella_is_member(business_id));
create policy zella_leads_managers_delete on public.lead_questions as RESTRICTIVE for DELETE to authenticated using (zella_has_role(business_id, ARRAY['owner'::text, 'admin'::text, 'manager'::text]));
create policy zella_leads_managers_insert on public.lead_questions as RESTRICTIVE for INSERT to authenticated with check (zella_has_role(business_id, ARRAY['owner'::text, 'admin'::text, 'manager'::text]));
create policy zella_leads_managers_update on public.lead_questions as RESTRICTIVE for UPDATE to authenticated using (zella_has_role(business_id, ARRAY['owner'::text, 'admin'::text, 'manager'::text])) with check (zella_has_role(business_id, ARRAY['owner'::text, 'admin'::text, 'manager'::text]));
create policy lead_rules_all on public.lead_rules as PERMISSIVE for ALL to authenticated using (zella_is_member(business_id)) with check (zella_is_member(business_id));
create policy zella_leads_managers_delete on public.lead_rules as RESTRICTIVE for DELETE to authenticated using (zella_has_role(business_id, ARRAY['owner'::text, 'admin'::text, 'manager'::text]));
create policy zella_leads_managers_insert on public.lead_rules as RESTRICTIVE for INSERT to authenticated with check (zella_has_role(business_id, ARRAY['owner'::text, 'admin'::text, 'manager'::text]));
create policy zella_leads_managers_update on public.lead_rules as RESTRICTIVE for UPDATE to authenticated using (zella_has_role(business_id, ARRAY['owner'::text, 'admin'::text, 'manager'::text])) with check (zella_has_role(business_id, ARRAY['owner'::text, 'admin'::text, 'manager'::text]));
create policy zella_viewer_no_delete on public.lead_rules as RESTRICTIVE for DELETE to authenticated using ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy zella_viewer_no_insert on public.lead_rules as RESTRICTIVE for INSERT to authenticated with check ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy zella_viewer_no_update on public.lead_rules as RESTRICTIVE for UPDATE to authenticated using ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy lead_submissions_read on public.lead_submissions as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy legal_acceptances_read on public.legal_acceptances as PERMISSIVE for SELECT to authenticated using (((user_id = auth.uid()) OR ((business_id IS NOT NULL) AND zella_has_role(business_id, ARRAY['owner'::text, 'admin'::text]))));
create policy legal_documents_published_read on public.legal_documents as PERMISSIVE for SELECT to authenticated using ((status = 'published'::text));
create policy live_notices_read on public.live_notices as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy message_drafts_read on public.message_drafts as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy "members read templates" on public.message_templates as PERMISSIVE for SELECT to authenticated using (((business_id IS NULL) OR zella_is_member(business_id)));
create policy meta_connections_read on public.meta_connections as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy meta_templates_read on public.meta_templates as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy "users can create notification preferences" on public.notification_preferences as PERMISSIVE for INSERT to authenticated with check (((user_id = ( SELECT auth.uid() AS uid)) AND is_business_member(business_id)));
create policy "users can delete notification preferences" on public.notification_preferences as PERMISSIVE for DELETE to authenticated using (((user_id = ( SELECT auth.uid() AS uid)) AND is_business_member(business_id)));
create policy "users can update notification preferences" on public.notification_preferences as PERMISSIVE for UPDATE to authenticated using (((user_id = ( SELECT auth.uid() AS uid)) AND is_business_member(business_id))) with check (((user_id = ( SELECT auth.uid() AS uid)) AND is_business_member(business_id)));
create policy "users can view notification preferences" on public.notification_preferences as PERMISSIVE for SELECT to authenticated using (((user_id = ( SELECT auth.uid() AS uid)) AND is_business_member(business_id)));
create policy "business members can create notifications" on public.notifications as PERMISSIVE for INSERT to authenticated with check (is_business_member(business_id));
create policy "users can delete their notifications" on public.notifications as PERMISSIVE for DELETE to authenticated using (((user_id = ( SELECT auth.uid() AS uid)) AND is_business_member(business_id)));
create policy "users can update their notifications" on public.notifications as PERMISSIVE for UPDATE to authenticated using (((user_id = ( SELECT auth.uid() AS uid)) AND is_business_member(business_id))) with check (((user_id = ( SELECT auth.uid() AS uid)) AND is_business_member(business_id)));
create policy "users can view their notifications" on public.notifications as PERMISSIVE for SELECT to authenticated using (((user_id = ( SELECT auth.uid() AS uid)) AND is_business_member(business_id)));
create policy on_call_settings_read on public.on_call_settings as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy on_call_shifts_read on public.on_call_shifts as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy "business members can view payments" on public.payments as PERMISSIVE for SELECT to authenticated using (is_business_member(business_id));
create policy "Anyone can view active plans" on public.plans as PERMISSIVE for SELECT to anon, authenticated using ((is_active = true));
create policy platform_alerts_admin_select on public.platform_alerts as PERMISSIVE for SELECT to authenticated using ((EXISTS ( SELECT 1
   FROM platform_admins p
  WHERE ((p.user_id = ( SELECT auth.uid() AS uid)) AND p.is_active))));
create policy platform_incidents_admin on public.platform_incidents as PERMISSIVE for SELECT to authenticated using (is_platform_admin());
create policy "Users can update their own profile" on public.profiles as PERMISSIVE for UPDATE to authenticated using ((id = ( SELECT auth.uid() AS uid))) with check ((id = ( SELECT auth.uid() AS uid)));
create policy "Users can view their own profile" on public.profiles as PERMISSIVE for SELECT to authenticated using ((id = ( SELECT auth.uid() AS uid)));
create policy quotes_select on public.quotes as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy review_sources_read on public.review_sources as PERMISSIVE for SELECT to authenticated using (zella_can_manage(business_id));
create policy reviews_read on public.reviews as PERMISSIVE for SELECT to authenticated using (zella_can_manage(business_id));
create policy sensitive_approvals_read on public.sensitive_approvals as PERMISSIVE for SELECT to authenticated using (zella_has_role(business_id, ARRAY['owner'::text, 'admin'::text]));
create policy "business members can create sms" on public.sms_messages as PERMISSIVE for INSERT to authenticated with check (is_business_member(business_id));
create policy "business members can view sms" on public.sms_messages as PERMISSIVE for SELECT to authenticated using (is_business_member(business_id));
create policy social_flows_read on public.social_flows as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy spam_incident_events_read on public.spam_incident_events as PERMISSIVE for SELECT to authenticated using (zella_has_role(business_id, ARRAY['owner'::text, 'admin'::text, 'manager'::text]));
create policy spam_incidents_read on public.spam_incidents as PERMISSIVE for SELECT to authenticated using (zella_has_role(business_id, ARRAY['owner'::text, 'admin'::text, 'manager'::text]));
create policy spam_list_entries_read on public.spam_list_entries as PERMISSIVE for SELECT to authenticated using (((business_id IS NOT NULL) AND zella_has_role(business_id, ARRAY['owner'::text, 'admin'::text, 'manager'::text])));
create policy spam_settings_read on public.spam_settings as PERMISSIVE for SELECT to authenticated using (zella_has_role(business_id, ARRAY['owner'::text, 'admin'::text, 'manager'::text]));
create policy staff_handovers_read on public.staff_handovers as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy staff_members_manager_delete on public.staff_members as PERMISSIVE for DELETE to authenticated using (zella_can_manage(business_id));
create policy staff_members_manager_insert on public.staff_members as PERMISSIVE for INSERT to authenticated with check (zella_can_manage(business_id));
create policy staff_members_manager_update on public.staff_members as PERMISSIVE for UPDATE to authenticated using (zella_can_manage(business_id)) with check (zella_can_manage(business_id));
create policy staff_members_member_select on public.staff_members as PERMISSIVE for SELECT to authenticated using ((EXISTS ( SELECT 1
   FROM business_members m
  WHERE ((m.business_id = staff_members.business_id) AND (m.user_id = ( SELECT auth.uid() AS uid)) AND (m.status = 'active'::text)))));
create policy zella_viewer_no_delete on public.staff_members as RESTRICTIVE for DELETE to authenticated using ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy zella_viewer_no_insert on public.staff_members as RESTRICTIVE for INSERT to authenticated with check ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy zella_viewer_no_update on public.staff_members as RESTRICTIVE for UPDATE to authenticated using ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy staff_notifications_select on public.staff_notifications as PERMISSIVE for SELECT to authenticated using ((zella_is_member(business_id) AND ((user_id IS NULL) OR (user_id = ( SELECT auth.uid() AS uid)))));
create policy "business members can view subscriptions" on public.subscriptions as PERMISSIVE for SELECT to authenticated using (is_business_member(business_id));
create policy "authorized managers can update support tickets" on public.support_tickets as PERMISSIVE for UPDATE to authenticated using ((EXISTS ( SELECT 1
   FROM business_members bm
  WHERE ((bm.business_id = support_tickets.business_id) AND (bm.user_id = ( SELECT auth.uid() AS uid)) AND (bm.status = 'active'::text) AND (bm.role = ANY (ARRAY['owner'::text, 'admin'::text, 'manager'::text])))))) with check ((EXISTS ( SELECT 1
   FROM business_members bm
  WHERE ((bm.business_id = support_tickets.business_id) AND (bm.user_id = ( SELECT auth.uid() AS uid)) AND (bm.status = 'active'::text) AND (bm.role = ANY (ARRAY['owner'::text, 'admin'::text, 'manager'::text]))))));
create policy "business members can create support tickets" on public.support_tickets as PERMISSIVE for INSERT to authenticated with check (is_business_member(business_id));
create policy "business members can view support tickets" on public.support_tickets as PERMISSIVE for SELECT to authenticated using (is_business_member(business_id));
create policy zella_viewer_no_delete on public.support_tickets as RESTRICTIVE for DELETE to authenticated using ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy zella_viewer_no_insert on public.support_tickets as RESTRICTIVE for INSERT to authenticated with check ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy zella_viewer_no_update on public.support_tickets as RESTRICTIVE for UPDATE to authenticated using ((NOT zella_has_role(business_id, ARRAY['viewer'::text])));
create policy time_off_requests_read on public.time_off_requests as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy "business members can view usage records" on public.usage_records as PERMISSIVE for SELECT to authenticated using (is_business_member(business_id));
create policy waitlist_select on public.waitlist_entries as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy website_forms_read on public.website_forms as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy website_pages_read on public.website_pages as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy website_sources_read on public.website_sources as PERMISSIVE for SELECT to authenticated using (zella_is_member(business_id));
create policy "managers read executions" on public.workflow_executions as PERMISSIVE for SELECT to authenticated using (((business_id IS NOT NULL) AND zella_can_manage(business_id)));
