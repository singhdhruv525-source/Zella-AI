// What finishing setup may do with the owner's invitation (found with ownerInvitation.ts, role = 'owner' only), and in
// which order. Pure: tested in owner_invite_test.ts.

export type OwnerInvitation = {
  id: string; email: string; owner_name: string | null; status: string; role?: string | null;
  expires_at?: string | null; created_at?: string | null; auth_user_id?: string | null;
};

export type FinishPlan =
  | { kind: "missing" }                 // no owner invitation: add the owner first
  | { kind: "revoked" }                 // cancelled: add the owner again on the Owner step
  | { kind: "expired" }                 // sent, but the link ran out: use Resend invitation, never resent silently
  | { kind: "accepted" }                // the owner joined already: nothing to send
  | { kind: "sent" }                    // sent and still valid: nothing to send again
  | { kind: "send" };                   // pending or failed: send it now

export function finishPlan(inv: OwnerInvitation | null, now: Date): FinishPlan {
  if (!inv) return { kind: "missing" };
  if (inv.status === "revoked") return { kind: "revoked" };
  if (inv.status === "accepted") return { kind: "accepted" };
  // a "sent" invitation whose link ran out isn't open (ownerInvitation.ts): Resend invitation sends a new one
  if (inv.status === "sent" && Boolean(inv.expires_at) && new Date(inv.expires_at as string) <= now) return { kind: "expired" };
  if (inv.status === "sent") return { kind: "sent" };
  return { kind: "send" };   // pending, failed, expired (open: ownerInvitation.ts OPEN_OWNER_INVITATION)
}

// What the person finishing setup is told for the plans that stop before anything changes.
export const FINISH_STOP: Record<string, [number, string]> = {
  missing: [400, "Add the business owner on the Owner step before finishing setup."],
  revoked: [409, "The owner's invitation was cancelled. Add the owner again on the Owner step, then finish."],
  expired: [409, "The owner's invitation link has expired. Choose Resend invitation on the business page, then finish."],
};

// Without the app's public address an invitation link can't open (Supabase would fall back to its own site address),
// so no owner invitation is sent until ZELLA_APP_URL is set. Same wording as the admin and staff invitations.
export const APP_URL_MISSING = "The app address is not set, so the invitation link would not open for the invited person. Add the ZELLA_APP_URL secret (the public address of the Zella Voice app) and try again.";
export function appUrlUsable(raw: string | null | undefined): string | null {
  const v = (raw ?? "").trim().replace(/\/+$/, "");
  try { const u = new URL(v); return u.protocol === "https:" || u.hostname === "localhost" ? v : null; } catch { return null; }
}

// A fallback number must be dialable as written (E.164), as voice-rules dials it.
export const E164 = /^\+[1-9][0-9]{7,14}$/;

// Required setup, checked by the server from saved data before the workspace becomes active.
export type SetupFacts = { name: string | null; industryId: string | null; openDays: number; documentsReady: boolean; documentsMissing: string[]; planSaved: boolean; fallbackSaved: boolean };
export function setupProblems(f: SetupFacts): string[] {
  const out: string[] = [];
  if (!f.name?.trim()) out.push("the business name");
  if (!f.industryId) out.push("the industry");
  if (f.openDays < 1) out.push("opening hours for at least one day (Hours & services)");
  if (!f.documentsReady) out.push(`verification documents (${f.documentsMissing.join(", ") || "required documents"})`);
  // REQ-BIL-57: the plan is reviewed and saved by a billing admin before the owner is invited
  if (!f.planSaved) out.push("the plan, reviewed and saved by a billing admin (Plan & pricing)");
  // REQ-BIL-34: every business has a fallback number from Create Business; calls go there whenever the AI can't take them
  if (!f.fallbackSaved) out.push("the fallback number, where calls go when the AI receptionist can't take them (Phone & integrations; save it again if it was entered before the receptionist was set up)");
  return out;
}

// Finishing setup, with its effects injected so retries and double submits can be tested (owner_invite_test.ts).
// Order: required setup from SAVED data -> the owner's invitation decides -> a pending/failed invitation is claimed
// atomically before the email (a second request can't send too) -> the workspace becomes active only after the
// owner's invitation went out (or was already sent / accepted). A failed email gives the claim back for Retry.
export interface FinishDeps {
  business(): Promise<{ name: string | null; industry_id: string | null; cancelled_at: string | null; suspended_at?: string | null }>;
  ownerInvitation(): Promise<OwnerInvitation | null>;
  documents(): Promise<{ ready: boolean; missing: string[] }>;
  openDays(): Promise<number>;
  planSaved(): Promise<boolean>;                                         // a business_plans version exists
  fallbackNumber(): Promise<string | null>;                              // the saved fallback number, if any
  appUrlSet(): boolean;                                                  // ZELLA_APP_URL is a usable public address
  claim(invitationId: string): Promise<boolean>;                       // open -> sent, true if this call won
  // a new account gets an invitation; an existing account gets a sign in link (existingAccount: true)
  sendInvite(email: string, name: string | null): Promise<{ userId: string; existingAccount?: boolean } | { error: string }>;
  release(invitationId: string, reason: string): Promise<void>;        // sent (unsent, ours) -> failed
  // links the account; "closed" when the invitation was cancelled meanwhile, or a bookkeeping error message
  recordSent(invitationId: string, userId: string): Promise<null | "closed" | string>;
  // false when the business could not be activated because it was suspended or cancelled meanwhile
  activate(): Promise<boolean | void>;
  now(): Date;
}
export const SUSPENDED_FINISH = "This business is suspended. Reactivate it on the business page before finishing setup.";
export const SUSPENDED_DURING_FINISH = "The business was suspended or cancelled while setup was being finished, so its workspace was not turned on. Check the business page.";
export class FinishError extends Error { constructor(message: string, public status: number) { super(message); } }

export async function finishSetupWith(d: FinishDeps) {
  const business = await d.business();
  if (business.cancelled_at) throw new FinishError("This business has been cancelled", 409);
  // BIZ-06: finishing would make a suspended workspace active and send its owner an invitation. Refused before
  // anything is claimed or sent; reactivate the business first.
  if (business.suspended_at) throw new FinishError(SUSPENDED_FINISH, 409);
  const inv = await d.ownerInvitation();
  const plan = finishPlan(inv, d.now());
  if (plan.kind in FINISH_STOP) { const [status, message] = FINISH_STOP[plan.kind]; throw new FinishError(message, status); }
  const [documents, openDays, planSaved, fallback] = await Promise.all([d.documents(), d.openDays(), d.planSaved(), d.fallbackNumber()]);
  const problems = setupProblems({ name: business.name, industryId: business.industry_id, openDays, documentsReady: documents.ready, documentsMissing: documents.missing, planSaved,
    fallbackSaved: typeof fallback === "string" && E164.test(fallback) });
  if (problems.length) throw new FinishError(`Before finishing, save ${problems.join("; ")}.`, 400);

  let invitationStatus: string = plan.kind;
  let warning: string | undefined;
  let existingAccount = false;
  if (plan.kind === "send") {
    // before the claim, so a refusal leaves the invitation exactly as it was
    if (!d.appUrlSet()) throw new FinishError(APP_URL_MISSING, 503);
    if (!(await d.claim(inv!.id))) throw new FinishError("Setup is already being finished in another window. Reload the page to see the result.", 409);
    let sent: { userId: string; existingAccount?: boolean } | { error: string };
    try { sent = await d.sendInvite(inv!.email, inv!.owner_name); }
    catch (e) { console.error("Owner invitation failed", e); sent = { error: "The invitation could not be sent. Please try again." }; }
    if ("error" in sent) {
      await d.release(inv!.id, sent.error);
      return { completed: false, invitationStatus: "failed", invitationError: sent.error };
    }
    const bookkeeping = await d.recordSent(inv!.id, sent.userId);
    if (bookkeeping === "closed") {
      // cancelled while the email was going out: the cancel wins, nothing is activated or linked
      return { completed: false, invitationStatus: "closed",
        invitationError: "The owner invitation was cancelled or accepted while it was being sent. Check the invitation before sending another." };
    }
    if (bookkeeping) warning = "The invitation was sent, but the owner could not be linked to the business. Check the invitation record.";
    invitationStatus = "sent";
    if (sent.existingAccount) existingAccount = true;
  }
  if ((await d.activate()) === false) {
    // suspended or cancelled while the invitation was going out: the suspension wins and the workspace stays off
    return { completed: false, invitationStatus, warning: SUSPENDED_DURING_FINISH, ...(existingAccount ? { existingAccount: true } : {}) };
  }
  return { completed: true, invitationStatus, warning, ...(existingAccount ? { existingAccount: true } : {}) };
}
