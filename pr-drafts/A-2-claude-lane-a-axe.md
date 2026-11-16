Install axe-core for the crawls and stop loudly when it is missing (PLT-06)
base: main

## What and why

**PLT-06.** The crawl scripts were wired for axe-core but it was installed nowhere, so glitch-sweep reported `axe: null` and page-review threw on load.

- `tests/browser/package.json` + lock: axe-core **4.14.0**, a dev tool for the crawls only (never deployed). 4.14.1 was published today, so this pins the newest release older than two weeks.
- `tests/browser/axe.cjs`: loads it (or `AXE=/path`) and runs the WCAG 2.1 AA scan, keeping serious and critical findings. A page where the scan can't run reports `axe-failed`, never an empty list.
- `glitch-sweep.cjs` and `page-review.cjs` stop with "axe-core is not installed. Run: npm ci --prefix tests/browser" instead of reporting null. `glitch-sweep --no-axe` skips the scan on purpose (pages say `axe: "skipped"`).
- README: install step, and the desktop, phone and dark rerun.

## Crawl results (local stand in over an isolated copy, admin persona, 16 Nov 2026)

| Run | Pages | Scanned by axe | Serious or critical |
|---|---|---|---|
| Desktop | 95 | 95 | 0 |
| Dark | 95 | 95 | 0 |
| Phone | 26 | 26 | 0 |

The phone run reaches only 26 pages: the crawl does not open the Settings tree from the phone menu. That is a crawl coverage limit, not an axe result. As a check that the scan works, an earlier run during a dropped preview server flagged `document-title` and `html-has-lang` on every blank page. Nothing to send to other jobs: there were no findings.

## Defaults taken (owner can change)

- `axe-core` pinned at 4.14.0 (a test tool only).

## Deploy order

Nothing to deploy. These are tests only.

## Tests (automated, local)

- `node --test tests/browser/axe.test.cjs`: 3 pass (loads the pinned copy; a missing file stops with the install step; a failed scan reports axe-failed).
- `node --test tests/browser/glitch-sweep.test.cjs`: 6 pass.
- The admin crawl above (desktop, phone, dark).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
