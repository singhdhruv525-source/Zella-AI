"""Generates sql/target/industries_seed.sql: the 28 Zella Voice industry configurations (docs/ARCHITECTURE.md §22.4).

Proposed defaults, to validate with pilot businesses. Prices are never seeded: businesses enter their own.
Run: python3 sql/target/generate_industries.py   (writes industries_seed.sql next to this file)
"""
import json
import os

CORE = ["today", "customers", "leads", "calls", "callbacks", "inbox", "calendar", "knowledge",
        "automations", "reports", "team", "settings"]

MODULES = {
    # core
    "today": "Today", "customers": "Customers", "leads": "Leads", "calls": "Calls", "callbacks": "Callbacks",
    "inbox": "Inbox", "calendar": "Calendar", "knowledge": "Knowledge", "automations": "Automations",
    "reports": "Reports", "team": "Team", "settings": "Settings",
    # industry modules
    "check_in": "Check-ins", "waitlist": "Waitlist", "reviews": "Reviews", "packages": "Packages",
    "classes": "Classes", "memberships": "Memberships", "tables": "Tables", "rooms": "Rooms", "trips": "Trips",
    "enrolments": "Enrolments", "pets": "Pets", "recalls": "Recalls", "matters": "Matters", "accounts": "Accounts",
    "policies": "Policies", "claims": "Claims", "projects": "Projects", "quotes": "Quotes", "listings": "Listings",
    "properties": "Properties", "maintenance": "Maintenance", "dispatch": "Dispatch",
    "recurring_visits": "Recurring visits", "seasonal": "Seasonal services", "vehicles": "Vehicles",
    "events": "Events", "orders": "Orders", "money": "Money", "records": "Records",
}

BASE_AUTOMATIONS = {"booking_confirmation": True, "reminders": True, "missed_call_follow_up": True,
                    "lead_follow_up": True}
BASE_KPIS = ["answered_rate", "missed_calls", "missed_call_recovery_rate", "bookings", "speed_to_lead"]
BASE_TOOLS = ["search_knowledge", "check_open_hours", "lookup_caller", "update_caller", "take_message",
              "request_follow_up", "report_emergency", "transfer_to_human", "report_unanswered_question"]
BOOKING_TOOLS = ["check_availability", "book_appointment", "find_my_appointments", "reschedule_appointment",
                 "cancel_appointment"]
REGULATED_LINES = ["Never give medical, legal or financial advice.",
                   "Never confirm or deny that a person is a client or patient.",
                   "Never repeat sensitive details back to the caller."]


def rt(key, name, fields, statuses, unique=None, private=None):
    return {"key": key, "name": name, "schema": {"fields": fields, "statuses": statuses,
                                                  "unique": unique, "private": private or []}}


def svc(key, name, minutes, kind="staff"):
    return {"key": key, "name": name, "duration_min": minutes, "resource_kind": kind}


# key, name, booking model, regulated, terminology, modules (beyond core; first = default on, ~ = optional),
# record types, services, extra automations, extra KPIs, safety lines, booking questions, knowledge checklist
INDUSTRIES = [
    ("beauty_salon", "Beauty & Salon", "staff_appointment", False,
     {"customer": "client", "appointment": "appointment", "staff": "stylist"},
     ["check_in", "waitlist", "reviews", "~packages", "~money"],
     [rt("client_profile", "Client preferences", ["preferred_stylist", "allergies", "notes"], ["active"]),
      rt("colour_formula", "Colour formula", ["formula", "date", "stylist"], ["active", "archived"])],
     [svc("haircut", "Haircut", 45), svc("colour", "Colour", 120), svc("blow_dry", "Blow-dry", 30)],
     {"rebook_nudge": True, "review_request": True}, ["rebooking_rate", "no_show_rate"],
     [], ["Which service?", "Any preferred stylist?"], ["services and durations", "cancellation policy", "parking"]),
    ("spa_wellness", "Spa & Wellness", "staff_appointment", False,
     {"customer": "client", "appointment": "appointment", "staff": "therapist"},
     ["check_in", "waitlist", "packages", "~reviews", "~money"],
     [rt("treatment_notes", "Treatment notes", ["treatment", "notes", "contraindications"], ["active"], private=["contraindications"]),
      rt("package", "Package", ["name", "sessions_total", "sessions_used"], ["active", "used_up", "expired"])],
     [svc("massage_60", "Massage (60 min)", 60, "room"), svc("facial", "Facial", 60, "room")],
     {"intake_form": True, "rebook_nudge": True}, ["rebooking_rate"],
     [], ["Which treatment?", "Any health conditions we should know about?"], ["treatments", "intake requirements", "arrival time"]),
    ("fitness", "Fitness", "class", False,
     {"customer": "member", "appointment": "class booking", "staff": "instructor"},
     ["classes", "waitlist", "memberships", "~check_in", "~money"],
     [rt("membership", "Membership", ["plan_name", "start", "renewal_date", "member_id"], ["active", "paused", "cancelled"],
         unique="member_id", private=["member_id"])],
     [svc("group_class", "Group class", 60, "class"), svc("personal_training", "Personal training", 60)],
     {"class_reminder": True, "renewal_reminder": True}, ["class_fill_rate"],
     [], ["Which class and time?"], ["class schedule", "membership options", "what to bring"]),
    ("restaurant", "Restaurant", "table", False,
     {"customer": "guest", "appointment": "reservation", "staff": "host"},
     ["tables", "waitlist", "~reviews"],
     [rt("guest_notes", "Guest notes", ["allergies", "preferences", "occasions"], ["active"])],
     [svc("dinner", "Dinner reservation", 90, "table"), svc("lunch", "Lunch reservation", 60, "table")],
     {"no_show_follow_up": True}, ["covers_booked", "no_show_rate"],
     [], ["How many guests?", "Any allergies or occasion?"], ["opening hours", "menu highlights", "large-party policy"]),
    ("hospitality", "Hospitality", "stay", False,
     {"customer": "guest", "appointment": "stay", "staff": "front desk"},
     ["rooms", "check_in", "~reviews"],
     [rt("stay", "Stay", ["room_type", "check_in", "check_out", "guests"], ["reserved", "checked_in", "checked_out", "cancelled"])],
     [], {"pre_arrival": True, "checkout_thank_you": True}, ["occupancy"],
     [], ["Dates?", "How many guests?", "Room type?"], ["room types", "check-in time", "policies"]),
    ("travel", "Travel", "consultation", False,
     {"customer": "traveller", "appointment": "consultation", "staff": "agent"},
     ["trips", "quotes"],
     [rt("trip", "Trip", ["destination", "dates", "travellers", "documents"], ["enquiry", "quoted", "booked", "travelled"])],
     [svc("travel_consult", "Travel consultation", 30, "staff")], {"quote_follow_up": True}, ["quote_conversion"],
     [], ["Destination and dates?"], ["services offered", "booking process"]),
    ("education", "Education", "class", False,
     {"customer": "student", "appointment": "class", "staff": "teacher"},
     ["classes", "enrolments"],
     [rt("enrolment", "Enrolment", ["course", "start_date", "guardian_contact"], ["applied", "enrolled", "completed", "withdrawn"],
         private=["guardian_contact"])],
     [svc("lesson", "Lesson", 60, "class")], {"class_reminder": True}, ["enrolment_conversion"],
     [], ["Which course?", "Student's level?"], ["courses", "schedules", "fees policy"]),
    ("childcare", "Childcare", "class", True,
     {"customer": "parent", "appointment": "tour", "staff": "staff member"},
     ["enrolments", "check_in"],
     [rt("child", "Child", ["first_name", "date_of_birth", "allergies", "authorised_pickups"], ["enquiry", "enrolled", "left"],
         private=["date_of_birth", "allergies", "authorised_pickups"])],
     [svc("tour", "Centre tour", 30, "staff")], {}, ["enquiry_to_enrolment"],
     ["Never share or confirm any child's details."], ["Child's age?", "Days needed?"], ["age groups", "hours", "enrolment process"]),
    ("pet_care_veterinary", "Pet Care & Veterinary", "staff_appointment", False,
     {"customer": "pet owner", "appointment": "appointment", "staff": "vet"},
     ["pets", "check_in", "~reviews"],
     [rt("pet", "Pet", ["name", "species", "breed", "date_of_birth", "vaccinations"], ["active", "deceased"])],
     [svc("checkup", "Check-up", 30), svc("vaccination", "Vaccination", 20), svc("grooming", "Grooming", 90)],
     {"vaccination_reminder": True, "service_due": True}, ["recall_compliance"],
     ["For an emergency, tell the caller to go to the nearest emergency vet now."], ["Which pet?", "Reason for visit?"],
     ["services", "emergency process", "species treated"]),
    ("dental", "Dental", "staff_appointment", True,
     {"customer": "patient", "appointment": "appointment", "staff": "dentist"},
     ["recalls", "check_in"],
     [rt("patient", "Patient record", ["insurance_provider", "member_id", "notes"], ["active", "inactive"],
         private=["member_id", "notes"])],
     [svc("checkup_clean", "Check-up and clean", 45), svc("emergency_visit", "Emergency visit", 30)],
     {"recall_reminder": True}, ["recall_compliance"],
     ["For severe pain, swelling or bleeding, offer the earliest emergency slot or advise emergency care."],
     ["New or existing patient?", "Reason for visit?"], ["insurance accepted", "new patient process", "emergency process"]),
    ("healthcare", "Healthcare", "staff_appointment", True,
     {"customer": "patient", "appointment": "appointment", "staff": "provider"},
     ["check_in"],
     [rt("patient", "Patient record", ["insurance_provider", "member_id", "notes"], ["active", "inactive"],
         private=["member_id", "notes"])],
     [svc("consultation", "Consultation", 20)], {}, [],
     ["For a medical emergency, tell the caller to call 911 now."], ["New or existing patient?"],
     ["insurance accepted", "new patient process", "hours"]),
    ("legal", "Legal", "consultation", True,
     {"customer": "client", "appointment": "consultation", "staff": "attorney"},
     ["matters"],
     [rt("matter", "Matter", ["matter_reference", "practice_area", "opposing_party"], ["intake", "open", "closed"],
         unique="matter_reference", private=["opposing_party"])],
     [svc("initial_consultation", "Initial consultation", 30)], {}, ["intake_to_client"],
     ["Keep everything confidential; collect only intake basics."], ["Practice area?", "Any deadlines?"],
     ["practice areas", "consultation fees policy"]),
    ("financial_services", "Financial Services", "consultation", True,
     {"customer": "client", "appointment": "consultation", "staff": "advisor"},
     ["accounts"],
     [rt("client_profile", "Client profile", ["services", "notes"], ["prospect", "active", "inactive"], private=["notes"])],
     [svc("advice_meeting", "Advice meeting", 60)], {}, [],
     [], ["Topic of the meeting?"], ["services offered", "meeting process"]),
    ("insurance", "Insurance", "consultation", True,
     {"customer": "policyholder", "appointment": "consultation", "staff": "agent"},
     ["policies", "claims"],
     [rt("policy", "Policy", ["policy_number", "type", "renewal_date"], ["quoted", "active", "lapsed"], unique="policy_number"),
      rt("claim", "Claim", ["claim_number", "policy_number", "description"], ["reported", "in_review", "closed"], unique="claim_number")],
     [svc("quote_call", "Quote call", 30)], {"renewal_reminder": True}, [],
     [], ["New quote or existing policy?"], ["products", "claims process"]),
    ("professional_services", "Professional Services", "consultation", False,
     {"customer": "client", "appointment": "consultation", "staff": "consultant"},
     ["projects", "quotes", "~money"],
     [rt("project", "Project", ["name", "budget_range", "deadline"], ["enquiry", "quoted", "active", "done"])],
     [svc("discovery_call", "Discovery call", 30)], {"quote_follow_up": True}, ["quote_conversion"],
     [], ["What do you need help with?"], ["services", "process", "availability"]),
    ("real_estate", "Real Estate", "viewing", False,
     {"customer": "lead", "appointment": "viewing", "staff": "agent"},
     ["listings"],
     [rt("listing", "Listing", ["address", "price_text", "bedrooms", "status_note"], ["active", "under_offer", "sold", "withdrawn"])],
     [svc("viewing", "Viewing", 30)], {"speed_to_lead_call": True}, ["speed_to_lead"],
     [], ["Which property?", "Buying or renting?"], ["listings", "viewing process"]),
    ("property_management", "Property Management", "field_job", False,
     {"customer": "tenant", "appointment": "job", "staff": "technician"},
     ["properties", "maintenance", "dispatch"],
     [rt("property", "Property", ["address", "units", "access_code"], ["active", "inactive"], private=["access_code"]),
      rt("maintenance_request", "Maintenance request", ["property", "unit", "issue", "urgency"], ["new", "scheduled", "in_progress", "done"])],
     [svc("maintenance_visit", "Maintenance visit", 60, "technician")], {"job_status_update": True}, ["job_completion_time"],
     ["For gas leaks, flooding or no heat in freezing weather, treat as an emergency."], ["Property and unit?", "Is it urgent?"],
     ["emergency process", "service area"]),
    ("hvac", "HVAC", "field_job", False,
     {"customer": "customer", "appointment": "job", "staff": "technician"},
     ["dispatch", "recurring_visits", "quotes", "~money"],
     [rt("equipment", "Equipment", ["type", "brand", "install_date", "serial_number"], ["active", "replaced"], unique="serial_number"),
      rt("service_agreement", "Service agreement", ["plan", "renewal_date"], ["active", "expired"])],
     [svc("repair_visit", "Repair visit", 90, "technician"), svc("maintenance_visit", "Maintenance visit", 60, "technician")],
     {"service_due": True, "quote_follow_up": True, "job_status_update": True}, ["first_time_fix_rate"],
     ["No heat in freezing weather or a gas smell is an emergency: advise leaving and calling the gas company if gas."],
     ["Heating or cooling?", "Is it urgent?", "Service address?"], ["service area", "emergency fees policy", "arrival windows"]),
    ("plumbing", "Plumbing", "field_job", False,
     {"customer": "customer", "appointment": "job", "staff": "plumber"},
     ["dispatch", "quotes", "~money"],
     [rt("job", "Job", ["address", "issue", "urgency"], ["new", "scheduled", "in_progress", "done"])],
     [svc("repair_visit", "Repair visit", 60, "technician")], {"quote_follow_up": True, "job_status_update": True}, [],
     ["For active flooding, advise shutting off the water main if safe."], ["What's the issue?", "Is water leaking now?"],
     ["service area", "emergency process"]),
    ("electrical", "Electrical", "field_job", False,
     {"customer": "customer", "appointment": "job", "staff": "electrician"},
     ["dispatch", "quotes", "~money"],
     [rt("job", "Job", ["address", "issue", "urgency"], ["new", "scheduled", "in_progress", "done"])],
     [svc("repair_visit", "Repair visit", 60, "technician")], {"quote_follow_up": True, "job_status_update": True}, [],
     ["For sparks, burning smell or exposed live wires, advise staying clear and calling 911 if there is fire."],
     ["What's the issue?", "Is anything sparking or burning?"], ["service area", "emergency process"]),
    ("home_services", "Home Services", "field_job", False,
     {"customer": "customer", "appointment": "job", "staff": "technician"},
     ["dispatch", "quotes", "~money"],
     [rt("job", "Job", ["address", "service", "notes"], ["new", "scheduled", "in_progress", "done"])],
     [svc("service_visit", "Service visit", 60, "technician")], {"quote_follow_up": True}, [],
     [], ["Which service?", "Service address?"], ["services", "service area"]),
    ("cleaning_services", "Cleaning Services", "field_job", False,
     {"customer": "customer", "appointment": "visit", "staff": "cleaner"},
     ["recurring_visits", "dispatch", "properties"],
     [rt("property", "Property", ["address", "size", "access_code", "pets"], ["active", "inactive"], private=["access_code"])],
     [svc("standard_clean", "Standard clean", 120, "technician"), svc("deep_clean", "Deep clean", 240, "technician")],
     {"recurring_visit_reminder": True}, ["retention_rate"],
     ["Never read access codes aloud."], ["How often?", "Property size?"], ["services", "service area", "supplies policy"]),
    ("landscaping_lawn_care", "Landscaping & Lawn Care", "field_job", False,
     {"customer": "customer", "appointment": "visit", "staff": "crew"},
     ["recurring_visits", "seasonal", "properties"],
     [rt("property", "Property", ["address", "lot_size", "notes"], ["active", "inactive"])],
     [svc("mowing", "Mowing", 60, "vehicle"), svc("cleanup", "Seasonal cleanup", 180, "vehicle")],
     {"seasonal_reminder": True}, ["retention_rate"],
     [], ["Service address?", "One-off or recurring?"], ["services", "service area", "seasons"]),
    ("pest_control", "Pest Control", "field_job", False,
     {"customer": "customer", "appointment": "treatment", "staff": "technician"},
     ["recurring_visits", "properties"],
     [rt("treatment", "Treatment", ["pest", "products_used", "next_due"], ["scheduled", "done"])],
     [svc("inspection", "Inspection", 45, "technician"), svc("treatment", "Treatment", 60, "technician")],
     {"treatment_reminder": True}, ["retention_rate"],
     ["Share preparation and safety notes only from the business's knowledge."], ["Which pest?", "Service address?"],
     ["treatments", "preparation instructions", "service area"]),
    ("automotive", "Automotive", "staff_appointment", False,
     {"customer": "customer", "appointment": "service appointment", "staff": "technician"},
     ["vehicles", "quotes", "~money"],
     [rt("vehicle", "Vehicle", ["make", "model", "year", "vin", "mileage"], ["active", "sold"], unique="vin"),
      rt("repair_order", "Repair order", ["vehicle", "concern", "estimate_text"], ["open", "waiting_parts", "ready", "closed"])],
     [svc("oil_change", "Oil change", 45, "technician"), svc("diagnostic", "Diagnostic", 60, "technician")],
     {"repair_status_update": True, "service_due": True}, ["bay_utilisation"],
     [], ["Make and model?", "What's the concern?"], ["services", "warranty policy", "loaner policy"]),
    ("photography_events", "Photography & Events", "staff_appointment", False,
     {"customer": "client", "appointment": "booking", "staff": "photographer"},
     ["events", "quotes", "~money"],
     [rt("event", "Event", ["event_date", "venue", "package"], ["enquiry", "booked", "delivered"])],
     [svc("consultation", "Consultation", 30)], {"quote_follow_up": True, "event_reminder": True}, ["quote_conversion"],
     [], ["Event date?", "Type of event?"], ["packages", "booking deposit policy"]),
    ("ecommerce", "E-commerce", "none", False,
     {"customer": "customer", "appointment": "order", "staff": "support"},
     ["orders"],
     [rt("order", "Order", ["order_number", "status_note"], ["open", "shipped", "delivered", "returned"], unique="order_number")],
     [], {"order_status_reply": True, "booking_confirmation": False, "reminders": False}, ["order_enquiries"],
     ["Never offer or book appointments."], ["Order number?"], ["shipping policy", "returns policy"]),
    ("other", "Other", "general", False,
     {"customer": "customer", "appointment": "appointment", "staff": "staff"},
     ["~records", "~money"],
     [], [svc("appointment", "Appointment", 30)], {}, [],
     [], [], ["services", "hours", "location"]),
]

assert len(INDUSTRIES) == 28, len(INDUSTRIES)


def q(v):
    return "null" if v is None else "'" + str(v).replace("'", "''") + "'"


def j(v):
    return q(json.dumps(v, separators=(",", ":"))) + "::jsonb"


def arr(values):
    return "array[" + ",".join(q(v) for v in values) + "]::text[]" if values else "'{}'::text[]"


out = ["-- GENERATED by sql/target/generate_industries.py. Do not edit by hand (REL-10).",
       "-- The 28 Zella Voice industry configurations (docs/ARCHITECTURE.md §22.4). Proposed defaults, to validate with",
       "-- pilot businesses. No prices: businesses enter their own.", "begin;"]
out.append("insert into modules (key, name, core) values")
out.append(",\n".join(f"  ({q(k)}, {q(n)}, {str(k in CORE).lower()})" for k, n in MODULES.items()) + ";")

for (key, name, model, regulated, terms, mods, rtypes, services, autos, kpis, lines, questions, checklist) in INDUSTRIES:
    out.append(f"\n-- {name}")
    policies = {"follow_ups": "draft_only", "review_requests": False, "transcripts_to_staff": False,
                "relationship_neutral_previews": True, "legal_review_required": True} if regulated else {}
    out.append(f"insert into industries (key, name, regulated, booking_model, terminology, policies) values "
               f"({q(key)}, {q(name)}, {str(regulated).lower()}, {q(model)}, {j(terms)}, {j(policies)});")
    rows = [(m, "required") for m in CORE if not (m == "calendar" and model == "none")]
    for m in mods:
        rows.append((m[1:], "optional") if m.startswith("~") else (m, "default_on"))
    assert all(m in MODULES for m, _ in rows), key
    out.append("insert into industry_modules (industry_key, module_key, availability) values "
               + ", ".join(f"({q(key)}, {q(m)}, {q(a)})" for m, a in rows) + ";")
    for r in rtypes:
        out.append(f"insert into industry_record_types (industry_key, key, name, schema) values "
                   f"({q(key)}, {q(r['key'])}, {q(r['name'])}, {j(r['schema'])});")
    for s in services:
        out.append(f"insert into industry_services (industry_key, key, name, duration_min, resource_kind) values "
                   f"({q(key)}, {q(s['key'])}, {q(s['name'])}, {s['duration_min']}, {q(s['resource_kind'])});")
    all_autos = dict(BASE_AUTOMATIONS)
    all_autos.update(autos)
    if model == "none":
        all_autos.update({"booking_confirmation": False, "reminders": False})
    if regulated:
        all_autos["review_request"] = False
    out.append("insert into industry_automation_presets (industry_key, kind, enabled) values "
               + ", ".join(f"({q(key)}, {q(k)}, {str(v).lower()})" for k, v in all_autos.items()) + ";")
    out.append("insert into industry_kpis (industry_key, metric_key, position) values "
               + ", ".join(f"({q(key)}, {q(m)}, {i + 1})" for i, m in enumerate(dict.fromkeys(BASE_KPIS + kpis))) + ";")
    tools = BASE_TOOLS + ([] if model == "none" else BOOKING_TOOLS) + (["lookup_order"] if model == "none" else [])
    safety = lines + (REGULATED_LINES if regulated else [])
    out.append(f"insert into industry_ai_profiles (industry_key, tools, safety_lines, booking_questions, knowledge_checklist) values "
               f"({q(key)}, {arr(tools)}, {arr(safety)}, {arr(questions)}, {arr(checklist)});")

out.append("commit;\n")
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "industries_seed.sql")
with open(path, "w") as f:
    f.write("\n".join(out))
print(f"wrote {path}: {len(INDUSTRIES)} industries, {len(MODULES)} modules")
