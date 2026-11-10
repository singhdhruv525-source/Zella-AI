# Staging test for the industry migrations (4 Nov 2026)

`tests/staging/run.sh` builds an isolated staging database and tests the ten migrations as a deployment would run them.
Use an isolated Postgres only; never point it at production.

**What staging is made of**
- The production schema: `sql/baseline`, plus the hardening already live in production. Checked read-only against production on 5 Nov: tables, columns and policies are identical, and the patched functions match by checksum.
- Production's reference data: industries, configurations, modules, presets and automation templates. Checked identical by hash. Pass the export as `REF`; it contains no customer data.
- Synthetic businesses from `seed.sql`:
  - four shaped like production (counts and statuses only);
  - one per industry, with records in every type, plain access codes, transcripts and every role.

**What it proves**

| Step | What is checked |
|---|---|
| Apply | The ten migrations apply in order, each report printed. A second run changes nothing. |
| Data | Nothing is lost. Every record's data is unchanged, apart from private values, which move to private storage. Every live record re-saves through the new write path. |
| Settings and roles | No type holding records is switched off. Roles, transcripts, access codes and money behave correctly on real-shaped data. |
| Rollback | It returns schema and data exactly to the frozen "before" copy. After the new features are used, it keeps everything recorded. It refuses to run without the pre-deploy backups. A second deploy after a rollback works. |

`make_rollback.py` writes `sql/rollback/industry_2026_11_04_rollback.sql` from the before/after pair. Its data part is hand-written in `sql/rollback/industry_data_part.sql`.

```bash
REF=/path/to/reference_export.sql tests/staging/run.sh
```
