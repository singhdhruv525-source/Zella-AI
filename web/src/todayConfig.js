// How the Today dashboard words and arranges itself for each industry. It never adds data: every number and row
// still comes from this business's own records. It only chooses wording and which optional columns, buttons and
// cards make sense. Most words come from the industry's terminology (Reservations, Guests, Technicians ...) through
// makeTerm; this adds the few the terminology doesn't hold. Industries not listed get the general layout.

const GENERAL = {
  arrived: "Arrived",          // label for a booking whose customer has turned up
  guests: false,               // show a party-size column and a total-guests card
  walkIn: false,               // offer a Walk-in button (a booking that starts now)
  staffColumn: true,           // show who the booking is with
  connect: ["revenue", "reviews"], // cards for data Zella can show once it's connected
};

const FIELD_WORK = { ...GENERAL, arrived: "On site", connect: ["revenue", "reviews"] };
const CLINIC = { ...GENERAL, arrived: "Checked in" };
const WALK_IN = { ...GENERAL, walkIn: true };

export const TODAY_BY_INDUSTRY = {
  restaurant: { ...GENERAL, arrived: "Seated", guests: true, walkIn: true, staffColumn: false, connect: ["orders", "tables", "reviews"] },
  hospitality: { ...GENERAL, arrived: "Checked in", guests: true, connect: ["revenue", "reviews"] },
  hotels: { ...GENERAL, arrived: "Checked in", guests: true, connect: ["revenue", "reviews"] },
  dental: CLINIC,
  healthcare: CLINIC,
  "pet-care-veterinary": CLINIC,
  "beauty-salon": WALK_IN,
  "spa-wellness": WALK_IN,
  fitness: { ...WALK_IN, arrived: "Checked in" },
  automotive: { ...WALK_IN, arrived: "Dropped off" },
  plumbing: FIELD_WORK,
  hvac: FIELD_WORK,
  electrical: FIELD_WORK,
  "home-services": FIELD_WORK,
  "cleaning-services": FIELD_WORK,
  "pest-control": FIELD_WORK,
  "landscaping-lawn-care": FIELD_WORK,
  "real-estate": { ...GENERAL, arrived: "Attended" },
  "property-management": { ...GENERAL, arrived: "Attended" },
  "photography-events": { ...GENERAL, guests: true },
  childcare: { ...GENERAL, arrived: "Dropped off" },
};

export const todayConfig = (industrySlug) => TODAY_BY_INDUSTRY[industrySlug] ?? GENERAL;

// What each "connect" card says. Shown instead of made-up numbers.
export const CONNECT = {
  orders: { icon: "receipt_long", title: "Orders", text: "Dine-in, takeout and delivery orders appear here once your ordering or till system is connected." },
  revenue: { icon: "payments", title: "Revenue", text: "Today's takings appear here once payments are connected." },
  tables: { icon: "table_restaurant", title: "Table layout", text: "A live floor plan needs your table positions and seating status. Your tables are listed under Restaurant operations." },
  reviews: { icon: "reviews", title: "Reviews & feedback", text: "Your rating and latest reviews appear here once Google reviews are connected. You can already send your review link." },
};

// Booking details per industry, for the calendar and its side panel. Each field is [label, key]; keys read real
// columns: party_size, staff (staff_id), type (appointment_type), location, address (location or the customer's
// address), notes (description). A field with no value is left out, and an industry never shows another's fields.
// "{staff}" is replaced by the industry's word for staff (Technician, Provider, Stylist ...).
const FIELDS_GENERAL = [["{staff}", "staff"], ["Type", "type"], ["Where", "location"], ["Notes", "notes"]];
const FIELDS_FIELD_WORK = [["{staff}", "staff"], ["Service type", "type"], ["Service address", "address"], ["Notes", "notes"]];
const FIELDS_CLINIC = [["{staff}", "staff"], ["Appointment type", "type"], ["Notes", "notes"]];
const FIELDS_SERVICE = [["{staff}", "staff"], ["Service", "type"], ["Notes", "notes"]];
export const BOOKING_FIELDS = {
  restaurant: [["Guests", "party_size"], ["Table", "location"], ["Seating and notes", "notes"]],
  hospitality: [["Guests", "party_size"], ["Room", "location"], ["Requests", "notes"]],
  hotels: [["Guests", "party_size"], ["Room", "location"], ["Requests", "notes"]],
  dental: FIELDS_CLINIC, healthcare: FIELDS_CLINIC, "pet-care-veterinary": [["{staff}", "staff"], ["Visit type", "type"], ["Pet and notes", "notes"]],
  plumbing: FIELDS_FIELD_WORK, electrical: FIELDS_FIELD_WORK, "home-services": FIELDS_FIELD_WORK, "pest-control": FIELDS_FIELD_WORK,
  "landscaping-lawn-care": FIELDS_FIELD_WORK, "cleaning-services": [["Assigned team", "staff"], ["Service type", "type"], ["Property", "address"], ["Notes", "notes"]],
  hvac: [["{staff}", "staff"], ["Maintenance type", "type"], ["Service address", "address"], ["Equipment and notes", "notes"]],
  "real-estate": [["{staff}", "staff"], ["Property", "location"], ["Buyer notes", "notes"]],
  "property-management": [["{staff}", "staff"], ["Property", "location"], ["Notes", "notes"]],
  "beauty-salon": FIELDS_SERVICE, "spa-wellness": FIELDS_SERVICE, fitness: [["{staff}", "staff"], ["Session", "type"], ["Notes", "notes"]],
  automotive: [["{staff}", "staff"], ["Repair type", "type"], ["Vehicle and notes", "notes"]],
};
export const bookingFields = (industrySlug, staffWord) =>
  (BOOKING_FIELDS[industrySlug] ?? FIELDS_GENERAL).map(([label, key]) => [label.replace("{staff}", staffWord), key]);

// The value of one booking field.
export function fieldValue(key, appt, person, staffName) {
  if (key === "party_size") return appt.party_size ? String(appt.party_size) : null;
  if (key === "staff") return appt.staff_id ? staffName[appt.staff_id] ?? "Former team member" : null;
  if (key === "type") return appt.appointment_type || null;
  if (key === "location") return appt.location || null;
  if (key === "address") return appt.location || person?.address || null;
  if (key === "notes") return appt.description || null;
  return null;
}
