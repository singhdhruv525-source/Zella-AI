-- Settings saved before sql/zella_channel_review.sql (test data only): what the migration has to find.
\set ON_ERROR_STOP 1
reset role; set timezone = 'UTC';
insert into businesses (id, name, industry_id, timezone, is_active, onboarding_status)
select v.id::uuid, v.n, i.id, 'UTC', true, 'active' from industries i,
  (values ('ec000000-0000-0000-0000-00000000000a', 'Calls Salon'), ('ec000000-0000-0000-0000-00000000000b', 'Switched Salon'),
          ('ec000000-0000-0000-0000-00000000000c', 'Waitlist Salon'), ('ec000000-0000-0000-0000-00000000000d', 'Text Salon')) v(id, n)
 where i.slug = 'beauty-salon';
insert into business_hours (business_id, weekday, opens, closes) select b.id, d, '00:00', '23:59' from businesses b, generate_series(0, 6) d where b.id::text like 'ec000000-%';
insert into customers (id, business_id, first_name, phone, email, status) select ('ec1' || substr(b.id::text, 4))::uuid, b.id, 'Cara', '+151255501' || lpad((ascii(right(b.id::text, 1)) - 96)::text, 2, '0'), 'cara@example.test', 'active'
  from businesses b where b.id::text like 'ec000000-%';
insert into automations (business_id, name, trigger_type, status, trigger_config) values
  ('ec000000-0000-0000-0000-00000000000a', 'Appointment reminder', 'appointment_reminder', 'active', '{"hours_before":[24],"channel":"call"}'),
  ('ec000000-0000-0000-0000-00000000000a', 'Booking confirmation', 'appointment_confirmation', 'active', '{"hours_before":24,"channel":"call"}'),
  ('ec000000-0000-0000-0000-00000000000b', 'Appointment reminder', 'appointment_reminder', 'active', '{"hours_before":[24],"channel":"sms","channel_requested":"sms_and_call"}'),
  ('ec000000-0000-0000-0000-00000000000c', 'Waitlist offer', 'waitlist_offer', 'active', '{"offers":1,"offer_minutes":30,"channel":"call"}'),
  ('ec000000-0000-0000-0000-00000000000d', 'Appointment reminder', 'appointment_reminder', 'active', '{"hours_before":[24],"channel":"sms"}');
-- a booking for Calls Salon with the reminder M3 queued as a text
insert into appointments (id, business_id, customer_id, title, start_time, end_time, timezone, status)
values ('ec200000-0000-0000-0000-00000000000a', 'ec000000-0000-0000-0000-00000000000a', 'ec100000-0000-0000-0000-00000000000a', 'Cut',
        date_trunc('hour', now()) + interval '3 days', date_trunc('hour', now()) + interval '3 days 30 minutes', 'UTC', 'scheduled');
update appointment_reminders set status = 'cancelled' where appointment_id = 'ec200000-0000-0000-0000-00000000000a';
insert into appointment_reminders (business_id, appointment_id, customer_id, kind, hours_before, reason, due_at, channel, status)
values ('ec000000-0000-0000-0000-00000000000a', 'ec200000-0000-0000-0000-00000000000a', 'ec100000-0000-0000-0000-00000000000a', 'reminder', 24, 'booked',
        date_trunc('hour', now()) + interval '2 days', 'sms', 'pending');
insert into waitlist_entries (business_id, customer_id, status, duration_minutes)
values ('ec000000-0000-0000-0000-00000000000c', 'ec100000-0000-0000-0000-00000000000c', 'waiting', 30);
