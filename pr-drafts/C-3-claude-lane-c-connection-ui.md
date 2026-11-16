Overview, AI agents and Integrations show the shared connected, answering and live states (COM-01, OPS-07, UI-02 part 2)
base: claude/lane-c-connection-state

## What and why
The pages now show what the server's one definition says (C2, `docs/PRODUCT.md` §9.1) instead of working it out themselves.
- **AI agents** (`web/src/AIAgents.jsx`):
  - Live, Answering and Ready to connect come from the server.
  - Each row shows Live or Not live and the answering line ("Answered a call 1 d ago" or "No call answered in 7 days"), and says what is still missing before it can be live ("Needs the number linked to Vapi").
  - There is a new Answering filter. Phone and Voice checks are relabelled "Active phone number" and "Number linked to Vapi".
  - The business line says "Setup finished" instead of the stage label "Live", so the word Live means one thing on the page.
- **Overview** (`web/src/OwnerOverview.jsx`): "AI receptionists live" uses the shared live count, with "N answered a call in 7 days" below it. The Businesses card note now says "N active" (finished setups), not "live".
- **Integrations** (`web/src/IntegrationsPage.jsx`):
  - The stat cards are Numbers linked, Live (with answering), Needs attention (all connection problems) and Waiting to connect.
  - Phone, Vapi link, calendar and lead sources come from the definition. Email reads "Not tracked" and never counts as waiting.
  - The integrations table is relabelled "Integration records" (store and other provider rows).
- Before the migration is applied, every state reads "Not available" (`connectionsAvailable: false`), never 0 or a guess.
- Shared words in the new `web/src/connectionState.js`.

**Not done here:** the Settings agent registry (AgentRegistry in `web/src/settings/AdminPanels.jsx`). That file is on the open polish branches (`claude/admin-ui-polish-1` and `-2`), so it waits for them to merge; it would then read the same `agents_list` fields. Voice & numbers belongs to Lane D.

## Defaults taken (owner can change)
The same definition and defaults as C2: a 7 day answering window, Live without needing a recent call, and email not tracked.

## Deploy order
Web deploy, with the owner's approval, after C2 (migration, then function) is live. If the web app goes first, it reads the old function's answer: the fields are missing, so the Live and Answering cards show "Not available", and nothing breaks.

## Tests
Automated, local:
- `node --test web/tests/connectionState.test.mjs` (3 tests) and `industryModules.test.mjs`, all pass.
- `npm run lint` 0 dashes, no new warnings in the changed files. `npx vite build` passes.
- The server tests from C2 still pass (`tests/connection_state/run.sh`, `pages.sh`).

Local browser crawl on the stand in (isolated database with the C2 fixtures and migration; 1440x900 and 390x844, deviceScaleFactor 1; no page errors, no failed calls, no sideways scroll):
- The same businesses agree on every page: Overview "2 live, 1 answered a call in 7 days"; AI agents Live 2, Answering 1; Integrations Live 2, "1 answered a call in 7 days".
- Business 1 is Live and answering on both pages. Business 6 is Live but "No call answered in 7 days (last 10 d ago)". Business 2 is Not live, "Needs the number linked to Vapi", and Integrations shows "Linked to Vapi · not connected". Email reads "Gmail · not tracked".
- Without the migration: Live, Answering and Ready to connect read "Not available", and Overview reads "Not available" and "Answering not available".
- Screenshots in `/tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-c/`:
  - c3-overview-1440.png, c3-overview-390.png
  - c3-agents-1440.png, c3-agents-390.png
  - c3-integrations-1440.png, c3-integrations-390.png
  - c3-agents-not-applied-1440.png

No migration.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
