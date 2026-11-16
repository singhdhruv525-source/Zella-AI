Missing routing: businesses without a transfer or fallback number (UI-17)
base: claude/lane-d-voice-admin

## What and why

**UI-17:** Voice, Call routing showed one business at a time, so nothing showed which businesses had no transfer or fallback number (the fallback number is required by REQ-BIL-34 and used by usage enforcement at 100%, COM-10).

- `sql/zella_admin_routing_missing.sql` (new function only): `zella_admin_routing_missing(p_limit, p_offset)`, `businesses.view`, read only. Lists businesses that aren't cancelled, with a default AI receptionist, where transfers are on but no transfer number is set (`escalation_rules.transfer_number` or `transfer_to.phone`, exactly as `zella_admin_routing_get` reads them), or no fallback number (`escalation_rules.fallback_number`). Transfers switched off aren't flagged for a transfer number. Suspended businesses are listed and marked. Paged, 1 to 100 rows, with the total.
- Web: `VoiceNumbersPage.jsx`, Call routing: a "Missing routing" list under the form; a row opens that business's routing form. The searchable picker is UI-26, not part of this PR.

## Deploy order (each step needs the owner's approval)
1. SQL: `sql/zella_admin_routing_missing.sql`. Production md5s to be confirmed by the supervisor before apply (new function `e3b06eca2cfa77abdcd6d998197e95f8`).
2. Web app.

## Tests
- Automated local (isolated Postgres): `tests/admin_routing_missing/run.sh`, 16 checks, ALL PASSED: the gap first; apply twice; transfer from `transfer_number` and `transfer_to.phone`, fallback from `fallback_number`; transfers off not flagged; routed, cancelled and no receptionist left out; suspended marked; paging and clamped limits; each row has the business id; wrong role, member and anonymous refused; rollback twice; reapply; ROLLBACK_DRIFT; VERSION_MISMATCH.
- `npm run lint` 0 errors, 0 dashes; `npx vite build` built.
- Local browser at 1440x900 and 390 wide, no page errors: the test business is listed with "Fallback number" missing, and its row opens its routing form (transfer number filled in). Screenshots `scratchpad/lane-d/shots/voice_routing_missing_*`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
