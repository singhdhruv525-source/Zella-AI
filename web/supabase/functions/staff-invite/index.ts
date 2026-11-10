// Zella: sends the email for a team invitation made in the business app (Team access > Invite someone).
//
// zella_invite_staff / zella_resend_invitation only write the invitation row. This function sends the email and
// ties the invitation to the account that owns that email address (auth_user_id). The decisions live in logic.ts;
// the invitation is finished atomically by zella_staff_invite_finalize and acceptance needs a session signed in
// through an email link (sql/zella_invitation_hardening.sql). Deploy that SQL before this function.
//
//   POST { invitationId }   (signed in; the caller must be an active owner or admin of that business)
//   -> { sent: true, existingAccount: boolean }
//
// verify_jwt is off for the same reason as owner-provision-business: the function checks the caller's token itself.

import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { withCors } from "../_shared/cors.ts";
import { type AuthUser, type Deps, sendInvitation } from "./logic.ts";

const respond = (data: unknown, status = 200) => Response.json(data, { status });
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function findUserByEmail(admin: SupabaseClient, email: string): Promise<AuthUser | null> {
  for (let page = 1; page <= 20; page++) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 1000 });
    if (error) throw error;
    const users = data?.users ?? [];
    const match = users.find((u: { email?: string }) => u.email?.toLowerCase() === email);
    if (match) return match as AuthUser;
    if (data.nextPage === null) return null;
  }
  throw new Error("User lookup page limit reached");
}

async function rpcText(admin: SupabaseClient, fn: string, args: Record<string, unknown>): Promise<string> {
  const { data, error } = await admin.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return String(data);
}

Deno.serve(withCors(async (req: Request) => {
  if (req.method !== "POST") return respond({ error: "Method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const publishableKey = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  const serverSecretKey = Deno.env.get("ZELLA_SERVER_SECRET_KEY");
  const appUrl = (Deno.env.get("ZELLA_APP_URL") ?? "").trim().replace(/\/+$/, "");
  if (!supabaseUrl || !publishableKey || !serverSecretKey) {
    console.error("staff-invite configuration is missing");
    return respond({ error: "Server configuration is incomplete" }, 500);
  }

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return respond({ error: "Please sign in first" }, 401);
  const caller = createClient(supabaseUrl, publishableKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: { user }, error: userError } = await caller.auth.getUser();
  if (userError || !user) return respond({ error: "Please sign in first" }, 401);
  if (!appUrl) return respond({ error: "The app address (ZELLA_APP_URL) is not set, so the invitation link would not open. Ask the Zella team." }, 503);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return respond({ error: "Invalid request" }, 400); }
  const invitationId = typeof body?.invitationId === "string" ? body.invitationId : "";
  if (!UUID_RE.test(invitationId)) return respond({ error: "Invalid request" }, 400);

  const admin = createClient(supabaseUrl, serverSecretKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const publicClient = createClient(supabaseUrl, publishableKey, { auth: { persistSession: false, autoRefreshToken: false } });

  const deps: Deps = {
    async getInvitation(id) {
      const { data, error } = await admin.from("business_invitations").select("id, business_id, email, owner_name, role, status, expires_at").eq("id", id).maybeSingle();
      if (error) throw error;
      return data;
    },
    async callerRole(businessId, userId) {
      const { data } = await admin.from("business_members").select("role").eq("business_id", businessId).eq("user_id", userId).eq("status", "active").maybeSingle();
      return data?.role ?? null;
    },
    async businessOpen(businessId) {
      const { data } = await admin.from("businesses").select("cancelled_at").eq("id", businessId).maybeSingle();
      return Boolean(data && !data.cancelled_at);
    },
    findUser: (email) => findUserByEmail(admin, email),
    async isActiveMember(businessId, userId) {
      const { data, error } = await admin.from("business_members").select("status").eq("business_id", businessId).eq("user_id", userId).maybeSingle();
      if (error) throw error;
      return data?.status === "active";
    },
    async inviteNewUser(email, name) {
      const { data, error } = await admin.auth.admin.inviteUserByEmail(email, { data: { full_name: name ?? null }, redirectTo: `${appUrl}/welcome` });
      if (error || !data?.user) throw new Error(error?.message ?? "The invitation email could not be sent");
      return data.user as AuthUser;
    },
    async sendSignInLink(email) {
      // An email link at the invited address; signing in through it is what lets the person accept.
      const { error } = await publicClient.auth.signInWithOtp({ email, options: { shouldCreateUser: false, emailRedirectTo: `${appUrl}/welcome` } });
      if (error) throw new Error(error.message);
    },
    finalize: (invitationId, actorId, userId, existing) =>
      rpcText(admin, "zella_staff_invite_finalize", { p_invitation_id: invitationId, p_actor: actorId, p_auth_user_id: userId, p_existing_account: existing }),
    fail: (invitationId, error) => rpcText(admin, "zella_staff_invite_fail", { p_invitation_id: invitationId, p_error: error.slice(0, 300) }),
    now: () => new Date(),
  };

  try {
    const result = await sendInvitation(deps, user.id, invitationId);
    if (result.status >= 500) console.error("staff-invite failed", invitationId, result.body.error);
    return respond(result.body, result.status);
  } catch (e) {
    console.error("staff-invite error", e instanceof Error ? e.message : String(e));
    return respond({ error: "Something went wrong. Please try again." }, 500);
  }
}));
