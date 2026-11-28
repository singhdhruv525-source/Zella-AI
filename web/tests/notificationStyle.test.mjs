// Notification style and wording (src/zellaVoice.js): five tones with a kicker, the new business moments in each
// industry's own words, and the writing rules (no emoji, no dashes).
//   cd web && node --test tests/notificationStyle.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { ALL_QUIET, SERIOUS, noteIcon, noteStyle, pickQuiet, plural, voiceTitle, warm } from "../src/zellaVoice.js";

test("tones and kickers", () => {
  assert.deepEqual(noteStyle({ kind: "best_day", severity: "info" }), { icon: "emoji_events", tone: "good", kicker: "Record" });
  assert.deepEqual(noteStyle({ kind: "call_surge", severity: "info" }), { icon: "trending_up", tone: "info", kicker: "Still answering" });
  assert.deepEqual(noteStyle({ kind: "on_call_gap", severity: "warning" }), { icon: "event_busy", tone: "heads", kicker: "On call" });
  assert.equal(noteStyle({ kind: "new_lead", severity: "info" }).tone, "brand");
  assert.equal(noteStyle({ kind: "emergency_call", severity: "urgent" }).kicker, "Urgent");
  assert.equal(noteStyle({ kind: "something_new", severity: "warning" }).kicker, "Heads up");
  assert.deepEqual(noteStyle({ kind: "something_new" }), { icon: "notifications", tone: "info", kicker: "Update" });
  // the chime keeps its four tones
  assert.equal(noteIcon({ kind: "best_day" }).tone, "celebrate");
  assert.equal(noteIcon({ kind: "on_call_gap", severity: "warning" }).tone, "warning");
});

test("plural", () => {
  assert.equal(plural("class"), "classes");
  assert.equal(plural("stay"), "stays");
  assert.equal(plural("service call"), "service calls");
  assert.equal(plural("chair"), "chairs");
  assert.equal(plural("family"), "families");
  assert.equal(plural("day"), "days");
});

const note = (kind, extra = {}) => ({ id: `n-${kind}`, kind, severity: "info", title: "Original title", ...extra });
test("new moments speak each industry's language", () => {
  const salon = voiceTitle(note("best_day"), { industry: "Beauty & Salon" });
  assert.ok(["A record day for your chairs", "Your busiest day for chairs in three months"].includes(salon), salon);
  const gym = voiceTitle(note("best_day"), { industry: "Fitness" });
  assert.match(gym, /classes/);
  const dental = voiceTitle(note("call_surge"), { industry: "Dental" });
  assert.match(dental, /patients/i);
  const plain = voiceTitle(note("best_day"), { industry: "Other" });
  assert.ok(["A record day for bookings", "Your busiest booking day in three months"].includes(plain), plain);
  // the business's own words win over the industry's
  const own = voiceTitle(note("best_day"), { industry: "Fitness", terminology: { appointment: "Session", appointments: "Sessions" } });
  assert.match(own, /sessions/);
  assert.doesNotMatch(own, /classes/);
  const cancelled = voiceTitle(note("appointment_cancelled"), { industry: "Fitness", terminology: { appointment: "Session" } });
  assert.match(cancelled, /session/i);
  const clients = voiceTitle(note("call_surge"), { industry: "Dental", terminology: { customer: "Client", customers: "Clients" } });
  assert.match(clients, /clients/i);
  // a singular only term that matches the industry's keeps the industry's plural
  const families = voiceTitle(note("call_surge"), { industry: "Childcare", terminology: { customer: "Family" } });
  assert.match(families, /families/i);
  assert.doesNotMatch(families, /familys/i);
  // the server writes "5-star review from Alex"; the bell never shows the hyphen
  for (let i = 0; i < 6; i++) assert.doesNotMatch(voiceTitle(note("five_star_review", { id: `r${i}`, title: "5-star review from Alex" }), { industry: "Other" }), /-/);
  // an on call gap keeps its own title: full and partial gaps say different things
  assert.equal(voiceTitle(note("on_call_gap", { title: "No one is on call this weekend", severity: "warning" }), { industry: "Plumbing" }), "No one is on call this weekend");
});

test("no emoji and no dashes in any wording", () => {
  const kinds = ["milestone", "five_star_review", "best_week", "best_day", "call_surge", "new_lead", "callback", "customer_reply", "went_live", "payment_received", "duplicate", "agent_config_published"];
  const industries = ["Other", "Restaurant", "Dental", "Fitness", "Hospitality", "Plumbing", "Real Estate", "Pet Care & Veterinary"];
  for (const kind of kinds) for (const industry of industries) for (let i = 0; i < 6; i++) {
    const t = voiceTitle(note(kind, { id: `${kind}-${i}`, title: "5-star review from Alex" }), { industry });
    assert.doesNotMatch(t, /\p{Extended_Pictographic}/u, `${kind} ${industry}: ${t}`);
    assert.doesNotMatch(t, /[–—]|[A-Za-z0-9]-[A-Za-z]/, `${kind} ${industry}: ${t}`);
  }
});

// The playful voice is back for the CRM (owner, 28 Nov 2026), but money, service problems, errors, urgent or safety
// alerts and security stay plain and serious: one wording, no joke variant, no exclamation mark.
const SERIOUS_KINDS = ["payment_failed", "payment_overdue", "payment_received", "renewal_upcoming", "trial_ending", "trial_ended",
  "account_cancelled", "account_reactivated", "account_suspended", "subscription_cancelled", "cancellation_coming", "usage_threshold",
  "incident_open", "incident_resolved", "agent_failures", "agent_sync_failed", "transfer_failures", "transfer_fallback_applied",
  "integration_down", "integration_reconnect", "calendar_disconnected", "calendar_sync_owner", "meta_disconnected", "reviews_disconnected",
  "website_page_broken", "email_bounced", "sms_not_delivered", "messages_failed", "reminder_failed", "knowledge_failed",
  "review_reply_failed", "meta_lead_failed", "meta_lead_incomplete", "kpi_message_failures", "kpi_missed_calls",
  "emergency_call", "escalation_unacknowledged", "data_rights_request", "data_rights_due",
  "spam_high_risk", "spam_unreviewed", "email_complaint", "meta_permissions_missing"];
const JOKES = /!|let's sort|easy to fix|bump|we're on it|a quick look will sort|thumbs up|over to you|nicely|looking good|nice one|lovely|breather|you've got this|make their day/i;

test("money, service, error, urgent and security kinds are plain: one wording, no joke, no exclamation mark", () => {
  for (const kind of SERIOUS_KINDS) assert.ok(kind in SERIOUS, `${kind} is listed as serious`);
  const industries = ["Other", "Restaurant", "Dental", "Fitness", "Hospitality", "Travel"];
  for (const kind of SERIOUS_KINDS) for (const industry of industries) {
    const seen = new Set();
    for (let i = 0; i < 8; i++) seen.add(voiceTitle(note(kind, { id: `${kind}-${i}`, severity: i % 2 ? "warning" : "info", title: "Minutes are 80% used" }), { industry }));
    assert.equal(seen.size, 1, `${kind} ${industry}: ${[...seen].join(" | ")}`);
    const [t] = seen;
    assert.doesNotMatch(t, JOKES, `${kind} ${industry}: ${t}`);
  }
  assert.equal(voiceTitle(note("payment_failed"), { industry: "Other" }), "Your payment didn't go through.");
  assert.equal(voiceTitle(note("incident_open"), { industry: "Restaurant" }), "We're working on a problem with Zella Voice.");
  // usage notices keep the server's facts
  assert.equal(voiceTitle(note("usage_threshold", { title: "Minutes are 80% used" }), { industry: "Other" }), "Minutes are 80% used");
});

test("an urgent notification shows the server's own title, whatever its kind", () => {
  for (const kind of ["call_insight", "new_lead", "industry_alert", "payment_failed", "emergency_call", "customer_arrived"]) {
    for (let i = 0; i < 4; i++) {
      const t = voiceTitle(note(kind, { id: `${kind}-${i}`, title: "A call sounded like an emergency", severity: "urgent" }), { industry: "Restaurant" });
      assert.equal(t, "A call sounded like an emergency", kind);
    }
  }
});

test("playful kinds keep their variants, with the kept fixes: AI receptionist, US spelling, sentence case", () => {
  const variants = new Set();
  for (let i = 0; i < 40; i++) variants.add(voiceTitle(note("new_lead", { id: `l${i}`, title: "New lead" }), { industry: "Other" }));
  assert.ok(variants.size > 1, "new leads have more than one wording");
  assert.ok([...variants].some((t) => /!/.test(t)), "and some are playful");
  const kinds = ["new_lead", "website_lead", "social_lead", "callback", "appointment_cancelled", "customer_arrived", "agent_config_published",
    "went_live", "kpi_no_shows", "on_call_starting", "knowledge_gap", "website_page_removed", "call_insight", "lead_escalated"];
  for (const kind of kinds) for (const industry of ["Other", "Travel", "Restaurant", "Dental"]) for (let i = 0; i < 8; i++) {
    const t = voiceTitle(note(kind, { id: `${kind}-${i}`, title: "You're on call tonight" }), { industry });
    assert.doesNotMatch(t, /\bShe\b|enquir|traveller|\byour AI\b(?! receptionist)|listening|taught us|Zella Voice is (picking|answering|on the line)/i, `${kind} ${industry}: ${t}`);
    assert.match(t, /^[A-Z0-9]/, `${kind} ${industry}: ${t}`);
  }
  assert.match(voiceTitle(note("callback", { id: "c1" }), { industry: "Travel" }), /traveler/);
});

test("warm() keeps its playful toasts, and never rewrites money, service, error or security messages", () => {
  assert.ok(["Saved. Looking good.", "All saved. Nicely done."].includes(warm("Details saved.")));
  assert.equal(warm("Booking confirmed."), "Confirmed! It's in the calendar.");
  assert.equal(warm("You're live. Calls are answered."), "You're live! Your AI receptionist is picking up the phone.");
  assert.equal(warm("Saved to the customer.", { terminology: { customer: "Guest" } }), "Saved to the Guest. Thanks for checking!".replace("Guest", "guest"));
  for (const m of ["Auto reload is on.", "Your card is saved.", "Payment method options saved.", "Two step sign in is on.",
    "Payment moved to Friday.", "Added. Your plan now includes 2 numbers.", "Submitted. A refund request is on its way.",
    "Plan is saved.", "Spam protection is off.", "Password is saved.", "Recording is off. Callers aren't told about recording."]) {
    assert.equal(warm(m), m, m);
  }
  // the business's own words still apply
  assert.equal(warm("Your card is saved for this customer.", { terminology: { customer: "Client" } }), "Your card is saved for this client.");
});

test("the bell's quiet line is one of a few calm ones", () => {
  for (const line of ALL_QUIET) assert.doesNotMatch(line, /!/);
  assert.ok(ALL_QUIET.includes(pickQuiet()));
});
