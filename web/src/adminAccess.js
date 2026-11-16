// Users & access: what the page says after an admin's access changes (ACC-18).

// After a removal or role change, owner-provision-business signs the person out on every device and returns how many
// sessions ended (sessionsEnded), or null with sessionsWarning when that failed.
export function signedOutText(result) {
  const n = result?.sessionsEnded;
  if (n === null || n === undefined) return result?.sessionsWarning ?? "";
  if (n === 0) return "They had no signed in devices.";
  return `They were signed out on ${n === 1 ? "1 device" : `${n} devices`}.`;
}

export const SIGNED_OUT_EVERYWHERE = "They will be signed out on every device.";
