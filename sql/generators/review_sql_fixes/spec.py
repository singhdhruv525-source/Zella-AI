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
--   * zella_claim_calendar_sync: an item stuck "in progress" for 30 minutes is marked failed (and the owner told by the
--     usual failure path on the next change) rather than left forever; it is not retried blindly, because the event may
--     already exist in the calendar.
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
     "    if v_why = 'emergency' and (v_call.id is null or not exists (select 1 from public.calls where id = v_call.id and escalation_reason = 'emergency')) then\n"
     "      return jsonb_build_object('ok', true, 'status', 'use_emergency',\n"
     "        'say', 'If this is an emergency, use the emergency action first. Otherwise ask why they need a person and try again with that reason.');\n"
     "    end if;\n"),
    ("        update public.calls set transfer_status = 'not_needed', escalation_reason = coalesce(escalation_reason, left(coalesce(v_why, 'asked_for_person'), 60)), updated_at = now() where id = v_call.id;",
     "        update public.calls set transfer_status = 'not_needed', escalation_reason = coalesce(escalation_reason, left(coalesce(v_why, 'asked_for_person'), 60)), updated_at = now()\n"
     "         where id = v_call.id and transfer_status is distinct from 'attempted';   -- an approved transfer stays approved"),
  ]),
  ("public.zella_calendar_connect_provider(uuid,text,uuid,text,text,text)", [
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
     "  -- a run that stopped half-way: fail it rather than retry blindly (the event may already be in the calendar)\n"
     "  update public.calendar_sync_queue set status = 'failed', error = 'interrupted', completed_at = now()\n"
     "   where status = 'in_progress' and claimed_at < now() - interval '30 minutes';\n"),
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
  "zella_complete_event": 75.2, "zella_record_consent": 76, "zella_calls_page": 77, "zella_inbox_previews": 78}
_name = lambda sig: sig.replace("public.", "").split("(")[0]
missing = [s for s, _ in FUNCS if _name(s) not in ORDER]
assert not missing, missing
FUNCS.sort(key=lambda f: ORDER[_name(f[0])])

EXTRA_UP = """
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
