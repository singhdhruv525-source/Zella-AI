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
