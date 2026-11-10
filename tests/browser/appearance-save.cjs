// Appearance saving against STUBBED Supabase Auth and Storage (no real account is changed).
// Needs the app:  cd web && VITE_SUPABASE_URL=https://example.supabase.co npx vite --port 5199
// Run:  node tests/browser/appearance-save.cjs
// Covers: preview vs saved status, one save for rapid changes, failure shown with Try again (look kept on this
// device), the other app's look kept from the account as it is now (not the tab's old copy), and an uploaded
// picture deleted only after the account saved the replacement or removal.
const { chromium } = require("playwright");
const BASE = process.env.APP_URL ?? "http://localhost:5199";
const B1 = "20000000-0000-0000-0000-000000000001";
const PIC = (n) => `https://example.supabase.co/storage/v1/object/public/brand-assets/user/30000000-0000-0000-0000-000000000001/background-${n}.webp`;
const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGM4EaCBFTEMLQkAaplQAc/OcKAAAAAASUVORK5CYII=", "base64");
const results = [];
const check = (name, ok, detail = "") => { results.push(ok); console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? " - " + detail : ""}`); };

async function open(b, account) {
  const user = { id: "30000000-0000-0000-0000-000000000001", email: "owner@glow.test", aud: "authenticated", role: "authenticated", factors: [], user_metadata: { zella_appearance: structuredClone(account.meta) } };
  const ctx = await b.newContext({ viewport: { width: 1300, height: 950 } });
  await ctx.addInitScript((u) => {
    const enc = (o) => btoa(JSON.stringify(o)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
    const exp = Math.floor(Date.now() / 1000) + 3600;
    localStorage.setItem("sb-example-auth-token", JSON.stringify({ access_token: `${enc({ alg: "HS256" })}.${enc({ sub: u.id, aal: "aal1", exp, role: "authenticated" })}.sig`, refresh_token: "r", token_type: "bearer", expires_in: 3600, expires_at: exp, user: u }));
  }, user);
  const p = await ctx.newPage(); p.setDefaultTimeout(8000);
  const errors = []; p.on("pageerror", (e) => errors.push(e.message));
  account.puts = []; account.deletes = [];
  // Playwright tries the most recently added route first: the catch-all goes first, /user after it
  await p.route("**/auth/v1/**", (r) => r.fulfill({ json: { currentLevel: "aal1", nextLevel: "aal1" } }));
  await p.route("**/auth/v1/user**", async (r) => {
    if (r.request().method() === "PUT") {
      const body = JSON.parse(r.request().postData());
      account.puts.push(body.data.zella_appearance);
      if (account.fail) return r.fulfill({ status: 500, json: { message: "Database error saving user", code: 500 } });
      account.meta = body.data.zella_appearance;
    }
    return r.fulfill({ json: { ...user, user_metadata: { zella_appearance: structuredClone(account.meta) } } });
  });
  await p.route("**/storage/v1/**", (r) => {
    const m = r.request().method();
    if (m === "DELETE" || r.request().url().includes("/object/brand-assets") && m === "DELETE") account.deletes.push(r.request().postData());
    if (m === "DELETE") return r.fulfill({ json: [] });
    return r.fulfill({ json: { Key: "brand-assets/user/x/background-new.webp", Id: "x" } });
  });
  await p.route("**/rest/v1/**", (r) => {
    const u = decodeURIComponent(r.request().url());
    if (!u.includes("/rpc/")) return r.fulfill({ json: [] });
    const fn = u.split("/rpc/")[1].split("?")[0];
    if (fn === "zella_my_workspaces") return r.fulfill({ json: [{ id: B1, name: "Glow Salon", role: "owner", is_active: true, onboarding_status: "active", terminology: {}, modules: [] }] });
    if (fn === "zella_workspace_navigation") return r.fulfill({ json: { role: "owner", configured: true, modules: [] } });
    if (fn.startsWith("zella_accept")) return r.fulfill({ json: fn.endsWith("v2") ? { accepted: 0, needs_email_link: 0, errors: [] } : 0 });
    return r.fulfill({ json: null });
  });
  await p.goto(BASE + "/app/settings/me/appearance");
  await p.waitForSelector(".zs-look-grid"); await p.waitForTimeout(700);
  return { ctx, p, errors };
}
const theme = (p) => p.evaluate(() => document.documentElement.dataset.zellaTheme);
const stateText = (p) => p.locator(".zs-page").innerText();

(async () => {
  const b = await chromium.launch();

  // 1. preview, then saved; the admin look comes from the account as it is now
  {
    const account = { meta: { admin: { theme: "classic", background: "lounge", dim: 35 }, crm: { theme: "classic", background: "lounge", dim: 35 } } };
    const { ctx, p, errors } = await open(b, account);
    account.meta.admin = { theme: "glass", background: "aurora", dim: 10 };   // changed meanwhile in the admin dashboard
    await p.click('button[role=radio]:has-text("Glass")');
    check("change shows at once (preview) and says it is saving", (await theme(p)) === "glass" && /Saving in a moment|Saving to your account/.test(await stateText(p)));
    await p.waitForTimeout(1200);
    check("then says saved to the account", /Saved to your account/.test(await stateText(p)));
    const put = account.puts.at(-1);
    check("the CRM look is saved and the admin look written back as the account has it now", put?.crm?.theme === "glass" && put?.admin?.background === "aurora", JSON.stringify(put));
    // rapid changes: one save
    const before = account.puts.length;
    await p.click('button[role=radio]:has-text("Classic")'); await p.click('button[role=radio]:has-text("Glass")'); await p.click('button[role=radio]:has-text("Always full")');
    await p.waitForTimeout(1300);
    check("three quick changes are saved once, with the last values", account.puts.length === before + 1 && account.puts.at(-1).crm.sidebar === "full" && account.puts.at(-1).crm.theme === "glass");
    check("no page errors", errors.length === 0, errors.join("; "));
    await ctx.close();
  }

  // 2. failure: shown, look kept here, Try again saves; leaving the page while unsaved asks
  {
    const account = { meta: { crm: { theme: "classic", background: "lounge", dim: 35 } }, fail: true };
    const { ctx, p, errors } = await open(b, account);
    await p.click('button[role=radio]:has-text("Glass")'); await p.waitForTimeout(1300);
    const t = await stateText(p);
    check("failed save is shown (no 'saved'), look kept on this device", /wasn't saved to your account/.test(t) && !/Saved to your account/.test(t) && (await theme(p)) === "glass");
    // an unsaved change is remembered in this browser, so it is sent again after a reload (instead of being lost)
    check("the unsaved change is kept for sending again after a reload", await p.evaluate(() => JSON.parse(localStorage.getItem("zella.appearance.crm") || "{}").unsynced === true));
    account.fail = false;
    await p.click('button:has-text("Try again")'); await p.waitForTimeout(1300);
    check("Try again saves and says so", /Saved to your account/.test(await stateText(p)) && account.meta.crm.theme === "glass");
    check("no page errors", errors.length === 0, errors.join("; "));
    await ctx.close();
  }

  // 3. replacing a picture: the old one is deleted only after the account saved the new one
  {
    const account = { meta: { crm: { theme: "glass", background: "custom", customUrl: PIC("old"), dim: 35 } }, fail: true };
    const { ctx, p, errors } = await open(b, account);
    await p.setInputFiles('input[type=file]', { name: "beach.png", mimeType: "image/png", buffer: PNG });
    await p.waitForTimeout(1800);
    if (process.env.DEBUG) console.log(account.puts.length, account.deletes, (await stateText(p)).slice(0, 900));
    check("new picture uploaded, save failed: the old picture is NOT deleted", account.puts.length >= 1 && account.deletes.length === 0 && /wasn't saved/.test(await stateText(p)), `deletes ${account.deletes.length}`);
    account.fail = false;
    await p.click('button:has-text("Try again")'); await p.waitForTimeout(1500);
    check("after the account saved the new picture, the old one is deleted", account.deletes.length === 1 && String(account.deletes[0]).includes("background-old.webp") && account.meta.crm.customUrl !== PIC("old"), String(account.deletes[0]));
    // removing while the save fails keeps the file
    account.fail = true;
    await p.click('button:has-text("Remove my picture")'); await p.waitForTimeout(1300);
    check("remove with a failing save: nothing deleted yet", account.deletes.length === 1);
    check("no page errors", errors.length === 0, errors.join("; "));
    await ctx.close();
  }

  // 3b. a failed save from outside the settings page (the sidebar's dock button) is shown there too
  {
    const account = { meta: { crm: { theme: "classic", background: "lounge", dim: 35 } }, fail: true };
    const { ctx, p } = await open(b, account);
    await p.evaluate(async () => { const s = await import("/src/router.js"); s.navigate("/app"); });
    await p.waitForTimeout(600);
    await p.locator(".zella-dock-toggle").first().click();   // the sidebar's dock button
    await p.waitForTimeout(1300);
    const notice = p.locator(".zella-save-notice");
    check("outside settings, a failed look save shows a notice with Try again", (await notice.count()) === 1 && /wasn't saved/.test(await notice.innerText()));
    account.fail = false;
    await notice.locator("button").click(); await p.waitForTimeout(1300);
    check("Try again from the notice saves and the notice goes away", (await notice.count()) === 0 && (account.meta.crm.sidebar === "compact" || account.meta.crm.sidebar === "full"));
    await ctx.close();
  }

  // 4. signing out while a change waits: nothing is written afterwards (no save for a signed-out or other account)
  {
    const account = { meta: { crm: { theme: "classic", background: "lounge", dim: 35 } } };
    const { ctx, p, errors } = await open(b, account);
    await p.click('button[role=radio]:has-text("Glass")');
    await p.evaluate(async () => { const s = (await import("/src/supabase.js")).supabase; await s.auth.signOut({ scope: "local" }); });
    await p.waitForTimeout(1300);
    check("sign-out before the save runs: nothing written, look back to default", account.puts.length === 0
      && (await p.evaluate(() => document.documentElement.dataset.zellaTheme)) !== "glass", `puts ${account.puts.length}`);   // back to the default look (whatever it is)
    check("no page errors", errors.length === 0, errors.join("; "));
    await ctx.close();
  }

  await b.close();
  const failed = results.filter((x) => !x).length;
  console.log(failed ? `${failed} FAILED of ${results.length}` : `ALL ${results.length} PASSED`);
  process.exit(failed ? 1 : 0);
})();
