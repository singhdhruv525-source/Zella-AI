import test from "node:test";
import assert from "node:assert/strict";
import { FIT, fitOptions, fitPlan } from "./floorPlanFit.js";

const box = (x, y, w = 70, h = 70) => ({ x, y, w, h });

test("no tables or no width: nothing to fit", () => {
  assert.equal(fitPlan([], 800, 560), null);
  assert.equal(fitPlan([box(50, 50)], 0, 560), null);
});

test("eight tables spread over the room: cropped to their box, no large empty bands", () => {
  const tables = [18, 38, 62, 82].flatMap((x) => [box(x, 25), box(x, 68)]);
  const f = fitPlan(tables, 1000, 560);
  // the drawn plan is the tables' box plus the padding, not the whole 16:9 room
  assert.ok(f.boxHeight < (1000 * 9) / 16, `height ${f.boxHeight}`);
  assert.ok(f.offsetY <= FIT.pad + 1);
  assert.ok(f.height * f.scale + 2 * FIT.pad <= f.boxHeight + 1);
  assert.equal(f.scrolls, false);
});

test("relative layout kept: one scale for both axes", () => {
  const f = fitPlan([box(10, 10), box(90, 90)], 900, 560);
  assert.ok(f.scale > 0);
  assert.equal(typeof f.scale, "number");
});

test("three tables are scaled up a little, never past the cap", () => {
  const f = fitPlan([box(40, 50, 58, 58), box(50, 50, 58, 58), box(60, 50, 58, 58)], 900, 560);
  assert.equal(f.scale, FIT.maxScale);
  assert.ok(f.boxHeight >= FIT.minHeight);
});

test("a big plan never shrinks below the readable minimum; it scrolls instead", () => {
  const many = Array.from({ length: 40 }, (_, i) => box(5 + (i % 10) * 10, 8 + Math.floor(i / 10) * 28, 96, 96));
  const f = fitPlan(many, 600, 320);
  assert.equal(f.scale, FIT.minScale);
  assert.ok(14 * f.scale >= 12, "14px labels stay at least 12px");
  assert.ok(58 * f.scale >= 44, "the smallest table stays a 44px tap target");
  assert.equal(f.scrolls, true);
  assert.ok(f.boxHeight <= 320);
});

test("twenty four tables on a desktop width fit without scrolling", () => {
  const tables = Array.from({ length: 24 }, (_, i) => box(8 + (i % 6) * 16.8, 12 + Math.floor(i / 6) * 25, 70, 70));
  const f = fitPlan(tables, 900, 560);
  assert.equal(f.scrolls, false);
  assert.ok(f.scale >= FIT.minScale);
});

test("eight tables are never drawn larger than life; three may be", () => {
  const eight = [18, 38, 62, 82].flatMap((x) => [box(x, 25), box(x, 68)]);
  assert.ok(fitPlan(eight, 744, 360, fitOptions(8)).scale <= 1);
  assert.ok(fitPlan(eight, 744, 360, fitOptions(8)).boxHeight <= 360);
  const three = [box(30, 45), box(50, 45), box(70, 45)];
  assert.ok(fitPlan(three, 744, 360, fitOptions(3)).scale > 1);
});

test("at the height cap the result depends only on the width given, so it settles in one state", () => {
  // a plan near the 480px cap at the scale floor: the same width always gives the same answer
  const many = Array.from({ length: 24 }, (_, i) => box(8 + (i % 6) * 16.8, 12 + Math.floor(i / 6) * 25, 96, 96));
  for (const width of [743, 760]) {
    const a = fitPlan(many, width, 480, fitOptions(24));
    const b = fitPlan(many, width, 480, fitOptions(24));
    assert.deepEqual(a, b);
    assert.ok(a.boxHeight <= 480);
    // scrolling is decided against the box the plan was given, never against itself
    assert.equal(a.scrolls, a.width * a.scale + 2 * FIT.pad > width + 0.5 || a.height * a.scale + 2 * FIT.pad > a.boxHeight + 0.5);
  }
});
