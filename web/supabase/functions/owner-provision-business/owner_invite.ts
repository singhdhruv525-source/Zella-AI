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

// Required setup, checked by the server from saved data before the workspace becomes active.
export type SetupFacts = { name: string | null; industryId: string | null; openDays: number; documentsReady: boolean; documentsMissing: string[] };
export function setupProblems(f: SetupFacts): string[] {
  const out: string[] = [];
  if (!f.name?.trim()) out.push("the business name");
  if (!f.industryId) out.push("the industry");
  if (f.openDays < 1) out.push("opening hours for at least one day (Hours & services)");
  if (!f.documentsReady) out.push(`verification documents (${f.documentsMissing.join(", ") || "required documents"})`);
  return out;
}

// Finishing setup, with its effects injected so retries and double submits can be tested (owner_invite_test.ts).
// Order: required setup from SAVED data -> the owner's invitation decides -> a pending/failed invitation is claimed
// atomically before the email (a second request can't send too) -> the workspace becomes active only after the
// owner's invitation went out (or was already sent / accepted). A failed email gives the claim back for Retry.
export interface FinishDeps {
  business(): Promise<{ name: string | null; industry_id: string | null; cancelled_at: string | null }>;
  ownerInvitation(): Promise<OwnerInvitation | null>;
  documents(): Promise<{ ready: boolean; missing: string[] }>;
  openDays(): Promise<number>;
  claim(invitationId: string): Promise<boolean>;                       // open -> sent, true if this call won
  sendInvite(email: string, name: string | null): Promise<{ userId: string } | { error: string }>;
  release(invitationId: string, reason: string): Promise<void>;        // sent (unsent, ours) -> failed
  // links the account; "closed" when the invitation was cancelled meanwhile, or a bookkeeping error message
  recordSent(invitationId: string, userId: string): Promise<null | "closed" | string>;
  activate(): Promise<void>;
  now(): Date;
}
export class FinishError extends Error { constructor(message: string, public status: number) { super(message); } }

export async function finishSetupWith(d: FinishDeps) {
  const business = await d.business();
  if (business.cancelled_at) throw new FinishError("This business has been cancelled", 409);
  const inv = await d.ownerInvitation();
  const plan = finishPlan(inv, d.now());
  if (plan.kind in FINISH_STOP) { const [status, message] = FINISH_STOP[plan.kind]; throw new FinishError(message, status); }
  const [documents, openDays] = await Promise.all([d.documents(), d.openDays()]);
  const problems = setupProblems({ name: business.name, industryId: business.industry_id, openDays, documentsReady: documents.ready, documentsMissing: documents.missing });
  if (problems.length) throw new FinishError(`Before finishing, save ${problems.join("; ")}.`, 400);

  let invitationStatus: string = plan.kind;
  let warning: string | undefined;
  if (plan.kind === "send") {
    if (!(await d.claim(inv!.id))) throw new FinishError("Setup is already being finished in another window. Reload the page to see the result.", 409);
    let sent: { userId: string } | { error: string };
    try { sent = await d.sendInvite(inv!.email, inv!.owner_name); }
    catch (e) { console.error("Owner invitation failed", e); sent = { error: "The invitation could not be sent. Please try again." }; }
    if ("error" in sent) {
      await d.release(inv!.id, sent.error);
      return { completed: false, invitationStatus: "failed",
        invitationError: /already|registered|exists/i.test(sent.error) ? "This email already has a Zella account" : sent.error };
    }
    const bookkeeping = await d.recordSent(inv!.id, sent.userId);
    if (bookkeeping === "closed") {
      // cancelled while the email was going out: the cancel wins, nothing is activated or linked
      return { completed: false, invitationStatus: "closed",
        invitationError: "The owner invitation was cancelled or accepted while it was being sent. Check the invitation before sending another." };
    }
    if (bookkeeping) warning = "The invitation was sent, but the owner could not be linked to the business. Check the invitation record.";
    invitationStatus = "sent";
  }
  await d.activate();
  return { completed: true, invitationStatus, warning };
}
