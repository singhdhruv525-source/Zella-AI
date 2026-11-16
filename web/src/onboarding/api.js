import { supabase } from "../supabase";
import { acceptInvitations as acceptAllInvitations } from "../BusinessAuth";
import { finishMfaEnrollment, mfaStatus, startMfaEnrollment, verifyMfaCode } from "../mfa";

// The owner onboarding journey's server calls, one function per call, exactly as docs/OWNER_ONBOARDING_CONTRACT.md
// (version 2) names them. The screens only ever talk to this module.
//
// A call that isn't deployed yet comes back as PostgREST's "function not found" (PGRST202) or the edge function's 404;
// the screens show "This step isn't ready yet" for those (steps.js isNotReady), never a crash.
//
// A stand in (fakeApi.js) exists for unit tests and the local browser journey only. It is loaded only when the app is
// built with VITE_ONBOARDING_FAKE=1, so a production build never contains it.

// A database function's refusal carries its code as the message: { code: "P0001", message: "<CODE>", details }, or,
// from the request check that runs first, { code: "42501", message: "MFA_REQUIRED" } (contract §4, version 2).
async function rpc(name, args) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) {
    const fromMessage = /^[A-Z_]{3,40}$/.test(String(error.message ?? "")) ? error.message : null;
    throw Object.assign(new Error(error.message || "Something went wrong."), { code: fromMessage ?? error.code, details: error.details ?? null, status: error.status });
  }
  return data;
}

// The owner-onboarding edge function answers { error: "<plain words>", code } on a refusal.
async function edge(action, payload) {
  const { data, error } = await supabase.functions.invoke("owner-onboarding", { body: { action, ...payload } });
  if (error) {
    const status = error.context?.status;
    let body = null;
    try { body = await error.context?.json(); } catch { /* not JSON */ }
    // our function always answers { error, code }; a 404 without it is the platform saying it isn't deployed yet
    if (status === 404 && !body?.error) throw Object.assign(new Error("Requested function was not found"), { status, notReady: true });
    throw Object.assign(new Error(body?.error || "Something went wrong. Please try again."), { status, code: typeof body?.code === "string" ? body.code : undefined, words: typeof body?.error === "string" ? body.error : undefined });
  }
  if (!data || data.error) throw Object.assign(new Error(data?.error || "Something went wrong. Please try again."), { code: data?.code });
  return data;
}

export const realApi = {
  // the signed in person (Supabase Auth)
  getSession: async () => (await supabase.auth.getSession()).data.session ?? null,
  onAuthChange: (fn) => {
    const { data } = supabase.auth.onAuthStateChange((_event, session) => fn(session));
    return () => data.subscription.unsubscribe();
  },
  signOut: () => supabase.auth.signOut(),
  // before the first call (contract §1): makes the owner's membership active; safe to repeat
  acceptInvitations: () => acceptAllInvitations(),
  setPassword: async (password) => {
    const { error } = await supabase.auth.updateUser({ password });
    if (error) throw error;
  },

  // two step sign in: the same calls the admin set up and Settings use (mfa.js)
  mfaStatus,
  startMfa: startMfaEnrollment,
  finishMfa: finishMfaEnrollment,
  verifyMfa: verifyMfaCode,

  // §5.1 to §5.7
  listBusinesses: () => rpc("zella_owner_onboarding_list"),
  getState: (businessId) => rpc("zella_owner_onboarding_get", { p_business_id: businessId }),
  completeStep: (businessId, step) => rpc("zella_owner_onboarding_complete_step", { p_business_id: businessId, p_step: step }),
  answerSection: (businessId, section, decision, note = null) => rpc("zella_owner_onboarding_section", { p_business_id: businessId, p_section: section, p_decision: decision, p_note: note }),
  acceptPlan: (businessId, version) => rpc("zella_owner_onboarding_plan_accept", { p_business_id: businessId, p_plan_version: version }),
  identityStatus: (businessId) => rpc("zella_owner_onboarding_identity_status", { p_business_id: businessId }),
  paymentStatus: (businessId) => rpc("zella_owner_onboarding_payment_status", { p_business_id: businessId }),
  finishLater: (businessId) => rpc("zella_owner_onboarding_finish_later", { p_business_id: businessId }),
  resume: (businessId) => rpc("zella_owner_onboarding_resume", { p_business_id: businessId }),

  // §5.8: a new identity document, through a one time upload link for the private bucket
  identityUploadUrl: (meta) => edge("identity_upload_url", meta),
  uploadFile: async (path, token, file) => {
    const { error } = await supabase.storage.from("business-documents").uploadToSignedUrl(path, token, file, { contentType: file.type });
    if (error) throw new Error(error.message || "The upload didn't finish.");
  },
  identityUploadConfirm: (meta) => edge("identity_upload_confirm", meta),

  // Pay (docs/PAYMENTS_ARCHITECTURE.md §6.1): the billing-api edge function opens Stripe Checkout for the accepted
  // plan. The browser sends no amount; it comes back from Stripe and asks the server to look again.
  startCheckout: (businessId, idempotencyKey) => billing("checkout_start", { business_id: businessId, idempotency_key: idempotencyKey }),
  checkoutReturn: (businessId) => billing("checkout_return", { business_id: businessId }),
};

async function billing(action, payload) {
  const { data, error } = await supabase.functions.invoke("billing-api", { body: { action, ...payload } });
  if (error) {
    const status = error.context?.status;
    let body = null;
    try { body = await error.context?.json(); } catch { /* not JSON */ }
    if (status === 404 && !body?.error) throw Object.assign(new Error("Requested function was not found"), { status, notReady: true });
    throw Object.assign(new Error(body?.error || "Something went wrong. Please try again."), { status, code: typeof body?.code === "string" ? body.code : undefined, words: typeof body?.error === "string" ? body.error : undefined });
  }
  return data;
}

// The api the screens use. With VITE_ONBOARDING_FAKE=1 (local preview and tests only) the stand in answers instead.
let chosen = null;
export async function getApi() {
  if (chosen) return chosen;
  if (import.meta.env.VITE_ONBOARDING_FAKE === "1") {
    const { createFakeApi } = await import("./fakeApi.js");
    chosen = createFakeApi({ scenario: new URLSearchParams(window.location.search).get("scenario") ?? "", storage: window.localStorage });
  } else {
    chosen = realApi;
  }
  return chosen;
}

// Is an owner onboarding journey waiting for the signed in person? Used by /welcome after an invitation link and by
// the CRM: yes opens (or offers) the journey; anything else (no journey, not deployed yet, an error) keeps today's
// behaviour, so an invitation always works. Returns the business row from §5.1, or null.
export async function waitingJourney({ accept = false } = {}) {
  try {
    const api = await getApi();
    if (accept) await api.acceptInvitations();
    const list = await api.listBusinesses();
    return (Array.isArray(list?.businesses) ? list.businesses : []).find((b) => b.completed === false) ?? null;
  } catch {
    return null;
  }
}
