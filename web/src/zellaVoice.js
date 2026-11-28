// Zella Voice's wording for notifications and confirmations inside the CRM (docs/DESIGN_SYSTEM.md, Notifications and
// Writing guide; owner, 27 Nov 2026): plain and calm, one line per kind, no jokes, no exclamation marks, no emoji, and
// in the business's own words. A notification says what happened; names, times and numbers come from the server's
// title and body, which are kept. Urgent notifications show the server's own title.

const key = (name) => String(name ?? "").toLowerCase().replace(/[^a-z]/g, "");
const sentence = (text) => `${String(text ?? "").trim().replace(/\.$/, "")}.`;

// A restaurant talks about tables and guests, not appointments and customers.
const BY_INDUSTRY = {
  restaurant: {
    appointment_cancelled: "A reservation was canceled. The table is free again.",
    appointment_rescheduled: "A guest moved their reservation to a new time.",
    new_lead: "A new guest is asking about a table.",
    callback: "A guest is waiting for a callback.",
    customer_reply: "A guest replied.",
    customer_request: "A guest has a special request.",
  },
  hospitality: {
    appointment_cancelled: "A reservation was canceled. That space is free again.",
    new_lead: "A new guest is asking about a stay.",
  },
};


// Every industry talks about its own people and bookings: patients and appointments, guests and tables, tenants and viewings.
const NOUNS = {"automotive": {"p": "customer", "ps": "customers", "b": "service slot"}, "beautysalon": {"p": "client", "ps": "clients", "b": "chair"}, "childcare": {"p": "family", "ps": "families", "b": "tour"}, "cleaningservices": {"p": "client", "ps": "clients", "b": "clean"}, "dental": {"p": "patient", "ps": "patients", "b": "appointment"}, "ecommerce": {"p": "customer", "ps": "customers", "b": "order"}, "education": {"p": "student", "ps": "students", "b": "session"}, "electrical": {"p": "customer", "ps": "customers", "b": "job"}, "financialservices": {"p": "client", "ps": "clients", "b": "consultation"}, "fitness": {"p": "member", "ps": "members", "b": "class"}, "healthcare": {"p": "patient", "ps": "patients", "b": "appointment"}, "homeservices": {"p": "customer", "ps": "customers", "b": "visit"}, "hospitality": {"p": "guest", "ps": "guests", "b": "stay"}, "hvac": {"p": "customer", "ps": "customers", "b": "service call"}, "insurance": {"p": "client", "ps": "clients", "b": "review"}, "landscapinglawncare": {"p": "customer", "ps": "customers", "b": "visit"}, "legal": {"p": "client", "ps": "clients", "b": "consultation"}, "other": {"p": "customer", "ps": "customers", "b": "booking"}, "pestcontrol": {"p": "customer", "ps": "customers", "b": "visit"}, "petcareveterinary": {"p": "pet owner", "ps": "pet owners", "b": "visit"}, "photographyevents": {"p": "client", "ps": "clients", "b": "shoot"}, "plumbing": {"p": "customer", "ps": "customers", "b": "job"}, "professionalservices": {"p": "client", "ps": "clients", "b": "meeting"}, "propertymanagement": {"p": "tenant", "ps": "tenants", "b": "viewing"}, "realestate": {"p": "buyer", "ps": "buyers", "b": "viewing"}, "restaurant": {"p": "guest", "ps": "guests", "b": "table"}, "spawellness": {"p": "guest", "ps": "guests", "b": "treatment"}, "travel": {"p": "traveler", "ps": "travelers", "b": "trip"}};
// The business's own words win: terminology set for this workspace ("session", "client") replaces the industry's.
function industryVoice(k, own = {}) {
  const n = NOUNS[k];
  if (!n || k === "other") return null;
  const P = own.customer || n.p, B = own.appointment || n.b;
  const a = /^[aeiou]/i.test(P) ? "An" : "A";
  // the industry's own plural when the business's word is the same as the industry's (family -> families)
  const ps = own.customers || (own.customer && own.customer !== n.p ? plural(own.customer) : n.ps);
  const Ps = ps.charAt(0).toUpperCase() + ps.slice(1);
  return {
    best_day: `A record day for your ${plural(B)}`,
    call_surge: `${Ps} are calling more than usual today`,
    new_lead: (x) => (/priority/i.test(x.title) ? `A new ${P} got in touch. It's a priority lead.` : `A new ${P} got in touch.`),
    callback: `${a} ${P} is waiting for a callback.`,
    appointment_cancelled: `A ${B} was canceled. That time is free again.`,
    customer_reply: `${a} ${P} replied.`,
    customer_request: `${a} ${P} has a request.`,
  };
}

// "class" -> "classes", "stay" -> "stays", "service call" -> "service calls"
export function plural(word) {
  const w = String(word ?? "");
  if (/[^aeiou]y$/i.test(w)) return `${w.slice(0, -1)}ies`;   // family -> families
  return /(s|sh|ch|x)$/.test(w) ? `${w}es` : `${w}s`;
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

// Bell titles by kind: one plain line each. A function gets the original notification, for kinds whose title carries
// the facts (a name, a number). Kinds not listed here (usage_threshold, industry_alert, on_call_gap, ...) show the
// server's title as it is. The body under the title always comes from the server.
const TITLES = {
  // leads
  new_lead: (n) => (/priority/i.test(n.title) ? "A new priority lead came in." : "A new lead came in."),
  website_lead: "A new lead came in from your website.",
  social_lead: "A new lead came in from social media.",
  lead_assigned: "A new lead was assigned to you.",
  lead_escalated: "A conversation needs a person.",
  lead_overdue: "A lead is still waiting for a first reply.",
  // callbacks
  callback: "Someone is waiting for a callback.",
  callback_assigned: "A callback was assigned to you.",
  callback_soon: "A callback is due soon.",
  callback_overdue: "A callback is overdue.",
  callback_digest: "Your callback roundup is ready.",
  callback_escalated: "A callback needs a senior team member.",
  callback_review: "A callback needs a check before anyone calls.",
  // calendar
  appointment_cancelled: "A booking was canceled. That time is free again.",
  appointment_rescheduled: "A booking moved to a new time. Your calendar is updated.",
  appointment_cancelled_mine: "One of your bookings was canceled.",
  appointment_moved_mine: "One of your bookings moved to a new time.",
  appointment_request: "Someone asked for an appointment. Pick a time.",
  appointments_need_outcome: "Some appointments need an outcome: done or no show.",
  customer_arrived: (n) => sentence(n.title),
  social_booking: "Someone booked through social media.",
  // messages
  customer_reply: "A customer replied.",
  customer_email: "A customer sent an email.",
  customer_request: "A customer sent a request.",
  customer_request_overdue: "A customer's request is still open.",
  slow_reply: "A customer is waiting for a reply.",
  social_message: "New message on social media.",
  social_comment: "New comment on your social media post.",
  social_handoff: "A social media conversation needs a person.",
  draft_ready: "A draft message is ready to review.",
  // calls and the AI receptionist
  emergency_call: "Emergency call. Please look at this one first.",
  escalation_unacknowledged: "Someone is still waiting for a person.",
  call_insight: "A recent call has a suggestion for you.",
  agent_config_published: "Your AI receptionist's update is live.",
  agent_failures: "Your AI receptionist ran into errors on some calls.",
  agent_sync_failed: "An update didn't reach your AI receptionist yet. We'll try again.",
  transfer_failures: "Some calls couldn't be transferred to a person. Check the transfer number.",
  transfer_fallback_applied: "Calls are now going to your backup number.",
  wrong_answer_reported: "Someone reported a wrong answer from your AI receptionist.",
  spot_check: "Some AI receptionist conversations are ready for a spot check.",
  on_call_starting: (n) => (/^You're on call/.test(n.title) ? `${sentence(n.title)} After hours calls come to you.` : sentence(n.title)),
  went_live: "You're live. Your AI receptionist is answering calls.",
  // the team
  task_overdue: "A task is overdue.",
  task_escalated: "A task was escalated.",
  unassigned_work: "Some work has no one assigned.",
  work_reassigned: "Some work was reassigned.",
  shift_handover: "Work was handed over to you.",
  approval_requested: "Someone asked for your approval.",
  approval_waiting: "An approval is still waiting for you.",
  time_off_request: "A team member asked for time off.",
  time_off_decision: "Your time off request has an answer.",
  staff_joined: "A new team member joined.",
  staff_unavailable: "Someone on your team is away.",
  team_scorecard: "Some work from last week is still open.",
  // summaries
  daily_summary: "Your daily summary is ready.",
  weekly_review: "Your weekly review is ready.",
  team_summary: "Your team summary is ready.",
  knowledge_report: "Your knowledge report is ready.",
  spam_weekly_report: "Your weekly spam protection report is ready.",
  // plan and money: always plain
  business_welcome: "Welcome to Zella Voice.",
  setup_incomplete: "A few setup steps are left before you go live.",
  setup_reminder: "Setup isn't finished yet. A few steps are left.",
  trial_ending: "Your trial ends soon.",
  trial_ended: "Your trial has ended.",
  payment_failed: "Your payment didn't go through.",
  payment_overdue: "A payment is overdue.",
  payment_received: "Payment received.",
  renewal_upcoming: "Your plan renews soon. You don't need to do anything unless you want to change it.",
  account_cancelled: "Your Zella Voice plan was canceled.",
  account_reactivated: "Your workspace is active again.",
  account_suspended: "Your workspace is paused.",
  subscription_cancelled: "Your plan was canceled.",
  cancellation_coming: "Your plan ends soon.",
  // service
  incident_open: "We're working on a problem with Zella Voice.",
  incident_resolved: "A problem with Zella Voice was fixed.",
  // connections and delivery
  integration_down: "One of your connections stopped working.",
  integration_reconnect: "A connection needs to be reconnected.",
  integration_reminder: "One of your connections isn't set up yet.",
  reconnect_reminder: "A connection still needs to be reconnected.",
  calendar_disconnected: "Your calendar was disconnected.",
  calendar_sync_owner: "Your calendar sync needs attention.",
  email_bounced: "An email couldn't be delivered.",
  email_complaint: "Someone marked an email as spam. We've stopped emailing them.",
  email_unsubscribed: "A customer unsubscribed from emails.",
  sms_not_delivered: "A text message wasn't delivered.",
  messages_failed: "Some messages weren't delivered.",
  reminder_failed: "A reminder wasn't sent.",
  meta_disconnected: "Facebook or Instagram was disconnected.",
  meta_lead_failed: "A lead from Facebook didn't come through.",
  meta_lead_incomplete: "A Facebook lead arrived with missing details.",
  meta_permissions_missing: "Facebook needs more permissions.",
  // trends
  kpi_message_failures: "More messages than usual weren't delivered.",
  kpi_missed_calls: "More calls than usual were missed.",
  kpi_no_shows: "No shows are higher than usual. Reminders may help.",
  // knowledge and the website
  knowledge_gap: "Callers asked something your AI receptionist couldn't answer.",
  knowledge_repeat: "The same question keeps coming up. You can add the answer to Knowledge.",
  knowledge_conflict: "Two answers in Knowledge disagree.",
  knowledge_failed: "A knowledge update didn't go through.",
  website_review: "New pages from your website are ready to review.",
  website_new_pages: "New pages were found on your website.",
  website_page_broken: "A page on your website isn't loading.",
  website_page_removed: "A page was removed from your website.",
  // privacy, records, spam and reviews
  data_rights_request: "A customer made a privacy request.",
  data_rights_due: "A privacy request is due soon.",
  duplicate: "Two records may be the same person.",
  duplicate_scan: "Some records may be the same person.",
  spam_high_risk: "Zella Voice blocked something suspicious.",
  spam_unreviewed: "Some suspicious contacts are waiting for review.",
  low_review: (n) => sentence(n.title),
  review_reply_failed: "A review reply couldn't be posted.",
  reviews_disconnected: "Google reviews stopped syncing.",
  // celebrations: the facts are in the title
  milestone: (n) => sentence(n.title),
  five_star_review: (n) => sentence(n.title),
  best_week: "Your best week in three months",
  best_day: "A record day for bookings",
  call_surge: "More calls than usual today",
};

const ownWords = (workspace) => {
  const t = workspace?.terminology ?? {};
  const w = (k) => (typeof t[k] === "string" && t[k].trim() ? t[k].trim().toLowerCase() : "");
  return { customer: w("customer"), customers: w("customers"), appointment: w("appointment") };
};

// Notification shown in the bell, pop ups and desktop alerts: one plain line per kind, in the business's own words.
export function voiceTitle(n, workspace) {
  // titles written by the server may say "5-star" or "24-hour"; the bell says "5 star" (names keep their hyphens)
  if (typeof n?.title === "string") n = { ...n, title: n.title.replace(/(\d)-(?=[A-Za-z])/g, "$1 ") };
  const term = workspace?.terminology ? (k) => workspace.terminology[k] || k : null;
  if (n.severity === "urgent") return localize(n.title, term);   // urgent stays the server's own words
  const ind = key(workspace?.industry);
  const entry = BY_INDUSTRY[ind]?.[n.kind] ?? industryVoice(ind, ownWords(workspace))?.[n.kind] ?? TITLES[n.kind];
  if (!entry) return localize(n.title, term);
  return localize(typeof entry === "function" ? entry(n) : entry, term);
}

// Confirmations ("Details saved.") are shown as the code wrote them, in the business's own words. There are no
// variants: one state, one wording (BRD-4).
export function plainNotice(message, workspace) {
  if (typeof message !== "string" || !message) return message;
  const term = workspace?.terminology ? (k) => workspace.terminology[k] || k : null;
  return localize(message, term);
}

// The bell when nothing needs a person.
export const ALL_QUIET = "Nothing needs you right now.";

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
  best_day: "emoji_events", call_surge: "trending_up", on_call_gap: "event_busy",
  data_rights_request: "privacy_tip", data_rights_due: "privacy_tip", duplicate: "content_copy", duplicate_scan: "content_copy", industry_alert: "campaign",
};
export const CELEBRATE = new Set(["milestone", "five_star_review", "best_week", "best_day", "went_live", "payment_received"]);
// Five tones: good (celebrations, money in), brand (new business: leads, bookings), info (updates), heads (needs a look
// soon) and urgent (needs a person now). The kicker is the short label above the title.
const KICKERS = [
  [/^(best_day|best_week)$/, "Record"], [/^(milestone|five_star_review)$/, "Celebration"], [/^went_live$/, "You're live"],
  [/^call_surge$/, "Still answering"], [/^on_call/, "On call"], [/^(payment|renewal|trial|subscription|account|cancellation|usage_threshold)/, "Your plan"],
  [/lead/, "New lead"], [/^(appointment|customer_arrived|social_booking)/, "Calendar"], [/^callback/, "Callback"],
  [/^(daily_summary|weekly_review|team_summary|team_scorecard|knowledge_report|spam_weekly_report)$/, "Summary"],
  [/^(customer_|social_)/, "Message"], [/^(knowledge|wrong_answer|spot_check)/, "Knowledge"],
  [/^(integration|calendar_|meta_|reviews_disconnected|reconnect)/, "Connection"], [/review/, "Reviews"], [/^spam/, "Spam protection"],
  [/^(task|unassigned|work_|shift|approval|draft|staff_|time_off)/, "Your team"],
];
const BRAND = /lead|^appointment_request$|^social_booking$|^customer_arrived$|^staff_joined$/;
export function noteStyle(n) {
  const kind = n?.kind ?? "";
  const icon = ICONS[kind] ?? "notifications";
  const tone = n?.severity === "urgent" ? "urgent" : n?.severity === "warning" ? "heads" : CELEBRATE.has(kind) ? "good" : BRAND.test(kind) ? "brand" : "info";
  const found = KICKERS.find(([re]) => re.test(kind));
  const kicker = tone === "urgent" ? "Urgent" : tone === "heads" && !found ? "Heads up" : found?.[1] ?? "Update";
  return { icon, tone, kicker };
}
// The older four tones, still used for the chime
export function noteIcon(n) {
  const { icon, tone } = noteStyle(n);
  return { icon, tone: { good: "celebrate", heads: "warning", brand: "info" }[tone] ?? tone };
}
