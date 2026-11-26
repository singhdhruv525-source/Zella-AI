// The Undo toast is a companion of every open dialog (data-dialog-companion): its button is in the dialog's Tab
// order, so an Undo still in its time can be reached from the keyboard while a dialog or sheet is open.
import { test } from "node:test";
import assert from "node:assert/strict";
import { companionControls, trapTab } from "../src/useDialogFocus.js";

let current;   // the document the elements belong to in each test
function el(name) { return { name, offsetParent: {}, focus() { current.activeElement = this; } }; }
const doc = { activeElement: null, querySelectorAll: () => [] };
const save = el("save"), cancel = el("cancel"), undo = el("undo");
const box = { contains: (x) => x === save || x === cancel, focus() {} };
const toast = { querySelectorAll: () => [undo] };
current = doc;
doc.querySelectorAll = (sel) => (sel === "[data-dialog-companion]" ? [toast] : []);
const key = (shiftKey = false) => ({ shiftKey, prevented: false, preventDefault() { this.prevented = true; } });

test("the toast's Undo is a companion control", () => {
  assert.deepEqual(companionControls(doc).map((x) => x.name), ["undo"]);
});

test("Tab goes from the dialog's last control to Undo, then back to the first", () => {
  doc.activeElement = cancel;
  const e = key();
  trapTab(e, box, [save, cancel], doc);
  assert.equal(e.prevented, true);
  assert.equal(doc.activeElement, undo, "whatever the page order, Undo comes next");
  const e2 = key();
  trapTab(e2, box, [save, cancel], doc);
  assert.equal(e2.prevented, true);
  assert.equal(doc.activeElement, save);
});

test("Shift+Tab from the first control reaches Undo; focus on Undo counts as inside", () => {
  doc.activeElement = save;
  trapTab(key(true), box, [save, cancel], doc);
  assert.equal(doc.activeElement, undo);
  trapTab(key(true), box, [save, cancel], doc);
  assert.equal(doc.activeElement, cancel, "from Undo, Shift+Tab goes back into the dialog");
});

test("focus outside the dialog and the toast comes back in", () => {
  doc.activeElement = el("page");
  trapTab(key(), box, [save, cancel], doc);
  assert.equal(doc.activeElement, save);
});

test("with no toast showing the cycle is the dialog's own", () => {
  const empty = { activeElement: cancel, querySelectorAll: () => [] };
  current = empty;
  const e = key();
  trapTab(e, box, [save, cancel], empty);
  assert.equal(e.prevented, true);
  assert.equal(empty.activeElement, save);
  current = doc;
});
