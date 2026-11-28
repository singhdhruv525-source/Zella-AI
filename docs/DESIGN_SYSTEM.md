# Zella design system

Every page in the admin dashboard, the business CRM, Settings, sign-in and the public link pages uses it. There are
three looks, chosen in Settings, Appearance (`appearance.js`), and all three re-point the same tokens:

| Look | File | What it is |
| --- | --- | --- |
| **Zella Voice** (the default) | `web/src/styles/zella-theme.css` | Paper pages (#FAFAF7), white cards and sidebar, midnight (#0B0F1A) for the things you act on, coral only for what is selected or live (the selected nav mark, soft coral tints). Pill shaped buttons. Inter Tight for page headings only; everything else is Inter. |
| Classic | `web/src/styles/tokens.css` | Warm and light: ivory pages, a cream sidebar, white cards, and mocha for the things you act on. 8px buttons. |
| Glass | `web/src/styles/glass.css` | Dark frosted surfaces over a wallpaper; the sidebar and top bar float as rounded cards. |

Each person can also choose a background: a built in picture (the default) or their own upload. With a picture, the look
takes its colours from it, everywhere, and the Zella Voice logo keeps its own colours (owner, 28 Oct 2026). Today the
code does this in the Glass look only, with the switch "Match colours to the picture", on by default
(`web/src/appearance.js`). Sign in and the public pages always use Classic. Token values change only in `tokens.css` (and the theme files'
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
| Text on a solid success surface (27 Nov 2026) | `--zella-on-success` | #FFFFFF (5.3:1 on #1F7A45); Zella Voice #FFFFFF on #0B7A5E; Glass #0E2A1B on #86E3AE |
| A sheen or highlight edge on a solid surface (27 Nov 2026) | `--zella-sheen` | rgba(255, 255, 255, 0.16); Glass 0.22 |
| The card picture's chip metal, light to dark (27 Nov 2026) | `--zella-metal-1`, `-2`, `-3` | #F3E2B3, #CDA85C, #8E6B2C in every look |
| The lowlight under embossed lettering (27 Nov 2026) | `--zella-emboss-low` | rgba(0, 0, 0, 0.32) |

The table above is Classic. The Zella Voice look re-points the same names (`zella-theme.css`): page #FAFAF7, cards and
sidebar white, primary midnight #0B0F1A, `--zella-primary-soft` coral tint #FFE9E3, text #0B0F1A, borders #D9DCE1.

Type (Inter, loaded in `index.html`, with system fallbacks): page headings 28px semibold, section headings 16 to 18px
semibold, body 13 to 14px, navigation 14px medium, KPI values 32px semibold, labels 13px medium, secondary text 12 to 13px.
Headings are weight 600 everywhere (set once in `components.css`; app stylesheets don't set 700 or 750 on headings).
In the Zella Voice look only page headings (`h1`) use Inter Tight with `-0.02em` tracking; card and section `h2` and `h3`
stay Inter at normal tracking, because tight tracking closes word spaces at 16 to 18px.

Shape: inputs 8px (10px in Zella Voice), small cards and banners 10px, cards, panels and modals 14px (16px in Zella
Voice). Buttons are pills in the Zella Voice look and 8px in Classic. Shadows stay minimal. The admin dashboard uses its own corner steps
in every look (see "Admin pages polish"): `--zella-radius-panel` 16, `--zella-radius-card` 12, `--zella-radius-note` 8
and `--zella-radius-nested` 4.

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

## Voice carousel

`VoiceSelect` (`web/src/settings/VoiceSelect.jsx`, `.zs-vc` in `settings/settings.css`) picks the receptionist's voice in
Settings > Voice and the admin create business wizard. Use the pattern for any choice among a few to a few dozen
items that people judge one at a time:

- One card per item in a horizontal track with scroll snap; the centred card is the choice (`role="radiogroup"`, each
  card a `radio` with `aria-checked`, one tab stop, arrow keys, Home and End, and a polite live line such as
  "Katie, Cartesia, English, female, selected"). Moving to a card selects it.
- Neighbours peek in at both sides, smaller and dimmer; the centred card grows to full size and takes a soft glow in
  `--zella-primary-ring` with an accent border. Scale, opacity and glow follow the scroll position each frame
  (`cardLook`: transform and opacity only), so a swipe, a smooth scroll and the snap all move as one. With reduced
  motion the scroll jumps and nothing eases.
- Card width is `min(280px, 70cqw)` of its stage (about 70% on a phone), with 14px gaps (10px on a phone).
- Under the track: Previous and Next buttons around the dots (`.zs-vc-dot`, the current one in the accent and a little
  larger); past nine items the dots become a window that follows, with a "4 of 21" counter.
- Filters are `.zs-chip` toggle chips (`aria-pressed`) above the track. Card actions (the round play button) sit beside
  the radio, never inside it, and never select.
- Disabled: the chosen card only, nothing moves.

## Tabs on one business's page

`BusinessDetails.jsx` (`.bd-tabs`, `web/src/business/businessDetail.css`) follows the WAI-ARIA tabs pattern: a
`tablist` with a label, each tab `aria-controls` its `tabpanel`, the panel is `aria-labelledby` its tab, one tab stop
(roving `tabIndex`), arrow keys wrap, Home and End jump, and the open tab is in the address. On a phone the row's edges
fade into `--zella-bg` to show it scrolls, and the open tab is scrolled into view. Other pages' tabs (`adminOps.jsx`)
are not changed by this.

## Components added with the owner onboarding journey

- **Glass checkout** (`web/src/billing/GlassCheckout.jsx`, `.zgc` in `billing/glassCheckout.css`; owner, 27 Nov
  2026): every payment the owner makes (the onboarding Pay step, Pay now, finishing or buying a pack). Like a real
  checkout: a status panel (`.zob-status` tones; its `h2` takes focus when the state changes), then three panels on a
  faint tinted backdrop (`--zella-primary-soft` glows over `--zella-alt`): the customer's card on the left, **Payment
  details** in the middle (Stripe's own card fields, number full width, expiry and security code side by side, then
  Stripe's billing address fields under them, with our Pay button at the bottom; the field Stripe reports focused gets
  the `--zella-primary` border and `--zella-primary-ring`; Stripe's fields take the look's tokens through their style
  object and the Appearance API; a skeleton while they load; the trust row "Secured by Stripe", "Card details never reach Zella
  Voice"), and the order summary as a receipt on the right (an icon per line, tabular numbers, a dashed divider, then
  the total at page heading size). From 1100px three columns (the journey card widens to 1240px); from 760px the card
  above the payment panel with the summary beside them; below that one column: card, payment details, summary. Panels
  have a light rim on the top edge (`--zella-sheen`), a contact and an ambient shadow, and a faint grain; Glass gets a
  stronger frost (28px blur), a fine light border (`--zella-border-strong`) and an inner glow from the primary.
- **Type on the payment pages** (owner, 27 Nov 2026): new tokens `--zella-text-md` (15px, reading text in the
  checkout's panels and on Billing and subscription) and `--zella-leading-loose` (1.6, paragraphs in narrow panels).
  Labels are `--zella-text-base` (14px); helper and footnote text is never smaller than `--zella-text-sm` (13px); panel
  headings are `--zella-text-xl` (18px); Due today stays `--zella-text-page`. Copy is short and plain, one idea per
  line, with no internal terms; Pay buttons read "Pay $278"; the trust row is "Secured by Stripe" once.
- **Add ons in the receipt** (`AddonPicker` in `web/src/billing/ReceiptExtras.jsx`, `.zgc-addons`; owner, 27 Nov 2026):
  under the receipt's total, an "Add ons" heading and a short note, then one `fieldset` per type with its `legend`
  (Minutes, Texts, Emails; small capitals in `--zella-text-secondary`). Each row is a real checkbox whose `label` is the
  whole row (`.zgc-addon`, at least 48px tall): a drawn box (`--zella-border-strong`, ticked `--zella-primary` with
  `--zella-on-primary` check), the pack's name (`--zella-text`, semibold) and a one line description
  (`--zella-text-2`), and its price "$29 one time" on the right; a ticked row takes `--zella-primary-soft` and
  `--zella-primary-border`; the keyboard focus ring is `--zella-focus` on the drawn box. Ticked packs are receipt lines
  (icon `add_circle`), with "Add ons are one time." under the total (on Pay now instead "Add ons are charged right
  after your plan."); a change of total is announced politely ("Total due today
  $278."). Below 360px the price moves under the name. Locked (dimmed, not clickable) while a start is in flight.
- **"I agree" box above Pay** (`ConsentBox`, `.zgc-consent`): a real checkbox (`accent-color: --zella-primary`,
  focus ring `--zella-focus`) with its label, on `--zella-subtle` with `--zella-border`; "Terms" and "Privacy Policy" are
  `.ba-link`s opening in a new tab (each with a screen reader "opens in a new tab"). Unticked, Pay keeps its place
  and its focus but looks disabled (`.zgc-pay-btn.is-blocked`, `aria-disabled="true"`); pressing it shows the error
  under the box (`--zella-danger`, `role="alert"`, the box's border `--zella-danger-border`). Pay buttons show the full
  total: "Pay $278" (it first opens Stripe's card form, then pays).
- **Add on progress after Pay now** (`AddonProgress`, `.zgc-addon-progress`): a card under the checkout once the plan
  payment is confirmed, one row per add on: adding (`hourglass_top`), added (`--zella-success-bg`,
  `--zella-success-border`) or "Plan paid. 100 minutes not added" (`--zella-danger-bg`, `--zella-danger-border`) with
  Try again for that pack only; announced politely.
- **Card problems** (`.zgc-field-error`, `.zgc-decline`, `.zgc.is-bankwait`, `.zgc-bank-preview`): Stripe's inline words
  under a field in `--zella-danger` (the slot's border `--zella-danger-border`); a declined card in the Payment details
  panel on `--zella-danger-bg` with `--zella-danger-border`, an icon, the title, what it means and "Try another card";
  while the bank checks, the status says "Waiting for your bank to confirm" and the card's motion pauses; the local
  preview's bank check is a modal card (`--zella-card`, `--zella-shadow-pop`, over `--zella-overlay`) with a "Preview
  only" badge and Approve, Fail and Close.
- **The card picture**: a photoreal ISO card (85.6 by 54 mm, corners 3.5% of the width) built from the look's
  primary (midnight, mocha, copper or the picture's colour): layered radial and linear gradients, film grain (an SVG
  `feTurbulence` texture), a holographic brushed sheen that moves with the pointer or the device's tilt, a thin bevel,
  a perspective drop shadow, and a slight 3D angle at rest. Real card layout: a gold EMV chip with contact pads
  (`--zella-metal-1` to `-3`) left of centre with the contactless mark beside it, the number across the middle in
  embossed monospace ("OCR A" when the device has it, then Courier New, then the system monospace; `--zella-sheen`
  above, `--zella-emboss-low` below), the cardholder name bottom left, "VALID THRU" and the expiry, and the brand
  bottom right as plain text (no licensed network artwork was available, so no logos). The back: a magnetic stripe, a
  signature panel (`--zella-on-primary` on `--zella-primary`, readable in every look) and the security code box
  showing "•••". **Live fill (NN-9 safe):** the brand appears as Stripe's card number field reports it; the part
  being typed is highlighted; focusing the security code turns the card over; once Stripe's preview returns, the
  number reads "•••• •••• •••• 4242" and the expiry "12/28". The name is the one typed in Stripe's billing address,
  in capitals; the address itself never shows. It **never shows the Zella Voice name**: it is the customer's card.
  After the server confirms, it shows the issuing bank (only Stripe's own `card.issuer`, as text) in the corner, the
  brand and "•••• •••• •••• 4242", on `--zella-success` with `--zella-on-success` text. On a fine pointer it tilts slightly and a highlight follows the pointer. In the local preview only, Payment
  details shows a static picture of Stripe's fields and billing address (divs, aria-hidden, no input, badged "Preview
  of Stripe's form"), laid out in the country's format (United States: State and ZIP code; Canada: Province and Postal
  code), with a "Fill with Stripe's test card" button that plays the typing with fake data.
- **Checkout motion (owner approved exception to the calm CRM motion, 27 Nov 2026):** the reference video's motion in
  Zella Voice's own colours, 600 to 900ms each, with a light spring (`cubic-bezier(0.34, 1.32, 0.64, 1)`). When Stripe
  finishes, a frosted layer fades in over the panels (they blur and dim), and the card lifts off the left column and
  settles in the centre (transform only, measured once) while its shadow on the "table" widens and fades with the
  height. While confirming, a sheen sweeps across the card and a progress ring turns. When the server confirms, the
  card flips (its thickness shows while it turns) to the success colour, the check draws itself (stroke dash offset)
  and a `--zella-success` glow pulses twice; the title becomes "Payment confirmed" (pending the owner's confirmation;
  step 7 owns "You're all set"). Everything behind the layer is `inert`. With reduced motion there is no blur, tilt,
  highlight, flight, flip, shimmer, spin, glow or drawing: the states simply change.
- **A payment's own page** (`web/src/billing/BillingPayRoute.jsx`, `.zpay-route`; owner, 27 Nov 2026): inside the CRM
  shell, a back link "Billing and subscription" (`--zella-text-2`, underlined on hover and focus), the title at
  `--zella-text-page` ("Pay for your plan"; never an invoice number), then the glass checkout at full width (its summary
  panel: "Summary", "Your Pro plan", one "Covers" line, "Due today") (up to 1240px) and, once paid, a primary "Back to Billing
  and subscription". The overview's "Next payment" line is `.zpay-next`: information only, never a button.
- **Payments panel** (`web/src/billing/PaymentsPanel.jsx`, `.zpay` in `billing/payments.css`): the renewal line with
  the saved card and Update card, the invoices as rows (number and period, amount, a status chip with a word, Pay now
  or View, a link to Stripe's page), and the packs with Buy. Rows stack on a phone. Used in Settings > Billing and
  subscription > Invoices and payments and on the owner's `/pay` page.
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
  - Wording pass (owner, 25 Nov 2026), both apps: labels are sentence case, never spaced capitals; "still working" is
    one ellipsis character ("Loading…", "Trying again…"), and choices have no dots ("Choose"); a failed load says what
    didn't load and offers "Try again" (one name for that action); an empty list offers the page's own add button
    (`.ba-empty-actions` in the CRM); a figure that didn't load is a small note (`.ba-kpi-missing`), never a big
    "Not available"; a line joining facts reads as a sentence with commas, not middle dots. The CRM writes "and", not
    "&". Admin screens never show file names or database talk: a missing setup note says what isn't switched on, with
    any file name in the note's hover tip.
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
- Pop ups (`.ba-toast`) sit on the plain card colour: no colour wash, no confetti, and the bell doesn't shake. The
  tone shows in the coloured left edge, the icon and the label (owner, 25 Nov 2026).
- In the CRM, `noteStyle(n)` in `web/src/zellaVoice.js` gives each notification its icon, tone and label. The five
  tones are classes `tone-good`, `tone-brand`, `tone-info`, `tone-heads` and `tone-urgent` on `.ba-toast`,
  `.ba-note-icon` and `.ba-kicker` (`BusinessApp.css`), built only from the `--ba-success`, `--ba-primary`,
  `--ba-info`, `--ba-warning` and `--ba-danger` tokens and their soft backgrounds.

## Shared components (every new admin page uses these)

All in `web/src/admin/adminOps.jsx` unless noted; their look is in `web/src/styles/components.css`.

| Component | What it does |
| --- | --- |
| `PageHeader({ eyebrow, title, description, actions, updatedAt, onRefresh })` | The eyebrow is the sidebar group (Businesses, Configuration, AI & communications, Operations, Administration); the H1 is the sidebar label. "Updated 2:44 PM" and a small Refresh button sit in the header actions, left of the single primary button. Cards don't carry their own Refresh. |
| `Metric({ label, value, note, onClick })` and `.owner-stat-card` | One KPI card: label 13px secondary, value 32px medium (500) with tabular figures and a thousands comma, one line of note 12px (ellipsis; two lines on a phone), a fixed minimum height, no coloured icon tiles. A card that filters the list is a real button (`onClick`) with a chevron, hover border and focus ring. |
| `DataTable({ columns, rows, cards, selected })` | Columns are `[header, cell, className, label]`. Use `num` for numbers (right aligned, tabular) and `col-actions` for the action cell. With `cards`, each row becomes a card under 600px, labelled from `data-label`. Tables that stay tables on a phone fade at the right edge. |
| `Pager` | The one table footer (`.owner-table-foot`): "Showing 1 to 25 of 96" (or "3 shown") on the left, Previous and Next small buttons on the right, chevrons only under 600px. |
| `Drawer({ eyebrow, title, status, footer })` | A side panel: a 12px eyebrow ("Plan"), the title (the business name) at 18px, an optional status badge, and a sticky footer for its actions. Facts inside are a two column list (`.ao-facts`); sections use `.drawer-section h3`. |
| `Filters({ active, onClear })`, `Search`, `Select`, `Toggle` | One row of filters at 36px: search first, then selects and dates, yes or no filters as toggle chips (`aria-pressed`), Clear filters as a text button at the end. Under 600px they fold behind a "Filters (2)" button. |
| `Tabs` | Page tabs in one line that scrolls sideways. The selected tab (and selected filter chip) is the soft tint with a hairline, never a midnight fill. |
| Badges: `Pill` (`.op-pill`, `.owner-badge`), `statusTone(word)` | One 22px pill. Tones come from the status tokens; neutral is `--zella-subtle`. |
| `EmptyValue({ label })` | The word for a missing value, in faint text. See Writing. |
| Banners: `.banner-info`, `.owner-info-banner`, `.banner-warning` | An `info` icon (20px), the lead phrase in the tone colour at 600, the rest in body text at 400. In the admin an information note is neutral (see "Admin pages polish"). Two lines at most; more goes in a disclosure. `.banner-warning` is for inline notices next to a table ("1 job is not in the state recorded for it"). |
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

## Admin polish (owner, 25 Nov 2026)

The owner approved 21 admin dashboard changes on 25 Nov 2026 ("yes to all"): polish only, the Glass and Zella Voice
looks and the brand stay, admin only (every rule in a shared stylesheet is scoped to `.owner-app`, so the CRM does not
change). Design pass guided by unslop by heydamir (CC BY 4.0).

- **Labels:** sidebar group labels, the eyebrow above the page title and the "More below" cue are sentence case,
  12px, weight 500, no letter spacing. Group labels are `--zella-text-faint`, the eyebrow `--zella-text-secondary`.
  A group label has more space above it than below (16 and 8), so each group reads as one block.
- **Weight:** panel titles keep 600 as the one emphasis. The page title, KPI figures, buttons, links, pills and list
  names are 500. Inter Tight is loaded at 500, 700 and 800, so the Zella Voice page title draws the weight it asks for.
- **Numbers:** counts use the locale's thousands separator (3,182); pipeline counts and table cells use tabular figures.
- **Setup pipeline:** 8px bars with a 4px radius; every stage is `--zella-text` at 28% on `--zella-subtle`, only Live is
  the accent, with a 3px by 16px mark before its label like the selected menu item. Live is coral `#FF4F2E` in the Zella
  Voice look, and the look's own `--zella-primary` elsewhere: mocha in Classic, copper (or the picture's copper) in Glass.
- **Icons:** buttons use Material Symbols (`refresh`, `add`), never typed symbols; menu and top bar icons are 18px.
- **Spacing:** one rhythm on the 4px grid: 24 between panels and under the KPI rows, panel headings 20 by 24, list
  rows 12 by 24, the pipeline 24 with 12 between rows.
- **Glass:** admin pages' entrance animations hold only their start state, so cards and panels really frost.
- **Motion:** one curve, `cubic-bezier(0.22, 1, 0.36, 1)`: 150ms for hover, 120ms press to 0.98, 200ms for menus and
  popups, the 350ms page rise. Buttons only change colour: no lift, glow, sheen, ripple or icon grow. Cards, panels
  and menu rows don't move or grow shadows under the pointer; no bounce or overshoot anywhere.
- **Copy:** panel captions have no full stop; the search box says "Search businesses".

## Admin pages polish (owner, 25 Nov 2026)

The owner approved the admin items for every page except Overview on 25 Nov 2026 ("yes to all A and C"). Polish only:
features, sections and their order stay; Glass, the dock, the picture palette, Classic and the Zella Voice look stay.
The rules live in `web/src/styles/admin-polish.css`, loaded last and scoped to `.owner-app` (or `html:has(.owner-app)`
for dialogs that open outside it), so the CRM does not change. A shared component change (the KPI card, the stat
"Not available", the icons) also reaches the Overview.

- **Corner and shadow steps (A22):** panels and dialogs 16 (`--zella-radius-panel`), stat cards 12
  (`--zella-radius-card`), notes and small boxes 8 (`--zella-radius-note`), and an item nested inside a panel or note
  takes the outer radius minus its padding, never under 4 (`--zella-radius-nested`; every admin panel pads 12 or more,
  so nested items such as module rows, alerts and provider boxes are 4). Panels and stat cards keep
  `--zella-shadow-sm`; notes and nested items have no shadow. On a phone a dialog keeps its sheet corners.
- **Neutral notes (A8, A57):** an information note is a light grey surface (`--zella-subtle`), a hairline border, a
  small grey `info` icon (18px) and text in `--zella-text`; the lead phrase is the text colour too. Warnings, errors
  and successes keep their tone. A "Not built yet" note (`Needs`) has a grey side bar and its title in the text
  colour; "What works today" is unchanged.
- **Number colours with a dot (A9, A33, A51):** a warning or danger figure on a stat card keeps the text colour; an
  8px dot before its label carries the tone (amber warning, red danger). States in a table are plain text with the
  same dot (`DotText` in `admin/adminOps.jsx`: green connected or accepted, grey not yet, red failed), never a
  coloured pill or a typed tick.
- **Not available (A10):** a stat card with no trustworthy number says "Not available" at 13px in faint text, not as a
  32px figure (`statValueClass`).
- **Weights and sizes (A6, A7):** emphasis is 600 and figures, badges and billing prices are 500; no admin text is
  bold (700). No admin text is under 12px (status labels, wizard step numbers, file lines, Settings badges and table
  heads, code lines, small notes).
- **Icons (A1):** Refresh, New, Add, Back, Continue, Close and every tick are Material Symbols (`refresh`, `add`,
  `arrow_back`, `arrow_forward`, `close`, `check`, `priority_high`), never typed symbols; the words stay.
- **Stat icons and the selected card (A11, A39):** stat icons are plain grey at 22px with no coloured tile; the
  selected count card is the soft tint with a hairline, like the selected tab.
- **Danger (A12, A13):** a danger action on a row or card is a quiet button with red text (36px, border
  `--zella-border-strong`); only the confirm button in its dialog is full red, and the dialog keeps its normal border.
- **Motion (A23, A24):** the setup wizard uses the one admin curve with no bounce on the current step, no shake on an
  error and no shadow on hover; with reduced motion the sidebar "More below" cue is shown or hidden, never faded.
- **Pages:** switched on modules keep the normal border (A35); the fallback number is the Phone numbers card's last
  row (A37); the offer form's Save and Cancel stay at the bottom while it scrolls (A44); the AI receptionists table
  fits at 1440 and Setup is "3 of 5 set" and its missing list in words, with no dots (A45, A46); Voice & numbers
  groups its nine equal tiles under Calls and Numbers (A47); a choice in a filter row is as wide as its longest option
  (A48); go live bars are grey and turn green when full (A49); every Audit logs filter control has the focus ring
  (A54); an opened audit entry lists what changed (field, before, after) with the raw record under "Show raw record"
  (A55); Reassign and Pause sit side by side (A59).

## Rules of use

- The primary colour (midnight in Zella Voice, mocha in Classic) is for primary buttons and key icons. Coral marks only
  what is selected or live. Most buttons are secondary (white with a border).
- Status badges always carry a word (Active, Pending, Failed). Colour backs the word up, never replaces it:
  green done or active, blue scheduled or informational, amber pending or warning, red failed, cancelled or urgent.
- Icons are Material Symbols Outlined (`<Icon name="..." />` from `BusinessUI.jsx`) in both apps.
- **CRM motion (owner, 25 Nov 2026, replaces the lively motion of 6 Nov 2026 for the CRM):** quiet and short. Nothing lifts, bounces,
  springs, shines or ripples. A hover is a colour or border change, a press scales to 0.98, the page eases in once
  (40ms apart), menus open in 200ms, all on one curve `cubic-bezier(0.22, 1, 0.36, 1)`. A centred dialog
  (`.ba-modal`, `.zs-dialog`, `.bd-confirm`) opens with a 200ms fade only, no rise or scale. Two movements stay, as
  approved: the phone bottom sheet (under 768px, the phone layout, REQ-MOB-06) slides up from the bottom edge in 300ms, and the booking side panel
  slides in from the side (`bp-slide`). The live dot and numbers counting up stay. Rules in `web/src/styles/crm-polish.css`, scoped to `html:has(.ba-root)`, so the
  admin dashboard is not affected.
- Motion in both apps is calm since 25 Nov 2026 (the CRM motion rule above, and "Admin polish" below for the admin
  dashboard), which replaces the lively motion of 6 Nov 2026 (`web/src/styles/motion.css`, `web/src/CrmMotion.css`).
  All motion stops for people who prefer reduced motion.
- On phones (both apps under 768px) the bottom bar and the side panel replace the sidebar and the menu button (see
  "Phone navigation" below, owner 25 Nov 2026). Wide tables and tab rows scroll inside themselves, never the whole
  page, and fade at the right edge while there is more.
- The admin sidebar's background and border run the full height of the page (`.owner-sidebar-col`); only the nav inside
  it is sticky. The settings sub navigation (`.zs-nav`) is sticky at the top of its column.
- A short choice such as a period is as wide as its options (`<Field fit>` in Settings), not the whole row. A long
  table in a Settings card shows its first rows with a count and a "See all" button under it (`.zs-table-more`).
- Setting keys (`sms_live`, `calls_live`, ...) are code: pages say what they mean in words ("Texts are in test mode",
  `web/src/copy/liveSwitches.js`) and give the key only as a tooltip (`NotAvailable`'s `tip`, or a `title`).

## Phone navigation (owner, 25 Nov 2026)

All of P1 to P29 of the phone navigation proposal are approved for both apps ("Yes to all"). Owner decisions:

1. The header menu button is removed on phones; More opens the side panel.
2. Restaurant middle tab: Tables. Salon: Clients.
3. The work tab says "Calendar" for every industry.
4. Admin fourth tab: Operations.
5. Owners picking their own tabs: later, not now.
6. Live call status: later, as its own task. No "call in progress" strip and no unread inbox counts; the live strip
   shows callers waiting for a person (CRM) and open incidents (admin).
7. 768 to 1023 wide keeps the icon rail. Under 768 gets the bottom bar and side panel, including the admin's 600 to
   767 range.

Where it lives: `web/src/navigation/` (`phoneTabs.js` the tab rule, `phoneHelpers.js` pure helpers, `usePhoneLayout.js`
the browser hooks, `PhoneNav.jsx` the bar, panel, strip, toast, skeleton and swipe row, `BottomSheet.jsx`,
`CrmPhone.jsx`, `AdminPhone.jsx`) and `web/src/styles/phone-nav.css`, loaded last in `main.jsx`. Every rule is
scoped to `html.pn-phone`, which is only set under 768 wide, and reads the shared `--zella-*` tokens; no shared
stylesheet changes, so tablets and desktops look exactly as before.

| Part | Look and behaviour |
|---|---|
| Top bar | One slim row, 56px. CRM: the business (tap to switch, as a sheet), search, the bell. Admin: the Zella Voice bars, the page name once its heading has scrolled away, search, the bell. Zella Voice: paper at 92% with blur; Glass: frosted. |
| Bottom bar | Five tabs, each a full cell (56px tall plus the home area, never under 44 by 44): icon over an 11px label. The selected tab has a filled icon, darker text and a thin bar along its top edge (coral in Zella Voice, copper in Glass, mocha in Classic); More is selected for a page from the panel. Counts are red pills, capped at 99+, and part of the tab's name. A labelled navigation landmark. |
| Side panel | 320px (at most 86% of the screen), slides in from the left over the dimmed backdrop, radius 20px on its open edge. The desktop menu groups inside, with the selected item's coral bar. Business or platform card at the top, account rows at the bottom. A dialog called Menu. |
| Bottom sheet | Radius 20px at the top, a 36 by 5 handle (a button: Show more, Show less). A dialog a page draws itself (the booking panel, the admin dialogs and drawers) carries its own 32px drag strip (`<SheetGrip />` as its first child, hidden for screen readers, shown only on phones, touch-action none) and becomes a sheet the same way; its content keeps its normal scrolling. Half height (52% of the screen) or full (92%); a short one fits its content. Drag the handle or the heading. Glass: almost solid (`--glass-solid`). |
| Sticky action | One pill button, 48px, full width above the bar (plus a 48px round button for Quick actions on Today). |
| Live strip | A card above the bar with a 3px brand mark on its left edge, a live dot (stops with reduced motion) and a pill "Open" or "View". |
| Swipe row | Swipe left for a tray of 76px actions (blue Call, green Done); every row also has a round check and a "more" button. A hint line says what the swipe does. |
| Toast | Dark (light in Glass), above the bar, 5 seconds, Undo when the change can be undone. A plain message never replaces a toast that still offers Undo: it waits and shows when that toast ends. |
| Skeleton | Grey rounded shapes in `--zella-subtle`, a slow fade (none with reduced motion). |

Motion: one curve, `cubic-bezier(0.22, 1, 0.36, 1)`; panel 280ms, sheets 300ms, backdrop 200ms, a press of 150ms on
every tap (rows, tabs and buttons darken slightly and scale to 98%). Reduced motion turns every slide off. Phones on
the web can't vibrate, so there are no haptics.

## CRM look (owner approved, 25 Nov 2026)

Every CRM page except Today ("yes to all A and C": C9, C10, C16, C17, C18, C27, C29, C37, C40, C41, C42, C51). Same
language as the Today polish. Rules in `web/src/styles/crm-look.css`, every one scoped to `html:has(.ba-root)` and
loaded last from `web/src/main.jsx`, so the admin dashboard does not change. Glass, the dock, the picture palette,
Classic and the Zella Voice theme stay; no feature, section or order changed.

- **The accent means today or current:** `--crm-accent` is the look's primary (mocha in Classic, copper or the
  picture's copper in Glass) and coral `#FF4F2E` in the Zella Voice theme, where the primary is midnight.
- **Icons:** number cards carry a 16px icon in the faint text colour next to the label (`.crm-kpi-label`,
  `.crm-kpi-glyph`), never a coloured tile (Calendar, Tables, Spam protection, the check ins columns). Icons in lists
  (`.ba-thread-icon`: Integrations cards, Inbox, Messages and other rows) sit in a neutral `--zella-subtle` box with
  secondary text; red (`.bad`) stays only for failed or missed.
- **Charts:** soft grey bars (the text colour at 50%) with the latest day or today in the accent: Spam protection's
  "Incidents per day" (square topped bars) and Reports' "Calls per day" (the rounded voice bars, 14px wide, with
  date marks under the first, middle and last bar; the last reads "Today" while it is today, and the figures reload
  at the business's midnight; until they have, that bar shows its own date).
- **Calendar:** today's column has no fill; a 3px accent bar sits on top of its day name.
- **Reports figures:** each group is one row of compact cards (`.rp-kpis`: at least 150px each, 28px figures), so
  five calls figures never leave a hole; two per row on a phone.
- **Notifications:** see Notifications above.
- **Glass:** names on the filled floor plan tables (seated, reserved, clearing, blocked) use the dark glass base
  colour, because Glass makes those fills light (not on Today's compact plan card, which keeps white names); the note under the Integrations cards sits in a quiet glass panel.
- **Stars:** review stars are gold `#B7791F` on the light looks (3.6:1 against a white card, WCAG 1.4.11 asks 3:1)
  and keep `#E0A21B` on Glass.
- **Voice carousel:** in the CRM the chosen card keeps its accent border and a 1px ring, without the glow.
- **Tables page, compacted (owner feedback, 25 Nov 2026: "the table layout is showing way too enlarged"):** the
  floor plan fits its tables (`FloorPlan fit`, `web/src/floorPlanFit.js`). The saved positions are kept exactly: the
  plan is cropped to the tables' bounding box (with room for chairs) plus 28px padding, then one scale is applied to
  both axes so it fits the width and a height cap (the viewport less 540px, between 300 and 480px), so the plan sits
  beside the details panel without large empty bands. The scale stays at least 0.86 (14px names and seats stay at
  least 12px; the smallest table stays about 50px, over the 44px tap target) and at most 1, or 1.35 for a plan of up
  to 4 tables so it doesn't look tiny. A big plan that would scroll at the screen's cap may grow to 480px first;
  one still too big at 0.86 scrolls inside its box. Below 560px wide (phones) the plan keeps the full room drawing;
  Today's card and the layout editor are unchanged. The four counts are compact cards like the Reports figures
  (12px by 16px padding, 28px figures, the note on one line, about 100px tall).

## CRM polish (owner approved, 25 Nov 2026)

A design pass on the CRM Today page; the shared parts apply to the whole CRM. Glass, the dock, the picture palette
and the Zella Voice brand are kept; no feature, section or order changed. Files: `web/src/BusinessToday.jsx`, the
Today section of `web/src/BusinessApp.css`, and `web/src/styles/crm-polish.css` (every rule scoped to the CRM root,
loaded last from `web/src/main.jsx`).

- **Number cards:** a label, the figure (32px, weight 500, tabular) and its change; a small 18px icon in the faint
  text colour, no coloured tile.
- **Colour means something:** list and feed icons sit in a neutral 32px box (`--zella-subtle`, secondary text);
  only a missed call (danger) and a call handed to a person (warning) keep a colour. "To review" counts are plain
  danger text, not a bubble. The top guests mark uses the secondary text colour.
- **Calls this week:** the Zella voice bars, solid. Past days are the text colour at 50%; the chosen day is the
  accent (`--zella-primary` in Glass and Classic, coral `#FF4F2E` in the Zella Voice theme). No gradient, no glow.
  Each bar's number is printed above it. Measured on the rendered page (25 Nov 2026), grey bar against the card and
  against its track: Zella Voice 3.9:1 and 3.5:1, Classic 3.5:1 and 3.0:1, Glass over the Lounge picture 5.3:1 and
  4.6:1; the chosen day against the card: coral 3.3:1, Classic copper 8.1:1, Glass copper 9.0:1 (WCAG 1.4.11 asks 3:1).
- **Spacing:** the 4px grid; every Today card uses a 20px side inset for its head, tabs and body; 16px between the
  usage strip, the number cards and the card grid; cards in a row share one height.
- **Type:** weights 400 and 500 (600 only for the page title); sizes 12, 13, 14, 16, 28 and 32px on Today; figures
  without negative tracking; sidebar section names in sentence case (12px, 500).
- **"You are here":** a 3px accent bar on the selected sidebar item in every CRM theme, the Glass dock included.
- **Glass:** floating sidebar corners 20px and top bar 16px (the dock stays a pill); the "Plain" background is the
  flat warm base colour.
- **Phone (under 760px):** the date on its own line with the buttons under it; the bookings table folds guests,
  table, staff and status under the name and hides the notes, so it never scrolls sideways.
- **Motion:** see Rules of use above.

Guided by unslop by @heydamir (CC BY 4.0).

