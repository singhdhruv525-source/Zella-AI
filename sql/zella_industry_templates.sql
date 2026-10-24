-- Zella - industry wording for reminders and waitlist offers (checklist 201, 205, 221, 225). Safe to run more than once.
-- The reminder and waitlist machinery is shared; these rows only change the words for one industry. A business can still
-- override any of them with its own template. Healthcare wording is administrative only: no service name, no health details.
insert into public.message_templates (business_id, industry_id, key, channel, purpose, locale, subject, body, version, status)
select null, i.id, v.key, v.channel, 'transactional', 'en-US', v.subject, v.body, 1, 'active'
  from (values
    ('dental', 'appointment_reminder', 'sms', null, 'Hi {{first_name}}, a reminder of your {{appointment}} at {{business}} on {{date}} at {{time}}. Please arrive 10 minutes early.{{reschedule_line}} Reply STOP to opt out.'),
    ('dental', 'appointment_reminder', 'email', 'Reminder: your visit on {{date}} at {{time}}', E'Hi {{first_name}},\n\nThis is a reminder of your {{appointment}} at {{business}} on {{date}} at {{time}}. Please arrive 10 minutes early so we can start on time.{{reschedule_line}}'),
    ('fitness', 'appointment_reminder', 'sms', null, 'Hi {{first_name}}, you are booked into {{appointment}} at {{business}} on {{date}} at {{time}}. Please arrive a few minutes early. If you cannot make it, let us know so someone else can take your spot.{{reschedule_line}} Reply STOP to opt out.'),
    ('fitness', 'appointment_reminder', 'email', 'Your class: {{appointment}} on {{date}} at {{time}}', E'Hi {{first_name}},\n\nYou are booked into {{appointment}} at {{business}} on {{date}} at {{time}}. Please arrive a few minutes early. If you cannot make it, let us know so someone else can take your spot.{{reschedule_line}}'),
    ('healthcare', 'appointment_reminder', 'sms', null, 'Hi {{first_name}}, a reminder of your appointment at {{business}} on {{date}} at {{time}}.{{reschedule_line}} Please do not reply with health details. Reply STOP to opt out.'),
    ('healthcare', 'appointment_reminder', 'email', 'Reminder: your appointment on {{date}} at {{time}}', E'Hi {{first_name}},\n\nThis is a reminder of your appointment at {{business}} on {{date}} at {{time}}.{{reschedule_line}}\n\nPlease do not reply to this email with health information. Call the office if you need to speak to someone.'),
    ('beauty-salon', 'appointment_reminder', 'sms', null, 'Hi {{first_name}}, we are looking forward to seeing you at {{business}} for {{appointment}} on {{date}} at {{time}}.{{reschedule_line}} Reply STOP to opt out.'),
    ('beauty-salon', 'appointment_reminder', 'email', 'See you on {{date}} at {{time}}', E'Hi {{first_name}},\n\nWe are looking forward to seeing you at {{business}} for {{appointment}} on {{date}} at {{time}}.{{reschedule_line}}'),
    ('beauty-salon', 'waitlist_offer', 'sms', null, 'Hi {{first_name}}, good news from {{business}}: a spot opened up on {{date}} at {{time}}.{{offer_line}} It goes to the first person who takes it. Reply STOP to opt out.')
  ) as v(slug, key, channel, subject, body)
  join public.industries i on i.slug = v.slug
 where not exists (select 1 from public.message_templates t where t.business_id is null and t.industry_id = i.id and t.key = v.key and t.channel = v.channel and t.locale = 'en-US' and t.status = 'active');
