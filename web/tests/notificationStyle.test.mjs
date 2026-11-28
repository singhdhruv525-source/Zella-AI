// Notification style and wording (src/zellaVoice.js): five tones with a kicker, the new business moments in each
// industry's own words, and the writing rules (no emoji, no dashes).
//   cd web && node --test tests/notificationStyle.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { ALL_QUIET, noteIcon, noteStyle, plainNotice, plural, voiceTitle } from "../src/zellaVoice.js";

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

test("plain and calm: one wording per kind, no exclamation marks, urgent keeps the server's words (owner, 27 Nov 2026)", () => {
  const kinds = ["new_lead", "website_lead", "callback", "callback_overdue", "appointment_cancelled", "customer_arrived", "customer_reply",
    "lead_escalated", "call_insight", "draft_ready", "shift_handover", "payment_failed", "payment_overdue", "payment_received",
    "incident_open", "account_suspended", "agent_config_published", "went_live", "kpi_no_shows", "on_call_starting", "weekly_review"];
  const industries = ["Other", "Restaurant", "Dental", "Travel", "Childcare"];
  for (const kind of kinds) for (const industry of industries) {
    const seen = new Set();
    for (let i = 0; i < 6; i++) seen.add(voiceTitle(note(kind, { id: `${kind}-${i}`, title: "Sam Lee has arrived" }), { industry }));
    assert.equal(seen.size, 1, `${kind} ${industry}: ${[...seen].join(" | ")}`);
    const [t] = seen;
    assert.doesNotMatch(t, /!/, `${kind} ${industry}: ${t}`);
    assert.doesNotMatch(t, /listening|taught us|\bShe\b|enquiry|traveller/i, `${kind} ${industry}: ${t}`);
    assert.match(t, /^[A-Z0-9]/, `${kind} ${industry}: ${t}`);
  }
  // a name in the server's title is kept
  assert.equal(voiceTitle(note("customer_arrived", { title: "Sam Lee has arrived" }), { industry: "Other" }), "Sam Lee has arrived.");
  // money messages say what happened
  assert.equal(voiceTitle(note("payment_failed"), { industry: "Other" }), "Your payment didn't go through.");
  // an urgent notification shows the server's own title
  assert.equal(voiceTitle(note("call_insight", { title: "A call sounded like an emergency", severity: "urgent" }), { industry: "Other" }), "A call sounded like an emergency");
  // US spelling for the travel industry's people
  assert.match(voiceTitle(note("callback"), { industry: "Travel" }), /^A traveler is waiting/);
});

test("confirmations are shown as written, in the business's own words", () => {
  const ws = { terminology: { customer: "Guest", appointment: "Reservation" } };
  assert.equal(plainNotice("Details saved.", ws), "Details saved.");
  assert.equal(plainNotice("Marked as contacted.", {}), "Marked as contacted.");
  assert.equal(plainNotice("Saved to the customer.", ws), "Saved to the guest.");
  assert.equal(plainNotice("Appointment moved to Friday.", ws), "Reservation moved to Friday.");
  assert.equal(ALL_QUIET, "Nothing needs you right now.");
});
