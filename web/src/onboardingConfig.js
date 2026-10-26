// What the Create Business wizard asks each industry. The database holds each industry's words (Patients,
// Reservations ...) and modules; this file holds only the onboarding questions that differ by kind of business, so
// a restaurant is asked about party sizes and a plumber about the area they cover, and nobody is asked both.
// Answers are saved with the business (setup_data.operations) and given to the AI receptionist as facts.
// An industry not listed here gets the general questions; nothing is assumed about it.

// Field: [key, label, type, options]. Types: text, number, time, yesno, select (options: [[value, label], ...]),
// list (comma-separated text). `required` marks fields that must be filled to continue.
const f = (key, label, type = "text", extra = {}) => ({ key, label, type, ...extra });

const LENGTHS = [[15, "15 min"], [30, "30 min"], [45, "45 min"], [60, "1 hour"], [90, "1.5 hours"], [120, "2 hours"]];

const GENERAL = {
  kind: "general",
  appointments: true,          // takes bookings, so booking preferences are asked
  team: "optional",           // "optional" | "recommended": staff list step
  teamHint: "Add the people customers can book with. The AI only offers times when one of them is working.",
  servicesHint: "What customers can ask about or book. Leave a price empty if the AI shouldn't quote it.",
  defaultLength: 30,
  details: [
    f("service_area", "Area served", "text", { placeholder: "e.g. Austin and nearby towns" }),
  ],
  faqPrompts: ["Do you take walk-ins?", "Where can I park?", "What payment methods do you accept?"],
  capabilities: ["answer_questions", "answer_calls", "collect_customer_info", "take_messages", "book_appointments", "reschedule_appointments"],
  spamBookingLimit: 3,         // bookings one contact may make per day before the rest wait for the team
};

const DINING = {
  ...GENERAL,
  kind: "dining",
  spamBookingLimit: 2,
  team: "optional",
  teamHint: "Optional. Restaurants usually book tables, not people, so you can skip this.",
  servicesHint: "Menus, set menus, private dining or catering the AI can describe. Prices are optional.",
  defaultLength: 90,
  details: [
    f("seating_capacity", "Seats", "number", { required: true, min: 1, max: 5000 }),
    f("max_party_size", "Largest party the AI may book", "number", { required: true, min: 1, max: 100, hint: "Bigger groups are passed to the team." }),
    f("walk_ins", "Walk-ins welcome", "yesno"),
    f("large_party_deposit", "Deposit for large groups", "text", { placeholder: "e.g. $10 per person for 8 or more" }),
    f("dietary_options", "Dietary options", "list", { placeholder: "e.g. vegetarian, vegan, gluten-free" }),
    f("takeaway_delivery", "Takeaway or delivery", "select", { options: [["none", "Neither"], ["takeaway", "Takeaway"], ["delivery", "Delivery"], ["both", "Both"]] }),
  ],
  faqPrompts: ["Do you have vegetarian options?", "Can I bring my own cake?", "Is there parking nearby?", "Do you host private events?"],
  capabilities: ["answer_questions", "answer_calls", "collect_customer_info", "take_messages", "book_appointments", "reschedule_appointments", "cancel_appointments"],
};

const LODGING = {
  ...GENERAL,
  kind: "lodging",
  spamBookingLimit: 2,
  teamHint: "Optional. Add front-desk or concierge staff if guests book time with them.",
  servicesHint: "Room types and extras (breakfast, spa, airport transfer). Prices are optional.",
  defaultLength: 60,
  details: [
    f("room_count", "Rooms", "number", { required: true, min: 1, max: 5000 }),
    f("check_in_time", "Check-in from", "time", { required: true }),
    f("check_out_time", "Check-out by", "time", { required: true }),
    f("parking", "Parking", "text", { placeholder: "e.g. Free on site, valet $25 a night" }),
    f("pets_allowed", "Pets allowed", "yesno"),
    f("amenities", "Amenities", "list", { placeholder: "e.g. pool, gym, restaurant" }),
  ],
  faqPrompts: ["Can I check in early?", "Is breakfast included?", "Do you have airport transfers?"],
};

const CLINIC = {
  ...GENERAL,
  kind: "clinic",
  spamBookingLimit: 2,
  team: "recommended",
  teamHint: "Add the providers patients book with, so the AI only offers their real availability.",
  servicesHint: "Treatments and visit types. Leave prices empty if they depend on an exam.",
  defaultLength: 30,
  details: [
    f("new_patients", "Accepting new patients", "yesno", { required: true }),
    f("insurance_accepted", "Insurance accepted", "list", { placeholder: "e.g. Delta Dental, Cigna, self-pay" }),
    f("emergency_policy", "Urgent or emergency cases", "text", { placeholder: "e.g. Same-day slots held for emergencies; after hours call 911" }),
    f("arrival_minutes", "Ask new patients to arrive early (minutes)", "number", { min: 0, max: 60 }),
  ],
  faqPrompts: ["Do you accept my insurance?", "Do you see children?", "What should I bring to my first visit?"],
};

const VET = {
  ...CLINIC,
  kind: "vet",
  details: [
    f("species_treated", "Animals treated", "list", { required: true, placeholder: "e.g. dogs, cats, rabbits" }),
    f("new_patients", "Accepting new patients", "yesno", { required: true }),
    f("emergency_policy", "Emergencies", "text", { placeholder: "e.g. After hours: nearest emergency vet and number" }),
  ],
  faqPrompts: ["Do you treat exotic pets?", "Do you offer vaccinations?", "Do you board pets?"],
};

const FIELD = {
  ...GENERAL,
  kind: "field",
  team: "recommended",
  teamHint: "Add the technicians or crews who go out to jobs, so bookings go to someone who is working.",
  servicesHint: "Jobs the business does. Prices are optional; many trades quote on site.",
  defaultLength: 60,
  details: [
    f("service_area", "Area served", "text", { required: true, placeholder: "e.g. Travis and Williamson County" }),
    f("emergency_service", "24/7 emergency call-outs", "yesno", { required: true }),
    f("call_out_fee", "Call-out or diagnostic fee", "text", { placeholder: "e.g. $89, waived if the job goes ahead" }),
    f("free_estimates", "Free estimates", "yesno"),
    f("license_number", "Licence number", "text", { placeholder: "Shown to customers who ask" }),
  ],
  faqPrompts: ["Do you charge for estimates?", "Can you come today?", "Are you licensed and insured?"],
};

const BEAUTY = {
  ...GENERAL,
  kind: "beauty",
  team: "recommended",
  teamHint: "Add the stylists or therapists clients book with.",
  servicesHint: "Services with their usual length and price, so the AI books the right amount of time.",
  defaultLength: 45,
  details: [
    f("walk_ins", "Walk-ins welcome", "yesno"),
    f("deposit_policy", "Deposit", "text", { placeholder: "e.g. $20 deposit for colour appointments" }),
    f("cancellation_notice_hours", "Cancellation notice needed (hours)", "number", { min: 0, max: 168 }),
  ],
  faqPrompts: ["How long does a colour take?", "Do you do bridal packages?", "Which products do you use?"],
};

const FITNESS = {
  ...BEAUTY,
  kind: "fitness",
  teamHint: "Add the trainers or instructors members book with.",
  servicesHint: "Classes, sessions and memberships. Prices are optional.",
  defaultLength: 60,
  details: [
    f("membership_types", "Memberships", "list", { placeholder: "e.g. monthly, 10-class pass, drop-in" }),
    f("trial_offer", "Free trial", "text", { placeholder: "e.g. First class free" }),
    f("cancellation_notice_hours", "Cancellation notice needed (hours)", "number", { min: 0, max: 168 }),
  ],
  faqPrompts: ["Do you have a free trial?", "Can I freeze my membership?", "Are there showers?"],
};

const PROPERTY = {
  ...GENERAL,
  kind: "property",
  team: "recommended",
  teamHint: "Add the agents or managers who show properties.",
  servicesHint: "What the business offers: sales, lettings, valuations, management.",
  defaultLength: 45,
  details: [
    f("areas_covered", "Areas covered", "list", { required: true, placeholder: "e.g. Downtown, Riverside, Eastwood" }),
    f("property_types", "Property types", "list", { placeholder: "e.g. houses, condos, commercial" }),
    f("license_number", "Licence or registration number", "text"),
  ],
  faqPrompts: ["Can I book a viewing this weekend?", "How do I get a valuation?", "What are your fees?"],
};

const PROPERTY_MGMT = {
  ...PROPERTY,
  kind: "property-management",
  details: [
    f("areas_covered", "Areas covered", "list", { required: true }),
    f("units_managed", "Units managed", "number", { min: 0, max: 100000 }),
    f("maintenance_emergency", "Emergency maintenance line", "text", { placeholder: "e.g. 24/7 on (555) 010-0200" }),
  ],
  faqPrompts: ["How do I report a repair?", "When is rent due?", "Are pets allowed?"],
};

const ADVISORY = {
  ...GENERAL,
  kind: "advisory",
  team: "recommended",
  teamHint: "Add the advisers or attorneys clients book consultations with.",
  servicesHint: "Practice areas or services. Fees are optional.",
  defaultLength: 60,
  details: [
    f("practice_areas", "Practice areas", "list", { required: true, placeholder: "e.g. family law, estate planning" }),
    f("free_consultation", "Free first consultation", "yesno"),
    f("license_number", "Licence or registration number", "text"),
  ],
  faqPrompts: ["Is the first consultation free?", "Do you offer virtual meetings?", "What documents should I bring?"],
};

const EDUCATION = {
  ...GENERAL,
  kind: "education",
  teamHint: "Add the instructors students book sessions with.",
  servicesHint: "Courses, subjects or programmes.",
  defaultLength: 60,
  details: [
    f("subjects", "Subjects or courses", "list", { required: true }),
    f("age_groups", "Age groups", "text", { placeholder: "e.g. 6 to 16, adults" }),
    f("online_sessions", "Online sessions", "yesno"),
  ],
  faqPrompts: ["Do you offer a trial lesson?", "Are sessions online or in person?"],
};

const CHILDCARE = {
  ...GENERAL,
  kind: "childcare",
  teamHint: "Optional. Add staff who give tours to parents.",
  servicesHint: "Programmes and age groups (infant, toddler, pre-K, after-school).",
  defaultLength: 30,
  details: [
    f("age_range", "Ages cared for", "text", { required: true, placeholder: "e.g. 6 weeks to 5 years" }),
    f("capacity", "Places", "number", { min: 1, max: 2000 }),
    f("license_number", "Childcare licence number", "text", { required: true }),
    f("waitlist_open", "Waitlist open", "yesno"),
  ],
  faqPrompts: ["Do you have places available?", "What are the drop-off times?", "Are meals included?"],
};

const AUTOMOTIVE = {
  ...GENERAL,
  kind: "automotive",
  teamHint: "Add service advisers or technicians customers book with.",
  servicesHint: "Repairs and services, with usual time and price where fixed.",
  defaultLength: 60,
  details: [
    f("makes_serviced", "Makes serviced", "list", { placeholder: "e.g. all makes, Toyota, Honda" }),
    f("loaner_cars", "Courtesy or loaner cars", "yesno"),
    f("pickup_dropoff", "Pick-up and drop-off", "yesno"),
  ],
  faqPrompts: ["How long does a service take?", "Do you offer a courtesy car?", "Can I wait while it's done?"],
};

const EVENTS = {
  ...GENERAL,
  kind: "events",
  teamHint: "Add photographers or event staff clients book.",
  servicesHint: "Packages, with what's included and the starting price.",
  defaultLength: 60,
  details: [
    f("event_types", "Event types", "list", { required: true, placeholder: "e.g. weddings, portraits, corporate" }),
    f("travel_area", "Will travel to", "text"),
    f("deposit_policy", "Deposit to secure a date", "text"),
  ],
  faqPrompts: ["Are you available on my date?", "How soon do we get the photos?"],
};

const ECOMMERCE = {
  ...GENERAL,
  kind: "ecommerce",
  appointments: false,
  team: "optional",
  teamHint: "Optional. Add support agents if customers are passed to a person.",
  servicesHint: "Product ranges the AI can talk about.",
  details: [
    f("returns_window_days", "Returns accepted for (days)", "number", { required: true, min: 0, max: 365 }),
    f("shipping_regions", "Ships to", "list", { required: true, placeholder: "e.g. United States, Canada" }),
    f("order_lookup", "How customers check an order", "text", { placeholder: "e.g. Order page with order number and email" }),
  ],
  faqPrompts: ["Where is my order?", "How do I return something?", "Do you ship internationally?"],
  capabilities: ["answer_questions", "answer_calls", "handle_sms", "collect_customer_info", "take_messages"],
};

const TRAVEL = {
  ...ADVISORY,
  kind: "travel",
  teamHint: "Add the travel advisers clients book consultations with.",
  servicesHint: "Trip types and services.",
  details: [
    f("destinations", "Destinations", "list", { required: true }),
    f("license_number", "Licence or registration number", "text"),
  ],
  faqPrompts: ["Can you arrange visas?", "Do you offer travel insurance?"],
};

export const ONBOARDING_BY_INDUSTRY = {
  restaurant: DINING,
  hospitality: LODGING, hotels: LODGING,
  dental: CLINIC, healthcare: CLINIC, "pet-care-veterinary": VET,
  plumbing: FIELD, hvac: FIELD, electrical: FIELD, "home-services": FIELD, "cleaning-services": FIELD,
  "pest-control": FIELD, "landscaping-lawn-care": FIELD,
  "beauty-salon": BEAUTY, "spa-wellness": BEAUTY, fitness: FITNESS,
  "real-estate": PROPERTY, "property-management": PROPERTY_MGMT,
  legal: ADVISORY, "financial-services": ADVISORY, insurance: ADVISORY, "professional-services": ADVISORY,
  education: EDUCATION, childcare: CHILDCARE, automotive: AUTOMOTIVE, "photography-events": EVENTS,
  ecommerce: ECOMMERCE, travel: TRAVEL,
};

export const onboardingFor = (slug) => ONBOARDING_BY_INDUSTRY[slug] ?? GENERAL;
export const LENGTH_OPTIONS = LENGTHS;

// Documents an admin collects to verify the business and the person registering it.
export const DOCUMENT_KINDS = [
  { kind: "business_registration", label: "Business registration", required: true,
    hint: "Certificate of incorporation, business licence, or another official record showing the business exists." },
  { kind: "owner_identity", label: "Owner's photo ID", required: true,
    hint: "Passport, driving licence or national ID of the person registering the business." },
  { kind: "tax_registration", label: "Tax registration", required: false, hint: "EIN letter, VAT or GST certificate. Optional." },
  { kind: "professional_license", label: "Professional or trade licence", required: false, hint: "For licensed trades and professions. Optional." },
];
export const DOCUMENT_TYPES = ["application/pdf", "image/jpeg", "image/png", "image/webp", "image/heic"];
export const DOCUMENT_MAX_BYTES = 10 * 1024 * 1024;

// Missing required details for the Hours & services step, as one readable list.
export function missingDetails(config, details) {
  return config.details.filter((d) => d.required && (details?.[d.key] === undefined || details?.[d.key] === null || String(details[d.key]).trim() === "")).map((d) => d.label);
}
