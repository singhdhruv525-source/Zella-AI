// A stand in for the owner onboarding server (docs/OWNER_ONBOARDING_CONTRACT.md, version 2), for unit tests and the
// local browser journey ONLY. api.js loads it only when the app is built with VITE_ONBOARDING_FAKE=1, so a production
// build never contains it. It answers in the contract's shapes and follows its rules (steps in order, only Looks right
// finishes a section, uploads only while allowed, payment never confirmed by itself), so the screens are tested against
// the same answers the database gives. The business, people and numbers are invented (example.test, 555 numbers).
//
// Scenarios (?scenario=... in the local preview):
//   ""          a fresh invitation: nothing done yet
//   notready    none of the owner calls is deployed yet
//   partial     the database calls work, the upload function isn't deployed yet
//   flaky       the first load fails, a retry works
//   returning   password and authenticator done, left on Check your details (Finish later)
//   none        the signed in person owns no business waiting for setup
// Test hooks (fake only): approveIdentity(), rejectIdentity(note), adminChangeDone(section, note), confirmPayment().

const KEY = "zella.onboardingFake.v2";
const BUSINESS = "00000000-0000-4000-8000-0000000000b1";
const SECRET = "TESTSECRET123456";
const QR = `data:image/svg+xml;utf8,${encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 21 21"><rect width="21" height="21" fill="#fff"/><path d="M1 1h7v7H1zM13 1h7v7h-7zM1 13h7v7H1z" fill="none" stroke="#000"/><path d="M3 3h3v3H3zM15 3h3v3h-3zM3 15h3v3H3zM10 2h1v1h-1zM9 9h3v3H9zM14 14h2v2h-2zM17 17h2v2h-2zM12 16h1v3h-1z"/></svg>')}`;
const ORDER = ["welcome", "security", "details", "identity", "plan", "payment", "done"];
const REQUIRED = ["owner_identity", "business_registration"];

// errors in the shapes the real calls give
const dbError = (code, details = null) => Object.assign(new Error(code), { code, details });
const missing = () => Object.assign(new Error("Could not find the function public.zella_owner_onboarding_get in the schema cache"), { code: "PGRST202" });
const edgeMissing = () => Object.assign(new Error("Requested function was not found"), { status: 404 });
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const now = () => new Date().toISOString();

function initialState(scenario) {
  const returning = scenario === "returning";
  return {
    scenario,
    loads: 0,
    factors: returning ? [{ id: "fake-factor", friendly_name: "Authenticator", created_at: now() }] : [],
    password: returning,
    done: returning ? ["welcome", "security"] : [],
    paused_at: returning ? now() : null,
    started_at: now(),
    completed_at: null,
    sections: {
      business: { status: "to_review", note: null, admin_note: null, data: {
        name: "Maple Street Salon", legal_name: "Maple Street Salon LLC", industry: "Beauty and Salon", phone: "+15550102040",
        email: "hello@maplestreet.example.test", website: "https://maplestreet.example.test",
        address: { line_1: "12 Maple Street", line_2: null, city: "Springfield", state: "IL", postal_code: "62701", country: "US" },
        timezone: "America/Chicago", description: "Haircuts, colour and styling." } },
      hours_services: { status: "to_review", note: null, admin_note: null, data: {
        hours: [1, 2, 3, 4, 5].map((weekday) => ({ weekday, opens: "09:00", closes: "17:00" })).concat([{ weekday: 6, opens: "10:00", closes: "14:00" }]),
        services: [{ name: "Haircut", duration: "45 min", price: "$40" }, { name: "Colour", duration: "90 min", price: "$95" }],
        takes_bookings: true } },
      team: { status: "to_review", note: null, admin_note: null, data: { members: [
        { name: "Jordan Lee", title: "Stylist", email: "jordan@maplestreet.example.test", phone: null },
        { name: "Alex Kim", title: "Stylist", email: null, phone: "+15550104455" }] } },
      receptionist_phone: { status: "to_review", note: null, admin_note: null, data: {
        name: "Ava", greeting: "Thanks for calling Maple Street Salon, this is Ava. How can I help?", language: "en-US", voice_id: null,
        transfer_to: { type: "owner", name: "", phone: "" }, fallback_number: "+15550102040",
        phone_setup: { mode: "call_forwarding", forward_from: "+15550102040", area_code: "" },
        numbers: [{ e164: "+15550109999", status: "active" }] } },
    },
    identity: { status: "needed", attempts_used: 0, documents: [] },
    plan: { accepted_version: null, accepted_at: null },
    payment_confirmed: false,
  };
}

// The stand in's fingerprint of a section's details (the database uses md5 of the same data): any stable text will do.
const hashOf = (data) => { const t = JSON.stringify(data ?? null); let h = 0; for (let i = 0; i < t.length; i++) h = (h * 31 + t.charCodeAt(i)) | 0; return `h${h >>> 0}`; };

export function createFakeApi({ scenario = "", storage = null, delay = 120 } = {}) {
  let st;
  try { st = JSON.parse(storage?.getItem(KEY) ?? "null"); } catch { st = null; }
  if (!st || st.scenario !== scenario) st = initialState(scenario);
  const save = () => { try { storage?.setItem(KEY, JSON.stringify(st)); } catch { /* memory only */ } };
  const listeners = new Set();
  const session = { user: { id: "00000000-0000-4000-8000-000000000001", email: "owner@maplestreet.example.test" } };

  const currentStep = () => ORDER.find((k) => !st.done.includes(k)) ?? "done";
  const identityOut = () => {
    const can = ["needed", "try_again"].includes(st.identity.status);
    const have = new Set(st.identity.documents.filter((d) => d.status !== "rejected").map((d) => d.kind));
    return {
      status: st.identity.status, attempts_used: st.identity.attempts_used, attempts_allowed: 2, can_upload: can,
      upload_kinds: can ? REQUIRED.filter((k) => !have.has(k)) : [], documents: st.identity.documents.map((d) => ({ ...d })),
    };
  };
  const paymentOut = () => (st.payment_confirmed ? { status: "confirmed", reason: null, checkout_available: false, confirmed_at: now() }
    : st.identity.status !== "verified" ? { status: "locked", reason: "identity_first", checkout_available: false, confirmed_at: null }
    : { status: "waiting", reason: "payments_not_connected", checkout_available: false, confirmed_at: null });
  const security = () => ({ password_set: st.password, authenticator: st.factors.length > 0, session_verified: st.factors.length > 0, ready: st.password && st.factors.length > 0 });
  const stateOut = () => {
    const cur = currentStep();
    const sections = Object.entries(st.sections).map(([key, s]) => ({ key, status: s.status, note: s.note, admin_note: s.admin_note, answered_at: s.status === "to_review" ? null : now(), data: s.data, data_hash: hashOf(s.data) }));
    return {
      business_id: BUSINESS, business_name: "Maple Street Salon",
      rules: { identity_provider: "none", plan_choice: "accept_only", first_payment: "pay_before_live", failed_check: "retry_then_review", identity_attempts: 2, payments_connected: false },
      current_step: cur, current_step_number: ORDER.indexOf(cur) + 1, steps_total: 7,
      started_at: st.started_at, paused_at: st.paused_at, completed_at: st.completed_at, business_available: true,
      steps: ORDER.map((key, i) => ({ key, number: i + 1, state: st.done.includes(key) ? "done" : key === cur ? "current" : "locked", reached_at: null, completed_at: null })),
      security: security(),
      details: { sections, all_looks_right: sections.every((s) => s.status === "looks_right") },
      identity: identityOut(),
      plan: { available: true, accepted: st.plan.accepted_version === 2, accepted_version: st.plan.accepted_version, accepted_at: st.plan.accepted_at,
        current: { version: 2, tier: "pro", billing_interval: "monthly", price_cents: 24900, setup_fee_cents: 0, currency: "USD", minutes: 1000, texts: 1500,
          emails: 5000, team_seats: 5, phone_numbers: 1, locations: 1, languages: ["en", "es"], trial_enabled: false, overage_cents_per_minute: null } },
      payment: paymentOut(),
      go_live: { ready: false, live: false, checks: [
        { key: "hours", label: "Opening hours set", ok: true },
        { key: "test_call", label: "Test call answered", ok: false },
        { key: "identity", label: "Owner identity verified", ok: st.identity.status === "verified" },
        { key: "payment", label: "First payment confirmed", ok: st.payment_confirmed }] },
    };
  };
  const db = async (fn) => {
    await wait(delay);
    if (st.scenario === "notready") throw missing();
    const out = fn();
    save();
    return out;
  };
  const owner = (id) => { if (id !== BUSINESS) throw dbError("NOT_ALLOWED"); if (st.scenario === "none") throw dbError("NOT_ALLOWED"); };
  const needsCode = () => { if (!security().session_verified) throw dbError("MFA_REQUIRED"); };
  const complete = (key) => { if (!st.done.includes(key)) { st.done.push(key); return true; } return false; };

  const api = {
    getSession: async () => session,
    onAuthChange: (fn) => { listeners.add(fn); return () => listeners.delete(fn); },
    signOut: async () => { listeners.forEach((fn) => fn(null)); },
    acceptInvitations: async () => ({ accepted: 0, needsEmailLink: 0, problems: [], failed: false }),
    setPassword: async (password) => { await wait(delay); if (String(password).length < 8) throw new Error("Choose a longer password."); st.password = true; save(); },

    mfaStatus: async () => ({ enrolled: st.factors.length > 0, factors: st.factors, level: st.factors.length ? "aal2" : "aal1" }),
    startMfa: async () => { await wait(delay); return { factorId: "fake-factor", qr: QR, secret: SECRET }; },
    finishMfa: async (_id, code) => {
      await wait(delay);
      const clean = String(code ?? "").replace(/\s/g, "");
      if (!/^\d{6}$/.test(clean)) throw new Error("Enter the 6 digit code from your authenticator app.");
      if (clean !== "123456") throw new Error("That code didn't work. Try the newest one.");
      st.factors = [{ id: "fake-factor", friendly_name: "Authenticator", created_at: now() }]; save();
    },
    verifyMfa: async () => {},

    listBusinesses: () => db(() => ({ businesses: st.scenario === "none" ? [] : [{ business_id: BUSINESS, business_name: "Maple Street Salon", current_step: currentStep(), completed: Boolean(st.completed_at) }] })),
    getState: (id) => db(() => {
      owner(id);
      st.loads += 1;
      if (st.scenario === "flaky" && st.loads === 1) throw new Error("Failed to fetch");
      return stateOut();
    }),
    completeStep: (id, step) => db(() => {
      owner(id);
      if (!ORDER.includes(step)) throw dbError("INVALID_INPUT");
      if (st.done.includes(step)) return { changed: false, state: stateOut() };
      if (step !== currentStep()) throw dbError("STEP_LOCKED");
      if (step === "security" && !security().ready) throw dbError("SECURITY_INCOMPLETE", [!st.password && "password", !st.factors.length && "authenticator"].filter(Boolean).join(","));
      if (ORDER.indexOf(step) >= 2) needsCode();
      if (step === "details" && Object.values(st.sections).some((s) => s.status !== "looks_right")) throw dbError("SECTIONS_NOT_CONFIRMED", Object.keys(st.sections).filter((k) => st.sections[k].status !== "looks_right").join(","));
      if (step === "identity" && st.identity.status !== "verified") throw dbError("IDENTITY_NOT_VERIFIED");
      if (step === "plan" && st.plan.accepted_version !== 2) throw dbError("PLAN_CHANGED");
      if (step === "payment" && !st.payment_confirmed) throw dbError("PAYMENT_NOT_CONFIRMED");
      complete(step);
      if (step === "done") st.completed_at = now();
      return { changed: true, state: stateOut() };
    }),
    answerSection: (id, section, decision, note = null, seenHash = null) => db(() => {
      owner(id); needsCode();
      const s = st.sections[section];
      if (!s || !["looks_right", "change"].includes(decision)) throw dbError("INVALID_INPUT");
      if (currentStep() !== "details") throw dbError(st.done.includes("details") ? "STEP_CLOSED" : "STEP_LOCKED");
      if (decision === "change") {
        const n = String(note ?? "").trim();
        if (!n) throw dbError("NOTE_REQUIRED");
        if (n.length > 1000) throw dbError("NOTE_REQUIRED", "too_long");
        if (s.status === "change_requested" && s.note === n) return { changed: false, state: stateOut() };
        s.status = "change_requested"; s.note = n;
      } else {
        if (!seenHash) throw dbError("INVALID_INPUT");
        if (seenHash !== hashOf(s.data)) throw dbError("DETAILS_CHANGED");
        if (s.status === "looks_right") return { changed: false, state: stateOut() };
        s.status = "looks_right"; s.note = null;
      }
      return { changed: true, state: stateOut() };
    }),
    acceptPlan: (id, version) => db(() => {
      owner(id); needsCode();
      if (currentStep() !== "plan") throw dbError(st.done.includes("plan") ? "INVALID_INPUT" : "STEP_LOCKED");
      if (version !== 2) throw dbError("PLAN_CHANGED");
      const changed = st.plan.accepted_version !== 2;
      st.plan = { accepted_version: 2, accepted_at: now() };
      complete("plan");
      return { changed, state: stateOut() };
    }),
    identityStatus: (id) => db(() => { owner(id); return identityOut(); }),
    paymentStatus: (id) => db(() => { owner(id); return paymentOut(); }),
    finishLater: (id) => db(() => { owner(id); st.paused_at = now(); return { changed: true, state: stateOut() }; }),
    resume: (id) => db(() => { owner(id); const changed = Boolean(st.paused_at); st.paused_at = null; return { changed, state: stateOut() }; }),

    identityUploadUrl: async (meta) => {
      await wait(delay);
      if (st.scenario === "notready" || st.scenario === "partial") throw edgeMissing();
      if (!identityOut().upload_kinds.includes(meta.kind)) throw Object.assign(new Error("We already have your documents."), { status: 409, code: "UPLOAD_NOT_ALLOWED" });
      return { path: `${BUSINESS}/${meta.kind}/fake.pdf`, token: "fake" };
    },
    uploadFile: async () => { await wait(delay); },
    identityUploadConfirm: async (meta) => {
      await wait(delay);
      const doc = { kind: meta.kind, status: "pending_review", review_note: null, uploaded_at: now(), reviewed_at: null };
      st.identity.documents = [doc, ...st.identity.documents.filter((d) => d.kind !== meta.kind)];
      const have = new Set(st.identity.documents.filter((d) => d.status !== "rejected").map((d) => d.kind));
      if (REQUIRED.every((k) => have.has(k))) st.identity.status = "checking";
      save();
      return { document: doc, identity: identityOut() };
    },

    // test hooks (fake only): what a Zella Voice admin does in Verification and on the business page
    approveIdentity: () => { st.identity.status = "verified"; st.identity.documents = st.identity.documents.map((d) => ({ ...d, status: "verified", reviewed_at: now() })); save(); },
    rejectIdentity: (note = "The photo is blurred.") => {
      st.identity.attempts_used += 1;
      st.identity.status = st.identity.attempts_used >= 2 ? "in_review" : "try_again";
      st.identity.documents = st.identity.documents.map((d) => (d.kind === "owner_identity" ? { ...d, status: "rejected", review_note: note, reviewed_at: now() } : d)); save();
    },
    adminChangeDone: (section, note = "Changed as asked.") => { const s = st.sections[section]; if (s?.status === "change_requested") { s.status = "updated"; s.admin_note = note; save(); } },
    confirmPayment: () => { st.payment_confirmed = true; save(); },
    reset: () => { st = initialState(scenario); save(); },
  };
  if (typeof window !== "undefined") window.__zellaOnboardingFake = api;
  return api;
}
