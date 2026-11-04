import json
def S(*pairs):  # statuses: ("key","Label","tone")
    return [{"key": k, "label": l, "tone": t} for k, l, t in pairs]
def F(key, label, type="text", **kw):
    d = {"key": key, "label": label, "type": type}; d.update(kw); return d
def SEL(key, label, options, **kw): return F(key, label, "select", options=options, **kw)
def LINK(key, label, target, **kw): return F(key, label, "record", target=target, **kw)
def T(key, singular, plural, icon, title, statuses, closed, fields, columns=None, **kw):
    d = {"key": key, "singular": singular, "plural": plural, "icon": icon, "title_label": title, "statuses": statuses,
         "closed_statuses": closed, "fields": fields, "columns": columns or [f["key"] for f in fields[:3]]}
    d.update(kw); return d
def EXT(key, fields=(), **kw):  # extend an existing preset type: new fields + properties
    d = {"key": key, "add_fields": list(fields)}; d.update(kw); return d

WINDOW = SEL("arrival_window", "Arrival window", ["8–12", "12–4", "4–8", "Any time"])
ACCESS = F("access", "Access instructions", "longtext", sensitive=True)
PRIV_NOTE = "Private fields are shown only to managers and the person assigned, and every view is logged."
COVERAGE = T("coverage", "Insurance coverage", "Insurance coverage", "health_and_safety", "Carrier",
  S(("active", "Active", "success"), ("verify", "Needs verification", "warning"), ("inactive", "Inactive", "")), ["inactive"],
  [F("member_id", "Member ID", sensitive=True), F("subscriber", "Subscriber"), F("group_number", "Group number"), F("verified_on", "Last verified", "date")],
  ["subscriber", "verified_on"], notice=PRIV_NOTE)

P = {}  # preset key -> {"types": [...new or EXT], "match": [...] (optional)}
P["dental"] = {"types": [
  T("treatment_plans", "Treatment plan", "Treatment plans", "medical_services", "Treatment",
    S(("proposed", "Proposed", "info"), ("presented", "Presented", "warning"), ("accepted", "Accepted", "success"), ("scheduled", "Scheduled", "success"),
      ("completed", "Completed", ""), ("declined", "Declined", "")), ["completed", "declined"],
    [F("provider", "Provider"), F("estimate", "Estimate", "number"), F("insurance_estimate", "Insurance estimate", "number"), F("presented_on", "Presented on", "date"), F("follow_up_on", "Follow up on", "date")],
    ["provider", "estimate", "presented_on"], notice="Amounts are estimates for the patient, not charges. Record payments in Money."),
  COVERAGE,
  T("forms", "New-patient form", "New-patient forms", "assignment", "Form",
    S(("sent", "Sent", "warning"), ("received", "Received", "info"), ("reviewed", "Reviewed", "success")), ["reviewed"],
    [F("sent_on", "Sent on", "date"), F("received_on", "Received on", "date")]),
  EXT("recalls", [SEL("interval", "Recall interval", ["3 months", "6 months", "12 months"]), F("last_xray_on", "Last X-ray", "date")]),
]}
P["healthcare"] = {"types": [
  T("refill_requests", "Refill request", "Refill requests", "medication", "Patient and medication",
    S(("received", "Received", "warning"), ("sent", "Sent to provider", "info"), ("approved", "Approved", "success"), ("denied", "Denied", "")), ["approved", "denied"],
    [F("medication", "Medication", required=True), F("pharmacy", "Pharmacy"), F("prescriber", "Prescriber")],
    notice="The provider decides. Never confirm a prescription to a caller whose identity isn't checked."),
  T("prior_auths", "Prior authorization", "Prior authorizations", "verified", "Procedure",
    S(("to_submit", "To submit", "warning"), ("submitted", "Submitted", "info"), ("approved", "Approved", "success"), ("denied", "Denied", "")), ["approved", "denied"],
    [F("payer", "Payer"), F("submitted_on", "Submitted on", "date"), F("auth_number", "Authorization number", sensitive=True), F("expires_on", "Expires", "date")],
    ["payer", "submitted_on", "expires_on"]),
  T("result_callbacks", "Results callback", "Results callbacks", "lab_profile", "Patient",
    S(("waiting", "Waiting", "warning"), ("called", "Called back", "success")), ["called"],
    [F("test", "Test"), F("clinician", "Clinician to call")], notice="Results are given by clinical staff only, never by the AI receptionist or the front desk."),
  COVERAGE,
]}
P["pet_care"] = {"types": [
  EXT("pets", [F("weight", "Weight", "number"), SEL("sex", "Sex", ["Female", "Male", "Unknown"]), F("neutered", "Spayed or neutered", "bool"), F("microchip", "Microchip"),
               F("allergies", "Allergies", "longtext"), F("alerts", "Alerts (e.g. bites)"), F("vaccines_due", "Vaccines due", "date"), F("deceased", "Passed away (stops reminders)", "bool")]),
  EXT("reminders", [LINK("pet", "Pet", "pets")]),
  T("boarding", "Boarding stay", "Boarding stays", "pets", "Stay",
    S(("booked", "Booked", "info"), ("in", "Checked in", "success"), ("out", "Checked out", ""), ("cancelled", "Cancelled", "")), ["out", "cancelled"],
    [LINK("pet", "Pet", "pets"), F("check_in", "Check-in", "date"), F("check_out", "Check-out", "date"), F("kennel", "Kennel"), F("feeding", "Feeding", "longtext"), F("medication", "Medication", "longtext")],
    ["check_in", "check_out", "kennel"]),
]}
P["spa_wellness"] = {"types": [
  T("intake", "Intake form", "Intake forms", "assignment_ind", "Client",
    S(("requested", "Requested", "warning"), ("signed", "Signed", "success"), ("expired", "Needs renewing", "")), ["expired"],
    [F("contraindications", "Health notes (pregnancy, allergies, surgery, blood pressure)", "longtext", sensitive=True), SEL("pressure", "Pressure", ["Light", "Medium", "Firm"]),
     SEL("therapist_preference", "Therapist preference", ["No preference", "Female", "Male"]), F("signed_on", "Signed on", "date")],
    ["pressure", "signed_on"], notice=PRIV_NOTE),
  EXT("packages", title_label="Client package"),
]}
P["fitness"] = {"types": [
  T("classes", "Class", "Classes", "sports_gymnastics", "Class",
    S(("scheduled", "Scheduled", "info"), ("completed", "Completed", ""), ("cancelled", "Cancelled", "")), ["completed", "cancelled"],
    [F("starts_at", "Starts", "datetime", required=True), F("places", "Places", "number", required=True), F("instructor", "Instructor"), F("room", "Room")],
    ["starts_at", "places", "instructor"], link_person=False, capability="classes"),
  T("class_bookings", "Class booking", "Class bookings", "event_seat", "Member",
    S(("booked", "Booked", "success"), ("waitlist", "Waitlist", "warning"), ("attended", "Attended", ""), ("no_show", "No-show", "danger"), ("cancelled", "Cancelled", "")),
    ["attended", "no_show", "cancelled"], [LINK("class", "Class", "classes", required=True)], ["class"], capability="classes",
    capacity={"parent_field": "class", "capacity_field": "places", "counted": ["booked", "attended"], "waitlist_status": "waitlist"},
    notice="When a class is full, new bookings go on its waitlist."),
  T("freeze_requests", "Freeze or cancellation", "Freezes and cancellations", "ac_unit", "Member",
    S(("requested", "Requested", "warning"), ("approved", "Approved", "success"), ("declined", "Declined", ""), ("done", "Done", "")), ["declined", "done"],
    [SEL("kind", "Request", ["Freeze", "Cancel"], required=True), F("from_on", "From", "date"), F("to_on", "Until", "date"), F("reason", "Reason"), F("notice_on", "Notice given on", "date")]),
  EXT("memberships", [F("waiver_signed", "Waiver signed", "bool"), F("pt_sessions_left", "PT sessions left", "number")]),
]}
P["beauty_salon"] = {"types": [
  T("colour_cards", "Colour card", "Colour cards", "palette", "Client",
    S(("current", "Current", "success"), ("old", "Old", "")), ["old"],
    [F("formula", "Formula", "longtext", required=True), F("developer", "Developer"), F("processing_minutes", "Processing (minutes)", "number"), F("stylist", "Stylist"), F("done_on", "Date", "date")],
    ["developer", "stylist", "done_on"]),
  EXT("preferences", [F("patch_test_on", "Patch test", "date")]),
]}
def trade_props(extra=(), access_label="Access instructions"):
    return T("properties", "Property", "Properties", "home", "Property",
      S(("active", "Active", "success"), ("inactive", "Inactive", "")), ["inactive"],
      [F("address", "Address", required=True, unique=True), F("access", access_label, "longtext", sensitive=True)] + list(extra), ["address"], notice=PRIV_NOTE)
P["plumbing"] = {"types": [
  EXT("properties", [F("water_heater", "Water heater (type)"), F("water_heater_age", "Water heater age (years)", "number")], sensitive=["access"]),
  EXT("jobs", [WINDOW, LINK("property", "Property", "properties"), F("permit_needed", "Permit needed", "bool"), F("inspection_on", "Inspection", "date"), F("warranty_until", "Warranty until", "date")], capability="dispatch"),
  EXT("plans", title_label="Agreement name"),
]}
P["hvac"] = {"types": [
  trade_props(),
  EXT("equipment", [LINK("property", "Property", "properties"), F("refrigerant", "Refrigerant"), F("filter_size", "Filter size")]),
  EXT("jobs", [WINDOW, LINK("property", "Property", "properties")], capability="dispatch"),
]}
P["electrical"] = {"types": [
  EXT("sites", [F("panel_size", "Panel and service size")], sensitive=["access"]),
  EXT("jobs", [WINDOW, LINK("site", "Site", "sites")], capability="dispatch"),
  T("permits", "Permit", "Permits", "approval", "Permit",
    S(("applied", "Applied", "warning"), ("issued", "Issued", "info"), ("passed", "Inspection passed", "success"), ("failed", "Inspection failed", "danger")), ["passed"],
    [F("permit_number", "Permit number", unique=True), LINK("job", "Job", "jobs"), F("inspection_on", "Inspection", "date")], link_person=False),
  T("plans", "Maintenance plan", "Maintenance plans", "autorenew", "Agreement name",
    S(("active", "Active", "success"), ("lapsed", "Lapsed", "")), ["lapsed"], [F("plan", "Plan"), F("next_visit", "Next visit", "date")]),
]}
P["home_services"] = {"match": ["homeservice", "homeservices", "handyman"], "types": [
  EXT("properties", [], sensitive=["access"]),
  EXT("jobs", [WINDOW, LINK("property", "Property", "properties"), SEL("skill", "Skill", ["Handyman", "Appliance", "Garage door", "Other"])], capability="dispatch"),
  EXT("plans", title_label="Agreement name"),
]}
P["cleaning"] = {"new": True, "match": ["cleaning", "cleaningservices", "domestic", "domesticcleaning"], "types": [
  trade_props([F("rooms", "Rooms"), F("checklist", "Checklist and special instructions", "longtext"), SEL("supplies", "Supplies", ["We bring", "Customer provides"])], "Key, lockbox and alarm codes"),
  T("visits", "Cleaning visit", "Cleaning visits", "cleaning_services", "Visit",
    S(("scheduled", "Scheduled", "info"), ("on_the_way", "On the way", "warning"), ("in_progress", "In progress", "warning"), ("done", "Done", "success"), ("cancelled", "Cancelled", "")),
    ["done", "cancelled"], [LINK("property", "Property", "properties", required=True), F("scheduled_for", "Scheduled for", "datetime"), WINDOW, F("team", "Team")],
    ["property", "scheduled_for", "team"], capability="dispatch"),
  T("plans", "Cleaning plan", "Cleaning plans", "autorenew", "Agreement name",
    S(("active", "Active", "success"), ("paused", "Paused", "warning"), ("ended", "Ended", "")), ["ended"],
    [LINK("property", "Property", "properties"), SEL("frequency", "Frequency", ["Weekly", "Every 2 weeks", "Monthly", "One-off"]), F("next_visit", "Next visit", "date")]),
]}
P["landscaping"] = {"types": [
  trade_props([F("lot_size", "Lot size"), F("grass_type", "Grass type"), F("irrigation", "Irrigation", "bool")], "Gate and access"),
  EXT("jobs", [WINDOW, LINK("property", "Property", "properties"), F("weather_delay", "Delayed by weather", "bool")], capability="dispatch"),
  EXT("plans", [SEL("season", "Seasonal add-on", ["None", "Aeration", "Leaf clean-up", "Snow removal"])], title_label="Agreement name"),
]}
P["pest_control"] = {"types": [
  trade_props([F("history", "Infestation history", "longtext"), F("safety", "Safety notes (children, pets, fish tanks)", "longtext")]),
  EXT("jobs", [WINDOW, LINK("property", "Property", "properties")], capability="dispatch"),
  T("applications", "Application record", "Application records", "science", "Application",
    S(("recorded", "Recorded", "success"),), [],
    [LINK("job", "Job", "jobs"), F("product", "Product", required=True), F("epa_reg_no", "EPA registration number", required=True), F("amount", "Amount applied", required=True),
     F("target_pest", "Target pest"), F("location", "Where applied"), F("applicator_license", "Applicator license"), F("applied_on", "Applied on", "date", required=True)],
    ["product", "epa_reg_no", "applied_on"], notice="Keep these for as long as your state requires. Archive only after that."),
  EXT("plans", [F("bond_renewal", "Termite bond renewal", "date")], title_label="Agreement name"),
]}
P["automotive"] = {"types": [
  EXT("vehicles", [F("vin", "VIN"), F("plate", "Plate number"), F("plate_state", "Plate state or territory"), F("recall_checked_on", "Recall check", "date")], relabel={"registration": "Registration (rego)"}),
  EXT("repair_orders", [LINK("vehicle_record", "Vehicle record", "vehicles"), F("declined_work", "Declined work", "longtext"), F("remind_declined_on", "Remind about declined work", "date"),
                        F("labour", "Labour", "number"), F("parts", "Parts", "number")]),
  T("loaners", "Loaner car", "Loaner cars", "car_rental", "Car",
    S(("available", "Available", "success"), ("out", "Out", "warning"), ("returned", "Returned", "")), ["returned"],
    [F("out_at", "Out", "datetime"), F("due_back", "Due back", "datetime"), SEL("fuel_out", "Fuel when out", ["Full", "3/4", "1/2", "1/4", "Empty"])]),
]}
P["property_management"] = {"types": [
  T("units", "Unit", "Units", "apartment", "Unit",
    S(("occupied", "Occupied", "success"), ("vacant", "Vacant", "warning"), ("notice", "Notice given", "warning"), ("inactive", "Inactive", "")), ["inactive"],
    [F("address", "Address", required=True), F("owner_name", "Owner"), F("rent", "Rent", "number"), F("keys", "Keys and access codes", "longtext", sensitive=True)],
    ["address", "owner_name", "rent"], link_person=False, notice=PRIV_NOTE),
  T("vendors", "Vendor", "Vendors", "handyman", "Company",
    S(("approved", "Approved", "success"), ("on_hold", "On hold", "")), ["on_hold"],
    [F("trade", "Trade"), F("phone", "Phone", "phone"), F("insurance_expires", "Insurance expires", "date"), F("emergency", "Takes emergencies", "bool")],
    ["trade", "phone", "insurance_expires"], link_person=False),
  EXT("requests", [LINK("unit_record", "Unit record", "units"), LINK("vendor", "Vendor", "vendors"), F("emergency", "Emergency", "bool")]),
  EXT("leases", [LINK("unit_record", "Unit record", "units")]),
  T("applications", "Rental application", "Rental applications", "assignment", "Applicant",
    S(("enquiry", "Enquiry", "info"), ("showing", "Showing", "info"), ("applied", "Applied", "warning"), ("approved", "Approved", "success"), ("declined", "Declined", "")), ["approved", "declined"],
    [LINK("unit", "Unit", "units"), F("move_in", "Move-in", "date")]),
]}
P["real_estate"] = {"types": [
  T("open_houses", "Open house", "Open houses", "door_open", "Open house",
    S(("planned", "Planned", "info"), ("held", "Held", "success"), ("cancelled", "Cancelled", "")), ["held", "cancelled"],
    [LINK("property", "Property", "properties"), F("starts_at", "Starts", "datetime"), F("sign_ins", "Sign-ins", "number")], link_person=False),
  T("seller_leads", "Seller lead", "Seller leads", "sell", "Seller",
    S(("new", "New", "info"), ("appraisal", "Appraisal booked", "warning"), ("listed", "Listed", "success"), ("lost", "Lost", "")), ["listed", "lost"],
    [F("address", "Property address", required=True), F("valuation_requested", "Valuation requested", "bool"), F("motivation", "Why selling"), F("timeframe", "Timeframe")]),
  EXT("requirements", [F("pre_approved", "Pre-approved", "bool")]),
  EXT("viewings", title_label="Summary"),
  EXT("deals", [F("inspection_on", "Inspection", "date"), F("appraisal_on", "Appraisal", "date"), F("financing_on", "Finance approval", "date"), F("closing_on", "Closing", "date")]),
]}
P["legal"] = {"types": [
  EXT("matters", [F("practice_area", "Practice area"), F("jurisdiction", "Jurisdiction"), F("incident_date", "Incident date", "date"),
                  F("opposing_parties", "Opposing parties", "longtext"), F("related_parties", "Related parties", "longtext"),
                  F("limitation_date", "Limitation or critical deadline", "date"), SEL("engagement", "Engagement letter", ["Not sent", "Sent", "Signed"]), F("consult_fee_paid", "Consultation fee paid", "bool")]),
  EXT("document_requests", title_label="Request"),
  T("deadlines", "Deadline", "Deadlines", "alarm", "Deadline",
    S(("open", "Open", "warning"), ("done", "Done", "success")), ["done"],
    [LINK("matter", "Matter", "matters", required=True), F("due", "Due", "date", required=True), SEL("kind", "Kind", ["Limitation", "Court date", "Filing", "Other"]), F("attorney", "Responsible attorney")],
    ["matter", "due", "attorney"], link_person=False, notice="Reminders go to the responsible attorney 30, 7 and 1 days before."),
]}
P["financial_services"] = {"match": ["financialservices", "finance", "financial", "accounting"], "types": [
  EXT("requests", [F("checklist", "Documents checklist", "longtext")], title_label="Summary"),
  T("reviews", "Annual review", "Annual reviews", "event_repeat", "Client",
    S(("due", "Due", "warning"), ("booked", "Booked", "info"), ("done", "Done", "success")), ["done"],
    [F("review_due", "Review due", "date", required=True), F("advisor", "Advisor"), F("household", "Household", "longtext")]),
]}
P["insurance"] = {"new": True, "match": ["insurance", "insuranceagency", "insurancebroker"], "types": [
  T("policies", "Policy", "Policies", "policy", "Policyholder",
    S(("active", "Active", "success"), ("renewing", "Renewing", "warning"), ("lapsed", "Lapsed", "danger"), ("cancelled", "Cancelled", "")), ["lapsed", "cancelled"],
    [F("carrier", "Carrier", required=True), SEL("line", "Line", ["Auto", "Home", "Life", "Health", "Commercial", "Other"], required=True), F("policy_number", "Policy number", unique=True),
     F("premium", "Premium", "number"), F("effective_on", "Effective", "date"), F("expires_on", "Expires", "date")],
    ["carrier", "line", "expires_on"]),
  T("claims", "Claim", "Claims", "report", "Claim",
    S(("reported", "Reported (first notice)", "warning"), ("submitted", "Submitted to carrier", "info"), ("open", "Open", "info"), ("closed", "Closed", ""), ("denied", "Denied", "")), ["closed", "denied"],
    [LINK("policy", "Policy", "policies"), F("loss_date", "Date of loss", "date", required=True), F("what_happened", "What happened", "longtext", required=True), F("claim_number", "Claim number"), F("adjuster", "Adjuster")],
    ["loss_date", "claim_number", "adjuster"], notice="Taking a claim never means it's covered. The carrier decides."),
  T("quotes", "Quote", "Quotes", "request_quote", "Quote",
    S(("requested", "Requested", "info"), ("quoted", "Quoted", "warning"), ("accepted", "Accepted", "success"), ("declined", "Declined", "")), ["accepted", "declined"],
    [SEL("line", "Line", ["Auto", "Home", "Life", "Health", "Commercial", "Other"]), F("carriers", "Carriers quoted"), F("premium", "Premium", "number")]),
  T("service_requests", "Policy request", "Policy requests", "support_agent", "Summary",
    S(("open", "Open", "warning"), ("done", "Done", "success")), ["done"],
    [SEL("kind", "Request", ["Certificate of insurance", "Policy change", "Cancellation", "Billing", "Other"], required=True), LINK("policy", "Policy", "policies"), F("details", "Details", "longtext")]),
]}
P["professional_services"] = {"types": [
  EXT("opportunities", [F("proposal_amount", "Proposal amount", "number"), SEL("proposal_status", "Proposal", ["Not sent", "Sent", "Accepted", "Declined"])]),
  EXT("projects", [F("retainer_value", "Retainer value", "number"), F("hours_used", "Hours used", "number")]),
]}
P["restaurant"] = {"types": [
  EXT("requests", [F("allergies", "Allergies and dietary needs", "longtext"), F("occasion", "Occasion")], title_label="Summary"),
  EXT("events", [F("deposit_required", "Deposit required", "bool"), F("minimum_spend", "Minimum spend", "number")]),
  T("catering", "Catering order", "Catering orders", "takeout_dining", "Order",
    S(("requested", "Requested", "info"), ("confirmed", "Confirmed", "success"), ("ready", "Ready", "warning"), ("done", "Done", ""), ("cancelled", "Cancelled", "")), ["done", "cancelled"],
    [F("headcount", "Headcount", "number"), F("menu", "Menu", "longtext"), SEL("handoff", "Pickup or delivery", ["Pickup", "Delivery"]), F("ready_at", "Ready at", "datetime")]),
]}
P["hospitality"] = {"types": [
  EXT("stays", [F("arrival_time", "Arrival time"), F("special_requests", "Special requests", "longtext")]),
  T("room_types", "Room type", "Room types", "bed", "Room type",
    S(("offered", "Offered", "success"), ("not_offered", "Not offered", "")), ["not_offered"],
    [F("sleeps", "Sleeps", "number"), F("rate", "From rate", "number"), F("details", "Details", "longtext")], link_person=False,
    notice="The AI receptionist quotes only what's here and never confirms a booking without your system."),
  T("lost_found", "Lost item", "Lost and found", "search", "Item",
    S(("logged", "Logged", "warning"), ("claimed", "Claimed", "info"), ("returned", "Returned", "success"), ("disposed", "Disposed", "")), ["returned", "disposed"],
    [F("found_on", "Found on", "date"), F("where_found", "Where found")]),
]}
P["photography_events"] = {"types": [
  EXT("bookings", [SEL("contract", "Contract", ["Not sent", "Sent", "Signed"]), F("balance_due", "Balance due", "date"), F("second_shooter", "Second shooter"), F("shot_list", "Shot list and timeline", "longtext")]),
  T("galleries", "Gallery", "Galleries", "photo_library", "Gallery",
    S(("editing", "Editing", "warning"), ("delivered", "Delivered", "success"), ("expired", "Expired", "")), ["expired"],
    [LINK("booking", "Booking", "bookings"), F("link", "Gallery link"), F("delivered_on", "Delivered on", "date"), F("expires_on", "Expires", "date")]),
]}
P["travel"] = {"types": [
  EXT("trips", [SEL("travel_insurance", "Travel insurance", ["Not offered", "Offered", "Accepted", "Declined"]), F("visas_needed", "Visas needed"),
                F("deposit_due", "Deposit due", "date"), F("final_payment_due", "Final payment due", "date")]),
  T("documents", "Traveler document", "Traveler documents", "badge", "Traveler",
    S(("valid", "Valid", "success"), ("expiring", "Expiring soon", "warning"), ("expired", "Expired", "danger")), [],
    [F("passport_number", "Passport number", sensitive=True), F("passport_expires", "Passport expires", "date"), F("nationality", "Nationality"), F("visa_notes", "Visa notes", "longtext")],
    ["passport_expires", "nationality"], notice="Passports within 6 months of expiry need attention. " + PRIV_NOTE),
]}
P["childcare"] = {"types": [
  T("children", "Child", "Children", "child_care", "Child's name",
    S(("enrolled", "Enrolled", "success"), ("waitlisted", "Waitlisted", "warning"), ("left", "Left", "")), ["left"],
    [F("date_of_birth", "Date of birth", "date", required=True), F("room", "Room or age group"), F("allergies", "Allergies and medical needs", "longtext", sensitive=True),
     F("pickups", "Authorized pick-up people", "longtext", sensitive=True), F("custody", "Custody notes", "longtext", sensitive=True), F("immunizations_ok", "Immunizations up to date", "bool")],
    ["date_of_birth", "room"], notice="Never confirm anything about a child to a caller. " + PRIV_NOTE),
  EXT("enrolments", [LINK("child", "Child", "children")]),
  T("incidents", "Incident report", "Incident reports", "report", "Summary",
    S(("open", "Open", "warning"), ("closed", "Closed", "")), ["closed"],
    [LINK("child", "Child", "children", required=True), F("happened_at", "When", "datetime", required=True), F("what_happened", "What happened", "longtext", sensitive=True), F("parent_informed", "Parent informed", "bool")],
    ["child", "happened_at", "parent_informed"]),
]}
P["education"] = {"types": [
  T("sessions", "Class session", "Class sessions", "co_present", "Session",
    S(("scheduled", "Scheduled", "info"), ("held", "Held", ""), ("cancelled", "Cancelled", "")), ["held", "cancelled"],
    [LINK("course", "Course", "courses"), F("starts_at", "Starts", "datetime", required=True), F("places", "Places", "number")], ["course", "starts_at", "places"],
    link_person=False, capability="classes"),
  T("session_bookings", "Session booking", "Session bookings", "event_seat", "Student",
    S(("booked", "Booked", "success"), ("waitlist", "Waitlist", "warning"), ("present", "Present", ""), ("absent", "Absent", "danger"), ("cancelled", "Cancelled", "")),
    ["present", "absent", "cancelled"], [LINK("session", "Session", "sessions", required=True)], ["session"], capability="classes",
    capacity={"parent_field": "session", "capacity_field": "places", "counted": ["booked", "present"], "waitlist_status": "waitlist"}),
  EXT("applications", [LINK("course_record", "Course record", "courses")]),
]}
P["ecommerce"] = {"types": [
  EXT("orders", [], capability="orders"),
  EXT("returns", [F("label_sent", "Return label sent", "bool"), F("refund_amount", "Refund amount", "number")], capability="orders"),
]}
P["other"] = {"types": []}

PRESETS = P
if __name__ == "__main__": print(len(P), "presets;", sum(len(v["types"]) for v in P.values()), "type entries")
