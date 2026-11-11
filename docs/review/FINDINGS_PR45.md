# CodeRabbit findings from singhdhruv525-source/Zella-AI#45 (web pages, settings and shared UI (part 2))

Fix list, in the order CodeRabbit posted them. CodeRabbit fixes them on this branch; each fix is checked and re-reviewed before merge.

- [ ] `web/src/admin/adminOps.jsx:208` — `DataTable` shows the "empty" text when the request failed.
- [ ] `web/src/admin/adminOps.jsx:304` — `AlertList` shows "Loading…" after a failed request.
- [ ] `web/src/admin/adminOps.jsx:326` — `useOptions` failures are silent and look like an empty business list.
- [ ] `web/src/admin/MessagingPage.jsx:223` — `changed` compares the trimmed body with the stored body, so it can be true when nothing was edited.
- [ ] `web/src/admin/VoiceNumbersPage.jsx:39` — The Numbers list and the open drawer are not refreshed after "Assign a number" or "Reassign or edit".
- [ ] `web/src/authErrors.js:47` — Do not render URL-supplied `error_description` as UI text.
- [ ] `web/src/copy/labels.js:80` — Guard the `LABELS` and `ACRONYMS` lookups against prototype keys.
- [ ] `web/src/formFields.css:9` — The focus ring can disappear.
- [ ] `web/src/formFields.jsx:13` — Replace the custom `useId` with `React.useId`.
- [ ] `web/src/formFields.jsx:246` — Password fields have an accessibility gap.
- [ ] `web/src/mfa.js:16` — Fail closed when the assurance-level lookup fails.
- [ ] `web/src/settings/BusinessLeadPanels.jsx:154` — A failed `lead_questions` read is shown as an empty list.
- [ ] `web/src/settings/BusinessLeadPanels.jsx:171` — Add an in-flight guard to `move`.
- [ ] `web/src/settings/BusinessLeadPanels.jsx:212` — Saving a rule can silently drop match conditions.
- [ ] `web/src/settings/BusinessLeadPanels.jsx:356` — Nested labels make the group label toggle "Owner".
- [ ] `web/src/settings/CallingUsagePanels.jsx:35` — Changing the date range keeps the old page number.
- [ ] `web/src/settings/CallingUsagePanels.jsx:82` — "Not yet" is never shown.
- [ ] `web/src/settings/LanguagePanel.jsx:48` — Changing the main language leaves it in `extras`, which blocks the three-language limit.
- [ ] `web/src/settings/settings.css:81` — Use separate classes for the checkbox row and checklist marker.
- [ ] `web/src/settings/SettingsKit.jsx:100` — `useAsync` shows stale data and lets stale responses overwrite newer ones.
- [ ] `web/src/settings/SettingsKit.jsx:128` — `save` discards edits typed while the request runs.
- [ ] `web/src/settings/SettingsWorkspace.jsx:95` — Real links block Ctrl/Cmd/Shift-click and middle-click.
- [ ] `web/src/UsersAccess.jsx:83` — Trim the email before sending it, and ignore a submit while a request is running.
- [ ] `web/src/VerificationQueue.jsx:80` — Ignore stale `load` responses and clear the old list when the tab changes.
- [ ] `web/src/WaitlistOffer.jsx:71` — Add a fallback for an unknown `res.reason`. The page can show a blank card or "Checking your link..." forever.
- [ ] `web/src/appearance.js:57` — Tighten the `customUrl` check so it accepts only Zella's own storage.
- [ ] `web/src/crm/pagingState.js:31` — Block `next` while the displayed data does not belong to `state.page`.
- [ ] `web/src/navigation/Sidebar.jsx:126` — Fix the menu keyboard and focus behavior in `useMenu`.
- [ ] `web/src/ownerFormat.js:35` — Guard `actionLabel` against a missing `action`.
