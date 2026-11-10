// Shared database safety checks for local browser test harnesses.
const { execFileSync } = require("node:child_process");
const PSQL_ENV = Object.fromEntries(Object.entries(process.env).filter(([k]) => !["PGHOSTADDR", "PGSERVICE", "PGSERVICEFILE", "PGHOST", "PGPORT", "PGDATABASE"].includes(k)));

// Refuse anything but the isolated local test server (same rule as tests/lib/isolated_guard.sh): a Unix socket, a test
// database name, and a server whose data directory is exactly the throwaway cluster's (fixed; no setting widens it).
// Runs before any other SQL.
function requireIsolated(host, port, db) {
  const WANT = "/var/lib/postgresql/zella-sec/data";
  if (!/^\/[A-Za-z0-9/._-]+(?![\s\S])/.test(host)) throw new Error(`REFUSED: ${host} is not a local socket directory`);
  if (!/^[0-9]{1,5}(?![\s\S])/.test(port)) throw new Error(`REFUSED: '${port}' is not a port number`);
  if (!/^z[a-z0-9_]{1,40}$/.test(db)) throw new Error(`REFUSED: '${db}' is not a test database name (z..., lower case)`);
  let data = "";
  try { data = execFileSync("psql", ["-h", host, "-p", port, "-U", "postgres", "-d", "postgres", "-AtqX", "-c", "select case when inet_server_addr() is null then current_setting('data_directory') end"], { stdio: ["ignore", "pipe", "pipe"], env: PSQL_ENV }).toString().trim(); }
  catch { throw new Error(`REFUSED: could not confirm the server at ${host}:${port} is the isolated test server`); }
  if (!data) throw new Error(`REFUSED: the connection to ${host}:${port} is not over a Unix socket`);
  if (data !== WANT) throw new Error(`REFUSED: the server keeps its data in '${data}', not in the isolated test cluster (${WANT})`);
}

module.exports = { PSQL_ENV, requireIsolated };
