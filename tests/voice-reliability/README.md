# Voice reliability tests (staging only)

`run_all.sh` builds two local databases from the repo's SQL: `zbase` (the live functions as they are) and `zvoice`
(the same plus `sql/zella_voice_reliability.sql` and `sql/zella_vapi_auth.sql`). Then it runs the same tests on both.
Never point it at production. `spam_compat.sh` builds two more (`zsv`, `zvs`) with spam protection applied before and
after, and runs the tests again on both.

- `tables.sql`: the live table definitions (columns, defaults, checks, keys, indexes) for the 24 tables involved, as
  reported by the production catalog on 2026-10-27; no data.
- `prod_md5.txt`: md5 of each live function body (`prosrc`). `build_functions.py` picks the repo definition with the
  same md5 (raw or comment-stripped), `rebuild_ai_voice.py` reproduces `zella_ai_voice` (repo body plus the caller
  patch), and `live_two.sql` holds the two bodies that exist only in production. The run stops unless all 33 match.
- `spam_tables.sql`, `spam_md5.txt`: the extra tables and the two live helper functions spam protection needs.
- `auth_test.sql`: the Vapi signature check; `spam_compat.sql`: blocked callers, requests and status events with both.
- `vapi-client.mjs`: signs test requests like Vapi's HMAC credential; `brain-e2e.mjs`: the 14 Brain tools over HTTP;
  `bench.sh` / `bench.mjs`: latency of the synchronous path (run after `run_all.sh`; `ZDB=zvs` for the spam database).
- `race.sh`: N sessions held on an advisory-lock barrier, released at the same instant.
- `*_test.sql`: assertion blocks; `brain-flow.mjs`: the shipped Brain Tools code nodes against the patched functions;
  `edge-e2e.mjs` + `mock-rest.mjs`: the `voice-rules` function over HTTP against the staging database.

Run: `DENO=<path to deno> tests/voice-reliability/run_all.sh` and `.../spam_compat.sh` (needs a local Postgres; set
`ZPSQL` to its psql command). Secrets used are generated test values only.
