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
    appointment_cancelled: ["A reservation was canceled. A table just opened up.", "One cancellation. That table is free again."],
    appointment_rescheduled: ["A guest picked a different time. Reservations are updated."],
    customer_arrived: (n) => [`${n.title}. Time to show them to their table!`, `${n.title}. A warm welcome awaits.`],
    new_lead: () => ["A new guest is asking about a table!", "Someone new wants to dine with you. Say hello!"],
    callback: ["A guest is waiting for your call.", "A guest would love a call back."],
    customer_reply: ["A guest wrote back!"],
    customer_request: ["A guest has a special request. Let's make it happen."],
  },
  hospitality: {
    appointment_cancelled: ["A reservation was canceled. That space is free again."],
    customer_arrived: (n) => [`${n.title}. Welcome them in!`],
    new_lead: () => ["A new guest is asking about a stay!"],
  },
  childcare: {
    new_lead: () => ["A new family is getting in touch. Say hello!"],
    appointment_cancelled: ["A tour was canceled. That time is free again."],
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
    appointment_cancelled: [`A ${B} was canceled. That time is free again.`, `One ${B} canceled. Your calendar has room.`],
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
  appointment_cancelled: ["Plans changed. A slot just opened up.", "One cancellation. That time is yours again.", "A booking was canceled. Your calendar has room."],
  appointment_rescheduled: ["Someone found a better time. Calendar updated!", "A booking moved. We've already updated your calendar."],
  appointment_cancelled_mine: ["One of your bookings was canceled. Time for a breather?", "A booking of yours was canceled. Your calendar has room."],
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

// The rest of the kinds the database sends (2026-10-28), so nothing in the bell reads like a log line.
// Kinds whose title carries the facts (a name, a number) keep it: the function gets the original notification.
Object.assign(TITLES, {
  // account and plan
  account_cancelled: ["Your Zella plan has been canceled. We're sorry to see you go."],
  account_reactivated: ["Welcome back! Your workspace is active again.", "You're back! Everything is switched on again."],
  account_suspended: ["Your workspace is paused. Let's get it sorted together."],
  subscription_cancelled: ["Your subscription was canceled. Your records are safe for now."],
  cancellation_coming: ["Your plan is ending soon. Want to keep Zella answering?"],
  trial_ended: ["Your trial has ended. We'd love to keep helping you."],
  usage_threshold: (n) => [`Minutes check-in: ${n.title}`, `Heads up on your minutes: ${n.title}`],
  // calls, callbacks and the AI receptionist
  agent_failures: ["Your AI receptionist hit a few bumps. Worth a look."],
  agent_sync_failed: ["An update didn't reach your AI receptionist yet. We'll try again."],
  callback_digest: ["Your callback round-up is ready."],
  callback_escalated: ["A callback needs someone senior. Can you step in?"],
  callback_review: ["A callback needs a quick check before anyone calls."],
  transfer_failures: ["Calls couldn't be passed to a person a few times. Let's check the number."],
  transfer_fallback_applied: ["Calls are now going to your backup number. Nobody gets left hanging."],
  wrong_answer_reported: ["Someone flagged an answer from your AI receptionist. Let's fix it together."],
  spot_check: ["A few AI conversations are ready for a quick spot check."],
  on_call_starting: (n) => /^You're on call/.test(n.title)
    ? [`${n.title}. Phone charged? You've got this.`, `${n.title}. After-hours calls will come to you.`]
    : [`${n.title}. After-hours calls are covered.`, `Tonight's cover: ${n.title.replace(/^(.+) is on call/, "$1, on call")}.`],
  // leads, work and the team
  lead_assigned: ["A new lead has your name on it. Say hello!", "You've got a lead! A quick hello goes a long way."],
  task_escalated: ["A task needs a hand. Can you help it over the line?"],
  appointment_request: ["Someone asked for an appointment. Pick a time that suits.", "A booking request is waiting for your yes."],
  appointments_need_outcome: ["A few visits need marking as done or no-show.", "Quick tidy-up: a few bookings need an outcome."],
  customer_request_overdue: ["A customer's request is still waiting. Let's close the loop."],
  team_scorecard: ["A few things are waiting from last week.", "Monday check-in: a little catching up to do."],
  duplicate_scan: ["We found some records that may be the same person."],
  calendar_sync_owner: ["Your calendar sync needs a look."],
  // messages and email
  email_complaint: ["Someone marked an email as spam. We've stopped emailing them."],
  email_unsubscribed: ["A customer unsubscribed from emails. We'll respect that."],
  kpi_message_failures: ["More messages than usual didn't get through. Let's check why."],
  kpi_missed_calls: ["More calls than usual went unanswered. Let's look together."],
  kpi_no_shows: ["No-shows are a little higher than usual. Reminders may help."],
  // knowledge and the website
  knowledge_gap: ["Callers asked something your AI couldn't answer. Teach it once, it remembers.", "A new question came up. A quick answer helps every caller after."],
  knowledge_repeat: ["The same question keeps coming up. Worth adding to Knowledge?"],
  knowledge_conflict: ["Two answers in Knowledge disagree. Which one is right?"],
  knowledge_failed: ["A knowledge update didn't go through. Let's try again."],
  integration_reminder: ["One small connection would make Zella even more helpful."],
  reconnect_reminder: ["A connection is still waiting to be reconnected."],
  data_rights_due: ["A privacy request is due soon. Please take a look."],
  website_review: ["New pages from your website are ready for a look."],
  website_new_pages: ["We spotted new pages on your website."],
  website_page_broken: ["A page on your website isn't loading. Worth a check."],
  website_page_removed: ["A page disappeared from your website. We've kept your AI up to date."],
  // social, spam and reviews
  social_comment: ["Someone commented on your social post!", "A new comment is waiting on social."],
  social_handoff: ["A social conversation needs a person. Over to you!"],
  meta_disconnected: ["Facebook or Instagram got disconnected. Let's reconnect it."],
  meta_lead_failed: ["A lead from Facebook didn't come through. Let's take a look."],
  meta_lead_incomplete: ["A Facebook lead arrived with missing details."],
  meta_permissions_missing: ["Facebook needs a little more permission to keep things running."],
  spam_high_risk: ["Zella blocked something suspicious. Have a quick look."],
  spam_unreviewed: ["A few suspicious contacts are waiting for your call on them."],
  spam_weekly_report: ["Your spam protection week in review is ready."],
  low_review: (n) => [`${n.title}. A kind reply can turn it around.`, `${n.title}. Your reply draft is ready.`],
  review_reply_failed: ["A review reply couldn't be posted. Let's try again."],
  reviews_disconnected: ["Google reviews stopped syncing. Let's reconnect."],
  // celebrations: the facts are in the title
  milestone: (n) => [`${n.title}! 🎉`, `Milestone: ${n.title.charAt(0).toLowerCase()}${n.title.slice(1)}!`, `${n.title}. Here's to the next one!`],
  five_star_review: (n) => [`${n.title}! ⭐`, `Five stars! ${n.title.replace(/^5-star review from /, "From ")}.`, `${n.title}. Your team earned this one.`],
  best_week: ["Your best week in three months! 🎉", "Record week! Your busiest in three months."],
});

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
  emergency_call: ["This is an emergency. Please look first.", "An emergency call is in. Everything else can wait."],
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

// Icon and tone for each kind in the bell and pop-ups. Unknown kinds get a plain bell.
const ICONS = {
  new_lead: "person_add", lead_assigned: "person_add", website_lead: "language", social_lead: "share", lead_escalated: "front_hand", lead_overdue: "hourglass_bottom",
  callback: "phone_callback", callback_assigned: "phone_callback", callback_soon: "alarm", callback_overdue: "phone_missed", callback_escalated: "phone_forwarded",
  callback_digest: "summarize", callback_review: "fact_check", emergency_call: "emergency", transfer_failures: "phone_disabled", transfer_fallback_applied: "call_split",
  appointment_cancelled: "event_busy", appointment_cancelled_mine: "event_busy", appointment_rescheduled: "event_repeat", appointment_moved_mine: "event_repeat",
  appointment_request: "event_available", appointments_need_outcome: "event_note", customer_arrived: "waving_hand", on_call_starting: "support_agent",
  customer_reply: "chat", customer_email: "mail", customer_request: "assignment", customer_request_overdue: "assignment_late", social_message: "forum",
  social_comment: "comment", social_handoff: "forum", social_booking: "event_available", slow_reply: "schedule",
  task_overdue: "task_alt", task_escalated: "task_alt", unassigned_work: "assignment_ind", work_reassigned: "swap_horiz", shift_handover: "swap_horiz",
  team_scorecard: "leaderboard", staff_joined: "group_add", staff_unavailable: "event_busy", time_off_request: "beach_access", time_off_decision: "beach_access",
  approval_requested: "verified_user", approval_waiting: "verified_user", draft_ready: "edit_note", call_insight: "insights",
  knowledge_gap: "help", knowledge_repeat: "repeat", knowledge_conflict: "rule", knowledge_failed: "error", knowledge_report: "menu_book",
  wrong_answer_reported: "report", spot_check: "fact_check", agent_config_published: "auto_awesome", agent_failures: "error", agent_sync_failed: "sync_problem",
  daily_summary: "today", weekly_review: "date_range", team_summary: "groups", kpi_missed_calls: "trending_down", kpi_no_shows: "trending_down", kpi_message_failures: "trending_down",
  email_bounced: "unsubscribe", email_complaint: "report", email_unsubscribed: "unsubscribe", sms_not_delivered: "sms_failed", messages_failed: "sms_failed", reminder_failed: "notifications_off",
  integration_down: "link_off", integration_reconnect: "link", integration_reminder: "extension", reconnect_reminder: "link", calendar_disconnected: "event_busy", calendar_sync_owner: "sync",
  meta_disconnected: "link_off", meta_lead_failed: "error", meta_lead_incomplete: "help", meta_permissions_missing: "lock",
  website_review: "language", website_new_pages: "language", website_page_broken: "link_off", website_page_removed: "delete",
  spam_high_risk: "gpp_maybe", spam_unreviewed: "gpp_maybe", spam_weekly_report: "shield",
  low_review: "reviews", five_star_review: "star", review_reply_failed: "error", reviews_disconnected: "link_off",
  escalation_unacknowledged: "front_hand", milestone: "celebration", best_week: "emoji_events", went_live: "rocket_launch", business_welcome: "waving_hand",
  payment_failed: "credit_card_off", payment_overdue: "credit_card", payment_received: "paid", renewal_upcoming: "autorenew", trial_ending: "hourglass_bottom", trial_ended: "hourglass_empty",
  usage_threshold: "timer", account_cancelled: "cancel", account_reactivated: "check_circle", account_suspended: "pause_circle", subscription_cancelled: "cancel", cancellation_coming: "event",
  setup_incomplete: "checklist", setup_reminder: "checklist", incident_open: "warning", incident_resolved: "check_circle",
  data_rights_request: "privacy_tip", data_rights_due: "privacy_tip", duplicate: "content_copy", duplicate_scan: "content_copy", industry_alert: "campaign",
};
export const CELEBRATE = new Set(["milestone", "five_star_review", "best_week", "went_live", "payment_received"]);
export function noteIcon(n) {
  const icon = ICONS[n?.kind] ?? "notifications";
  const tone = n?.severity === "urgent" ? "urgent" : CELEBRATE.has(n?.kind) ? "celebrate" : n?.severity === "warning" ? "warning" : "info";
  return { icon, tone };
}
