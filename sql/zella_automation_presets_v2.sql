-- Starter automations for the new industry records (2026-11-04 industry work, batch 4).
-- Every one of these creates a task for the team. None sends anything to a customer, takes a payment or charges a fee.
-- New businesses get them switched on with the rest of their industry's starters; existing businesses see them in the
-- Automation library, switched off, until the owner turns them on. Needs zella_presets_v2.sql. Safe to run twice.

insert into public.industry_automation_presets (industry_key, name, description, trigger_type, trigger_config)
select v.industry_key, v.name, v.description, v.trigger_type, v.cfg::jsonb
  from (values
  ('legal', 'Deadline in 30 days', 'Tells the responsible attorney 30 days before a limitation or court deadline.', 'record_due_reminder',
   '{"type_key":"deadlines","due_field":"due","statuses":["open"],"before_hours":720,"rule":{"task":{"title":"Deadline in 30 days: {title}","priority":"high","due_hours":24}}}'),
  ('legal', 'Deadline in 7 days', 'Tells the responsible attorney 7 days before a deadline.', 'record_due_reminder',
   '{"type_key":"deadlines","due_field":"due","statuses":["open"],"before_hours":168,"rule":{"task":{"title":"Deadline in 7 days: {title}","priority":"urgent","due_hours":4}}}'),
  ('legal', 'Deadline tomorrow', 'Tells the responsible attorney the day before a deadline.', 'record_due_reminder',
   '{"type_key":"deadlines","due_field":"due","statuses":["open"],"before_hours":24,"rule":{"task":{"title":"Deadline tomorrow: {title}","priority":"urgent","due_hours":1}}}'),
  ('insurance', 'Policy renewal coming up', 'A task 30 days before a policy expires.', 'record_due_reminder',
   '{"type_key":"policies","due_field":"expires_on","statuses":["active","renewing"],"before_hours":720,"rule":{"task":{"title":"Renewal due: {title}","priority":"normal","due_hours":72}}}'),
  ('insurance', 'New claim not yet submitted', 'A claim still at first notice after a day.', 'record_stale',
   '{"type_key":"claims","status":"reported","after_days":1,"rule":{"task":{"title":"Submit claim to carrier: {title}","priority":"high","due_hours":4}}}'),
  ('insurance', 'Quote waiting for an answer', 'A quote sent 3 days ago with no decision.', 'record_stale',
   '{"type_key":"quotes","status":"quoted","after_days":3,"rule":{"task":{"title":"Follow up on quote: {title}","priority":"normal","due_hours":24}}}'),
  ('healthcare', 'Refill request waiting', 'A refill request not sent to the provider after 4 hours.', 'record_stale',
   '{"type_key":"refill_requests","status":"received","after_hours":4,"rule":{"task":{"title":"Send refill request to provider: {title}","priority":"high","due_hours":2}}}'),
  ('healthcare', 'Prior authorization pending', 'A prior authorization submitted 7 days ago with no decision.', 'record_stale',
   '{"type_key":"prior_auths","status":"submitted","after_days":7,"rule":{"task":{"title":"Chase prior authorization: {title}","priority":"normal","due_hours":24}}}'),
  ('dental', 'Treatment plan not accepted', 'A presented treatment plan with no decision after 7 days.', 'record_stale',
   '{"type_key":"treatment_plans","status":"presented","after_days":7,"rule":{"task":{"title":"Follow up on treatment plan: {title}","priority":"normal","due_hours":48}}}'),
  ('fitness', 'Freeze or cancellation request waiting', 'A request not handled after a day.', 'record_stale',
   '{"type_key":"freeze_requests","status":"requested","after_days":1,"rule":{"task":{"title":"Handle request: {title}","priority":"high","due_hours":8}}}'),
  ('childcare', 'Incident report still open', 'An incident report open after 4 hours.', 'record_stale',
   '{"type_key":"incidents","status":"open","after_hours":4,"rule":{"task":{"title":"Close incident report: {title}","priority":"urgent","due_hours":2}}}'),
  ('property_management', 'Vendor insurance expiring', 'A task 30 days before a vendor''s insurance expires.', 'record_due_reminder',
   '{"type_key":"vendors","due_field":"insurance_expires","statuses":["approved"],"before_hours":720,"rule":{"task":{"title":"Vendor insurance expiring: {title}","priority":"normal","due_hours":72}}}'),
  ('travel', 'Passport expiring', 'A task when a traveler''s passport is within 6 months of expiry.', 'record_due_reminder',
   '{"type_key":"documents","due_field":"passport_expires","before_hours":4380,"rule":{"task":{"title":"Passport expires within 6 months: {title}","priority":"high","due_hours":24}}}'),
  ('automotive', 'Declined work reminder', 'A task on the reminder date for declined repairs.', 'record_due_reminder',
   '{"type_key":"repair_orders","due_field":"remind_declined_on","include_closed":true,"rule":{"task":{"title":"Remind about declined work: {title}","priority":"normal","due_hours":48}}}'),
  ('cleaning', 'Visit not started', 'A cleaning visit still scheduled an hour after its time.', 'record_due_reminder',
   '{"type_key":"visits","due_field":"scheduled_for","statuses":["scheduled"],"after_hours":1,"rule":{"task":{"title":"Visit not started: {title}","priority":"high","due_hours":1}}}')
  ) v(industry_key, name, description, trigger_type, cfg)
 where not exists (select 1 from public.industry_automation_presets p where p.industry_key = v.industry_key and p.name = v.name);
