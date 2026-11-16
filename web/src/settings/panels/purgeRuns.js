// Purge runs (Data retention): words for each state and what this admin is offered. Pure: tested in
// tests/purgeRuns.test.mjs. The database decides again whatever is offered here.

export const RUN_STATUS = {
  requested: ["Waiting for approvals", "warning"], approved: ["Approved by two people", "accent"], running: ["Running", "accent"],
  files_pending: ["Removing files", "accent"], done: ["Done", "success"], failed: ["Not finished", "danger"], cancelled: ["Cancelled", ""],
};

export function runActions(run, { you, owner, manage, purgeEnabled }) {
  const approvers = [run?.owner_approved_by, run?.second_approved_by].filter(Boolean);
  const mine = Boolean(you) && approvers.includes(you);
  const open = run?.status === "requested";
  // an owner fills the owner place; anyone with security.manage fills the other one
  const slot = owner ? !run?.owner_approved_by || !run?.second_approved_by : !run?.second_approved_by;
  return {
    approve: Boolean(manage) && open && !mine && slot,
    run: Boolean(manage) && run?.status === "approved" && mine && Boolean(purgeEnabled),
    cancel: Boolean(manage) && (open || run?.status === "approved"),
  };
}
