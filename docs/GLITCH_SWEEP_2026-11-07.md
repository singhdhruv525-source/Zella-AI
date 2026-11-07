# Glitch sweep: every admin and CRM page (7 Nov 2026)

At laptop width, every page of the admin dashboard and the business CRM was opened in a real browser for each
role (in the default and the Glass theme); at phone width, the CRM and admin menu pages were opened (most Settings
subpages weren't reached on a phone, see the results). Up to eight opening buttons per page were clicked. Everything ran against the **local stand-in** (`tests/browser/local-backend.mjs`)
over an **isolated test database** (production state plus Batch 3, Releases 1–3 and the slot-search fix; test
businesses only). Browser routing blocked outside addresses except the permitted font endpoints, and the sweep read only the isolated test database. Edge-function outbound access was not independently verified.

## How it was checked

| Tool | What it does |
|---|---|
| `tests/browser/glitch-sweep.cjs` | Signs in through the real sign-in page as each role and opens every page: the CRM and admin menus (from the app's own registries), every Settings subpage (all categories opened), every record type, and detail pages found by crawling. Per page it records crashes, the error screen, console errors, backend answers with an HTTP error (400 and above; a request that never answers isn't counted), "Page not found", pages stuck loading, sideways overflow (and the elements causing it), tables that need sideways scrolling at laptop width, cut-off buttons, broken images, raw values (`undefined`, `NaN`, `Invalid Date`), empty pages and axe-core accessibility problems (serious and critical, WCAG 2.1 AA), plus a screenshot. |
| `tests/browser/glitch-interact.cjs` | On every page from a sweep, clicks up to eight buttons per page that open something (Add, New, Edit, Filter, More, Open, Block time…) and checks that a dialog, menu or drawer appears, nothing crashes, no backend answer is an HTTP error, the console stays clean, focus moves into it, it isn't off-screen (it may run up to 40 px below the window, where it scrolls) or wider than itself, and Escape closes it (the same dialog, menu and drawer selectors for both checks). Buttons whose label mentions deleting, canceling, sending, calling, paying, publishing, inviting, importing, connecting or signing out are never clicked. Both scripts refuse to run unless the backend is on localhost, every other outside address (http or https) answers empty in the test browser except the font, and the sweep reads only a `z…` test database on a local socket. A button is clicked only when its whole label is the approved one, never a longer label that contains it. |

Roles: Zella owner and read-only admin (admin dashboard); owner, manager, staff and viewer (CRM). Views: laptop
(1280 px) in the default theme, the Glass (dark) theme, and a phone (390 px). Screenshots were also reviewed by
eye.

## What was wrong, and what was fixed

| Where | Glitch | Fix |
|---|---|---|
| Every CRM dialog | The shared CRM dialog didn't move focus into itself, keep Tab inside or give focus back on close (keyboard users typed into the page behind). | `Modal` uses the existing `useDialogFocus`. |
| Admin dialogs | Same for the admin drawer, reason dialog, Offers overlay, Security & abuse incident drawer and its two confirms, the business confirm, the spam incident panel; the Settings confirm box couldn't be closed with Escape at all. | All use `useDialogFocus` (or the new `DialogFocus` wrapper for inline dialogs). |
| CRM › Callbacks | The action cell was `display: flex` on a `<td>`, which pulled it out of the row: Call / Mark contacted / More were squeezed into clipped circles and the table stopped short. | The buttons sit in a wrapper inside a normal cell. |
| CRM › Calls | The table needed sideways scrolling on a laptop; "Follow-up set" was cut off, "1 d ago" broke over two lines. | Tighter columns, one-line times, the flags column wraps. |
| CRM › Today | "100% vs last week" in red: the direction was only an arrow icon. Five stat cards left Spam alone on a second row; on a phone the longer wording ran off the card. | "Up/Down N% vs last week" in words, the arrow flows with them, five cards fit one row, the text wraps on a phone. |
| CRM › phone header | The business switcher was squeezed into a sliver next to the menu button. | It keeps its initials at full size. |
| CRM › Settings › Daily report | Staff and viewers got "Couldn't load this… Try again" (the server shows it to owners, admins and managers only; trying again can't work). | Staff and viewers see "Only owners, admins and managers can see the daily report."; managers see it read-only. |
| Dialogs over dialogs | A confirmation opened over a drawer (the spam incident panel) had two focus traps: the drawer's pulled Tab back out of the confirmation. | Only the topmost open dialog handles Tab and Escape. |
| Admin › setup wizard (no receptionist) | Hours & services wrote the business hours before refusing for a missing receptionist, so a failed save still changed them. | The receptionist is checked before anything is written. |
| CRM › Calendar connections | "Connect Google Calendar / Outlook" said "couldn't be started. Try again" when the connection isn't set up on Zella (the server's `not_configured` answer wasn't recognised). Google sign-in isn't set up yet, so every owner would have hit this. | It says the calendar can't be connected yet and to contact Zella support. "canceled" spelling. |
| CRM › Store connection | The same `not_configured` answer gave a generic failure. | Explained. |
| CRM › Dispatch, Resources, Follow-through | Plain browser date box and select (unstyled); Follow-through had no breadcrumb. | The styled date box and select; breadcrumb added. |
| Card headings, Settings rows | Buttons ("Add time", "Open") were squeezed when the text beside them wrapped. | Buttons keep their size; the text wraps. |
| Admin › business page | A business with no receptionist couldn't be opened at all ("Could not load this business: This business has no AI receptionist"), so the admin couldn't see or fix it. | `owner-provision-business` reads such a business (receptionist shown as missing); changing the receptionist still refuses clearly. |
| Admin › Settings › All businesses | The created date broke over four lines and the Summary button was cut off. | Date only (time on hover); the button doesn't wrap. |
| Glass (dark) theme | Eleven CSS variables were used but never defined, so they always fell back to light-theme colours: the setup wizard's step ladder was unreadable (contrast 1.36), and the new Dispatch and Resources cards had light borders. | Each uses the real theme token; every `var()` in the CSS now resolves. |
| Wording | Title case in the admin sidebar and breadcrumb ("Industry Configuration", "AI Agents", "Platform Operations"…), "Security & Abuse", "Cancelled", "New Visit", "Today's Visits", "AI Receptionist Activity", old page names in help text. | Sentence case and US spelling (`docs/ZELLA_PRODUCT_VOICE.md`); the admin page keys are unchanged, so no link moves. |

## Results after the fixes

Final run on the fixed build (isolated test database, local stand-in; not production):

| Run | Pages | With problems |
|---|---|---|
| Laptop, default theme: owner, manager, staff, viewer (CRM) | 129 each | 0 |
| Laptop, default theme: Zella owner (admin) | 95 | 1, Settings › All businesses needed sideways scrolling; fixed after the run (columns shortened, the Summary button is an icon) and re-measured: no scrolling |
| Laptop, default theme: read-only admin | 95 | 6: five are the known read-only-admin refusals (see "Not changed"); the sixth is the All businesses table, fixed as above |
| Glass (dark) theme: owner (CRM) + Zella owner (admin) | 129 + 95 | 0 |
| Phone (390 px): owner (CRM) | 43 (every menu page and record type; most Settings subpages weren't reached, because the crawler doesn't open the phone's Settings menu) | 0 |
| Phone (390 px): Zella owner (admin) | 24 when the report was written | 2, buttons squeezed in panel headings (Overview, business page); fixed after the run and re-measured: none squeezed, no sideways overflow |
| Click-through: owner, Zella owner, staff | up to eight opening buttons on every page | no real problem left; the remaining reports were checked by hand: Filter, Edit, Details, Add hours and Add a service open inline; authenticator setup and picture upload open the system's own screens; Callbacks › More does move focus (the check reads it on a fixed delay) |

The web unit tests pass (53/53); `tests/browser/admin-permissions.cjs` passes (49/49) with the sentence-case
sidebar; `deno check` passes for `owner-provision-business`; the production build passes.

## Not changed (and why)

- **Read-only admin**: Offers, Platform operations and a few Settings health panels refuse with 400 for the
  `read_only_admin` role. That role can't be given to anyone today (audit item M-3: `platform_admins` only accepts
  `zella_owner` and `super_admin`), so nobody sees this; it belongs with M-3.
- **Code warnings** (`npm run lint`): no errors; the warnings are style (unused imports, effects that set state).
  None showed up as a visible glitch in the sweep, so they were left alone.
- Buttons the click-through reported as "nothing opened" were checked by hand: they work inline (Filter, Edit,
  Details, Add hours, Add a service, tabs) or open the system file chooser.

## Deploy

- **Web app:** merges to main deploy through Cloudflare Pages as usual.
- **Edge function:** `owner-provision-business` changed (the business page and the "Canceled" label). Deploy it
  after merging, from `web/`:
  `npx supabase@latest functions deploy owner-provision-business --project-ref pffqxlumqhjdbzvvoszm --no-verify-jwt --use-api`
- **Database:** no changes.

## Re-running

Set up the local stand-in as in `tests/browser/README.md`. Any local edge-function runtime must use a local
`SUPABASE_URL` and have no provider keys configured (voice, SMS, email, calendar, store, or AI providers).
Local test JWT/service credentials authenticate to the isolated stand-in; they are distinct from provider keys
that authorize outbound services. Verify this configuration before running; the historical runtime environment
was not independently verified by this follow-up.

Then:

```bash
ZDB=<test db> node tests/browser/glitch-sweep.cjs all            # add --mobile for the phone width
node tests/browser/glitch-interact.cjs owner tests/browser/out/glitch/owner/results.json
```

`PERSONAS='{"name":"email"}'` chooses the test accounts (default: `admin@zella.test`, `readonly@zella.test` and
the Batch 3 test people).
