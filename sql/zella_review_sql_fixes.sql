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
--   * zella_claim_calendar_sync: an item stuck "in progress" for 30 minutes is marked failed (and the owner told by the
--     usual failure path on the next change) rather than left forever; it is not retried blindly, because the event may
--     already exist in the calendar.
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
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_claim_admin_alert_email(integer)');
  if v is null or v not in ('66ec3be2abc0cc68eaf0758031f0ad30', '1ec8f039861dcb236c5160c38f8ed65c') then
    raise exception 'VERSION_MISMATCH: public.zella_claim_admin_alert_email(integer) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_admin_routing_save(uuid,jsonb,text)');
  if v is null or v not in ('1d84b93ac5222790d7d3c12e153d0656', '4d9ef4fcd2a4a29688b26858ef061c90') then
    raise exception 'VERSION_MISMATCH: public.zella_admin_routing_save(uuid,jsonb,text) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_admin_message_detail(text,uuid,boolean)');
  if v is null or v not in ('f32a252a1bc43904d8848ae4b80b1e09', '92d5a49bfec16b5135d3f041442f0529') then
    raise exception 'VERSION_MISMATCH: public.zella_admin_message_detail(text,uuid,boolean) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_admin_template_variables(text,text)');
  if v is null or v not in ('e6904c352df8bf5a2f2c21f3abd8abae', '23dd55db660283e7a8855dd6aae919d5') then
    raise exception 'VERSION_MISMATCH: public.zella_admin_template_variables(text,text) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_admin_numbers(text,text,uuid,integer,integer)');
  if v is null or v not in ('3a908348bf6db01ad9497d0238190386', 'e85dcd8fc411420c7e0789319c46a2d0') then
    raise exception 'VERSION_MISMATCH: public.zella_admin_numbers(text,text,uuid,integer,integer) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_admin_calls(timestamp with time zone,timestamp with time zone,uuid,text,text,text,boolean,text,integer,integer)');
  if v is null or v not in ('3b8aab3f3f87318f2266a2f8af2d97e6', '44cdecfec1eae33acb56f947f64eab8b') then
    raise exception 'VERSION_MISMATCH: public.zella_admin_calls(timestamp with time zone,timestamp with time zone,uuid,text,text,text,boolean,text,integer,integer) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_admin_automations(text,text,text,uuid,uuid,integer,integer)');
  if v is null or v not in ('f69ee721fff74677147af763f87bb1e8', 'c87d62cbe5ca6aae0678ce597ea0db8b') then
    raise exception 'VERSION_MISMATCH: public.zella_admin_automations(text,text,text,uuid,uuid,integer,integer) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_admin_runs(text,uuid,text,timestamp with time zone,timestamp with time zone,integer,integer)');
  if v is null or v not in ('4a6c768f50bf3b9f0bc3542074e8021a', 'ddee65cc0c59cbd9950dd06b751fd4a4') then
    raise exception 'VERSION_MISMATCH: public.zella_admin_runs(text,uuid,text,timestamp with time zone,timestamp with time zone,integer,integer) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_admin_templates(text,text,text,integer,integer)');
  if v is null or v not in ('2283af7bc93cf4dd471647e7d8b0a2c7', '38d76ea2282fb8af4889190e3c7ad908') then
    raise exception 'VERSION_MISMATCH: public.zella_admin_templates(text,text,text,integer,integer) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_set_industry_rules(uuid,jsonb)');
  if v is null or v not in ('9ae8a61bea21efd37e66599fd516fb3c', 'c444036975e3e20bd4bbaad3868b9664') then
    raise exception 'VERSION_MISMATCH: public.zella_set_industry_rules(uuid,jsonb) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_answer_knowledge_gap(uuid,text,text,text)');
  if v is null or v not in ('e7616fdc57dea7bb19d4c99c9b7feb87', '2e2db3e725388681bcfe89700b747cf6') then
    raise exception 'VERSION_MISMATCH: public.zella_answer_knowledge_gap(uuid,text,text,text) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_knowledge_guard()');
  if v is null or v not in ('f99fda69f0ddb6b632ebfbeb1edccfbb', '5f14fe50b740f39554cac3500bf64292') then
    raise exception 'VERSION_MISMATCH: public.zella_knowledge_guard() is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_capture_web_lead(text,text,text,text,text,text,jsonb,boolean,text,text,text,text)');
  if v is null or v not in ('e16a5e4646e1f9eb896a22058dc6117c', '1eb6ffbf52f0ad14a513936a3e7bd768') then
    raise exception 'VERSION_MISMATCH: public.zella_capture_web_lead(text,text,text,text,text,text,jsonb,boolean,text,text,text,text) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_ai_booking(text,uuid,text,jsonb)');
  if v is null or v not in ('36a2ee5cb1092f130cb3212862f46b7a', '143795206381bbf713f630fa71c317c3') then
    raise exception 'VERSION_MISMATCH: public.zella_ai_booking(text,uuid,text,jsonb) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_flag_unrecorded_appointments()');
  if v is null or v not in ('01b13252d9bd88c95aafc242428e1fbe', 'a08c1e9024823dbd5326508b072dc6c6') then
    raise exception 'VERSION_MISMATCH: public.zella_flag_unrecorded_appointments() is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_rebalance_assignments()');
  if v is null or v not in ('57190298f8eeecb222e7e0d4063f57f4', 'fc91d27184d6ee1b3a222f226231f2ba') then
    raise exception 'VERSION_MISMATCH: public.zella_rebalance_assignments() is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_save_business_hours(uuid,jsonb)');
  if v is null or v not in ('e34678fff3a3ac4389804818344f2591', 'c864bcd81e2f346b6038346adeab8df8') then
    raise exception 'VERSION_MISMATCH: public.zella_save_business_hours(uuid,jsonb) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_add_business_closure(uuid,date,date,text,time without time zone,time without time zone)');
  if v is null or v not in ('8087333b5db23bec9593230e07838333', 'bfa131f09555844052be50e149da3ab4') then
    raise exception 'VERSION_MISMATCH: public.zella_add_business_closure(uuid,date,date,text,time without time zone,time without time zone) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_finish_calendar_sync(uuid,boolean,text,text)');
  if v is null or v not in ('c0c78505daa0263a089d103ad7b16da0', '4b18a344282c6977ad51c411eb50800b') then
    raise exception 'VERSION_MISMATCH: public.zella_finish_calendar_sync(uuid,boolean,text,text) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_calendar_connect_provider(uuid,text,uuid,text,text,text)');
  if v is null or v not in ('b6dc2e33e83e99b3b8c40e90da5e739b', 'a1ba4c76bb2432b7f2807d2725aa3bf5') then
    raise exception 'VERSION_MISMATCH: public.zella_calendar_connect_provider(uuid,text,uuid,text,text,text) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_queue_calendar_sync()');
  if v is null or v not in ('8095c177e6e5c8074c0e825548a1798a', '95f4636ad40ef15376343c0dcccc6892') then
    raise exception 'VERSION_MISMATCH: public.zella_queue_calendar_sync() is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_claim_calendar_sync(integer)');
  if v is null or v not in ('01219c987442b1e4a595a953b8c6156a', 'eba8925564ca983e12117a6b72ee3dd3') then
    raise exception 'VERSION_MISMATCH: public.zella_claim_calendar_sync(integer) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_replace_calendar_busy(uuid,jsonb)');
  if v is null or v not in ('cac8ab21d3f54016a5fbe785d46a84fd', '65257b369ceec1c5d2ba72cc7b07a0fa') then
    raise exception 'VERSION_MISMATCH: public.zella_replace_calendar_busy(uuid,jsonb) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_sensitive_industry(uuid)');
  if v is null or v not in ('0f069e0c8c1819f5b1e3247b1fdc0c10', '3f15f600ed429815b2e390fda889ad04') then
    raise exception 'VERSION_MISMATCH: public.zella_sensitive_industry(uuid) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_today_operations(uuid)');
  if v is null or v not in ('dfc7fb1a1c68be1c7c1633407094ed6b', 'fa972b0670fac6cf72372fdbe8d3575f') then
    raise exception 'VERSION_MISMATCH: public.zella_today_operations(uuid) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_merge_customers(uuid,uuid,uuid)');
  if v is null or v not in ('e5203dc5e23b975fd40f59bed3d0f488', '1ffffe1f411350deb30e83abb6ab25d6') then
    raise exception 'VERSION_MISMATCH: public.zella_merge_customers(uuid,uuid,uuid) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_log_customer_request(uuid,uuid,text,text,text,uuid,text)');
  if v is null or v not in ('f02d95957f35e01ec96624db1dd14922', '464765fe77597e58606f2331c362d47e') then
    raise exception 'VERSION_MISMATCH: public.zella_log_customer_request(uuid,uuid,text,text,text,uuid,text) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_update_customer_request(uuid,text,text)');
  if v is null or v not in ('6b392bb4a8ae5a7569dd8c310e6bb463', '6c9a507452eb1486582bff6df9e59517') then
    raise exception 'VERSION_MISMATCH: public.zella_update_customer_request(uuid,text,text) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_record_status_touches_trg()');
  if v is null or v not in ('62367e9f9fa36454b7f6a3e1f70f5baf', 'a9a209fb6b333aec451d598262b0158e') then
    raise exception 'VERSION_MISMATCH: public.zella_record_status_touches_trg() is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_queue_customer_touches(integer)');
  if v is null or v not in ('66b07ecf937f27d9c4236ea56e3489e7', 'dfebe3b6dbacdb07be68d77bc34876e0') then
    raise exception 'VERSION_MISMATCH: public.zella_queue_customer_touches(integer) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_check_engine_health()');
  if v is null or v not in ('67061f0eeca63add98b314b98496590d', '8c3f9666bd1f4bc4b9f9f42c4f06b0ee') then
    raise exception 'VERSION_MISMATCH: public.zella_check_engine_health() is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_ai_voice(text,uuid,text,jsonb)');
  if v is null or v not in ('1995441567225e6380a6b84744fc196c', '9c06db95d2f765ac7fcbcb7eee0d9e37') then
    raise exception 'VERSION_MISMATCH: public.zella_ai_voice(text,uuid,text,jsonb) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_complete_followup_task(uuid,text,text,text,uuid,integer)');
  if v is null or v not in ('b6df61bdd1635b64b5d2fdd29d624f57', 'e9f7374bbaeae258f623da3b5dae2964') then
    raise exception 'VERSION_MISMATCH: public.zella_complete_followup_task(uuid,text,text,text,uuid,integer) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_claim_reminders(integer,text)');
  if v is null or v not in ('3e5e83a02e3f78d0f3d4b5ca91060972', 'df1e22ad22b09a5e86237e0a43c6d2b0') then
    raise exception 'VERSION_MISMATCH: public.zella_claim_reminders(integer,text) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_permission_check()');
  if v is null or v not in ('0b4cd9f129e7203577d88420a42a9c2f', '56f7546c45e3880cbbc73798303f19d1') then
    raise exception 'VERSION_MISMATCH: public.zella_permission_check() is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_apply_industry_automations(uuid)');
  if v is null or v not in ('1cd857cf1c7a9943dbc407c5daa96cd5', '0e0e8b8f5aa6b386b37037688183a8f3') then
    raise exception 'VERSION_MISMATCH: public.zella_apply_industry_automations(uuid) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_decide_draft(uuid,boolean,text)');
  if v is null or v not in ('2d0abf26c70486d6ab1af6518e8d5817', '4cf309b1cc799a9e7790b01c07a8ff7f') then
    raise exception 'VERSION_MISMATCH: public.zella_decide_draft(uuid,boolean,text) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_claim_events(integer)');
  if v is null or v not in ('21962313b731f6168b5f321b8fd887ab', '7fc04a3da1928b2894fa329a1dec5b1b') then
    raise exception 'VERSION_MISMATCH: public.zella_claim_events(integer) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_complete_event(uuid,boolean,text,text)');
  if v is null or v not in ('ff9ae32f589ac00c83cc1c781050f685', '77fab2a3a617026853faabfebbaba49a') then
    raise exception 'VERSION_MISMATCH: public.zella_complete_event(uuid,boolean,text,text) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_record_consent(uuid,text,text,text,uuid,text,text,text,text,jsonb)');
  if v is null or v not in ('dc3a5b030f66e0840e50a9356bf2b268', 'c0e226e6beaa383961ee5535b8ddc6b0') then
    raise exception 'VERSION_MISMATCH: public.zella_record_consent(uuid,text,text,text,uuid,text,text,text,text,jsonb) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_calls_page(uuid,text,boolean,integer,jsonb)');
  if v is null or v not in ('b9ae335d234eecf76afb291e3a9b9854', 'f3d6816ff1dd4b6169b18d8c159c1021') then
    raise exception 'VERSION_MISMATCH: public.zella_calls_page(uuid,text,boolean,integer,jsonb) is not the version this file was written against (expected the live version or this file version)';
  end if;
  select md5(prosrc) into v from pg_proc where oid = to_regprocedure('public.zella_inbox_previews(uuid,uuid[])');
  if v is null or v not in ('e8cd6f3e5f8eeabd949ad0c74e952e90', '58bbc9302a8d8d197b0c360f8264084c') then
    raise exception 'VERSION_MISMATCH: public.zella_inbox_previews(uuid,uuid[]) is not the version this file was written against (expected the live version or this file version)';
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
  -- a run that stopped half-way: fail it rather than retry blindly (the event may already be in the calendar)
  update public.calendar_sync_queue set status = 'failed', error = 'interrupted', completed_at = now()
   where status = 'in_progress' and claimed_at < now() - interval '30 minutes';
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
    if v_why = 'emergency' and (v_call.id is null or not exists (select 1 from public.calls where id = v_call.id and escalation_reason = 'emergency')) then
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
begin
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
