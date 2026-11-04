#!/usr/bin/env bash
# Two bookings for the last place in a class at the same moment: exactly one gets it, the other is waitlisted.
DB="$1"; H=${ZPG_HOST:-/var/lib/postgresql/zella-sec}; P=${ZPG_PORT:-55433}
PSQL="psql -h $H -p $P -U postgres -qtAX -v ON_ERROR_STOP=1 -d $DB"
B=e5000000-0000-0000-0000-0000000000a1
$PSQL <<SQL >/dev/null || exit 1
insert into public.businesses (id, name, timezone, is_active, onboarding_status) values ('$B', 'Gym C', 'UTC', true, 'active');
insert into public.crm_record_types (business_id, key, singular, plural, statuses, fields, capacity) values
 ('$B', 'classes', 'Class', 'Classes', '[{"key":"open","label":"Open"}]', '[{"key":"places","label":"Places","type":"number"}]', null),
 ('$B', 'bookings', 'Booking', 'Bookings', '[{"key":"booked","label":"Booked"},{"key":"waitlist","label":"Waitlist"}]',
  '[{"key":"class","label":"Class","type":"record","target":"classes"}]', '{"parent_field":"class","capacity_field":"places","counted":["booked"],"waitlist_status":"waitlist"}');
insert into public.crm_records (id, business_id, type_key, title, status, data) values ('e5000000-0000-0000-0000-0000000000c1', '$B', 'classes', 'Spin', 'open', '{"places":1}');
SQL
book() { $PSQL -c "begin; select public.zella_crm_write_record(null, 'staff', '$B', 'bookings', null, '$1', 'booked', null, null, null, '{\"class\":\"e5000000-0000-0000-0000-0000000000c1\"}'); select pg_sleep(0.6); commit;" >/dev/null; }
book A & book B & wait
res=$($PSQL -c "select string_agg(status, ',' order by status) from public.crm_records where business_id = '$B' and type_key = 'bookings'")
if [ "$res" = "booked,waitlist" ]; then echo "PASS concurrent bookings for the last place: one booked, one waitlisted"; else echo "FAIL concurrent capacity: $res"; exit 1; fi
