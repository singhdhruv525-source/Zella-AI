# Zella Voice

AI receptionist and multi-tenant CRM for small businesses (React + Vite web app, Supabase Postgres with RLS and
`zella_*` functions, Deno edge functions, n8n workers, Vapi voice).

**Every rule in the file below is binding. Read it before doing anything in this repository.**

@ZELLA_VOICE_RULES.md

How the system works: `docs/ARCHITECTURE.md`.

## Commands

- Web: `cd web && npm ci && npm run lint && npm run build`; unit tests `node web/src/<name>.test.mjs`
- Edge functions: `web/supabase/functions/check.sh` (type check), `deno test` in each function folder
- n8n: `node n8n/src/build.mjs` then `node n8n/test.mjs` (never hand-edit `n8n/workflows/*.json`)
- Database: `sql/baseline/restore.sh <db>` on an isolated Postgres, then `tests/security/run.sh`; never production
