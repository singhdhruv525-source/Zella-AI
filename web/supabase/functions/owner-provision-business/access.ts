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

export const ACCESS_PERMISSIONS: Record<string, string> = {};

export function accessHandlers(_admin: SupabaseClient, _fields: Json) {
  const handlers: Record<string, () => Promise<unknown>> = {};
  const audited: Record<string, (r: Json) => Json | null> = {};
  return { handlers, audited };
}
