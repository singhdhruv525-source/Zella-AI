# Contrasting businesses x 28 industries through the call handler (5 Nov 2026)

`tests/calls/run.sh` builds an isolated database and serves the real `voice-rules` function (Vapi's server URL)
under Deno behind the local Supabase stand-in (`tests/browser/local-backend.mjs`). The database is:
- `sql/baseline`;
- the live fixes;
- production's 28 industry slugs (`industries_28.sql`; configuration only);
- the 17 pending migrations;
- `sql/zella_setup_enforcement.sql`.

`contrast_matrix.mjs` then sends Vapi-signed messages for two businesses per industry:

| | A "everything on" | B "held back" |
|---|---|---|
| setup | default booking abilities, a setup FAQ, a transfer phone, English + Spanish, own greeting, 2 hours' notice | booking, rescheduling and cancelling off; no FAQ; no transfer number |
| search_knowledge "parking" | the setup FAQ's answer | "no approved information" (nothing invented) |
| check_availability / book_appointment | times all at least 2 hours ahead; an offered time books (where the industry takes bookings; e-commerce refuses) | refused |
| cancel_appointment | — | refused |
| transfer-destination-request | its own number | refused with a message, no number |
| assistant settings (`zella_assistant_config`) | opens with the setup greeting; English and Spanish | tools leave out booking, rescheduling and cancelling |

## Results

- **With the fix: 28 industries, 56 businesses, 335 checks, all passed.**
- **The same run without `zella_setup_enforcement.sql`** (`WITHOUT_FIX=1 ZDB=zcalls_before tests/calls/run.sh`) fails 214 checks, in exactly the places the setup trace predicted (`docs/SETUP_FIELD_TRACE_2026-11-05.md`):

| Check that fails without the fix | Industries |
|---|---|
| B still offers booking, rescheduling and cancelling | 28 |
| B can still cancel | 28 |
| A's setup FAQ isn't answered | 28 |
| A doesn't open with its setup greeting | 28 |
| A isn't set up for English and Spanish | 28 |
| B can still check availability | 27 |
| B can still book | 27 |
| A offers times inside its 2 hours' notice | 27 |

E-commerce takes no bookings either way, which is why some rows show 27. The transfer checks pass in both runs, because
A's number was typed on the receptionist step. Numbers given only on the Integrations or Owner step are handled by
`owner-provision-business` (unit-tested, `setup_sync_test.ts`).

## Not covered

- Vapi itself: speech, the model's choices, and the hosted gateway.
- The function runs under Deno with the repository's lockfile, not inside Supabase's edge-runtime image (Docker isn't running here).
- The other session's `tests/runtime` covers `voice-rules` in that image.
