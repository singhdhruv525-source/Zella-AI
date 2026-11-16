Audit log filters by person, dates, action and record, a cursor that never skips, and an audited CSV export (ACC-12)
base: claude/lane-a-refusals

## What and why

**ACC-12.** The audit log had only business and action filters, a `created_at` cursor that skipped entries with the same time, no user agent and no export.
- `auditLogList` (index.ts, lane A range) reads checked filters from access.ts: business, action (key `auditAction`, since `action` names the function's own action), person, from and to dates (to covers the whole day), record type and id; a malformed one is refused, never widened. It orders by (created_at, id) and pages with an exact `created_at|id` cursor (microseconds kept). It selects `user_agent` and returns the people list and `canExport`.
- `audit_export`: at most 10,000 entries as CSV, newest first; cells a spreadsheet would run as a formula (= + - @, tab, return) start with an apostrophe; action labels from the shared catalog; audited as `audit.exported` with the filters, row count and whether it was cut.
- AuditLogs.jsx: Person, From, To, Record type and Record id filters; the Action filter lists every catalog action; Details show the record id and browser; Export CSV for those allowed. ownerFormat.js is not edited (held by the Businesses list job).

## Defaults taken (owner can change)

- `AUDIT_EXPORT_ROLES`: export needs audit.view AND the Zella Voice owner or super admin role (the file holds addresses and browsers).
- `AUDIT_EXPORT_MAX_ROWS` = 10,000.

## Deploy order (each step needs the owner's approval)

1. Deploy `owner-provision-business`.
2. Deploy the web app. Either order works: the new function still accepts the old page's `search`, and an old function ignores the new filters.

## Tests

- Deno: filters checked and malformed ones refused; the function's own action never a filter; the cursor keeps the exact time and refuses injection shaped markers; the query order and `or` filter; CSV escaping; export roles; 2,500 rows exported once each; 10,050 cut at 10,000 and said so; the audit entry holds no file.
- Web unit test: the Action filter lists every catalog action, sorted; empty filters dropped. Lint, build.
- Local browser `tests/browser/admin-audit-log.cjs` (isolated database): 68 entries, 65 at the same instant, page through exactly once each; person and date filters; malformed filter and page marker refused; export refused for a read only admin, a business member and anonymous; the owner's export has 65 rows, formula cells defused, audited with filters; the page downloads the filtered CSV at 1440x900 and 390 wide; a read only admin sees no Export button; no page errors. Screenshots: /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/audit/audit-filters-desktop.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/audit/audit-filters-phone.png

No migration.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
