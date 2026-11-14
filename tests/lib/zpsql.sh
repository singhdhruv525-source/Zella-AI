#!/usr/bin/env bash
# Sourced by the scripts that pass a psql command line to helpers in ZPSQL (tests/features, tests/voice-reliability).
# ZPSQL is always built here from the isolated test server's socket and port. A ZPSQL already in the environment is
# ignored: it could name any server, so the guard could not check it. Call zella_require_dbs with every database the
# script creates or uses before touching any of them.
_zpsql_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=isolated_guard.sh
. "$_zpsql_dir/isolated_guard.sh"
export ZPG_HOST=${ZPG_HOST:-/var/lib/postgresql/zella-sec} ZPG_PORT=${ZPG_PORT:-55433}
export ZPSQL="psql -X -q -At -v ON_ERROR_STOP=1 -h $ZPG_HOST -p $ZPG_PORT -U postgres"
zella_require_dbs() {
  local db
  for db in "$@"; do zella_require_isolated "$ZPG_HOST" "$ZPG_PORT" "$db" || return 1; done
}
