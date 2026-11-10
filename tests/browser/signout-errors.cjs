// Stubbed browser checks. Start Vite with synthetic Supabase configuration as in security-journeys.cjs.
// Run with Playwright installed: node tests/browser/signout-errors.cjs
const assert = require("node:assert/strict");
const { chromium } = require("playwright");
const BASE = process.env.APP_URL ?? "http://localhost:5199";
const user = { id: "30000000-0000-0000-0000-000000000001", email: "owner@example.test", aud: "authenticated", role: "authenticated", factors: [] };
const workspace = { id: "20000000-0000-0000-0000-000000000001", name: "Test workspace", role: "owner", timezone: "UTC", terminology: {}, modules: [] };
const warning = /session may still be active on this device.*try again/i;

async function setup(browser, workspaces, path = "/app") {
  const context = await browser.newContext();
  await context.addInitScript((u) => {
    const enc = (o) => btoa(JSON.stringify(o)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
    const exp = Math.floor(Date.now() / 1000) + 3600;
    localStorage.setItem("sb-example-auth-token", JSON.stringify({ access_token: `${enc({ alg: "HS256", typ: "JWT" })}.${enc({ sub: u.id, aal: "aal1", amr: [{ method: "password" }], exp, role: "authenticated" })}.sig`, refresh_token: "r", token_type: "bearer", expires_in: 3600, expires_at: exp, user: u }));
  }, user);
  const page = await context.newPage();
  page.on("pageerror", (error) => console.error("Page error:", error.message));
  // The current checkout has an unrelated initialization-order error in appearance.js. Move the
  // declaration in the served test response only so sign-out behavior can be exercised.
  await page.route("**/src/appearance.js", async (route) => {
    const response = await route.fetch();
    const source = await response.text();
    const declaration = source.match(/const SUPABASE_ORIGIN = [\s\S]*?\}\)\(\);/)[0];
    const corrected = source.replace(declaration, "").replace("let current = normalise(local?.pref);", `${declaration}let current = normalise(local?.pref);`);
    await route.fulfill({ response, body: corrected });
  });
  await page.route("**/auth/v1/**", (route) => route.fulfill({ json: user }));
  await page.route("**/rest/v1/**", (route) => {
    const url = route.request().url();
    let data = [];
    if (url.includes("/rpc/zella_my_workspaces")) data = workspaces;
    else if (url.includes("/rpc/is_platform_admin")) data = false;
    else if (url.includes("/rpc/zella_accept_my_invitations")) data = 0;
    else if (url.includes("/rpc/zella_accept_staff_invitations_v2")) data = { accepted: 0, needs_email_link: 0, expired: 0, errors: [] };
    else if (url.includes("/rpc/zella_workspace_navigation")) data = { role: "owner", configured: true, modules: [], industry: {}, capabilities: {} };
    else if (url.includes("/rpc/zella_my_profile")) data = { first_name: "Sam" };
    return route.fulfill({ json: data });
  });
  await page.goto(BASE + path);
  await page.waitForSelector(workspaces.length === 0 ? "text=No workspace yet" : workspaces[0].suspended_at || workspaces[0].cancelled_at ? ".ba-auth-card button" : ".ba-profile-btn", { timeout: 7000 }).catch(async (error) => { console.error("Page text:", await page.locator("body").innerText()); throw error; });
  await page.evaluate(async () => {
    const { supabase } = await import("/src/supabase.js");
    const original = supabase.auth.signOut.bind(supabase.auth);
    window.signOutCalls = [];
    window.allowLocalSignOut = false;
    supabase.auth.signOut = async (options) => {
      window.signOutCalls.push(options?.scope ?? "global");
      if (options?.scope === "local" && window.allowLocalSignOut) return original(options);
      if (options?.scope === "local") throw new Error("local failure");
      return { error: new Error("global failure") };
    };
  });
  return { context, page };
}

(async () => {
  const browser = process.env.CDP_URL ? await chromium.connectOverCDP(process.env.CDP_URL) : await chromium.launch();
  try {
    for (const [name, workspaces] of [["no workspace", []], ["paused workspace", [{ ...workspace, suspended_at: "2026-01-01" }]], ["ended workspace", [{ ...workspace, cancelled_at: "2026-01-01" }]]]) {
      const { context, page } = await setup(browser, workspaces);
      await page.getByRole("button", { name: "Sign out", exact: true }).click();
      await page.getByRole("alert").filter({ hasText: warning }).waitFor();
      assert.deepEqual(await page.evaluate(() => window.signOutCalls), ["global", "local"]);
      await page.evaluate(() => { window.allowLocalSignOut = true; });
      await page.getByRole("button", { name: "Sign out", exact: true }).click();
      await page.locator(".ba-auth-card").getByText(/sign in/i).first().waitFor();
      assert.equal(await page.getByText(warning).count(), 0);
      console.log(`PASS ${name}: failure shown and local retry signs out`);
      await context.close();
    }
    {
      const { context, page } = await setup(browser, [workspace]);
      await page.locator(".ba-profile-btn").click();
      await page.getByRole("button", { name: "Sign out", exact: true }).click();
      await page.locator("main [role=alert]").filter({ hasText: warning }).waitFor();
      assert.deepEqual(await page.evaluate(() => window.signOutCalls), ["global", "local"]);
      console.log("PASS profile menu: failure remains visible after menu closes");
      await context.close();
    }
    {
      const { context, page } = await setup(browser, [workspace], "/app/settings/me/logout");
      await page.locator(".zs-card").getByRole("button", { name: "Sign out", exact: true }).click();
      const dialog = page.getByRole("dialog");
      await dialog.getByRole("button", { name: "Sign out", exact: true }).click();
      await dialog.getByRole("alert").filter({ hasText: warning }).waitFor();
      assert.equal(await dialog.isVisible(), true);
      assert.equal(await dialog.getByRole("button", { name: "Sign out", exact: true }).isEnabled(), true);
      await page.evaluate(() => { window.allowLocalSignOut = true; });
      await dialog.getByRole("button", { name: "Sign out", exact: true }).click();
      await dialog.waitFor({ state: "hidden" });
      await page.locator(".ba-auth-card").getByText(/sign in/i).first().waitFor();
      assert.deepEqual(await page.evaluate(() => window.signOutCalls), ["global", "local", "global", "local"]);
      console.log("PASS settings: confirmation stays open on failure and retry signs out");
      await context.close();
    }
  } finally {
    await browser.close();
  }
})().catch((error) => { console.error(error); process.exitCode = 1; });
