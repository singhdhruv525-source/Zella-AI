#!/usr/bin/env bash
# Restores the schema-only baseline (captured read-only from the live project on 2026-11-04: tables, constraints,
# indexes, functions, view, triggers, row security, policies, grants, storage policies; no rows, no secrets) into a
# fresh database on an ISOLATED Postgres, then applies any extra files in order. Never point this at production.
# 00_supabase_stubs.sql stands in for Supabase's own schemas (auth, storage, vault, net, cron) and is test-only.
# Production runs Postgres 17; on 16 the MAINTAIN grants are skipped (maintenance rights only).
# Usage: [ZPG_HOST=... ZPG_PORT=...] restore.sh <db name> [extra .sql files...]
set -u
DB="$1"; shift
H=${ZPG_HOST:-/var/lib/postgresql/zella-sec}; P=${ZPG_PORT:-55433}
B="$(cd "$(dirname "$0")" && pwd)"
. "$B/../../tests/lib/isolated_guard.sh"; zella_require_isolated "$H" "$P" "$DB" || exit 1
PSQL=(psql -h "$H" -p "$P" -U postgres -v ON_ERROR_STOP=1 -q -X)   # an array: each value stays one argument
psql -h "$H" -p "$P" -U postgres -qX -c "drop database if exists \"$DB\"" -c "create database \"$DB\"" >/dev/null || exit 1
sed "s/current_database_placeholder/\"$DB\"/" "$B/00_supabase_stubs.sql" | "${PSQL[@]}" -d "$DB" || { echo "FAILED at stubs"; exit 1; }
run() { # file
  { echo "set check_function_bodies = off; set search_path = public, extensions;"; cat "$1"; } | "${PSQL[@]}" -d "$DB" -f - || { echo "FAILED at $1"; exit 1; }
}
run "$B/01_tables.sql"
run "$B/02_constraints.sql"
for f in "$B"/05_functions_*.sql; do run "$f"; done
run "$B/03_indexes.sql"
run "$B/04_foreign_keys.sql"
run "$B/06_views.sql"
run "$B/07_triggers.sql"
run "$B/08_rls.sql"
run "$B/09_policies.sql"
VERSION=$("${PSQL[@]}" -d "$DB" -Atc "show server_version_num") || exit 1
{ echo "revoke execute on all functions in schema public from public;"; if [ "$VERSION" -ge 170000 ]; then cat "$B/10_table_grants.sql"; else grep -v "grant MAINTAIN " "$B/10_table_grants.sql"; fi; cat "$B/11_column_grants.sql" "$B/12_function_grants.sql" "$B/13_public_grants.sql"; } > "${TMPDIR:-/tmp}/zella-grants.$$.sql" && run "${TMPDIR:-/tmp}/zella-grants.$$.sql"; rm -f "${TMPDIR:-/tmp}/zella-grants.$$.sql"
run "$B/14_storage.sql"
for extra in "$@"; do run "$extra"; done
echo "restored $DB"
