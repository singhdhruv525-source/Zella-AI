One definition of connected, answering and live: SQL and function (COM-01, OPS-07, UI-02 part 1; COM-06 Live)
base: claude/lane-c-industry-modules

## What and why
The AI agents, Integrations and Overview pages and the operations health count each worked "connected" out on their own, mostly from the `integrations` table, which only the store connection writes. So four pages gave four answers about the same business (UI-02). The definition now lives once, in SQL.

`sql/zella_connection_state.sql` adds three new functions and replaces nothing:
- `zella_connection_state(uuid[])`: the definition. Private, with no grants.
- `zella_business_connections(uuid[])`: one row per business, for `businesses.view` or server code.
- `zella_connection_counts()`: the same definition summed over every business.

In owner-provision-business (Lane C ranges only):
- `agentsList`: phone and voice checks, `live`, `answering`, `lastServedAt`. `stats.live` now uses the one Live definition (COM-06). `stats.answering` is new, and `readyToConnect` now means "set up but not linked to Vapi".
- `integrationsOverview`: phone, voice, calendar and leads come from the definition, plus `voice.answering`, `live`, `problems`, `counts` and `connectionsAvailable`. Email is `connected: null, tracked: false`.
- `overviewData`: `receptionistsLive` and `receptionistsAnswering` from the counts. `receptionistsSwitchedOn` keeps the old status only number under an honest name.
- `platformStatus`: only the `brokenIntegrations` line changed. It now counts connections that need attention, falling back to the integrations count until the migration is applied.
- Before the migration is applied, the pages get `connectionsAvailable: false` and a null live count instead of a guess.
- The UI that shows these states is the next PR (C3).

## Shared with Business detail
Signature (stable; the Business detail job can call it from the function with the server key, or from the browser as an admin with `businesses.view`):

```sql
public.zella_business_connections(p_business_ids uuid[])
RETURNS TABLE(business_id uuid, business_state text,  -- 'active' | 'setup' | 'suspended' | 'cancelled'
  receptionist text,                                    -- default receptionist status: 'active' | 'paused' | 'disabled' | 'none'
  phone boolean, phone_numbers integer, vapi_linked boolean,
  answering boolean, last_served_at timestamptz,
  calendar boolean, leads boolean, lead_sources text[],  -- subset of {website, meta, google}
  email text,                                           -- always 'not_tracked'
  problems integer, live boolean)
-- at most 1000 ids per call (TOO_MANY_BUSINESSES), null is refused (BUSINESS_IDS_REQUIRED); NOT_ALLOWED without businesses.view
public.zella_connection_counts() RETURNS jsonb
-- {businesses, active, receptionists_active, phone, vapi_linked, answering, calendar, leads, live, problems, email: 'not_tracked'}
```

Helpers in `config.ts`: `connectionsFor(admin, ids)`, which chunks by 1000 and returns null when the function isn't applied, and `connectionCounts(admin)`.

`zella_business_readiness` (the readiness ladder, held by the Business detail job) is **not** changed. Its voice check still reads the integrations table. The Business detail job can switch its phone, voice and live checks to `zella_business_connections` when it agrees with this signature.

## Defaults taken (owner can change)
The definition is written in `docs/PRODUCT.md` §9.1 and `docs/ARCHITECTURE.md` REQ-ADM-21:
- **Answering window: 7 days** (`ANSWERING_DAYS`, the `knobs` CTE in `zella_connection_state`).
- **Live** = the business is active (onboarding finished, switched on, not suspended or cancelled), the default receptionist is `active`, and an active number has its Vapi number id. A recent answered call is not required.
- **Answering is never part of Live.** It can be 0 until the numbers send assistant-request to voice-rules, which is a provider change needing approval.
- **Email reads "not tracked"**, because no mailbox connection table exists.
- **Needs attention** = integrations in `error` or `disconnected`, calendars in `error` or `disconnected`, and Meta accounts in `needs_reconnect`, `error` or `disconnected`.

## Deploy order (each step needs the owner's approval)
1. Apply `sql/zella_connection_state.sql`. It adds new functions only, so the current function and app are unaffected.
2. Deploy `owner-provision-business`. If it is deployed first, the pages say the state isn't available, and nothing breaks.
3. The web app (C3) after that.
- Rollback: deploy the earlier function first, then `sql/rollback/zella_connection_state_rollback.sql`.

## Tests
Automated, local, on isolated databases (zprod3, then the writing cleanup, then the admin_permissions and admin_mfa migrations, then this one):
- `tests/connection_state/run.sh`, 30 checks, all pass:
  - the old rule's gap is reproduced first: a business with only integrations rows reads connected, and one with a linked number reads not connected;
  - apply, then apply again;
  - 8 fixture businesses each get the expected phone, Vapi link, answering, calendar, leads, problems and live;
  - the counts equal the per business rows summed;
  - a Zella Voice owner may read; read_only_admin is refused without `businesses.view` and allowed with it; a business owner is refused, even for their own business; anonymous gets permission denied; the private definition can't be called;
  - more than 1000 ids, or null, is refused;
  - rollback twice removes exactly the three functions;
  - reapply; the rollback refuses a changed function (ROLLBACK_DRIFT) and the migration stops on one (VERSION_MISMATCH).
- `tests/connection_state/pages.sh`, 5 checks: the real function under Deno against the local stand in.
  - Before the migration, the pages say live isn't available.
  - After it, AI agents (8 receptionists), Integrations (12 businesses), Overview and `platform_status` all match the SQL definition: 2 live, 1 answering, 3 need attention.
- Deno `config_test.ts`, 6 tests, including chunking by 1000 and the "not applied" fallback, while any other error is still raised. `deno check index.ts` is clean. `tests/industry_modules/run.sh` still passes.
- `npm run lint` 0 dashes; `npx vite build` passes (no web change in this PR).
- A production read only count is still needed to confirm the real values. It needs the owner's approval.

## Production md5s
The functions are new. The guard needs them to be absent, or exactly this file's versions: `zella_connection_state` f03b127e562815f7cf5c7897e283f46d, `zella_business_connections` adcf308f2984282e34b03ee2d72d125b, `zella_connection_counts` 0124fe13da3e43dd57ff6c1b37742fc6. It also needs `zella_admin_can(text)`, which exists on zprod3. Production md5s to be confirmed by the supervisor before apply: these three functions should not exist in production yet.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
