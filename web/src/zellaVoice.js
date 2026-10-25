// Zella's voice for notifications and confirmations inside the CRM: warm, short, never robotic.
// The facts (names, times, reasons) still come from the original message; only the wrapping changes.
// Urgent and safety-related messages stay plain and direct, with warmth but no jokes.

const hash = (text) => { let h = 0; for (const ch of String(text)) h = (h * 31 + ch.charCodeAt(0)) >>> 0; return h; };
const choose = (list, seed) => list[hash(seed) % list.length];
const roll = (list) => list[Math.floor(Math.random() * list.length)];

const key = (name) => String(name ?? "").toLowerCase().replace(/[^a-z]/g, "");

// Industry flavour: a restaurant talks about tables and guests, not appointments and customers.
const BY_INDUSTRY = {
  restaurant: {
    industry_alert: (n) => [`Kitchen-side heads up: ${n.title}`, `Front of house, take a look: ${n.title}`, `Zella spotted something: ${n.title}`],
    appointment_cancelled: ["A reservation was cancelled. A table just opened up.", "One cancellation. That table is free again."],
    appointment_rescheduled: ["A guest picked a different time. Reservations are updated."],
    customer_arrived: (n) => [`${n.title}. Time to show them to their table!`, `${n.title}. A warm welcome awaits.`],
    new_lead: () => ["A new guest is asking about a table!", "Someone new wants to dine with you. Say hello!"],
    callback: ["A guest is waiting for your call.", "A guest would love a call back."],
    customer_reply: ["A guest wrote back!"],
    customer_request: ["A guest has a special request. Let's make it happen."],
  },
  hospitality: {
    appointment_cancelled: ["A reservation was cancelled. That space is free again."],
    customer_arrived: (n) => [`${n.title}. Welcome them in!`],
    new_lead: () => ["A new guest is asking about a stay!"],
  },
  childcare: {
    new_lead: () => ["A new family is getting in touch. Say hello!"],
    appointment_cancelled: ["A tour was cancelled. That time is free again."],
  },
  dental: {
    new_lead: () => ["A new patient is getting in touch. Say hello!"],
    customer_arrived: (n) => [`${n.title}. Time to welcome them in!`],
  },
};


// Every industry talks about its own people and bookings: patients and appointments, guests and tables, tenants and viewings.
const NOUNS = {"automotive": {"p": "customer", "ps": "customers", "b": "service slot"}, "beautysalon": {"p": "client", "ps": "clients", "b": "chair"}, "childcare": {"p": "family", "ps": "families", "b": "tour"}, "cleaningservices": {"p": "client", "ps": "clients", "b": "clean"}, "dental": {"p": "patient", "ps": "patients", "b": "appointment"}, "ecommerce": {"p": "customer", "ps": "customers", "b": "order"}, "education": {"p": "student", "ps": "students", "b": "session"}, "electrical": {"p": "customer", "ps": "customers", "b": "job"}, "financialservices": {"p": "client", "ps": "clients", "b": "consultation"}, "fitness": {"p": "member", "ps": "members", "b": "class"}, "healthcare": {"p": "patient", "ps": "patients", "b": "appointment"}, "homeservices": {"p": "customer", "ps": "customers", "b": "visit"}, "hospitality": {"p": "guest", "ps": "guests", "b": "stay"}, "hvac": {"p": "customer", "ps": "customers", "b": "service call"}, "insurance": {"p": "client", "ps": "clients", "b": "review"}, "landscapinglawncare": {"p": "customer", "ps": "customers", "b": "visit"}, "legal": {"p": "client", "ps": "clients", "b": "consultation"}, "other": {"p": "customer", "ps": "customers", "b": "booking"}, "pestcontrol": {"p": "customer", "ps": "customers", "b": "visit"}, "petcareveterinary": {"p": "pet owner", "ps": "pet owners", "b": "visit"}, "photographyevents": {"p": "client", "ps": "clients", "b": "shoot"}, "plumbing": {"p": "customer", "ps": "customers", "b": "job"}, "professionalservices": {"p": "client", "ps": "clients", "b": "meeting"}, "propertymanagement": {"p": "tenant", "ps": "tenants", "b": "viewing"}, "realestate": {"p": "buyer", "ps": "buyers", "b": "viewing"}, "restaurant": {"p": "guest", "ps": "guests", "b": "table"}, "spawellness": {"p": "guest", "ps": "guests", "b": "treatment"}, "travel": {"p": "traveller", "ps": "travellers", "b": "trip"}};
function industryVoice(k) {
  const n = NOUNS[k];
  if (!n || k === "other") return null;
  const P = n.p, B = n.b;
  const a = /^[aeiou]/i.test(P) ? "An" : "A";
  return {
    new_lead: () => [`${a} new ${P} is getting in touch. Say hello!`, `Someone new wants to become ${a.toLowerCase()} ${P}. Say hello!`, `A new ${P} enquiry just arrived.`],
    callback: [`${a} ${P} is waiting for your call.`, `${a} ${P} would love a call back.`],
    appointment_cancelled: [`A ${B} was cancelled. That time is free again.`, `One ${B} cancelled. Your calendar has room.`],
    customer_arrived: (x) => [`${x.title}. Time to welcome them in!`, `${x.title}. Your ${P} is here!`],
    customer_reply: [`${a} ${P} wrote back!`, `New reply from ${a.toLowerCase()} ${P}. The conversation is moving.`],
    customer_request: [`${a} ${P} has a request. Let's make it happen.`],
  };
}

// Swap generic words for the business's own: appointment -> reservation, customer -> guest.
export function localize(text, term) {
  if (typeof text !== "string" || !term) return text;
  const lower = (value) => String(value).toLowerCase();
  return text
    .replace(/\bappointments\b/gi, (m) => (m[0] === m[0].toUpperCase() ? term("appointments") : lower(term("appointments"))))
    .replace(/\bappointment\b/gi, (m) => (m[0] === m[0].toUpperCase() ? term("appointment") : lower(term("appointment"))))
    .replace(/\bcustomers\b/gi, (m) => (m[0] === m[0].toUpperCase() ? term("customers") : lower(term("customers"))))
    .replace(/\bcustomer\b/gi, (m) => (m[0] === m[0].toUpperCase() ? term("customer") : lower(term("customer"))));
}

// Bell titles by kind. A function gets the original title (for kinds that carry a name).
const TITLES = {
  new_lead: (n) => /priority/i.test(n.title)
    ? ["A hot lead just arrived. Worth a quick hello.", "Priority lead! Someone's keen to hear from you.", "This one's a strong lead. Say hello while it's warm."]
    : ["A new lead just walked in!", "Fresh lead! Someone's interested in you.", "Someone new wants to talk. Say hello!"],
  website_lead: ["Your website just made a new friend.", "Someone filled in your form. Say hello!"],
  social_lead: ["A new lead found you on social media!", "Someone reached out from social. Say hello!"],
  callback: ["Someone's waiting for your call.", "A callback is waiting. They'd love to hear from you.", "A friendly call-back is on your list."],
  callback_assigned: ["A callback was handed to you. Over to you!", "You've got a callback. A warm voice will go a long way."],
  callback_soon: ["A callback is coming up soon. Almost time!", "Heads up: a callback is due shortly."],
  callback_overdue: ["Someone is still waiting on that callback.", "A callback is running late. A quick call will make their day."],
  appointment_cancelled: ["Plans changed. A slot just opened up.", "One cancellation. That time is yours again.", "A booking was cancelled. Your calendar has room."],
  appointment_rescheduled: ["Someone found a better time. Calendar updated!", "A booking moved. We've already updated your calendar."],
  appointment_cancelled_mine: ["One of your bookings was cancelled. Time for a breather?", "A booking of yours was cancelled. Your calendar has room."],
  appointment_moved_mine: ["One of your bookings moved. We've updated everything."],
  customer_arrived: (n) => [`${n.title}. Time to say hello!`, `${n.title}. Someone's here to see you!`, `Doorbell! ${n.title}.`],
  customer_reply: ["A customer wrote back!", "You've got a reply. Someone's talking to you.", "New reply. The conversation is moving."],
  customer_email: ["A customer sent an email.", "A new email just landed from a customer."],
  customer_request: ["A customer has a request for you.", "Someone asked for something. Let's take a look."],
  social_message: ["A new message from social media!", "Someone messaged you on social. Say hello!"],
  social_booking: ["Someone booked through social media. Lovely!"],
  emergency_call: ["Emergency call. Please look at this one first.", "This one can't wait. An emergency call came in."],
  lead_escalated: ["Someone needs a person, and soon. Can you step in?", "A conversation needs your touch. Over to you."],
  escalation_unacknowledged: ["Someone is still waiting for a person. Please take a look."],
  task_overdue: ["A gentle nudge: a task is running late.", "One task is overdue. A small step gets it moving."],
  lead_overdue: ["A lead is waiting for a first hello.", "Someone's been waiting. A quick reply will help."],
  unassigned_work: ["Some work needs an owner. Who's up for it?"],
  work_reassigned: ["Some work was handed to someone new."],
  slow_reply: ["A customer's been waiting a little while for a reply."],
  call_insight: ["Zella noticed something worth a look on a recent call.", "A recent call has something worth your attention."],
  approval_requested: ["Someone is asking for your thumbs up."],
  approval_waiting: ["A thumbs-up is still waiting on you."],
  time_off_request: ["A teammate is hoping for some time off.", "Someone on your team has asked for time off."],
  time_off_decision: ["There's an answer on your time-off request."],
  staff_joined: ["A new teammate just joined. Welcome them in!", "Say hello! Someone new has joined the team."],
  staff_unavailable: ["Someone on your team is away. We've kept things covered."],
  went_live: ["You're live! Zella is picking up the phone.", "It's official: Zella is on the line for you."],
  business_welcome: ["Welcome aboard! We're glad you're here.", "Welcome to Zella. We're right here with you."],
  setup_incomplete: ["A few small steps left before you go live."],
  setup_reminder: ["Almost there. A few steps are left to finish setup."],
  trial_ending: ["Your trial is wrapping up. We'd love to keep you."],
  payment_failed: ["Your payment didn't go through. Easy to fix, let's sort it."],
  payment_overdue: ["A payment is overdue. A quick look will sort it."],
  payment_received: ["Payment received. Thank you!", "Thanks! Your payment landed safely."],
  renewal_upcoming: ["Your plan renews soon. Nothing you need to do unless you'd like to change something."],
  integration_down: ["One of your connections needs attention. We'll walk you through it."],
  integration_reconnect: ["A connection needs a quick reconnect. It only takes a moment."],
  calendar_disconnected: ["Your calendar got disconnected. Let's reconnect it."],
  email_bounced: ["An email didn't land. Worth a quick look."],
  sms_not_delivered: ["A text message didn't get through. Let's try again."],
  messages_failed: ["Some messages didn't get through. Let's try again."],
  reminder_failed: ["A reminder didn't go out. Let's try that again."],
  daily_summary: ["Your day at a glance is ready."],
  weekly_review: ["Your week in review is ready. Look how far you've come!"],
  team_summary: ["Your team recap is ready."],
  incident_open: ["We hit a bump, and we're on it."],
  incident_resolved: ["All clear. Everything's back to normal."],
  data_rights_request: ["A customer made a privacy request. Please take a look."],
  agent_config_published: ["Your AI receptionist has a fresh update. She's ready!"],
  knowledge_report: ["Your knowledge report is ready."],
  duplicate: ["Two records look like the same person. Want to tidy up?"],
  industry_alert: (n) => [`Zella spotted something: ${n.title}`, `Heads up! ${n.title}`, `Worth a look: ${n.title}`, `A little nudge from Zella: ${n.title}`],
  draft_ready: ["Zella wrote a message for you. Give it a look and send it!", "A message is warmed up and waiting for your OK.", "Fresh draft on your desk. Edit it, send it, or skip it.", "We've done the writing. You make the call."],
  shift_handover: ["Work was handed to you. Your team is counting on you!", "A handover just landed on your desk. Welcome to the next leg.", "Baton passed! Some work is yours now."],
};

// More ways to say the same thing, so the bell never feels like a template. Only the wording changes, never the facts.
const EXTRA = {
  website_lead: ["A visitor liked your website enough to say hi!", "Your website just did its job. A new enquiry is in."],
  social_lead: ["Social media delivered! Someone wants to talk.", "A new face from social is knocking."],
  callback: ["A caller is keeping a seat warm for your call.", "Somebody's hoping for a ring from you today."],
  callback_assigned: ["A callback has your name on it.", "This callback was made for you."],
  callback_soon: ["Callback o'clock is almost here.", "Get ready: a callback is due shortly."],
  callback_overdue: ["A callback is sitting patiently. A quick ring would make their day.", "Someone's still hoping to hear from you."],
  appointment_cancelled: ["A slot just came free. Breathing room!", "Cancellation! That gap is yours to fill or enjoy."],
  appointment_rescheduled: ["Someone shuffled their plans. We kept your calendar tidy.", "A booking hopped to a new time, all updated."],
  customer_reply: ["Ding! A customer wrote back.", "They answered! The conversation lives on."],
  customer_email: ["A customer's email just arrived.", "Mail call! A customer wrote to you."],
  customer_request: ["A customer has a little ask for you.", "A request came in. Let's make someone's day."],
  emergency_call: ["This one is urgent. Please look first.", "An emergency call is in. Everything else can wait."],
  lead_escalated: ["A conversation needs your human touch.", "Zella's passing this one to you. It's a good one."],
  task_overdue: ["A task is feeling a bit forgotten. A small nudge will do.", "One task is running behind, and it'd love your attention."],
  lead_overdue: ["A lead is still waiting for hello number one.", "Don't let this lead go cold. A quick hello will do it."],
  call_insight: ["Zella was listening and noticed something worth a look.", "A recent call taught us something. Take a peek."],
  staff_joined: ["Team news: someone new has joined. Wave hello!"],
  went_live: ["We're live! The phone is ours now.", "Go time! Zella is answering calls for you."],
  payment_received: ["Payment received. You're a star.", "Thank you! That payment arrived safely."],
  daily_summary: ["Your day, wrapped up neatly.", "Today's recap is ready, with everything that mattered."],
  weekly_review: ["Your week, all tied up with a bow. Take a look!", "Weekly review is ready. It was a good one."],
  incident_resolved: ["Back to smooth sailing.", "All fixed. Thanks for your patience."],
  agent_config_published: ["Your AI receptionist just learned something new.", "Fresh update live. She's sharper than before!"],
  duplicate: ["These two look like the same person. Shall we tidy up?", "Double vision: two records may be one person."],
};
for (const [kind, extra] of Object.entries(EXTRA)) if (Array.isArray(TITLES[kind])) TITLES[kind] = [...TITLES[kind], ...extra];

// Notification shown in the bell: same facts, friendlier words.
export function voiceTitle(n, workspace) {
  const term = workspace?.terminology ? (k) => workspace.terminology[k] || k : null;
  if (n.kind === "industry_alert" && n.severity === "urgent") return localize(n.title, term); // urgent stays plain and direct
  const ind = key(workspace?.industry);
  const entry = BY_INDUSTRY[ind]?.[n.kind] ?? industryVoice(ind)?.[n.kind] ?? TITLES[n.kind];
  if (!entry) return localize(n.title, term);
  const list = typeof entry === "function" ? entry(n) : entry;
  return localize(choose(list, n.id ?? n.title), term);
}

// Short confirmations ("Saved.") in Zella's voice. Unknown messages are left alone.
const RULES = [
  [/^Details saved\.?$/, () => roll(["Saved. Looking good.", "All saved. Nicely done."])],
  [/^Callback scheduled\.?$/, () => roll(["Callback scheduled. They'll be glad to hear from you.", "Callback set. A friendly call is on its way."])],
  [/^Callback finished\.?$/, () => roll(["Callback done. One less thing on your plate.", "Callback complete. Nicely handled."])],
  [/^Marked as contacted\.?$/, () => roll(["Marked as contacted. Nice and quick.", "Contacted! They'll appreciate the hello."])],
  [/^Booking confirmed\. Reminders are set\.?$/, () => roll(["Booked! Reminders are set so nobody forgets.", "It's in the calendar, and reminders are set."])],
  [/^Booking confirmed\.?$/, () => "Confirmed! It's in the calendar."],
  [/^Lead created\.?$/, () => roll(["Lead added. A promising start.", "New lead saved. Welcome them in!"])],
  [/^Removed\. The time is open again\.?$/, () => "Done. That time is open again."],
  [/^Block removed\. The time is open again\.?$/, () => "Done. That time is open again."],
  [/^You're live\./, () => "You're live! Zella is picking up the phone."],
  [/^Run queued to try again\.?$/, () => "Trying again. Fingers crossed!"],
  [/^Submitted\. /, (m) => m.replace(/^Submitted\./, "Thanks, submitted.")],
  [/^Added\. /, (m) => m.replace(/^Added\./, "Added. Nice one.")],
  [/^(.+) moved to (.+)$/, (m, a, b) => `${a} moved to ${b}. The calendar is all updated.`],
  [/^(.+) is (on|off)\.$/, (m, a, s) => (s === "on" ? `${a} is on. It's got it from here.` : `${a} is off. We'll hold back.`)],
  [/^(.+) options saved\.$/, (m, a) => `${a} options saved. Fresh settings, ready to go.`],
  [/^(.+) is saved\.$/, (m, a) => `${a} is saved and ready to go.`],
  [/^Suggestion dismissed\.?$/, () => "Dismissed. Moving on."],
  [/^Saved to the customer\.?$/, () => "Saved to the customer. Thanks for checking!"],
];

export function warm(message, workspace) {
  if (typeof message !== "string" || !message) return message;
  const term = workspace?.terminology ? (k) => workspace.terminology[k] || k : null;
  for (const [pattern, make] of RULES) {
    const hit = message.match(pattern);
    if (hit) return localize(make(message, ...hit.slice(1)), term);
  }
  return localize(message, term);
}

export const ALL_QUIET = [
  "All quiet. Nothing needs you right now.",
  "You're all caught up. Enjoy the calm.",
  "Nothing new. We'll tap you on the shoulder if that changes.",
];
export const pickQuiet = () => roll(ALL_QUIET);
