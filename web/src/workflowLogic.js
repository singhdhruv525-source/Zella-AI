// Release 3: words and rules for approvals, milestones, inspections, exceptions and credits on records
// (sql/zella_record_workflows.sql). The server decides who may do what; this only explains it.
// Unit tests: web/tests/release3_unit.test.mjs. Amounts use BusinessMoney's showMoney / toMinor.

export const APPROVAL_KINDS = [
  ["estimate", "Estimate or quote"], ["additional_work", "Additional work"], ["change_order", "Change order"], ["cost", "Cost approval"],
  ["contract", "Contract or agreement"], ["engagement", "Engagement"], ["treatment_plan", "Treatment plan"], ["endorsement", "Policy change"],
  ["refund", "Refund"], ["other", "Other"],
];
export const APPROVAL_LABEL = Object.fromEntries(APPROVAL_KINDS);
// how the customer gave their answer (a refund is the business's own decision: "internal")
export const APPROVAL_METHODS = [["in_person", "In person"], ["phone", "By phone"], ["email", "By email"], ["text", "By text"], ["signed_form", "Signed form"]];
export const METHOD_LABEL = { ...Object.fromEntries(APPROVAL_METHODS), internal: "Decided by the team" };
export const APPROVAL_STATUS = { requested: ["Waiting", "warning"], approved: ["Approved", "success"], declined: ["Declined", ""], withdrawn: ["Withdrawn", ""] };

export const MILESTONE_KINDS = [["milestone", "Milestone"], ["deadline", "Deadline"], ["renewal", "Renewal"], ["payment_due", "Payment due"], ["delivery", "Delivery"], ["follow_up", "Follow-up"]];
export const MILESTONE_LABEL = Object.fromEntries(MILESTONE_KINDS);

export const EXCEPTION_KINDS = [
  ["waiting_parts", "Waiting on parts or materials"], ["waiting_customer", "Waiting on the customer"], ["waiting_supplier", "Waiting on a supplier or third party"],
  ["delayed", "Delayed"], ["weather", "Weather"], ["damaged", "Damaged"], ["disputed", "Disputed"], ["delivery_issue", "Delivery problem"],
  ["warranty", "Warranty or comeback"], ["safety", "Safety concern"], ["inspection_failed", "Inspection failed"], ["other", "Other"],
];
export const EXCEPTION_LABEL = Object.fromEntries(EXCEPTION_KINDS);
// opened by hand (a failed inspection opens its own)
export const MANUAL_EXCEPTION_KINDS = EXCEPTION_KINDS.filter(([k]) => k !== "inspection_failed");

// how these show in a record's history (crm_record_events.kind)
export const WORKFLOW_EVENT_LABELS = { approval: "Approval", milestone: "Date", inspection: "Inspection", exception: "Problem", credit: "Credits" };

export const INSPECTION_RESULTS = [["pass", "Pass"], ["fail", "Fail"], ["na", "N/A"]];

// a package's balance from its ledger
export function creditBalance(entries) {
  return (entries ?? []).reduce((sum, e) => sum + (["grant", "refund"].includes(e.kind) ? e.units : -e.units), 0);
}

// "2 of 6 checked · 1 failed"
export function inspectionProgress(items) {
  const list = Array.isArray(items) ? items : [];
  const answered = list.filter((i) => i.result).length;
  const failed = list.filter((i) => i.result === "fail").length;
  return { answered, failed, total: list.length, complete: list.length > 0 && answered === list.length,
    text: list.length ? `${answered} of ${list.length} checked${failed ? ` · ${failed} failed` : ""}` : "" };
}

// due dates read plainly against today (both YYYY-MM-DD)
export function dueText(dueOn, today) {
  if (!dueOn) return "";
  const days = Math.round((Date.parse(`${dueOn}T00:00:00Z`) - Date.parse(`${today}T00:00:00Z`)) / 86400000);
  if (days < -1) return `${-days} days overdue`;
  if (days === -1) return "1 day overdue";
  if (days === 0) return "Due today";
  if (days === 1) return "Due tomorrow";
  return `Due in ${days} days`;
}
// the same day a year later, for rolling a renewal forward (29 Feb → 28 Feb)
export function nextYear(day) {
  const [y, m, d] = String(day).split("-").map(Number);
  const last = new Date(Date.UTC(y + 1, m, 0)).getUTCDate();
  return `${y + 1}-${String(m).padStart(2, "0")}-${String(Math.min(d, last)).padStart(2, "0")}`;
}

// which parts of the workflow a record type shows (milestones and exceptions always)
export function workflowParts(type) {
  const w = type?.workflow ?? {};
  return { approvals: Array.isArray(w.approvals) ? w.approvals : [], inspection: w.inspection ?? null, credits: w.credits ?? null, milestones: true, exceptions: true };
}

const ERRORS = [
  [/NOT_AUTHORIZED_APPROVER/, () => "That person isn't the customer and isn't authorized to approve for them. Add them under People & consent with the \"approve\" permission, verified, first."],
  [/NO_APPROVER/, () => "Choose who gave the approval."],
  [/EXPIRED/, () => "This approval request has expired. Withdraw it and ask again."],
  [/\bCHANGED\b/, () => "This changed while you were looking at it, so nothing was done. Check it as it is now and try again."],
  [/CHECKLIST_INCOMPLETE/, () => "Answer every item (pass, fail or N/A) before finishing."],
  [/ALREADY_OPEN/, () => "There's already an open exception of that kind on this record. Resolve it first."],
  [/ALREADY_USED/, () => "That visit has already used a credit from this package."],
  [/NO_CREDITS/, () => "There aren't enough credits left for that."],
  [/MORE_THAN_USED/, () => "You can only give back credits that were used. To add new ones, ask a manager."],
  [/NOT_OPEN/, () => "This package is finished, so it can't be used."],
  [/BAD_DATE/, () => "Check the date: it can't be in the past, and a renewal's next date must come after this one."],
  [/record_approvals_title_len|record_milestones_title_len|record_inspections_title_len/, () => "Give it a name (2 to 120 characters)."],
  [/record_approvals_amount/, () => "The amount must be more than zero."],
  [/record_credits_units/, () => "Use a whole number from 1 to 1,000."],
  [/NOT_VALID/, () => "Something here isn't valid for this record. Check the choices and try again."],
  [/NOT_FOUND/, () => "That item has changed or was removed. Refresh and try again."],
  [/NOT_ALLOWED|permission denied|42501/, () => "You don't have permission to do that here."],
  [/MFA_REQUIRED/, () => "Enter the code from your authenticator app first: sign out and sign in again."],
  [/failed to fetch|network|load failed/i, () => "Couldn't reach Zella. Nothing was changed; try again."],
  [/zella_approval|zella_milestone|zella_inspection|zella_exception|zella_credit|zella_workflow|record_approvals|record_milestones|schema cache|Could not find the function/,
    () => "This isn't available on this workspace yet. Ask the Zella Voice team."],
];
export function workflowError(error) {
  const text = `${error?.message ?? ""} ${error?.code ?? ""}`;
  for (const [re, msg] of ERRORS) if (re.test(text)) return msg(error);
  return "That didn't work. Try again, or contact Zella Voice support if it keeps happening.";
}

// The workflow editor's form, from a type's saved workflow setting.
export function workflowForm(w) {
  return {
    kinds: Array.isArray(w?.approvals) ? w.approvals : [], inspect: Boolean(w?.inspection), title: w?.inspection?.title ?? "Checklist",
    items: (w?.inspection?.items ?? []).join("\n"), credits: Boolean(w?.credits), unit: w?.credits?.unit ?? "sessions",
  };
}

// Merge a newer saved setting into an open editor's form, field by field. `synced` is the form as it last matched the
// server (what was loaded, or what was just submitted); `after` is the newer form from the server. A field still equal
// to `synced` (not edited since) takes the server's value, including any tidying the server did; a field edited since
// keeps the unsaved value.
export function reconcileWorkflowForm(form, synced, after) {
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  return Object.fromEntries(Object.keys(after).map((k) => [k, same(form[k], synced[k]) ? after[k] : form[k]]));
}
