# Glitch sweep: every admin and CRM page (7 Nov 2026)

Every page of the admin dashboard and the business CRM was opened in a real browser, per role, and the buttons
that open things were clicked. Everything ran against the **local stand-in** (`tests/browser/local-backend.mjs`)
over an **isolated test database** (production state plus Batch 3, Releases 1–3 and the slot-search fix; test
businesses only). Nothing touched production; nothing was sent.

## How it was checked

| Tool | What it does |
|---|---|
| `tests/browser/glitch-sweep.cjs` | Signs in through the real sign-in page as each role and opens every page: the CRM and admin menus (from the app's own registries), every Settings subpage (all categories opened), every record type, and detail pages found by crawling. Per page it records crashes, the error screen, console errors, failed backend calls, "Page not found", pages stuck loading, sideways overflow (and the elements causing it), tables that need sideways scrolling at laptop width, cut-off buttons, broken images, raw values (`undefined`, `NaN`, `Invalid Date`), empty pages and axe-core accessibility problems (serious and critical, WCAG 2.1 AA), plus a screenshot. |
| `tests/browser/glitch-interact.cjs` | On every page from a sweep, clicks each button that opens something (Add, New, Edit, Filter, More, Open, Block time…) and checks a dialog, drawer or form appears, nothing crashes or fails, focus moves into the dialog, it fits the screen and Escape closes it. Buttons that delete, cancel, send, call, pay, publish or sign out are never clicked. |

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
| CRM › Settings › Daily report | Staff and viewers got "Couldn't load this… Try again" (the server only shows it to owners and admins; trying again can't work). | They see "Only an owner or admin can see and change the daily report." |
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
| Glass (dark) theme, owner (CRM) + Zella owner (admin) | 129 + 95 | 0 |
| Laptop, default theme, all six roles | in progress, see below | |
| Phone (390 px), owner + Zella owner | in progress, see below | |
| Click-through, staff | every opening button on every staff page | 0 real (two reports checked by hand: Filter opens inline; Callbacks › More does move focus, the check looked too early) |

The web unit tests pass (53/53); `deno check` passes for `owner-provision-business`; the production build passes.

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

Set up the local stand-in as in `tests/browser/README.md`, then:

```bash
ZDB=<test db> node tests/browser/glitch-sweep.cjs all            # add --mobile for the phone width
node tests/browser/glitch-interact.cjs owner tests/browser/out/glitch/owner/results.json
```

`PERSONAS='{"name":"email"}'` chooses the test accounts (default: `admin@zella.test`, `readonly@zella.test` and
the Batch 3 test people).
