import { test } from "node:test";
import assert from "node:assert/strict";
import { hasUnsavedChanges, stepProgress } from "./wizardProgress.js";

const STEPS = [
  { key: "business" }, { key: "owner" }, { key: "operations" }, { key: "team", optional: true }, { key: "receptionist" },
  { key: "integrations", optional: true }, { key: "automations" }, { key: "crm", optional: true }, { key: "review" },
];
const rows = (over = {}) => [
  { key: "business", ok: true, required: true }, { key: "owner", ok: true, required: true }, { key: "owner", ok: true, required: true },
  { key: "operations", ok: false, required: true }, { key: "team", ok: false }, { key: "receptionist", ok: true },
  { key: "integrations", ok: true }, { key: "automations", ok: true }, { key: "crm", ok: true },
].map((r) => ({ ...r, ...(over[r.key] ?? {}) }));

test("a step that was only visited or skipped is not complete", () => {
  const p = stepProgress(STEPS, rows(), "owner_setup", new Set());
  assert.equal(p.business, "done");
  assert.equal(p.operations, "todo", "hours not saved yet");
  assert.equal(p.integrations, "optional", "always-ok row still needs a save");
  assert.equal(p.automations, "todo");
  assert.equal(p.receptionist, "todo", "has data from the industry but was never saved");
  assert.equal(p.review, "todo");
});

test("saving a step in this session, or server progress past it, marks it done", () => {
  const p = stepProgress(STEPS, rows(), "ai_setup", new Set(["integrations"]));
  assert.equal(p.receptionist, "done");
  assert.equal(p.integrations, "done");
  assert.equal(p.automations, "todo");
});

test("one failing row (documents) keeps the owner step open", () => {
  const r = rows(); r[2] = { ...r[2], ok: false };
  assert.equal(stepProgress(STEPS, r, "testing", new Set()).owner, "todo");
});

test("unsaved changes ignore documents and the invitation, which save on their own", () => {
  const saved = { business: { name: "A" }, documents: [], invitation: null };
  assert.equal(hasUnsavedChanges({ ...saved, documents: [{ id: 1 }], invitation: { status: "sent" } }, saved), false);
  assert.equal(hasUnsavedChanges({ ...saved, business: { name: "B" } }, saved), true);
  assert.equal(hasUnsavedChanges(saved, null), false);
});
