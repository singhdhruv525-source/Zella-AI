-- Review fixes for the SQL migrations (CodeRabbit full-repository review, part 1: 10 Nov 2026). Safe to run twice.
-- Rollback: sql/rollback/zella_review_sql_fixes_rollback.sql
-- Depends on: everything in tests/deploy/run_all.sh's pending list, zella_batch1_security, zella_batch3_pagination
-- (the production state these definitions were taken from). Each function is replaced whole, and only if it is
-- exactly the version this file was written against (DB-3); otherwise the file stops before changing anything.
-- Generated from the live definitions on an isolated copy by applying exact edits, so nothing else in them changes.
--
-- Security and privacy
--   * dental reminder wording (platform templates): no treatment name, only "your appointment".
--   * zella_record_consent: signed-in callers can record consent only from staff-recordable sources (staff, verbal
--     call, web form, import), an opt-in needs a manager, and only the server (no signed-in user) can lift a
--     customer's do-not-text / do-not-email flag. Before, any editor could pass source 'email_link' with 'opted_in'
--     and undo a customer's STOP (TCPA / CAN-SPAM).
--   * zella_merge_customers: the customer being kept can't be an archived one, and the dropped customer's consent
--     history moves to the kept customer, so an opt-out recorded against the duplicate keeps working.
--   * zella_claim_reminders: a reminder whose channel can't be used (do-not-text with no usable email, and the other
--     way round) is skipped instead of being sent anyway.
--   * zella_knowledge_guard: approved_by / approved_at can't be supplied by the app; only the guard sets them.
--   * zella_update_customer_request: any move into or out of a final state of a privacy request (resolved or
--     rejected, including reopening) needs an owner or admin, not only "resolved".
--   * zella_log_customer_request: two different unidentified callers' requests are no longer merged into one; a
--     request without a known customer is matched only by the same call.
--   * zella_complete_followup_task: a task that is already finished is not finished again (no second "wants a call
--     back" escalation), and the call it links must belong to the task's business.
--   * zella_ai_voice (transfer_to_human): the assistant can't label a transfer an emergency; that label comes only from
--     report_emergency, which also alerts the owners. A refused transfer no longer overwrites a transfer that was
--     already approved on the call.
--   * zella_capture_web_lead: a website visitor's wording no longer raises an existing customer's priority.
--   * zella_sensitive_industry: answers only for the caller's own business (or a platform admin).
--   * zella_booking_choices, zella_arrival_window, zella_capability_on: internal helpers; signed-in users can no
--     longer call them directly for another business (the functions that use them run with the owner's rights).
--     zella_cross_sell_ideas: not callable by anon.
--   * zella_calendar_connect (legacy, no callers, no role check): removed; zella_calendar_connect_provider replaces it.
--   * zella_calendar_connect_provider: switching provider forgets the old provider's event ids, so an id from Google
--     is never sent to Outlook (or the reverse).
--   * platform_admins changes are written to audit_logs (the audit trigger had a branch for it but was never attached).
--   * zella_permission_check also reports public tables with row security off that anon or signed-in users can reach.
--   * zella_admin_message_detail: an email's metadata is shown without body / text / html, like SMS.
--   * zella_admin_template_variables: only platform templates (no business) decide which variables are allowed.
--
-- Correctness
--   * zella_admin_routing_save: a NULL rules value is refused (it used to blank the escalation rules).
--   * admin lists (numbers, calls, messages, automations, runs, templates): id breaks ties, so rows can't move between
--     pages.
--   * zella_set_industry_rules: a missing or invalid notify_via leaves the saved channel alone (it used to store null).
--   * zella_answer_knowledge_gap: accepts the product and price kinds the table allows.
--   * zella_flag_unrecorded_appointments: one failing task no longer stops the rest.
--   * zella_check_engine_health: stuck follow-ups that have used every attempt are failed, not retried forever.
--   * zella_decide_draft: "20% off" is caught as marketing (the word-boundary pattern could never match "% off").
--   * zella_calls_page: a follow-up counts as done when its status is done (the table has no "completed" status).
--   * zella_inbox_previews: the 100-id limit counts every element, whatever the array's shape.
--   * zella_ai_booking: a malformed duration or day count falls back to the default instead of failing the call.
--   * zella_today_operations: "today" is the business's local day, also on the 23- and 25-hour days of DST changes.
--   * zella_save_business_hours: two rows for the same weekday are caught however the weekday is written.
--   * zella_add_business_closure: the audit entry records the same label that was saved.
--   * zella_rebalance_assignments: businesses that never saved assignment rules (round robin by default) are included.
--   * zella_record_status_touches_trg: one message per status change, even when two automations match.
--   * zella_queue_customer_touches: a malformed "days" value falls back to 180 instead of stopping every business.
--   * zella_apply_industry_automations: the general presets (visit feedback, six-month check-in, review request) are
--     created paused, so the owner turns them on; the presets chosen for the business's own industry stay on.
--   * zella_claim_events / zella_complete_event: an event that has used its 5 attempts goes to dead letters instead of
--     being claimed again, and completing an event that is no longer being processed does nothing.
--   * zella_claim_admin_alert_email: a claim that was never finished (the workflow stopped) is retried after 15 minutes,
--     at most 3 times in all; alerts claimed before this change are never re-sent.
--   * zella_queue_calendar_sync: cancelling a booking that never reached the calendar drops its pending upload.
--   * Calendar claims interrupted for 30 minutes are recovered by the claim RPC and health check (up to 5 attempts).
--     n8n reconciles appointment markers before creating an event; exhausted claims use the usual failure alerts.
--   * zella_finish_calendar_sync, zella_replace_calendar_busy: the business's active calendar is updated whichever
--     provider it is (it was always "google"), the owner's message says "your calendar", and a pull of more than 500
--     events is refused before any busy time is removed (it used to delete them all and keep only the first 500).
--
-- Who can do what afterwards: as before, except where listed above. Nothing is sent, and no live flag changes.
-- Verify: tests/review_sql/run.sh (isolated copy only).

begin;

-- Version guard: every function below must be the version this file was written against (or already this
-- file's version, so a second run is a no-op). Otherwise nothing changes.
do $guard$
declare v text;
begin
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_claim_admin_alert_email(integer)');
  if v is null or v not in ('78b170185fbbee0396f5217f91b7980f', '7475a9a1192c1640d4a34c2cd43ac199') then
    raise exception 'VERSION_MISMATCH: public.zella_claim_admin_alert_email(integer) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_admin_routing_save(uuid,jsonb,text)');
  if v is null or v not in ('9d5f8d233ef529d6e6ad99f15f9750a1', '481212ddb7e82c833347b276ae5110cd') then
    raise exception 'VERSION_MISMATCH: public.zella_admin_routing_save(uuid,jsonb,text) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_admin_message_detail(text,uuid,boolean)');
  if v is null or v not in ('ad71ce21bf44c64cc0d1b01878ebd8e3', 'b50368af28d43198d519f69799705596') then
    raise exception 'VERSION_MISMATCH: public.zella_admin_message_detail(text,uuid,boolean) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_admin_template_variables(text,text)');
  if v is null or v not in ('931a50d4976389408e0f9743801bf656', 'b3cf3dce93050cd76604b9a80969c62c') then
    raise exception 'VERSION_MISMATCH: public.zella_admin_template_variables(text,text) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_admin_numbers(text,text,uuid,integer,integer)');
  if v is null or v not in ('ef4838fdec880aed471be646600fcee4', 'bed32020b81254bfb618f4c004260b34') then
    raise exception 'VERSION_MISMATCH: public.zella_admin_numbers(text,text,uuid,integer,integer) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_admin_calls(timestamp with time zone,timestamp with time zone,uuid,text,text,text,boolean,text,integer,integer)');
  if v is null or v not in ('76d07613e1f9a4ef5d8240f7f0d311d9', 'd182a3dbf2112c0e6f8b64c2c82e9f8c') then
    raise exception 'VERSION_MISMATCH: public.zella_admin_calls(timestamp with time zone,timestamp with time zone,uuid,text,text,text,boolean,text,integer,integer) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_admin_automations(text,text,text,uuid,uuid,integer,integer)');
  if v is null or v not in ('4604774c905a8710f4423883ef878d7a', 'f02b02915d6f7ab29390fd83c45ca302') then
    raise exception 'VERSION_MISMATCH: public.zella_admin_automations(text,text,text,uuid,uuid,integer,integer) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_admin_runs(text,uuid,text,timestamp with time zone,timestamp with time zone,integer,integer)');
  if v is null or v not in ('a3e1e913bc7547c82eb3898511afa644', '342c84f42d4e7df997abe5f5f3f0da97') then
    raise exception 'VERSION_MISMATCH: public.zella_admin_runs(text,uuid,text,timestamp with time zone,timestamp with time zone,integer,integer) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_admin_templates(text,text,text,integer,integer)');
  if v is null or v not in ('6ee03a144d856aae53002c822b0996b1', '19e3cf8c0cdcf075404dcbd117bf7846') then
    raise exception 'VERSION_MISMATCH: public.zella_admin_templates(text,text,text,integer,integer) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_set_industry_rules(uuid,jsonb)');
  if v is null or v not in ('1c00e650ac1566977f02b70ffde7c482', '9d987f934d6dee3f9869cc311c9345e8') then
    raise exception 'VERSION_MISMATCH: public.zella_set_industry_rules(uuid,jsonb) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_answer_knowledge_gap(uuid,text,text,text)');
  if v is null or v not in ('ec34ae8717bcde5f0d9befdf84045e6d', 'd3e59106fac39bc25588570dcac27dcd') then
    raise exception 'VERSION_MISMATCH: public.zella_answer_knowledge_gap(uuid,text,text,text) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_knowledge_guard()');
  if v is null or v not in ('2eb712cb74b8ebca84aa321934164bb2', 'c14d02095780cb04f150f165fbed9405') then
    raise exception 'VERSION_MISMATCH: public.zella_knowledge_guard() is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_capture_web_lead(text,text,text,text,text,text,jsonb,boolean,text,text,text,text)');
  if v is null or v not in ('a250820470472da69cb6bb69a262710f', '9135680d4ed9bf46b4651320caf7b106') then
    raise exception 'VERSION_MISMATCH: public.zella_capture_web_lead(text,text,text,text,text,text,jsonb,boolean,text,text,text,text) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_ai_booking(text,uuid,text,jsonb)');
  if v is null or v not in ('62a54ffd24a2500d5e37d80848b441e7', '9a51d8626096d17e653764b5106a9eda') then
    raise exception 'VERSION_MISMATCH: public.zella_ai_booking(text,uuid,text,jsonb) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_flag_unrecorded_appointments()');
  if v is null or v not in ('d6285be3e17dbbde221dc9de1bf7c820', '713dae58c10fac0253dc7a5734b182be') then
    raise exception 'VERSION_MISMATCH: public.zella_flag_unrecorded_appointments() is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_rebalance_assignments()');
  if v is null or v not in ('b5a446cca05995bbe1e6b493b5e74fb3', '8e51bd0ca8d789bea6342eb92976d42f') then
    raise exception 'VERSION_MISMATCH: public.zella_rebalance_assignments() is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_save_business_hours(uuid,jsonb)');
  if v is null or v not in ('18f3299c8b8d86ff077bc476488225fa', 'b97c330a3ab6985e5b0107ead23eca3b') then
    raise exception 'VERSION_MISMATCH: public.zella_save_business_hours(uuid,jsonb) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_add_business_closure(uuid,date,date,text,time without time zone,time without time zone)');
  if v is null or v not in ('146208fe6a703700cc7d58617d6924d3', 'f11db8217743a29ff1892c6dbf9ea6b9') then
    raise exception 'VERSION_MISMATCH: public.zella_add_business_closure(uuid,date,date,text,time without time zone,time without time zone) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_finish_calendar_sync(uuid,boolean,text,text)');
  if v is null or v not in ('39fb72ca1085f27ac9218e920f390fc7', 'f7012f3004e0d9b7c271563bbd96989f') then
    raise exception 'VERSION_MISMATCH: public.zella_finish_calendar_sync(uuid,boolean,text,text) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_calendar_connect_provider(uuid,text,uuid,text,text,text)');
  if v is null or v not in ('59e47a581b66326398601d5f9e739e0e', '251194d9699c23f55b63b306bd80155c') then
    raise exception 'VERSION_MISMATCH: public.zella_calendar_connect_provider(uuid,text,uuid,text,text,text) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_queue_calendar_sync()');
  if v is null or v not in ('33ee870e17e39b7934fbd7cd85eb28cb', 'f8883f2d80575ada191ac230754c2b6f') then
    raise exception 'VERSION_MISMATCH: public.zella_queue_calendar_sync() is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_claim_calendar_sync(integer)');
  if v is null or v not in ('dc2640b340530c2cdfbf663d1b6bc71b', 'b92d1471d2570e0d62eb78d1427309cc') then
    raise exception 'VERSION_MISMATCH: public.zella_claim_calendar_sync(integer) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_replace_calendar_busy(uuid,jsonb)');
  if v is null or v not in ('06ed66f72e3e0ac3d77c43143c3dd726', '0dcce697a56d6c3848fa78be5dac7a0c') then
    raise exception 'VERSION_MISMATCH: public.zella_replace_calendar_busy(uuid,jsonb) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_sensitive_industry(uuid)');
  if v is null or v not in ('7a6c1c0c93afcc384a121ea74b51639d', 'ad2e363ec6fa112404cc2710cc7132e4') then
    raise exception 'VERSION_MISMATCH: public.zella_sensitive_industry(uuid) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_today_operations(uuid)');
  if v is null or v not in ('7e7639036d93663d36643de8c1974033', 'd2d9e704b0b4427aee6c491ab0fe94ad') then
    raise exception 'VERSION_MISMATCH: public.zella_today_operations(uuid) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_merge_customers(uuid,uuid,uuid)');
  if v is null or v not in ('67c12a63703abad917d36110772d227b', '08ab5747bb24046eb2e7af03bd623a72') then
    raise exception 'VERSION_MISMATCH: public.zella_merge_customers(uuid,uuid,uuid) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_log_customer_request(uuid,uuid,text,text,text,uuid,text)');
  if v is null or v not in ('19885e7bd4c40cf1a4de7236a6e5d0bd', 'f2cdbb4b583b7df1e38abee7f4492a8a') then
    raise exception 'VERSION_MISMATCH: public.zella_log_customer_request(uuid,uuid,text,text,text,uuid,text) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_update_customer_request(uuid,text,text)');
  if v is null or v not in ('fc9582465472459ba67e2da8324ca9e9', '84069f6f320403339385701fd365deec') then
    raise exception 'VERSION_MISMATCH: public.zella_update_customer_request(uuid,text,text) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_record_status_touches_trg()');
  if v is null or v not in ('a5bbc266be4840bde237a872c9640e7b', '2472798d91f5140634ae69388b8a1153') then
    raise exception 'VERSION_MISMATCH: public.zella_record_status_touches_trg() is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_queue_customer_touches(integer)');
  if v is null or v not in ('6ec47cae09b7b3bc01cef0ca7778db38', 'a67de53597d676091cad8a6d31381813') then
    raise exception 'VERSION_MISMATCH: public.zella_queue_customer_touches(integer) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_check_engine_health()');
  if v is null or v not in ('94e9eb38a2fb2b7119b784ab8bbbf31d', '2241568c73e146a2fdaea422e102d2aa') then
    raise exception 'VERSION_MISMATCH: public.zella_check_engine_health() is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_ai_voice(text,uuid,text,jsonb)');
  if v is null or v not in ('3d23f57e34634757c15ad593de16c280', '923639e65151324cdeb431e26367fea1') then
    raise exception 'VERSION_MISMATCH: public.zella_ai_voice(text,uuid,text,jsonb) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_complete_followup_task(uuid,text,text,text,uuid,integer)');
  if v is null or v not in ('1de8764b263ee24cbb3c431a9892a5ac', 'bb10e661454ffe7079fce5d0f0925846') then
    raise exception 'VERSION_MISMATCH: public.zella_complete_followup_task(uuid,text,text,text,uuid,integer) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_claim_reminders(integer,text)');
  if v is null or v not in ('fa34d88946ef4b2760d9068f05a3163d', '50d4d7b4d66a4653bbbbc3a094a15e3a') then
    raise exception 'VERSION_MISMATCH: public.zella_claim_reminders(integer,text) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_permission_check()');
  if v is null or v not in ('c1d53645c82f97c2e4670cf1560a9133', '3d5d8247e2a85cfa0dc5851737d66051') then
    raise exception 'VERSION_MISMATCH: public.zella_permission_check() is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_apply_industry_automations(uuid)');
  if v is null or v not in ('62ae8b658e5dee0f1400abe6a91c7a79', '7faa67fef4a15ffaf0f3b40f6ce466bf') then
    raise exception 'VERSION_MISMATCH: public.zella_apply_industry_automations(uuid) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_decide_draft(uuid,boolean,text)');
  if v is null or v not in ('f60a2781f1e5df564f399af6772d4688', '7b92fc3ca810755ab48ffe626cbaf2e2') then
    raise exception 'VERSION_MISMATCH: public.zella_decide_draft(uuid,boolean,text) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_claim_events(integer)');
  if v is null or v not in ('23cf476399ce1591cdfd6e66ef23bd44', '38ef083e202f4450221debe02995e3bf') then
    raise exception 'VERSION_MISMATCH: public.zella_claim_events(integer) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_complete_event(uuid,boolean,text,text)');
  if v is null or v not in ('4fef2e3b8127d07d94138dca9fb3cdc0', 'bcad07cf4df1195bdda334f394c54fd9') then
    raise exception 'VERSION_MISMATCH: public.zella_complete_event(uuid,boolean,text,text) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_record_consent(uuid,text,text,text,uuid,text,text,text,text,jsonb)');
  if v is null or v not in ('c0ecfe6b2a5a7b6d67c534d77cf30e74', '4044d26f09c28639deeffa61a4449beb') then
    raise exception 'VERSION_MISMATCH: public.zella_record_consent(uuid,text,text,text,uuid,text,text,text,text,jsonb) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_calls_page(uuid,text,boolean,integer,jsonb)');
  if v is null or v not in ('418b00001fd73a641124d138807cca4e', '884c5119469f8a4c8462c39067c9c3f7') then
    raise exception 'VERSION_MISMATCH: public.zella_calls_page(uuid,text,boolean,integer,jsonb) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_inbox_previews(uuid,uuid[])');
  if v is null or v not in ('4056e1f758f5da3886e4f5f1a883f562', 'c73ac566a70bcd0400d648e537189aeb') then
    raise exception 'VERSION_MISMATCH: public.zella_inbox_previews(uuid,uuid[]) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_admin_messages(text,timestamp with time zone,timestamp with time zone,uuid,text,text,text,text,integer,integer)');
  if v is null or v not in ('b5266efa18efd567be8823bd366347c7', 'c24262336af3803fcb64c29fd5a6ed4e') then
    raise exception 'VERSION_MISMATCH: public.zella_admin_messages(text,timestamp with time zone,timestamp with time zone,uuid,text,text,text,text,integer,integer) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_config_migration_restore(uuid)');
  if v is null or v not in ('bf10db91f9e8c2f256ce4bde22abf45b', '22a34e2fc9e2711d82189dfc5ceab1ec') then
    raise exception 'VERSION_MISMATCH: public.zella_config_migration_restore(uuid) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_dispatch_n8n()');
  if v is null or v not in ('da510c38639c117833a799c01723f07f', 'a415745bfcd66f15293eee25d2767d7f') then
    raise exception 'VERSION_MISMATCH: public.zella_dispatch_n8n() is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_platform_admin_email_check()');
  if v is null or v not in ('8afa557d293ef3e92a310842c461b6d6', 'b90210c5a2693e974f284f9f33b5fe26') then
    raise exception 'VERSION_MISMATCH: public.zella_platform_admin_email_check() is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_session_proved_email()');
  if v is null or v not in ('6414658bfcbdadb8af7003f4c762ec96', '24b1ef7a8efbb8c511b6cb247cdd5581') then
    raise exception 'VERSION_MISMATCH: public.zella_session_proved_email() is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_offer_redeem_core(uuid,uuid,text,text,text)');
  if v is null or v not in ('c25cd23249dfdc84570416c4bc8de9bd', 'bbdabe8a60a313dee4cbd81b02718791') then
    raise exception 'VERSION_MISMATCH: public.zella_offer_redeem_core(uuid,uuid,text,text,text) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_reassign_callback(uuid,uuid)');
  if v is null or v not in ('137b3dd9edb6b2c632c6d93370757df5', '11428e212deb216c43129ebafb69a030') then
    raise exception 'VERSION_MISMATCH: public.zella_reassign_callback(uuid,uuid) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_erase_customer(uuid,uuid)');
  if v is null or v not in ('c382a6510ef2f93d47c198f2880593ac', '3e070f982d65afbe1bf78ea4af835fe8') then
    raise exception 'VERSION_MISMATCH: public.zella_erase_customer(uuid,uuid) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_language_allowance(uuid)');
  if v is null or v not in ('6065f9d8f83e516cfcf119865723e053', '3803b3857250d255a80058ef0def94ae') then
    raise exception 'VERSION_MISMATCH: public.zella_language_allowance(uuid) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_decide_time_off(uuid,boolean)');
  if v is null or v not in ('65cfff0b090957176b03a09573272fd2', '2cdb807f2fa95ae26db1b3634265fddd') then
    raise exception 'VERSION_MISMATCH: public.zella_decide_time_off(uuid,boolean) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_offboard_member(uuid,uuid,uuid)');
  if v is null or v not in ('5600a85970b4db6d3098f7436118aaaa', '65c78ec745b471a153ce7d00e2dba5f4') then
    raise exception 'VERSION_MISMATCH: public.zella_offboard_member(uuid,uuid,uuid) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_public_status()');
  if v is null or v not in ('5bffa7615dd51d83d6a0cdfe9131c9b8', 'a6b97350537ab1f77f40430f032b98af') then
    raise exception 'VERSION_MISMATCH: public.zella_public_status() is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_check_uptime()');
  if v is null or v not in ('ff763b4ad36144503c67881c4e18790c', '92689ace8808705ae6f51a842623d47f') then
    raise exception 'VERSION_MISMATCH: public.zella_check_uptime() is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_record_email_event(text,jsonb,text)');
  if v is null or v not in ('eab985f3dfbfdadad7b73f6a0b5818a6', '4b8ce14641635b9b92e39863625eecb1') then
    raise exception 'VERSION_MISMATCH: public.zella_record_email_event(text,jsonb,text) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(pg_get_functiondef(oid)) into v from pg_proc where oid = to_regprocedure('public.zella_business_currency(uuid)');
  if v is null or v not in ('478feda6c0e6714ebb6bac9591b19716', '5d3592b5abf157fb6983059e39762b40') then
    raise exception 'VERSION_MISMATCH: public.zella_business_currency(uuid) is not the version this file was written against (expected the live version or this file version)';
  end if;
end $guard$;
-- CodeRabbit #0
CREATE OR REPLACE FUNCTION public.zella_claim_admin_alert_email(p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_live boolean := coalesce(public.zella_setting('email_live', 'false'::jsonb) = 'true'::jsonb, false);
  v_from text := nullif(trim(public.zella_setting('email_from_address', '""'::jsonb) #>> '{}'), '');
  v_to jsonb; v_alerts jsonb;
begin
  select coalesce(jsonb_agg(distinct lower(trim(u.email))), '[]'::jsonb) into v_to
  from public.platform_admins p join auth.users u on u.id = p.user_id where p.is_active and u.email is not null and not exists (select 1 from public.admin_alert_prefs ap where ap.user_id = p.user_id and not ap.email_enabled);
  if not v_live or v_from is null or jsonb_array_length(v_to) = 0 then
    return jsonb_build_object('alerts', '[]'::jsonb, 'to', v_to, 'live', v_live, 'from', v_from,
                              'why', case when not v_live then 'email_off' when v_from is null then 'no_sender' else 'no_admins' end);
  end if;
  with c as (
    update public.platform_alerts a set notified_at = now(),
           meta = coalesce(a.meta, '{}'::jsonb) || jsonb_build_object('email_claimed_at', now())
                  || case when a.notified_at is null then '{}'::jsonb
                          else jsonb_build_object('email_attempts', coalesce((a.meta ->> 'email_attempts')::int, 0) + 1) end
    where a.id in (select s.id from public.platform_alerts s
                   where s.status = 'open'
                     and (s.notified_at is null
                          -- claimed by this version, never finished (no emailed_at), retried at most 3 times in all
                          or (s.meta ? 'email_claimed_at' and not s.meta ? 'emailed_at' and s.notified_at < now() - interval '15 minutes'
                              and coalesce((s.meta ->> 'email_attempts')::int, 0) < 2))
                   order by case s.severity when 'urgent' then 0 when 'warning' then 1 else 2 end, s.first_seen_at
                   limit greatest(1, least(coalesce(p_limit, 25), 50)) for update skip locked)
    returning a.id, a.kind, a.severity, a.title, a.detail, a.occurrences, a.first_seen_at, a.last_seen_at, a.business_id)
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'kind', c.kind, 'severity', c.severity, 'title', c.title, 'detail', c.detail,
           'occurrences', c.occurrences, 'first_seen_at', c.first_seen_at, 'last_seen_at', c.last_seen_at, 'business', b.name)
           order by case c.severity when 'urgent' then 0 when 'warning' then 1 else 2 end, c.first_seen_at), '[]'::jsonb)
    into v_alerts from c left join public.businesses b on b.id = c.business_id;
  return jsonb_build_object('alerts', v_alerts, 'to', v_to, 'live', true, 'from', v_from, 'from_name', 'Zella');
end $function$;

-- CodeRabbit #1
CREATE OR REPLACE FUNCTION public.zella_admin_routing_save(p_business_id uuid, p_rules jsonb, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_reason text := public.zella_admin_reason(p_reason); v_cfg uuid; v_old jsonb; v_new jsonb; v_num text; v_fb text;
begin
  perform public.zella_admin_require('telephony.manage');
  if p_rules is null or jsonb_typeof(p_rules) <> 'object' then raise exception 'INVALID_RULES'; end if;
  select cfg.id, coalesce(cfg.escalation_rules, '{}'::jsonb) into v_cfg, v_old
    from public.ai_agents ag join public.ai_agent_configs cfg on cfg.agent_id = ag.id
   where ag.business_id = p_business_id and ag.is_default limit 1;
  if v_cfg is null then raise exception 'NO_RECEPTIONIST'; end if;
  v_num := nullif(trim(coalesce(p_rules ->> 'transfer_number', '')), '');
  v_fb := nullif(trim(coalesce(p_rules ->> 'fallback_number', '')), '');
  if v_num is not null and public.zella_normalize_e164(v_num) is null then raise exception 'INVALID_TRANSFER_NUMBER'; end if;
  if v_fb is not null and public.zella_normalize_e164(v_fb) is null then raise exception 'INVALID_FALLBACK_NUMBER'; end if;
  if coalesce(p_rules ->> 'transfer_route', 'primary') not in ('primary', 'fallback') then raise exception 'INVALID_ROUTE'; end if;
  if p_rules ->> 'transfer_route' = 'fallback' and v_fb is null then raise exception 'FALLBACK_NEEDS_NUMBER'; end if;
  v_new := v_old
    || jsonb_build_object('transfer_enabled', coalesce((p_rules ->> 'transfer_enabled')::boolean, true),
                          'transfer_number', coalesce(public.zella_normalize_e164(v_num), ''),
                          'fallback_number', coalesce(public.zella_normalize_e164(v_fb), ''),
                          'transfer_route', coalesce(p_rules ->> 'transfer_route', 'primary'),
                          'transfer_open_hours_only', coalesce((p_rules ->> 'transfer_open_hours_only')::boolean, true));
  update public.ai_agent_configs set escalation_rules = v_new, updated_at = now() where id = v_cfg;
  perform public.zella_admin_audit('telephony.routing_updated', 'business', p_business_id, p_business_id,
    jsonb_build_object('transfer_enabled', v_old -> 'transfer_enabled', 'transfer_number', public.zella_admin_mask(v_old ->> 'transfer_number'),
                       'fallback_number', public.zella_admin_mask(v_old ->> 'fallback_number'), 'transfer_route', v_old -> 'transfer_route', 'open_hours_only', v_old -> 'transfer_open_hours_only'),
    jsonb_build_object('transfer_enabled', v_new -> 'transfer_enabled', 'transfer_number', public.zella_admin_mask(v_new ->> 'transfer_number'),
                       'fallback_number', public.zella_admin_mask(v_new ->> 'fallback_number'), 'transfer_route', v_new -> 'transfer_route', 'open_hours_only', v_new -> 'transfer_open_hours_only', 'reason', v_reason));
  return public.zella_admin_routing_get(p_business_id);
end $function$;

-- CodeRabbit #2
CREATE OR REPLACE FUNCTION public.zella_admin_message_detail(p_channel text, p_id uuid, p_with_content boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s public.sms_messages; e public.email_messages; v_content boolean := coalesce(p_with_content, false) and public.zella_admin_can('comms.manage'); out jsonb;
begin
  perform public.zella_admin_require('businesses.view');
  if p_channel = 'sms' then
    select * into s from public.sms_messages where id = p_id;
    if s.id is null then raise exception 'NOT_FOUND'; end if;
    out := jsonb_build_object('message', jsonb_build_object('id', s.id, 'business_id', s.business_id, 'business_name', (select name from public.businesses where id = s.business_id),
        'direction', s.direction, 'status', s.status, 'to', public.zella_admin_mask(s.to_number), 'from', public.zella_admin_mask(s.from_number),
        'provider_id', s.external_message_id, 'created_at', s.created_at, 'sent_at', s.sent_at, 'delivered_at', s.delivered_at, 'updated_at', s.updated_at,
        'conversation_id', s.conversation_id, 'customer_id', s.customer_id,
        'meta', s.metadata - 'body' - 'text'),
      'content', case when v_content then jsonb_build_object('body', s.message_body) end);
    if v_content then perform public.zella_admin_audit('admin.message_content_viewed', 'sms_message', s.id, s.business_id, null, null); end if;
  elsif p_channel = 'email' then
    select * into e from public.email_messages where id = p_id;
    if e.id is null then raise exception 'NOT_FOUND'; end if;
    out := jsonb_build_object('message', jsonb_build_object('id', e.id, 'business_id', e.business_id, 'business_name', (select name from public.businesses where id = e.business_id),
        'direction', e.direction, 'status', e.status, 'to', public.zella_admin_mask(e.to_email), 'from', e.from_email, 'subject', e.subject,
        'provider_id', e.external_message_id, 'created_at', e.created_at, 'sent_at', e.sent_at, 'delivered_at', e.delivered_at, 'updated_at', e.updated_at,
        'conversation_id', e.conversation_id, 'customer_id', e.customer_id, 'meta', e.metadata - 'body' - 'text' - 'html' - 'body_text' - 'body_html'),
      'events', coalesce((select jsonb_agg(jsonb_build_object('type', ev.type, 'at', ev.created_at, 'detail', ev.detail - 'to' - 'from' - 'email') order by ev.created_at)
                            from public.email_events ev where ev.email_message_id = e.id), '[]'::jsonb),
      'content', case when v_content then jsonb_build_object('body', e.body_text) end);
    if v_content then perform public.zella_admin_audit('admin.message_content_viewed', 'email_message', e.id, e.business_id, null, null); end if;
  else raise exception 'INVALID_CHANNEL'; end if;
  return out || jsonb_build_object('content_allowed', public.zella_admin_can('comms.manage'), 'retry', public.zella_admin_message_retry_check(p_channel, p_id));
end $function$;

-- CodeRabbit #3
CREATE OR REPLACE FUNCTION public.zella_admin_template_variables(p_key text, p_channel text)
 RETURNS text[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select array(select distinct v from (
      select (regexp_matches(coalesce(t.body, '') || ' ' || coalesce(t.subject, ''), '\{\{\s*([a-z_]+)\s*\}\}', 'g'))[1] v
        from public.message_templates t where t.key = p_key and t.channel = p_channel and t.business_id is null
      union all select unnest(array['first_name', 'business'])) x order by 1);
$function$;

-- CodeRabbit #4
CREATE OR REPLACE FUNCTION public.zella_admin_numbers(p_q text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_business uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 25, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_q text := nullif(regexp_replace(coalesce(p_q, ''), '[^0-9A-Za-z +@.-]', '', 'g'), ''); v_lim int := least(greatest(coalesce(p_limit, 25), 1), 100);
begin
  perform public.zella_admin_require('businesses.view');
  return (with f as (
      select n.*, b.name as business_name, b.timezone, b.suspended_at, b.cancelled_at, b.is_active as business_active,
             (select jsonb_build_object('id', a.id, 'name', a.name, 'status', a.status) from public.ai_agents a
               where a.business_id = n.business_id and a.agent_type = 'receptionist' order by a.is_default desc, a.created_at limit 1) as agent
        from public.business_phone_numbers n join public.businesses b on b.id = n.business_id
       where (p_status is null or n.status = p_status)
         and (p_business is null or n.business_id = p_business)
         and (v_q is null or n.e164 like '%' || regexp_replace(v_q, '\D', '', 'g') || '%' and regexp_replace(v_q, '\D', '', 'g') <> ''
              or b.name ilike '%' || v_q || '%' or coalesce(n.label, '') ilike '%' || v_q || '%'))
    select jsonb_build_object('total', (select count(*) from f), 'rows', coalesce((select jsonb_agg(jsonb_build_object(
        'id', f.id, 'e164', f.e164, 'country_code', '+' || substring(f.e164 from 2 for case when f.e164 like '+1%' or f.e164 like '+7%' then 1 else 2 end),
        'label', f.label, 'status', f.status, 'vapi_linked', f.vapi_phone_number_id is not null, 'vapi_phone_number_id', f.vapi_phone_number_id,
        'business_id', f.business_id, 'business_name', f.business_name,
        'business_state', case when f.cancelled_at is not null then 'cancelled' when f.suspended_at is not null then 'suspended'
                               when coalesce(f.business_active, false) then 'active' else 'setup' end,
        'agent', f.agent, 'created_at', f.created_at,
        'calls_30d', (select count(*) from public.calls c where c.business_id = f.business_id
                       and (c.to_number = f.e164 or c.from_number = f.e164) and c.created_at > now() - interval '30 days'),
        'last_call_at', (select max(c.created_at) from public.calls c where c.business_id = f.business_id and (c.to_number = f.e164 or c.from_number = f.e164)))
        order by f.created_at desc) from (select * from f order by created_at desc, id limit v_lim offset greatest(coalesce(p_offset, 0), 0)) f), '[]'::jsonb)));
end $function$;

-- CodeRabbit #4
CREATE OR REPLACE FUNCTION public.zella_admin_calls(p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_business uuid DEFAULT NULL::uuid, p_direction text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_outcome text DEFAULT NULL::text, p_failed_only boolean DEFAULT false, p_q text DEFAULT NULL::text, p_limit integer DEFAULT 25, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_lim int := least(greatest(coalesce(p_limit, 25), 1), 100); v_digits text := nullif(regexp_replace(coalesce(p_q, ''), '\D', '', 'g'), '');
begin
  perform public.zella_admin_require('businesses.view');
  return (with f as (
      select c.* from public.calls c
       where c.created_at >= coalesce(p_from, now() - interval '30 days') and c.created_at < coalesce(p_to, now() + interval '1 minute')
         and (p_business is null or c.business_id = p_business)
         and (p_direction is null or c.direction = p_direction)
         and (p_status is null or c.status = p_status)
         and (p_outcome is null or c.outcome = p_outcome)
         and (not coalesce(p_failed_only, false) or c.status = 'failed' or c.failure_reason is not null or c.transfer_status in ('failed', 'no_one_available'))
         and (v_digits is null or length(v_digits) < 4 or regexp_replace(coalesce(c.from_number, ''), '\D', '', 'g') like '%' || v_digits || '%'
              or regexp_replace(coalesce(c.to_number, ''), '\D', '', 'g') like '%' || v_digits || '%'))
    select jsonb_build_object('total', (select count(*) from f), 'rows', coalesce((select jsonb_agg(jsonb_build_object(
        'id', f.id, 'created_at', f.created_at, 'business_id', f.business_id, 'business_name', b.name,
        'direction', f.direction, 'status', f.status, 'caller', public.zella_admin_mask(case when f.direction = 'inbound' then f.from_number else f.to_number end),
        'number', case when f.direction = 'inbound' then f.to_number else f.from_number end,
        'agent', (select a.name from public.ai_agents a where a.business_id = f.business_id and a.agent_type = 'receptionist' order by a.is_default desc limit 1),
        'ai_handled', f.ai_handled, 'duration_seconds', f.duration_seconds, 'outcome', f.outcome, 'transfer_status', f.transfer_status,
        'has_recording', f.recording_url is not null, 'has_transcript', f.transcript is not null, 'failure_reason', f.failure_reason,
        'needs_human', f.needs_human) order by f.created_at desc, f.id)
      from (select * from f order by created_at desc, id limit v_lim offset greatest(coalesce(p_offset, 0), 0)) f
      join public.businesses b on b.id = f.business_id), '[]'::jsonb)));
end $function$;

-- CodeRabbit #4
CREATE OR REPLACE FUNCTION public.zella_admin_automations(p_q text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_trigger text DEFAULT NULL::text, p_business uuid DEFAULT NULL::uuid, p_industry uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 25, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_q text := nullif(lower(trim(coalesce(p_q, ''))), ''); v_lim int := least(greatest(coalesce(p_limit, 25), 1), 100);
begin
  perform public.zella_admin_require('businesses.view');
  return (with f as (
      select a.*, b.name as business_name, b.industry_id, i.name as industry_name, b.is_active as business_live, b.suspended_at
        from public.automations a join public.businesses b on b.id = a.business_id left join public.industries i on i.id = b.industry_id
       where (p_status is null or a.status = p_status) and (p_trigger is null or a.trigger_type = p_trigger)
         and (p_business is null or a.business_id = p_business) and (p_industry is null or b.industry_id = p_industry)
         and (v_q is null or lower(a.name) like '%' || v_q || '%' or lower(b.name) like '%' || v_q || '%' or a.trigger_type like '%' || v_q || '%'))
    select jsonb_build_object('total', (select count(*) from f),
      'triggers', (select coalesce(jsonb_agg(distinct trigger_type), '[]'::jsonb) from public.automations),
      'can_manage', public.zella_admin_can('integrations.manage'),
      'rows', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'name', f.name, 'description', f.description, 'scope', 'business',
          'trigger_type', f.trigger_type, 'status', f.status, 'business_id', f.business_id, 'business_name', f.business_name,
          'industry_name', f.industry_name, 'business_live', coalesce(f.business_live, false), 'business_suspended', f.suspended_at is not null,
          'paused_by_suspension', f.paused_by_suspension, 'updated_at', f.updated_at, 'created_at', f.created_at,
          'runs', (select jsonb_build_object('total', count(*), 'failed', count(*) filter (where r.status = 'failed'), 'last_at', max(r.created_at),
                                             'last_status', (select r2.status from public.automation_runs r2 where r2.automation_id = f.id order by r2.created_at desc limit 1))
                     from public.automation_runs r where r.automation_id = f.id))
          order by f.business_name, f.name, f.id)
        from (select * from f order by business_name, name, id limit v_lim offset greatest(coalesce(p_offset, 0), 0)) f), '[]'::jsonb)));
end $function$;

-- CodeRabbit #4
CREATE OR REPLACE FUNCTION public.zella_admin_runs(p_status text DEFAULT NULL::text, p_business uuid DEFAULT NULL::uuid, p_q text DEFAULT NULL::text, p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 25, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_lim int := least(greatest(coalesce(p_limit, 25), 1), 100); v_q text := nullif(lower(trim(coalesce(p_q, ''))), '');
        v_from timestamptz := coalesce(p_from, now() - interval '30 days'); v_to timestamptz := coalesce(p_to, now() + interval '1 minute');
begin
  perform public.zella_admin_require('businesses.view');
  return (with u as (
      select 'workflow' as kind, w.id, w.business_id, w.workflow_key as name, w.status, w.started_at, w.finished_at, w.current_step as failed_step,
             w.error_category, left(w.error_message, 200) as error, w.retry_count as attempts, w.needs_manual, w.event_id
        from public.workflow_executions w where w.started_at >= v_from and w.started_at < v_to
      union all
      select 'run', r.id, r.business_id, a.name, case r.status when 'completed' then 'succeeded' when 'queued' then 'running' when 'waiting' then 'running' else r.status end,
             coalesce(r.started_at, r.created_at), r.completed_at, r.last_action_status, null, left(r.error_message, 200), r.attempt_count, false, null
        from public.automation_runs r join public.automations a on a.id = r.automation_id where r.created_at >= v_from and r.created_at < v_to),
    f as (select * from u where (p_status is null or status = p_status) and (p_business is null or business_id = p_business)
            and (v_q is null or lower(name) like '%' || v_q || '%' or lower(coalesce(error, '')) like '%' || v_q || '%'))
    select jsonb_build_object('total', (select count(*) from f), 'rows', coalesce((select jsonb_agg(jsonb_build_object(
        'kind', f.kind, 'id', f.id, 'name', f.name, 'business_id', f.business_id, 'business_name', b.name, 'status', f.status,
        'started_at', f.started_at, 'finished_at', f.finished_at, 'duration_seconds', round(extract(epoch from f.finished_at - f.started_at)::numeric, 1),
        'failed_step', case when f.status = 'failed' then f.failed_step end, 'error_category', f.error_category, 'error', f.error,
        'attempts', f.attempts, 'needs_manual', f.needs_manual) order by f.started_at desc, f.id)
      from (select * from f order by started_at desc, id limit v_lim offset greatest(coalesce(p_offset, 0), 0)) f left join public.businesses b on b.id = f.business_id), '[]'::jsonb)));
end $function$;

-- CodeRabbit #4
CREATE OR REPLACE FUNCTION public.zella_admin_templates(p_q text DEFAULT NULL::text, p_channel text DEFAULT NULL::text, p_scope text DEFAULT 'platform'::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_q text := nullif(lower(trim(coalesce(p_q, ''))), ''); v_lim int := least(greatest(coalesce(p_limit, 50), 1), 100);
begin
  perform public.zella_admin_require('businesses.view');
  return (with f as (
      select t.*, i.name as industry_name, b.name as business_name from public.message_templates t
        left join public.industries i on i.id = t.industry_id left join public.businesses b on b.id = t.business_id
       where t.status = 'active' and (p_channel is null or t.channel = p_channel)
         and case coalesce(p_scope, 'platform') when 'platform' then t.business_id is null when 'business' then t.business_id is not null else true end
         and (v_q is null or t.key like '%' || v_q || '%' or lower(t.body) like '%' || v_q || '%' or lower(coalesce(t.subject, '')) like '%' || v_q || '%'))
    select jsonb_build_object('total', (select count(*) from f), 'can_edit', public.zella_admin_can('comms.manage'),
      'rows', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'key', f.key, 'channel', f.channel, 'purpose', f.purpose, 'locale', f.locale,
          'subject', f.subject, 'body', f.body, 'version', f.version, 'status', f.status, 'created_at', f.created_at,
          'scope', case when f.business_id is not null then 'business' when f.industry_id is not null then 'industry' else 'platform' end,
          'industry_id', f.industry_id, 'industry_name', f.industry_name, 'business_id', f.business_id, 'business_name', f.business_name,
          'variables', public.zella_admin_template_variables(f.key, f.channel),
          'business_copies', (select count(*) from public.message_templates x where x.key = f.key and x.channel = f.channel and x.business_id is not null and x.status = 'active'))
          order by f.key, f.channel, f.industry_name nulls first, f.id)
        from (select * from f order by key, channel, id limit v_lim offset greatest(coalesce(p_offset, 0), 0)) f), '[]'::jsonb)));
end $function$;

-- CodeRabbit #7
CREATE OR REPLACE FUNCTION public.zella_set_industry_rules(p_business_id uuid, p_rules jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_key text; r jsonb; p public.industry_automation_presets; a public.automations; n integer := 0; v_notify text; v_on boolean;
begin
  if not (public.is_platform_admin() or public.zella_has_role(p_business_id, array['owner', 'admin'])) then raise exception 'NOT_ALLOWED'; end if;
  if p_rules is null or jsonb_typeof(p_rules) <> 'array' then raise exception 'BAD_RULES'; end if;
  v_key := public.zella_industry_key_for(p_business_id);
  for r in select * from jsonb_array_elements(p_rules) loop
    select * into p from public.industry_automation_presets where name = r ->> 'name' and (industry_key in (v_key, 'general') or v_key = 'other') order by (industry_key = 'general') limit 1;
    if not found then continue; end if;
    v_notify := case when r ->> 'notify_via' in ('sms', 'email', 'both') then r ->> 'notify_via' else null end;
    v_on := coalesce((r ->> 'enabled')::boolean, true);
    select * into a from public.automations where business_id = p_business_id and name = p.name for update;
    if not found then
      insert into public.automations (business_id, name, description, trigger_type, status, trigger_config, actions, conditions, created_by)
      values (p_business_id, p.name, p.description, p.trigger_type, case when v_on then 'active' else 'disabled' end,
              p.trigger_config || case when v_notify is null then '{}'::jsonb else jsonb_build_object('notify_via', v_notify) end, '[]'::jsonb, '{}'::jsonb, auth.uid());
    else
      update public.automations set status = case when v_on then 'active' else 'disabled' end,
             trigger_config = a.trigger_config || case when v_notify is null then '{}'::jsonb else jsonb_build_object('notify_via', v_notify) end, updated_at = now()
       where id = a.id;
    end if;
    n := n + 1;
  end loop;
  insert into public.audit_logs (business_id, user_id, action, entity_type, new_data) values (p_business_id, auth.uid(), 'industry_rules.changed', 'automations', jsonb_build_object('count', n));
  return n;
end $function$;

-- CodeRabbit #12
CREATE OR REPLACE FUNCTION public.zella_answer_knowledge_gap(p_gap_id uuid, p_answer text, p_kind text DEFAULT 'faq'::text, p_title text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_gap record; v_item uuid;
begin
  select * into v_gap from public.knowledge_gaps where id = p_gap_id for update;
  if not found or not public.zella_knowledge_gap_editor(v_gap.business_id) then   -- zella_gap_editor_check
    raise exception 'NOT_ALLOWED';
  end if;
  if v_gap.status <> 'open' then raise exception 'ALREADY_RESOLVED'; end if;
  if nullif(trim(coalesce(p_answer, '')), '') is null then raise exception 'EMPTY_ANSWER'; end if;
  insert into public.knowledge_items (business_id, kind, title, question, answer, status, gap_id, created_by, approved_by, approved_at)
  values (v_gap.business_id, case when p_kind in ('faq','service','policy','hours','other','product','price') then p_kind else 'faq' end,
          coalesce(nullif(trim(p_title), ''), left(v_gap.question, 80)), v_gap.question, trim(p_answer), 'processing', p_gap_id, auth.uid(), auth.uid(), now())
  returning id into v_item;
  update public.knowledge_gaps set status = 'answered', knowledge_item_id = v_item, resolved_by = auth.uid(), resolved_at = now() where id = p_gap_id;
  return v_item;
end $function$;

-- CodeRabbit #13
CREATE OR REPLACE FUNCTION public.zella_knowledge_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_service boolean := coalesce(auth.role(), 'service_role') = 'service_role' and auth.uid() is null;
begin
  if tg_op = 'INSERT' then
    if not v_service then
      new.approved_by := null; new.approved_at := null;   -- only this guard sets them
      new.status := case when new.status = 'draft' then 'draft' else 'processing' end;
      new.version := 1; new.error := null; new.ready_at := null;
      new.created_by := auth.uid();
      if new.status = 'processing' then new.approved_by := auth.uid(); new.approved_at := now(); end if;
    end if;
    return new;
  end if;

  if not v_service then
    -- members may change content, archive, or send a draft for processing; nothing else
    if new.status not in ('draft', 'processing', 'archived') then
      new.status := old.status;
    end if;
    if new.status = 'ready' or (old.status = 'ready' and new.status = 'ready') then new.status := old.status; end if;
    new.ready_at := old.ready_at; new.error := old.error; new.version := old.version;
    new.business_id := old.business_id; new.created_by := old.created_by; new.gap_id := old.gap_id;
    new.approved_by := old.approved_by; new.approved_at := old.approved_at;   -- changed below only when it is approved now
    if (new.title, new.question, new.answer, new.kind) is distinct from (old.title, old.question, old.answer, old.kind)
       and new.status <> 'archived' then
      -- changed content is never live until it has been processed again
      new.status := case when old.status = 'draft' and new.status = 'draft' then 'draft' else 'processing' end;
      new.version := old.version + 1; new.error := null; new.ready_at := null;
      if new.status = 'processing' then new.approved_by := auth.uid(); new.approved_at := now(); end if;
    elsif old.status = 'draft' and new.status = 'processing' then
      new.approved_by := auth.uid(); new.approved_at := now(); new.version := old.version + 1;
    end if;
  end if;
  new.updated_at := now();
  return new;
end $function$;

-- CodeRabbit #14
CREATE OR REPLACE FUNCTION public.zella_capture_web_lead(p_public_key text, p_kind text, p_name text DEFAULT NULL::text, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_message text DEFAULT NULL::text, p_source jsonb DEFAULT '{}'::jsonb, p_marketing_consent boolean DEFAULT false, p_origin text DEFAULT NULL::text, p_ip text DEFAULT NULL::text, p_honeypot text DEFAULT NULL::text, p_channel text DEFAULT 'website'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  f public.website_forms; v_kind text; v_channel text; v_name text; v_phone text; v_email text; v_msg text; v_src jsonb := '{}'::jsonb;
  v_cust uuid; v_cb uuid; v_sub uuid; v_urgent boolean; v_first text; v_last text; k text; v_summary text; v_reason text; v_ack text;
  v_digits text;
begin
  select * into f from public.website_forms where public_key = p_public_key and enabled;
  if f.id is null then return jsonb_build_object('ok', false, 'error', 'unknown_form'); end if;
  if cardinality(f.allowed_origins) > 0 and (p_origin is null or not (lower(p_origin) = any (select lower(x) from unnest(f.allowed_origins) x))) then
    return jsonb_build_object('ok', false, 'error', 'origin_not_allowed');
  end if;

  v_kind := case when p_kind in ('contact_form','quote_request','appointment_request','callback_request','chat','newsletter_signup') then p_kind else null end;
  v_channel := case when p_channel in ('website','website_chat') then p_channel else 'website' end;
  if v_kind is null then return jsonb_build_object('ok', false, 'error', 'unknown_kind'); end if;

  if not public.zella_rate_limit('form:' || f.id::text || ':' || coalesce(left(p_ip, 64), 'x'), 5, 60) or not public.zella_rate_limit('form:' || f.id::text, 60, 60) then
    insert into public.lead_submissions (business_id, form_id, kind, channel, status) values (f.business_id, f.id, v_kind, v_channel, 'rate_limited');
    return jsonb_build_object('ok', false, 'error', 'too_many_requests');
  end if;

  v_name := left(nullif(trim(coalesce(p_name, '')), ''), 120);
  v_phone := left(nullif(trim(coalesce(p_phone, '')), ''), 40);
  v_email := left(nullif(lower(trim(coalesce(p_email, ''))), ''), 254);
  v_msg := left(nullif(trim(coalesce(p_message, '')), ''), 2000);
  v_digits := public.zella_digits(v_phone);
  v_ack := 'Thank you. We have your details and will be in touch soon.';

  if nullif(trim(coalesce(p_honeypot, '')), '') is not null or (length(coalesce(v_msg, '')) - length(replace(lower(coalesce(v_msg, '')), 'http', ''))) / 4 > 2 then
    insert into public.lead_submissions (business_id, form_id, kind, channel, status) values (f.business_id, f.id, v_kind, v_channel, 'spam');
    return jsonb_build_object('ok', true, 'message', v_ack);
  end if;

  if v_phone is not null and (v_digits is null or length(v_digits) < 7 or length(v_digits) > 15) then
    return jsonb_build_object('ok', false, 'error', 'invalid_phone', 'message', 'Please enter a valid phone number.');
  end if;
  if v_email is not null and not public.zella_valid_email(v_email) then
    return jsonb_build_object('ok', false, 'error', 'invalid_email', 'message', 'Please enter a valid email address.');
  end if;
  if v_phone is null and v_email is null then
    return jsonb_build_object('ok', false, 'error', 'no_contact', 'message', 'Please give a phone number or an email address so we can reply.');
  end if;
  if v_kind = 'newsletter_signup' and v_email is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_email', 'message', 'Please enter your email address.');
  end if;

  foreach k in array array['utm_source','utm_medium','utm_campaign','utm_term','utm_content','referrer','page_url'] loop
    if nullif(trim(coalesce(p_source ->> k, '')), '') is not null then v_src := v_src || jsonb_build_object(k, left(p_source ->> k, 300)); end if;
  end loop;

  v_urgent := coalesce(v_msg ~* '(emergency|urgent|asap|right now|immediately|flood|leak|no heat|no power|burst)', false);

  begin
    select m.customer_id into v_cust from public.zella_match_customer(f.business_id, v_phone, v_email) m where m.certainty = 'exact' limit 1;
    if v_cust is null then
      v_first := split_part(coalesce(v_name, ''), ' ', 1);
      v_last := nullif(trim(substr(coalesce(v_name, ''), length(v_first) + 1)), '');
      insert into public.customers (business_id, first_name, last_name, phone, email, status, source, lead_stage, priority, qualification, metadata)
      values (f.business_id, coalesce(nullif(v_first, ''), 'Website visitor'), v_last, v_phone, v_email, 'active', v_channel, 'new',
              case when v_urgent then 'high' else 'normal' end,
              jsonb_build_object('kind', v_kind, 'urgent', v_urgent, 'has_phone', v_phone is not null, 'has_email', v_email is not null),
              jsonb_build_object('attribution', jsonb_build_object('first_touch', v_src || jsonb_build_object('channel', v_channel, 'at', now()))))
      returning id into v_cust;
    else
      update public.customers set
          metadata = jsonb_set(coalesce(metadata, '{}'::jsonb), '{attribution,last_touch}', v_src || jsonb_build_object('channel', v_channel, 'at', now()), true),
          updated_at = now()   -- the visitor's wording stays on the submission and callback, not on the customer
        where id = v_cust;
      if exists (select 1 from public.lead_submissions s where s.customer_id = v_cust and s.kind = v_kind and s.status = 'accepted' and s.created_at > now() - interval '10 minutes') then
        insert into public.lead_submissions (business_id, form_id, kind, channel, status, customer_id, source) values (f.business_id, f.id, v_kind, v_channel, 'duplicate', v_cust, v_src);
        return jsonb_build_object('ok', true, 'message', v_ack);
      end if;
    end if;

    if v_kind = 'newsletter_signup' or p_marketing_consent then
      if v_email is not null then
        insert into public.contact_consents (business_id, customer_id, email_lower, channel, purpose, status, source, evidence)
        values (f.business_id, v_cust, v_email, 'email', 'marketing', 'opted_in', 'web_form', jsonb_build_object('form_id', f.id, 'origin', left(p_origin, 200), 'at', now()));
      end if;
      if v_digits is not null and p_marketing_consent then
        insert into public.contact_consents (business_id, customer_id, phone_digits, channel, purpose, status, source, evidence)
        values (f.business_id, v_cust, v_digits, 'sms', 'marketing', 'opted_in', 'web_form', jsonb_build_object('form_id', f.id, 'origin', left(p_origin, 200), 'at', now()));
      end if;
    end if;

    v_summary := left(case v_kind
        when 'quote_request' then 'Quote request' when 'appointment_request' then 'Wants an appointment'
        when 'callback_request' then 'Asked for a call back' when 'chat' then 'Website chat enquiry'
        when 'newsletter_signup' then 'Newsletter signup' else 'Website enquiry' end
      || coalesce(': ' || v_msg, ''), 600);
    v_reason := case v_kind when 'appointment_request' then 'appointment_request' when 'callback_request' then 'requested' else 'new_lead' end;

    if v_kind <> 'newsletter_signup' then
      if v_digits is not null then
        v_cb := public.zella_create_callback(f.business_id, v_phone, v_reason, case when v_urgent then 'high' else 'normal' end, v_summary, null, v_cust, null, null, 'system',
                                             case when v_reason = 'new_lead' then 'new_lead_callback' else 'missed_call_follow_up' end);
      else
        perform public.zella_notify(f.business_id, 'website_lead', 'New website enquiry', v_summary || ' (email only: ' || v_email || ')', case when v_urgent then 'urgent' else 'info' end, 'customers', v_cust);
      end if;
    end if;

    insert into public.lead_submissions (business_id, form_id, kind, channel, status, customer_id, callback_id, source, summary, urgent)
    values (f.business_id, f.id, v_kind, v_channel, 'accepted', v_cust, v_cb, v_src, v_summary, v_urgent) returning id into v_sub;
    return jsonb_build_object('ok', true, 'message', v_ack, 'submission_id', v_sub);
  exception when others then
    insert into public.lead_submissions (business_id, form_id, kind, channel, status, source) values (f.business_id, f.id, v_kind, v_channel, 'failed', v_src);
    perform public.zella_platform_alert('lead_capture_failed', 'A website lead could not be saved', left(sqlerrm, 200), 'warning', f.business_id, 'lead_capture_failed:' || f.business_id::text);
    return jsonb_build_object('ok', false, 'error', 'try_again', 'message', 'Something went wrong. Please try again or call us.');
  end;
end $function$;

-- CodeRabbit #16
CREATE OR REPLACE FUNCTION public.zella_ai_booking(p_provider_call_id text, p_business_id uuid, p_action text, p_args jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_args jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  v_call_biz uuid; v_call_phone text; v_biz uuid; v_tz text;
  v_dur integer; v_from timestamptz; v_to timestamptz; v_day date; v_days integer; v_slots jsonb;
  v_start timestamptz; v_title text; v_first text; v_last text; v_phone text; v_email text; v_notes text;
  v_lead jsonb; v_cust uuid; v_appt uuid; v_err text; v_when text; v_book_rules jsonb; v_notice integer; v_ahead integer; v_window integer; v_tables boolean; v_party integer; v_pref jsonb;
begin
  if nullif(p_provider_call_id, '') is not null then
    select c.business_id, c.from_number into v_call_biz, v_call_phone from public.calls c where c.external_call_id = p_provider_call_id limit 1;
  end if;
  v_biz := coalesce(v_call_biz, p_business_id);
  select b.id, coalesce(b.timezone, 'America/New_York') into v_biz, v_tz from public.businesses b
   where b.id = v_biz and b.suspended_at is null and b.cancelled_at is null and coalesce(b.is_active, true);
  if v_biz is null then raise exception 'UNKNOWN_BUSINESS'; end if;

  v_dur := least(480, greatest(5, case when (v_args ->> 'duration_minutes') ~ '^\d{1,4}$' then (v_args ->> 'duration_minutes')::integer else 30 end));
  /* zella_setup_enforcement_booking: the setup's booking rules */
  v_book_rules := public.zella_booking_rules(v_biz);
  v_notice := case when (v_book_rules ->> 'min_notice_hours') ~ '^\d{1,3}$' then (v_book_rules ->> 'min_notice_hours')::integer else 0 end;
  v_ahead := case when (v_book_rules ->> 'max_days_ahead') ~ '^\d{1,3}$' then greatest(1, (v_book_rules ->> 'max_days_ahead')::integer) end;
  if nullif(v_args ->> 'duration_minutes', '') is null and (v_book_rules ->> 'default_minutes') ~ '^\d{1,3}$' then
    v_dur := least(480, greatest(5, (v_book_rules ->> 'default_minutes')::integer));
  end if;

  v_window := public.zella_arrival_window(v_biz);   /* zella_arrival_windows: a window is booked whole */
  if v_window is not null then v_dur := v_window; end if;
  v_tables := public.zella_table_mode(v_biz);   /* zella_tables */
  v_party := case when (v_args ->> 'party_size') ~ '^\d{1,3}$' then (v_args ->> 'party_size')::int end;
  if v_tables and p_action in ('availability', 'book') then
    if v_party is null or v_party < 1 then
      return jsonb_build_object('ok', false, 'status', 'need_info', 'say', 'Ask how many people the reservation is for, then try again with party_size.');
    end if;
    if p_action = 'availability' and v_party > public.zella_max_party_ai(v_biz) then
      return jsonb_build_object('ok', true, 'status', 'large_party', 'slots', '[]'::jsonb, 'say',
        'Parties of more than ' || public.zella_max_party_ai(v_biz) || ' are arranged by the team. Ask for the preferred day and time, the name and a phone number, then call book_appointment with that time: it is passed to the team to confirm. Do not say it is booked.');
    end if;
    v_pref := public.zella_seating_pref(v_biz, v_args ->> 'seating');
  end if;

  if p_action in ('availability', 'book') then
    begin v_day := nullif(v_args ->> 'date', '')::date; exception when others then v_day := null; end;
    v_day := greatest(coalesce(v_day, (now() at time zone v_tz)::date), (now() at time zone v_tz)::date);
    v_days := least(14, greatest(1, case when (v_args ->> 'days') ~ '^\d{1,3}$' then (v_args ->> 'days')::integer else 3 end));
  end if;

  if p_action = 'availability' then
    v_from := v_day::timestamp at time zone v_tz;
    v_to := (v_day + v_days)::timestamp at time zone v_tz;
    v_from := greatest(v_from, now() + make_interval(hours => v_notice));
    if v_ahead is not null then v_to := least(v_to, now() + make_interval(days => v_ahead)); end if;
    if v_to <= v_from then
      return jsonb_build_object('ok', true, 'status', 'slots', 'slots', '[]'::jsonb, 'say',
        'There are no openings in that period. This business books from ' || v_notice || ' hours ahead'
        || coalesce(' and up to ' || v_ahead || ' days ahead', '') || '. Offer other days in that range, or take a message.');
    end if;
    select coalesce(jsonb_agg(jsonb_build_object('start', s.slot_start, 'say', public.zella_slot_say(s.slot_start, v_tz, v_window))), '[]'::jsonb)
      into v_slots from public.zella_offer_times(v_tables, v_party, v_biz, v_from, v_to, v_dur, v_window, v_args ->> 'seating') s;
    return jsonb_build_object('ok', true, 'status', 'slots', 'slots', v_slots,
      'say', case when jsonb_array_length(v_slots) = 0 then 'There are no openings in that period. Offer to look at other days.' else 'Offer the caller these times and let them choose.' end);
  end if;

  if p_action <> 'book' then raise exception 'BAD_ACTION'; end if;
  perform public.zella_booking_lock(v_biz); -- zella_booking_lock

  begin v_start := nullif(v_args ->> 'start', '')::timestamptz; exception when others then v_start := null; end;
  if v_start is not null and (v_start < now() + make_interval(hours => v_notice) or (v_ahead is not null and v_start > now() + make_interval(days => v_ahead))) then
    return jsonb_build_object('ok', false, 'status', 'unavailable', 'say', 'That time is outside when this business takes bookings. Offer the times from check_availability.');
  end if;
  if v_start is null or v_start <= now() or v_start > now() + interval '1 year' then
    return jsonb_build_object('ok', false, 'status', 'need_info', 'say', 'The time was not clear. Ask the caller to choose one of the offered times.');
  end if;
  v_first := nullif(trim(left(coalesce(v_args ->> 'first_name', ''), 80)), '');
  v_last := nullif(trim(left(coalesce(v_args ->> 'last_name', ''), 80)), '');
  v_phone := nullif(trim(left(coalesce(v_args ->> 'phone', ''), 30)), '');
  v_email := nullif(trim(left(coalesce(v_args ->> 'email', ''), 200)), '');
  v_title := coalesce(nullif(trim(left(coalesce(v_args ->> 'title', ''), 120)), ''), 'Appointment');
  v_notes := nullif(trim(left(coalesce(v_args ->> 'notes', ''), 500)), '');
  v_phone := coalesce(v_phone, v_call_phone);
  if v_first is null then return jsonb_build_object('ok', false, 'status', 'need_info', 'say', 'Ask the caller for their name.'); end if;
  if v_tables and v_party > public.zella_max_party_ai(v_biz) then   -- zella_tables: a large party is the team's to arrange
    v_appt := public.zella_request_appointment(v_biz, null, coalesce(v_phone, v_call_phone), 'Reservation - party of ' || v_party, v_start,
                left(coalesce(v_notes || ' ', '') || 'Party of ' || v_party || '. Name: ' || v_first || coalesce(' ' || v_last, '') || '.', 500));
    update appointments set party_size = v_party, metadata = coalesce(metadata, '{}') || jsonb_build_object('source', 'ai_call') where id = v_appt;
    return jsonb_build_object('ok', true, 'status', 'requested', 'appointment_id', v_appt, 'say',
      'The request for a party of ' || v_party || ' was passed to the team, who will call to confirm. Do not say it is booked.');
  end if;
  if public.zella_digits(v_phone) is null and v_email is null then
    return jsonb_build_object('ok', false, 'status', 'need_info', 'say', 'Ask the caller for a phone number so the business can reach them.');
  end if;
  v_when := public.zella_slot_say(v_start, v_tz, v_window);

  begin
    v_lead := public.zella_capture_lead(v_biz, v_first, v_last, v_phone, v_email, 'phone_call', 'Booked by the phone assistant', null);
    v_cust := (v_lead ->> 'customer_id')::uuid;
  exception when others then
    v_err := sqlerrm;
    if v_err = 'BAD_EMAIL' then return jsonb_build_object('ok', false, 'status', 'need_info', 'say', 'The email address did not look right. Ask the caller to repeat it, or skip it.'); end if;
    v_cust := null;
  end;

  if v_cust is not null then
    select a.id into v_appt from public.appointments a
     where a.business_id = v_biz and a.customer_id = v_cust and a.start_time = v_start and a.status in ('scheduled', 'confirmed') and coalesce(a.booking_state, 'confirmed') = 'confirmed' limit 1;
    if v_appt is not null then return jsonb_build_object('ok', true, 'status', 'booked', 'appointment_id', v_appt, 'say', 'Already booked for ' || v_when || '. Tell the caller they are all set.'); end if;
  end if;

  if v_cust is null or coalesce(v_lead ->> 'result', '') = 'needs_review' then
    v_appt := public.zella_request_appointment(v_biz, v_cust, v_phone, v_title, v_start, v_notes);
    return jsonb_build_object('ok', true, 'status', 'requested', 'appointment_id', v_appt, 'say', 'The request for ' || v_when || ' was passed to the team, who will confirm it. Do not say it is booked.');
  end if;

  begin
    v_appt := public.zella_book_appointment(v_biz, v_cust, v_title, v_start, v_dur, null, v_party, v_notes, coalesce(v_pref, '{}') || jsonb_build_object('source', 'ai_call', 'seating', v_args ->> 'seating'));
    return jsonb_build_object('ok', true, 'status', 'booked', 'appointment_id', v_appt, 'say', 'Booked for ' || v_when || '.' || case when v_window is not null then ' The team arrives within that window.' else '' end || ' Tell the caller they are all set' || case when (public.zella_setting('sms_live', 'false'::jsonb) = 'true'::jsonb or public.zella_setting('email_live', 'false'::jsonb) = 'true'::jsonb) then ' and will get a confirmation message.' else '. Do not promise a text or email confirmation.' end);
  exception when others then
    v_err := sqlerrm;
    if v_err = 'SLOT_TAKEN' or v_err = 'BAD_TIME' then
      select coalesce(jsonb_agg(jsonb_build_object('start', s.slot_start, 'say', public.zella_slot_say(s.slot_start, v_tz, v_window))), '[]'::jsonb)
        into v_slots from public.zella_offer_times(v_tables, v_party, v_biz, greatest(now(), v_start - interval '1 day'), v_start + interval '3 days', v_dur, v_window, v_args ->> 'seating') s;
      return jsonb_build_object('ok', false, 'status', 'unavailable', 'slots', v_slots, 'say', 'That time is not available. Apologise briefly and offer these other times.');
    end if;
    v_appt := public.zella_request_appointment(v_biz, v_cust, v_phone, v_title, v_start, v_notes);
    return jsonb_build_object('ok', true, 'status', 'requested', 'appointment_id', v_appt, 'say', 'The request for ' || v_when || ' was passed to the team, who will confirm it. Do not say it is booked.');
  end;
end $function$;

-- CodeRabbit #18
CREATE OR REPLACE FUNCTION public.zella_flag_unrecorded_appointments()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a record; n integer := 0; v_who text;
begin
  for a in select ap.id, ap.business_id, ap.customer_id, ap.assigned_to, ap.title, ap.end_time from public.appointments ap
            where ap.status in ('scheduled', 'confirmed') and ap.end_time < now() - interval '2 hours' and ap.end_time > now() - interval '7 days'
              and ap.arrived_at is null and ap.checked_in_at is null and ap.in_service_at is null
              and not exists (select 1 from public.crm_tasks t where t.kind = 'record_attendance' and t.entity_id = ap.id)
            order by ap.end_time limit 100 loop
    select coalesce(nullif(trim(coalesce(c.first_name,'') || ' ' || coalesce(c.last_name,'')), ''), a.title, 'a customer') into v_who from public.customers c where c.id = a.customer_id;
    v_who := coalesce(v_who, a.title, 'a customer');
    begin   -- one appointment that can't get its task doesn't stop the others
      perform public.zella_create_task(a.business_id, a.customer_id, 'record_attendance', 'Did ' || v_who || ' come in? Mark completed or no-show', 'The appointment ended and nothing was recorded.', 'normal', now() + interval '1 day', a.assigned_to, 'automation', a.id);
      n := n + 1;
    exception when others then
      raise warning 'zella_flag_unrecorded_appointments: appointment % skipped: %', a.id, sqlerrm;
    end;
  end loop;
  return n;
end $function$;

-- CodeRabbit #23
CREATE OR REPLACE FUNCTION public.zella_rebalance_assignments()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare w record; v_user uuid; v_moved integer := 0;
begin
  for w in
    select 'lead' kind, c.id, c.business_id, c.assigned_to from public.customers c
      join public.business_members m on m.business_id = c.business_id and m.user_id = c.assigned_to
     where c.lead_stage in ('new', 'contacted', 'qualified', 'quote_sent')
       and (m.status <> 'active' or not m.accepts_work or (m.away_until is not null and m.away_until > now()))
    union all
    select 'callback', b.id, b.business_id, b.assigned_to from public.callbacks b
      join public.business_members m on m.business_id = b.business_id and m.user_id = b.assigned_to
     where b.status not in ('completed', 'cancelled')
       and (m.status <> 'active' or not m.accepts_work or (m.away_until is not null and m.away_until > now()))
    limit 200
  loop
    v_user := public.zella_pick_assignee(w.business_id, w.assigned_to);
    if v_user is null then continue; end if;
    if w.kind = 'lead' then update public.customers set assigned_to = v_user, updated_at = now() where id = w.id;
    else update public.callbacks set assigned_to = v_user, updated_at = now() where id = w.id; end if;
    perform public.zella_mark_assigned(w.business_id, v_user);
    perform public.zella_notify(w.business_id, 'work_reassigned', 'Work moved to you', case w.kind when 'lead' then 'A lead was reassigned to you because its owner is away.' else 'A callback was reassigned to you because its owner is away.' end, 'info', case w.kind when 'lead' then 'customers' else 'callbacks' end, w.id, v_user);
    v_moved := v_moved + 1;
  end loop;

  for w in
    select 'lead' kind, c.id, c.business_id from public.customers c left join public.assignment_rules a on a.business_id = c.business_id
     where coalesce(a.mode, 'round_robin') <> 'off' and
      c.assigned_to is null and c.lead_stage in ('new', 'contacted', 'qualified', 'quote_sent')
    union all
    select 'callback', b.id, b.business_id from public.callbacks b left join public.assignment_rules a on a.business_id = b.business_id
     where coalesce(a.mode, 'round_robin') <> 'off' and
      b.assigned_to is null and b.status not in ('completed', 'cancelled')
    limit 200
  loop
    v_user := public.zella_pick_assignee(w.business_id);
    if v_user is null then continue; end if;
    if w.kind = 'lead' then update public.customers set assigned_to = v_user, updated_at = now() where id = w.id;
    else update public.callbacks set assigned_to = v_user, updated_at = now() where id = w.id; end if;
    perform public.zella_mark_assigned(w.business_id, v_user);
    v_moved := v_moved + 1;
  end loop;
  return v_moved;
end $function$;

-- CodeRabbit #31
CREATE OR REPLACE FUNCTION public.zella_save_business_hours(p_business_id uuid, p_hours jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r jsonb; n integer := 0; v_day int; v_open time; v_close time;
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) or auth.uid() is null then raise exception 'NOT_ALLOWED'; end if;
  if jsonb_typeof(p_hours) is distinct from 'array' or jsonb_array_length(p_hours) > 42 then raise exception 'BAD_INPUT'; end if;
  -- Check everything before changing anything.
  for r in select * from jsonb_array_elements(p_hours) loop
    begin
      v_day := (r ->> 'weekday')::int; v_open := (r ->> 'opens')::time; v_close := (r ->> 'closes')::time;
    exception when others then raise exception 'BAD_HOURS';
    end;
    if v_day is null or v_day not between 0 and 6 or v_open is null or v_close is null then raise exception 'BAD_HOURS'; end if;
    if v_close <= v_open then raise exception 'CLOSES_BEFORE_OPENS'; end if;
  end loop;
  if exists (select 1 from jsonb_array_elements(p_hours) with ordinality a(v, i), jsonb_array_elements(p_hours) with ordinality b(v, i)
              where a.i < b.i and (a.v ->> 'weekday')::int = (b.v ->> 'weekday')::int
                and (a.v ->> 'opens')::time < (b.v ->> 'closes')::time and (b.v ->> 'opens')::time < (a.v ->> 'closes')::time) then
    raise exception 'HOURS_OVERLAP';
  end if;

  perform 1 from public.businesses where id = p_business_id for update;   -- one save at a time per business
  delete from public.business_hours where business_id = p_business_id;
  insert into public.business_hours (business_id, weekday, opens, closes)
  select p_business_id, (e ->> 'weekday')::smallint, (e ->> 'opens')::time, (e ->> 'closes')::time from jsonb_array_elements(p_hours) e;
  get diagnostics n = row_count;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (p_business_id, auth.uid(), 'business.hours_updated', 'business', p_business_id, jsonb_build_object('hours', p_hours));
  return n;
end $function$;

-- CodeRabbit #32
CREATE OR REPLACE FUNCTION public.zella_add_business_closure(p_business_id uuid, p_starts_on date, p_ends_on date, p_label text DEFAULT 'Closed'::text, p_opens time without time zone DEFAULT NULL::time without time zone, p_closes time without time zone DEFAULT NULL::time without time zone)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid;
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) or auth.uid() is null then raise exception 'NOT_ALLOWED'; end if;
  if p_starts_on is null or p_ends_on is null or p_ends_on < p_starts_on then raise exception 'BAD_DATES'; end if;
  if p_ends_on < current_date - 1 then raise exception 'IN_THE_PAST'; end if;
  if p_ends_on - p_starts_on > 366 then raise exception 'BAD_DATES'; end if;
  if (p_opens is null) <> (p_closes is null) or (p_opens is not null and p_closes <= p_opens) then raise exception 'BAD_HOURS'; end if;
  insert into public.business_closures (business_id, starts_on, ends_on, label, opens, closes)
  values (p_business_id, p_starts_on, p_ends_on, coalesce(nullif(left(trim(coalesce(p_label, '')), 80), ''), 'Closed'), p_opens, p_closes)
  returning id into v_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (p_business_id, auth.uid(), 'business.closure_added', 'business_closure', v_id,
          jsonb_build_object('starts_on', p_starts_on, 'ends_on', p_ends_on, 'label', coalesce(nullif(left(trim(coalesce(p_label, '')), 80), ''), 'Closed')));
  return v_id;
end $function$;

-- CodeRabbit #33
CREATE OR REPLACE FUNCTION public.zella_finish_calendar_sync(p_queue_id uuid, p_ok boolean, p_event_id text DEFAULT NULL::text, p_error text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare q record;
begin
  select * into q from public.calendar_sync_queue where id = p_queue_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if q.status <> 'in_progress' then return 'ignored'; end if;
  if p_ok then
    update public.calendar_sync_queue set status = 'done', event_id = left(p_event_id, 200), error = null, completed_at = now() where id = q.id;
    update public.appointments set external_event_id = case when q.action = 'delete' then null else coalesce(left(p_event_id, 200), external_event_id) end where id = q.appointment_id;
    update public.calendar_connections set last_pushed_at = now(), last_error = null where business_id = q.business_id and status = 'active';
    return 'done';
  end if;
  if q.attempts < 5 then
    update public.calendar_sync_queue set status = 'pending', due_at = now() + make_interval(mins => 5 * q.attempts), error = left(p_error, 300) where id = q.id;
    return 'retry';
  end if;
  update public.calendar_sync_queue set status = 'failed', error = left(p_error, 300), completed_at = now() where id = q.id;
  update public.calendar_connections set last_error = left(p_error, 300) where business_id = q.business_id and status = 'active';
  if not exists (select 1 from public.staff_notifications where business_id = q.business_id and kind = 'calendar_sync_owner' and created_at > now() - interval '12 hours') then perform public.zella_notify_owners(q.business_id, 'calendar_sync_owner', 'A booking is not on your calendar', 'Zella could not copy a booking to your calendar. The booking itself is saved. Check the calendar connection in Settings.', 'warning', 'settings'); end if;
  perform public.zella_platform_alert('calendar_sync_failed', 'A booking could not be copied to the business calendar', left(p_error, 300), 'warning', q.business_id, q.appointment_id::text);
  return 'failed';
end $function$;

-- CodeRabbit #33
CREATE OR REPLACE FUNCTION public.zella_calendar_connect_provider(p_business_id uuid, p_provider text, p_actor uuid, p_account_email text, p_refresh_token text, p_calendar_id text DEFAULT 'primary'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'vault'
AS $function$
declare v_name text; v_id uuid; o record;
begin
  if p_provider not in ('google', 'outlook') then raise exception 'BAD_PROVIDER'; end if;
  -- the person who started the sign-in must still be allowed when it finishes
  if not exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = p_actor and m.status = 'active' and m.role in ('owner', 'admin'))
     or not exists (select 1 from public.businesses where id = p_business_id and suspended_at is null and cancelled_at is null) then
    raise exception 'NOT_ALLOWED';
  end if;
  if nullif(trim(coalesce(p_refresh_token, '')), '') is null then raise exception 'NO_TOKEN'; end if;
  -- the other provider's calendar, if any, is disconnected and its token deleted
  for o in select * from public.calendar_connections where business_id = p_business_id and provider <> p_provider and status <> 'disconnected' loop
    update public.calendar_connections set status = 'disconnected', busy_refresh_due_at = null, last_error = null where id = o.id;
    if o.vault_secret_name is not null then delete from vault.secrets where name = o.vault_secret_name; end if;
    delete from public.blocked_times where connection_id = o.id and end_time > now();
    -- event ids belong to the old provider's calendar: never send them to the new one (bookings are copied again)
    update public.appointments set external_event_id = null where business_id = p_business_id and external_event_id is not null;
    delete from public.calendar_sync_queue where business_id = p_business_id and status = 'pending';
  end loop;
  v_name := 'zella_cal_' || p_provider || '_' || p_business_id::text;
  if exists (select 1 from vault.secrets where name = v_name) then
    perform vault.update_secret((select id from vault.secrets where name = v_name), p_refresh_token);
  else
    perform vault.create_secret(p_refresh_token, v_name);
  end if;
  insert into public.calendar_connections (business_id, provider, status, calendar_id, account_email, vault_secret_name, busy_refresh_due_at, last_error)
  values (p_business_id, p_provider, 'active', coalesce(nullif(trim(p_calendar_id), ''), 'primary'), left(p_account_email, 200), v_name, now(), null)
  on conflict (business_id, provider) do update set status = 'active', calendar_id = excluded.calendar_id, account_email = excluded.account_email,
    vault_secret_name = excluded.vault_secret_name, busy_refresh_due_at = now(), last_error = null, connected_at = now()
  returning id into v_id;
  insert into public.calendar_sync_queue (business_id, appointment_id, action)
  select business_id, id, 'upsert' from public.appointments
   where business_id = p_business_id and start_time > now()
     and status in ('scheduled', 'confirmed', 'completed')
     and coalesce(booking_state, 'confirmed') not in ('requested', 'tentative')
  on conflict (appointment_id) where status = 'pending' do update set action = 'upsert', due_at = now();
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (p_business_id, p_actor, 'calendar_connected', 'calendar_connection', v_id, jsonb_build_object('provider', p_provider, 'account', left(p_account_email, 200)));
  return v_id;
end $function$;

-- CodeRabbit #34
CREATE OR REPLACE FUNCTION public.zella_queue_calendar_sync()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_action text; v_state text := coalesce(to_jsonb(new) ->> 'booking_state', 'confirmed');
begin
  if not exists (select 1 from public.calendar_connections c where c.business_id = new.business_id and c.status = 'active') then return new; end if;
  if new.status in ('cancelled', 'no_show') or v_state = 'requested' then
    if new.external_event_id is null then   -- never reached the calendar: drop its pending upload
      update public.calendar_sync_queue set status = 'skipped', error = 'cancelled_before_sync', completed_at = now() where appointment_id = new.id and status = 'pending';
      return new;
    end if;
    v_action := 'delete';
  elsif v_state = 'tentative' or new.status not in ('scheduled', 'confirmed', 'completed') then
    return new;
  else
    v_action := 'upsert';
  end if;
  insert into public.calendar_sync_queue (business_id, appointment_id, action) values (new.business_id, new.id, v_action)
  on conflict (appointment_id) where status = 'pending' do update set action = excluded.action, due_at = now();
  return new;
end $function$;

-- CodeRabbit #36
CREATE OR REPLACE FUNCTION public.zella_claim_calendar_sync(p_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'vault'
AS $function$
declare v_res jsonb := '[]'::jsonb; q record; a record; c record; b record; cu record; v_token text;
begin
  if not public.zella_calendar_live() then return v_res; end if;
  -- interrupted claims are retried through n8n marker reconciliation before any calendar create
  update public.calendar_sync_queue set status = 'pending', error = 'interrupted', due_at = now()
   where status = 'in_progress' and attempts < 5 and claimed_at < now() - interval '30 minutes';
  for q in select * from public.calendar_sync_queue where status = 'pending' and due_at <= now()
            order by due_at limit greatest(1, least(coalesce(p_limit, 10), 50)) for update skip locked loop
    select * into c from public.calendar_connections where business_id = q.business_id and status = 'active';
    select * into a from public.appointments where id = q.appointment_id;
    if c.id is null or a.id is null then
      update public.calendar_sync_queue set status = 'skipped', error = 'no_active_connection_or_appointment', completed_at = now() where id = q.id; continue;
    end if;
    select decrypted_secret into v_token from vault.decrypted_secrets where name = c.vault_secret_name limit 1;
    if v_token is null then
      update public.calendar_sync_queue set status = 'failed', error = 'no_token', completed_at = now() where id = q.id;
      update public.calendar_connections set status = 'error', last_error = 'The calendar needs to be connected again.' where id = c.id;
      continue;
    end if;
    select coalesce(timezone, 'America/New_York') as tz, name into b from public.businesses where id = q.business_id;
    select nullif(trim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')), '') as nm, phone into cu from public.customers where id = a.customer_id;
    update public.calendar_sync_queue set status = 'in_progress', attempts = attempts + 1, claimed_at = now() where id = q.id;
    v_res := v_res || jsonb_build_array(jsonb_build_object(
      'queue_id', q.id, 'action', q.action, 'appointment_id', a.id, 'event_id', a.external_event_id, 'attempt', q.attempts + 1,
      'calendar_id', c.calendar_id, 'provider', c.provider, 'refresh_token', v_token,
      'event', jsonb_build_object(
        'summary', left(coalesce(nullif(trim(a.title), ''), 'Appointment') || coalesce(' - ' || cu.nm, ''), 200),
        'description', left('Booked with Zella.' || coalesce(E'\nCustomer: ' || cu.nm, '') || coalesce(E'\nPhone: ' || cu.phone, '') || coalesce(E'\nNotes: ' || a.description, ''), 1000),
        'start', a.start_time, 'end', a.end_time, 'timezone', b.tz)));
  end loop;
  return v_res;
end $function$;

-- CodeRabbit #38
CREATE OR REPLACE FUNCTION public.zella_replace_calendar_busy(p_connection_id uuid, p_events jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c record; e jsonb; n integer := 0; v_s timestamptz; v_e timestamptz;
begin
  select * into c from public.calendar_connections where id = p_connection_id and status = 'active';
  if c.id is null then return 0; end if;
  if jsonb_typeof(p_events) <> 'array' then raise exception 'BAD_EVENTS'; end if;
  -- refused before anything is removed: keeping only the first 500 would drop real busy times
  if jsonb_array_length(p_events) > 500 then raise exception 'TOO_MANY_EVENTS' using hint = 'More than 500 busy times in the window; nothing was changed.'; end if;
  delete from public.blocked_times where connection_id = c.id and source = 'google' and end_time >= now() - interval '1 day';
  for e in select * from jsonb_array_elements(p_events) loop
    begin v_s := (e ->> 'start')::timestamptz; v_e := (e ->> 'end')::timestamptz; exception when others then continue; end;
    if v_s is null or v_e is null or v_e <= v_s or (e ->> 'id') is null then continue; end if;
    if exists (select 1 from public.appointments a where a.business_id = c.business_id and a.external_event_id = e ->> 'id') then continue; end if;
    insert into public.blocked_times (business_id, title, reason, start_time, end_time, all_day, source, external_id, connection_id)
    values (c.business_id, case when c.provider = 'outlook' then 'Busy (Outlook calendar)' else 'Busy (Google Calendar)' end, 'Busy in the business calendar', v_s, v_e, coalesce((e ->> 'all_day')::boolean, false), 'google', left(e ->> 'id', 200), c.id)
    on conflict (connection_id, external_id) where external_id is not null do update set start_time = excluded.start_time, end_time = excluded.end_time, all_day = excluded.all_day;
    n := n + 1;
  end loop;
  update public.calendar_connections set last_pulled_at = now(), busy_refresh_due_at = null, last_error = null where id = c.id;
  return n;
end $function$;

-- CodeRabbit #39
CREATE OR REPLACE FUNCTION public.zella_sensitive_industry(p_business_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((select i.slug in ('dental', 'healthcare', 'pet-care-veterinary', 'legal', 'financial-services', 'insurance', 'childcare')
                     from public.businesses b join public.industries i on i.id = b.industry_id where b.id = p_business_id
                      and (auth.uid() is null or public.zella_is_member(p_business_id) or public.is_platform_admin())), false);
$function$;

-- CodeRabbit #42
CREATE OR REPLACE FUNCTION public.zella_today_operations(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tz text; v_start timestamptz; v_end timestamptz;
begin
  if auth.uid() is not null and not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select coalesce(nullif(timezone, ''), 'UTC') into v_tz from public.businesses where id = p_business_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  v_start := (date_trunc('day', now() at time zone v_tz)) at time zone v_tz;
  v_end := (date_trunc('day', now() at time zone v_tz) + interval '1 day') at time zone v_tz;   -- 23 or 25 hours on DST days
  return coalesce((
    select jsonb_agg(jsonb_build_object('key', t.key, 'plural', t.plural, 'icon', t.icon, 'open', coalesce(c.open, 0),
             'overdue', coalesce(c.overdue, 0), 'due_today', coalesce(c.due_today, 0), 'unassigned', coalesce(c.unassigned, 0)) order by t.position, t.key)
      from public.crm_record_types t
      left join lateral (
        select count(*) as open,
               count(*) filter (where r.due_at < now()) as overdue,
               count(*) filter (where r.due_at >= v_start and r.due_at < v_end) as due_today,
               count(*) filter (where r.assigned_to is null) as unassigned
          from public.crm_records r
         where r.business_id = p_business_id and r.type_key = t.key and r.archived_at is null and r.closed_at is null
           and not (r.status = any (coalesce(t.closed_statuses, '{}'::text[])))
      ) c on true
     where t.business_id = p_business_id and t.enabled and (t.capability is null or public.zella_capability_on(p_business_id, t.capability))), '[]'::jsonb);
end $function$;

-- CodeRabbit #47
CREATE OR REPLACE FUNCTION public.zella_merge_customers(p_business_id uuid, p_keep uuid, p_drop uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare k public.customers; d public.customers; t record; v_moved integer := 0; v_skipped text[] := '{}'; v_n integer;
begin
  if not public.zella_has_role(p_business_id, array['owner', 'admin', 'manager']) then raise exception 'NOT_ALLOWED'; end if;
  if p_keep = p_drop then raise exception 'SAME_CUSTOMER'; end if;
  select * into k from public.customers where id = p_keep and business_id = p_business_id for update;
  select * into d from public.customers where id = p_drop and business_id = p_business_id for update;
  if k.id is null or d.id is null then raise exception 'NOT_FOUND'; end if;
  if k.status = 'archived' then raise exception 'KEEP_ARCHIVED'; end if;
  perform public.zella_people_merge(p_business_id, p_keep, p_drop); /* zella_relationships_merge */
  for t in select distinct c1.table_name from information_schema.columns c1 join information_schema.columns c2 on c2.table_schema = 'public' and c2.table_name = c1.table_name and c2.column_name = 'business_id'
            join information_schema.tables tb on tb.table_schema = 'public' and tb.table_name = c1.table_name and tb.table_type = 'BASE TABLE'
            where c1.table_schema = 'public' and c1.column_name = 'customer_id' and c1.table_name not in ('duplicate_reviews', 'email_unsubscribe_tokens', 'contact_consents', 'data_rights_requests', 'customer_relationships') loop
    begin
      execute format('update public.%I set customer_id = $1 where customer_id = $2 and business_id = $3', t.table_name) using p_keep, p_drop, p_business_id;
      get diagnostics v_n = row_count; v_moved := v_moved + v_n;
    exception when others then v_skipped := v_skipped || t.table_name;
    end;
  end loop;
  update public.customers set
      first_name = coalesce(first_name, d.first_name), last_name = coalesce(last_name, d.last_name), phone = coalesce(phone, d.phone), email = coalesce(email, d.email),
      company_name = coalesce(company_name, d.company_name), date_of_birth = coalesce(date_of_birth, d.date_of_birth), address = coalesce(address, d.address),
      do_not_contact = coalesce(do_not_contact, false) or coalesce(d.do_not_contact, false), do_not_sms = coalesce(do_not_sms, false) or coalesce(d.do_not_sms, false),
      do_not_email = coalesce(do_not_email, false) or coalesce(d.do_not_email, false), do_not_call = coalesce(do_not_call, false) or coalesce(d.do_not_call, false),
      notes = case when nullif(d.notes, '') is null then notes else coalesce(notes || E'\n', '') || d.notes end,
      last_contacted_at = greatest(last_contacted_at, d.last_contacted_at), updated_at = now()
   where id = p_keep;
  -- the duplicate's consent history (opt-outs included) now belongs to the kept customer; order and evidence unchanged
  update public.contact_consents set customer_id = p_keep, evidence = coalesce(evidence, '{}'::jsonb) || jsonb_build_object('merged_from', p_drop)
   where business_id = p_business_id and customer_id = p_drop;
  update public.customers set status = 'archived', phone = null, email = null, notes = null, metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('merged_into', p_keep, 'merged_at', now()), updated_at = now() where id = p_drop;
  update public.duplicate_reviews set status = 'merged', resolved_by = auth.uid(), resolved_at = now()
   where business_id = p_business_id and status = 'open' and (customer_id in (p_keep, p_drop) and (incoming ->> 'duplicate_customer_id') in (p_keep::text, p_drop::text));
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (p_business_id, auth.uid(), 'customer.merged', 'customer', p_keep, jsonb_build_object('merged_from', p_drop, 'rows_moved', v_moved, 'tables_skipped', to_jsonb(v_skipped)));
  return jsonb_build_object('kept', p_keep, 'archived', p_drop, 'rows_moved', v_moved, 'tables_skipped', to_jsonb(v_skipped));
end $function$;

-- CodeRabbit #50
CREATE OR REPLACE FUNCTION public.zella_log_customer_request(p_business_id uuid, p_customer_id uuid, p_kind text, p_summary text, p_source text DEFAULT 'staff'::text, p_call_id uuid DEFAULT NULL::uuid, p_priority text DEFAULT 'normal'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_summary text := left(regexp_replace(trim(coalesce(p_summary, '')), '\s+', ' ', 'g'), 1000); v_id uuid; v_user uuid; v_due timestamptz; v_status text; u record;
begin
  if p_kind not in ('complaint', 'correction', 'data_access', 'data_deletion') then raise exception 'INVALID_KIND'; end if;
  if length(v_summary) < 3 then raise exception 'EMPTY_SUMMARY'; end if;
  if not exists (select 1 from public.businesses where id = p_business_id and suspended_at is null and cancelled_at is null) then raise exception 'BUSINESS_NOT_AVAILABLE'; end if;
  if p_customer_id is not null and not exists (select 1 from public.customers where id = p_customer_id and business_id = p_business_id) then p_customer_id := null; end if;
  select id into v_id from public.customer_requests
   where business_id = p_business_id and kind = p_kind and status in ('open', 'in_progress', 'waiting_verification')
     and ((p_customer_id is not null and customer_id = p_customer_id) or (p_customer_id is null and p_call_id is not null and call_id = p_call_id))
     and created_at > now() - interval '24 hours' limit 1;
  if v_id is not null then return v_id; end if;

  v_due := now() + case p_kind when 'complaint' then case when p_priority = 'urgent' then interval '4 hours' else interval '24 hours' end
                                when 'correction' then interval '3 days' else interval '30 days' end;
  v_status := case when p_kind in ('data_access', 'data_deletion') then 'waiting_verification' else 'open' end;
  if p_kind in ('data_access', 'data_deletion') then
    select user_id into v_user from public.business_members where business_id = p_business_id and status = 'active' and role in ('owner', 'admin') order by created_at limit 1;
  else
    v_user := public.zella_pick_assignee(p_business_id);
    if v_user is not null then perform public.zella_mark_assigned(p_business_id, v_user); end if;
  end if;
  insert into public.customer_requests (business_id, customer_id, call_id, kind, summary, source, status, priority, assigned_to, due_at)
  values (p_business_id, p_customer_id, p_call_id, p_kind, v_summary, case when p_source in ('phone', 'web', 'email', 'sms', 'staff') then p_source else 'staff' end,
          v_status, case when p_priority in ('normal', 'high', 'urgent') then p_priority else 'normal' end, v_user, v_due) returning id into v_id;

  if p_kind in ('data_access', 'data_deletion') or v_user is null then
    for u in select user_id from public.business_members where business_id = p_business_id and status = 'active' and role in ('owner', 'admin') loop
      perform public.zella_notify(p_business_id, 'customer_request', case p_kind when 'complaint' then 'New complaint' when 'correction' then 'Data correction request' when 'data_access' then 'Privacy request: access to data' else 'Privacy request: deletion' end,
        left(v_summary, 200), case when p_kind = 'complaint' then 'warning' else 'info' end, 'customers', v_id, u.user_id);
    end loop;
  else
    perform public.zella_notify(p_business_id, 'customer_request', case p_kind when 'complaint' then 'New complaint for you' else 'Data correction request for you' end,
      left(v_summary, 200), case when p_kind = 'complaint' then 'warning' else 'info' end, 'customers', v_id, v_user);
  end if;
  return v_id;
end $function$;

-- CodeRabbit #51
CREATE OR REPLACE FUNCTION public.zella_update_customer_request(p_id uuid, p_status text, p_note text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record;
begin
  select * into r from public.customer_requests where id = p_id;
  if not found or not public.zella_can_edit(r.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_status not in ('open', 'in_progress', 'waiting_verification', 'resolved', 'rejected') then raise exception 'INVALID_STATUS'; end if;
  if p_status in ('resolved', 'rejected') and nullif(trim(coalesce(p_note, '')), '') is null then raise exception 'NOTE_REQUIRED'; end if;
  if r.kind in ('data_access', 'data_deletion') and (p_status in ('resolved', 'rejected') or r.status in ('resolved', 'rejected')) and not exists (select 1 from public.business_members where business_id = r.business_id and user_id = auth.uid() and status = 'active' and role in ('owner', 'admin')) then raise exception 'NOT_ALLOWED'; end if;
  update public.customer_requests set status = p_status, resolution_note = case when p_status in ('resolved', 'rejected') then left(p_note, 1000) else resolution_note end,
         resolved_at = case when p_status in ('resolved', 'rejected') then now() else null end, updated_at = now() where id = p_id;
  return true;
end $function$;

-- CodeRabbit #52
CREATE OR REPLACE FUNCTION public.zella_record_status_touches_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a record; v_line text;
begin
  if new.status is distinct from old.status and new.customer_id is not null then
    for a in select * from public.automations x
              where x.business_id = new.business_id and x.trigger_type = 'record_status_update' and x.status = 'active'
                and (x.trigger_config ->> 'type_key' is null or x.trigger_config ->> 'type_key' = new.type_key)
                and nullif(trim(x.trigger_config -> 'messages' ->> new.status), '') is not null
              order by (x.trigger_config ->> 'type_key') is null, x.created_at, x.id limit 1 loop   -- one message per change
      v_line := left(nullif(trim(a.trigger_config -> 'messages' ->> new.status), ''), 300);
      if v_line is not null then
        perform public.zella_queue_customer_message(new.business_id, new.customer_id, 'record_status_update',
          jsonb_build_object('status_line', v_line, 'status', new.status, 'record_title', new.title), interval '1 minute', null, interval '0');
      end if;
    end loop;
    if new.status = 'completed' and new.type_key in ('jobs', 'work_orders') and not exists (
         select 1 from public.automations x where x.business_id = new.business_id and x.trigger_type = 'record_status_update' and x.status = 'active'
            and nullif(trim(x.trigger_config -> 'messages' ->> 'completed'), '') is not null) then
      perform public.zella_queue_customer_message(new.business_id, new.customer_id, 'service_completed', jsonb_build_object('record_title', new.title), interval '5 minutes', null, interval '1 day');
    end if;
  end if;
  return new;
exception when others then
  return new;
end $function$;

-- CodeRabbit #53
CREATE OR REPLACE FUNCTION public.zella_queue_customer_touches(p_limit integer DEFAULT 50)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a record; c record; n integer := 0; v_days integer;
begin
  for a in select * from public.automations x where x.trigger_type = 'service_due' and x.status = 'active' loop
    v_days := greatest(7, case when (a.trigger_config ->> 'days') ~ '^\d{1,4}$' then (a.trigger_config ->> 'days')::integer else 180 end);
    for c in select x.id from public.customers x
              where x.business_id = a.business_id and not coalesce(x.do_not_contact, false)
                and exists (select 1 from public.appointments p where p.customer_id = x.id and p.status = 'completed' and p.start_time < now() - make_interval(days => v_days))
                and not exists (select 1 from public.appointments p where p.customer_id = x.id and p.status not in ('cancelled','no_show') and p.start_time > now() - make_interval(days => v_days))
              limit greatest(1, least(coalesce(p_limit, 50), 200)) loop
      if public.zella_queue_customer_message(a.business_id, c.id, 'service_due',
           jsonb_build_object('service', coalesce(nullif(a.trigger_config ->> 'service', ''), 'visit')), interval '0', null, make_interval(days => v_days)) is not null then
        n := n + 1;
      end if;
    end loop;
  end loop;
  for c in select x.id, x.business_id from public.customers x
            where x.lead_stage = 'new' and coalesce(x.last_contacted_at, x.created_at) < now() - interval '3 days'
              and coalesce(x.last_contacted_at, x.created_at) > now() - interval '14 days'
              and not coalesce(x.do_not_contact, false)
              and exists (select 1 from public.followup_tasks f where f.customer_id = x.id and f.status = 'done' and f.created_at > now() - interval '14 days')
            limit greatest(1, least(coalesce(p_limit, 50), 200)) loop
    if public.zella_queue_customer_message(c.business_id, c.id, 'no_response_follow_up', '{}'::jsonb, interval '0', null, interval '14 days') is not null then
      n := n + 1;
    end if;
  end loop;
  -- lead sequence: day 1 for a lead nobody has reached, day 7 as the last note
  for c in select x.id, x.business_id, case when x.created_at < now() - interval '7 days' then 'lead_final_follow_up' else 'lead_follow_up' end as kind
             from public.customers x
            where x.lead_stage in ('new', 'contacted') and not coalesce(x.do_not_contact, false)
              and x.created_at < now() - interval '1 day' and x.created_at > now() - interval '14 days'
              and coalesce(x.last_contacted_at, x.created_at) < now() - interval '1 day'
              and coalesce(lower(x.source), '') not in ('import', 'csv', 'migration')
              and not exists (select 1 from public.appointments p where p.customer_id = x.id and p.status <> 'cancelled')
            limit greatest(1, least(coalesce(p_limit, 50), 200)) loop
    if public.zella_queue_customer_message(c.business_id, c.id, c.kind, '{}'::jsonb, interval '0', null, interval '14 days') is not null then
      n := n + 1;
    end if;
  end loop;
  return n;
end $function$;

-- CodeRabbit #62
CREATE OR REPLACE FUNCTION public.zella_check_engine_health()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_freed integer := 0; n integer; q record; v_backlog jsonb := '{}'::jsonb;
begin
  for q in select id from public.automation_events
    where status = 'processing' and attempts >= 5 and claimed_at < now() - interval '10 minutes'
    for update skip locked loop
    perform public.zella_complete_event(q.id, false, 'provider_timeout', 'Execution interrupted at final attempt');
  end loop;
  update public.followup_tasks set status = 'failed', outcome = 'failed', outcome_notes = 'Stopped after the last attempt never finished.', completed_at = now(), updated_at = now()
   where status = 'in_progress' and channel in ('sms', 'email') and claimed_at < now() - interval '30 minutes' and attempts >= max_attempts;
  update public.followup_tasks set status = 'pending', due_at = now(), updated_at = now()
   where status = 'in_progress' and channel in ('sms', 'email') and claimed_at < now() - interval '30 minutes' and attempts < max_attempts;
  get diagnostics n = row_count; v_freed := v_freed + n;
  update public.appointment_reminders set status = 'pending'
   where status = 'sending' and due_at < now() - interval '60 minutes';
  get diagnostics n = row_count; v_freed := v_freed + n;
  update public.staff_notifications set delivery_status = 'pending'
   where delivery_status = 'sending' and claimed_at < now() - interval '30 minutes';
  get diagnostics n = row_count; v_freed := v_freed + n;
  if v_freed > 0 then
    perform public.zella_platform_alert('engine_stuck_work', 'Stuck work was put back in the queue',
      v_freed || ' item(s) were picked up but never finished, so they were put back to be tried again.', 'info', null, 'stuck', jsonb_build_object('freed', v_freed));
  end if;

  for q in select id from public.calendar_sync_queue where status = 'in_progress' and attempts >= 5
    and claimed_at < now() - interval '30 minutes' for update skip locked loop
    perform public.zella_finish_calendar_sync(q.id, false, null, 'interrupted');
  end loop;
  update public.calendar_sync_queue set status = 'pending', error = 'interrupted', due_at = now()
    where status = 'in_progress' and attempts < 5 and claimed_at < now() - interval '30 minutes';
  for q in
    select * from (values
      ('reminders', 'Appointment reminders are waiting', (select count(*) from public.appointment_reminders where status = 'pending' and due_at < now() - interval '30 minutes')),
      ('followups', 'Follow-ups are waiting', (select count(*) from public.followup_tasks where status = 'pending' and channel in ('sms', 'email') and due_at < now() - interval '60 minutes')),
      ('events', 'Events are waiting to be processed', (select count(*) from public.automation_events where status = 'received' and received_at < now() - interval '15 minutes')),
      ('notifications', 'Owner notifications are waiting', (select count(*) from public.staff_notifications where delivery_status = 'pending' and created_at < now() - interval '60 minutes'))
    ) as t(queue, title, waiting)
  loop
    v_backlog := v_backlog || jsonb_build_object(q.queue, q.waiting);
    if q.waiting > 0 then
      perform public.zella_platform_alert('queue_backlog', q.title,
        q.waiting || ' item(s) have waited too long. The automation engine may be switched off, or a provider may be down.', 'warning', null, q.queue,
        jsonb_build_object('waiting', q.waiting));
    else
      perform public.zella_resolve_platform_alerts('queue_backlog', null, q.queue, 'Queue is empty again');
    end if;
  end loop;

  return jsonb_build_object('freed', v_freed, 'waiting', v_backlog);
end $function$;

-- CodeRabbit #64
CREATE OR REPLACE FUNCTION public.zella_ai_voice(p_provider_call_id text, p_business_id uuid, p_action text, p_args jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_args jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  v_call public.calls%rowtype; v_biz uuid; v_tz text; v_name text;
  v_rules jsonb; v_open jsonb; v_is_open boolean; v_mode text;
  v_transfer_on boolean; v_hours_only boolean; v_number text; v_fallback text;
  v_em_on boolean; v_keywords text[];
  v_msg text; v_cname text; v_cphone text; v_cust uuid; v_mid uuid; v_why text; v_next text;
begin
  if nullif(p_provider_call_id, '') is not null then
    select * into v_call from public.calls c where c.external_call_id = p_provider_call_id limit 1;
  end if;
  v_biz := coalesce(v_call.business_id, p_business_id);
  select b.id, coalesce(b.timezone, 'America/New_York'), b.name into v_biz, v_tz, v_name from public.businesses b
   where b.id = v_biz and b.suspended_at is null and b.cancelled_at is null and coalesce(b.is_active, true);
  if v_biz is null then raise exception 'UNKNOWN_BUSINESS'; end if;

  if v_call.id is null and nullif(p_provider_call_id, '') is not null then
    insert into public.calls (business_id, direction, status, from_number, external_call_id, started_at, ai_handled)
    values (v_biz, 'inbound', 'answered', nullif(left(coalesce(v_args ->> 'caller_number', ''), 30), ''), p_provider_call_id, now(), true)
    on conflict (external_call_id) where external_call_id is not null do nothing; -- zella_one_call_row
    select * into v_call from public.calls c where c.external_call_id = p_provider_call_id limit 1;
  end if;

  select coalesce(cfg.escalation_rules, '{}'::jsonb) into v_rules
    from public.ai_agents ag join public.ai_agent_configs cfg on cfg.agent_id = ag.id
   where ag.business_id = v_biz and ag.is_default limit 1;
  v_rules := coalesce(v_rules, '{}'::jsonb);
  v_mode := coalesce(nullif(v_rules ->> 'after_hours_mode', ''), 'take_message');
  if v_mode not in ('take_message', 'book_only', 'info_only') then v_mode := 'take_message'; end if;
  v_transfer_on := coalesce((v_rules ->> 'transfer_enabled')::boolean, true);
  v_hours_only := coalesce((v_rules ->> 'transfer_open_hours_only')::boolean, true);
  v_number := coalesce(nullif(v_rules ->> 'transfer_number', ''), nullif(v_rules #>> '{transfer_to,phone}', ''));
  v_fallback := nullif(v_rules ->> 'fallback_number', '');
  if coalesce(v_rules ->> 'transfer_route', '') = 'fallback' and v_fallback is not null then v_number := v_fallback; end if;
  v_em_on := coalesce((v_rules ->> 'emergency_enabled')::boolean, case when jsonb_typeof(v_rules -> 'triggers') = 'array' then v_rules -> 'triggers' ? 'emergency' else false end);
  select coalesce(array_agg(lower(trim(k))) filter (where length(trim(k)) between 2 and 40), array[]::text[]) into v_keywords
    from jsonb_array_elements_text(case when jsonb_typeof(v_rules -> 'emergency_keywords') = 'array' then v_rules -> 'emergency_keywords' else '[]'::jsonb end) k;

  v_open := public.zella_business_open(v_biz);
  v_is_open := coalesce((v_open ->> 'open')::boolean, true);
  if not v_is_open then -- zella_on_call: whoever is on call takes after-hours transfers
    declare v_oc jsonb;
    begin
      v_oc := public.zella_on_call_now(v_biz);
      if v_oc ->> 'phone' is not null then
        v_number := v_oc ->> 'phone';
        if v_oc ->> 'scope' = 'after_hours' then v_hours_only := false; end if;
      end if;
    exception when others then null;
    end;
  end if;
  v_next := case when v_open ->> 'next_open' is not null then to_char((v_open ->> 'next_open')::timestamptz at time zone v_tz, 'FMDay "at" FMHH12:MI AM') end;

  -- zella_spam_voice_guard: screened callers can't be transferred or leave a callback (emergencies always allowed)
  if p_action in ('transfer', 'message') then
    declare v_scr jsonb; v_cfg jsonb;
    begin
      v_scr := public.zella_caller_context(v_biz, coalesce(nullif(v_args ->> 'caller_number', ''), v_call.from_number)) -> 'screening';
      if v_scr ->> 'decision' in ('blocked', 'restricted', 'screened') then
        v_cfg := public.zella_spam_config(v_biz);
        if not (p_action = 'message' and v_scr ->> 'decision' <> 'blocked' and v_cfg ->> 'ai_spam_handling' = 'take_message') then
          return jsonb_build_object('ok', false, 'status', 'screened',
            'say', 'Spam protection: this caller is not accepted for this. Do not transfer, book or take details. Politely say the business can''t help with this call and end it.');
        end if;
      end if;
    exception when others then
      null;
    end;
  end if;

  if p_action = 'rules' then
    return jsonb_build_object('ok', true, 'status', case when v_is_open then 'open' else v_open ->> 'reason' end,
      'open', v_is_open, 'after_hours_mode', v_mode, 'can_transfer', (v_transfer_on and v_number is not null and (v_is_open or not v_hours_only)),
      'emergency_keywords', to_jsonb(v_keywords),
      'caller', public.zella_caller_context(v_biz, coalesce(nullif(v_args ->> 'caller_number', ''), v_call.from_number)),
      'say', case
        when v_is_open then coalesce(v_name, 'The business') || ' is open now.'
        when v_open ->> 'reason' = 'holiday' then coalesce(v_name, 'The business') || ' is closed today (' || coalesce(v_open ->> 'label', 'holiday') || ').' || coalesce(' They open again ' || v_next || '.', '')
        else coalesce(v_name, 'The business') || ' is closed right now.' || coalesce(' They open again ' || v_next || '.', '') end
        || case when v_is_open then ''
             when v_mode = 'take_message' then ' Offer to take a message and call_rules with action "message". If the caller wants an appointment, you can still book one for a time when the business is open.'
             when v_mode = 'book_only' then ' You can book an appointment, but do not promise a person right now.'
             else ' Give general information only and say the team will be back at opening time.' end
        || case when v_em_on and cardinality(v_keywords) > 0 then ' If the caller describes an emergency, use action "emergency" straight away.' else '' end);
  end if;

  if p_action = 'message' then
    v_msg := nullif(trim(regexp_replace(left(coalesce(v_args ->> 'message', ''), 1500), '\s+', ' ', 'g')), '');
    if v_msg is null or length(v_msg) < 3 then
      return jsonb_build_object('ok', false, 'status', 'need_info', 'say', 'Ask the caller what the message is.');
    end if;
    v_cname := nullif(trim(left(coalesce(v_args ->> 'name', ''), 80)), '');
    v_cphone := coalesce(nullif(trim(left(coalesce(v_args ->> 'phone', ''), 30)), ''), v_call.from_number);
    if public.zella_digits(v_cphone) is null then
      return jsonb_build_object('ok', false, 'status', 'need_info', 'say', 'Ask the caller for a phone number so the team can call back.');
    end if;
    begin
      select m.customer_id into v_cust from public.zella_match_customer(v_biz, v_cphone, null) m where m.certainty = 'exact' limit 1;
    exception when others then v_cust := null; end;
    insert into public.call_messages (business_id, call_id, customer_id, kind, caller_name, caller_phone, message, after_hours)
    values (v_biz, v_call.id, v_cust, 'message', v_cname, v_cphone, v_msg, not v_is_open) returning id into v_mid;
    perform public.zella_create_callback(v_biz, v_cphone, case when v_is_open then 'requested' else 'after_hours' end, 'normal',
      left(coalesce(v_cname || ': ', '') || v_msg, 500), null, v_cust, v_call.id, null, 'phone_assistant', null);
    return jsonb_build_object('ok', true, 'status', 'message_saved', 'message_id', v_mid,
      'say', 'The message was saved and the team will call back' || coalesce(case when not v_is_open then ' when they open ' || v_next end, '') || '. Thank the caller.');
  end if;

  if p_action = 'emergency' then
    if not v_em_on then
      return jsonb_build_object('ok', true, 'status', 'not_enabled', 'say', 'Emergency handling is not set up. Take a message instead and say the team will be told.');
    end if;
    v_msg := coalesce(nullif(trim(regexp_replace(left(coalesce(v_args ->> 'summary', ''), 800), '\s+', ' ', 'g')), ''), 'Caller reported an emergency.');
    v_cname := nullif(trim(left(coalesce(v_args ->> 'name', ''), 80)), '');
    v_cphone := coalesce(nullif(trim(left(coalesce(v_args ->> 'phone', ''), 30)), ''), v_call.from_number);
    begin
      select m.customer_id into v_cust from public.zella_match_customer(v_biz, v_cphone, null) m where m.certainty = 'exact' limit 1;
    exception when others then v_cust := null; end;
    insert into public.call_messages (business_id, call_id, customer_id, kind, caller_name, caller_phone, message, after_hours)
    values (v_biz, v_call.id, v_cust, 'emergency', v_cname, v_cphone, v_msg, not v_is_open) returning id into v_mid;
    if v_call.id is not null then
      update public.calls set needs_human = true, escalation_reason = 'emergency', escalated_at = coalesce(escalated_at, now()), updated_at = now() where id = v_call.id;
    end if;
    perform public.zella_notify_owners(v_biz, 'emergency_call', 'Emergency call', left(coalesce(v_cname, 'A caller') || ': ' || v_msg, 300), 'urgent', 'calls');
    if public.zella_digits(v_cphone) is not null then
      perform public.zella_create_callback(v_biz, v_cphone, 'needs_human', 'urgent', left('EMERGENCY - ' || v_msg, 500), null, v_cust, v_call.id, null, 'phone_assistant', null);
    end if;
    if v_transfer_on and v_number is not null then
      if v_call.id is not null then update public.calls set transfer_status = 'attempted', transfer_approved_at = now() where id = v_call.id; end if;
      return jsonb_build_object('ok', true, 'status', 'transfer', 'transfer_number', v_number,
        'say', 'The owners have been alerted. Tell the caller you are connecting them to a person now, then use the transfer tool (the system chooses the number). Stay calm and short.');
    end if;
    return jsonb_build_object('ok', true, 'status', 'alerted',
      'say', 'The owners have been alerted and will call back as soon as possible. Tell the caller that, and if anyone is in danger tell them to hang up and call emergency services.');
  end if;

  if p_action = 'transfer' then
    v_why := nullif(trim(left(coalesce(v_args ->> 'reason', ''), 300)), '');
    -- an emergency is reported with report_emergency (it alerts the owners and marks the call); the assistant can't claim one here
    if lower(v_why) = 'emergency' and (v_call.id is null or not exists (select 1 from public.calls where id = v_call.id and escalation_reason = 'emergency')) then
      return jsonb_build_object('ok', true, 'status', 'use_emergency',
        'say', 'If this is an emergency, use the emergency action first. Otherwise ask why they need a person and try again with that reason.');
    end if;
    /* zella_escalation_rules: only for a reason the business ticked (when it saved its triggers) */
    if public.zella_escalation_triggers(v_biz) is not null
       and not ((case when v_why = any (public.zella_escalation_trigger_keys()) then v_why else 'customer_requests_human' end) = any (public.zella_escalation_triggers(v_biz))) then
      if v_call.id is not null then
        update public.calls set transfer_status = 'not_needed', escalation_reason = coalesce(escalation_reason, left(coalesce(v_why, 'asked_for_person'), 60)), updated_at = now()
         where id = v_call.id and transfer_status is distinct from 'attempted';   -- an approved transfer stays approved
      end if;
      return jsonb_build_object('ok', true, 'status', 'not_for_this',
        'say', 'This business does not pass calls to a person for this. Offer to take a message or arrange a callback instead.');
    end if;
    if v_transfer_on and v_number is not null and (v_is_open or not v_hours_only) then
      if v_call.id is not null then
        update public.calls set transfer_status = 'attempted', transfer_approved_at = now(), needs_human = true, escalation_reason = coalesce(escalation_reason, case when v_why = any (public.zella_escalation_trigger_keys()) then v_why else 'asked_for_person' end), escalated_at = coalesce(escalated_at, now()), updated_at = now() where id = v_call.id;
      end if;
      return jsonb_build_object('ok', true, 'status', 'transfer', 'transfer_number', v_number,
        'say', 'Tell the caller you are connecting them to a person, then use the transfer tool. Do not say a number; the system chooses it.'); -- zella_server_transfer
    end if;
    if v_call.id is not null then update public.calls set transfer_status = 'no_one_available', needs_human = true, updated_at = now() where id = v_call.id; end if;
    v_cphone := coalesce(nullif(trim(left(coalesce(v_args ->> 'phone', ''), 30)), ''), v_call.from_number);
    if public.zella_digits(v_cphone) is not null then
      perform public.zella_create_callback(v_biz, v_cphone, 'needs_human', 'high', left(coalesce(v_why, 'Caller asked for a person.'), 500), null, null, v_call.id, null, 'phone_assistant', null);
    end if;
    return jsonb_build_object('ok', true, 'status', 'no_one_available',
      'say', 'Nobody can take the call right now. Say sorry, tell the caller the team will call back' || coalesce(case when not v_is_open then ' when they open ' || v_next end, '') || ', and offer to take a message.');
  end if;

  raise exception 'BAD_ACTION';
end $function$;

-- CodeRabbit #65
CREATE OR REPLACE FUNCTION public.zella_complete_followup_task(p_task_id uuid, p_outcome text, p_notes text DEFAULT NULL::text, p_provider_call_id text DEFAULT NULL::text, p_call_id uuid DEFAULT NULL::uuid, p_retry_in_minutes integer DEFAULT 120)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_task record; v_tz text; v_status text;
begin
  select * into v_task from public.followup_tasks where id = p_task_id for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  if v_task.status in ('done', 'failed', 'cancelled', 'skipped') then return v_task.status; end if;   -- already finished: a late duplicate report
  if p_call_id is not null and not exists (select 1 from public.calls where id = p_call_id and business_id = v_task.business_id) then raise exception 'TENANT_MISMATCH'; end if;
  if p_outcome not in ('rescheduled', 'wants_callback', 'declined', 'no_answer', 'voicemail', 'sms_sent', 'email_sent', 'failed') then
    raise exception 'BAD_OUTCOME';
  end if;

  if p_outcome in ('no_answer', 'voicemail', 'failed') and v_task.attempts < v_task.max_attempts then
    select coalesce(b.timezone, 'America/New_York') into v_tz from public.businesses b where b.id = v_task.business_id;
    update public.followup_tasks
       set status = 'pending', outcome = p_outcome, outcome_notes = p_notes,
           provider_call_id = coalesce(p_provider_call_id, provider_call_id),
           call_id = coalesce(p_call_id, call_id),
           due_at = public.zella_next_call_time(now() + make_interval(mins => greatest(5, coalesce(p_retry_in_minutes, 120))), v_tz),
           updated_at = now()
     where id = p_task_id;
    return 'retry_scheduled';
  end if;

  v_status := case when p_outcome = 'failed' then 'failed' else 'done' end;
  update public.followup_tasks
     set status = v_status, outcome = p_outcome, outcome_notes = p_notes,
         provider_call_id = coalesce(p_provider_call_id, provider_call_id),
         call_id = coalesce(p_call_id, call_id),
         completed_at = now(), updated_at = now()
   where id = p_task_id;

  if p_outcome = 'wants_callback' and coalesce(p_call_id, v_task.call_id) is not null then
    update public.calls
       set needs_human = true,
           escalation_reason = coalesce(nullif(p_notes, ''), 'Asked for a call back after a missed appointment'),
           escalated_at = now(), escalation_resolved_at = null, updated_at = now()
     where id = coalesce(p_call_id, v_task.call_id) and business_id = v_task.business_id;
  end if;
  return v_status;
end $function$;

-- CodeRabbit #67
CREATE OR REPLACE FUNCTION public.zella_claim_reminders(p_limit integer DEFAULT 25, p_channel text DEFAULT 'sms'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_res jsonb := '[]'::jsonb; r record; a record; c record; b record; v_staff text;
        v_channel text := case when p_channel = 'email' then 'email' else 'sms' end;
        v_phone_ok boolean; v_email_ok boolean;
begin
  for r in select * from public.appointment_reminders where status = 'pending' and due_at <= now() and channel = v_channel order by due_at
           limit greatest(1, least(coalesce(p_limit, 25), 100)) for update skip locked loop
    select * into a from public.appointments where id = r.appointment_id;
    select * into c from public.customers where id = r.customer_id;
    select id, name, coalesce(timezone, 'America/New_York') as tz, suspended_at, cancelled_at into b from public.businesses where id = r.business_id;
    if a.id is null or a.status not in ('scheduled', 'confirmed') or coalesce(a.booking_state, 'confirmed') <> 'confirmed' or (r.kind in ('reminder', 'confirmation_request') and a.start_time <= now()) then
      update public.appointment_reminders set status = 'skipped', error = 'appointment_no_longer_active' where id = r.id; continue;
    end if;
    /* zella_channel_review: held while the owner chooses how it is sent */
    if public.zella_channel_on_hold(r.business_id, case when r.kind = 'reminder' then 'appointment_reminder' else 'appointment_confirmation' end) then
      update public.appointment_reminders set status = 'skipped', error = 'channel_needs_review' where id = r.id; continue;
    end if;
    /* zella_message_settings_fix: the automation that queued it must still be on */
    if not exists (select 1 from public.automations x where x.business_id = r.business_id and x.status = 'active'
                     and x.trigger_type = case when r.kind = 'reminder' then 'appointment_reminder' else 'appointment_confirmation' end) then
      update public.appointment_reminders set status = 'skipped', error = 'automation_off' where id = r.id; continue;
    end if;
    if b.suspended_at is not null or b.cancelled_at is not null or c.id is null or coalesce(c.do_not_contact, false) or (public.zella_digits(c.phone) is null and nullif(trim(coalesce(c.email, '')), '') is null) then
      update public.appointment_reminders set status = 'skipped', error = 'cannot_contact' where id = r.id; continue;
    end if;
    v_phone_ok := public.zella_digits(c.phone) is not null and not coalesce(c.do_not_sms, false);
    v_email_ok := public.zella_valid_email(c.email) and not coalesce(c.do_not_email, false);
    if v_channel = 'sms' and not v_phone_ok and v_email_ok then
      update public.appointment_reminders set channel = 'email' where id = r.id; continue;
    elsif v_channel = 'email' and not v_email_ok and v_phone_ok then
      update public.appointment_reminders set channel = 'sms' where id = r.id; continue;
    end if;
    if (v_channel = 'sms' and not v_phone_ok) or (v_channel = 'email' and not v_email_ok) then
      update public.appointment_reminders set status = 'skipped', error = 'cannot_contact' where id = r.id; continue;
    end if;
    select s.name into v_staff from public.staff_members s where s.id = a.staff_id;
    update public.appointment_reminders set status = 'sending', attempts = attempts + 1 where id = r.id;
    v_res := v_res || jsonb_build_array(jsonb_build_object('reminder_id', r.id, 'kind', r.kind, 'channel', r.channel, 'reason', r.reason, 'hours_before', r.hours_before,
      'reschedule_line', public.zella_reschedule_line(a.id),
      'business', jsonb_build_object('id', b.id, 'name', b.name, 'timezone', b.tz),
      'customer', jsonb_build_object('id', c.id, 'first_name', c.first_name, 'phone', c.phone, 'email', c.email, 'preferred_contact', to_jsonb(c) ->> 'preferred_contact'),
      'appointment', jsonb_build_object('id', a.id, 'title', a.title, 'start_time', a.start_time, 'end_time', a.end_time, 'staff', v_staff)));
  end loop;
  return v_res;
end $function$;

-- CodeRabbit #71
CREATE OR REPLACE FUNCTION public.zella_permission_check()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_fn text[]; v_pol text[]; v_rls text[]; v_allowed text[] := array['zella_unsubscribe_email', 'zella_unsubscribe_lookup', 'zella_digits', 'zella_valid_email'];
begin
  select coalesce(array_agg(p.proname order by p.proname), '{}') into v_fn from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and has_function_privilege('anon', p.oid, 'execute')
     and pg_get_function_result(p.oid) <> 'trigger' and p.proname <> all (v_allowed);
  select coalesce(array_agg(tablename || '.' || policyname order by tablename), '{}') into v_pol from pg_policies
   where schemaname = 'public' and (qual = 'true' or with_check = 'true') and (roles && array['anon'::name, 'public'::name] or cmd <> 'SELECT')
     and tablename not in ('plans', 'industries');
  -- tables (and partitioned tables) with row security off that anon or signed-in users can read or change
  select coalesce(array_agg(c.relname::text order by c.relname), '{}') into v_rls from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') and not c.relrowsecurity
     and (has_table_privilege('anon', c.oid, 'select, insert, update, delete') or has_table_privilege('authenticated', c.oid, 'select, insert, update, delete'));
  return jsonb_build_object('anon_functions', to_jsonb(v_fn), 'open_policies', to_jsonb(v_pol), 'tables_without_row_security', to_jsonb(v_rls),
                            'ok', cardinality(v_fn) = 0 and cardinality(v_pol) = 0 and cardinality(v_rls) = 0);
end $function$;

-- CodeRabbit #72
CREATE OR REPLACE FUNCTION public.zella_apply_industry_automations(p_business_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_name text; v_key text; n integer := 0; v_rows integer; p record;
begin
  select regexp_replace(lower(coalesce(ind.name, '')), '[^a-z]', '', 'g') into v_name
    from public.businesses b left join public.industries ind on ind.id = b.industry_id where b.id = p_business_id;
  if not found then return 0; end if;
  select k.key into v_key from public.industry_crm_presets k where v_name = any (k.match) order by k.key limit 1;
  if v_key is null then v_key := 'other'; end if;
  for p in select * from public.industry_automation_presets
            where industry_key = v_key
               or (industry_key = 'general' and v_key not in ('healthcare', 'dental', 'legal', 'financial_services', 'childcare')) loop
    insert into public.automations (business_id, name, description, trigger_type, status, trigger_config, actions, conditions)
    select p_business_id, p.name, p.description, p.trigger_type, case when p.industry_key = 'general' then 'paused' else 'active' end, p.trigger_config, '[]'::jsonb, '{}'::jsonb
     where not exists (select 1 from public.automations x where x.business_id = p_business_id and x.name = p.name);
    get diagnostics v_rows = row_count;
    n := n + v_rows;
  end loop;
  return n;
end $function$;

-- CodeRabbit #73
CREATE OR REPLACE FUNCTION public.zella_decide_draft(p_draft_id uuid, p_send boolean, p_body text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare d public.message_drafts; v_body text; v_id uuid;
begin
  select * into d from public.message_drafts where id = p_draft_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not public.zella_has_role(d.business_id, array['owner','admin','manager','staff']) then raise exception 'NOT_ALLOWED'; end if;
  if d.status <> 'pending' then raise exception 'ALREADY_DECIDED'; end if;
  if p_send then
    v_body := left(coalesce(nullif(trim(p_body), ''), d.body), 300);
    if v_body ~ '[$€£]' or (v_body ~* '\m(sale|discount|offer ends|promo)\M' or v_body ~* '%\s*off\M') then raise exception 'NO_MARKETING_OR_PRICES'; end if;
    v_id := public.zella_queue_customer_message(d.business_id, d.customer_id, 'record_status_update',
              jsonb_build_object('status_line', v_body, 'status', 'draft', 'record_title', ''), interval '0', null, interval '0');
    if v_id is null then raise exception 'CANNOT_REACH'; end if;
    update public.message_drafts set status = 'sent', decided_by = auth.uid(), decided_at = now() where id = d.id;
  else
    update public.message_drafts set status = 'dismissed', decided_by = auth.uid(), decided_at = now() where id = d.id;
  end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (d.business_id, auth.uid(), case when p_send then 'draft_sent' else 'draft_dismissed' end, 'message_draft', d.id, jsonb_build_object('customer_id', d.customer_id));
  return case when p_send then 'queued' else 'dismissed' end;
end $function$;

-- CodeRabbit #75
CREATE OR REPLACE FUNCTION public.zella_claim_events(p_limit integer DEFAULT 20)
 RETURNS SETOF automation_events
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare q record;
begin
  for q in select id from public.automation_events
    where status = 'processing' and attempts >= 5 and claimed_at < now() - interval '10 minutes'
    for update skip locked loop
    perform public.zella_complete_event(q.id, false, 'provider_timeout', 'Execution interrupted at final attempt');
  end loop;
  return query
  with picked as (
    select id from public.automation_events
     where (status = 'received' and coalesce(next_attempt_at, now()) <= now())
        or (status = 'processing' and claimed_at < now() - interval '10 minutes' and attempts < 5)
     order by received_at
     for update skip locked
     limit greatest(1, least(coalesce(p_limit, 20), 100))
  )
  update public.automation_events e
     set status = 'processing', attempts = e.attempts + 1, claimed_at = now()
    from picked where e.id = picked.id
  returning e.*;
end $function$;

-- CodeRabbit #75
CREATE OR REPLACE FUNCTION public.zella_complete_event(p_event_id uuid, p_ok boolean, p_error_category text DEFAULT NULL::text, p_error text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare e public.automation_events; v_temp boolean;
begin
  select * into e from public.automation_events where id = p_event_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if e.status <> 'processing' then return 'ignored'; end if;   -- finished already, or reclaimed and finished by another run
  if p_ok then
    update public.automation_events set status = 'processed', processed_at = now(), error_category = null, error_message = null where id = e.id;
    return 'processed';
  end if;
  v_temp := coalesce(p_error_category, 'unknown_error') in ('rate_limited','temporary_network','provider_timeout','unknown_error');
  if v_temp and e.attempts < 5 then
    update public.automation_events
       set status = 'received', next_attempt_at = now() + make_interval(secs => least(3600, 30 * power(2, e.attempts)::int)),
           error_category = coalesce(p_error_category, 'unknown_error'), error_message = public.zella_redact(p_error)
     where id = e.id;
    return 'retry';
  end if;
  update public.automation_events
     set status = 'failed', processed_at = now(), error_category = coalesce(p_error_category, 'unknown_error'), error_message = public.zella_redact(p_error)
   where id = e.id;
  insert into public.automation_dead_letters (business_id, source_table, source_id, event_id, reason, error_category)
  values (e.business_id, 'automation_events', e.id, e.id, coalesce(public.zella_redact(p_error), 'Failed'), coalesce(p_error_category, 'unknown_error'))
  on conflict do nothing;
  return 'dead_letter';
end $function$;

-- CodeRabbit #76
CREATE OR REPLACE FUNCTION public.zella_record_consent(p_business_id uuid, p_channel text, p_status text, p_source text, p_customer_id uuid DEFAULT NULL::uuid, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_purpose text DEFAULT 'marketing'::text, p_keyword text DEFAULT NULL::text, p_evidence jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid(); v_id uuid; v_cust uuid := p_customer_id; v_digits text := public.zella_digits(p_phone);
begin
  if v_uid is not null and not public.zella_can_edit(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  -- signed-in people record only what staff can witness; keyword replies and email links come from the server
  if v_uid is not null and p_source not in ('staff', 'verbal_call', 'web_form', 'import') then raise exception 'NOT_ALLOWED'; end if;
  if v_uid is not null and p_status = 'opted_in' and not public.zella_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if not exists (select 1 from public.businesses where id = p_business_id) then raise exception 'INVALID_BUSINESS'; end if;
  if v_cust is not null and not exists (select 1 from public.customers where id = v_cust and business_id = p_business_id) then raise exception 'TENANT_MISMATCH'; end if;
  if v_cust is null and v_digits is not null then
    select id into v_cust from public.customers where business_id = p_business_id and public.zella_digits(phone) = v_digits order by created_at limit 1;
  end if;
  if v_cust is null and p_email is not null then
    select id into v_cust from public.customers where business_id = p_business_id and lower(email) = lower(p_email) order by created_at limit 1;
  end if;
  insert into public.contact_consents (business_id, customer_id, phone_digits, email_lower, channel, purpose, status, source, keyword, evidence, recorded_by)
  values (p_business_id, v_cust, v_digits, nullif(lower(trim(coalesce(p_email, ''))), ''), p_channel, coalesce(p_purpose, 'marketing'), p_status, p_source, upper(left(p_keyword, 20)), coalesce(p_evidence, '{}'::jsonb), v_uid)
  returning id into v_id;
  if v_cust is not null and p_status = 'opted_out' then
    update public.customers set
      do_not_sms = do_not_sms or p_channel = 'sms',
      do_not_call = do_not_call or p_channel = 'call',
      do_not_email = do_not_email or p_channel = 'email',
      updated_at = now()
     where id = v_cust;
  elsif v_cust is not null and p_status = 'opted_in' and v_uid is null and p_source in ('inbound_sms_keyword','email_link') then
    update public.customers set
      do_not_sms = do_not_sms and p_channel <> 'sms',
      do_not_email = do_not_email and p_channel <> 'email',
      updated_at = now()
     where id = v_cust;
  end if;
  return v_id;
end $function$;

-- CodeRabbit #77
CREATE OR REPLACE FUNCTION public.zella_calls_page(p_business_id uuid, p_filter text DEFAULT 'all'::text, p_transcripts_only boolean DEFAULT false, p_limit integer DEFAULT 25, p_after jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 100);
  c record;
  v_out jsonb;
begin
  perform public.zella_b3_member(p_business_id);
  if coalesce(p_filter, '') not in ('all', 'answered', 'missed', 'ai', 'human', 'recorded') then raise exception 'BAD_FILTER' using errcode = '22023'; end if;
  select * into c from public.zella_b3_cursor(p_after);

  with base as (
    select v.id, v.created_at, v.status, v.metadata, case p_filter when 'missed' then v.status = 'missed'
                              when 'ai' then coalesce(v.ai_handled, false)
                              when 'answered' then v.status in ('answered', 'completed')
                              when 'human' then coalesce(v.needs_human, false) and v.escalation_resolved_at is null
                              when 'recorded' then v.recording_url is not null and (v.metadata ->> 'recording_consent') is distinct from 'false'
                              else true end matches
      from public.calls_view v
     where v.business_id = p_business_id
       and (not coalesce(p_transcripts_only, false) or coalesce(v.transcript, '') <> ''
            or (v.recording_url is not null and (v.metadata ->> 'recording_consent') is distinct from 'false'))
  ), page as (
    select b.created_at, b.id
      from base b where b.matches and (c.t is null or (b.created_at, b.id) < (c.t, c.id))
     order by b.created_at desc, b.id desc limit v_limit + 1
  ), shown as (
    select * from page order by created_at desc, id desc limit v_limit
  )
  select jsonb_build_object(
    'rows', (select coalesce(jsonb_agg((select public.zella_call_row(v) from public.calls_view v where v.id = s.id) || jsonb_build_object('follow_ups', coalesce((
               select jsonb_agg(f order by f ->> 'due_at') from (
                 select jsonb_build_object('id', b.id, 'kind', 'callback', 'reason', b.reason, 'due_at', b.due_at, 'done', b.status in ('completed', 'cancelled')) f
                   from public.callbacks b where b.call_id = s.id
                 union all
                 select jsonb_build_object('id', t.id, 'kind', 'followup', 'due_at', t.due_at, 'done', t.status in ('done', 'cancelled'))
                   from public.followup_tasks t where t.call_id = s.id) ff), '[]'))
             order by s.created_at desc, s.id desc), '[]') from shown s),
    'next', case when (select count(*) from page) > v_limit
                 then (select jsonb_build_object('t', created_at, 'id', id) from (select * from shown order by created_at, id limit 1) q) end,
    'total', (select count(*) from base where matches),
    -- missed calls nobody has followed up yet: not marked, and no callback or follow-up call linked
    'missed_open', (select count(*) from base b where b.status = 'missed' and (b.metadata ->> 'followed_up_at') is null
                      and not exists (select 1 from public.callbacks x where x.call_id = b.id)
                      and not exists (select 1 from public.followup_tasks x where x.call_id = b.id)))
  into v_out;
  return v_out;
end $function$;

-- CodeRabbit #78
CREATE OR REPLACE FUNCTION public.zella_inbox_previews(p_business_id uuid, p_conversation_ids uuid[])
 RETURNS TABLE(conversation_id uuid, preview text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
begin
  perform public.zella_b3_member(p_business_id);
  if coalesce(cardinality(p_conversation_ids), 0) > 100 then raise exception 'TOO_MANY' using errcode = '22023'; end if;
  return query
    select x.id, left(regexp_replace(m.content, '\s+', ' ', 'g'), 160)
      from public.conversations x
      cross join lateral (select cm.content from public.conversation_messages cm where cm.conversation_id = x.id
                           order by cm.created_at desc limit 1) m
     where x.business_id = p_business_id and x.id = any (p_conversation_ids);
end $function$;

-- CodeRabbit #100
CREATE OR REPLACE FUNCTION public.zella_admin_messages(p_channel text, p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_business uuid DEFAULT NULL::uuid, p_status text DEFAULT NULL::text, p_direction text DEFAULT NULL::text, p_kind text DEFAULT NULL::text, p_q text DEFAULT NULL::text, p_limit integer DEFAULT 25, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_lim int := least(greatest(coalesce(p_limit, 25), 1), 100); v_q text := nullif(lower(trim(coalesce(p_q, ''))), '');
        v_from timestamptz := coalesce(p_from, now() - interval '30 days'); v_to timestamptz := coalesce(p_to, now() + interval '1 minute');
begin
  perform public.zella_admin_require('businesses.view');
  if p_channel = 'sms' then
    return (with f as (
        select m.*, case when m.metadata ? 'reminder_id' then 'reminder' when m.metadata ? 'task_id' then 'follow_up'
                         when m.metadata ? 'notification_id' then 'staff_alert' when m.direction = 'inbound' then 'inbound' else 'other' end as kind
          from public.sms_messages m
         where m.created_at >= v_from and m.created_at < v_to and (p_business is null or m.business_id = p_business)
           and (p_status is null or m.status = p_status) and (p_direction is null or m.direction = p_direction)
           and (v_q is null or length(regexp_replace(v_q, '\D', '', 'g')) >= 4 and (regexp_replace(coalesce(m.to_number, ''), '\D', '', 'g') like '%' || regexp_replace(v_q, '\D', '', 'g') || '%'
                or regexp_replace(coalesce(m.from_number, ''), '\D', '', 'g') like '%' || regexp_replace(v_q, '\D', '', 'g') || '%')
                or m.external_message_id = p_q)),
      g as (select * from f where p_kind is null or kind = p_kind)
      select jsonb_build_object('total', (select count(*) from g), 'rows', coalesce((select jsonb_agg(jsonb_build_object(
          'id', g.id, 'created_at', g.created_at, 'business_id', g.business_id, 'business_name', b.name, 'direction', g.direction, 'status', g.status,
          'to', public.zella_admin_mask(g.to_number), 'from', public.zella_admin_mask(g.from_number), 'kind', g.kind,
          'provider_id', g.external_message_id, 'conversation_id', g.conversation_id, 'sent_at', g.sent_at, 'delivered_at', g.delivered_at,
          'error', left(coalesce(g.metadata ->> 'error', g.metadata ->> 'failure_reason'), 160)) order by g.created_at desc, g.id)
        from (select * from g order by created_at desc, id limit v_lim offset greatest(coalesce(p_offset, 0), 0)) g join public.businesses b on b.id = g.business_id), '[]'::jsonb)));
  elsif p_channel = 'email' then
    return (with f as (
        select m.*, case when m.metadata ? 'reminder_id' then 'reminder' when m.metadata ? 'task_id' then 'follow_up'
                         when m.metadata ? 'notification_id' then 'owner_email' when m.direction = 'inbound' then 'inbound' else 'other' end as kind
          from public.email_messages m
         where m.created_at >= v_from and m.created_at < v_to and (p_business is null or m.business_id = p_business)
           and (p_status is null or m.status = p_status) and (p_direction is null or m.direction = p_direction)
           and (v_q is null or lower(coalesce(m.to_email, '')) = v_q or lower(coalesce(m.from_email, '')) = v_q
                or lower(coalesce(m.subject, '')) like '%' || v_q || '%' or m.external_message_id = p_q)),
      g as (select * from f where p_kind is null or kind = p_kind)
      select jsonb_build_object('total', (select count(*) from g), 'rows', coalesce((select jsonb_agg(jsonb_build_object(
          'id', g.id, 'created_at', g.created_at, 'business_id', g.business_id, 'business_name', b.name, 'direction', g.direction, 'status', g.status,
          'to', public.zella_admin_mask(g.to_email), 'from', g.from_email, 'subject', left(g.subject, 120), 'kind', g.kind,
          'provider_id', g.external_message_id, 'sent_at', g.sent_at, 'delivered_at', g.delivered_at,
          'last_event', (select ev.type from public.email_events ev where ev.email_message_id = g.id order by ev.created_at desc limit 1),
          'error', left(coalesce(g.metadata ->> 'error', g.metadata ->> 'failure_reason'), 160)) order by g.created_at desc, g.id)
        from (select * from g order by created_at desc, id limit v_lim offset greatest(coalesce(p_offset, 0), 0)) g join public.businesses b on b.id = g.business_id), '[]'::jsonb)));
  end if;
  raise exception 'INVALID_CHANNEL';
end $function$;

-- CodeRabbit #100
CREATE OR REPLACE FUNCTION public.zella_config_migration_restore(p_snapshot_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s record; v_agent uuid; k jsonb;
begin
  select * into s from config_migration_snapshots where id = p_snapshot_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if s.restored_at is not null then return jsonb_build_object('restored', false, 'reason', 'already restored'); end if;
  select a.id into v_agent from ai_agents a where a.business_id = s.business_id and a.is_default limit 1;
  delete from business_languages where business_id = s.business_id;
  if s.languages is not null then
    insert into business_languages select * from jsonb_populate_record(null::business_languages, s.languages);
  end if;
  if s.applied ? 'transfer_number' then
    update ai_agent_configs
       set escalation_rules = (coalesce(escalation_rules, '{}'::jsonb) - 'transfer_number' - 'transfer_number_source')
             || (select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
                   from jsonb_each(coalesce(s.escalation_rules, '{}'::jsonb))
                  where key in ('transfer_number', 'transfer_number_source')),
           updated_at = now()
     where agent_id = v_agent;
  end if;
  update knowledge_items set status = 'archived', updated_at = now()
   where business_id = s.business_id and source_key like 'setup:%' and source_page_id is null
     and not exists (select 1 from jsonb_array_elements(s.setup_knowledge) x where (x ->> 'id')::uuid = knowledge_items.id);
  for k in select * from jsonb_array_elements(s.setup_knowledge) loop
    update knowledge_items set status = k ->> 'status', title = k ->> 'title', question = k ->> 'question', answer = k ->> 'answer', kind = k ->> 'kind', updated_at = now()
     where id = (k ->> 'id')::uuid;
  end loop;
  update config_migration_snapshots set restored_at = now() where id = p_snapshot_id;
  return jsonb_build_object('restored', true, 'business_id', s.business_id);
end $function$;

-- CodeRabbit #100
CREATE OR REPLACE FUNCTION public.zella_dispatch_n8n()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_base text := nullif(trim(public.zella_setting('n8n_base_url', '""'::jsonb) #>> '{}'), '');
  v_on boolean := coalesce(public.zella_setting('n8n_dispatch_enabled', 'false'::jsonb) = 'true'::jsonb, false);
  v_secret text; w record; n integer; st public.n8n_dispatch_state; v_same integer; v_res jsonb := '{}'::jsonb; v_spam integer := 0; v_reconcile integer := 0; v_reviews integer := 0;
  v_text_kinds text[] := array['no_show_follow_up', 'post_appointment_follow_up', 'quote_follow_up', 'lead_reactivation', 'callback_sms', 'welcome_new_customer', 'feedback_request', 'cancellation_confirmation', 'record_status_update', 'service_due', 'no_response_follow_up', 'reschedule_confirmation', 'booking_follow_up', 'service_completed', 'lead_follow_up', 'lead_final_follow_up', 'reply_confirmed', 'reply_reschedule', 'reply_help', 'waitlist_offer', 'cross_sell'];
  v_email_kinds text[] := array['no_show_follow_up', 'post_appointment_follow_up', 'quote_follow_up', 'lead_reactivation', 'callback_sms', 'welcome_new_customer', 'feedback_request', 'cancellation_confirmation', 'record_status_update', 'service_due', 'no_response_follow_up', 'reschedule_confirmation', 'booking_follow_up', 'service_completed', 'lead_follow_up', 'lead_final_follow_up', 'cross_sell'];
begin
  if not v_on then return jsonb_build_object('skipped', 'switched_off'); end if;
  if v_base is null then return jsonb_build_object('skipped', 'no_base_url'); end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'zella_n8n_secret' limit 1;
  if v_secret is null or v_secret = '' then return jsonb_build_object('skipped', 'no_secret'); end if;
  if to_regprocedure('public.zella_spam_work_waiting()') is not null then
    begin execute 'select public.zella_spam_work_waiting()' into v_spam; exception when others then v_spam := 0; end;
  end if;
  if to_regprocedure('public.zella_call_reconcile_waiting()') is not null then
    begin execute 'select public.zella_call_reconcile_waiting()' into v_reconcile; exception when others then v_reconcile := 0; end;
  end if;

  if to_regprocedure('public.zella_review_work_waiting()') is not null then
    begin execute 'select public.zella_review_work_waiting()' into v_reviews; exception when others then v_reviews := 0; end;
  end if;

  for w in select * from (values ('event-router'), ('sms-sender'), ('email-sender'), ('followup-texts'), ('followup-emails'), ('owner-emails'), ('outbound-calls'), ('knowledge-sync'), ('calendar-sync'), ('connection-tests'), ('meta-leads'), ('meta-sender'), ('meta-health'), ('website-crawl'), ('staff-sms'), ('call-intel'), ('admin-alerts'), ('spam-response'), ('call-reconcile'), ('review-replies')) as t(name) loop
    n := case w.name
      when 'event-router' then (select count(*) from public.automation_events
         where (status = 'received' and coalesce(next_attempt_at, now()) <= now()) or (status = 'processing' and claimed_at < now() - interval '10 minutes'))
      when 'sms-sender' then (select count(*) from public.appointment_reminders where status = 'pending' and channel = 'sms' and due_at <= now())
      when 'email-sender' then (select count(*) from public.appointment_reminders where status = 'pending' and channel = 'email' and due_at <= now())
      when 'followup-texts' then (select count(*) from public.followup_tasks where status = 'pending' and channel = 'sms' and due_at <= now() and kind = any (v_text_kinds))
      when 'followup-emails' then (select count(*) from public.followup_tasks where status = 'pending' and channel = 'email' and due_at <= now() and kind = any (v_email_kinds))
      when 'outbound-calls' then (select count(*) from public.followup_tasks where status = 'pending' and channel = 'call' and due_at <= now())
         + (select count(*) from public.callbacks where status in ('scheduled', 'retry_scheduled', 'due') and due_at <= now() and auto_call
              and (locked_at is null or locked_at < now() - interval '15 minutes'))
      when 'knowledge-sync' then (select count(*) from public.knowledge_items where status = 'processing')
         + case when coalesce(public.zella_setting('knowledge_ai_live', 'false'::jsonb) = 'true'::jsonb, false)
                then (select count(*) from public.knowledge_gaps where status = 'open' and suggested_at is null and suggestion_attempts < 3) else 0 end
      when 'call-intel' then case when coalesce(public.zella_setting('call_intel_live', 'false'::jsonb) = 'true'::jsonb, false)
         then (select count(*) from public.call_insights where (status = 'pending' and attempts < 3) or (status = 'processing' and claimed_at < now() - interval '15 minutes')) else 0 end
      when 'calendar-sync' then case when public.zella_calendar_live()
         then (select count(*) from public.calendar_sync_queue where status = 'pending' and due_at <= now())
            + (select count(*) from public.calendar_connections where status = 'active' and busy_refresh_due_at <= now()) else 0 end
      when 'connection-tests' then case when public.zella_provider_checks_live()
         then (select count(*) from unnest(array['telnyx', 'vapi', 'resend']) p where not exists (select 1 from public.provider_health h where h.provider = p
                 and (coalesce(h.checked_at, 'epoch') > now() - interval '3 hours' or coalesce(h.claimed_at, 'epoch') > now() - interval '10 minutes'))) else 0 end
      when 'meta-leads' then (select count(*) from public.meta_events where kind = 'lead'
         and ((status = 'pending' and next_try_at <= now()) or (status = 'processing' and claimed_at < now() - interval '10 minutes')))
      when 'meta-sender' then (select count(*) from public.meta_outbox where (status = 'queued' and next_try_at <= now()) or (status = 'sending' and claimed_at < now() - interval '10 minutes'))
      when 'meta-health' then (select count(*) from public.meta_connections where status in ('connected', 'error') and next_check_at <= now())
      when 'website-crawl' then case when public.zella_website_crawl_live()
         then (select count(*) from public.website_pages wp join public.website_sources ws on ws.id = wp.source_id and ws.status = 'active'
                where wp.status in ('approved', 'broken', 'missing') and wp.next_fetch_at <= now() and (wp.claimed_at is null or wp.claimed_at < now() - interval '10 minutes'))
            + (select count(*) from public.website_sources where status = 'active' and next_discovery_at <= now()) else 0 end
      when 'staff-sms' then case when coalesce(public.zella_setting('sms_live', 'false'::jsonb) = 'true'::jsonb, false)
         then (select count(*) from public.staff_notifications where created_at > now() - interval '6 hours'
                 and (sms_status = 'pending' or (sms_status = 'sending' and sms_claimed_at < now() - interval '15 minutes'))) else 0 end
      when 'admin-alerts' then case when coalesce(public.zella_setting('email_live', 'false'::jsonb) = 'true'::jsonb, false)
                                     and nullif(trim(public.zella_setting('email_from_address', '""'::jsonb) #>> '{}'), '') is not null
         then (select count(*) from public.platform_alerts s where s.status = 'open' and (s.notified_at is null or s.notified_at < now() - interval '15 minutes')
                     and s.meta ->> 'emailed_at' is null and coalesce((s.meta ->> 'email_attempts')::int, 0) < 3) else 0 end
      when 'spam-response' then coalesce(v_spam, 0)
      when 'call-reconcile' then coalesce(v_reconcile, 0)
      when 'review-replies' then coalesce(v_reviews, 0)
      when 'owner-emails' then (select count(*) from public.staff_notifications s join public.businesses b on b.id = s.business_id
         where b.suspended_at is null and b.cancelled_at is null
           and (s.delivery_status = 'pending' or (s.delivery_status = 'sending' and s.claimed_at < now() - interval '30 minutes')))
      else 0 end;
    if n = 0 then
      update public.n8n_dispatch_state set last_count = 0, consecutive_same = 0 where workflow = w.name;
      continue;
    end if;

    insert into public.n8n_dispatch_state (workflow) values (w.name) on conflict do nothing;
    select * into st from public.n8n_dispatch_state where workflow = w.name;
    if st.last_triggered_at > now() - interval '8 seconds' then continue; end if;
    v_same := case when n >= st.last_count and st.last_triggered_at > now() - interval '10 minutes' then st.consecutive_same + 1 else 0 end;
    if v_same >= 12 and st.last_triggered_at > now() - interval '15 minutes' then
      update public.n8n_dispatch_state set last_count = n, consecutive_same = v_same where workflow = w.name;
      v_res := v_res || jsonb_build_object(w.name, 'backed_off');
      continue;
    end if;

    perform net.http_post(url := v_base || '/webhook/zella/run/' || w.name,
                          headers := jsonb_build_object('Content-Type', 'application/json', 'X-Zella-Secret', v_secret),
                          body := '{}'::jsonb, timeout_milliseconds := 5000);
    update public.n8n_dispatch_state set last_triggered_at = now(), last_count = n, consecutive_same = v_same, triggers_total = triggers_total + 1 where workflow = w.name;
    v_res := v_res || jsonb_build_object(w.name, n);
  end loop;
  return v_res;
end $function$;

-- CodeRabbit #100
CREATE OR REPLACE FUNCTION public.zella_platform_admin_email_check()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare u record;
begin
  if not new.is_active then return new; end if;
  if tg_op = 'UPDATE' and old.is_active and old.user_id = new.user_id then return new; end if;   -- unchanged grant
  select email, invited_at, last_sign_in_at into u from auth.users where id = new.user_id;
  if not found then raise exception 'ADMIN_ACCOUNT_NOT_FOUND' using errcode = '23503'; end if;
  if not exists (select 1 from auth.identities i where i.user_id = new.user_id
       and lower(i.identity_data ->> 'email') = lower(u.email)
       and i.identity_data -> 'email_verified' = 'true'::jsonb)
     and not (u.invited_at is not null and u.last_sign_in_at is null) then
    raise exception 'ADMIN_EMAIL_NOT_CONFIRMED' using errcode = '42501',
      hint = 'This account''s email address was never confirmed, so it can''t be made an admin.';
  end if;
  return new;
end $function$;

-- CodeRabbit #100
CREATE OR REPLACE FUNCTION public.zella_session_proved_email()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  -- the session must have signed in by email (link, or emailed code: the app has no phone sign-in), on this
  -- account's current address, with an email identity the auth provider verified
  select exists (
    select 1 from auth.users u
    join auth.sessions s on s.user_id = u.id and s.id::text = auth.jwt() ->> 'session_id'
    where u.id = auth.uid() and lower(u.email) = lower(auth.jwt() ->> 'email')
      and exists (select 1 from auth.identities i where i.user_id = u.id
        and lower(i.identity_data ->> 'email') = lower(u.email)
        and i.identity_data -> 'email_verified' = 'true'::jsonb)
      and exists (select 1 from jsonb_array_elements(
        case when jsonb_typeof(auth.jwt() -> 'amr') = 'array' then auth.jwt() -> 'amr' else '[]'::jsonb end) m
        where m ->> 'method' in ('otp', 'magiclink', 'invite', 'recovery', 'email/signup', 'email_change'))
  );
$function$;

-- CodeRabbit #200
CREATE OR REPLACE FUNCTION public.zella_offer_redeem_core(p_offer uuid, p_business uuid, p_source text, p_key text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o public.offers; r public.offer_redemptions; v_reason text; v_hold jsonb := public.zella_offer_rule_config('claim_hold');
        v_total int; v_mine int; v_recent int; v_unusual jsonb := public.zella_offer_rule_config('unusual_activity'); v_limit jsonb;
begin
  if p_key is null or length(p_key) < 8 then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;
  -- one redemption at a time per key, so two simultaneous requests cannot both pass the lookup
  perform pg_advisory_xact_lock(hashtextextended(p_key, 0));
  select * into r from public.offer_redemptions where idempotency_key = p_key;
  if found then
    if r.offer_id <> p_offer or r.business_id <> p_business then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
    return jsonb_build_object('ok', r.status in ('pending', 'confirmed'), 'status', r.status, 'redemption_id', r.id, 'repeat', true);
  end if;

  select * into o from public.offers where id = p_offer for update;
  if not found then v_reason := 'not_found';
  elsif o.status = 'paused' then v_reason := 'paused';
  elsif o.status in ('expired', 'archived') or (o.ends_at is not null and o.ends_at <= now()) then v_reason := 'expired';
  elsif o.status <> 'active' or o.starts_at is null or o.starts_at > now() then v_reason := 'not_started';
  elsif p_source in ('dashboard', 'code') and not ('dashboard' = any (o.channels)) then v_reason := 'not_available_here';
  elsif p_source = 'admin' and not ('sales' = any (o.channels)) and not ('dashboard' = any (o.channels)) then v_reason := 'not_available_here';
  elsif p_source = 'dashboard' and o.code is not null then v_reason := 'code_required';
  elsif not public.zella_offer_is_eligible(o, p_business) then v_reason := 'not_eligible';
  end if;

  if v_reason is null then
    select count(*) filter (where status in ('pending', 'confirmed')),
           count(*) filter (where status in ('pending', 'confirmed') and business_id = p_business)
      into v_total, v_mine from public.offer_redemptions where offer_id = o.id;
    if v_mine >= o.max_per_business then v_reason := 'already_claimed';
    elsif o.max_redemptions is not null and v_total >= o.max_redemptions then v_reason := 'limit_reached';
    elsif not o.stackable and exists (
      select 1 from public.offer_redemptions x join public.offers xo on xo.id = x.offer_id
      where x.business_id = p_business and x.status = 'pending' and x.offer_id <> o.id and not xo.stackable) then
      v_reason := 'cannot_combine';
    end if;
  end if;

  if v_reason is not null then
    perform public.zella_offer_log(case when o.id is not null then o.id end, 'claim_rejected', null, null,
                                   jsonb_build_object('reason', v_reason, 'source', p_source), p_business);
    return jsonb_build_object('ok', false, 'reason', v_reason);
  end if;

  insert into public.offer_redemptions (offer_id, business_id, status, source, idempotency_key, terms, hold_until, claimed_by, note)
  values (o.id, p_business, 'pending', p_source, p_key, public.zella_offer_terms(o),
          now() + make_interval(days => coalesce((v_hold ->> 'days')::int, 14)), auth.uid(), left(nullif(btrim(p_note), ''), 500))
  returning * into r;
  perform public.zella_offer_log(o.id, 'claimed', null, null, jsonb_build_object('source', p_source, 'redemption_id', r.id), p_business);

  v_total := v_total + 1;
  v_limit := public.zella_offer_rule_config('limit_warning');
  if o.max_redemptions is not null then
    if v_total >= o.max_redemptions then
      perform public.zella_platform_alert('offer_limit_reached', 'Offer limit reached: ' || o.name,
        format('All %s claims for this offer have been used.', o.max_redemptions), 'info', null, 'limit:' || o.id);
    elsif v_limit is not null and v_total * 100 >= o.max_redemptions * coalesce((v_limit ->> 'percent')::int, 80) then
      perform public.zella_platform_alert('offer_limit_near', 'Offer nearly used up: ' || o.name,
        format('%s of %s claims used.', v_total, o.max_redemptions), 'info', null, 'limitnear:' || o.id);
    end if;
  end if;
  if v_unusual is not null then
    select count(*) into v_recent from public.offer_redemptions where offer_id = o.id and created_at > now() - interval '1 hour';
    if v_recent >= coalesce((v_unusual ->> 'claims_per_hour')::int, 20) then
      perform public.zella_platform_alert('offer_unusual_activity', 'Unusual number of claims: ' || o.name,
        format('%s claims in the last hour. Consider pausing the offer to review.', v_recent), 'warning', null,
        'unusual:' || o.id || ':' || to_char(now(), 'YYYYMMDDHH24'));
    end if;
  end if;
  return jsonb_build_object('ok', true, 'status', r.status, 'redemption_id', r.id, 'hold_until', r.hold_until);
end $function$;

-- CodeRabbit #200
CREATE OR REPLACE FUNCTION public.zella_reassign_callback(p_callback_id uuid, p_to_user uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare cb record;
begin
  select * into cb from public.callbacks where id = p_callback_id;
  if cb.id is null then return 'not_found'; end if;
  if not public.zella_has_role(cb.business_id, array['owner','admin','manager','staff']) then raise exception 'NOT_ALLOWED'; end if;
  if p_to_user is not null and not exists (select 1 from public.business_members m where m.business_id = cb.business_id and m.user_id = p_to_user and m.status = 'active') then raise exception 'TARGET_NOT_ACTIVE'; end if;
  update public.callbacks set assigned_to = p_to_user, updated_at = now() where id = p_callback_id and status not in ('completed','cancelled');
  if not found then return 'closed'; end if;
  if p_to_user is not null then
    perform public.zella_notify(cb.business_id, 'callback', 'A callback was assigned to you', coalesce(cb.summary, 'Please call them back.'), 'info', 'callbacks', cb.id, p_to_user);
  end if;
  return 'reassigned';
end $function$;

-- CodeRabbit #200
CREATE OR REPLACE FUNCTION public.zella_erase_customer(p_business_id uuid, p_customer_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_column text;
begin
  if not public.zella_has_role(p_business_id, array['owner','admin']) then raise exception 'NOT_ALLOWED'; end if;
  if not exists (select 1 from public.customers where id = p_customer_id and business_id = p_business_id) then raise exception 'NOT_FOUND'; end if;
  if not public.zella_approval_ok(p_business_id, 'erase_customer', p_customer_id) then raise exception 'APPROVAL_REQUIRED'; end if;
  update public.sms_messages set message_body = '[removed]' where customer_id = p_customer_id and business_id = p_business_id;
  update public.email_messages set subject = '[removed]', body_text = '[removed]', body_html = null where customer_id = p_customer_id and business_id = p_business_id;
  update public.calls set transcript = null, recording_url = null, summary = null, from_number = null, to_number = null where customer_id = p_customer_id and business_id = p_business_id;
  update public.callbacks set contact_number = null, summary = null, note = null where customer_id = p_customer_id and business_id = p_business_id;
  update public.appointments set description = null where customer_id = p_customer_id and business_id = p_business_id;
  update public.crm_tasks set title = '[removed]', body = null where customer_id = p_customer_id and business_id = p_business_id;
  -- The base customer_requests DDL is external to this migration set. Scrub its
  -- descriptive fields when present without changing workflow keys or links.
  for v_column in select column_name from information_schema.columns
    where table_schema = 'public' and table_name = 'customer_requests'
      and column_name in ('title','subject','description','summary','body','notes','details','metadata','resolution','contact_name','contact_email','contact_phone')
  loop
    execute format('update public.customer_requests set %I = %s where customer_id = $1 and business_id = $2',
      v_column, case when v_column in ('details','metadata') then quote_literal('{}') else quote_literal('[removed]') end)
      using p_customer_id, p_business_id;
  end loop;
  -- Consent history is append-only (docs/ARCHITECTURE.md section 7.2). Keep
  -- phone_digits and email_lower for all channels/purposes: SMS opt-out readers
  -- match phone_digits and voice checks use the latest consent by that number.
  -- Do not erase/rewrite history or suppression identifiers when the profile is cleared.
  update public.followup_tasks set status = 'cancelled', updated_at = now() where customer_id = p_customer_id and business_id = p_business_id and status in ('pending','in_progress');
  update public.customers set first_name = 'Deleted', last_name = null, phone = null, email = null, address = null, notes = null, date_of_birth = null, company_name = null,
         tags = '{}', metadata = '{}'::jsonb, qualification = null, do_not_contact = true, status = 'archived', updated_at = now()
   where id = p_customer_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id) values (p_business_id, auth.uid(), 'customer_erased', 'customer', p_customer_id);
  return 'erased';
end $function$;

-- CodeRabbit #200
CREATE OR REPLACE FUNCTION public.zella_language_allowance(p_business_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s public.subscriptions; v text;
begin
  if not public.zella_has_role(p_business_id, array['owner','admin','manager','staff','viewer']) then raise exception 'NOT_ALLOWED'; end if;
  s := public.zella_current_subscription(p_business_id);
  if s.id is null then return null; end if;
  select p.limits ->> 'languages' into v from public.plans p where p.id = s.plan_id;
  if v is null or v !~ '^[0-9]{1,2}$' then return null; end if;
  return greatest(v::int, 1);
end $function$;

-- CodeRabbit #200
CREATE OR REPLACE FUNCTION public.zella_decide_time_off(p_request_id uuid, p_approve boolean)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.time_off_requests%rowtype; v_name text; v_block uuid;
begin
  select * into r from public.time_off_requests where id = p_request_id for update;
  if not found or not public.zella_can_manage(r.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if r.status <> 'pending' then raise exception 'ALREADY_DECIDED'; end if;
  select name into v_name from public.staff_members where id = r.staff_id;
  if p_approve then
    insert into public.blocked_times (business_id, title, reason, start_time, end_time, staff_id, created_by, source)
    values (r.business_id, 'Time off: ' || coalesce(v_name, 'staff'), coalesce(r.reason, 'Time off'), r.from_at, r.to_at, r.staff_id, auth.uid(), 'time_off')
    returning id into v_block;
  end if;
  update public.time_off_requests set status = case when p_approve then 'approved' else 'declined' end, decided_by = auth.uid(), decided_at = now(), blocked_time_id = v_block where id = r.id;
  if r.requested_by is not null then
    perform public.zella_notify(r.business_id, 'time_off_decision', case when p_approve then 'Time off approved' else 'Time off declined' end,
      coalesce(v_name, 'Staff') || ': ' || to_char(r.from_at, 'Mon FMDD') || ' to ' || to_char(r.to_at, 'Mon FMDD'), 'info', 'calendar', r.id, r.requested_by);
  end if;
  return case when p_approve then 'approved' else 'declined' end;
end $function$;

-- CodeRabbit #200
CREATE OR REPLACE FUNCTION public.zella_offboard_member(p_business_id uuid, p_user_id uuid, p_reassign_to uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_role text; v_moved jsonb := '{}'::jsonb;
begin
  if auth.uid() is not null and not exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active' and m.role in ('owner','admin')) then
    raise exception 'NOT_ALLOWED';
  end if;
  select role into v_role from public.business_members where business_id = p_business_id and user_id = p_user_id;
  if v_role is null then raise exception 'NOT_A_MEMBER'; end if;
  if auth.uid() is not null and v_role in ('owner','admin')
     and not exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active' and m.role = 'owner') then
    raise exception 'NOT_ALLOWED';
  end if;
  if p_reassign_to is not null and (p_reassign_to = p_user_id or not exists (
    select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = p_reassign_to and m.status = 'active')) then
    raise exception 'TARGET_NOT_ACTIVE';
  end if;
  if v_role = 'owner' and not exists (select 1 from public.business_members m where m.business_id = p_business_id and m.role = 'owner' and m.status = 'active' and m.user_id <> p_user_id) then
    raise exception 'LAST_OWNER';
  end if;
  update public.business_members set status = 'suspended', accepts_work = false where business_id = p_business_id and user_id = p_user_id;
  if p_reassign_to is not null then
    v_moved := public.zella_move_open_work(p_business_id, p_user_id, p_reassign_to);
  else
    update public.customers set assigned_to = null where business_id = p_business_id and assigned_to = p_user_id;
    update public.callbacks set assigned_to = null where business_id = p_business_id and assigned_to = p_user_id and status not in ('completed','done','reached','cancelled','failed');
    update public.customer_requests set assigned_to = null where business_id = p_business_id and assigned_to = p_user_id and status not in ('resolved','closed','cancelled');
  end if;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, new_data)
  values (p_business_id, auth.uid(), 'member_offboarded', 'business_member', p_user_id, jsonb_build_object('reassigned_to', p_reassign_to, 'moved', v_moved));
  return v_moved;
end $function$;

-- CodeRabbit #200
CREATE OR REPLACE FUNCTION public.zella_public_status()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_checks boolean := public.zella_provider_checks_live();
  v_n8n boolean := nullif(trim(public.zella_setting('n8n_base_url', '""'::jsonb) #>> '{}'), '') is not null
                   and coalesce(public.zella_setting('n8n_dispatch_enabled', 'true'::jsonb) = 'true'::jsonb, true);
  v_components jsonb := '[]'::jsonb; v_incidents jsonb; v_state text; h record; c record; v_rank int := 0;
  rank_of constant jsonb := '{"operational": 0, "unknown": 0, "degraded": 1, "outage": 2}';
begin
  for c in select * from (values ('phone', 'Phone assistant', 'vapi'), ('texts', 'Text messages', 'telnyx'), ('email', 'Email', 'resend')) as t(key, label, provider) loop
    select * into h from public.provider_health where provider = c.provider;
    v_state := case
      when not v_checks or h.provider is null or h.checked_at is null or h.checked_at < now() - interval '6 hours' then 'unknown'
      when h.ok then 'operational'
      when h.consecutive_failures >= 2 then 'outage'
      else 'degraded' end;
    v_components := v_components || jsonb_build_object('key', c.key, 'label', c.label, 'state', v_state,
      'checked_at', case when v_state <> 'unknown' then h.checked_at end);
  end loop;
  v_state := case
    when exists (select 1 from public.platform_alerts a where a.status <> 'resolved' and a.kind in ('automation_heartbeat', 'automation_stalled')) then 'outage'
    when exists (select 1 from public.platform_alerts a where a.status <> 'resolved' and a.kind = 'queue_backlog') then 'degraded'
    when v_n8n then 'operational' else 'unknown' end;
  v_components := v_components || jsonb_build_object('key', 'automations', 'label', 'Reminders and follow-ups', 'state', v_state);
  v_components := v_components || jsonb_build_object('key', 'app', 'label', 'Zella app', 'state', 'operational');

  for c in select distinct i.component from public.platform_incidents i where i.is_public and i.status = 'open' and i.component is not null loop
    select coalesce(jsonb_agg(case when x ->> 'key' = c.component and x ->> 'state' in ('operational', 'unknown') then x || '{"state": "degraded"}'::jsonb else x end), '[]'::jsonb)
      into v_components from jsonb_array_elements(v_components) x;
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object('message', i.public_message, 'status', i.status, 'component', i.component,
           'started_at', i.created_at, 'resolved_at', i.resolved_at) order by (i.status = 'open') desc, i.created_at desc), '[]'::jsonb) into v_incidents
    from (select * from public.platform_incidents where is_public and (status = 'open' or resolved_at > now() - interval '14 days')
           order by created_at desc limit 20) i;

  select max((rank_of ->> (x ->> 'state'))::int) into v_rank from jsonb_array_elements(v_components) x;
  if exists (select 1 from public.platform_incidents where is_public and status = 'open') then v_rank := greatest(v_rank, 1); end if;
  return jsonb_build_object('overall', case v_rank when 2 then 'outage' when 1 then 'degraded' else 'operational' end,
    'components', v_components, 'incidents', v_incidents, 'generated_at', now());
end $function$;

-- CodeRabbit #200
CREATE OR REPLACE FUNCTION public.zella_check_uptime()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_last timestamptz; v_stuck text[]; v_since timestamptz;
  v_n8n boolean := nullif(trim(public.zella_setting('n8n_base_url', '""'::jsonb) #>> '{}'), '') is not null
                   and coalesce(public.zella_setting('n8n_dispatch_enabled', 'true'::jsonb) = 'true'::jsonb, true);
begin
  select max(checked_at) into v_last from public.provider_health;
  select min(updated_at) into v_since from public.platform_settings where key = 'provider_checks_live';
  if public.zella_provider_checks_live() and coalesce(greatest(v_last, v_since), now()) < now() - interval '6 hours' then
    perform public.zella_platform_alert('automation_heartbeat', 'The automation engine looks down',
      'No connection check has come back for 6 hours (last: ' || coalesce(to_char(v_last at time zone 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', 'never')
      || '). n8n may be down or the Connection Tests workflow switched off.', 'urgent', null, 'heartbeat');
  else
    perform public.zella_resolve_platform_alerts('automation_heartbeat', null, 'heartbeat', 'Connection checks are coming back again');
  end if;
  select coalesce(array_agg(workflow order by workflow), '{}') into v_stuck from public.n8n_dispatch_state
   where workflow <> '_kick' and consecutive_same >= 12 and last_count > 0 and last_triggered_at > now() - interval '30 minutes';
  if v_n8n and cardinality(v_stuck) > 0 then
    perform public.zella_platform_alert('automation_stalled', 'Automations are not being worked',
      'n8n keeps being called but these queues are not going down: ' || array_to_string(v_stuck, ', ') || '. Check the workflows are published and their credentials work.',
      'urgent', null, 'stalled', jsonb_build_object('workflows', to_jsonb(v_stuck)));
  else
    perform public.zella_resolve_platform_alerts('automation_stalled', null, 'stalled', 'Queues are moving again');
  end if;
  return jsonb_build_object('heartbeat_last', v_last, 'stalled', to_jsonb(v_stuck));
end $function$;

-- CodeRabbit #300
CREATE OR REPLACE FUNCTION public.zella_record_email_event(p_key text, p_event jsonb, p_event_id text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_secret text; v_type text; v_data jsonb; v_ext text; v_to text; v_msg record; v_bounce text; v_n integer; v_cust record;
begin
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'zella_resend_webhook_key' limit 1;
  if v_secret is null or v_secret = '' then return 'not_configured'; end if;
  if p_key is null or encode(sha256(convert_to(p_key, 'utf8')), 'hex') <> encode(sha256(convert_to(v_secret, 'utf8')), 'hex') then return 'unauthorized'; end if;
  if p_event is null or jsonb_typeof(p_event) <> 'object' or nullif(p_event_id, '') is null then return 'ignored'; end if;

  v_type := left(coalesce(p_event ->> 'type', ''), 60);
  v_data := case when jsonb_typeof(p_event -> 'data') = 'object' then p_event -> 'data' else '{}'::jsonb end;
  v_ext := nullif(left(coalesce(v_data ->> 'email_id', ''), 200), '');
  v_to := lower(nullif(trim(left(coalesce(case when jsonb_typeof(v_data -> 'to') = 'array' then v_data -> 'to' ->> 0 else v_data ->> 'to' end, ''), 300)), ''));
  v_bounce := lower(coalesce(v_data -> 'bounce' ->> 'type', ''));

  select m.id, m.business_id, m.customer_id, m.to_email into v_msg from public.email_messages m
   where v_ext is not null and m.external_message_id = v_ext and m.direction = 'outbound' limit 1;
  v_to := coalesce(v_to, lower(v_msg.to_email));

  insert into public.email_events (provider_event_id, type, email_message_id, business_id, to_email, detail)
  values (left(p_event_id, 200), v_type, v_msg.id, v_msg.business_id, v_to,
          jsonb_build_object('bounce_type', nullif(v_bounce, ''), 'bounce_sub_type', v_data -> 'bounce' ->> 'subType'))
  on conflict (provider_event_id) do nothing;
  if not found then return 'duplicate'; end if;
  if v_msg.id is null and v_to is null then return 'ignored'; end if;

  if v_type = 'email.delivered' then
    update public.email_messages set status = 'delivered', delivered_at = now(), updated_at = now() where id = v_msg.id and status in ('sent', 'queued');
    return 'delivered';
  end if;

  if v_type = 'email.bounced' and v_bounce in ('permanent', 'hard') then
    if v_msg.id is not null then
      update public.email_messages set status = 'failed', metadata = metadata || jsonb_build_object('bounced', true), updated_at = now() where id = v_msg.id;
    end if;
    -- only the business that sent the message (NN-1, TEN-3); a bounce that matches no message changes no customer
    if v_msg.id is not null and v_to is not null then
      for v_cust in
        update public.customers c set do_not_email = true, email_suppressed_at = now(), email_suppressed_reason = 'bounced', updated_at = now()
         where c.business_id = v_msg.business_id and lower(c.email) = v_to and not coalesce(c.do_not_email, false)
        returning c.business_id, c.id
      loop
        perform public.zella_notify(v_cust.business_id, 'email_bounced', 'An email address does not work',
          'An email to ' || v_to || ' could not be delivered, so we will not email that address again. Please check the address with the customer.', 'info', 'customers', v_cust.id);
      end loop;
    end if;
    return 'bounced';
  end if;

  if v_type = 'email.complained' then
    if v_msg.business_id is not null and v_to is not null then
      for v_cust in
        update public.customers c set do_not_email = true, email_suppressed_at = now(), email_suppressed_reason = 'complained', updated_at = now()
         where c.business_id = v_msg.business_id and lower(c.email) = v_to and not coalesce(c.do_not_email, false)
        returning c.business_id, c.id
      loop
        perform public.zella_notify(v_cust.business_id, 'email_complaint', 'A customer marked an email as spam',
          v_to || ' marked an email as spam, so we will not email them again.', 'warning', 'customers', v_cust.id);
      end loop;
    end if;
    return 'complained';
  end if;

  return 'recorded';
end $function$;

-- CodeRabbit #300
CREATE OR REPLACE FUNCTION public.zella_business_currency(p_business_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(upper(nullif(b.setup_data #>> '{billing,currency}', '')), case upper(coalesce(b.country, 'US'))
    when 'AU' then 'AUD' when 'GB' then 'GBP' when 'UK' then 'GBP' when 'CA' then 'CAD' when 'NZ' then 'NZD' when 'IN' then 'INR'
    when 'IE' then 'EUR' when 'DE' then 'EUR' when 'FR' then 'EUR' when 'ES' then 'EUR' when 'IT' then 'EUR' when 'NL' then 'EUR'
    when 'SG' then 'SGD' when 'AE' then 'AED' when 'ZA' then 'ZAR' when 'JP' then 'JPY' else 'USD' end)
  from public.businesses b where b.id = p_business_id
    -- members of that business only; server code (no signed-in user) as before
    and (auth.uid() is null or public.is_business_member(p_business_id));
$function$;

-- CodeRabbit #38 (autofix): call insights summarise call content, so they follow the call-content rule, not membership
alter policy call_insights_read on public.call_insights using (public.zella_can_read_call_content(business_id));
-- #8: dental reminders don't name the treatment (anyone who sees the phone or inbox would read it); the platform
-- wording only, so a business's own template is untouched
update public.message_templates t set body = replace(t.body, 'a reminder of your {{appointment}} at', 'a reminder of your appointment at')
 where t.business_id is null and t.key = 'appointment_reminder' and t.status = 'active'
   and t.industry_id in (select id from public.industries where slug = 'dental') and t.body like '%a reminder of your {{appointment}} at%';
-- #21 (and #41, #46): internal helpers; only the functions that use them (owner's rights) and the server call them

-- internal helpers: only the functions that use them (owner's rights) and the server call them
revoke execute on function public.zella_booking_choices(uuid, timestamptz, timestamptz, integer, integer, integer) from public, anon, authenticated;
grant execute on function public.zella_booking_choices(uuid, timestamptz, timestamptz, integer, integer, integer) to service_role;
revoke execute on function public.zella_arrival_window(uuid) from public, anon, authenticated;
grant execute on function public.zella_arrival_window(uuid) to service_role;
revoke execute on function public.zella_capability_on(uuid, text) from public, anon, authenticated;
grant execute on function public.zella_capability_on(uuid, text) to service_role;
revoke execute on function public.zella_cross_sell_ideas(text) from public, anon;
grant execute on function public.zella_cross_sell_ideas(text) to authenticated, service_role;

-- #35: legacy connect: no callers, no actor or role check; zella_calendar_connect_provider replaces it
drop function if exists public.zella_calendar_connect(uuid, text, text, text);

-- #70: platform_admins is audited like business_members (the trigger function already had the branch for it)
drop trigger if exists zella_audit_privileged_trg on public.platform_admins;
create trigger zella_audit_privileged_trg after insert or update or delete on public.platform_admins
  for each row execute function public.zella_audit_privileged();

commit;
