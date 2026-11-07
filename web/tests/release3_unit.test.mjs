// Release 3: the words and rules the workflow screens use (src/workflowLogic.js).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  APPROVAL_KINDS, APPROVAL_METHODS, EXCEPTION_KINDS, MANUAL_EXCEPTION_KINDS, METHOD_LABEL, MILESTONE_KINDS, WORKFLOW_EVENT_LABELS,
  creditBalance, dueText, inspectionProgress, nextYear, workflowError, workflowParts,
} from "../src/workflowLogic.js";

const sql = readFileSync(new URL("../../sql/zella_record_workflows.sql", import.meta.url), "utf8");
const listIn = (constraint) => {
  const m = sql.match(new RegExp(`constraint ${constraint} check \\(\\w+ (?:is null or \\w+ )?in \\(([^)]*)\\)`));
  assert.ok(m, `constraint ${constraint} found`);
  return [...m[1].matchAll(/'([a-z_]+)'/g)].map((x) => x[1]).sort();
};
const keys = (list) => list.map(([k]) => k).sort();

test("the screens offer exactly the kinds the database allows", () => {
  assert.deepEqual(keys(APPROVAL_KINDS), listIn("record_approvals_kind"));
  assert.deepEqual(keys(EXCEPTION_KINDS), listIn("record_exceptions_kind"));
  assert.deepEqual(keys(MILESTONE_KINDS), listIn("record_milestones_kind"));
  // the customer's ways of answering, plus "internal" for the business's own decisions (refunds)
  assert.deepEqual([...keys(APPROVAL_METHODS), "internal"].sort(), listIn("record_approvals_method"));
  assert.equal(METHOD_LABEL.internal, "Decided by the team");
  // a failed inspection opens its own exception: it isn't offered by hand, and the server refuses it by hand too
  assert.ok(!MANUAL_EXCEPTION_KINDS.some(([k]) => k === "inspection_failed"));
  assert.match(sql, /if p_kind = 'inspection_failed' then raise exception 'NOT_VALID'/);
});

test("every kind of history entry the server writes has words", () => {
  const logged = [...new Set([...sql.matchAll(/zella_workflow_log\([^,]+, [^,]+, '([a-z_]+)'/g)].map((m) => m[1]))].sort();
  assert.deepEqual(logged, Object.keys(WORKFLOW_EVENT_LABELS).sort());
});

test("credits, checklists and dates read plainly", () => {
  assert.equal(creditBalance([{ kind: "grant", units: 5 }, { kind: "use", units: 2 }, { kind: "refund", units: 1 }, { kind: "expire", units: 1 }]), 3);
  assert.equal(creditBalance(null), 0);
  assert.deepEqual(inspectionProgress([{ label: "a", result: "pass" }, { label: "b", result: "fail" }, { label: "c" }]),
    { answered: 2, failed: 1, total: 3, complete: false, text: "2 of 3 checked · 1 failed" });
  assert.equal(inspectionProgress([{ label: "a", result: "na" }]).complete, true);
  assert.equal(inspectionProgress([]).complete, false);
  assert.equal(dueText("2026-11-07", "2026-11-07"), "Due today");
  assert.equal(dueText("2026-11-08", "2026-11-07"), "Due tomorrow");
  assert.equal(dueText("2026-11-17", "2026-11-07"), "Due in 10 days");
  assert.equal(dueText("2026-11-06", "2026-11-07"), "1 day overdue");
  assert.equal(dueText("2026-11-01", "2026-11-07"), "6 days overdue");
  assert.equal(nextYear("2026-11-07"), "2027-11-07");
  assert.equal(nextYear("2028-02-29"), "2029-02-28");
});

test("a record type shows the parts its workflow names; dates and problems always", () => {
  assert.deepEqual(workflowParts({ workflow: {} }), { approvals: [], inspection: null, credits: null, milestones: true, exceptions: true });
  const p = workflowParts({ workflow: { approvals: ["estimate"], inspection: { title: "Check", items: ["A"] }, credits: { unit: "visits" } } });
  assert.deepEqual(p.approvals, ["estimate"]);
  assert.equal(p.inspection.title, "Check");
  assert.equal(p.credits.unit, "visits");
  assert.deepEqual(workflowParts(null).approvals, []);
});

test("refusals are explained in plain words", () => {
  for (const [code, want] of [["NOT_AUTHORIZED_APPROVER", /authorized to approve/], ["NO_APPROVER", /who gave the approval/], ["EXPIRED", /expired/],
    ["CHANGED", /changed while you were looking/], ["CHECKLIST_INCOMPLETE", /Answer every item/], ["ALREADY_OPEN", /already an open exception/],
    ["ALREADY_USED", /already used a credit/], ["NO_CREDITS", /enough credits/], ["MORE_THAN_USED", /only give back credits that were used/], ["NOT_OPEN", /finished/], ["BAD_DATE", /Check the date/],
    ["new row violates check constraint \"record_credits_units\"", /whole number/], ["NOT_ALLOWED", /permission/],
    ["Could not find the function public.zella_workflow_due", /isn't available/]]) {
    assert.match(workflowError({ message: code }), want, code);
  }
  assert.doesNotMatch(workflowError({ message: "NOT_CHANGED" }), /changed while you were looking/);
  assert.match(workflowError({ message: "something odd" }), /didn't work/);
});

test("every one of the 28 industry presets has workflow defaults, naming only statuses its record types have", () => {
  const presets = [...sql.matchAll(/^ \('([a-z_]+)', '([a-z_]+)', '(\{.*\})'\)/gm)].map((m) => ({ preset: m[1], type: m[2], config: JSON.parse(m[3]) }));
  assert.equal(new Set(presets.map((p) => p.preset)).size, 28);
  for (const p of presets) {
    for (const k of p.config.approvals ?? []) assert.ok(APPROVAL_KINDS.some(([a]) => a === k), `${p.preset}.${p.type}: ${k}`);
    if (p.config.inspection) assert.ok(p.config.inspection.items.length >= 1 && p.config.inspection.title.length >= 2, `${p.preset}.${p.type} inspection`);
    if (p.config.credits) assert.ok(p.config.credits.unit.length >= 2, `${p.preset}.${p.type} credits`);
  }
});
