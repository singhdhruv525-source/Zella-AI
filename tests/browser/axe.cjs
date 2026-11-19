// axe-core for the browser crawls (PLT-06). It is pinned in tests/browser/package.json; install it once with
//   npm ci --prefix tests/browser
// AXE=/path/to/axe.min.js uses another copy. A crawl that wants axe and can't find it stops with this message
// instead of quietly reporting no accessibility results.
const fs = require("fs");

const INSTALL = "axe-core is not installed. Run: npm ci --prefix tests/browser (or set AXE=/path/to/axe.min.js)";

function axePath() {
  if (process.env.AXE) return process.env.AXE;
  return require.resolve("axe-core/axe.min.js", { paths: [__dirname] });
}

// The axe-core source to inject into each page. Throws with INSTALL when it is missing.
function loadAxe() {
  let file;
  try { file = axePath(); } catch { throw new Error(INSTALL); }
  try { return fs.readFileSync(file, "utf8"); } catch { throw new Error(`${INSTALL}; could not read ${file}`); }
}

// Serious and critical WCAG 2.1 AA problems on the page. When axe can't run there, one "axe-failed" row says why,
// so a page is never counted as clean because the scan didn't happen.
async function runAxe(page, source) {
  await page.addScriptTag({ content: source }).catch(() => {});
  return page.evaluate(async () => {
    if (!window.axe) return [{ id: "axe-failed", impact: "critical", n: 1, sample: ["axe did not load on this page"] }];
    const r = await window.axe.run(document, { runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"] }, resultTypes: ["violations"] });
    return r.violations.filter((v) => v.impact === "serious" || v.impact === "critical").map((v) => ({ id: v.id, impact: v.impact, n: v.nodes.length,
      sample: v.nodes.slice(0, 2).map((n) => `${n.target.join(" ")} :: ${(n.failureSummary ?? "").split("\n").slice(-1)[0].slice(0, 120)}`) }));
  }).catch((e) => [{ id: "axe-failed", impact: "critical", n: 1, sample: [String(e?.message ?? e).slice(0, 200)] }]);
}

module.exports = { loadAxe, runAxe, INSTALL };
