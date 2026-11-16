Incident updates, edit, paging and a similar open incident warning; dialogs instead of browser prompts (OPS-12, OPS-11)
base: main

Open after #93 merges: this branch is claude/lane-a-catalog plus a merge of origin/main (after #85, safe retry, which also edits PlatformMonitoring.jsx), plus one commit. Until #93 merges, its diff against main includes the catalog commits.

## What and why

- **OPS-12:** `sql/zella_incident_updates.sql` adds `platform_incident_updates` (admins who can see incidents read it; written only through `zella_incident_post_update`), `zella_incident_edit` (open incidents only, audited `platform.incident_edited` with before and after, nobody notified) and `zella_open_incident_checked` (returns SIMILAR_OPEN with the matching open incidents unless forced). Updates are audited `platform.incident_updated`. **`zella_open_incident` is not replaced**, so an older web app keeps working and the deploy order is free (the critic's SIMILAR_OPEN risk). The Incidents panel shows each incident's updates, posts one with Tell affected businesses (off by default), edits open incidents, warns about a similar open one with Open anyway, and loads older incidents 20 at a time.
- **OPS-11:** opening, publishing and resolving ask in a dialog instead of window.confirm and window.prompt, and the public status text starts empty (it was prefilled from the internal details).

Not built: showing updates on the public status page (`zella_public_status` unchanged), and a separate public title.

## Defaults taken (owner can change)

- Updates never notify businesses unless "Tell affected businesses" is ticked (`p_notify` false by default).
- "Similar": the same words after lower casing and removing punctuation, or one title containing the other, among open incidents.

## Deploy order (each step needs the owner's approval)

1. `sql/zella_admin_permissions.sql` must be applied first (it adds `zella_admin_can`, which these functions use).
2. Apply `sql/zella_incident_updates.sql`.
3. Deploy the web app (before the apply, it falls back to `zella_open_incident`; updates and edit say they need the database update).

## Tests

- Isolated database `tests/incident_updates/run.sh` (zprod3, then writing cleanup and admin permissions): ALL PASSED. The gap first (the same problem opens twice and owners are told twice); applies twice; SIMILAR_OPEN for the same and a longer title, nothing opened; force opens; a different problem opens; read only admin can't open, post or edit but reads the timeline; business owner and anonymous read nothing; no direct writes; internal update tells no one, Tell affected businesses tells owners; updates and edits audited; resolved incidents can't be edited; rollback refuses while updates exist, then runs twice; `zella_open_incident` untouched; reapply; VERSION_MISMATCH and DRIFT.
- Web unit tests, lint (the drift test caught both new audit actions until labelled), build. owner-provision-business Deno tests pass (unchanged).
- Local browser `tests/browser/incident-updates.cjs` at 1440x900 and 390 wide: open in a dialog; the similar warning; internal and notifying updates; edit audited; empty public text; resolve; 20 then Load more; no browser prompts; no page errors. Screenshots: /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/incidents/similar-desktop.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/incidents/similar-phone.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/incidents/public-text-desktop.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/incidents/public-text-phone.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/incidents/incidents-desktop.png, /tmp/claude-0/-home-user/58823c8d-9af3-5361-a674-6d6aa3bb79c6/scratchpad/lane-a/incidents/incidents-phone.png

## Production md5s to be confirmed by the supervisor before apply

All new; the guard expects them absent, or exactly this file's version on a rerun:
- `zella_incident_post_update(uuid,text,boolean)`: 1ecc82de3e0ecb6f1538033985357075
- `zella_incident_edit(uuid,text,text)`: e0215d925eed949c81af4ee8d21ac576
- `zella_incident_title_key(text)`: 4980429f996f03a32006003ada23cad3
- `zella_open_incident_checked(text,text,boolean)`: 4e398548b0542d880d50cf8beb377d2a

Computed on an isolated database (zprod3, then `zella_writing_cleanup.sql`, then the merged unapplied migrations).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_013Va58JdJpyGbAfXAEmDqgK
