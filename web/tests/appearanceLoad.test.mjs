// The appearance module must load: `current` is normalised at import time and calls isOwnPicture, so the check must
// be usable then (a const declared further down would throw "Cannot access before initialization").
import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "vite";

test("appearance.js loads and checks pictures at import time", async () => {
  process.env.VITE_SUPABASE_URL ??= "https://abcd.supabase.co";
  process.env.VITE_SUPABASE_PUBLISHABLE_KEY ??= "fake-test-publishable-key";
  const server = await createServer({ server: { middlewareMode: true }, appType: "custom", logLevel: "silent" });
  try {
    const m = await server.ssrLoadModule("/src/appearance.js");
    assert.equal(typeof m.isOwnPicture, "function");
    assert.equal(m.isOwnPicture("https://abcd.supabase.co/storage/v1/object/public/brand-assets/user/u/p.jpg", "https://abcd.supabase.co"), true);
    assert.equal(m.isOwnPicture('https://abcd.supabase.co/storage/v1/object/public/brand-assets/user/u/p.jpg"),url("x', "https://abcd.supabase.co"), false);
  } finally { await server.close(); }
});
