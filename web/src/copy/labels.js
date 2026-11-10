// The words people see for Zella's internal values: statuses, roles, channels, providers, kinds.
// Internal values (database enums, API fields) never change for the sake of wording; only their labels live here.
// Meanings: docs/ZELLA_STATUS_LANGUAGE_GUIDE.md. A value that isn't listed is still shown readably (humanize), so an
// unknown status never appears as raw code.
//
// These labels are context-free, so each must be true wherever the value appears. A label that depends on the
// screen (for example "Sending failed" for a reminder) is chosen by that screen.

const LABELS = {
  // shared states
  pending: "Pending", queued: "Queued", sending: "Sending", processing: "Processing", running: "Running",
  in_progress: "In progress", waiting: "Waiting", done: "Done", completed: "Completed", succeeded: "Succeeded",
  failed: "Failed", partial: "Partly done", skipped: "Skipped", cancelled: "Canceled", ignored: "Ignored",
  rejected: "Rejected", dismissed: "Dismissed", retried: "Retried", resolved: "Resolved", closed: "Closed",
  open: "Open", new: "New", active: "Active", inactive: "Inactive", paused: "Paused", disabled: "Turned off",
  archived: "Archived", expired: "Expired", draft: "Draft", published: "Published", superseded: "Replaced",
  valid: "Valid", invalid: "Invalid", ready: "Ready", error: "Error", live: "Live", none: "None",

  // messages (SMS and email): "sent" = handed to the provider; "delivered" = the provider confirmed delivery
  sent: "Sent", delivered: "Delivered", received: "Received", blocked: "Blocked",
  dry_run: "Not sent (test mode)", dry_run_no_provider: "Not sent (test mode: no provider connected)",

  // calls and transfers
  initiated: "Starting", ringing: "Ringing", answered: "Answered", missed: "Missed",
  not_needed: "Not needed", attempted: "Attempted", connected: "Connected", no_one_available: "No one available",
  inbound: "Incoming", outbound: "Outgoing",

  // appointments, callbacks, tasks
  scheduled: "Scheduled", confirmed: "Confirmed", no_show: "No-show", due: "Due", contacted: "Contacted",
  reschedule_requested: "Reschedule requested", retry_scheduled: "Retry scheduled",
  waiting_on_customer: "Waiting on customer", escalated: "Escalated", needs_review: "Needs review",
  booked: "Booked", offered: "Offered", removed: "Removed",

  // people, consent, access
  owner: "Owner", admin: "Admin", manager: "Manager", staff: "Staff", viewer: "View only",
  invited: "Invited", accepted: "Accepted", revoked: "Revoked", suspended: "Suspended",
  opted_in: "Opted in", opted_out: "Opted out",

  // billing
  trial: "Trial", renewal_due: "Renewal due", past_due: "Past due", grace_period: "Grace period",
  refunded: "Refunded", reversed: "Reversed", lapsed: "Lapsed", processed: "Processed",
  monthly: "Monthly", yearly: "Yearly", annual: "Annual",

  // reviews, approvals, documents
  pending_review: "Awaiting review", pending_approval: "Awaiting approval", verified: "Verified",
  replaced: "Replaced", approved: "Approved", declined: "Declined", in_review: "In review", retired: "Retired",
  drafted: "Draft ready", posting: "Posting", posted: "Posted", replied_elsewhere: "Replied elsewhere",
  waiting_verification: "Waiting for verification",

  // spam, duplicates, leads
  under_review: "Under review", confirmed_spam: "Confirmed spam", false_positive: "Not spam", spam: "Spam",
  duplicate: "Duplicate", rate_limited: "Too many attempts", merged: "Merged", kept_separate: "Kept separate",

  // integrations
  disconnected: "Disconnected", needs_reconnect: "Needs reconnecting", missing: "Missing", broken: "Broken",

  // channels
  sms: "Text message", email: "Email", call: "Call", voice: "Voice", web: "Web", chat: "Chat",

  // providers and products: their own names
  vapi: "Vapi", telnyx: "Telnyx", twilio: "Twilio", resend: "Resend", stripe: "Stripe", n8n: "n8n",
  google: "Google", google_calendar: "Google Calendar", meta: "Meta", facebook: "Facebook", instagram: "Instagram",
  whatsapp: "WhatsApp", "11labs": "ElevenLabs", elevenlabs: "ElevenLabs", deepgram: "Deepgram",
  anthropic: "Anthropic", openai: "OpenAI", supabase: "Supabase", microsoft: "Microsoft", outlook: "Outlook",

  // usage reconciliation
  ok: "OK", adjusted: "Adjusted", discrepancy: "Doesn't match", recorded: "Recorded",
};

// Short words kept in capitals inside a humanized phrase.
const ACRONYMS = { ai: "AI", sms: "SMS", crm: "CRM", id: "ID", url: "URL", api: "API", faq: "FAQ", mfa: "MFA", ip: "IP", csv: "CSV", vip: "VIP" };

// US spelling for words that come straight from internal values.
const US = [[/\bcancell(ed|ing)\b/gi, (m, end) => `${m[0]}ancel${end}`]];

// "no_answer" -> "No answer", "receptionist.voice_changed" -> "Receptionist voice changed", "ai_setup" -> "AI setup".
export function humanize(value) {
  if (value === null || value === undefined || value === "") return "";
  const raw = String(value);
  const known = LABELS[raw] ?? LABELS[raw.toLowerCase()];
  if (known) return known;
  if (/^dry_run/i.test(raw)) return LABELS.dry_run;
  let text = raw.replace(/[_.]+/g, " ").replace(/\s+/g, " ").trim();
  text = text.split(" ").map((w) => ACRONYMS[w.toLowerCase()] ?? w).join(" ");
  for (const [re, fix] of US) text = text.replace(re, fix);
  return text.replace(/^./, (c) => c.toUpperCase());
}

// What a call's result is called, from calls.status. Only "missed" counts as missed and only answered or completed
// calls count as answered; a call that failed to connect or is still ringing is never shown as answered.
export function callResult(status) {
  if (status === "missed") return { label: "Missed", tone: "danger" };
  if (status === "failed") return { label: "Didn't connect", tone: "danger" };
  if (status === "initiated" || status === "ringing") return { label: "In progress", tone: "info" };
  if (status === "answered" || status === "completed") return { label: "Answered", tone: "success" };
  return { label: status ? humanize(status) : "Unknown", tone: "" };
}
export const isAnswered = (status) => status === "answered" || status === "completed";
