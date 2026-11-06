# Batch 2: platform admin dashboard, verified corrections (6 Nov 2026)

Branch `claude/batch2-admin-fixes`, created from `82f7b69` (`main` and `claude/bold-pasteur-efhksy` were both at that
commit, which contains Batch 1's `69e8010`; the history matched the architect's observations). **Nothing is merged or
deployed. No database, edge function or production record was changed.** All changes are in the web app.

Shared piece: `web/src/admin/loadState.jsx` (hook `useRefreshable`, `LoadNotice`, `UpdatedAt`) and
`web/src/admin/loadStatus.js` (pure helpers `loadStatus`, `metric`, `countOf`, `emptyText`, `isCount`). Every page
that uses them follows the same rules:

| Data state | Metrics | Lists | Banner |
|---|---|---|---|
| loading (nothing yet) | `…` | "Loading..." | none |
| loaded, value is a number | the number, **0 included** | rows, or the real empty message | "Updated hh:mm" |
| loaded, value missing from the answer | `—` | "Not reported." | as above |
| first load failed | `—` | "Not available: … couldn't be loaded." | error with **Retry** |
| refresh failed after a good load | last good values | last good rows | "The latest refresh failed (…). Showing … from hh:mm; it may be out of date." with **Retry**, plus "Last updated hh:mm" |

A failed refresh keeps the error showing until a refresh succeeds. Answers that arrive after the page is left are ignored.

## 1. Results by issue

| ID | Result | Before | After |
|---|---|---|---|
| **B2-01** Overview metrics (`OwnerOverview.jsx`) | Done | `value ?? 0`: missing or failed values read as 0. A failed first load still said "Nothing needs attention", "No businesses yet" and offered "Create your first business". A failed refresh kept old data with only an error line. | Shared states. A real 0 shows 0. Missing shows `—`. A failed first load shows an error with Retry and no zeros or success empty-states. "Create your first business" appears only after an answer that really lists no businesses. A failed refresh keeps the data, marked stale with its time. Retry clears the warning. Layout and navigation buttons unchanged. |
| **B2-02** Platform operations health (`PlatformOperations.jsx`) | Done | "All systems normal" whenever the four counters were 0 and required settings were set. Zero fallbacks for metrics. "None" for counts. | The banner is scoped and names its coverage: "No issues found in the checks below" (state `clear`), "N issues found (… required settings missing)" (`issues`), "Checks incomplete" (`incomplete`: a count or the configuration list missing, or the automation status unavailable), "Health check failed: no results, so nothing here is confirmed healthy" (`failed`). Each line also notes that the check doesn't test whether the phone, voice, text or email providers are reachable. Each service line shows Configured, Missing (required), Not set, **Turned off on purpose** or **Status unknown**. A missing count shows "Unknown", never "None". Links to Businesses, Overview, Integrations and Support kept. `PlatformMonitoring` unchanged. |
| **B2-03** Integrations (`IntegrationsPage.jsx`) | Done | `?? 0` metrics. Empty-list messages after a failed request. | Shared states. Counts only from arrays the server returned. A failure shows an error with Retry, `—` metrics and "Not available", not "Nothing connected yet". A failed refresh keeps rows, marked stale, with the last refresh time. Read-only, as before: it never starts a provider sign-in or connection (checked in the test). A provider shows "✓" only when the server reports it connected (unchanged). |
| **B2-04** AI receptionist statistics (`AIAgents.jsx`) | Done, with one deviation (below) | `v ?? 0`. "Live" for any agent with status `active`. | Shared states. A missing count shows `—`. A failed request never says "No AI receptionists yet". **Live** means status `active` **and** the phone and voice connections the server reports active. Active without them shows "Not connected"; a status outside `active/paused/disabled` shows "Unknown". The Live card, the Live pill and the Live filter use the same rule. Search, filters and business links unchanged. |
| **B2-05** Module catalog (`ModulesPage.jsx`) | Done | A failed request showed "No modules configured yet." | An error with Retry (no page reload). The empty message appears only after a successful answer with no modules. A failed refresh keeps the catalog, marked stale. The link to Industry Configuration is kept. Presets and dependencies untouched. |
| **B2-06** Document approval (`VerificationQueue.jsx`) | Done | Verify called `document_review` immediately. | Verify opens a dialog with the business, document type, file name and requested action ("Mark as verified", noting when it replaces an earlier rejection). Cancel, Escape or a backdrop click closes it with no request. Focus starts on Cancel and returns to the Verify button. Confirm sends one request (ref guard plus disabled buttons). A failure is shown inside the dialog and the row keeps its server status. Success closes the dialog and reloads the queue. The rejection-reason flow is unchanged, except that its errors now show inside its dialog. Server authorization and audit logging are unchanged. |
| **B2-07** Admin invitation roles (`UsersAccess.jsx`) | Done | "They get full access to every client business" for every role. | The text says access depends on the role. A live explanation under the role picker comes from the server's own definitions (`roles_get`: the permission catalog and each restricted role's permissions). Zella owner: everything, plus managing admins and roles. Super admin: everything except managing admins and roles (the server's rule). A restricted role lists exactly its permissions, or says it has none. If the definitions can't load, the text says only that the role's own permissions apply. Role-change confirmations include the explanation. The success message names the role. Invitation and role-update requests are unchanged. |
| **B2-08** Business list (`OwnerDashboard.jsx`) | Done | A failed refresh replaced the table with an error. Statistics defaulted to 0. Data from an earlier session was not cleared on account switch. | The last good refresh is tracked and shown ("Updated hh:mm"). A failed refresh keeps the list, with a stale warning and Retry. A failed first load shows `—` statistics and the existing error panel. Statistics are never made up. When access is lost or re-checked (sign-out, another account signs in, a fresh permission check), businesses, industries and statistics are cleared, and any answer for the earlier session is dropped. Batch 1's rule holds: nothing loads before authorization. |

### Deviations from the requested solution
1. **B2-04 "Live".** The database's only statuses are `active`, `paused` and `disabled`, and the default is `active`. Every new receptionist was therefore "Live" before any phone or voice connection. To make "Live" reflect a verified state, the page combines two existing backend fields per agent: `status === "active"` and `checks.phone && checks.voice`, which the server computes from integrations with status `active`. No backend change. The page's Live count is computed from the agent list with the same rule, instead of `stats.live` (which counts `active` only), so the card and the pills agree.
2. **B2-02 "Intentionally disabled".** `platform_status` has no disabled field. The page also calls the existing `automation_overview` action (same `businesses.view` permission, read-only). It shows n8n as "Turned off on purpose" when that action's `n8n.dispatchEnabled` is false. No new status values were invented, and no backend change was made.
3. **Stale banner in Businesses (B2-08)** is written inline rather than with `LoadNotice`, because that page's loading code is the existing one (kept to avoid rewriting it).

## 2. Files changed

| File | Change |
|---|---|
| `web/src/admin/loadState.jsx` (new) | `useRefreshable`, `LoadNotice`, `UpdatedAt` |
| `web/src/admin/loadStatus.js` (new) | pure helpers for data states and metric text |
| `web/src/OwnerOverview.jsx` | B2-01 |
| `web/src/PlatformOperations.jsx` | B2-02 |
| `web/src/IntegrationsPage.jsx` | B2-03 |
| `web/src/AIAgents.jsx` | B2-04 |
| `web/src/ModulesPage.jsx` | B2-05 |
| `web/src/VerificationQueue.jsx` | B2-06 |
| `web/src/UsersAccess.jsx` | B2-07 |
| `web/src/OwnerDashboard.jsx` | B2-08 |
| `web/src/OwnerPages.css` | styles for the updated time, stale warning and confirmation facts |
| `web/tests/batch2_unit.test.mjs` (new) | unit tests |
| `tests/browser/admin-batch2.cjs` (new) | browser tests for all eight fixes |
| `tests/browser/admin-permissions.cjs` | Batch 1 account-switch test now waits for the new account's menu instead of reading it while permissions are still loading (a timing fix in the test, not a behavior change) |

## 3. Historical tests (reported by the original author)

| Command | Kind | Result |
|---|---|---|
| `cd web && node --test tests/batch2_unit.test.mjs tests/batch1_unit.test.mjs` | unit | **15 / 15** (4 new + 11 Batch 1) |
| `node tests/browser/admin-batch2.cjs` | Chromium, **stubbed backend** | **64 / 64** (historical total only; breakdown corrected): B2-01 11, B2-02 13, B2-03 6, B2-04 8, B2-05 5, B2-06 9, B2-07 6, B2-08 6 |
| `node tests/browser/admin-permissions.cjs` (Batch 1) | stubbed backend | **49 / 49** (3 runs in a row) |
| `node tests/browser/crm-batch1.cjs` (Batch 1) | stubbed backend | **13 / 13** |
| `node tests/browser/security-journeys.cjs` (existing admin and CRM routes) | stubbed backend | **23 / 23** |
| `node tests/browser/page-sweep.cjs admin` (existing, every admin page, every role) | stubbed backend, compared with a build of `main` | 301 page checks; **52 error-boundary pages on `main` and the same 52 on this branch: none new, none fixed** (Settings pages under the sweep's empty canned answers; existing, see risks) |
| `tests/security/batch1/run.sh` | isolated Postgres | all passed |
| `tests/security/run.sh` (existing security suite) | isolated Postgres | all passed |
| `tests/deploy/run_all.sh` (all suites, 28-industry call matrix, rollback, web build, function tests) | isolated Postgres plus local runtime | **25 / 25**; 28-industry matrix 391 / 391 (current voice-rules) and 335 / 335 (deployed-era) |
| `web/supabase/functions/check.sh` | type check | all 11 functions ok (no function changed) |
| `npm run build` | build | ok |
| `npx oxlint src` | lint | 0 errors; 183 warnings (185 on `main`) |

**Mocked versus live:** the eight fixes were tested only in a browser against canned backend answers. The database suites run against isolated copies. Nothing was tested against production or the live `owner-provision-business`. **Unverified:** the real `automation_overview` value of `n8n_dispatch_enabled` in production; Safari and Firefox; screen readers beyond the dialog's ARIA attributes and focus order.

## 4. Remaining risks
- **Existing:** 52 admin Settings pages show the error boundary under the sweep's empty-answer stub on both `main` and this branch. It is probably a stub artifact (empty objects where the pages expect fields), but it isn't proven against the real backend. Outside Batch 2's scope.
- Statistics computed on the server (`stats.*`) still arrive as 0 when the server itself defaults them. The page can only tell "missing" from "0" when the field is absent.
- "Turned off on purpose" depends on the `n8n_dispatch_enabled` setting. If production keeps n8n off by leaving the webhook unset rather than turning that setting off, the line shows "Not set" (neutral, not counted as an issue).
- Times shown are the browser's local time.

## 5. Deployment
- **Database migrations:** none. **Edge functions:** none. **Configuration:** none.
- **Web app:** publish `web/` (Cloudflare Pages builds `main`) once this branch is reviewed and merged.

## 6. Rollback
Redeploy the previous Pages build, or revert this branch's commit on `main` (`git revert <commit>`), then let Pages rebuild. There is no data or schema to undo.

## Review corrections

The Off filter is now labeled Not live; its selection predicate is unchanged. Dashboard requests use a sequence as well as the authorization epoch. Invitation resends accurately preserve the existing role, and role confirmations read current definitions. Both review dialogs contain keyboard focus; cancellation restores the opener and success focuses the persistent Verification heading.

Current review validation: Batch 2 and Batch 1 unit suites passed 15/15; the web build passed. Batch 2, admin-permissions and CRM Batch 1 browser suites were attempted but could not start because Playwright is not installed. Added browser assertions remain unverified. Request-ordering, resend-notice and delayed-role regression coverage remains outstanding. No database, edge-function, deployment or production operations were run.
