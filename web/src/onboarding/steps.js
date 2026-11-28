// The owner onboarding journey: which screens there are, where an owner resumes, how far along they are, and how the
// server's answers map to what each screen shows. Pure functions only (no React, no network), so the rules are unit
// tested in web/tests/ownerOnboarding.test.mjs. The server decides every rule (docs/OWNER_ONBOARDING_CONTRACT.md);
// these only read what it says.

// The seven steps, in the server's order (contract §2). Each is one screen.
export const SCREENS = [
  { key: "welcome", label: "Welcome" },
  { key: "security", label: "Password and two step sign in" },
  { key: "details", label: "Check your details" },
  { key: "identity", label: "Verify your identity" },
  { key: "plan", label: "Your plan" },
  { key: "payment", label: "Pay" },
  { key: "done", label: "You're all set" },
];
export const STEP_KEYS = SCREENS.map((s) => s.key);
const isStep = (k) => STEP_KEYS.includes(k);

// Where the owner picks up: the server's current step (the first one not done). Progress is saved after every step,
// so this is also where Finish later comes back to.
export function resumeStep(state) {
  if (state?.completed_at) return "done";
  const step = isStep(state?.current_step) ? state.current_step : "welcome";
  // a new plan version saved after the owner accepted (contract version 3): back to the plan, which must be accepted again
  if (["payment", "done"].includes(step) && state?.plan?.available === true && state.plan.accepted === false) return "plan";
  return step;
}

// Which steps the owner may open: those the server marks done, and the current one. Later ones are locked.
export function canOpen(state, step) {
  const s = Array.isArray(state?.steps) ? state.steps.find((x) => x.key === step) : null;
  if (s) return s.state === "done" || s.state === "current";
  return step === resumeStep(state);
}

// The progress bar: step n of 7, from the step on screen.
export function progressFor(step) {
  const i = Math.max(0, STEP_KEYS.indexOf(step));
  return {
    screen: i + 1,
    total: SCREENS.length,
    label: SCREENS[i].label,
    percent: Math.round((i / (SCREENS.length - 1)) * 100),
    text: `Step ${i + 1} of ${SCREENS.length}`,
  };
}
export function nextStep(step) {
  const i = STEP_KEYS.indexOf(step);
  return i < 0 || i === STEP_KEYS.length - 1 ? "done" : STEP_KEYS[i + 1];
}
export function previousStep(step) {
  const i = STEP_KEYS.indexOf(step);
  return i <= 0 ? null : STEP_KEYS[i - 1];
}

// Screen 2 has three parts, from state.security: a password, an authenticator, then a code verified session.
// The state to show after "Carry on now" (after Finish later): the resume answer, else the state read again, else null
// (the caller keeps the paused screen and says so). Never the stale screen state, so a step finished just before
// leaving (a saved password whose refresh failed) isn't asked for again. The api is passed in; nothing here throws.
export async function stateAfterResume(api, businessId) {
  const resumed = await api.resume(businessId).catch(() => null);
  if (resumed?.state) return resumed.state;
  return (await api.getState(businessId).catch(() => null)) ?? null;
}

export function securityPart(security) {
  if (!security?.password_set) return "password";
  if (!security?.authenticator) return "authenticator";
  if (!security?.session_verified) return "code";
  return "ready";
}

// Check your details (contract §2): only "looks_right" counts toward finishing the step.
export const DETAIL_SECTIONS = [
  { key: "business", title: "Your business" },
  { key: "hours_services", title: "Hours and services" },
  { key: "team", title: "Your team" },
  { key: "receptionist_phone", title: "AI receptionist and phone" },
];
export const sectionTitle = (key) => DETAIL_SECTIONS.find((s) => s.key === key)?.title ?? "Details";
export function sectionState(section) {
  const s = String(section?.status ?? "");
  if (s === "looks_right") return { key: "looks_right", label: "Looks right", tone: "good", done: true, open: false };
  if (s === "change_requested") return { key: "change_requested", label: "Waiting for Zella Voice", tone: "info", done: false, open: false };
  if (s === "updated") return { key: "updated", label: "Changed, check again", tone: "heads", done: false, open: true };
  return { key: "to_review", label: "To check", tone: "heads", done: false, open: true };
}
// The next section that needs the owner's answer, or null.
export function nextOpenSection(sections, after = null) {
  const list = Array.isArray(sections) ? sections : [];
  const from = after ? list.findIndex((s) => s.key === after) + 1 : 0;
  return [...list.slice(from), ...list.slice(0, from)].find((s) => sectionState(s).open)?.key ?? null;
}
export const detailsDone = (details) => Array.isArray(details?.sections) && details.sections.length > 0
  && details.sections.every((s) => sectionState(s).done);

// Verify your identity (contract §5.2 notes): the owner sees Documents needed, Checking, Verified, Try again or In review,
// exactly as the server says. Anything unknown reads as Checking, never as Verified.
export function identityState(identity) {
  const s = String(identity?.status ?? "");
  if (s === "verified") return { key: "verified", label: "Verified", tone: "good" };
  if (s === "try_again") return { key: "try_again", label: "Try again", tone: "urgent" };
  if (s === "in_review") return { key: "in_review", label: "In review", tone: "info" };
  if (s === "needed") return { key: "needed", label: "Documents needed", tone: "heads" };
  return { key: "checking", label: "Checking", tone: "info" };
}
export const identityPassed = (identity) => identityState(identity).key === "verified";
// The kinds the owner may upload right now (only while the server allows it).
export const uploadKinds = (identity) => (identity?.can_upload === true && Array.isArray(identity.upload_kinds) ? identity.upload_kinds : []);

// Pay (contract §5.2 notes): "Payment received" only when the server says confirmed.
export function paymentState(payment) {
  const s = String(payment?.status ?? "");
  if (s === "confirmed") return { key: "confirmed", label: "Payment received", tone: "good" };
  if (s === "locked") return { key: "locked", label: "Payment opens after verification", tone: "info" };
  if (s === "waiting" && payment?.reason === "processing") return { key: "processing", label: "Confirming your payment", tone: "info" };
  if (s === "waiting" && payment?.checkout_available === true) return { key: "ready", label: "Ready to pay", tone: "info" };
  return { key: "waiting", label: "Payment opens here soon", tone: "info" };
}
// Owner decision (16 Nov 2026): until payments are live the first payment isn't required (required false); the step
// still shows "Payment opens here soon" and the owner may continue. Never shown as "Payment received".
export const paymentPassed = (payment) => paymentState(payment).key === "confirmed" || (payment?.required === false && paymentState(payment).key === "waiting");

// Whether the owner may press Continue on a step, from the server's state. The server checks again.
export function canLeave(step, state = {}) {
  if (step === "security") return securityPart(state.security) === "ready";
  if (step === "details") return detailsDone(state.details);
  if (step === "identity") return identityPassed(state.identity);
  if (step === "plan") return state.plan?.available === true;
  if (step === "payment") return paymentPassed(state.payment);
  return true;
}

// A server call that isn't deployed yet (the database function or the edge function is missing) reads as "This step
// isn't ready yet", never as a crash or as an empty success.
export function isNotReady(error) {
  if (!error) return false;
  if (error.notReady === true || error.code === "NOT_READY" || error.code === "PGRST202") return true;
  if (error.status === 404 && !error.code) return true;
  const text = `${error.message ?? error}`;
  return /could not find the function|schema cache|requested function was not found|function not found/i.test(text);
}

// The server's error codes (contract §4), in words. The raw code is never shown.
export const ERROR_WORDS = {
  NOT_SIGNED_IN: "Please sign in again.",
  NOT_ALLOWED: "Only the business owner can do this.",
  NOT_FOUND: "We couldn't find that business.",
  MFA_REQUIRED: "Enter the code from your authenticator app to continue.",
  BUSINESS_NOT_AVAILABLE: "This workspace is paused. Contact Zella Voice support.",
  INVALID_INPUT: "That didn't work. Reload the page and try again.",
  STEP_LOCKED: "Finish the earlier steps first.",
  STEP_CLOSED: "These details are already confirmed. You can change them in Settings.",
  NOTE_REQUIRED: "Tell us what should change.",
  SECURITY_INCOMPLETE: "Set a password and add an authenticator app first.",
  SECTIONS_NOT_CONFIRMED: "Check every section first.",
  IDENTITY_NOT_VERIFIED: "We're still checking your identity.",
  UPLOAD_NOT_ALLOWED: "We already have your documents.",
  PLAN_MISSING: "Your plan isn't ready yet. Zella Voice will be in touch.",
  PLAN_CHANGED: "Your plan was just updated. Please review it again.",
  DETAILS_CHANGED: "These details were just updated. Please check them again.",
  PAYMENT_NOT_CONFIRMED: "We haven't received a payment yet.",
  PAYMENTS_NOT_LIVE: "Payments aren't switched on yet. Nothing has been charged.",
  ALREADY_PAID: "Your payment is already confirmed.",
  CHECKOUT_NOT_READY: "We couldn't open the payment page. Please try again in a minute.",
  rate_limited: "Too many attempts. Wait a minute and try again.",
  SERVER_ERROR: "Something went wrong on our side. Please try again.",
};
// The code a server error carries: a database function raises it as the message, the edge function sends it as code.
export function errorCode(error) {
  if (!error) return null;
  if (typeof error.code === "string" && ERROR_WORDS[error.code]) return error.code;
  const m = String(error.message ?? "").trim();
  return ERROR_WORDS[m] ? m : null;
}
// What the journey does after finishing a step failed: "plan" (a new plan version was saved while a later step was open:
// read the state and show the plan), "reload" (the server is further along, or an earlier step reopened), or nothing.
export function afterCompleteError(step, error) {
  const code = errorCode(error);
  if (code === "PLAN_CHANGED" && (step === "payment" || step === "done")) return "plan";
  if (["STEP_LOCKED", "SECURITY_INCOMPLETE", "SECTIONS_NOT_CONFIRMED"].includes(code)) return "reload";
  return null;
}

// The screen to show once the state is read again after such an error: the plan, or where the server says the owner is.
export function stepAfterError(next, fresh) {
  return next === "plan" ? "plan" : resumeStep(fresh);
}

// When finishing a step moved the owner to another step (the server is elsewhere), the reason in words, kept by the
// journey and shown on the step it moved to; empty when the owner stays put or the plan screen explains it itself.
export function movedNotice(next, from, to, error) {
  if (next !== "reload" || !to || to === from) return "";
  return errorWords(error) ?? "";
}

// Answers on the details step can overlap (the owner moves between parts). Only the latest call's state may be shown:
// an answer whose reply comes back after a newer call is dropped and the state read again, and a read again is itself
// dropped when a newer answer or read started meanwhile, so an older snapshot never hides a newer answer.
//   answer(send): runs send() and returns its reply if it is still the latest call, else null (and reads again)
//   reread(): reads the state and applies it if it is still the latest call; a failed read goes to onReadError
export function createAnswerQueue({ read, apply, onReadError = () => {} }) {
  let latest = 0;
  async function reread() {
    const ticket = ++latest;
    try {
      const fresh = await read();
      if (ticket !== latest) return;
      if (!fresh || typeof fresh !== "object") throw new Error("Your setup didn't load.");   // a missing state is a failed read
      apply(fresh);
    } catch (err) { if (ticket === latest) onReadError(err); }
  }
  async function answer(send) {
    const ticket = ++latest;
    const res = await send();
    if (ticket === latest) return res;
    reread();
    return null;
  }
  return { answer, reread };
}

// A database call's error as the screens get it (contract §4): the code from the message (P0001 or the request check),
// an expired session as NOT_SIGNED_IN, and for anything else safe words only, never the database's own text (which can
// name tables or functions). The original text is kept in rawMessage for logs. "Not deployed yet" (PGRST202) and
// network failures keep their text, so isNotReady and errorWords can still tell them apart.
const SESSION_ENDED = new Set(["PGRST301", "PGRST303"]);
export function rpcError(error) {
  const raw = String(error?.message ?? "");
  const fromMessage = /^[A-Z_]{3,40}$/.test(raw) ? raw : null;
  const code = fromMessage ?? (SESSION_ENDED.has(error?.code) ? "NOT_SIGNED_IN" : error?.code);
  const keep = fromMessage || code === "PGRST202" || /fetch|network|failed to load|load failed/i.test(raw);
  const message = code === "NOT_SIGNED_IN" && !fromMessage ? "NOT_SIGNED_IN" : keep ? raw : "Something went wrong. Please try again.";
  return Object.assign(new Error(message), { code, details: error?.details ?? null, status: error?.status, rawMessage: raw });
}

export function errorWords(error) {
  const code = errorCode(error);
  if (code === "NOTE_REQUIRED" && /too_long/.test(String(error?.details ?? ""))) return "Keep the note under 1000 characters.";
  // the upload function says exactly what was wrong with a file, in plain words (contract §5.8)
  if (code === "INVALID_INPUT" && typeof error?.words === "string" && error.words && !/[\u2014\u2013]|[A-Za-z]-[A-Za-z]/.test(error.words)) return error.words;
  if (code) return ERROR_WORDS[code];
  if (isNotReady(error)) return "This step isn't ready yet. Choose Finish later and come back soon.";
  const m = String(error?.message ?? error ?? "");
  if (/fetch|network|failed to load|load failed/i.test(m)) return "We couldn't reach Zella Voice. Check your connection and try again.";
  if (!m || /^[A-Z_]+$|^\s*\{|\bat \w+ \(|TypeError|ReferenceError|P0001|PGRST/.test(m)) return "Something went wrong. Please try again.";
  return m;
}

// Words for the details the Zella Voice team entered (contract §5.2, details.sections[].data).
const DAY = { 0: "Sunday", 1: "Monday", 2: "Tuesday", 3: "Wednesday", 4: "Thursday", 5: "Friday", 6: "Saturday", 7: "Sunday" };
const LANG = { en: "English", "en-US": "English", es: "Spanish", "es-US": "Spanish" };
const set = (v) => v !== null && v !== undefined && String(v).trim() !== "";
export function phoneWords(v) {
  const s = String(v ?? "");
  if (/^\+1\d{10}$/.test(s)) return `(${s.slice(2, 5)}) ${s.slice(5, 8)} ${s.slice(8)}`;
  return set(s) ? s.replace(/-/g, " ") : "Not set";
}
export const languageWords = (v) => (Array.isArray(v) ? v : set(v) ? [v] : []).map((l) => LANG[l] ?? l).filter((l, i, a) => a.indexOf(l) === i).join(" and ") || "Not set";
const text = (v) => (set(v) ? String(v) : "Not set");
const time = (t) => (set(t) ? String(t).slice(0, 5) : "");
// A list from the server: its rows, the empty words only for an explicit empty list, and never "none" when it's missing.
export const UNAVAILABLE = "Not available right now";
const listRows = (v, empty, row) => (Array.isArray(v) ? (v.length ? v.map(row) : empty) : UNAVAILABLE);

export function sectionRows(key, data) {
  const d = data ?? {};
  if (key === "business") {
    const a = d.address ?? {};
    const address = typeof d.address === "string" ? d.address
      : [a.line_1, a.line_2, a.city, [a.state, a.postal_code].filter(set).join(" "), a.country].filter(set).join(", ");
    return [
      ["Business name", text(d.name)], ["Legal name", text(d.legal_name)], ["Industry", text(d.industry)],
      ["Phone", phoneWords(d.phone)], ["Email", text(d.email)], ["Website", text(d.website)],
      ["Address", text(address)], ["Time zone", set(d.timezone) ? String(d.timezone).replace(/_/g, " ") : "Not set"],
      ["About the business", text(d.description)],
    ];
  }
  if (key === "hours_services") {
    // business_hours.weekday is 0 = Sunday to 6 = Saturday, as in the CRM (BusinessHours.jsx); shown Monday first
    const hours = (Array.isArray(d.hours) ? d.hours : []).slice().sort((x, y) => ((x.weekday + 6) % 7) - ((y.weekday + 6) % 7));
    return [
      ["Opening hours", hours.length ? hours.map((h) => `${DAY[h.weekday] ?? "Day"}: ${time(h.opens)} to ${time(h.closes)}`) : "Not set"],
      ["Services", listRows(d.services, "No services yet", (s) => [s.name, s.duration, s.price].filter(set).join(", "))],
      ["Takes bookings", d.takes_bookings === true ? "Yes" : d.takes_bookings === false ? "No" : "Not set"],
    ];
  }
  if (key === "team") {
    return [["Team members", listRows(d.members, "No team members yet", (m) => [m.name, m.title, m.email, set(m.phone) ? phoneWords(m.phone) : null].filter(set).join(", "))]];
  }
  if (key === "receptionist_phone") {
    const t = d.transfer_to ?? {};
    const transfer = t.type === "owner" ? "You, the owner" : [t.name, set(t.phone) ? phoneWords(t.phone) : null].filter(set).join(", ") || "Not set";
    const setup = d.phone_setup ?? {};
    const mode = setup.mode === "call_forwarding" ? `Calls forwarded from ${phoneWords(setup.forward_from)}` : setup.mode === "new_number" ? "A new Zella Voice number" : text(setup.mode && String(setup.mode).replace(/_/g, " "));
    return [
      ["AI receptionist name", text(d.name)], ["Greeting", text(d.greeting)], ["Language", languageWords(d.language)],
      ["Calls are transferred to", transfer], ["Fallback number", phoneWords(d.fallback_number)],
      ["Phone setup", mode], ["Zella Voice numbers", listRows(d.numbers, "No numbers yet", (n) => `${phoneWords(n.e164)}${n.status === "active" ? "" : " (not active yet)"}`)],
    ];
  }
  return [];
}

// Money (integer cents) and allowances, written the way owners read them.
export function money(cents, currency = "USD") {
  if (cents === null || cents === undefined || cents === "" || !Number.isFinite(Number(cents))) return "Not set";
  const v = Number(cents) / 100;
  return v.toLocaleString("en-US", { style: "currency", currency: currency || "USD", minimumFractionDigits: v % 1 ? 2 : 0 });
}
export function allowance(n, one, many = `${one}s`) {
  if (n === null || n === undefined || n === "" || !Number.isFinite(Number(n))) return "Not set";
  return `${Number(n).toLocaleString("en-US")} ${Number(n) === 1 ? one : many}`;
}
export const billingPeriod = (interval) => (interval === "yearly" || interval === "year" ? "a year" : "a month");
export const tierName = (tier) => (tier === "pro" ? "Pro" : tier === "base" ? "Base" : set(tier) ? String(tier) : "Your plan");
