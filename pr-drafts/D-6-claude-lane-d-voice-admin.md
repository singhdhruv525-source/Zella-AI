Voice admin: refused Vapi request counter, switches, missed call alert, real alert kinds (COM-09, COM-13, UI-14, COM-08)
base: claude/lane-d-resume-all

> **voice-rules deploy needs its own approval.** voice-rules is the live call path. This PR adds one counter call there and nothing else. The "Fix Vapi call auth" work may touch the same refusal lines (about 78 to 84); deploy after it, and merge by keeping both sides. No branch touching voice-rules/index.ts was found on the remote at the time of writing.

## What and why

- **COM-09:** a refused Vapi request was only logged to the console; nothing raised the `vapi_webhook` alert the page filtered on; the auth mode wasn't shown.
- **COM-13:** the Voice page showed only a banner when calls were off; usage enforcement for calls, the auth mode and the call jobs weren't shown.
- **UI-14 (alert):** no missed call rate alert.
- **COM-08:** "Needs attention" filtered five kinds nothing raises, and the real ones never showed.

`sql/zella_voice_admin.sql` (new, version guarded):
- `vapi_refusals`: an hourly counter by message type, reason and the auth header **names**. Never a value, payload or content (tested: no such column). Every input is folded to a short known list (unknown types and reasons become `other`, unknown header names are dropped), so a flood is one counted row, not one row each (200 refusals tested). Rows older than 30 days are deleted as new ones arrive. Server only.
- `zella_vapi_refusal_record(type, header names, reason)`: service role only.
- `zella_admin_voice_overview` (production md5 `f2eb6462c0ff90296786252005b50d4f`, archived): every existing key, plus `auth_mode`, `refusals_24h`, `last_refusal_at` and read only `switches` {`calls_live`, `enforcement_calls`, `vapi_auth_mode`, `jobs`: `zella_jobs_every5` (stuck and open call sweeps), `zella_jobs_every15` (call usage reconcile), `zella_jobs_hourly` (call verification), each on or off with its recorded intent}.
- `zella_admin_voice_alerts` (production md5 `54adf47cf26d62aab4249243e730c548`, archived): adds `missed_call_rate` and `vapi_refused`, **computed on read** so they need no timed job (most jobs are off), and lists the kinds really raised: `repeated_transfer_failures`, `call_volume_spike`, `ai_call_failure`, `agent_failures`, `agent_sync_failed`, `call_not_summarized`. The missed call alert carries a `filter` (status missed, direction inbound, 1 day, the business) for the Voice page tiles.

`web/supabase/functions/voice-rules`: `logic.ts` gets `refusalArgs` and `recordRefusal` (never throws, returns at once, uses `EdgeRuntime.waitUntil` where present); `index.ts` gets **one line** after the existing refusal log: the counter call, not awaited, right before the unchanged 401.

## Defaults taken (owner can change)
- Missed call alert: at least 5 inbound calls in 24 hours with 25% or more missed, severity warning (named constants `missed_min_inbound`, `missed_min_share`, `missed_window` in `zella_admin_voice_alerts`; plan.owner_decisions UI-14).
- Refused requests: any refusal in the last hour is a warning (`refusal_window`).

## Deploy order (each step needs the owner's approval)
1. SQL: `sql/zella_voice_admin.sql`. **Production md5s to be confirmed by the supervisor before apply.**
2. Edge function: `voice-rules`, **its own approval** (live call path; after "Fix Vapi call auth"). Before step 1 the counter call fails quietly and the 401 is unchanged.
3. Web app (the Voice page PR that follows).

## Fingerprints (isolated copy: zprod3, writing_cleanup, merged unapplied migrations)
- `zella_admin_voice_overview(timestamptz,timestamptz)` before `f2eb6462c0ff90296786252005b50d4f`, after `beb55e2f313319dce5322d40561aab19`.
- `zella_admin_voice_alerts()` before `54adf47cf26d62aab4249243e730c548`, after `65c91db2da69d8137fabd822f311fe3c`.

## Catalog (PLT-08, #93)
If #93 merges first, add the computed alert kinds `missed_call_rate` and `vapi_refused` (they are never written to platform_alerts; list them if the drift test reads `'kind', '...'` literals).

## Tests
- Automated local (isolated Postgres): `tests/voice_admin/run.sh`, 29 checks, ALL PASSED: the gaps first; apply twice; counter upsert under a flood (200 refusals, one row), folding, header names only, no value column, service role only, not readable directly; every overview key kept; auth mode, refusals, switches and call jobs as set; **missed call alert at 5 inbound with 40% missed, not at 4 (all missed), not at 24%, yes at 28%, older than 24 hours not counted**, warning with the filter; raised voice kinds show and others don't; the computed alerts read without dashes; refusal alert in the last hour only; wrong role, business member and anonymous refused; rollback twice restores both functions exactly and removes the counter; reapply; ROLLBACK_DRIFT; VERSION_MISMATCH.
- Deno: voice-rules `deno test` 44 passed, including the new test that a hanging, rejecting or throwing recorder returns at once and the call isn't awaited before the 401; `deno check index.ts`.
- Local run of voice-rules against the local stand in: three requests with a wrong credential each got 401 in under 0.13 s and the counter read 3 (`status-update`, `not_configured`, header `authorization`).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
