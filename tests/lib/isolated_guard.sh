#!/usr/bin/env bash
# Sourced by test scripts before they build or change a database. Proceeds only when the target is the isolated local
# test server: a Unix socket (no network host), a server whose data directory is exactly
# /var/lib/postgresql/zella-sec/data (the throwaway cluster these tests start; fixed here, no setting can widen it),
# and a test database name (z..., lower case).
# A hosted database (Supabase) fails the check: it has a network host and doesn't let a client read data_directory.
# libpq settings that could send a connection somewhere other than the socket named with -h: cleared for the whole
# script that sources this file, so the guard and every later psql call connect the same way.
unset PGHOSTADDR PGSERVICE PGSERVICEFILE PGHOST PGPORT PGDATABASE
zella_require_isolated() {
  local host=$1 port=$2 db=$3 data; local -r want=/var/lib/postgresql/zella-sec/data
  case "$host" in /*) ;; *) echo "REFUSED: $host is not a local socket directory; these tests run only on the isolated test server" >&2; return 1;; esac
  # a plain path and a plain number only: nothing a later command line could split into extra options (e.g. "/sock -h prod")
  [[ "$host" =~ ^/[A-Za-z0-9/._-]+$ ]] || { echo "REFUSED: '$host' is not a plain socket directory path" >&2; return 1; }
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || { echo "REFUSED: '$port' is not a port number" >&2; return 1; }
  [[ "$db" =~ ^z[a-z0-9_]{1,40}$ ]] || { echo "REFUSED: '$db' is not a test database name (z..., lower case)" >&2; return 1; }
  # inet_server_addr() is null only over a Unix socket: a network connection is refused whatever it reports
  data=$(psql -h "$host" -p "$port" -U postgres -d postgres -qtAX -c "select case when inet_server_addr() is null then current_setting('data_directory') end" 2>/dev/null) \
    || { echo "REFUSED: could not confirm the server at $host:$port is the isolated test server" >&2; return 1; }
  [ -n "$data" ] || { echo "REFUSED: the connection to $host:$port is not over a Unix socket" >&2; return 1; }
  [ "$data" = "$want" ] && return 0
  echo "REFUSED: the server at $host:$port keeps its data in '$data', not in the isolated test cluster ($want)" >&2; return 1
}
