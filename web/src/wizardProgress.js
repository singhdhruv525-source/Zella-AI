// Setup wizard progress, worked out from what is SAVED (never from which step is on screen), so a step that was only
// looked at or skipped is not shown as done.

// Server progress, in order (businesses.onboarding_status). A save of a step moves it forward.
export const STATUS_ORDER = ["started", "business_info", "owner_setup", "industry_setup", "ai_setup", "communications_setup",
  "automation_setup", "testing", "ready", "active"];
// The setup wizard's steps, in order (CreateBusinessWizard.jsx). Essentials first (business, owner, hours), then what
// the AI and the phone need, then optional fine tuning.
export const WIZARD_STEPS = [
  { key: "business", label: "Business" },
  { key: "owner", label: "Owner & verification" },
  { key: "operations", label: "Hours & services" },
  { key: "team", label: "Team", optional: true },
  { key: "receptionist", label: "AI receptionist" },
  { key: "integrations", label: "Phone & integrations", optional: true },
  { key: "automations", label: "Automations" },
  { key: "crm", label: "CRM setup", optional: true },
  { key: "plan", label: "Plan & pricing" },
  { key: "review", label: "Review" },
];

// Where a saved draft reopens: the step after the last one that moved setup forward. Any other status reopens at the
// first step. The stage labels on the Businesses list name this step (ownerFormat.js).
export const RESUME_AT = {
  started: "business",
  business_info: "owner",
  owner_setup: "operations",
  industry_setup: "team",
  ai_setup: "integrations",
  communications_setup: "automations",
  automation_setup: "crm",
  testing: "review",
  ready: "review",
  active: "review",
};
export const resumeStep = (status) => WIZARD_STEPS.find((s) => s.key === (RESUME_AT[status] ?? WIZARD_STEPS[0].key));

const rank = (status) => Math.max(0, STATUS_ORDER.indexOf(status));

// The status a step's save moves setup to (index.ts / onboarding.ts advance()).
const SAVED_AT = { receptionist: "ai_setup", integrations: "communications_setup", automations: "automation_setup", review: "testing" };

// rows: the review rows ({ key, ok, required }) computed from saved data. savedKeys: steps saved in this session.
// Returns { [stepKey]: "done" | "todo" | "optional" }.
export function stepProgress(steps, rows, status, savedKeys) {
  const out = {};
  for (const step of steps) {
    const mine = rows.filter((r) => r.key === step.key);
    const dataOk = mine.length > 0 && mine.every((r) => r.ok);
    const saved = savedKeys.has(step.key) || (SAVED_AT[step.key] && rank(status) >= rank(SAVED_AT[step.key]));
    let done;
    if (step.key === "review") done = Boolean(saved);
    else if (SAVED_AT[step.key]) done = Boolean(saved) && (mine.length === 0 || dataOk);
    else done = dataOk;
    out[step.key] = done ? "done" : step.optional ? "optional" : "todo";
  }
  return out;
}

// Unsaved changes: compare what is on screen with what was last saved. Documents upload straight away, so they
// never count as unsaved.
const comparable = (setup) => JSON.stringify({ ...setup, documents: undefined, invitation: undefined });
export const hasUnsavedChanges = (setup, saved) => Boolean(saved) && comparable(setup) !== comparable(saved);
