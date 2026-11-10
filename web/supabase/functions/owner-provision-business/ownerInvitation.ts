// Owner invitations share business_invitations with staff invitations (role column). Every owner lookup must filter
// on role = 'owner', or a newer staff invitation is taken for the owner's (finishing setup would email it).
import type { SupabaseClient } from "@supabase/supabase-js";

type Json = Record<string, unknown>;

export type OwnerInvitation = { id: string; email: string; owner_name: string | null; status: string };

export const OPEN_OWNER_INVITATION = ["pending", "failed", "expired"];

// The newest owner invitation that hasn't been cancelled.
export function latestOwnerInvitation(admin: SupabaseClient, businessId: string, columns: string) {
  return admin
    .from("business_invitations")
    .select(columns)
    .eq("business_id", businessId)
    .eq("role", "owner")
    .neq("status", "revoked")
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle<OwnerInvitation>();
}

// An owner invitation only moves out of an open state. A cancel or acceptance that lands while the email is being
// sent wins: the late write matches no row and the caller is told, instead of reopening a closed invitation.
export async function moveOwnerInvitation(admin: SupabaseClient, id: string, patch: Json): Promise<boolean> {
  const { data, error } = await admin
    .from("business_invitations")
    .update(patch)
    .eq("id", id)
    .eq("role", "owner")
    .in("status", OPEN_OWNER_INVITATION)
    .select("id");
  if (error) throw error;
  return (data ?? []).length > 0;
}
