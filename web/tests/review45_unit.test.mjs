// CodeRabbit review #45: the picture-URL check, the paging guard and actionLabel (fixed by hand; the autofix skipped them).
import test from "node:test";
import assert from "node:assert/strict";
import { pageReduce, PAGE_START } from "../src/crm/pagingState.js";
import { actionLabel } from "../src/ownerFormat.js";

test("Next is refused while the shown rows belong to an earlier page (failed load)", () => {
  let s = pageReduce({ ...PAGE_START }, { type: "filters", key: "k" });
  s = pageReduce(s, { type: "request", seq: s.seq });
  s = pageReduce(s, { type: "ok", seq: s.seq, key: "k", data: { rows: [1], next: "c1" } });
  s = pageReduce(s, { type: "next" });                       // page 1 requested
  assert.equal(s.page, 1);
  s = pageReduce(s, { type: "fail", seq: s.seq, key: "k", error: "x" }); // page 1 failed; page 0's rows still shown
  const again = pageReduce(s, { type: "next" });
  assert.equal(again, s, "next must not reuse page 0's cursor");
  s = pageReduce(s, { type: "reload" });
  s = pageReduce(s, { type: "ok", seq: s.seq, key: "k", data: { rows: [2], next: "c2" } });
  assert.equal(pageReduce(s, { type: "next" }).page, 2, "next works again once page 1 has loaded");
});

test("actionLabel tolerates a missing action", () => {
  assert.equal(actionLabel(null), "");
  assert.equal(actionLabel(undefined), "");
  assert.equal(actionLabel("member.added"), "member added");
});

import { isOwnPicture } from "../src/pictureUrl.js";
const ORIGIN = "https://abcd.supabase.co";
const OWN = ORIGIN + "/storage/v1/object/public/brand-assets/user/u1/pic.jpg";
test("own pictures pass the picture-URL check", () => {
  assert.equal(isOwnPicture(OWN, ORIGIN), true);
});
test("a picture URL can't break out of CSS url(\"...\")", () => {
  for (const bad of [
    OWN + '"),url("https://attacker.example/track', OWN + "'),url('https://attacker.example/t", OWN + ")", OWN + "(",
    OWN + "<", OWN + "`", OWN + "\\", OWN + " x", "http://abcd.supabase.co/storage/v1/object/public/brand-assets/user/a.jpg",
    "https://evil.example/storage/v1/object/public/brand-assets/user/a.jpg", ORIGIN + "/storage/v1/object/public/brand-assets/other/a.jpg",
  ]) assert.equal(isOwnPicture(bad, ORIGIN), false, bad);
  assert.equal(isOwnPicture(OWN, null), false);
});
