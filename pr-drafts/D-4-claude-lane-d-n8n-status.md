Read n8n's own workflow status with a server side key (AUTO-N8N-STATUS)
base: claude/lane-d-go-live

## What and why

**AUTO-N8N-STATUS:** the Scheduler page said n8n's workflow activation and execution logs aren't read from n8n.

- `owner-provision-business/n8n.ts` (a helper imported by `ops.ts`; no new hook in index.ts): reads n8n's public API, `GET /api/v1/workflows?limit=250` and `GET /api/v1/executions?limit=250`, with `X-N8N-API-KEY`, a 5 second timeout, and https only (the key is never sent over plain http). Returns each Zella Voice workflow's active flag and last execution (status and times). Names read in plain words without dashes ("Follow up Texts"). The key and the address are never returned.
- `ops.ts`: `n8n_status` (`businesses.view`). `N8N_API_KEY` and `N8N_API_URL` join `SERVER_SECRETS`, so they appear on Operations' Services and on the go live checklist.
- Web: `web/src/settings/panels/N8nStatus.jsx` replaces the "aren't read from n8n" note in `N8nConfig` (Settings, n8n and Automations, Scheduler & n8n). **With `N8N_API_KEY` unset it says "Not connected yet"**; a refused key or an unreachable n8n is said plainly, with nothing marked confirmed.

Built against a stub only (blocked item: real data needs the owner to create the key in n8n and set both secrets).

## Defaults taken (owner can change)
- The address secret is `N8N_API_URL` (https only); the newest 250 executions are read to find each workflow's last run.

## Deploy order (each step needs the owner's approval)
1. Owner: create an n8n API key; set `N8N_API_KEY` and `N8N_API_URL` as Supabase secrets (optional; until then the page says Not connected yet).
2. Edge function: `owner-provision-business`.
3. Web app.

No migration.

## Tests
- Deno: `deno test` in owner-provision-business, 38 passed (n8n_test.ts against a stubbed n8n API: not connected without the key or address and nothing called; active flags and the newest execution per workflow; only Zella Voice workflows; the key sent only in the header to n8n and **never in the answer**, nor the address; a refused key, an n8n error, an unreachable n8n and a plain http address; the action and its permission); `deno check index.ts`.
- Authorization on the local stand in: anonymous 401, a business member 403, a `support_admin` without `businesses.view` 403, the owner 200 `{"configured":false}`.
- Web unit 115 pass; `npm run lint` 0 errors, 0 dashes; `npx vite build` built.
- Local browser at 1440x900 and 390 wide, deviceScaleFactor 1, no page errors: Automations, Scheduler & n8n and Settings, n8n say "Not connected yet" with the key unset. Screenshots `scratchpad/lane-d/shots/automations_n8n_status_*`, `settings_n8n_status_*`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
