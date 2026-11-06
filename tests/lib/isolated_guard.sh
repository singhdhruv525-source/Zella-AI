#!/usr/bin/env bash
# Sourced by test scripts before they build or change a database. Proceeds only when the target is the isolated local
# test server: a Unix socket (no network host), a server whose data directory is under ZELLA_ISOLATED_DIR (default
# /var/lib/postgresql/zella-sec, the throwaway cluster these tests start), and a test database name (z..., lower case).
# A hosted database (Supabase) fails the check: it has a network host and doesn't let a client read data_directory.
zella_require_isolated() {
  local host=$1 port=$2 db=$3 dir=${ZELLA_ISOLATED_DIR:-/var/lib/postgresql/zella-sec} data
  case "$host" in /*) ;; *) echo "REFUSED: $host is not a local socket directory; these tests run only on the isolated test server" >&2; return 1;; esac
  [[ "$db" =~ ^z[a-z0-9_]{1,40}$ ]] || { echo "REFUSED: '$db' is not a test database name (z..., lower case)" >&2; return 1; }
  data=$(psql -h "$host" -p "$port" -U postgres -d postgres -qtAX -c "select current_setting('data_directory')" 2>/dev/null) \
    || { echo "REFUSED: could not confirm the server at $host:$port is the isolated test server" >&2; return 1; }
  case "$data" in "$dir"/*) return 0;; esac
  echo "REFUSED: the server at $host:$port keeps its data in '$data', not under $dir" >&2; return 1
}
