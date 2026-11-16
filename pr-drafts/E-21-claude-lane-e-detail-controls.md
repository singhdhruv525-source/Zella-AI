Business page controls: size form, module dependencies, filtered Review, before and after in Activity (web only)
base: claude/lane-e-detail-tabs

## What and why
The web halves of plan PRs 5, 6, 7, 8 and 12, plus BIZ-26 and BIZ-28 copy. The Businesses list job already gated the
write buttons on `can()` (BIZ-23); this adds what was left.
- **BIZ-04 (web):** no Activity tab when the server says `activityAllowed: false`.
- **BIZ-06 (web):** "Continue setup" is disabled, with a line saying why, while a suspended business's setup isn't
  finished.
- **COM-04 option B (label):** "Edit setup" on a live business opens a confirm: "What you save in setup, including the
  AI receptionist, applies from its next call." (Critic: the button opens the whole wizard, so the label stays "Edit
  setup" and the confirm says what applies; agree the wording with the list job's BIZ-15 and UI-03.)
- **UI-05 and BIZ-08 (web):** the Business size card is a labelled `owner-field`, a primary "Save size" disabled until
  changed, "Saving…", a status notice and friendly errors, through `business_size_save`; an older edge says "Not
  available yet".
- **CFG-02 (web):** modules use the server's `requires` (fallback to the old list), and a module whose dependency the
  industry doesn't offer is disabled with "Needs Calls, which this industry doesn't offer".
- **BIZ-31 (web):** Review (when documents exist, not for a cancelled business, businesses.manage only) goes to
  `/verification?business=<id>`; the queue sends `businessId`, filters in the browser too for an older edge, and offers
  "Show all". Upload keeps the wizard. (`VerificationQueue.jsx`: a few lines; tell lane B.)
- **BIZ-17 (web):** Activity rows show what changed, before and after (`business/changes.js`), "The newest 30 of N",
  rows with no actor read "Zella Voice system", a Support access list (BIZ-22), and action notices add `auditWarning`.
- **BIZ-26 copy:** "handed to n8n" and "apply sql/zella_onboarding.sql" and "Run by n8n" replaced with plain words.
- **BIZ-28:** every "None" on the page replaced (Not set, Not recorded, No problems, …); the checklist's "later" marker
  is an icon with the label "Not yet, can wait".

## Defaults taken (owner can change)
- Edit setup on a live business asks for confirmation.

## Deploy order
Web only; each part degrades on an older edge (missing fields hide, `Unknown action` reads "Not available yet").

## Tests
- Automated local: `node --test web/tests/*.test.mjs` 128 pass, 0 fail (new `businessChanges.test.mjs`).
  `npm run lint` 0 errors, check-dashes 0, catalog drift passes. `npx vite build` passes.
- Local browser (isolated `zle_ui`, real function), 1440x900 and 390 wide, deviceScaleFactor 1, no page errors, no
  failed requests, no sideways overflow:
  - `readonly@zella.test`: no Activity tab, no setup button.
  - `ops@zella.test` (businesses.manage, audit.view): saves the size (notice "Business size saved"); Edit setup on the
    live business opens the confirm; Activity shows "Changed business size" with "Size: medium → small" and the
    Support access list; on the suspended draft "Continue setup" is disabled.
  Screenshots in `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-e/shots/`:
  `ctl_readonly_overview_1440.png`, `ctl_readonly_overview_390.png`, `ctl_ops_liveconfirm_1440.png`,
  `ctl_ops_activity_1440.png`, `ctl_ops_activity_390.png`, `ctl_ops_suspended_1440.png`, `ctl_ops_suspended_390.png`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
