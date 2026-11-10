// The decisions of staff-invite, separated from Supabase so they can be tested with fakes (logic_test.ts).
//
// Order: check the caller and the invitation, send the email, then finish through the database
// (zella_staff_invite_finalize), which locks the invitation and changes it only if it is still open and the caller
// may still invite. A failure is recorded with zella_staff_invite_fail, which never reopens a closed invitation.
//
// Email ownership: a new person gets Supabase's invitation email; someone who already has an account gets a sign-in
// link at that address. Either way the invitation is accepted only from a session signed in through such a link
// (zella_accept_staff_invitations_v2 checks the session's sign-in method), never because the account signed in once.

export type Invitation = { id: string; business_id: string; email: string; owner_name: string | null; role: string; status: string; expires_at: string | null };
export type AuthUser = { id: string; email?: string | null; email_confirmed_at?: string | null; last_sign_in_at?: string | null; invited_at?: string | null };

export interface Deps {
  getInvitation(id: string): Promise<Invitation | null>;
  callerRole(businessId: string, userId: string): Promise<string | null>;   // active membership role, or null
  businessOpen(businessId: string): Promise<boolean>;
  findUser(email: string): Promise<AuthUser | null>;
  isActiveMember(businessId: string, userId: string): Promise<boolean>;
  inviteNewUser(email: string, name: string | null): Promise<AuthUser>;      // Supabase invitation email (new or never-confirmed account)
  sendSignInLink(email: string): Promise<void>;                               // email link for an existing account
  finalize(invitationId: string, actorId: string, userId: string, existing: boolean): Promise<string>;
  fail(invitationId: string, error: string): Promise<string>;
  now(): Date;
}

export type Result = { status: number; body: Record<string, unknown> };
const err = (status: number, error: string, code?: string): Result => ({ status, body: code ? { error, code } : { error } });

const FINALIZE_MESSAGES: Record<string, [number, string]> = {
  CLOSED: [409, "This invitation was cancelled or accepted meanwhile, so it wasn't changed."],
  EXPIRED: [409, "This invitation has expired. Choose Send again."],
  NOT_ALLOWED: [403, "You don't have permission to do that in this workspace."],
  BUSINESS_CLOSED: [409, "This workspace is closed."],
  EMAIL_MISMATCH: [409, "The account for this email address changed meanwhile. Please try again."],
  ALREADY_MEMBER: [409, "That person is already on your team."],
  NOT_FOUND: [404, "Invitation not found"],
};

export async function sendInvitation(deps: Deps, callerId: string, invitationId: string): Promise<Result> {
  const invitation = await deps.getInvitation(invitationId);
  if (!invitation) return err(404, "Invitation not found");

  // The caller must run this business, checked here and never taken from the request (and again when finishing).
  const role = await deps.callerRole(invitation.business_id, callerId);
  if (!role || !["owner", "admin"].includes(role)) return err(403, "You don't have permission to do that in this workspace.");
  if (invitation.role === "owner") return err(403, "Owner invitations are sent by the Zella team.");
  if (invitation.role === "admin" && role !== "owner") return err(403, "Only the owner can invite an admin.");
  if (!["pending", "sent", "failed"].includes(invitation.status)) return err(409, "This invitation is already closed.");
  if (invitation.expires_at && new Date(invitation.expires_at) <= deps.now()) return err(409, "This invitation has expired. Choose Send again.");
  if (!(await deps.businessOpen(invitation.business_id))) return err(409, "This workspace is closed.");

  const email = String(invitation.email).trim().toLowerCase();
  let target: AuthUser | null;
  let existingAccount = false;
  try {
    target = await deps.findUser(email);
    if (target && (await deps.isActiveMember(invitation.business_id, target.id))) return err(409, "That person is already on your team.");
    // An account that was only ever invited (never confirmed, never signed in) gets the invitation email again.
    // Any other existing account gets a sign-in link: having signed in before proves nothing about the address.
    const onlyInvited = Boolean(target && !target.email_confirmed_at && !target.last_sign_in_at);
    if (!target || onlyInvited) {
      target = await deps.inviteNewUser(email, invitation.owner_name);
    } else {
      existingAccount = true;
      await deps.sendSignInLink(email);
    }
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    try { await deps.fail(invitation.id, message); } catch { /* still return the email failure */ }
    return err(502, /rate limit|security purposes|too many/i.test(message)
      ? "Too many emails were sent in a short time. Wait a minute and try again."
      : "The invitation email could not be sent. Please try again.");
  }

  let outcome: string;
  try {
    outcome = await deps.finalize(invitation.id, callerId, target.id, existingAccount);
  } catch (e) {
    // the email went out but the invitation couldn't be marked; recording "failed" is safe (it never reopens)
    await deps.fail(invitation.id, "finalize: " + (e instanceof Error ? e.message : String(e))).catch(() => "");
    return err(500, "The email was sent but the invitation couldn't be updated. Reload and check the invitation.");
  }
  if (outcome !== "sent") {
    const [status, message] = FINALIZE_MESSAGES[outcome] ?? [409, "The invitation could not be updated. Reload and try again."];
    return err(status, message, outcome);
  }
  return { status: 200, body: { sent: true, existingAccount } };
}
