// When a business is live for its automations (BIZ-07), and what status a saved automation gets. Pure: live_test.ts.
//
// Live means setup finished and switched on by going live (onboarding_status "active"), not suspended, not cancelled.
// "is_active" alone is not enough: it is already true while a business is being tested after setup.
//
// The new rule starts real messages (turning an automation on for a live business starts it at once), so it is behind
// a switch the owner turns on with the deploy: the secret ZELLA_AUTOMATIONS_START_ON_SAVE = "on". Until then every
// save behaves exactly as before this change.
export const START_ON_SAVE_SWITCH = "ZELLA_AUTOMATIONS_START_ON_SAVE";
export const startOnSave = (value: string | undefined | null) => (value ?? "").trim().toLowerCase() === "on";

export type LiveBusiness = {
  onboarding_status?: string | null;
  is_active?: boolean | null;
  suspended_at?: string | null;
  cancelled_at?: string | null;
};

export function liveFor(b: LiveBusiness): boolean {
  return b.onboarding_status === "active" && !b.suspended_at && !b.cancelled_at;
}

export type Saved = { status: "active" | "paused" | "disabled"; pausedBySuspension: boolean };

// The status a save gives one automation.
//   kind "standard": the ten standard automations. Before the switch, an enabled one stayed active only if it already
//     was, otherwise it waited as paused (and stayed paused after go live: the BIZ-07 bug).
//   kind "rule": the industry's rules. Before the switch, an enabled one was active whenever is_active was true, which
//     includes businesses still being tested.
// With the switch on: an enabled automation of a live business is active; of a business that went live and is now
// suspended, paused and flagged paused_by_suspension, so reactivating restarts it (the lifecycle trigger does that);
// of a business not live yet, paused (going live activates it: zella_request_activation).
export function savedStatus(o: {
  kind: "standard" | "rule";
  enabled: boolean;
  current: string | null | undefined;
  business: LiveBusiness;
  switchOn: boolean;
}): Saved {
  if (!o.enabled) return { status: "disabled", pausedBySuspension: false };
  if (!o.switchOn) {
    if (o.kind === "rule") return { status: o.business.is_active === true ? "active" : "paused", pausedBySuspension: false };
    return { status: o.current === "active" ? "active" : "paused", pausedBySuspension: false };
  }
  if (liveFor(o.business)) return { status: "active", pausedBySuspension: false };
  const wentLive = o.business.onboarding_status === "active" && !o.business.cancelled_at;
  if (wentLive && o.business.suspended_at) return { status: "paused", pausedBySuspension: true };
  return { status: "paused", pausedBySuspension: false };
}
