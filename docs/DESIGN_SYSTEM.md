# Zella design system

Warm, calm and light: ivory pages, a cream sidebar, white cards, and mocha for the things you act on.
Every page in the admin dashboard, the business CRM, Settings, sign-in and the public link pages uses it.

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

Type (Inter, loaded in `index.html`, with system fallbacks): page headings 28px semibold, section headings 16–18px
semibold, body 13–14px, navigation 14px medium, KPI values 32px bold, labels 13px medium, secondary text 12–13px.

Shape: 8px buttons and inputs, 10px small cards and banners, 14px cards, panels and modals. Shadows stay minimal.

## Components added with billing

- **Usage meter** (`.zs-usage`, `.zs-meter` in `web/src/settings/settings.css`): a label, "used of included", a bar, and what is left. The bar is mocha below 80%, amber from 80% and red at 100%, and the words say the same (a "Over 80%" or "Used up" badge), so colour never carries the meaning alone. It has `role="meter"` and an accessible label.
- **Billing layouts** (`web/src/billing.css`, `.bp-*`): the plan page puts the form (cards: Pricing, Monthly allowances, Account) beside a sticky summary card (price, estimated margin with a Healthy / Below target / Loses money label, cost lines, warnings, the review button); money inputs carry a `$` prefix and a unit suffix; Base/Pro, Monthly/Yearly and languages are segmented buttons (`aria-pressed`). The owner's plan page shows a plan header (name, status, price, next charge, what's included as chips) and one usage tile per resource. Below 1100px the summary moves under the form; below 760px everything is one column.

## Rules of use

- Primary mocha is for primary buttons, the selected navigation item, key icons and important actions. Most
  buttons are secondary (white with a border).
- Status badges always carry a word (Active, Pending, Failed). Colour backs the word up, never replaces it:
  green done or active, blue scheduled or informational, amber pending or warning, red failed, cancelled or urgent.
- Icons are Material Symbols Outlined (`<Icon name="..." />` from `BusinessUI.jsx`) in both apps.
- Motion is quiet: pages fade in once; nothing moves on hover. All motion stops for people who prefer reduced motion.
- On phones (CRM under 760px, admin under 600px) the sidebar opens as a drawer from the menu button in the top bar;
  it closes on Escape, on the backdrop, or when a page is chosen. Wide tables and tab rows scroll inside themselves,
  never the whole page.
