-- New industry automation presets, draft-mode presets for sensitive industries, and the restaurant walk-in waitlist and tables.
-- Messages follow the rules: no prices, no promotions, under 300 characters. Safe to run more than once.
-- Needs zella_automation_completion.sql first.

------------------------------------------------------------------ Restaurant: walk-in waitlist and tables
update public.industry_crm_presets
   set config = jsonb_set(config, '{types}', (config -> 'types') || jsonb_build_array(
     jsonb_build_object('key','waitlist','icon','hourglass_top','singular','Walk-in party','plural','Walk-in waitlist','title_label','Party name','link_person',true,
       'statuses', jsonb_build_array(
          jsonb_build_object('key','waiting','tone','warning','label','Waiting'),
          jsonb_build_object('key','notified','tone','info','label','Table ready'),
          jsonb_build_object('key','seated','tone','success','label','Seated'),
          jsonb_build_object('key','left','tone','','label','Left'),
          jsonb_build_object('key','no_show','tone','','label','Did not come back')),
       'closed_statuses', jsonb_build_array('seated','left','no_show'),
       'fields', jsonb_build_array(
          jsonb_build_object('key','party_size','type','number','label','Party size'),
          jsonb_build_object('key','quoted_minutes','type','number','label','Quoted wait (minutes)'),
          jsonb_build_object('key','seating','type','select','label','Seating','options', jsonb_build_array('No preference','Indoor','Outdoor','Bar')),
          jsonb_build_object('key','notes','type','longtext','label','Notes')),
       'columns', jsonb_build_array('party_size','quoted_minutes','seating')),
     jsonb_build_object('key','tables','icon','table_restaurant','singular','Table','plural','Tables','title_label','Table name','link_person',false,
       'statuses', jsonb_build_array(
          jsonb_build_object('key','free','tone','success','label','Free'),
          jsonb_build_object('key','occupied','tone','warning','label','Occupied'),
          jsonb_build_object('key','reserved','tone','info','label','Reserved'),
          jsonb_build_object('key','out_of_service','tone','','label','Out of service')),
       'closed_statuses', jsonb_build_array(),
       'fields', jsonb_build_array(
          jsonb_build_object('key','seats','type','number','label','Seats'),
          jsonb_build_object('key','area','type','select','label','Area','options', jsonb_build_array('Indoor','Outdoor','Bar','Private room')),
          jsonb_build_object('key','notes','type','longtext','label','Notes')),
       'columns', jsonb_build_array('seats','area'))
   )), updated_at = now()
 where key = 'restaurant' and not exists (select 1 from jsonb_array_elements(config -> 'types') x where x ->> 'key' = 'waitlist');

------------------------------------------------------------------ Presets
with p(industry_key, name, description, trigger_type, trigger_config) as (values
 -- shared
 ('general','Review request','Two days after a completed visit, ask for a review. Needs a review link in Settings; nothing is sent without one.','appointment_followup',
   '{"after_days":2,"rule":{"message":"Thanks for visiting. If you were happy with us, a short review helps a lot: {review_link} If anything was not right, reply here and we will put it right.","delay_minutes":1}}'::jsonb),
 -- restaurant
 ('restaurant','Table ready','Tell a walk-in party their table is ready.','record_status_action',
   '{"type_key":"waitlist","rules":[{"status":"notified","message":"Your table is ready. Please check in with the host.","delay_minutes":1}]}'::jsonb),
 ('restaurant','Walk-in waiting too long','Alert the team when a walk-in party has waited over an hour.','record_stale',
   '{"type_key":"waitlist","status":"waiting","after_hours":1,"rule":{"notify":{"title":"Walk-in waiting over an hour: {title}","body":"Check the waitlist.","severity":"warning"}}}'::jsonb),
 ('restaurant','Notified party not seated','Remind the team to release the table if a notified party has not come forward.','record_stale',
   '{"type_key":"waitlist","status":"notified","after_hours":1,"rule":{"task":{"title":"Party not seated, release the table: {title}","priority":"high","due_hours":1}}}'::jsonb),
 ('restaurant','Walk-in did not return','Close the loop when a party is marked as not returning.','record_status_action',
   '{"type_key":"waitlist","rules":[{"status":"no_show","task":{"title":"Walk-in did not return: {title}","body":"Check for a no-show pattern before holding tables for this party again.","priority":"normal","due_hours":24}}]}'::jsonb),
 -- spa
 ('spa_wellness','Membership renewal reminder','Remind members three days before renewal.','record_due_reminder',
   '{"type_key":"memberships","due_field":"renews","statuses":["active"],"before_hours":72,"rule":{"message":"Your membership renews in a few days. Reply here if you want to change anything.","delay_minutes":1}}'::jsonb),
 ('spa_wellness','Package used up','Offer help when the last session of a package is used.','record_status_action',
   '{"type_key":"packages","rules":[{"status":"used_up","message":"You have used your last session. Reply here if you would like to renew your package.","delay_minutes":60}]}'::jsonb),
 ('spa_wellness','Membership ended','Ask what could have been better when a membership ends.','record_status_action',
   '{"type_key":"memberships","rules":[{"status":"ended","task":{"title":"Follow up on ended membership: {title}","body":"Ask whether anything could have been better.","priority":"normal","due_hours":72}}]}'::jsonb),
 -- property management
 ('property_management','Lease ending soon','Chase a lease that is marked as ending and has not moved for a week.','record_stale',
   '{"type_key":"leases","status":"ending","after_days":7,"rule":{"task":{"title":"Lease ending, confirm move-out plans: {title}","priority":"high","due_hours":24}}}'::jsonb),
 ('property_management','Renewal due chase','Follow up when a renewal has been due for five days.','record_stale',
   '{"type_key":"leases","status":"renewal_due","after_days":5,"rule":{"task":{"title":"Renewal waiting: {title}","priority":"normal","due_hours":24}}}'::jsonb),
 ('property_management','Request still in progress','Update the tenant when a request has been in progress for three days.','record_stale',
   '{"type_key":"requests","status":"in_progress","after_days":3,"rule":{"message":"A quick update: we are still working on your request and will tell you as soon as it is done.","delay_minutes":1,"task":{"title":"Request in progress for 3 days: {title}","priority":"normal","due_hours":24}}}'::jsonb),
 ('property_management','Request scheduled','Tell the tenant when work has been scheduled.','record_status_action',
   '{"type_key":"requests","rules":[{"status":"scheduled","message":"Your maintenance request is scheduled. We will confirm the arrival time before we come.","delay_minutes":1}]}'::jsonb),
 -- beauty salon
 ('beauty_salon','Membership welcome','Welcome a new member.','record_status_action',
   '{"type_key":"memberships","rules":[{"status":"active","message":"Welcome. Your membership is active. Reply here if you have any questions.","delay_minutes":5}]}'::jsonb),
 ('beauty_salon','Long gap check-in','Check in with customers who have not visited for four months.','service_due',
   '{"days":120,"service":"appointment"}'::jsonb),
 -- childcare (drafts: a person reviews anything sent to a family)
 ('childcare','Tour follow-up','Draft a follow-up three days after a tour is booked and nothing has moved.','record_stale',
   '{"type_key":"enrolments","status":"tour_booked","after_days":3,"rule":{"mode":"draft","message":"Thank you for your interest. Do you have any questions about a tour or about spaces? Reply here and we will help.","delay_minutes":1}}'::jsonb),
 ('childcare','Enquiry not answered','Task when an enquiry has waited a day.','record_stale',
   '{"type_key":"enrolments","status":"enquiry","after_hours":24,"rule":{"task":{"title":"Reply to enquiry: {title}","priority":"high","due_hours":4}}}'::jsonb),
 ('childcare','Withdrawn follow-up','Ask the family for feedback when they withdraw.','record_status_action',
   '{"type_key":"enrolments","rules":[{"status":"withdrawn","task":{"title":"Ask for feedback: {title}","priority":"normal","due_hours":72}}]}'::jsonb),
 -- landscaping
 ('landscaping','Approved job to schedule','Task when an approved job has not been scheduled for two days.','record_stale',
   '{"type_key":"jobs","status":"approved","after_days":2,"rule":{"task":{"title":"Schedule approved job: {title}","priority":"high","due_hours":24}}}'::jsonb),
 ('landscaping','Plan paused check-in','Check in on a plan that has been paused for a month.','record_stale',
   '{"type_key":"plans","status":"paused","after_days":30,"rule":{"task":{"title":"Check in on paused plan: {title}","priority":"normal","due_hours":48}}}'::jsonb),
 ('landscaping','Job running long','Task when a job has been in progress for a week.','record_stale',
   '{"type_key":"jobs","status":"in_progress","after_days":7,"rule":{"task":{"title":"Job in progress for a week: {title}","priority":"normal","due_hours":24}}}'::jsonb),
 -- pest control
 ('pest_control','Plan visit reminder','Remind the customer the day before a plan visit.','record_due_reminder',
   '{"type_key":"plans","due_field":"next_visit","statuses":["active"],"before_hours":24,"rule":{"message":"A reminder that your next plan visit is tomorrow. Reply here if you need to change it.","delay_minutes":1}}'::jsonb),
 ('pest_control','Approved job to schedule','Task when an approved job has not been scheduled for two days.','record_stale',
   '{"type_key":"jobs","status":"approved","after_days":2,"rule":{"task":{"title":"Schedule approved job: {title}","priority":"high","due_hours":24}}}'::jsonb),
 ('pest_control','Visit reminder','Remind the customer the day before an inspection or treatment.','record_due_reminder',
   '{"type_key":"jobs","due_field":"scheduled_for","statuses":["inspection_booked","scheduled"],"before_hours":24,"rule":{"message":"A reminder that your visit is tomorrow. Reply here if you need to change it.","delay_minutes":1}}'::jsonb),
 -- professional services
 ('professional_services','Contract not signed','Task when a contract has waited five days.','record_stale',
   '{"type_key":"opportunities","status":"contract","after_days":5,"rule":{"task":{"title":"Contract waiting: {title}","priority":"normal","due_hours":24}}}'::jsonb),
 ('professional_services','Discovery follow-up','Task two days after a discovery call.','record_stale',
   '{"type_key":"opportunities","status":"discovery","after_days":2,"rule":{"task":{"title":"Follow up after discovery call: {title}","priority":"normal","due_hours":24}}}'::jsonb),
 -- pet care
 ('pet_care','Reminder not booked','Task when a contacted reminder has not booked after a week.','record_stale',
   '{"type_key":"reminders","status":"contacted","after_days":7,"rule":{"task":{"title":"Reminder not booked: {title}","priority":"normal","due_hours":24}}}'::jsonb),
 ('pet_care','Overdue reminder','Send a gentle nudge when a reminder becomes overdue.','record_status_action',
   '{"type_key":"reminders","rules":[{"status":"overdue","message":"A reminder is overdue for your pet. Reply here and we will help you find a time.","delay_minutes":5}]}'::jsonb),
 -- photography and events
 ('photography_events','Quote chase','Check on a quote after three days.','record_stale',
   '{"type_key":"bookings","status":"quoted","after_days":3,"rule":{"message":"Just checking whether you would like to go ahead. Reply here with any questions.","delay_minutes":1,"task":{"title":"Quote waiting: {title}","priority":"normal","due_hours":24}}}'::jsonb),
 -- sensitive industries: drafts only, a person decides what goes out
 ('healthcare','Referral follow-up (draft)','Draft a note when a referral has been contacted but not booked after three days.','record_stale',
   '{"type_key":"referrals","status":"contacted","after_days":3,"rule":{"mode":"draft","message":"We tried to reach you about your referral. Reply here and we will help you find a time.","delay_minutes":1}}'::jsonb),
 ('legal','Consultation follow-up (draft)','Draft a note when a consultation was held and nothing has moved for three days.','record_stale',
   '{"type_key":"matters","status":"consultation","after_days":3,"rule":{"mode":"draft","message":"Thank you for speaking with us. Reply here if you would like to take the next step or have any questions.","delay_minutes":1}}'::jsonb),
 ('financial_services','Consultation follow-up (draft)','Draft a note when a consultation was held and nothing has moved for three days.','record_stale',
   '{"type_key":"opportunities","status":"consultation","after_days":3,"rule":{"mode":"draft","message":"Thank you for meeting with us. Reply here if you have questions or would like to continue.","delay_minutes":1}}'::jsonb)
)
insert into public.industry_automation_presets (industry_key, name, description, trigger_type, trigger_config)
select industry_key, name, description, trigger_type, trigger_config from p
on conflict (industry_key, name) do nothing;

------------------------------------------------------------------ Second batch: bring the 5-6 preset industries up to 7
with p(industry_key, name, description, trigger_type, trigger_config) as (values
 ('pet_care','Declined reminder revisit','Revisit a declined reminder after two months.','record_stale',
   '{"type_key":"reminders","status":"declined","after_days":60,"rule":{"task":{"title":"Revisit declined reminder: {title}","priority":"normal","due_hours":48}}}'::jsonb),
 ('pet_care','Reminder due soon','Tell the owner a reminder is due in three days.','record_due_reminder',
   '{"type_key":"reminders","due_field":"due_date","statuses":["due","contacted"],"before_hours":72,"rule":{"message":"A reminder for your pet is due in a few days. Reply here and we will help you find a time.","delay_minutes":1}}'::jsonb),
 ('dental','Declined recall revisit','Revisit a declined recall after three months.','record_stale',
   '{"type_key":"recalls","status":"declined","after_days":90,"rule":{"task":{"title":"Revisit declined recall: {title}","priority":"normal","due_hours":72}}}'::jsonb),
 ('electrical','Approved job to schedule','Task when an approved job has not been scheduled for two days.','record_stale',
   '{"type_key":"jobs","status":"approved","after_days":2,"rule":{"task":{"title":"Schedule approved job: {title}","priority":"high","due_hours":24}}}'::jsonb),
 ('fitness','Trial attended follow-up','Task two days after someone attended a trial and has not joined.','record_stale',
   '{"type_key":"trials","status":"attended","after_days":2,"rule":{"task":{"title":"Follow up after trial: {title}","priority":"normal","due_hours":24}}}'::jsonb),
 ('home_services','Follow-up job chase','Task when a job marked for follow-up has waited three days.','record_stale',
   '{"type_key":"jobs","status":"follow_up","after_days":3,"rule":{"task":{"title":"Follow-up job waiting: {title}","priority":"normal","due_hours":24}}}'::jsonb),
 ('travel','Payment due reminder','Remind the traveller three days before a payment is due.','record_due_reminder',
   '{"type_key":"bookings","due_field":"payment_due","statuses":["pending","confirmed"],"before_hours":72,"rule":{"message":"A reminder that a payment for your booking is due in three days. Reply here if you have any questions.","delay_minutes":1}}'::jsonb),
 ('ecommerce','Refund issued','Tell the customer when a refund has been issued.','record_status_action',
   '{"type_key":"returns","rules":[{"status":"refunded","message":"Your refund has been issued. Reply here if you have any questions.","delay_minutes":5}]}'::jsonb)
)
insert into public.industry_automation_presets (industry_key, name, description, trigger_type, trigger_config)
select industry_key, name, description, trigger_type, trigger_config from p
on conflict (industry_key, name) do nothing;
