// Support actions on one member of a business, from the admin Business page (UI-06 parts c and d). Pure guards here;
// the actions are in detail.ts. Lane E defaults, owner can change; both need the owner's approval before deploy.
//
// Permission: businesses.manage. A fresh admin code (ACC-19) is not built yet, so each action needs a typed reason
// instead; when ACC-19 lands, its step up check is added in front of these.
export const MEMBER_SUPPORT_PERMISSION = "businesses.manage";
export const MEMBER_REASON = { min: 10, max: 300 };
export const MEMBER_STATUSES = ["active", "suspended"] as const;

export type Member = { user_id: string; role: string; status: string };

export function reasonProblem(reason: string): string | null {
  if (reason.length < MEMBER_REASON.min) return `Give a reason of at least ${MEMBER_REASON.min} characters`;
  if (reason.length > MEMBER_REASON.max) return `Keep the reason under ${MEMBER_REASON.max} characters`;
  return null;
}

// Why a member's status can't change to `next`, or null when it can. The business must always keep one active owner.
export function statusProblem(members: Member[], userId: string, next: string): { message: string; status: number } | null {
  if (!(MEMBER_STATUSES as readonly string[]).includes(next)) return { message: "Choose active or suspended", status: 400 };
  const member = members.find((m) => m.user_id === userId);
  if (!member) return { message: "This person isn't a member of this business", status: 404 };
  if (member.status === next) return { message: next === "active" ? "This member is already active" : "This member is already deactivated", status: 409 };
  if (next === "active" && member.status !== "suspended") return { message: "Only a deactivated member can be reactivated here", status: 409 };
  if (next === "suspended" && member.role === "owner" && member.status === "active") {
    const owners = members.filter((m) => m.role === "owner" && m.status === "active").length;
    if (owners <= 1) return { message: "This is the business's only active owner, so they can't be deactivated", status: 409 };
  }
  return null;
}
