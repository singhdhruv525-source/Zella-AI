// People tab rules mirrored from the server, for showing state only (the server decides). Pure:
// web/tests/businessPeople.test.mjs.
export const RESEND_COOLDOWN_MINUTES = 5;   // detail.ts RESEND_COOLDOWN_MINUTES

// When the owner's invitation can be sent again, or null when it can now.
export function resendAt(invitedAt, now) {
  if (!invitedAt) return null;
  const at = new Date(new Date(invitedAt).getTime() + RESEND_COOLDOWN_MINUTES * 60000);
  return at > now ? at : null;
}
