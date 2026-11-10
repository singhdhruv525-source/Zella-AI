-- ============================================================
-- Zella industry CRM: one shared record system, configured per industry.
-- Run AFTER zella_workflows.sql. Safe to run again.
-- Presets are copied into each business the first time its CRM opens;
-- after that the business's own settings are never overwritten.
-- ============================================================

create table if not exists public.industry_crm_presets (
  key text primary key,
  match text[] not null,
  config jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.industry_crm_presets enable row level security;
revoke all on public.industry_crm_presets from anon, authenticated;

create table if not exists public.crm_record_types (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  key text not null check (key ~ '^[a-z][a-z0-9_]{1,40}$'),
  singular text not null,
  plural text not null,
  icon text not null default 'folder',
  title_label text not null default 'Name',
  link_person boolean not null default true,
  statuses jsonb not null,
  closed_statuses text[] not null default '{}',
  fields jsonb not null default '[]'::jsonb,
  columns text[] not null default '{}',
  notice text,
  enabled boolean not null default true,
  position integer not null default 0,
  preset_key text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, key)
);

create table if not exists public.crm_records (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  type_key text not null,
  title text not null,
  status text not null,
  customer_id uuid references public.customers(id) on delete set null,
  assigned_to uuid,
  due_at timestamptz,
  data jsonb not null default '{}'::jsonb,
  unique_key text,
  source text not null default 'staff' check (source in ('staff', 'ai', 'automation', 'import')),
  created_by uuid,
  closed_at timestamptz,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (business_id, type_key) references public.crm_record_types (business_id, key) on delete cascade
);
create index if not exists crm_records_list_idx on public.crm_records (business_id, type_key, updated_at desc) where archived_at is null;
create index if not exists crm_records_person_idx on public.crm_records (customer_id) where archived_at is null;
create unique index if not exists crm_records_unique_idx on public.crm_records (business_id, type_key, unique_key) where unique_key is not null and archived_at is null;

create table if not exists public.crm_record_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  record_id uuid not null references public.crm_records(id) on delete cascade,
  kind text not null,
  detail text,
  actor uuid,
  created_at timestamptz not null default now()
);
create index if not exists crm_record_events_idx on public.crm_record_events (record_id, created_at desc);

do $$ declare t text; begin
  foreach t in array array['crm_record_types', 'crm_records', 'crm_record_events'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.zella_is_member(business_id))', t || '_select', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('revoke insert, update, delete on public.%I from authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;

-- ---------- preset data ----------
insert into public.industry_crm_presets (key, match, config) values
  ('automotive', array['automotive','autorepair','auto','vehicle'], $j${"types": [{"key": "vehicles", "singular": "Vehicle", "plural": "Vehicles", "icon": "directions_car", "title_label": "Nickname or plate", "link_person": true, "statuses": [{"key": "active", "label": "Active", "tone": "warning"}, {"key": "inactive", "label": "Inactive", "tone": "success"}], "closed_statuses": ["inactive"], "fields": [{"key": "registration", "label": "Registration", "type": "text", "unique": true, "required": true}, {"key": "make", "label": "Make", "type": "text"}, {"key": "model", "label": "Model", "type": "text"}, {"key": "year", "label": "Year", "type": "number"}, {"key": "mileage", "label": "Mileage", "type": "number"}, {"key": "next_service_due", "label": "Next service due", "type": "date"}, {"key": "warranty_until", "label": "Warranty until", "type": "date"}], "columns": ["registration", "make", "model"], "notice": null}, {"key": "repair_orders", "singular": "Repair order", "plural": "Repair orders", "icon": "build", "title_label": "Summary", "link_person": true, "statuses": [{"key": "checked_in", "label": "Checked in", "tone": "warning"}, {"key": "diagnosing", "label": "Diagnosing", "tone": "info"}, {"key": "estimate_sent", "label": "Estimate sent", "tone": "info"}, {"key": "approved", "label": "Approved", "tone": "info"}, {"key": "in_repair", "label": "In repair", "tone": "info"}, {"key": "ready", "label": "Ready for pickup", "tone": "info"}, {"key": "collected", "label": "Collected", "tone": "success"}, {"key": "cancelled", "label": "Cancelled", "tone": ""}], "closed_statuses": ["cancelled", "collected"], "fields": [{"key": "vehicle", "label": "Vehicle registration", "type": "text"}, {"key": "reported_problem", "label": "Reported problem", "type": "longtext"}, {"key": "estimate", "label": "Estimate", "type": "select", "options": ["Not sent", "Sent", "Approved", "Declined"]}, {"key": "mechanic", "label": "Mechanic", "type": "text"}, {"key": "parts_status", "label": "Parts", "type": "select", "options": ["Not needed", "Ordered", "Arrived"]}, {"key": "pickup_at", "label": "Pickup", "type": "datetime"}], "columns": ["vehicle", "estimate", "mechanic"], "notice": null}]}$j$::jsonb),
  ('beauty_salon', array['beautysalon','beautyandsalon','salon','beauty'], $j${"types": [{"key": "memberships", "singular": "Membership", "plural": "Memberships", "icon": "loyalty", "title_label": "Membership", "link_person": true, "statuses": [{"key": "active", "label": "Active", "tone": "warning"}, {"key": "paused", "label": "Paused", "tone": "info"}, {"key": "ended", "label": "Ended", "tone": "success"}], "closed_statuses": ["ended"], "fields": [{"key": "plan", "label": "Plan or package", "type": "text"}, {"key": "started", "label": "Started", "type": "date"}, {"key": "renews", "label": "Renews", "type": "date"}, {"key": "preferred_stylist", "label": "Preferred stylist", "type": "text"}, {"key": "notes", "label": "Notes", "type": "longtext"}], "columns": ["plan", "started", "renews"], "notice": null}, {"key": "preferences", "singular": "Service preference", "plural": "Service preferences", "icon": "tune", "title_label": "Preference", "link_person": true, "statuses": [{"key": "active", "label": "Active", "tone": "warning"}, {"key": "retired", "label": "Retired", "tone": "success"}], "closed_statuses": ["retired"], "fields": [{"key": "service", "label": "Service", "type": "text"}, {"key": "stylist", "label": "Stylist", "type": "text"}, {"key": "rebook_after_weeks", "label": "Rebook after (weeks)", "type": "number"}, {"key": "notes", "label": "Notes", "type": "longtext"}], "columns": ["service", "stylist", "rebook_after_weeks"], "notice": null}]}$j$::jsonb),
  ('dental', array['dental','dentist','dentalclinic'], $j${"types": [{"key": "recalls", "singular": "Recall", "plural": "Recalls", "icon": "event_repeat", "title_label": "Recall", "link_person": true, "statuses": [{"key": "due", "label": "Due", "tone": "warning"}, {"key": "contacted", "label": "Contacted", "tone": "info"}, {"key": "booked", "label": "Booked", "tone": "success"}, {"key": "declined", "label": "Declined", "tone": ""}, {"key": "overdue", "label": "Overdue", "tone": "info"}], "closed_statuses": ["booked", "declined"], "fields": [{"key": "due_date", "label": "Recall due", "type": "date", "required": true}, {"key": "kind", "label": "Type", "type": "select", "options": ["Check-up", "Hygiene", "Other"]}, {"key": "provider", "label": "Preferred provider", "type": "text"}, {"key": "notes", "label": "Administrative notes", "type": "longtext"}], "columns": ["due_date", "kind", "provider"], "notice": "Keep clinical charts, diagnoses and treatment records in your dental practice system. Zella holds administrative information only."}, {"key": "enquiries", "singular": "Enquiry", "plural": "Enquiries", "icon": "help", "title_label": "Enquiry", "link_person": true, "statuses": [{"key": "new", "label": "New", "tone": "warning"}, {"key": "replied", "label": "Replied", "tone": "info"}, {"key": "resolved", "label": "Resolved", "tone": "success"}], "closed_statuses": ["resolved"], "fields": [{"key": "topic", "label": "Topic", "type": "text"}, {"key": "referral_source", "label": "Referral source", "type": "text"}, {"key": "details", "label": "Details", "type": "longtext"}], "columns": ["topic", "referral_source", "details"], "notice": "Do not record clinical details here."}]}$j$::jsonb),
  ('ecommerce', array['ecommerce','retail','onlineretail'], $j${"types": [{"key": "orders", "singular": "Order", "plural": "Orders", "icon": "shopping_bag", "title_label": "Order", "link_person": true, "statuses": [{"key": "open", "label": "Open", "tone": "warning"}, {"key": "packed", "label": "Packed", "tone": "info"}, {"key": "shipped", "label": "Shipped", "tone": "info"}, {"key": "delivered", "label": "Delivered", "tone": "success"}, {"key": "issue", "label": "Delivery issue", "tone": "info"}, {"key": "cancelled", "label": "Cancelled", "tone": ""}], "closed_statuses": ["cancelled", "delivered"], "fields": [{"key": "order_ref", "label": "Order number", "type": "text", "unique": true, "required": true}, {"key": "platform", "label": "Store or platform", "type": "text"}, {"key": "tracking", "label": "Tracking number", "type": "text"}, {"key": "issue", "label": "Issue", "type": "longtext"}], "columns": ["order_ref", "tracking", "platform"], "notice": "Orders, inventory and payments stay in your store platform. Zella keeps references for support only."}, {"key": "returns", "singular": "Return", "plural": "Returns", "icon": "assignment_return", "title_label": "Return", "link_person": true, "statuses": [{"key": "requested", "label": "Requested", "tone": "warning"}, {"key": "received", "label": "Received", "tone": "info"}, {"key": "refunded", "label": "Refunded", "tone": "success"}, {"key": "exchanged", "label": "Exchanged", "tone": "success"}, {"key": "rejected", "label": "Rejected", "tone": "success"}], "closed_statuses": ["exchanged", "refunded", "rejected"], "fields": [{"key": "order_ref", "label": "Order number", "type": "text"}, {"key": "reason", "label": "Reason", "type": "select", "options": ["Wrong item", "Damaged", "Not as described", "Changed mind", "Other"]}, {"key": "resolution", "label": "Resolution", "type": "select", "options": ["Refund", "Exchange", "Store credit"]}], "columns": ["order_ref", "reason", "resolution"], "notice": null}, {"key": "cases", "singular": "Support case", "plural": "Support cases", "icon": "support_agent", "title_label": "Case", "link_person": true, "statuses": [{"key": "open", "label": "Open", "tone": "warning"}, {"key": "waiting", "label": "Waiting on customer", "tone": "info"}, {"key": "resolved", "label": "Resolved", "tone": "success"}], "closed_statuses": ["resolved"], "fields": [{"key": "category", "label": "Category", "type": "select", "options": ["Product question", "Complaint", "Shipping", "Other"]}, {"key": "order_ref", "label": "Order number", "type": "text"}, {"key": "details", "label": "Details", "type": "longtext"}], "columns": ["category", "order_ref", "details"], "notice": null}]}$j$::jsonb),
  ('education', array['education','school','training'], $j${"types": [{"key": "applications", "singular": "Application", "plural": "Applications", "icon": "school", "title_label": "Applicant", "link_person": true, "statuses": [{"key": "enquiry", "label": "Enquiry", "tone": "warning"}, {"key": "counselling", "label": "Counselling booked", "tone": "info"}, {"key": "documents", "label": "Documents pending", "tone": "info"}, {"key": "applied", "label": "Applied", "tone": "info"}, {"key": "offered", "label": "Offered", "tone": "info"}, {"key": "enrolled", "label": "Enrolled", "tone": "success"}, {"key": "declined", "label": "Declined", "tone": ""}, {"key": "withdrawn", "label": "Withdrawn", "tone": ""}], "closed_statuses": ["declined", "enrolled", "withdrawn"], "fields": [{"key": "course", "label": "Course or program", "type": "text"}, {"key": "intake", "label": "Intake", "type": "text"}, {"key": "counsellor", "label": "Counsellor", "type": "text"}, {"key": "guardian_name", "label": "Guardian name", "type": "text"}, {"key": "guardian_phone", "label": "Guardian phone", "type": "phone"}, {"key": "documents_received", "label": "Documents received", "type": "bool"}], "columns": ["course", "intake", "counsellor"], "notice": "Grades and sensitive student records belong in your student system, not here."}, {"key": "courses", "singular": "Course", "plural": "Courses", "icon": "menu_book", "title_label": "Course", "link_person": false, "statuses": [{"key": "open", "label": "Open for enquiries", "tone": "warning"}, {"key": "full", "label": "Full", "tone": "info"}, {"key": "closed", "label": "Closed", "tone": "success"}], "closed_statuses": ["closed"], "fields": [{"key": "code", "label": "Code", "type": "text", "unique": true}, {"key": "starts", "label": "Starts", "type": "date"}, {"key": "seats", "label": "Seats", "type": "number"}, {"key": "details", "label": "Details", "type": "longtext"}], "columns": ["code", "starts", "seats"], "notice": null}]}$j$::jsonb),
  ('electrical', array['electrical','electrician'], $j${"types": [{"key": "jobs", "singular": "Job", "plural": "Jobs", "icon": "electrical_services", "title_label": "Job", "link_person": true, "statuses": [{"key": "new", "label": "New", "tone": "warning"}, {"key": "dispatched", "label": "Dispatched", "tone": "info"}, {"key": "on_site", "label": "On site", "tone": "info"}, {"key": "estimate", "label": "Estimate sent", "tone": "info"}, {"key": "approved", "label": "Approved", "tone": "info"}, {"key": "completed", "label": "Completed", "tone": "success"}, {"key": "follow_up", "label": "Follow-up", "tone": "info"}, {"key": "cancelled", "label": "Cancelled", "tone": ""}], "closed_statuses": ["cancelled", "completed"], "fields": [{"key": "site_address", "label": "Site address", "type": "text", "required": true}, {"key": "fault", "label": "Fault description", "type": "longtext"}, {"key": "priority", "label": "Priority", "type": "select", "options": ["Emergency", "Urgent", "Routine"]}, {"key": "electrician", "label": "Electrician", "type": "text"}, {"key": "estimate", "label": "Estimate", "type": "select", "options": ["Not sent", "Sent", "Approved", "Declined"]}, {"key": "scheduled_for", "label": "Scheduled", "type": "datetime"}], "columns": ["site_address", "priority", "electrician"], "notice": null}, {"key": "sites", "singular": "Site", "plural": "Sites", "icon": "home_pin", "title_label": "Site", "link_person": true, "statuses": [{"key": "active", "label": "Active", "tone": "warning"}, {"key": "inactive", "label": "Inactive", "tone": "success"}], "closed_statuses": ["inactive"], "fields": [{"key": "address", "label": "Address", "type": "text", "unique": true, "required": true}, {"key": "access", "label": "Access instructions", "type": "longtext"}, {"key": "last_inspection", "label": "Last inspection", "type": "date"}], "columns": ["address", "access", "last_inspection"], "notice": null}]}$j$::jsonb),
  ('financial_services', array['financialservices','finance','financial','insurance','accounting'], $j${"types": [{"key": "opportunities", "singular": "Opportunity", "plural": "Opportunities", "icon": "trending_up", "title_label": "Opportunity", "link_person": true, "statuses": [{"key": "lead", "label": "Lead", "tone": "warning"}, {"key": "qualified", "label": "Qualified", "tone": "info"}, {"key": "consultation", "label": "Consultation", "tone": "info"}, {"key": "application", "label": "Application", "tone": "info"}, {"key": "pending", "label": "Pending", "tone": "info"}, {"key": "won", "label": "Won", "tone": "success"}, {"key": "lost", "label": "Lost", "tone": ""}], "closed_statuses": ["lost", "won"], "fields": [{"key": "kind", "label": "Service type", "type": "text"}, {"key": "advisor", "label": "Advisor", "type": "text"}, {"key": "source", "label": "Source", "type": "text"}, {"key": "next_step", "label": "Next step", "type": "date"}], "columns": ["kind", "advisor", "source"], "notice": "Do not store account numbers, card details or log-in credentials in Zella. Zella does not give financial advice or promise eligibility."}, {"key": "requests", "singular": "Service request", "plural": "Service requests", "icon": "assignment", "title_label": "Request", "link_person": true, "statuses": [{"key": "open", "label": "Open", "tone": "warning"}, {"key": "waiting", "label": "Waiting on documents", "tone": "info"}, {"key": "done", "label": "Done", "tone": "success"}], "closed_statuses": ["done"], "fields": [{"key": "kind", "label": "Request", "type": "text"}, {"key": "documents_requested", "label": "Documents requested", "type": "longtext"}, {"key": "documents_received", "label": "Documents received", "type": "bool"}, {"key": "renewal", "label": "Renewal date", "type": "date"}], "columns": ["kind", "documents_requested", "documents_received"], "notice": null}]}$j$::jsonb),
  ('fitness', array['fitness','gym'], $j${"types": [{"key": "memberships", "singular": "Membership", "plural": "Memberships", "icon": "fitness_center", "title_label": "Membership", "link_person": true, "statuses": [{"key": "trial", "label": "Trial", "tone": "warning"}, {"key": "active", "label": "Active", "tone": "info"}, {"key": "frozen", "label": "Frozen", "tone": "info"}, {"key": "expiring", "label": "Expiring", "tone": "info"}, {"key": "cancelled", "label": "Cancelled", "tone": ""}, {"key": "expired", "label": "Expired", "tone": ""}], "closed_statuses": ["cancelled", "expired"], "fields": [{"key": "plan", "label": "Plan", "type": "text"}, {"key": "started", "label": "Started", "type": "date"}, {"key": "renews", "label": "Renews", "type": "date"}, {"key": "trainer", "label": "Trainer", "type": "text"}], "columns": ["plan", "started", "renews"], "notice": "Health assessments and workout programs belong in your fitness software."}, {"key": "trials", "singular": "Trial or enquiry", "plural": "Trials and enquiries", "icon": "directions_run", "title_label": "Enquiry", "link_person": true, "statuses": [{"key": "new", "label": "New", "tone": "warning"}, {"key": "booked", "label": "Trial booked", "tone": "info"}, {"key": "attended", "label": "Attended", "tone": "info"}, {"key": "joined", "label": "Joined", "tone": "success"}, {"key": "not_proceeding", "label": "Not joining", "tone": ""}], "closed_statuses": ["joined", "not_proceeding"], "fields": [{"key": "class", "label": "Class of interest", "type": "text"}, {"key": "trial_date", "label": "Trial date", "type": "datetime"}, {"key": "outcome", "label": "Outcome", "type": "longtext"}], "columns": ["class", "trial_date", "outcome"], "notice": null}]}$j$::jsonb),
  ('healthcare', array['healthcare','medical','clinic'], $j${"types": [{"key": "referrals", "singular": "Referral", "plural": "Referrals", "icon": "assignment_ind", "title_label": "Referral", "link_person": true, "statuses": [{"key": "received", "label": "Received", "tone": "warning"}, {"key": "contacted", "label": "Contacted", "tone": "info"}, {"key": "booked", "label": "Booked", "tone": "success"}, {"key": "declined", "label": "Declined", "tone": ""}, {"key": "closed", "label": "Closed", "tone": "success"}], "closed_statuses": ["booked", "closed", "declined"], "fields": [{"key": "referring_provider", "label": "Referring provider", "type": "text"}, {"key": "provider", "label": "Provider", "type": "text"}, {"key": "urgency", "label": "Urgency", "type": "select", "options": ["Urgent", "Soon", "Routine"]}, {"key": "received_on", "label": "Received", "type": "date"}], "columns": ["referring_provider", "provider", "urgency"], "notice": "Administrative information only. Zella does not diagnose or handle emergencies. Urgent calls go to staff. Keep clinical details in your clinical system."}, {"key": "enquiries", "singular": "Administrative enquiry", "plural": "Administrative enquiries", "icon": "help", "title_label": "Enquiry", "link_person": true, "statuses": [{"key": "new", "label": "New", "tone": "warning"}, {"key": "replied", "label": "Replied", "tone": "info"}, {"key": "resolved", "label": "Resolved", "tone": "success"}], "closed_statuses": ["resolved"], "fields": [{"key": "topic", "label": "Topic", "type": "text"}, {"key": "details", "label": "Details", "type": "longtext"}], "columns": ["topic", "details"], "notice": "Do not record clinical details here."}]}$j$::jsonb),
  ('home_services', array['homeservices','homeservice','domestic','cleaning'], $j${"types": [{"key": "properties", "singular": "Property", "plural": "Properties", "icon": "home", "title_label": "Property", "link_person": true, "statuses": [{"key": "active", "label": "Active", "tone": "warning"}, {"key": "inactive", "label": "Inactive", "tone": "success"}], "closed_statuses": ["inactive"], "fields": [{"key": "address", "label": "Address", "type": "text", "unique": true, "required": true}, {"key": "property_type", "label": "Property type", "type": "select", "options": ["House", "Apartment", "Office", "Other"]}, {"key": "access", "label": "Access instructions", "type": "longtext"}], "columns": ["address", "property_type", "access"], "notice": null}, {"key": "jobs", "singular": "Job", "plural": "Jobs", "icon": "handyman", "title_label": "Job", "link_person": true, "statuses": [{"key": "new", "label": "New", "tone": "warning"}, {"key": "estimate", "label": "Estimate sent", "tone": "info"}, {"key": "scheduled", "label": "Scheduled", "tone": "info"}, {"key": "in_progress", "label": "In progress", "tone": "info"}, {"key": "completed", "label": "Completed", "tone": "success"}, {"key": "follow_up", "label": "Follow-up", "tone": "info"}, {"key": "cancelled", "label": "Cancelled", "tone": ""}], "closed_statuses": ["cancelled", "completed"], "fields": [{"key": "category", "label": "Category", "type": "text"}, {"key": "address", "label": "Service address", "type": "text"}, {"key": "team", "label": "Team", "type": "text"}, {"key": "scheduled_for", "label": "Scheduled", "type": "datetime"}, {"key": "details", "label": "Details", "type": "longtext"}], "columns": ["category", "address", "team"], "notice": null}, {"key": "plans", "singular": "Service plan", "plural": "Service plans", "icon": "autorenew", "title_label": "Plan", "link_person": true, "statuses": [{"key": "active", "label": "Active", "tone": "warning"}, {"key": "paused", "label": "Paused", "tone": "info"}, {"key": "ended", "label": "Ended", "tone": "success"}], "closed_statuses": ["ended"], "fields": [{"key": "plan", "label": "Plan", "type": "text"}, {"key": "frequency", "label": "Frequency", "type": "select", "options": ["Weekly", "Fortnightly", "Monthly", "Quarterly", "Yearly"]}, {"key": "next_visit", "label": "Next visit", "type": "date"}], "columns": ["plan", "frequency", "next_visit"], "notice": null}]}$j$::jsonb),
  ('hvac', array['hvac','heatingandcooling','heating'], $j${"types": [{"key": "equipment", "singular": "Equipment", "plural": "Equipment", "icon": "ac_unit", "title_label": "Equipment", "link_person": true, "statuses": [{"key": "active", "label": "In service", "tone": "warning"}, {"key": "needs_service", "label": "Needs service", "tone": "info"}, {"key": "retired", "label": "Retired", "tone": "success"}], "closed_statuses": ["retired"], "fields": [{"key": "kind", "label": "Type", "type": "select", "options": ["Air conditioner", "Furnace", "Heat pump", "Boiler", "Other"]}, {"key": "make", "label": "Make", "type": "text"}, {"key": "model", "label": "Model", "type": "text"}, {"key": "serial", "label": "Serial number", "type": "text", "unique": true}, {"key": "installed", "label": "Installed", "type": "date"}, {"key": "next_maintenance", "label": "Next maintenance", "type": "date"}, {"key": "address", "label": "Address", "type": "text"}], "columns": ["kind", "make", "next_maintenance"], "notice": null}, {"key": "jobs", "singular": "Job", "plural": "Jobs", "icon": "construction", "title_label": "Job", "link_person": true, "statuses": [{"key": "new", "label": "New", "tone": "warning"}, {"key": "assessed", "label": "Assessed", "tone": "info"}, {"key": "dispatched", "label": "Dispatched", "tone": "info"}, {"key": "on_site", "label": "On site", "tone": "info"}, {"key": "completed", "label": "Completed", "tone": "success"}, {"key": "follow_up", "label": "Follow-up", "tone": "info"}, {"key": "cancelled", "label": "Cancelled", "tone": ""}], "closed_statuses": ["cancelled", "completed"], "fields": [{"key": "kind", "label": "Job type", "type": "select", "options": ["Repair", "Installation", "Inspection", "Maintenance"]}, {"key": "priority", "label": "Priority", "type": "select", "options": ["Emergency", "Urgent", "Routine"]}, {"key": "technician", "label": "Technician", "type": "text"}, {"key": "scheduled_for", "label": "Scheduled", "type": "datetime"}, {"key": "estimate", "label": "Estimate", "type": "select", "options": ["Not sent", "Sent", "Approved", "Declined"]}, {"key": "details", "label": "Details", "type": "longtext"}], "columns": ["kind", "priority", "technician"], "notice": null}, {"key": "agreements", "singular": "Service agreement", "plural": "Service agreements", "icon": "verified", "title_label": "Agreement", "link_person": true, "statuses": [{"key": "active", "label": "Active", "tone": "warning"}, {"key": "renewal_due", "label": "Renewal due", "tone": "info"}, {"key": "ended", "label": "Ended", "tone": "success"}], "closed_statuses": ["ended"], "fields": [{"key": "plan", "label": "Plan", "type": "text"}, {"key": "starts", "label": "Starts", "type": "date"}, {"key": "renews", "label": "Renews", "type": "date"}], "columns": ["plan", "starts", "renews"], "notice": null}]}$j$::jsonb),
  ('legal', array['legal','law','lawfirm'], $j${"types": [{"key": "matters", "singular": "Matter", "plural": "Matters", "icon": "gavel", "title_label": "Matter", "link_person": true, "statuses": [{"key": "intake", "label": "Intake", "tone": "warning"}, {"key": "conflict_check", "label": "Conflict check", "tone": "info"}, {"key": "consultation", "label": "Consultation", "tone": "info"}, {"key": "accepted", "label": "Accepted", "tone": "info"}, {"key": "active", "label": "Active", "tone": "info"}, {"key": "closed", "label": "Closed", "tone": "success"}, {"key": "declined", "label": "Declined", "tone": ""}], "closed_statuses": ["closed", "declined"], "fields": [{"key": "reference", "label": "Matter reference", "type": "text", "unique": true}, {"key": "matter_type", "label": "Matter type", "type": "text"}, {"key": "lawyer", "label": "Lawyer", "type": "text"}, {"key": "conflict_checked", "label": "Conflict check done", "type": "bool"}, {"key": "key_date", "label": "Important date", "type": "date"}], "columns": ["reference", "matter_type", "lawyer"], "notice": "Case documents and legal advice stay in your practice system. Anything Zella says is general information, not advice from a lawyer."}, {"key": "document_requests", "singular": "Document request", "plural": "Document requests", "icon": "description", "title_label": "Document", "link_person": true, "statuses": [{"key": "requested", "label": "Requested", "tone": "warning"}, {"key": "received", "label": "Received", "tone": "success"}, {"key": "cancelled", "label": "Cancelled", "tone": ""}], "closed_statuses": ["cancelled", "received"], "fields": [{"key": "matter_ref", "label": "Matter reference", "type": "text"}, {"key": "document", "label": "Document", "type": "text"}, {"key": "due", "label": "Due", "type": "date"}], "columns": ["matter_ref", "document", "due"], "notice": null}]}$j$::jsonb),
  ('other', array['other','general'], $j${"types": [{"key": "enquiries", "singular": "Enquiry", "plural": "Enquiries", "icon": "help", "title_label": "Enquiry", "link_person": true, "statuses": [{"key": "new", "label": "New", "tone": "warning"}, {"key": "in_progress", "label": "In progress", "tone": "info"}, {"key": "resolved", "label": "Resolved", "tone": "success"}], "closed_statuses": ["resolved"], "fields": [{"key": "subject", "label": "Subject", "type": "text"}, {"key": "details", "label": "Details", "type": "longtext"}], "columns": ["subject", "details"], "notice": null}, {"key": "records", "singular": "Record", "plural": "Records", "icon": "folder", "title_label": "Title", "link_person": true, "statuses": [{"key": "open", "label": "Open", "tone": "warning"}, {"key": "done", "label": "Done", "tone": "success"}], "closed_statuses": ["done"], "fields": [{"key": "details", "label": "Details", "type": "longtext"}], "columns": ["details"], "notice": "Add the fields you need in Settings, then rename this to suit your business."}]}$j$::jsonb),
  ('plumbing', array['plumbing','plumber'], $j${"types": [{"key": "jobs", "singular": "Job", "plural": "Jobs", "icon": "plumbing", "title_label": "Job", "link_person": true, "statuses": [{"key": "new", "label": "New", "tone": "warning"}, {"key": "dispatched", "label": "Dispatched", "tone": "info"}, {"key": "on_site", "label": "On site", "tone": "info"}, {"key": "quote_sent", "label": "Quote sent", "tone": "info"}, {"key": "approved", "label": "Approved", "tone": "info"}, {"key": "completed", "label": "Completed", "tone": "success"}, {"key": "follow_up", "label": "Follow-up", "tone": "info"}, {"key": "cancelled", "label": "Cancelled", "tone": ""}], "closed_statuses": ["cancelled", "completed"], "fields": [{"key": "address", "label": "Service address", "type": "text", "required": true}, {"key": "issue", "label": "Issue", "type": "longtext"}, {"key": "urgency", "label": "Urgency", "type": "select", "options": ["Emergency", "Urgent", "Routine"]}, {"key": "technician", "label": "Technician", "type": "text"}, {"key": "estimate", "label": "Estimate", "type": "select", "options": ["Not sent", "Sent", "Approved", "Declined"]}, {"key": "scheduled_for", "label": "Scheduled", "type": "datetime"}, {"key": "materials", "label": "Parts or materials", "type": "longtext"}], "columns": ["address", "urgency", "technician"], "notice": null}, {"key": "properties", "singular": "Property", "plural": "Properties", "icon": "home", "title_label": "Property", "link_person": true, "statuses": [{"key": "active", "label": "Active", "tone": "warning"}, {"key": "inactive", "label": "Inactive", "tone": "success"}], "closed_statuses": ["inactive"], "fields": [{"key": "address", "label": "Address", "type": "text", "unique": true, "required": true}, {"key": "access", "label": "Access instructions", "type": "longtext"}], "columns": ["address", "access"], "notice": null}, {"key": "plans", "singular": "Maintenance plan", "plural": "Maintenance plans", "icon": "autorenew", "title_label": "Plan", "link_person": true, "statuses": [{"key": "active", "label": "Active", "tone": "warning"}, {"key": "due", "label": "Visit due", "tone": "info"}, {"key": "ended", "label": "Ended", "tone": "success"}], "closed_statuses": ["ended"], "fields": [{"key": "plan", "label": "Plan", "type": "text"}, {"key": "next_visit", "label": "Next visit", "type": "date"}], "columns": ["plan", "next_visit"], "notice": null}]}$j$::jsonb),
  ('professional_services', array['professionalservices','consulting','agency'], $j${"types": [{"key": "opportunities", "singular": "Opportunity", "plural": "Opportunities", "icon": "trending_up", "title_label": "Opportunity", "link_person": true, "statuses": [{"key": "lead", "label": "Lead", "tone": "warning"}, {"key": "discovery", "label": "Discovery call", "tone": "info"}, {"key": "proposal", "label": "Proposal sent", "tone": "info"}, {"key": "contract", "label": "Contract", "tone": "info"}, {"key": "won", "label": "Won", "tone": "success"}, {"key": "lost", "label": "Lost", "tone": ""}], "closed_statuses": ["lost", "won"], "fields": [{"key": "service", "label": "Service", "type": "text"}, {"key": "owner", "label": "Owner", "type": "text"}, {"key": "proposal", "label": "Proposal", "type": "select", "options": ["Not sent", "Sent", "Accepted", "Declined"]}, {"key": "next_step", "label": "Next step", "type": "date"}], "columns": ["service", "owner", "proposal"], "notice": null}, {"key": "projects", "singular": "Project", "plural": "Projects", "icon": "work", "title_label": "Project", "link_person": true, "statuses": [{"key": "planning", "label": "Planning", "tone": "warning"}, {"key": "active", "label": "Active", "tone": "info"}, {"key": "on_hold", "label": "On hold", "tone": "info"}, {"key": "completed", "label": "Completed", "tone": "success"}, {"key": "cancelled", "label": "Cancelled", "tone": ""}], "closed_statuses": ["cancelled", "completed"], "fields": [{"key": "lead", "label": "Project lead", "type": "text"}, {"key": "milestone", "label": "Next milestone", "type": "text"}, {"key": "milestone_date", "label": "Milestone date", "type": "date"}], "columns": ["lead", "milestone", "milestone_date"], "notice": null}]}$j$::jsonb),
  ('real_estate', array['realestate','property','estateagent'], $j${"types": [{"key": "requirements", "singular": "Requirement", "plural": "Requirements", "icon": "person_search", "title_label": "Requirement", "link_person": true, "statuses": [{"key": "active", "label": "Active", "tone": "warning"}, {"key": "matched", "label": "Matched", "tone": "info"}, {"key": "paused", "label": "Paused", "tone": "info"}, {"key": "closed", "label": "Closed", "tone": "success"}], "closed_statuses": ["closed"], "fields": [{"key": "intent", "label": "Looking to", "type": "select", "options": ["Buy", "Rent", "Sell", "Let"]}, {"key": "locations", "label": "Preferred locations", "type": "text"}, {"key": "budget", "label": "Budget range (free text)", "type": "text"}, {"key": "property_type", "label": "Property type", "type": "text"}, {"key": "agent", "label": "Agent", "type": "text"}, {"key": "next_follow_up", "label": "Next follow-up", "type": "date"}], "columns": ["intent", "locations", "agent"], "notice": null}, {"key": "properties", "singular": "Property", "plural": "Properties", "icon": "apartment", "title_label": "Property", "link_person": false, "statuses": [{"key": "available", "label": "Available", "tone": "warning"}, {"key": "under_offer", "label": "Under offer", "tone": "info"}, {"key": "sold", "label": "Sold", "tone": "success"}, {"key": "let", "label": "Let", "tone": "success"}, {"key": "withdrawn", "label": "Withdrawn", "tone": ""}], "closed_statuses": ["let", "sold", "withdrawn"], "fields": [{"key": "reference", "label": "Listing reference", "type": "text", "unique": true}, {"key": "address", "label": "Address", "type": "text"}, {"key": "kind", "label": "Type", "type": "text"}, {"key": "listing_source", "label": "Listing system", "type": "text"}, {"key": "checked_on", "label": "Availability last checked", "type": "date"}], "columns": ["reference", "address", "checked_on"], "notice": "Availability is only as current as your listing system. Check it before telling a buyer a property is available."}, {"key": "viewings", "singular": "Viewing", "plural": "Viewings", "icon": "key", "title_label": "Viewing", "link_person": true, "statuses": [{"key": "requested", "label": "Requested", "tone": "warning"}, {"key": "booked", "label": "Booked", "tone": "info"}, {"key": "done", "label": "Done", "tone": "success"}, {"key": "no_show", "label": "No-show", "tone": ""}, {"key": "cancelled", "label": "Cancelled", "tone": ""}], "closed_statuses": ["cancelled", "done", "no_show"], "fields": [{"key": "property_ref", "label": "Listing reference", "type": "text"}, {"key": "viewing_at", "label": "Viewing", "type": "datetime"}, {"key": "agent", "label": "Agent", "type": "text"}, {"key": "feedback", "label": "Feedback", "type": "longtext"}], "columns": ["property_ref", "viewing_at", "agent"], "notice": null}, {"key": "deals", "singular": "Deal", "plural": "Deals", "icon": "handshake", "title_label": "Deal", "link_person": true, "statuses": [{"key": "enquiry", "label": "Enquiry", "tone": "warning"}, {"key": "viewing", "label": "Viewing", "tone": "info"}, {"key": "offer", "label": "Offer", "tone": "info"}, {"key": "negotiation", "label": "Negotiation", "tone": "info"}, {"key": "contract", "label": "Contract", "tone": "info"}, {"key": "closed_won", "label": "Completed", "tone": "success"}, {"key": "closed_lost", "label": "Lost", "tone": ""}], "closed_statuses": ["closed_lost", "closed_won"], "fields": [{"key": "property_ref", "label": "Listing reference", "type": "text"}, {"key": "agent", "label": "Agent", "type": "text"}, {"key": "next_milestone", "label": "Next milestone", "type": "text"}, {"key": "milestone_date", "label": "Milestone date", "type": "date"}], "columns": ["property_ref", "agent", "next_milestone"], "notice": null}]}$j$::jsonb),
  ('restaurant', array['restaurant','cafe','foodandbeverage'], $j${"types": [{"key": "events", "singular": "Event or catering enquiry", "plural": "Events and catering", "icon": "celebration", "title_label": "Enquiry", "link_person": true, "statuses": [{"key": "new", "label": "New", "tone": "warning"}, {"key": "quoted", "label": "Quoted", "tone": "info"}, {"key": "confirmed", "label": "Confirmed", "tone": "info"}, {"key": "completed", "label": "Completed", "tone": "success"}, {"key": "declined", "label": "Declined", "tone": ""}], "closed_statuses": ["completed", "declined"], "fields": [{"key": "kind", "label": "Type", "type": "select", "options": ["Private dining", "Catering", "Event"]}, {"key": "event_date", "label": "Date", "type": "datetime"}, {"key": "guests", "label": "Guests", "type": "number"}, {"key": "details", "label": "Details", "type": "longtext"}], "columns": ["kind", "event_date", "guests"], "notice": null}, {"key": "requests", "singular": "Special request", "plural": "Special requests", "icon": "star", "title_label": "Request", "link_person": true, "statuses": [{"key": "open", "label": "Open", "tone": "warning"}, {"key": "handled", "label": "Handled", "tone": "success"}], "closed_statuses": ["handled"], "fields": [{"key": "reservation_date", "label": "Reservation date", "type": "datetime"}, {"key": "request", "label": "Request", "type": "longtext"}], "columns": ["reservation_date", "request"], "notice": null}]}$j$::jsonb),
  ('travel', array['travel','travelagency','tourism'], $j${"types": [{"key": "trips", "singular": "Trip", "plural": "Trips", "icon": "luggage", "title_label": "Trip", "link_person": true, "statuses": [{"key": "enquiry", "label": "Enquiry", "tone": "warning"}, {"key": "quoted", "label": "Quoted", "tone": "info"}, {"key": "booked", "label": "Booked", "tone": "info"}, {"key": "documents", "label": "Documents pending", "tone": "info"}, {"key": "departed", "label": "Departed", "tone": "info"}, {"key": "returned", "label": "Returned", "tone": "success"}, {"key": "cancelled", "label": "Cancelled", "tone": ""}], "closed_statuses": ["cancelled", "returned"], "fields": [{"key": "destination", "label": "Destination", "type": "text", "required": true}, {"key": "depart", "label": "Departure", "type": "date"}, {"key": "return_date", "label": "Return", "type": "date"}, {"key": "travellers", "label": "Travellers", "type": "number"}, {"key": "budget", "label": "Budget note", "type": "text"}, {"key": "documents_ready", "label": "Documents ready", "type": "bool"}], "columns": ["destination", "depart", "travellers"], "notice": "Flight, hotel and supplier availability must come from your booking systems or confirmed staff updates."}, {"key": "bookings", "singular": "Booking", "plural": "Bookings", "icon": "confirmation_number", "title_label": "Booking", "link_person": true, "statuses": [{"key": "pending", "label": "Pending", "tone": "warning"}, {"key": "confirmed", "label": "Confirmed", "tone": "info"}, {"key": "ticketed", "label": "Ticketed", "tone": "success"}, {"key": "cancelled", "label": "Cancelled", "tone": ""}], "closed_statuses": ["cancelled", "ticketed"], "fields": [{"key": "kind", "label": "Type", "type": "select", "options": ["Flight", "Hotel", "Tour", "Transfer", "Other"]}, {"key": "supplier", "label": "Supplier", "type": "text"}, {"key": "supplier_ref", "label": "Supplier reference", "type": "text", "unique": true}, {"key": "payment_due", "label": "Payment milestone", "type": "date"}], "columns": ["kind", "supplier", "supplier_ref"], "notice": null}]}$j$::jsonb),
  ('hospitality', array['hospitality','hotel','resort'], $j${"types": [{"key": "stays", "singular": "Stay", "plural": "Stays", "icon": "hotel", "title_label": "Stay", "link_person": true, "statuses": [{"key": "booked", "label": "Booked", "tone": "warning"}, {"key": "pre_arrival", "label": "Pre-arrival sent", "tone": "info"}, {"key": "checked_in", "label": "Checked in", "tone": "info"}, {"key": "checked_out", "label": "Checked out", "tone": "success"}, {"key": "cancelled", "label": "Cancelled", "tone": ""}], "closed_statuses": ["cancelled", "checked_out"], "fields": [{"key": "pms_ref", "label": "Booking reference", "type": "text", "unique": true}, {"key": "unit", "label": "Room or unit", "type": "text"}, {"key": "arrival", "label": "Arrival", "type": "date"}, {"key": "departure", "label": "Departure", "type": "date"}], "columns": ["pms_ref", "unit", "arrival"], "notice": "Your property-management system stays the source of truth for rooms and confirmed reservations."}, {"key": "guest_requests", "singular": "Guest request", "plural": "Guest requests", "icon": "room_service", "title_label": "Request", "link_person": true, "statuses": [{"key": "open", "label": "Open", "tone": "warning"}, {"key": "assigned", "label": "Assigned", "tone": "info"}, {"key": "done", "label": "Done", "tone": "success"}, {"key": "escalated", "label": "Escalated", "tone": "info"}], "closed_statuses": ["done"], "fields": [{"key": "category", "label": "Category", "type": "select", "options": ["Request", "Complaint", "Housekeeping", "Maintenance", "Other"]}, {"key": "unit", "label": "Room or unit", "type": "text"}, {"key": "assigned", "label": "Assigned to", "type": "text"}, {"key": "details", "label": "Details", "type": "longtext"}], "columns": ["category", "unit", "assigned"], "notice": null}, {"key": "groups", "singular": "Group or event enquiry", "plural": "Group and event enquiries", "icon": "groups", "title_label": "Enquiry", "link_person": true, "statuses": [{"key": "new", "label": "New", "tone": "warning"}, {"key": "quoted", "label": "Quoted", "tone": "info"}, {"key": "confirmed", "label": "Confirmed", "tone": "success"}, {"key": "closed", "label": "Closed", "tone": "success"}], "closed_statuses": ["closed", "confirmed"], "fields": [{"key": "kind", "label": "Type", "type": "text"}, {"key": "dates", "label": "Dates", "type": "text"}, {"key": "size", "label": "Group size", "type": "number"}, {"key": "details", "label": "Details", "type": "longtext"}], "columns": ["kind", "dates", "size"], "notice": null}]}$j$::jsonb)
  on conflict (key) do update set match = excluded.match, config = excluded.config, updated_at = now();

-- ---------- copy the industry's preset into a business (first open) ----------
create or replace function public.zella_apply_crm_preset(p_business_id uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare v_name text; v_key text; v_cfg jsonb; t jsonb; i integer := 0; n integer := 0; v_rows integer;
begin
  select regexp_replace(lower(coalesce(ind.name, '')), '[^a-z]', '', 'g') into v_name
    from public.businesses b left join public.industries ind on ind.id = b.industry_id where b.id = p_business_id;
  if not found then raise exception 'NOT_ALLOWED'; end if;
  select p.key, p.config into v_key, v_cfg from public.industry_crm_presets p where v_name = any (p.match) order by p.key limit 1;
  if v_key is null then select p.key, p.config into v_key, v_cfg from public.industry_crm_presets p where p.key = 'other'; end if;
  if v_key is null then return 0; end if;
  for t in select * from jsonb_array_elements(v_cfg -> 'types') loop
    i := i + 1;
    insert into public.crm_record_types (business_id, key, singular, plural, icon, title_label, link_person, statuses, closed_statuses, fields, columns, notice, position, preset_key)
    values (p_business_id, t ->> 'key', t ->> 'singular', t ->> 'plural', coalesce(t ->> 'icon', 'folder'), coalesce(t ->> 'title_label', 'Name'),
            coalesce((t ->> 'link_person')::boolean, true), t -> 'statuses',
            coalesce((select array_agg(x) from jsonb_array_elements_text(t -> 'closed_statuses') x), '{}'),
            t -> 'fields', coalesce((select array_agg(x) from jsonb_array_elements_text(t -> 'columns') x), '{}'),
            nullif(t ->> 'notice', ''), i, v_key)
    on conflict (business_id, key) do nothing;
    get diagnostics v_rows = row_count;
    n := n + v_rows;
  end loop;
  -- Industry changed: hide the old industry's record types that were never used.
  update public.crm_record_types ty set enabled = false, updated_at = now()
   where ty.business_id = p_business_id and ty.preset_key is distinct from v_key and ty.enabled
     and not exists (select 1 from jsonb_array_elements(v_cfg -> 'types') nt where nt ->> 'key' = ty.key)
     and not exists (select 1 from public.crm_records r where r.business_id = ty.business_id and r.type_key = ty.key);
  return n;
end $$;

revoke all on function public.zella_apply_crm_preset(uuid) from public, anon, authenticated;

-- Members opening their CRM: makes sure the starting set exists (adds only what is missing).
-- Nothing is built while the admin is still going through the setup steps.
create or replace function public.zella_ensure_crm_types(p_business_id uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare v_status text;
begin
  if auth.uid() is not null and not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  select onboarding_status into v_status from public.businesses where id = p_business_id;
  if v_status is null or v_status not in ('testing', 'ready', 'active', 'paused') then return 0; end if;
  return public.zella_apply_crm_preset(p_business_id);
end $$;

-- The CRM is built when the admin finishes the setup steps (status reaches testing, ready or active),
-- and rebuilt if the industry is changed after that. Never blocks the admin's save.
create or replace function public.zella_crm_on_industry() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.industry_id is not null and new.onboarding_status in ('testing', 'ready', 'active', 'paused')
     and (tg_op = 'INSERT' or new.industry_id is distinct from old.industry_id or new.onboarding_status is distinct from old.onboarding_status) then
    begin
      perform public.zella_apply_crm_preset(new.id);
    exception when others then
      raise warning 'zella_crm_on_industry: %', sqlerrm;
    end;
  end if;
  return new;
end $$;
revoke all on function public.zella_crm_on_industry() from public, anon, authenticated;
drop trigger if exists zella_crm_on_industry on public.businesses;
create trigger zella_crm_on_industry after insert or update of industry_id, onboarding_status on public.businesses
  for each row execute function public.zella_crm_on_industry();

-- ---------- validation shared by every write ----------
create or replace function public.zella_crm_clean_data(p_fields jsonb, p_data jsonb, out cleaned jsonb, out unique_key text)
language plpgsql set search_path = public as $$
declare f jsonb; k text; v text; lbl text; ty text; out_obj jsonb := '{}'::jsonb;
begin
  for f in select * from jsonb_array_elements(coalesce(p_fields, '[]'::jsonb)) loop
    k := f ->> 'key'; lbl := f ->> 'label'; ty := f ->> 'type';
    v := nullif(trim(coalesce(p_data ->> k, '')), '');
    if v is null then
      if coalesce((f ->> 'required')::boolean, false) and ty <> 'bool' then raise exception 'FIELD_REQUIRED:%', lbl; end if;
      continue;
    end if;
    if ty = 'number' then
      begin perform v::numeric; exception when others then raise exception 'BAD_FIELD:%', lbl; end;
      out_obj := out_obj || jsonb_build_object(k, v::numeric);
    elsif ty = 'bool' then
      out_obj := out_obj || jsonb_build_object(k, v in ('true', 't', '1', 'yes'));
    elsif ty = 'date' then
      begin perform v::date; exception when others then raise exception 'BAD_FIELD:%', lbl; end;
      out_obj := out_obj || jsonb_build_object(k, v::date::text);
    elsif ty = 'datetime' then
      begin perform v::timestamptz; exception when others then raise exception 'BAD_FIELD:%', lbl; end;
      out_obj := out_obj || jsonb_build_object(k, v);
    elsif ty = 'select' then
      if not (f -> 'options') ? v then raise exception 'BAD_FIELD:%', lbl; end if;
      out_obj := out_obj || jsonb_build_object(k, v);
    elsif ty = 'email' then
      if v !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'BAD_FIELD:%', lbl; end if;
      out_obj := out_obj || jsonb_build_object(k, lower(v));
    else
      out_obj := out_obj || jsonb_build_object(k, left(v, 4000));
    end if;
    if coalesce((f ->> 'unique')::boolean, false) then unique_key := lower(regexp_replace(v, '[^[:alnum:]]', '', 'g')); end if;
  end loop;
  cleaned := out_obj;
end $$;

-- ---------- one writer for staff, the AI and automations ----------
create or replace function public.zella_crm_write_record(
  p_actor uuid, p_source text, p_business_id uuid, p_type_key text, p_id uuid, p_title text, p_status text,
  p_customer_id uuid, p_assigned_to uuid, p_due_at timestamptz, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ty record; v_status text; v_clean jsonb; v_ukey text; v_dup uuid; v_id uuid; v_old_status text;
begin
  select * into ty from public.crm_record_types where business_id = p_business_id and key = p_type_key and enabled;
  if not found then raise exception 'NOT_VALID'; end if;
  if nullif(trim(coalesce(p_title, '')), '') is null then raise exception 'EMPTY_TITLE'; end if;
  if p_customer_id is not null and not exists (select 1 from public.customers where id = p_customer_id and business_id = p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if ty.link_person = false then p_customer_id := null; end if;
  select c.cleaned, c.unique_key into v_clean, v_ukey from public.zella_crm_clean_data(ty.fields, p_data) c;
  if p_id is not null then
    select status into v_old_status from public.crm_records
      where id = p_id and business_id = p_business_id and type_key = p_type_key and archived_at is null for update;
    if not found then raise exception 'NOT_ALLOWED'; end if;
  end if;
  v_status := coalesce(nullif(p_status, ''), v_old_status, ty.statuses -> 0 ->> 'key');
  if not exists (select 1 from jsonb_array_elements(ty.statuses) s where s ->> 'key' = v_status) then raise exception 'NOT_VALID'; end if;
  if v_ukey is not null then
    select id into v_dup from public.crm_records
      where business_id = p_business_id and type_key = p_type_key and unique_key = v_ukey and archived_at is null and id is distinct from p_id limit 1;
    if v_dup is not null then raise exception 'DUPLICATE:%', v_dup; end if;
  end if;
  if p_id is null then
    insert into public.crm_records (business_id, type_key, title, status, customer_id, assigned_to, due_at, data, unique_key, source, created_by, closed_at)
    values (p_business_id, p_type_key, trim(p_title), v_status, p_customer_id, p_assigned_to, p_due_at, v_clean, v_ukey, p_source, p_actor,
            case when v_status = any (ty.closed_statuses) then now() end)
    returning id into v_id;
    insert into public.crm_record_events (business_id, record_id, kind, detail, actor) values (p_business_id, v_id, 'created', null, p_actor);
  else
    update public.crm_records set title = trim(p_title), status = v_status, customer_id = p_customer_id, assigned_to = p_assigned_to, due_at = p_due_at,
      data = v_clean, unique_key = v_ukey, updated_at = now(),
      closed_at = case when v_status = any (ty.closed_statuses) then coalesce(closed_at, now()) else null end
      where id = p_id;
    v_id := p_id;
    insert into public.crm_record_events (business_id, record_id, kind, detail, actor) values (p_business_id, v_id, 'edited', null, p_actor);
    if v_old_status <> v_status then
      insert into public.crm_record_events (business_id, record_id, kind, detail, actor) values (p_business_id, v_id, 'status', v_old_status || ' → ' || v_status, p_actor);
    end if;
  end if;
  return jsonb_build_object('id', v_id);
end $$;
revoke all on function public.zella_crm_write_record(uuid, text, uuid, text, uuid, text, text, uuid, uuid, timestamptz, jsonb) from public, anon, authenticated;
revoke all on function public.zella_crm_clean_data(jsonb, jsonb) from public, anon, authenticated;

create or replace function public.zella_save_record(p_business_id uuid, p_type_key text, p_id uuid, p_title text, p_status text,
  p_customer_id uuid default null, p_assigned_to uuid default null, p_due_at timestamptz default null, p_data jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.zella_is_member(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  return public.zella_crm_write_record(auth.uid(), 'staff', p_business_id, p_type_key, p_id, p_title, p_status, p_customer_id, p_assigned_to, p_due_at, p_data);
end $$;

create or replace function public.zella_set_record_status(p_id uuid, p_status text, p_note text default null) returns boolean
language plpgsql security definer set search_path = public as $$
declare r record; ty record;
begin
  select * into r from public.crm_records where id = p_id and archived_at is null for update;
  if not found or not public.zella_is_member(r.business_id) then raise exception 'NOT_ALLOWED'; end if;
  select * into ty from public.crm_record_types where business_id = r.business_id and key = r.type_key;
  if not exists (select 1 from jsonb_array_elements(ty.statuses) s where s ->> 'key' = p_status) then raise exception 'NOT_VALID'; end if;
  if r.status = p_status then return true; end if;
  update public.crm_records set status = p_status, updated_at = now(),
    closed_at = case when p_status = any (ty.closed_statuses) then coalesce(closed_at, now()) else null end where id = p_id;
  insert into public.crm_record_events (business_id, record_id, kind, detail, actor)
    values (r.business_id, p_id, 'status', r.status || ' → ' || p_status || coalesce(' · ' || nullif(trim(p_note), ''), ''), auth.uid());
  return true;
end $$;

create or replace function public.zella_add_record_note(p_id uuid, p_note text) returns boolean
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  select * into r from public.crm_records where id = p_id and archived_at is null;
  if not found or not public.zella_is_member(r.business_id) then raise exception 'NOT_ALLOWED'; end if;
  if nullif(trim(coalesce(p_note, '')), '') is null then raise exception 'EMPTY_TITLE'; end if;
  insert into public.crm_record_events (business_id, record_id, kind, detail, actor) values (r.business_id, p_id, 'note', left(trim(p_note), 2000), auth.uid());
  update public.crm_records set updated_at = now() where id = p_id;
  return true;
end $$;

create or replace function public.zella_archive_record(p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  select * into r from public.crm_records where id = p_id and archived_at is null;
  if not found or not public.zella_can_manage(r.business_id) then raise exception 'NOT_ALLOWED'; end if;
  update public.crm_records set archived_at = now(), updated_at = now() where id = p_id;
  insert into public.crm_record_events (business_id, record_id, kind, detail, actor) values (r.business_id, p_id, 'archived', null, auth.uid());
  return true;
end $$;

-- ---------- owners tailor their own CRM (labels, statuses, fields, on/off) ----------
create or replace function public.zella_save_record_type(p_business_id uuid, p_key text, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ty record; v_sing text; v_plur text; v_st jsonb; v_closed text[]; v_fields jsonb; v_cols text[]; v_enabled boolean; v_pos integer;
        f jsonb; o jsonb; v_keys text[]; k text; v_uniq integer;
begin
  if not public.zella_can_manage(p_business_id) then raise exception 'NOT_ALLOWED'; end if;
  if p_key is null or p_key !~ '^[a-z][a-z0-9_]{1,40}$' then raise exception 'NOT_VALID'; end if;
  select * into ty from public.crm_record_types where business_id = p_business_id and key = p_key for update;
  v_sing := coalesce(nullif(trim(p_patch ->> 'singular'), ''), ty.singular);
  v_plur := coalesce(nullif(trim(p_patch ->> 'plural'), ''), ty.plural);
  if v_sing is null or v_plur is null then raise exception 'EMPTY_TITLE'; end if;
  v_enabled := coalesce((p_patch ->> 'enabled')::boolean, ty.enabled, true);
  v_pos := coalesce((p_patch ->> 'position')::integer, ty.position, 99);
  v_st := coalesce(p_patch -> 'statuses', ty.statuses, '[{"key":"open","label":"Open","tone":"warning"},{"key":"done","label":"Done","tone":"success"}]'::jsonb);
  v_fields := coalesce(p_patch -> 'fields', ty.fields, '[]'::jsonb);
  if jsonb_typeof(v_st) <> 'array' or jsonb_array_length(v_st) = 0 or jsonb_typeof(v_fields) <> 'array' then raise exception 'NOT_VALID'; end if;
  -- statuses: slug keys, labels, and none that existing records still use may disappear
  v_keys := '{}';
  for o in select * from jsonb_array_elements(v_st) loop
    if (o ->> 'key') !~ '^[a-z][a-z0-9_]{0,40}$' or nullif(trim(o ->> 'label'), '') is null then raise exception 'NOT_VALID'; end if;
    v_keys := v_keys || (o ->> 'key');
  end loop;
  if cardinality(v_keys) <> (select count(distinct x) from unnest(v_keys) x) then raise exception 'NOT_VALID'; end if;
  if ty.id is not null and exists (select 1 from public.crm_records r where r.business_id = p_business_id and r.type_key = p_key and not (r.status = any (v_keys))) then raise exception 'STATUS_IN_USE'; end if;
  v_closed := coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p_patch -> 'closed_statuses', to_jsonb(ty.closed_statuses), '[]'::jsonb)) x where x = any (v_keys)), '{}');
  -- fields: slug keys, known types, selects have options, one unique field, existing fields can't be removed or retyped
  v_keys := '{}'; v_uniq := 0;
  for f in select * from jsonb_array_elements(v_fields) loop
    k := f ->> 'key';
    if k !~ '^[a-z][a-z0-9_]{0,40}$' or nullif(trim(f ->> 'label'), '') is null
       or (f ->> 'type') not in ('text', 'longtext', 'select', 'date', 'datetime', 'number', 'phone', 'email', 'bool') then raise exception 'NOT_VALID'; end if;
    if (f ->> 'type') = 'select' and (jsonb_typeof(f -> 'options') <> 'array' or jsonb_array_length(f -> 'options') = 0) then raise exception 'NOT_VALID'; end if;
    if coalesce((f ->> 'unique')::boolean, false) then v_uniq := v_uniq + 1; end if;
    v_keys := v_keys || k;
  end loop;
  if v_uniq > 1 or cardinality(v_keys) <> (select count(distinct x) from unnest(v_keys) x) then raise exception 'NOT_VALID'; end if;
  if ty.id is not null then
    for o in select * from jsonb_array_elements(ty.fields) loop
      if not (o ->> 'key') = any (v_keys) then raise exception 'FIELD_REMOVED:%', o ->> 'label'; end if;
      if (select x ->> 'type' from jsonb_array_elements(v_fields) x where x ->> 'key' = o ->> 'key') <> (o ->> 'type') then raise exception 'FIELD_LOCKED:%', o ->> 'label'; end if;
    end loop;
  end if;
  v_cols := coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p_patch -> 'columns', to_jsonb(ty.columns), '[]'::jsonb)) x where x = any (v_keys)), '{}');
  if cardinality(v_cols) = 0 then v_cols := v_keys[1:3]; end if;
  if ty.id is null then
    insert into public.crm_record_types (business_id, key, singular, plural, icon, title_label, link_person, statuses, closed_statuses, fields, columns, enabled, position)
    values (p_business_id, p_key, v_sing, v_plur, coalesce(nullif(p_patch ->> 'icon', ''), 'folder'), coalesce(nullif(trim(p_patch ->> 'title_label'), ''), 'Name'),
            coalesce((p_patch ->> 'link_person')::boolean, true), v_st, v_closed, v_fields, v_cols, v_enabled, v_pos);
  else
    update public.crm_record_types set singular = v_sing, plural = v_plur, enabled = v_enabled, position = v_pos, statuses = v_st, closed_statuses = v_closed,
      fields = v_fields, columns = v_cols, title_label = coalesce(nullif(trim(p_patch ->> 'title_label'), ''), title_label), updated_at = now()
      where id = ty.id;
  end if;
  return jsonb_build_object('key', p_key);
end $$;

-- ---------- AI receptionist: create a record or flag a possible duplicate ----------
create or replace function public.zella_ai_save_record(p_business_id uuid, p_type_key text, p_customer_id uuid, p_title text,
  p_data jsonb default '{}'::jsonb, p_follow_up_title text default null, p_follow_up_at timestamptz default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_res jsonb; v_dup uuid; v_msg text;
begin
  begin
    v_res := public.zella_crm_write_record(null, 'ai', p_business_id, p_type_key, null, p_title, null, p_customer_id, null, null, p_data);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like 'DUPLICATE:%' then
      v_dup := substring(v_msg from 11)::uuid;
      perform public.zella_create_task(p_business_id, p_customer_id, 'duplicate_review', 'Possible duplicate: ' || left(coalesce(p_title, ''), 80),
        'The AI receptionist found a record that may already exist. Please check it.', 'normal', now() + interval '1 day', null, 'ai', v_dup);
      return jsonb_build_object('status', 'duplicate_review', 'existing_id', v_dup);
    end if;
    raise;
  end;
  if nullif(trim(coalesce(p_follow_up_title, '')), '') is not null then
    perform public.zella_create_task(p_business_id, p_customer_id, 'follow_up', p_follow_up_title, null, 'normal', p_follow_up_at, null, 'ai', (v_res ->> 'id')::uuid);
  end if;
  return jsonb_build_object('status', 'created', 'id', v_res -> 'id');
end $$;

revoke all on function public.zella_ensure_crm_types(uuid), public.zella_save_record(uuid, text, uuid, text, text, uuid, uuid, timestamptz, jsonb),
  public.zella_set_record_status(uuid, text, text), public.zella_add_record_note(uuid, text), public.zella_archive_record(uuid),
  public.zella_save_record_type(uuid, text, jsonb) from public, anon;
grant execute on function public.zella_ensure_crm_types(uuid), public.zella_save_record(uuid, text, uuid, text, text, uuid, uuid, timestamptz, jsonb),
  public.zella_set_record_status(uuid, text, text), public.zella_add_record_note(uuid, text), public.zella_archive_record(uuid),
  public.zella_save_record_type(uuid, text, jsonb) to authenticated, service_role;
revoke all on function public.zella_ai_save_record(uuid, text, uuid, text, jsonb, text, timestamptz) from public, anon, authenticated;
grant execute on function public.zella_ai_save_record(uuid, text, uuid, text, jsonb, text, timestamptz) to service_role;
