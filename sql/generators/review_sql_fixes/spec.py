NAME = "zella_review_sql_fixes"

HEADER = """-- Review fixes for the SQL migrations (CodeRabbit full-repository review, part 1: 10 Nov 2026). Safe to run twice.
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
-- Verify: tests/review_sql/run.sh (isolated copy only)."""

ROLLBACK_HEADER = """-- Rollback of sql/zella_review_sql_fixes.sql: puts back every function exactly as it was, the grants, the legacy
-- zella_calendar_connect, and removes the platform_admins audit trigger. Keeps every row. Needs the owner's approval
-- before it is run on production; run it with sql/rollback/run.sh."""

FUNCS = [
  # ---------------- security ----------------
  ("public.zella_record_consent(uuid,text,text,text,uuid,text,text,text,text,jsonb)", [
    ("  if v_uid is not null and p_source = 'inbound_sms_keyword' then raise exception 'NOT_ALLOWED'; end if;",
     "  -- signed-in people record only what staff can witness; keyword replies and email links come from the server\n"
     "  if v_uid is not null and p_source not in ('staff', 'verbal_call', 'web_form', 'import') then raise exception 'NOT_ALLOWED'; end if;\n"
     "  if v_uid is not null and p_status = 'opted_in' and not public.zella_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;"),
    ("elsif v_cust is not null and p_status = 'opted_in' and p_source in ('inbound_sms_keyword','email_link') then",
     "elsif v_cust is not null and p_status = 'opted_in' and v_uid is null and p_source in ('inbound_sms_keyword','email_link') then"),
  ]),
  ("public.zella_merge_customers(uuid,uuid,uuid)", [
    ("  if k.id is null or d.id is null then raise exception 'NOT_FOUND'; end if;\n",
     "  if k.id is null or d.id is null then raise exception 'NOT_FOUND'; end if;\n"
     "  if k.status = 'archived' then raise exception 'KEEP_ARCHIVED'; end if;\n"),
    ("  update public.customers set status = 'archived', phone = null,",
     "  -- the duplicate's consent history (opt-outs included) now belongs to the kept customer; order and evidence unchanged\n"
     "  update public.contact_consents set customer_id = p_keep, evidence = coalesce(evidence, '{}'::jsonb) || jsonb_build_object('merged_from', p_drop)\n"
     "   where business_id = p_business_id and customer_id = p_drop;\n"
     "  update public.customers set status = 'archived', phone = null,"),
  ]),
  ("public.zella_claim_reminders(text,integer)", [
    ("      update public.appointment_reminders set channel = 'sms' where id = r.id; continue;\n    end if;\n",
     "      update public.appointment_reminders set channel = 'sms' where id = r.id; continue;\n    end if;\n"
     "    if (v_channel = 'sms' and not v_phone_ok) or (v_channel = 'email' and not v_email_ok) then\n"
     "      update public.appointment_reminders set status = 'skipped', error = 'cannot_contact' where id = r.id; continue;\n"
     "    end if;\n"),
  ]),
  ("public.zella_knowledge_guard()", [
    ("    if not v_service then\n      new.status := case when new.status = 'draft' then 'draft' else 'processing' end;",
     "    if not v_service then\n      new.approved_by := null; new.approved_at := null;   -- only this guard sets them\n"
     "      new.status := case when new.status = 'draft' then 'draft' else 'processing' end;"),
    ("    new.business_id := old.business_id; new.created_by := old.created_by; new.gap_id := old.gap_id;",
     "    new.business_id := old.business_id; new.created_by := old.created_by; new.gap_id := old.gap_id;\n"
     "    new.approved_by := old.approved_by; new.approved_at := old.approved_at;   -- changed below only when it is approved now"),
  ]),
  ("public.zella_update_customer_request(uuid,text,text)", [
    ("if r.kind in ('data_access', 'data_deletion') and p_status = 'resolved' and not exists",
     "if r.kind in ('data_access', 'data_deletion') and (p_status in ('resolved', 'rejected') or r.status in ('resolved', 'rejected')) and not exists"),
  ]),
  ("public.zella_log_customer_request(uuid,uuid,text,text,text,uuid,text)", [
    ("     and customer_id is not distinct from p_customer_id and created_at > now() - interval '24 hours' limit 1;",
     "     and ((p_customer_id is not null and customer_id = p_customer_id) or (p_customer_id is null and p_call_id is not null and call_id = p_call_id))\n"
     "     and created_at > now() - interval '24 hours' limit 1;"),
  ]),
  ("public.zella_complete_followup_task(uuid,text,text,text,uuid,integer)", [
    ("  if not found then raise exception 'TASK_NOT_FOUND'; end if;\n",
     "  if not found then raise exception 'TASK_NOT_FOUND'; end if;\n"
     "  if v_task.status in ('done', 'failed', 'cancelled', 'skipped') then return v_task.status; end if;   -- already finished: a late duplicate report\n"
     "  if p_call_id is not null and not exists (select 1 from public.calls where id = p_call_id and business_id = v_task.business_id) then raise exception 'TENANT_MISMATCH'; end if;\n"),
    ("     where id = coalesce(p_call_id, v_task.call_id);",
     "     where id = coalesce(p_call_id, v_task.call_id) and business_id = v_task.business_id;"),
  ]),
  ("public.zella_capture_web_lead(text,text,text,text,text,text,jsonb,boolean,text,text,text,text)", [
    ("          priority = case when v_urgent then 'high' else priority end, updated_at = now()\n        where id = v_cust;",
     "          updated_at = now()   -- the visitor's wording stays on the submission and callback, not on the customer\n        where id = v_cust;"),
  ]),
  ("public.zella_sensitive_industry(uuid)", [
    ("where b.id = p_business_id), false);",
     "where b.id = p_business_id\n                      and (auth.uid() is null or public.zella_is_member(p_business_id) or public.is_platform_admin())), false);"),
  ]),
  ("public.zella_ai_voice(text,uuid,text,jsonb)", [
    ("    v_why := nullif(trim(left(coalesce(v_args ->> 'reason', ''), 300)), '');\n",
     "    v_why := nullif(trim(left(coalesce(v_args ->> 'reason', ''), 300)), '');\n"
     "    -- an emergency is reported with report_emergency (it alerts the owners and marks the call); the assistant can't claim one here\n"
     "    if lower(v_why) = 'emergency' and (v_call.id is null or not exists (select 1 from public.calls where id = v_call.id and escalation_reason = 'emergency')) then\n"
     "      return jsonb_build_object('ok', true, 'status', 'use_emergency',\n"
     "        'say', 'If this is an emergency, use the emergency action first. Otherwise ask why they need a person and try again with that reason.');\n"
     "    end if;\n"),
    ("        update public.calls set transfer_status = 'not_needed', escalation_reason = coalesce(escalation_reason, left(coalesce(v_why, 'asked_for_person'), 60)), updated_at = now() where id = v_call.id;",
     "        update public.calls set transfer_status = 'not_needed', escalation_reason = coalesce(escalation_reason, left(coalesce(v_why, 'asked_for_person'), 60)), updated_at = now()\n"
     "         where id = v_call.id and transfer_status is distinct from 'attempted';   -- an approved transfer stays approved"),
  ]),
  ("public.zella_calendar_connect_provider(uuid,text,uuid,text,text,text)", [
    ("  returning id into v_id;\n", "  returning id into v_id;\n"
     "  insert into public.calendar_sync_queue (business_id, appointment_id, action)\n"
     "  select business_id, id, 'upsert' from public.appointments\n"
     "   where business_id = p_business_id and start_time > now()\n"
     "     and status in ('scheduled', 'confirmed', 'completed')\n"
     "     and coalesce(booking_state, 'confirmed') not in ('requested', 'tentative')\n"
     "  on conflict (appointment_id) where status = 'pending' do update set action = 'upsert', due_at = now();\n"),
    ("    delete from public.blocked_times where connection_id = o.id and end_time > now();\n  end loop;",
     "    delete from public.blocked_times where connection_id = o.id and end_time > now();\n"
     "    -- event ids belong to the old provider's calendar: never send them to the new one (bookings are copied again)\n"
     "    update public.appointments set external_event_id = null where business_id = p_business_id and external_event_id is not null;\n"
     "    delete from public.calendar_sync_queue where business_id = p_business_id and status = 'pending';\n"
     "  end loop;"),
  ]),
  ("public.zella_permission_check()", [
    ("declare v_fn text[]; v_pol text[];", "declare v_fn text[]; v_pol text[]; v_rls text[];"),
    ("  return jsonb_build_object('anon_functions', to_jsonb(v_fn), 'open_policies', to_jsonb(v_pol), 'ok', cardinality(v_fn) = 0 and cardinality(v_pol) = 0);",
     "  -- tables (and partitioned tables) with row security off that anon or signed-in users can read or change\n"
     "  select coalesce(array_agg(c.relname::text order by c.relname), '{}') into v_rls from pg_class c\n"
     "   where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') and not c.relrowsecurity\n"
     "     and (has_table_privilege('anon', c.oid, 'select, insert, update, delete') or has_table_privilege('authenticated', c.oid, 'select, insert, update, delete'));\n"
     "  return jsonb_build_object('anon_functions', to_jsonb(v_fn), 'open_policies', to_jsonb(v_pol), 'tables_without_row_security', to_jsonb(v_rls),\n"
     "                            'ok', cardinality(v_fn) = 0 and cardinality(v_pol) = 0 and cardinality(v_rls) = 0);"),
  ]),
  ("public.zella_admin_message_detail(text,uuid)", [
    ("'customer_id', e.customer_id, 'meta', e.metadata),",
     "'customer_id', e.customer_id, 'meta', e.metadata - 'body' - 'text' - 'html' - 'body_text' - 'body_html'),"),
  ]),
  ("public.zella_admin_template_variables(text,text)", [
    ("from public.message_templates t where t.key = p_key and t.channel = p_channel",
     "from public.message_templates t where t.key = p_key and t.channel = p_channel and t.business_id is null"),
  ]),
  # ---------------- correctness ----------------
  ("public.zella_admin_routing_save(uuid,jsonb,text)", [
    ("if jsonb_typeof(p_rules) <> 'object' then", "if p_rules is null or jsonb_typeof(p_rules) <> 'object' then"),
  ]),
  ("public.zella_set_industry_rules(uuid,jsonb)", [
    ("p.trigger_config || coalesce(jsonb_build_object('notify_via', v_notify), '{}'::jsonb), '[]'::jsonb",
     "p.trigger_config || case when v_notify is null then '{}'::jsonb else jsonb_build_object('notify_via', v_notify) end, '[]'::jsonb"),
    ("trigger_config = a.trigger_config || coalesce(jsonb_build_object('notify_via', v_notify), '{}'::jsonb),",
     "trigger_config = a.trigger_config || case when v_notify is null then '{}'::jsonb else jsonb_build_object('notify_via', v_notify) end,"),
  ]),
  ("public.zella_answer_knowledge_gap(uuid,text,text,text)", [
    ("case when p_kind in ('faq','service','policy','hours','other') then p_kind else 'faq' end",
     "case when p_kind in ('faq','service','policy','hours','other','product','price') then p_kind else 'faq' end"),
  ]),
  ("public.zella_flag_unrecorded_appointments()", [
    ("    perform public.zella_create_task(a.business_id, a.customer_id, 'record_attendance', 'Did ' || v_who || ' come in? Mark completed or no-show', 'The appointment ended and nothing was recorded.', 'normal', now() + interval '1 day', a.assigned_to, 'automation', a.id);\n    n := n + 1;",
     "    begin   -- one appointment that can't get its task doesn't stop the others\n"
     "      perform public.zella_create_task(a.business_id, a.customer_id, 'record_attendance', 'Did ' || v_who || ' come in? Mark completed or no-show', 'The appointment ended and nothing was recorded.', 'normal', now() + interval '1 day', a.assigned_to, 'automation', a.id);\n"
     "      n := n + 1;\n"
     "    exception when others then\n"
     "      raise warning 'zella_flag_unrecorded_appointments: appointment % skipped: %', a.id, sqlerrm;\n"
     "    end;"),
  ]),
  ("public.zella_check_engine_health()", [
    ("  for q in\n    select * from (values", "  for q in select id from public.calendar_sync_queue where status = 'in_progress' and attempts >= 5\n"
     "    and claimed_at < now() - interval '30 minutes' for update skip locked loop\n"
     "    perform public.zella_finish_calendar_sync(q.id, false, null, 'interrupted');\n"
     "  end loop;\n"
     "  update public.calendar_sync_queue set status = 'pending', error = 'interrupted', due_at = now()\n"
     "    where status = 'in_progress' and attempts < 5 and claimed_at < now() - interval '30 minutes';\n"
     "  for q in\n    select * from (values"),
    ("begin\n  update public.followup_tasks", "begin\n  for q in select id from public.automation_events\n    where status = 'processing' and attempts >= 5 and claimed_at < now() - interval '10 minutes'\n    for update skip locked loop\n    perform public.zella_complete_event(q.id, false, 'provider_timeout', 'Execution interrupted at final attempt');\n  end loop;\n  update public.followup_tasks"),
    ("  update public.followup_tasks set status = 'pending', due_at = now(), updated_at = now()\n   where status = 'in_progress' and channel in ('sms', 'email') and claimed_at < now() - interval '30 minutes';",
     "  update public.followup_tasks set status = 'failed', outcome = 'failed', outcome_notes = 'Stopped after the last attempt never finished.', completed_at = now(), updated_at = now()\n"
     "   where status = 'in_progress' and channel in ('sms', 'email') and claimed_at < now() - interval '30 minutes' and attempts >= max_attempts;\n"
     "  update public.followup_tasks set status = 'pending', due_at = now(), updated_at = now()\n"
     "   where status = 'in_progress' and channel in ('sms', 'email') and claimed_at < now() - interval '30 minutes' and attempts < max_attempts;"),
  ]),
  ("public.zella_decide_draft(uuid,text,text)", [
    ("v_body ~* '\\m(sale|discount|% off|offer ends|promo)\\M'",
     "(v_body ~* '\\m(sale|discount|offer ends|promo)\\M' or v_body ~* '%\\s*off\\M')"),
  ]),
  ("public.zella_calls_page(uuid,integer,text,text,text,uuid,text,date,date,timestamp with time zone,uuid)", [
    ("'kind', 'followup', 'due_at', t.due_at, 'done', t.status in ('completed', 'cancelled'))",
     "'kind', 'followup', 'due_at', t.due_at, 'done', t.status in ('done', 'cancelled'))"),
  ]),
  ("public.zella_inbox_previews(uuid,uuid[])", [
    ("coalesce(array_length(p_conversation_ids, 1), 0) > 100", "coalesce(cardinality(p_conversation_ids), 0) > 100"),
  ]),
  ("public.zella_ai_booking(text,uuid,text,jsonb)", [
    ("coalesce(nullif(v_args ->> 'duration_minutes', '')::integer, 30)",
     "case when (v_args ->> 'duration_minutes') ~ '^\\d{1,4}$' then (v_args ->> 'duration_minutes')::integer else 30 end"),
    ("coalesce(nullif(v_args ->> 'days', '')::integer, 3)",
     "case when (v_args ->> 'days') ~ '^\\d{1,3}$' then (v_args ->> 'days')::integer else 3 end"),
  ]),
  ("public.zella_today_operations(uuid)", [
    ("  v_end := v_start + interval '1 day';",
     "  v_end := (date_trunc('day', now() at time zone v_tz) + interval '1 day') at time zone v_tz;   -- 23 or 25 hours on DST days"),
  ]),
  ("public.zella_save_business_hours(uuid,jsonb)", [
    ("(a.v ->> 'weekday') = (b.v ->> 'weekday')", "(a.v ->> 'weekday')::int = (b.v ->> 'weekday')::int"),
  ]),
  ("public.zella_add_business_closure(uuid,date,date,text,time without time zone,time without time zone)", [
    ("jsonb_build_object('starts_on', p_starts_on, 'ends_on', p_ends_on, 'label', p_label)",
     "jsonb_build_object('starts_on', p_starts_on, 'ends_on', p_ends_on, 'label', coalesce(nullif(left(trim(coalesce(p_label, '')), 80), ''), 'Closed'))"),
  ]),
  ("public.zella_rebalance_assignments()", [
    ("from public.customers c join public.assignment_rules a on a.business_id = c.business_id and a.mode <> 'off'",
     "from public.customers c left join public.assignment_rules a on a.business_id = c.business_id\n     where coalesce(a.mode, 'round_robin') <> 'off' and"),
    ("     where c.assigned_to is null and c.lead_stage", "      c.assigned_to is null and c.lead_stage"),
    ("from public.callbacks b join public.assignment_rules a on a.business_id = b.business_id and a.mode <> 'off'",
     "from public.callbacks b left join public.assignment_rules a on a.business_id = b.business_id\n     where coalesce(a.mode, 'round_robin') <> 'off' and"),
    ("     where b.assigned_to is null and b.status not in", "      b.assigned_to is null and b.status not in"),
  ]),
  ("public.zella_record_status_touches_trg()", [
    ("and (x.trigger_config ->> 'type_key' is null or x.trigger_config ->> 'type_key' = new.type_key) loop",
     "and (x.trigger_config ->> 'type_key' is null or x.trigger_config ->> 'type_key' = new.type_key)\n"
     "                and nullif(trim(x.trigger_config -> 'messages' ->> new.status), '') is not null\n"
     "              order by (x.trigger_config ->> 'type_key') is null, x.created_at, x.id limit 1 loop   -- one message per change"),
  ]),
  ("public.zella_queue_customer_touches()", [
    ("v_days := greatest(7, coalesce((a.trigger_config ->> 'days')::integer, 180));",
     "v_days := greatest(7, case when (a.trigger_config ->> 'days') ~ '^\\d{1,4}$' then (a.trigger_config ->> 'days')::integer else 180 end);"),
  ]),
  ("public.zella_apply_industry_automations(uuid)", [
    ("select p_business_id, p.name, p.description, p.trigger_type, 'active', p.trigger_config",
     "select p_business_id, p.name, p.description, p.trigger_type, case when p.industry_key = 'general' then 'paused' else 'active' end, p.trigger_config"),
  ]),
  ("public.zella_claim_events(integer)", [
    ("begin\n  return query", "declare q record;\nbegin\n  for q in select id from public.automation_events\n    where status = 'processing' and attempts >= 5 and claimed_at < now() - interval '10 minutes'\n    for update skip locked loop\n    perform public.zella_complete_event(q.id, false, 'provider_timeout', 'Execution interrupted at final attempt');\n  end loop;\n  return query"),
    ("        or (status = 'processing' and claimed_at < now() - interval '10 minutes')",
     "        or (status = 'processing' and claimed_at < now() - interval '10 minutes' and attempts < 5)"),
  ]),
  ("public.zella_complete_event(uuid,boolean,text,text)", [
    ("  if not found then raise exception 'NOT_FOUND'; end if;\n",
     "  if not found then raise exception 'NOT_FOUND'; end if;\n"
     "  if e.status <> 'processing' then return 'ignored'; end if;   -- finished already, or reclaimed and finished by another run\n"),
  ]),
  ("public.zella_claim_admin_alert_email(integer)", [
    ("    update public.platform_alerts a set notified_at = now()\n",
     "    update public.platform_alerts a set notified_at = now(),\n"
     "           meta = coalesce(a.meta, '{}'::jsonb) || jsonb_build_object('email_claimed_at', now())\n"
     "                  || case when a.notified_at is null then '{}'::jsonb\n"
     "                          else jsonb_build_object('email_attempts', coalesce((a.meta ->> 'email_attempts')::int, 0) + 1) end\n"),
    ("                   where s.notified_at is null and s.status = 'open'\n",
     "                   where s.status = 'open'\n"
     "                     and (s.notified_at is null\n"
     "                          -- claimed by this version, never finished (no emailed_at), retried at most 3 times in all\n"
     "                          or (s.meta ? 'email_claimed_at' and not s.meta ? 'emailed_at' and s.notified_at < now() - interval '15 minutes'\n"
     "                              and coalesce((s.meta ->> 'email_attempts')::int, 0) < 2))\n"),
  ]),
  ("public.zella_queue_calendar_sync()", [
    ("    if new.external_event_id is null then return new; end if;",
     "    if new.external_event_id is null then   -- never reached the calendar: drop its pending upload\n"
     "      update public.calendar_sync_queue set status = 'skipped', error = 'cancelled_before_sync', completed_at = now() where appointment_id = new.id and status = 'pending';\n"
     "      return new;\n"
     "    end if;"),
  ]),
  ("public.zella_claim_calendar_sync(integer)", [
    ("  if not public.zella_calendar_live() then return v_res; end if;\n",
     "  if not public.zella_calendar_live() then return v_res; end if;\n"
     "  -- interrupted claims are retried through n8n marker reconciliation before any calendar create\n"
     "  update public.calendar_sync_queue set status = 'pending', error = 'interrupted', due_at = now()\n"
     "   where status = 'in_progress' and attempts < 5 and claimed_at < now() - interval '30 minutes';\n"),
  ]),
  ("public.zella_finish_calendar_sync(uuid,boolean,text,text)", [
    ("update public.calendar_connections set last_pushed_at = now(), last_error = null where business_id = q.business_id and provider = 'google';",
     "update public.calendar_connections set last_pushed_at = now(), last_error = null where business_id = q.business_id and status = 'active';"),
    ("update public.calendar_connections set last_error = left(p_error, 300) where business_id = q.business_id and provider = 'google';",
     "update public.calendar_connections set last_error = left(p_error, 300) where business_id = q.business_id and status = 'active';"),
    ("'Zella could not copy a booking to Google Calendar. The booking itself is saved.",
     "'Zella could not copy a booking to your calendar. The booking itself is saved."),
    ("'A booking could not be copied to Google Calendar'", "'A booking could not be copied to the business calendar'"),
  ]),
  ("public.zella_replace_calendar_busy(uuid,jsonb)", [
    ("  if jsonb_typeof(p_events) <> 'array' then raise exception 'BAD_EVENTS'; end if;\n",
     "  if jsonb_typeof(p_events) <> 'array' then raise exception 'BAD_EVENTS'; end if;\n"
     "  -- refused before anything is removed: keeping only the first 500 would drop real busy times\n"
     "  if jsonb_array_length(p_events) > 500 then raise exception 'TOO_MANY_EVENTS' using hint = 'More than 500 busy times in the window; nothing was changed.'; end if;\n"),
    ("from jsonb_array_elements(p_events) limit 500 loop", "from jsonb_array_elements(p_events) loop"),
    ("'Busy (Google Calendar)'", "case when c.provider = 'outlook' then 'Busy (Outlook calendar)' else 'Busy (Google Calendar)' end"),
  ]),
]

# admin lists: id breaks ties
for fn, inner, outer in [
    ("zella_admin_numbers", "(select * from f order by created_at desc limit v_lim", None),
    ("zella_admin_calls", "(select * from f order by created_at desc limit v_lim", "'needs_human', f.needs_human) order by f.created_at desc)"),
    ("zella_admin_automations", "(select * from f order by business_name, name limit v_lim", "          order by f.business_name, f.name)"),
    ("zella_admin_runs", "(select * from f order by started_at desc limit v_lim", "'needs_manual', f.needs_manual) order by f.started_at desc)"),
    ("zella_admin_templates", "(select * from f order by key, channel limit v_lim", "          order by f.key, f.channel, f.industry_name nulls first)"),
]:
    reps = [(inner, inner.replace(" limit v_lim", ", id limit v_lim"))]
    if outer:
        reps.append((outer, outer.replace(" desc)", " desc, f.id)").replace(" nulls first)", " nulls first, f.id)") if "desc)" in outer or "nulls first)" in outer else outer[:-1] + ", f.id)"))
    FUNCS.append((fn, reps))


# CodeRabbit's autofix on review-only PR #38 (10 Nov, 20:14): the fixes it made that this migration did not have yet.
# Each pair is CodeRabbit's edit to the applied migration, applied here to the live definition instead (DB-7).
FUNCS.append(('zella_admin_messages', [
    ("          'to', public.zella_admin_mask(g.to_number), 'from', public.zella_admin_mask(g.from_number), 'kind', g.kind,\n          'provider_id', g.external_message_id, 'conversation_id', g.conversation_id, 'sent_at', g.sent_at, 'delivered_at', g.delivered_at,\n          'error', left(coalesce(g.metadata ->> 'error', g.metadata ->> 'failure_reason'), 160)) order by g.created_at desc)\n        from (select * from g order by created_at desc limit v_lim offset greatest(coalesce(p_offset, 0), 0)) g join public.businesses b on b.id = g.business_id), '[]'::jsonb)));\n  elsif p_channel = 'email' then\n    return (with f as (",
     "          'to', public.zella_admin_mask(g.to_number), 'from', public.zella_admin_mask(g.from_number), 'kind', g.kind,\n          'provider_id', g.external_message_id, 'conversation_id', g.conversation_id, 'sent_at', g.sent_at, 'delivered_at', g.delivered_at,\n          'error', left(coalesce(g.metadata ->> 'error', g.metadata ->> 'failure_reason'), 160)) order by g.created_at desc, g.id)\n        from (select * from g order by created_at desc, id limit v_lim offset greatest(coalesce(p_offset, 0), 0)) g join public.businesses b on b.id = g.business_id), '[]'::jsonb)));\n  elsif p_channel = 'email' then\n    return (with f as ("),
    ("          'provider_id', g.external_message_id, 'sent_at', g.sent_at, 'delivered_at', g.delivered_at,\n          'last_event', (select ev.type from public.email_events ev where ev.email_message_id = g.id order by ev.created_at desc limit 1),\n          'error', left(coalesce(g.metadata ->> 'error', g.metadata ->> 'failure_reason'), 160)) order by g.created_at desc)\n        from (select * from g order by created_at desc limit v_lim offset greatest(coalesce(p_offset, 0), 0)) g join public.businesses b on b.id = g.business_id), '[]'::jsonb)));\n  end if;\n  raise exception 'INVALID_CHANNEL';",
     "          'provider_id', g.external_message_id, 'sent_at', g.sent_at, 'delivered_at', g.delivered_at,\n          'last_event', (select ev.type from public.email_events ev where ev.email_message_id = g.id order by ev.created_at desc limit 1),\n          'error', left(coalesce(g.metadata ->> 'error', g.metadata ->> 'failure_reason'), 160)) order by g.created_at desc, g.id)\n        from (select * from g order by created_at desc, id limit v_lim offset greatest(coalesce(p_offset, 0), 0)) g join public.businesses b on b.id = g.business_id), '[]'::jsonb)));\n  end if;\n  raise exception 'INVALID_CHANNEL';"),
]))
FUNCS.append(('zella_config_migration_restore', [
    ("    insert into business_languages select * from jsonb_populate_record(null::business_languages, s.languages);\n  end if;\n  update ai_agent_configs set escalation_rules = s.escalation_rules, updated_at = now() where agent_id = v_agent;\n  update knowledge_items set status = 'archived', updated_at = now()\n   where business_id = s.business_id and source_key like 'setup:%' and source_page_id is null",
     "    insert into business_languages select * from jsonb_populate_record(null::business_languages, s.languages);\n  end if;\n  if s.applied ? 'transfer_number' then\n    update ai_agent_configs\n       set escalation_rules = (coalesce(escalation_rules, '{}'::jsonb) - 'transfer_number' - 'transfer_number_source')\n             || (select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)\n                   from jsonb_each(coalesce(s.escalation_rules, '{}'::jsonb))\n                  where key in ('transfer_number', 'transfer_number_source')),\n           updated_at = now()\n     where agent_id = v_agent;\n  end if;\n  update knowledge_items set status = 'archived', updated_at = now()\n   where business_id = s.business_id and source_key like 'setup:%' and source_page_id is null"),
]))
FUNCS.append(('zella_dispatch_n8n', [
    ('declare\n  v_base text := nullif(trim(public.zella_setting(\'n8n_base_url\', \'""\'::jsonb) #>> \'{}\'), \'\');\n  v_on boolean := coalesce(public.zella_setting(\'n8n_dispatch_enabled\', \'true\'::jsonb) = \'true\'::jsonb, true);\n  v_secret text; w record; n integer; st public.n8n_dispatch_state; v_same integer; v_res jsonb := \'{}\'::jsonb; v_spam integer := 0; v_reconcile integer := 0; v_reviews integer := 0;\n  v_text_kinds text[] := array[\'no_show_follow_up\', \'post_appointment_follow_up\', \'quote_follow_up\', \'lead_reactivation\', \'callback_sms\', \'welcome_new_customer\', \'feedback_request\', \'cancellation_confirmation\', \'record_status_update\', \'service_due\', \'no_response_follow_up\', \'reschedule_confirmation\', \'booking_follow_up\', \'service_completed\', \'lead_follow_up\', \'lead_final_follow_up\', \'reply_confirmed\', \'reply_reschedule\', \'reply_help\', \'waitlist_offer\', \'cross_sell\'];',
     'declare\n  v_base text := nullif(trim(public.zella_setting(\'n8n_base_url\', \'""\'::jsonb) #>> \'{}\'), \'\');\n  v_on boolean := coalesce(public.zella_setting(\'n8n_dispatch_enabled\', \'false\'::jsonb) = \'true\'::jsonb, false);\n  v_secret text; w record; n integer; st public.n8n_dispatch_state; v_same integer; v_res jsonb := \'{}\'::jsonb; v_spam integer := 0; v_reconcile integer := 0; v_reviews integer := 0;\n  v_text_kinds text[] := array[\'no_show_follow_up\', \'post_appointment_follow_up\', \'quote_follow_up\', \'lead_reactivation\', \'callback_sms\', \'welcome_new_customer\', \'feedback_request\', \'cancellation_confirmation\', \'record_status_update\', \'service_due\', \'no_response_follow_up\', \'reschedule_confirmation\', \'booking_follow_up\', \'service_completed\', \'lead_follow_up\', \'lead_final_follow_up\', \'reply_confirmed\', \'reply_reschedule\', \'reply_help\', \'waitlist_offer\', \'cross_sell\'];'),
    ('      when \'admin-alerts\' then case when coalesce(public.zella_setting(\'email_live\', \'false\'::jsonb) = \'true\'::jsonb, false)\n                                     and nullif(trim(public.zella_setting(\'email_from_address\', \'""\'::jsonb) #>> \'{}\'), \'\') is not null\n         then (select count(*) from public.platform_alerts where notified_at is null and status = \'open\') else 0 end\n      when \'spam-response\' then coalesce(v_spam, 0)\n      when \'call-reconcile\' then coalesce(v_reconcile, 0)',
     '      when \'admin-alerts\' then case when coalesce(public.zella_setting(\'email_live\', \'false\'::jsonb) = \'true\'::jsonb, false)\n                                     and nullif(trim(public.zella_setting(\'email_from_address\', \'""\'::jsonb) #>> \'{}\'), \'\') is not null\n         then (select count(*) from public.platform_alerts s where s.status = \'open\' and (s.notified_at is null or s.notified_at < now() - interval \'15 minutes\')\n                     and s.meta ->> \'emailed_at\' is null and coalesce((s.meta ->> \'email_attempts\')::int, 0) < 3) else 0 end\n      when \'spam-response\' then coalesce(v_spam, 0)\n      when \'call-reconcile\' then coalesce(v_reconcile, 0)'),
]))
FUNCS.append(('zella_platform_admin_email_check', [
    ("  if not new.is_active then return new; end if;\n  if tg_op = 'UPDATE' and old.is_active and old.user_id = new.user_id then return new; end if;   -- unchanged grant\n  select email_confirmed_at, last_sign_in_at into u from auth.users where id = new.user_id;\n  if not found then raise exception 'ADMIN_ACCOUNT_NOT_FOUND' using errcode = '23503'; end if;\n  if u.email_confirmed_at is null and u.last_sign_in_at is not null then\n    raise exception 'ADMIN_EMAIL_NOT_CONFIRMED' using errcode = '42501',\n      hint = 'This account''s email address was never confirmed, so it can''t be made an admin.';",
     "  if not new.is_active then return new; end if;\n  if tg_op = 'UPDATE' and old.is_active and old.user_id = new.user_id then return new; end if;   -- unchanged grant\n  select email, invited_at, last_sign_in_at into u from auth.users where id = new.user_id;\n  if not found then raise exception 'ADMIN_ACCOUNT_NOT_FOUND' using errcode = '23503'; end if;\n  if not exists (select 1 from auth.identities i where i.user_id = new.user_id\n       and lower(i.identity_data ->> 'email') = lower(u.email)\n       and i.identity_data -> 'email_verified' = 'true'::jsonb)\n     and not (u.invited_at is not null and u.last_sign_in_at is null) then\n    raise exception 'ADMIN_EMAIL_NOT_CONFIRMED' using errcode = '42501',\n      hint = 'This account''s email address was never confirmed, so it can''t be made an admin.';"),
]))


# CodeRabbit's autofix on review-only PR #41 (SQL part 2, e082ea1), in its order, applied to the live definitions (DB-7).
# Already fixed in production, so not repeated: the lead pipeline role checks (zella_can_edit), the null-user bypass in
# zella_has_role, and zella_accept_staff_invitations (no longer exists).
FUNCS.append(('zella_offer_redeem_core', [
    ("  if p_key is null or length(p_key) < 8 then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;\n  select * into r from public.offer_redemptions where idempotency_key = p_key;",
     "  if p_key is null or length(p_key) < 8 then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;\n  -- one redemption at a time per key, so two simultaneous requests cannot both pass the lookup\n  perform pg_advisory_xact_lock(hashtextextended(p_key, 0));\n  select * into r from public.offer_redemptions where idempotency_key = p_key;"),
]))
FUNCS.append(('zella_reassign_callback', [
    ("  if p_to_user is not null and not exists (select 1 from public.business_members m where m.business_id = cb.business_id and m.user_id = p_to_user and m.status = 'active') then raise exception 'TARGET_NOT_ACTIVE'; end if;\n  update public.callbacks set assigned_to = p_to_user, updated_at = now() where id = p_callback_id and status not in ('completed','cancelled');\n  if p_to_user is not null then\n    perform public.zella_notify(cb.business_id, 'callback', 'A callback was assigned to you', coalesce(cb.summary, 'Please call them back.'), 'info', 'callbacks', cb.id, p_to_user);",
     "  if p_to_user is not null and not exists (select 1 from public.business_members m where m.business_id = cb.business_id and m.user_id = p_to_user and m.status = 'active') then raise exception 'TARGET_NOT_ACTIVE'; end if;\n  update public.callbacks set assigned_to = p_to_user, updated_at = now() where id = p_callback_id and status not in ('completed','cancelled');\n  if not found then return 'closed'; end if;\n  if p_to_user is not null then\n    perform public.zella_notify(cb.business_id, 'callback', 'A callback was assigned to you', coalesce(cb.summary, 'Please call them back.'), 'info', 'callbacks', cb.id, p_to_user);"),
]))
FUNCS.append(('zella_erase_customer', [
    ("begin\n  if not public.zella_has_role(p_business_id, array['owner','admin']) then raise exception 'NOT_ALLOWED'; end if;",
     "declare v_column text;\nbegin\n  if not public.zella_has_role(p_business_id, array['owner','admin']) then raise exception 'NOT_ALLOWED'; end if;"),
    ("  update public.calls set transcript = null, recording_url = null, summary = null, from_number = null, to_number = null where customer_id = p_customer_id and business_id = p_business_id;\n  update public.callbacks set contact_number = null, summary = null, note = null where customer_id = p_customer_id and business_id = p_business_id;\n  update public.followup_tasks set status = 'cancelled', updated_at = now() where customer_id = p_customer_id and business_id = p_business_id and status in ('pending','in_progress');\n  update public.customers set first_name = 'Deleted', last_name = null, phone = null, email = null, address = null, notes = null, date_of_birth = null, company_name = null,",
     "  update public.calls set transcript = null, recording_url = null, summary = null, from_number = null, to_number = null where customer_id = p_customer_id and business_id = p_business_id;\n  update public.callbacks set contact_number = null, summary = null, note = null where customer_id = p_customer_id and business_id = p_business_id;\n  update public.appointments set description = null where customer_id = p_customer_id and business_id = p_business_id;\n  update public.crm_tasks set title = '[removed]', body = null where customer_id = p_customer_id and business_id = p_business_id;\n  -- The base customer_requests DDL is external to this migration set. Scrub its\n  -- descriptive fields when present without changing workflow keys or links.\n  for v_column in select column_name from information_schema.columns\n    where table_schema = 'public' and table_name = 'customer_requests'\n      and column_name in ('title','subject','description','summary','body','notes','details','metadata','resolution','contact_name','contact_email','contact_phone')\n  loop\n    execute format('update public.customer_requests set %I = %s where customer_id = $1 and business_id = $2',\n      v_column, case when v_column in ('details','metadata') then quote_literal('{}') else quote_literal('[removed]') end)\n      using p_customer_id, p_business_id;\n  end loop;\n  -- Consent history is append-only (docs/ARCHITECTURE.md section 7.2). Keep\n  -- phone_digits and email_lower for all channels/purposes: SMS opt-out readers\n  -- match phone_digits and voice checks use the latest consent by that number.\n  -- Do not erase/rewrite history or suppression identifiers when the profile is cleared.\n  update public.followup_tasks set status = 'cancelled', updated_at = now() where customer_id = p_customer_id and business_id = p_business_id and status in ('pending','in_progress');\n  update public.customers set first_name = 'Deleted', last_name = null, phone = null, email = null, address = null, notes = null, date_of_birth = null, company_name = null,"),
]))
FUNCS.append(('zella_language_allowance', [
    ('declare s public.subscriptions; v text;\nbegin\n  s := public.zella_current_subscription(p_business_id);\n  if s.id is null then return null; end if;',
     "declare s public.subscriptions; v text;\nbegin\n  if not public.zella_has_role(p_business_id, array['owner','admin','manager','staff','viewer']) then raise exception 'NOT_ALLOWED'; end if;\n  s := public.zella_current_subscription(p_business_id);\n  if s.id is null then return null; end if;"),
]))
FUNCS.append(('zella_decide_time_off', [
    ("declare r public.time_off_requests%rowtype; v_name text; v_block uuid;\nbegin\n  select * into r from public.time_off_requests where id = p_request_id;\n  if not found or not public.zella_can_manage(r.business_id) then raise exception 'NOT_ALLOWED'; end if;\n  if r.status <> 'pending' then raise exception 'ALREADY_DECIDED'; end if;",
     "declare r public.time_off_requests%rowtype; v_name text; v_block uuid;\nbegin\n  select * into r from public.time_off_requests where id = p_request_id for update;\n  if not found or not public.zella_can_manage(r.business_id) then raise exception 'NOT_ALLOWED'; end if;\n  if r.status <> 'pending' then raise exception 'ALREADY_DECIDED'; end if;"),
]))
FUNCS.append(('zella_offboard_member', [
    ("  select role into v_role from public.business_members where business_id = p_business_id and user_id = p_user_id;\n  if v_role is null then raise exception 'NOT_A_MEMBER'; end if;\n  if v_role = 'owner' and not exists (select 1 from public.business_members m where m.business_id = p_business_id and m.role = 'owner' and m.status = 'active' and m.user_id <> p_user_id) then\n    raise exception 'LAST_OWNER';",
     "  select role into v_role from public.business_members where business_id = p_business_id and user_id = p_user_id;\n  if v_role is null then raise exception 'NOT_A_MEMBER'; end if;\n  if auth.uid() is not null and v_role in ('owner','admin')\n     and not exists (select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = auth.uid() and m.status = 'active' and m.role = 'owner') then\n    raise exception 'NOT_ALLOWED';\n  end if;\n  if p_reassign_to is not null and (p_reassign_to = p_user_id or not exists (\n    select 1 from public.business_members m where m.business_id = p_business_id and m.user_id = p_reassign_to and m.status = 'active')) then\n    raise exception 'TARGET_NOT_ACTIVE';\n  end if;\n  if v_role = 'owner' and not exists (select 1 from public.business_members m where m.business_id = p_business_id and m.role = 'owner' and m.status = 'active' and m.user_id <> p_user_id) then\n    raise exception 'LAST_OWNER';"),
]))
FUNCS.append(('zella_public_status', [
    ("  end loop;\n\n  select coalesce(jsonb_agg(jsonb_build_object('title', i.title, 'message', i.public_message, 'status', i.status, 'component', i.component,\n           'started_at', i.created_at, 'resolved_at', i.resolved_at) order by (i.status = 'open') desc, i.created_at desc), '[]'::jsonb) into v_incidents\n    from (select * from public.platform_incidents where is_public and (status = 'open' or resolved_at > now() - interval '14 days')",
     "  end loop;\n\n  select coalesce(jsonb_agg(jsonb_build_object('message', i.public_message, 'status', i.status, 'component', i.component,\n           'started_at', i.created_at, 'resolved_at', i.resolved_at) order by (i.status = 'open') desc, i.created_at desc), '[]'::jsonb) into v_incidents\n    from (select * from public.platform_incidents where is_public and (status = 'open' or resolved_at > now() - interval '14 days')"),
]))
FUNCS.append(('zella_check_uptime', [
    ("  select max(checked_at) into v_last from public.provider_health;\n  select min(updated_at) into v_since from public.platform_settings where key = 'provider_checks_live';\n  if public.zella_provider_checks_live() and coalesce(v_last, v_since, now()) < now() - interval '6 hours' then\n    perform public.zella_platform_alert('automation_heartbeat', 'The automation engine looks down',\n      'No connection check has come back for 6 hours (last: ' || coalesce(to_char(v_last at time zone 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', 'never')",
     "  select max(checked_at) into v_last from public.provider_health;\n  select min(updated_at) into v_since from public.platform_settings where key = 'provider_checks_live';\n  if public.zella_provider_checks_live() and coalesce(greatest(v_last, v_since), now()) < now() - interval '6 hours' then\n    perform public.zella_platform_alert('automation_heartbeat', 'The automation engine looks down',\n      'No connection check has come back for 6 hours (last: ' || coalesce(to_char(v_last at time zone 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', 'never')"),
]))


# CodeRabbit's autofix on #38, policy and email-proof fixes not in production yet
FUNCS.append(("zella_session_proved_email", [
    (" STABLE\n SET search_path TO ''", " STABLE SECURITY DEFINER\n SET search_path TO ''", "header"),
    ("  select coalesce((select bool_or(m ->> 'method' in ('otp', 'magiclink', 'invite', 'recovery', 'email/signup', 'email_change'))\n                     from jsonb_array_elements(case when jsonb_typeof(auth.jwt() -> 'amr') = 'array' then auth.jwt() -> 'amr' else '[]'::jsonb end) m), false);",
     "  -- the session must have signed in by email (link, or emailed code: the app has no phone sign-in), on this\n  -- account's current address, with an email identity the auth provider verified\n  select exists (\n    select 1 from auth.users u\n    join auth.sessions s on s.user_id = u.id and s.id::text = auth.jwt() ->> 'session_id'\n    where u.id = auth.uid() and lower(u.email) = lower(auth.jwt() ->> 'email')\n      and exists (select 1 from auth.identities i where i.user_id = u.id\n        and lower(i.identity_data ->> 'email') = lower(u.email)\n        and i.identity_data -> 'email_verified' = 'true'::jsonb)\n      and exists (select 1 from jsonb_array_elements(\n        case when jsonb_typeof(auth.jwt() -> 'amr') = 'array' then auth.jwt() -> 'amr' else '[]'::jsonb end) m\n        where m ->> 'method' in ('otp', 'magiclink', 'invite', 'recovery', 'email/signup', 'email_change'))\n  );"),
]))


# CodeRabbit security audit (PR #42 comment, 10 Nov): tenant isolation in the database
FUNCS.append(("zella_record_email_event", [
    ("""    if v_to is not null then
      for v_cust in
        update public.customers c set do_not_email = true, email_suppressed_at = now(), email_suppressed_reason = 'bounced', updated_at = now()
         where lower(c.email) = v_to and not coalesce(c.do_not_email, false)""",
     """    -- only the business that sent the message (NN-1, TEN-3); a bounce that matches no message changes no customer
    if v_msg.id is not null and v_to is not null then
      for v_cust in
        update public.customers c set do_not_email = true, email_suppressed_at = now(), email_suppressed_reason = 'bounced', updated_at = now()
         where c.business_id = v_msg.business_id and lower(c.email) = v_to and not coalesce(c.do_not_email, false)"""),
]))
FUNCS.append(("zella_business_currency", [
    ("  from public.businesses b where b.id = p_business_id;",
     "  from public.businesses b where b.id = p_business_id\n"
     "    -- members of that business only; server code (no signed-in user) as before\n"
     "    and (auth.uid() is null or public.is_business_member(p_business_id));"),
]))

# CodeRabbit's order (finding number on PR #38, first finding = 0): each function is written in the order of its
# first finding, so the migration reads in the same order as the review.
ORDER = {"zella_claim_admin_alert_email": 0, "zella_admin_routing_save": 1, "zella_admin_message_detail": 2,
  "zella_admin_template_variables": 3, "zella_admin_numbers": 4.1, "zella_admin_calls": 4.2, "zella_admin_automations": 4.3,
  "zella_admin_runs": 4.4, "zella_admin_templates": 4.5, "zella_set_industry_rules": 7, "zella_answer_knowledge_gap": 12,
  "zella_knowledge_guard": 13, "zella_capture_web_lead": 14, "zella_ai_booking": 16, "zella_flag_unrecorded_appointments": 18,
  "zella_rebalance_assignments": 23, "zella_save_business_hours": 31, "zella_add_business_closure": 32,
  "zella_finish_calendar_sync": 33.1, "zella_calendar_connect_provider": 33.2, "zella_queue_calendar_sync": 34,
  "zella_claim_calendar_sync": 36, "zella_replace_calendar_busy": 38, "zella_sensitive_industry": 39,
  "zella_today_operations": 42, "zella_merge_customers": 47, "zella_log_customer_request": 50,
  "zella_update_customer_request": 51, "zella_record_status_touches_trg": 52, "zella_queue_customer_touches": 53,
  "zella_check_engine_health": 62, "zella_ai_voice": 64, "zella_complete_followup_task": 65, "zella_claim_reminders": 67,
  "zella_permission_check": 71, "zella_apply_industry_automations": 72, "zella_decide_draft": 73, "zella_claim_events": 75.1,
  "zella_complete_event": 75.2, "zella_record_consent": 76, "zella_calls_page": 77, "zella_inbox_previews": 78,
  # second pass (CodeRabbit's autofix on #38), in its commit order
  "zella_admin_messages": 100.1, "zella_config_migration_restore": 100.2, "zella_dispatch_n8n": 100.3,
  "zella_platform_admin_email_check": 100.4, "zella_session_proved_email": 100.5,
  # CodeRabbit security audit on PR #42, in its order
  "zella_record_email_event": 300.2, "zella_business_currency": 300.7,
  # PR #41 (SQL part 2), in its order
  "zella_offer_redeem_core": 200.1, "zella_reassign_callback": 200.2, "zella_erase_customer": 200.3, "zella_language_allowance": 200.4,
  "zella_decide_time_off": 200.5, "zella_offboard_member": 200.6, "zella_public_status": 200.7, "zella_check_uptime": 200.8}
_name = lambda sig: sig.replace("public.", "").split("(")[0]
missing = [s for s, _ in FUNCS if _name(s) not in ORDER]
assert not missing, missing
FUNCS.sort(key=lambda f: ORDER[_name(f[0])])

EXTRA_UP = """
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
"""

EXTRA_DOWN = """
alter policy call_insights_read on public.call_insights using (public.zella_is_member(business_id));
-- #8: the dental reminder wording as it was
update public.message_templates t set body = replace(t.body, 'a reminder of your appointment at', 'a reminder of your {{appointment}} at')
 where t.business_id is null and t.key = 'appointment_reminder' and t.status = 'active'
   and t.industry_id in (select id from public.industries where slug = 'dental') and t.body like '%a reminder of your appointment at%';
-- the legacy connect function, exactly as it was (service role only)
CREATE OR REPLACE FUNCTION public.zella_calendar_connect(p_business_id uuid, p_account_email text, p_refresh_token text, p_calendar_id text DEFAULT 'primary'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'vault'
AS $function$
declare v_name text := 'zella_gcal_' || p_business_id::text; v_id uuid;
begin
  if not exists (select 1 from public.businesses where id = p_business_id and suspended_at is null and cancelled_at is null) then raise exception 'BUSINESS_NOT_AVAILABLE'; end if;
  if nullif(trim(coalesce(p_refresh_token, '')), '') is null then raise exception 'NO_TOKEN'; end if;
  if exists (select 1 from vault.secrets where name = v_name) then
    perform vault.update_secret((select id from vault.secrets where name = v_name), p_refresh_token);
  else
    perform vault.create_secret(p_refresh_token, v_name);
  end if;
  insert into public.calendar_connections (business_id, provider, status, calendar_id, account_email, vault_secret_name, busy_refresh_due_at, last_error)
  values (p_business_id, 'google', 'active', coalesce(nullif(trim(p_calendar_id), ''), 'primary'), left(p_account_email, 200), v_name, now(), null)
  on conflict (business_id, provider) do update set status = 'active', calendar_id = excluded.calendar_id, account_email = excluded.account_email,
    vault_secret_name = excluded.vault_secret_name, busy_refresh_due_at = now(), last_error = null
  returning id into v_id;
  return v_id;
end $function$;
revoke execute on function public.zella_calendar_connect(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.zella_calendar_connect(uuid, text, text, text) to service_role;
drop trigger if exists zella_audit_privileged_trg on public.platform_admins;
grant execute on function public.zella_booking_choices(uuid, timestamptz, timestamptz, integer, integer, integer) to authenticated;
grant execute on function public.zella_arrival_window(uuid) to authenticated;
grant execute on function public.zella_capability_on(uuid, text) to authenticated;
grant execute on function public.zella_cross_sell_ideas(text) to public;
"""
