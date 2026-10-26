// Zella: sends the email for a team invitation made in the business app (Team access > Invite someone).
//
// zella_invite_staff / zella_resend_invitation only write the invitation row. This function sends the Supabase
// invitation email and ties the invitation to the account that owns that email address, so only that account can
// accept it (zella_accept_staff_invitations checks auth_user_id). Someone who signs up with the same email
// address later cannot take the place.
//
//   POST { invitationId }   (signed in; the caller must be an active owner or admin of that business)
//   -> { sent: true, existingAccount: boolean }
//
// verify_jwt is off for the same reason as owner-provision-business: the function checks the caller's token itself.

import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { withCors } from "../_shared/cors.ts";

const respond = (data: unknown, status = 200) => Response.json(data, { status });
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function findUserByEmail(admin: SupabaseClient, email: string) {
  for (let page = 1; page <= 20; page++) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 1000 });
    if (error) throw error;
    const users = data?.users ?? [];
    const match = users.find((u: { email?: string }) => u.email?.toLowerCase() === email);
    if (match) return match;
    if (users.length < 1000) return null;
  }
  return null;
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
  if (!appUrl) return respond({ error: "The app address (ZELLA_APP_URL) is not set, so the invitation link would not open. Ask the Zella team." }, 503);

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return respond({ error: "Please sign in first" }, 401);
  const caller = createClient(supabaseUrl, publishableKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: { user }, error: userError } = await caller.auth.getUser();
  if (userError || !user) return respond({ error: "Please sign in first" }, 401);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return respond({ error: "Invalid request" }, 400); }
  const invitationId = typeof body?.invitationId === "string" ? body.invitationId : "";
  if (!UUID_RE.test(invitationId)) return respond({ error: "Invalid request" }, 400);

  const admin = createClient(supabaseUrl, serverSecretKey, { auth: { persistSession: false, autoRefreshToken: false } });

  const { data: invitation, error: invError } = await admin.from("business_invitations")
    .select("id, business_id, email, owner_name, role, status, expires_at").eq("id", invitationId).maybeSingle();
  if (invError) { console.error("staff-invite lookup failed", invError.message); return respond({ error: "Something went wrong. Please try again." }, 500); }
  if (!invitation) return respond({ error: "Invitation not found" }, 404);

  // The caller must run this business, checked here and never taken from the request.
  const { data: me } = await admin.from("business_members").select("role")
    .eq("business_id", invitation.business_id).eq("user_id", user.id).eq("status", "active").maybeSingle();
  if (!me || !["owner", "admin"].includes(me.role)) return respond({ error: "You don't have permission to do that in this workspace." }, 403);
  if (invitation.role === "owner") return respond({ error: "Owner invitations are sent by the Zella team." }, 403);
  if (invitation.role === "admin" && me.role !== "owner") return respond({ error: "Only the owner can invite an admin." }, 403);
  if (!["pending", "sent", "failed"].includes(invitation.status)) return respond({ error: "This invitation is already closed." }, 409);
  if (invitation.expires_at && new Date(invitation.expires_at) < new Date()) return respond({ error: "This invitation has expired. Choose Send again." }, 409);

  const { data: business } = await admin.from("businesses").select("name, cancelled_at").eq("id", invitation.business_id).maybeSingle();
  if (!business || business.cancelled_at) return respond({ error: "This workspace is closed." }, 409);

  const email = String(invitation.email).toLowerCase();
  try {
    let target = await findUserByEmail(admin, email);
    const existingAccount = Boolean(target?.last_sign_in_at);
    if (!target || !existingAccount) {
      // New person, or someone invited before who never signed in: send (or resend) the email link.
      const { data, error } = await admin.auth.admin.inviteUserByEmail(email, {
        data: { full_name: invitation.owner_name ?? null },
        redirectTo: `${appUrl}/welcome`,
      });
      if (error || !data?.user) throw new Error(error?.message ?? "The invitation email could not be sent");
      target = data.user;
    }
    const { data: member } = await admin.from("business_members").select("status")
      .eq("business_id", invitation.business_id).eq("user_id", target.id).maybeSingle();
    if (member?.status === "active") return respond({ error: "That person is already on your team." }, 409);

    const { error: updateError } = await admin.from("business_invitations")
      .update({ status: "sent", auth_user_id: target.id, last_error: null, updated_at: new Date().toISOString() })
      .eq("id", invitation.id);
    if (updateError) throw updateError;
    await admin.from("audit_logs").insert({
      business_id: invitation.business_id, user_id: user.id, action: "staff_invitation.sent", entity_type: "business_invitation",
      entity_id: invitation.id, new_data: { email, role: invitation.role, existing_account: existingAccount },
    });
    return respond({ sent: true, existingAccount });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error("staff-invite send failed", message);
    await admin.from("business_invitations").update({ status: "failed", last_error: message.slice(0, 300), updated_at: new Date().toISOString() }).eq("id", invitation.id);
    return respond({ error: /rate limit/i.test(message) ? "Too many emails were sent in a short time. Wait a minute and try again." : "The invitation email could not be sent. Please try again." }, 502);
  }
}));
