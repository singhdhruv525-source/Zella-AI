# Zella Voice target schema

The required database design of `docs/ARCHITECTURE.md` (§6 multi-tenant isolation, §7 domain model, §29 data schema),
written as executable Postgres DDL for Supabase.

**This is not a migration for the current production database. Never apply it to production.** The new build is created
from it, one reviewed migration at a time (build phase 2, architecture §24), following `ZELLA_VOICE_RULES.md`.

| File | What it is |
|---|---|
| `zella_voice_schema.sql` | Tables, composite tenant foreign keys, tenant-scoped uniques, the booking exclusion constraint, authorization helpers, integrity and audit triggers, row-level security, grants, storage policies |
| `industries_seed.sql` | The 28 industry configurations (§22.4): modules, terminology, booking models, record types, default services (no prices), automations, KPIs, AI profiles. **Generated**; do not edit by hand |
| `generate_industries.py` | Source of the industry seed: edit this, then run `python3 sql/target/generate_industries.py` |
| `test_isolation.sql` | Three-business isolation suite (§6.12), capacity and restaurant booking cases, industry engine cases |
| `test.sh` | Loads the schema into a fresh isolated local database and runs the suite, plus a concurrent double-booking race |

Run (isolated local test cluster only; the shared guard refuses anything else):

```bash
sql/target/test.sh
```

Last run: 54/54 checks passed on Postgres 16 (local, isolated). Production runs Postgres 17.

Design rules the schema enforces:
- every tenant table: `business_id NOT NULL`, `unique (business_id, id)`, composite foreign keys to other tenant tables;
- one phone number, assistant or sender maps to exactly one business;
- clients only read through row-level security; all writes go through server functions (§30);
- sensitive tables need manager or admin; location-limited members see only their locations;
- booking conflicts are prevented per business and resource: exclusive resources (one stylist, one table) by an exclusion
  constraint; shared resources (a multi-client stylist, a class, restaurant covers) by a capacity check under a
  per-resource lock. Several staff or tables at the same time never conflict; restaurants book tables, joined tables or
  covers by party size;
- audit log, usage ledger and consent history are append-only; private values never enter the audit log;
- files live under `<business_uuid>/…` in private buckets, served through server-signed URLs.
- industry-driven: Create Business applies the industry (`app_private.apply_industry`), a business can only switch on modules
  its industry offers and never switch off required ones, industry upgrades keep the business's customizations, and
  the app, AI and workers read `effective_config(business)`.
