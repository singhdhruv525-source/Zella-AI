// Admin access (lane A): what happens to an admin's sessions when their access changes (ACC-18), and the admins' own
// security actions. index.ts imports this module next to platform.ts; every action listed in ACCESS_PERMISSIONS runs
// after index.ts has checked the caller's sign in, two step sign in, platform role and that permission.

import type { SupabaseClient } from "@supabase/supabase-js";

type Json = Record<string, unknown>;
type Access = { role: string; is_active: boolean };

// Every device of an admin who is deactivated or given another role is signed out (ACC-18). Their access token
// already issued keeps working until it expires, but index.ts reads the role again on every call, so the function
// refuses or limits them at once; ending the sessions stops any device from getting a new token.
export function endsSessions(before: Access, after: Access) {
  return (before.is_active && !after.is_active) || (after.is_active && before.role !== after.role);
}

export const SESSIONS_NOT_ENDED =
  "The change is saved, but their devices could not be signed out. They are refused on their next action; try again to sign them out everywhere.";

// Returns how many sessions ended, or null with a warning when the database couldn't do it (for example before
// sql/zella_admin_sessions.sql is applied). The role change itself is never undone.
export async function endSessionsAfterChange(admin: SupabaseClient, userId: string, before: Access, after: Access) {
  if (!endsSessions(before, after)) return { sessionsEnded: 0 };
  const { data, error } = await admin.rpc("zella_end_user_sessions", { p_user_id: userId });
  if (error || typeof data !== "number") {
    console.error("Ending an admin's sessions failed", error?.message ?? data);
    return { sessionsEnded: null, sessionsWarning: SESSIONS_NOT_ENDED };
  }
  return { sessionsEnded: data };
}

// ACC-30: an admin's own two step sign in and password changes go through the server, so they are audited and the
// "keep at least one authenticator" rule (ACC-01) holds on the server too. Any active admin, for their own account
// only (index.ts lets SELF actions through for every role, like me_admin). me_mfa_remove and me_password_change also
// need a fresh code (mfa_gate.ts FRESH_CODE_ACTIONS).
export const SELF = "self";
export const ACCESS_PERMISSIONS: Record<string, string> = {
  me_mfa_added: SELF,
  me_mfa_remove: SELF,
  me_password_change: SELF,
};
export const SELF_ACTIONS = Object.keys(ACCESS_PERMISSIONS).filter((a) => ACCESS_PERMISSIONS[a] === SELF);

// The app's rule (web/src/formValidation.js passwordRules): 8 to 64 characters with a capital, a lower case letter
// and a number. Checked here too, so a direct call to the function meets the same rule as the page.
export function passwordProblem(p: unknown): string | null {
  if (typeof p !== "string" || !p) return "Enter a new password.";
  if (p.length < 8) return "Use at least 8 characters.";
  if (p.length > 64) return "Use no more than 64 characters.";
  if (!/[A-Z]/.test(p) || !/[a-z]/.test(p) || !/[0-9]/.test(p)) return "Use a capital, a lower case letter and a number.";
  return null;
}

type Kit = { InputError: new (message: string, status?: number) => Error; requireId: (v: unknown, label?: string) => string };
type Factor = { id: string; status?: string; factor_type?: string; friendly_name?: string | null };

export function accessHandlers(admin: SupabaseClient, fields: Json, userId: string, kit: Kit) {
  const { InputError, requireId } = kit;

  const verifiedFactors = async (): Promise<Factor[]> => {
    const { data, error } = await admin.auth.admin.mfa.listFactors({ userId });
    if (error) throw error;
    return ((data?.factors ?? []) as Factor[]).filter((f) => f.status === "verified");
  };

  const handlers: Record<string, () => Promise<unknown>> = {
    // The browser has just verified a new authenticator (Supabase Auth); record it once it is really in the list.
    me_mfa_added: async () => {
      const factorId = requireId(fields.factorId, "authenticator");
      const factor = (await verifiedFactors()).find((f) => f.id === factorId);
      if (!factor) throw new InputError("That authenticator isn't set up on your account", 404);
      return { factorId, friendlyName: factor.friendly_name ?? null };
    },
    // Removing one needs another left: every admin keeps two step sign in (ACC-01).
    me_mfa_remove: async () => {
      const factorId = requireId(fields.factorId, "authenticator");
      const factors = await verifiedFactors();
      const factor = factors.find((f) => f.id === factorId);
      if (!factor) throw new InputError("That authenticator isn't set up on your account", 404);
      if (factors.length < 2) throw new InputError("Every Zella Voice admin needs two step sign in. Add another authenticator first, then remove this one.", 409);
      const { error } = await admin.auth.admin.mfa.deleteFactor({ userId, id: factorId });
      if (error) throw error;
      return { factorId, friendlyName: factor.friendly_name ?? null, left: factors.length - 1 };
    },
    // Through the server key, which skips Supabase's own reauthentication: the fresh code (entered within 5 minutes)
    // is the reauthentication instead.
    me_password_change: async () => {
      const problem = passwordProblem(fields.password);
      if (problem) throw new InputError(problem);
      const { error } = await admin.auth.admin.updateUserById(userId, { password: fields.password as string });
      if (error) throw new InputError(/weak|pwned|leaked|known/i.test(error.message) ? "That password is too easy to guess or has appeared in a data breach. Choose another." : "The password could not be changed. Try again.", 422);
      return { changed: true };
    },
  };

  // Never the password itself, nor anything about it.
  const audited: Record<string, (r: Json) => Json | null> = {
    me_mfa_added: (r) => ({ action: "admin.mfa_added", entity_type: "mfa_factor", entity_id: r.factorId, new_data: { friendly_name: r.friendlyName } }),
    me_mfa_remove: (r) => ({ action: "admin.mfa_removed", entity_type: "mfa_factor", entity_id: r.factorId, old_data: { friendly_name: r.friendlyName }, new_data: { left: r.left } }),
    me_password_change: () => ({ action: "admin.password_changed", entity_type: "user", entity_id: userId }),
  };
  return { handlers, audited };
}
