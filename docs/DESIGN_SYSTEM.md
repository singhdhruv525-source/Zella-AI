# Zella design system

Every page in the admin dashboard, the business CRM, Settings, sign-in and the public link pages uses it. There are
three looks, chosen in Settings, Appearance (`appearance.js`), and all three re-point the same tokens:

| Look | File | What it is |
| --- | --- | --- |
| **Zella Voice** (the default) | `web/src/styles/zella-theme.css` | Paper pages (#FAFAF7), white cards and sidebar, midnight (#0B0F1A) for the things you act on, coral only for what is selected or live (the selected nav mark, soft coral tints). Pill shaped buttons. Inter Tight for page headings only; everything else is Inter. |
| Classic | `web/src/styles/tokens.css` | Warm and light: ivory pages, a cream sidebar, white cards, and mocha for the things you act on. 8px buttons. |
| Glass | `web/src/styles/glass.css` | Dark frosted surfaces over a wallpaper; the sidebar and top bar float as rounded cards. |

Sign in and the public pages always use Classic. Token values change only in `tokens.css` (and the theme files'
re-pointing blocks); app stylesheets use the tokens.

## Where it lives

| File | What it holds |
| --- | --- |
| `web/src/styles/tokens.css` | The only place colours, type sizes, spacing, radii and shadows are defined (`--zella-*`). |
| `web/src/index.css` | Base styles for every page (font, background, focus ring, headings, reduced motion). Imports the tokens. |
| `web/src/styles/components.css` | One look for each kind of element across apps: sidebar, top bar, page headings, cards, KPI cards, buttons, fields, search, tables, badges, banners, empty states, modals, phone drawer. Loaded last (from `main.jsx`). |
| App stylesheets (`OwnerDashboard.css`, `OwnerPages.css`, `BusinessApp.css`, `App.css`, `settings/settings.css`, ...) | Layout: widths, grids, breakpoints. Their own variable names (`--ba-*`, `--bg-surface`, `--zs-*`, ...) point at the tokens. |

Change a value in `tokens.css` and every app follows. Don't add hex colours to app stylesheets; use a token.

## Tokens

| Use | Token | Value |
| --- | --- | --- |
| Page background | `--zella-bg` | #F7F4EF |
| Sidebar | `--zella-sidebar` | #F1EBE2 |
| Cards | `--zella-card` | #FFFFFF |
| Primary (buttons, selected nav, key icons) | `--zella-primary` / `--zella-primary-hover` | #70452F / #543321 |
| Text / secondary text | `--zella-text` / `--zella-text-secondary` | #252321 / #77716B |
| Borders | `--zella-border` / `--zella-border-strong` | #E9E2D9 / #D9CFC3 |
| Selected navigation | `--zella-nav-active` | #E7D9CB |
| Success, info, warning, danger | `--zella-{success,info,warning,danger}` + `-bg`, `-border` | green, blue, amber, red |

The table above is Classic. The Zella Voice look re-points the same names (`zella-theme.css`): page #FAFAF7, cards and
sidebar white, primary midnight #0B0F1A, `--zella-primary-soft` coral tint #FFE9E3, text #0B0F1A, borders #D9DCE1.

Type (Inter, loaded in `index.html`, with system fallbacks): page headings 28px semibold, section headings 16 to 18px
semibold, body 13 to 14px, navigation 14px medium, KPI values 32px semibold, labels 13px medium, secondary text 12 to 13px.
Headings are weight 600 everywhere (set once in `components.css`; app stylesheets don't set 700 or 750 on headings).
In the Zella Voice look only page headings (`h1`) use Inter Tight with `-0.02em` tracking; card and section `h2` and `h3`
stay Inter at normal tracking, because tight tracking closes word spaces at 16 to 18px.

Shape: inputs 8px (10px in Zella Voice), small cards and banners 10px, cards, panels and modals 14px (16px in Zella
Voice). Buttons are pills in the Zella Voice look and 8px in Classic. Shadows stay minimal.

## Buttons

| Kind | Class | Use |
| --- | --- | --- |
| Primary | `.owner-primary-button`, `.zs-btn.primary`, `.ba-btn.primary` | One per page header, dialog or save bar. Midnight (Zella Voice) or mocha (Classic). |
| Secondary | `.owner-secondary-button`, `.zs-btn`, `.ba-btn` | Everything else. White with a border. |
| Small | add `.sm` (32px high) | Buttons inside tables, card headers, the page header Refresh and save bars. |
| Text action | `.owner-link-button` | Quiet actions such as Clear filters. No border; underlined only on hover and focus. |
| Danger | `.bd-danger-button`, `.zs-btn.danger`, `.zs-btn.danger-outline` | Destructive steps, after a confirmation. |

Disabled: a secondary button fades to 50%. A disabled primary becomes a quiet grey surface (`--zella-subtle`, faint
text, a border) instead of a faded midnight pill, and always has a short reason next to it ("Add a phone number to
continue"), as onboarding does.

## Components added with billing

- **Usage meter** (`.zs-usage`, `.zs-meter` in `web/src/settings/settings.css`): a label, "used of included", a bar, and what is left. The bar is mocha below 80%, amber from 80% and red at 100%, and the words say the same (a "Over 80%" or "Used up" badge), so colour never carries the meaning alone. It has `role="meter"` and an accessible label.
- **Billing layouts** (`web/src/billing.css`, `.bp-*`): the plan page puts the form (cards: Pricing, Monthly allowances, Account) beside a sticky summary card (price, estimated margin with a Healthy / Below target / Loses money label, cost lines, warnings, the review button); money inputs carry a `$` prefix and a unit suffix; Base/Pro, Monthly/Yearly and languages are segmented buttons (`aria-pressed`). The owner's plan page shows a plan header (name, status, price, next charge, what's included as chips) and one usage tile per resource. Below 1100px the summary moves under the form; below 760px everything is one column.

## Tabs on one business's page

`BusinessDetails.jsx` (`.bd-tabs`, `web/src/business/businessDetail.css`) follows the WAI-ARIA tabs pattern: a
`tablist` with a label, each tab `aria-controls` its `tabpanel`, the panel is `aria-labelledby` its tab, one tab stop
(roving `tabIndex`), arrow keys wrap, Home and End jump, and the open tab is in the address. On a phone the row's edges
fade into `--zella-bg` to show it scrolls, and the open tab is scrolled into view. Other pages' tabs (`adminOps.jsx`)
are not changed by this.

## Components added with the owner onboarding journey

- **Progress steps** (`web/src/onboarding/ProgressSteps.jsx`, `.zv-progress` in `onboarding/onboarding.css`): "Step 3 of 7" and the step's name, a mocha bar with `role="progressbar"` and an accessible value text, and one dot per step (done, here, to come). The words carry the meaning; the bar and dots back them up. Give it `screens` and the `current` index.
- **Authenticator set up** (`web/src/AuthenticatorSetup.jsx`, `.zv-authsetup`): the three instructions, the QR code (kept black on white in every look), the key to type by hand, the six digit code and one main button. It uses the same calls as the admin sign in and Settings (`mfa.js`); `start` and `finish` can be passed in. It never decides who must use two step sign in.
- **Journey page** (`.ba-root.zob`): a top bar (Zella Voice, the business, Finish later) and one card, 16px gutters on a phone, 680px wide from 760px. Main buttons are full width on a phone. Status panels (`.zob-status`, tones `good`, `info`, `heads`, `urgent`) always carry a word. Headings that take focus when a step opens show no focus ring (they aren't controls). The Glass look frosts the card and the top bar.

## Writing (owner's rule, 14 Nov 2026)

- **No dashes or hyphens anywhere people read text**: screens, emails, texts, notifications and what the AI
  receptionist says. Not "—", not "–", not a hyphen between words.
  - A pause in a sentence becomes a full stop or a comma: "Minutes used up. New calls go to your fallback number."
  - A range uses "to": "9:00 to 17:00", "1 Nov to 30 Nov", "1 to 25 of 80".
  - An empty value is never blank and never "—". It is one quiet word (`EmptyValue`), one word per kind of value:
    "None" for lists and counts, "Not set" for configuration, "Never" for times.
  - Times read "5 days ago" or "Yesterday" (never "5 d ago"), with the exact time on hover; dates and times in full read
    "Nov 16, 2026 at 2:49 PM". Time zones read "Eastern Time (New York)", not "America/New_York". Column heads say
    the period in words: "AI calls, last 30 days".
  - Compound words are written as separate words, or as one word where that is the usual spelling: follow up,
    sign in, no show, check in, walk in, two step sign in, auto reload, pay as you go, read only; callback, checkup,
    roundup, setup, Ecommerce.
  - Phone numbers use spaces: (555) 010 2040.
  - Code is not text: class names, routes, keys, stored values, file names, web addresses and locale tags keep theirs.
- `npm run lint` runs `web/scripts/check-dashes.mjs`, which fails on any dash or hyphen in the app's text
  (`npm run check:writing` lists them).

## Notifications: creative but professional

Every notification (banner, pop up, bell item, email) follows one pattern, in the business's own words:

| Part | What it is |
|---|---|
| Picture | A ring that fills to the percentage (usage), or an icon on a soft tile that says what happened (phone, calendar, chat, envelope, star, shield, refresh) |
| Label | Two or three words above the headline: Heads up, Action needed, Topped up, Still answering, Paused for now, Celebration |
| Headline | Warm and plain: "Your receptionist has been busy this month", "Every call is still being answered" |
| Body | The facts: numbers, the date things reset, what happens to calls and messages, money involved |
| Action | One clear main button (and at most two others) |

- Colour says how urgent it is: green good news, blue information, warm brown business moments, amber heads ups,
  red urgent or action needed. The label always says it in words too.
- Red notices can't be dismissed until the problem is fixed; the others can. Pop ups fade after a few seconds.
- Each business sees the notifications for its own kind of business plus the general ones; the wording uses its
  terms (chairs, patients, tables, jobs, viewings, tenants).
- No jokes, no emoji, no dashes. Motion (filling rings, fades) stops for people who prefer reduced motion.
- Emails use one layout (`web/src/emails/businessEmails.js`): the Zella Voice name and the business, a tone badge,
  the headline, the facts, one mocha button, and the reason for the email in the footer. Email clients can't read CSS
  variables, so `EMAIL_COLORS` copies the hex values from `tokens.css`; `web/tests/businessEmails.test.mjs` fails if
  they drift.
- In the CRM, `noteStyle(n)` in `web/src/zellaVoice.js` gives each notification its icon, tone and label. The five
  tones are classes `tone-good`, `tone-brand`, `tone-info`, `tone-heads` and `tone-urgent` on `.ba-toast`,
  `.ba-note-icon` and `.ba-kicker` (`BusinessApp.css`), built only from the `--ba-success`, `--ba-primary`,
  `--ba-info`, `--ba-warning` and `--ba-danger` tokens and their soft backgrounds.

## Shared components (every new admin page uses these)

All in `web/src/admin/adminOps.jsx` unless noted; their look is in `web/src/styles/components.css`.

| Component | What it does |
| --- | --- |
| `PageHeader({ eyebrow, title, description, actions, updatedAt, onRefresh })` | The eyebrow is the sidebar group (Businesses, Configuration, AI and communications, Operations); the H1 is the sidebar label. "Updated 2:44 PM" and a small Refresh button sit in the header actions, left of the single primary button. Cards don't carry their own Refresh. |
| `Metric({ label, value, note, onClick })` and `.owner-stat-card` | One KPI card: label 13px secondary, value 32px semibold with tabular figures, one line of note 12px (ellipsis), a fixed minimum height, no coloured icon tiles. A card that filters the list is a real button (`onClick`) with a chevron, hover border and focus ring. |
| `DataTable({ columns, rows, cards, selected })` | Columns are `[header, cell, className, label]`. Use `num` for numbers (right aligned, tabular) and `col-actions` for the action cell. With `cards`, each row becomes a card under 600px, labelled from `data-label`. Tables that stay tables on a phone fade at the right edge. |
| `Pager` | The one table footer (`.owner-table-foot`): "Showing 1 to 25 of 96" (or "3 shown") on the left, Previous and Next small buttons on the right, chevrons only under 600px. |
| `Drawer({ eyebrow, title, status, footer })` | A side panel: a 12px eyebrow ("Plan"), the title (the business name) at 18px, an optional status badge, and a sticky footer for its actions. Facts inside are a two column list (`.ao-facts`); sections use `.drawer-section h3`. |
| `Filters({ active, onClear })`, `Search`, `Select`, `Toggle` | One row of filters at 36px: search first, then selects and dates, yes or no filters as toggle chips (`aria-pressed`), Clear filters as a text button at the end. Under 600px they fold behind a "Filters (2)" button. |
| `Tabs` | Page tabs in one line that scrolls sideways. The selected tab (and selected filter chip) is the soft tint with a hairline, never a midnight fill. |
| Badges: `Pill` (`.op-pill`, `.owner-badge`), `statusTone(word)` | One 22px pill. Tones come from the status tokens; neutral is `--zella-subtle`. |
| `EmptyValue({ label })` | The word for a missing value, in faint text. See Writing. |
| Banners: `.banner-info`, `.owner-info-banner`, `.banner-warning` | An `info` icon (20px), the lead phrase in the tone colour at 600, the rest in body text at 400. Two lines at most; more goes in a disclosure. `.banner-warning` is for inline notices next to a table ("1 job is not in the state recorded for it"). |
| Settings: `SettingRow`, `SectionSaveBar`, `MissingSettings` (`web/src/settings/SettingsKit.jsx`) | A compact row: label and help on the left (40%), the control on the right (numbers at most 240px wide), the setting key in a "Technical details" disclosure. One sticky save bar per section ("2 unsaved changes", Discard, Save) that only appears once something changed. Settings the database doesn't have yet collapse into one info banner at the top, and their rows show a neutral "Not available yet" badge. |
| Format helpers (`web/src/lib/format.js`, re-exported from `ownerFormat.js`) | `formatCount` ("1,203"), `formatRelative` ("5 days ago", "Yesterday"; the exact time goes in a `title`), `formatDateTime` ("Nov 16, 2026 at 2:49 PM"), `formatPhone` ("(555) 123 0001"), `formatTimeZone` ("Eastern Time (New York)"), `formatDuration`. `when`, `num`, `duration` and `ago` in `adminOps.jsx` use them. |

### Tables

- Cells sit in the middle of the row with 10px by 16px padding. Words never break mid word: no `overflow-wrap: anywhere`
  or `break-all` on table text. Long emails and names use `.owner-cell-truncate` (220px, ellipsis) with the full value in
  a `title`; a secondary line under a cell uses `.owner-table-secondary` (one line, ellipsis).
- Badges in tables never wrap.
- The action cell holds at most one `.owner-secondary-button.sm`, plus an optional icon only overflow button
  (`more_horiz`, with an `aria-label`). No underlined bare links, actions never stack vertically, and the cell is
  `td.col-actions` (`width: 1%; white-space: nowrap; text-align: right`). When the whole row opens the record, the row is
  clickable (`.ao-clickable`: pointer, hover `--zella-alt`).
- The open row is marked one way everywhere: `--zella-primary-soft` with a 3px inset bar in `--zella-primary`. Other rows
  are never tinted.

### Badge tones

| Tone | Words |
| --- | --- |
| Success | Live, Active, Ready, Healthy |
| Info | Trial, In progress, Scheduled |
| Warning | Draft, Not yet, Pending, Paused |
| Danger | Failed, Suspended, Urgent |
| Neutral | Everything else, such as No plan, Canceled, Not available yet |

## Rules of use

- The primary colour (midnight in Zella Voice, mocha in Classic) is for primary buttons and key icons. Coral marks only
  what is selected or live. Most buttons are secondary (white with a border).
- Status badges always carry a word (Active, Pending, Failed). Colour backs the word up, never replaces it:
  green done or active, blue scheduled or informational, amber pending or warning, red failed, cancelled or urgent.
- Icons are Material Symbols Outlined (`<Icon name="..." />` from `BusinessUI.jsx`) in both apps.
- Motion is quiet: pages fade in once; nothing moves on hover. All motion stops for people who prefer reduced motion.
- On phones (CRM under 760px, admin under 600px) the sidebar opens as a drawer from the menu button in the top bar;
  it closes on Escape, on the backdrop, or when a page is chosen. Wide tables and tab rows scroll inside themselves,
  never the whole page, and fade at the right edge while there is more.
- The admin sidebar's background and border run the full height of the page (`.owner-sidebar-col`); only the nav inside
  it is sticky. The settings sub navigation (`.zs-nav`) is sticky at the top of its column.
- A short choice such as a period is as wide as its options (`<Field fit>` in Settings), not the whole row. A long
  table in a Settings card shows its first rows with a count and a "See all" button under it (`.zs-table-more`).
- Setting keys (`sms_live`, `calls_live`, ...) are code: pages say what they mean in words ("Texts are in test mode",
  `web/src/copy/liveSwitches.js`) and give the key only as a tooltip (`NotAvailable`'s `tip`, or a `title`).
