// The heading and the one-line note on the Today page. They change on each visit and differ by
// industry, so the page doesn't feel the same every time. Lines make no claims about numbers.
const GENERAL = [
  "Here's {biz} at a glance.",
  "Let's see how {biz} is doing.",
  "Everything {biz} needs, in one place.",
  "The latest from {biz}.",
  "Your front desk has been busy. Here's the picture.",
  "A quick look before the day gets going.",
  "Calls, customers and bookings, all in one view.",
  "Here's what's happening at {biz}.",
];

const BY_INDUSTRY = {
  dental: ["Healthy smiles, healthy schedule.", "Chairs, check-ups and callbacks, all in one view.", "A clear schedule makes for calm appointments."],
  healthcare: ["Patients first. Here's your day.", "A well-run front desk, ready for the day.", "Appointments and messages, all in one view."],
  beautysalon: ["Chairs full, phones handled.", "Looking good starts at the front desk.", "Here's the book for the day."],
  fitness: ["Members first. Here's the floor at a glance.", "Classes, trials and members, all in one view.", "Strong schedule, strong week."],
  restaurant: ["Tables, bookings and calls, ready for service.", "Here's the front of house at a glance.", "Ready for the rush."],
  plumbing: ["Jobs, quotes and callbacks, all in one view.", "Every call logged, so the work can start.", "Here's the job board."],
  electrical: ["Jobs, quotes and callbacks, all in one view.", "Every call logged, so the work can start.", "Here's the job board."],
  hvac: ["Jobs, quotes and callbacks, all in one view.", "Every call logged, so the work can start.", "Here's the job board."],
  homeservices: ["Jobs, quotes and callbacks, all in one view.", "Here's the job board for today."],
  legal: ["Enquiries and consultations, all in one view.", "Every enquiry handled with care.", "Here's the matter board."],
  financialservices: ["Enquiries and reviews, all in one view.", "Here's your client pipeline at a glance."],
  realestate: ["Viewings, enquiries and deals, all in one view.", "Here's the pipeline at a glance."],
  education: ["Enquiries and applications, all in one view.", "Here's the intake at a glance."],
  petcareveterinary: ["Happy pets, happy owners. Here's your day.", "Visits and reminders, all in one view."],
  spawellness: ["A calm front desk, ready for the day.", "Bookings and rebookings, all in one view."],
  childcare: ["Families first. Here's your day at a glance.", "Enquiries, tours and start dates, all in one view."],
  automotive: ["Repairs, quotes and pickups, all in one view.", "Here's the workshop at a glance."],
  landscapinglawncare: ["Jobs and plans, all in one view.", "Here's the job board for the week."],
  pestcontrol: ["Jobs and follow-ups, all in one view.", "Here's the job board for today."],
  photographyevents: ["Enquiries, shoots and deliveries, all in one view.", "Here's the booking calendar at a glance."],
  propertymanagement: ["Requests and leases, all in one view.", "Here's the property desk at a glance."],
};

const key = (name) => String(name ?? "").toLowerCase().replace(/[^a-z]/g, "");
const pick = (list, avoid) => {
  const options = list.length > 1 ? list.filter((x) => x !== avoid) : list;
  return options[Math.floor(Math.random() * options.length)];
};
const remember = (name, value) => { try { localStorage.setItem(name, value); } catch { /* optional */ } };
const recall = (name) => { try { return localStorage.getItem(name) ?? ""; } catch { return ""; } };

// true = "Welcome back", false = "Good morning/afternoon/evening". Alternates, never the same twice in a row.
export function welcomeStyle() {
  const last = recall("zella.today.heading");
  const next = last === "welcome" ? "time" : last === "time" ? "welcome" : Math.random() < 0.5 ? "welcome" : "time";
  remember("zella.today.heading", next);
  return next === "welcome";
}

export function todayNote(industry, businessName) {
  const pool = [...GENERAL, ...(BY_INDUSTRY[key(industry)] ?? []), ...(BY_INDUSTRY[key(industry)] ?? [])];
  const choice = pick(pool, recall("zella.today.note"));
  remember("zella.today.note", choice);
  return choice.replaceAll("{biz}", businessName || "your business");
}
