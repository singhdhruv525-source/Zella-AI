// Website reader for the n8n Website Crawler (security audit 18 Nov 2026, 5.4, M9). Pure functions, tested in
// logic_test.ts: which addresses may be read, which IP addresses may be connected to, and reading a plain HTTP/1.1
// answer. Nothing here connects anywhere.

// Names that are never a business's public website: internal suffixes, and wildcard DNS services that answer any
// name with any address (for example 127.0.0.1.nip.io resolves to 127.0.0.1).
export const DENY_SUFFIXES = ["localhost", "local", "internal", "lan", "home", "corp", "intranet", "localdomain", "test", "invalid", "example",
  "nip.io", "sslip.io", "xip.io", "nip.direct", "localtest.me", "lvh.me", "vcap.me", "lacolhost.com", "traefik.me", "localhost.direct"];

export type Target = { url: URL; host: string; port: number; https: boolean };
// the same rules as n8n/src/website-plan.js, checked again here because this is where the request is made
export function checkUrl(raw: unknown, ownerHost: unknown): Target | { error: string } {
  const url = typeof raw === "string" ? raw : "";
  const m = /^https?:\/\/([a-z0-9.-]+)(?::([0-9]{1,5}))?(?:[\/?]|$)/i.exec(url);
  if (!m || url.length > 2000 || /[\s<>"'\\]/.test(url)) return { error: "bad_url" };
  const host = m[1].toLowerCase();
  if (m[2] && m[2] !== "80" && m[2] !== "443") return { error: "bad_port" };
  if (!/\./.test(host) || /^\.|\.$|\.\./.test(host) || /^[0-9.]+$/.test(host)) return { error: "bad_host" };
  if (DENY_SUFFIXES.some((s) => host === s || host.endsWith("." + s))) return { error: "internal_host" };
  const strip = (h: string) => h.replace(/^www\./, "");
  if (typeof ownerHost !== "string" || strip(host) !== strip(ownerHost.toLowerCase())) return { error: "other_site" };
  let u: URL; try { u = new URL(url); } catch { return { error: "bad_url" }; }
  if (u.username || u.password || u.hostname !== host) return { error: "bad_url" };
  const https = u.protocol === "https:";
  return { url: u, host, port: u.port ? Number(u.port) : https ? 443 : 80, https };
}

function v4(ip: string): number[] | null {
  const p = ip.split(".");
  if (p.length !== 4 || p.some((x) => !/^\d{1,3}$/.test(x) || Number(x) > 255)) return null;
  return p.map(Number);
}
function v6(ip: string): number[] | null {   // 8 groups of 16 bits; an embedded IPv4 tail is allowed
  let s = ip.toLowerCase().split("%")[0];
  const tail = /:(\d+\.\d+\.\d+\.\d+)$/.exec(s);
  if (tail) { const b = v4(tail[1]); if (!b) return null; s = s.slice(0, -tail[1].length) + ((b[0] << 8) | b[1]).toString(16) + ":" + ((b[2] << 8) | b[3]).toString(16); }
  const halves = s.split("::");
  if (halves.length > 2) return null;
  const parse = (h: string) => (h ? h.split(":") : []).map((g) => (/^[0-9a-f]{1,4}$/.test(g) ? parseInt(g, 16) : NaN));
  const a = parse(halves[0]), b = halves.length === 2 ? parse(halves[1]) : [];
  const fill = halves.length === 2 ? 8 - a.length - b.length : 0;
  const g = [...a, ...Array(Math.max(fill, 0)).fill(0), ...b];
  return g.length === 8 && g.every((x) => Number.isInteger(x)) && (halves.length === 2 ? fill >= 1 : true) ? g : null;
}
// true only for an ordinary public address: never private, loopback, link local (cloud metadata), CGNAT, multicast,
// reserved, documentation, or an IPv6 form that carries one of those
export function isPublicAddress(ip: string): boolean {
  const a = v4(ip);
  if (a) {
    const [x, y] = a;
    if (x === 0 || x === 10 || x === 127 || x >= 224) return false;                      // this network, private, loopback, multicast, reserved
    if (x === 100 && y >= 64 && y <= 127) return false;                                   // CGNAT (and 100.100.100.200 metadata)
    if (x === 169 && y === 254) return false;                                             // link local, 169.254.169.254 metadata
    if (x === 172 && y >= 16 && y <= 31) return false;
    if (x === 192 && (y === 168 || (y === 0 && (a[2] === 0 || a[2] === 2)) || (y === 88 && a[2] === 99))) return false;
    if (x === 198 && (y === 18 || y === 19 || (y === 51 && a[2] === 100))) return false;  // benchmarking, documentation
    if (x === 203 && y === 0 && a[2] === 113) return false;
    return true;
  }
  const g = v6(ip);
  if (!g) return false;
  if (g.slice(0, 7).every((x) => x === 0)) return false;                                  // :: and ::1
  if (g.slice(0, 5).every((x) => x === 0) && (g[5] === 0xffff || g[5] === 0)) return false;              // IPv4 mapped or compatible
  if (g[0] === 0x64 && g[1] === 0xff9b) return false;                                     // NAT64
  if ((g[0] & 0xfe00) === 0xfc00) return false;                                           // unique local (fd00:ec2::254 metadata)
  if ((g[0] & 0xffc0) === 0xfe80 || (g[0] & 0xffc0) === 0xfec0) return false;            // link local, site local
  if ((g[0] & 0xff00) === 0xff00) return false;                                           // multicast
  if (g[0] === 0x2001 && (g[1] === 0x0db8 || g[1] < 0x0200)) return false;                // documentation, Teredo and other special use
  if (g[0] === 0x2002) return false;                                                       // 6to4 carries an IPv4 address
  return (g[0] & 0xe000) === 0x2000;                                                       // global unicast only
}

// every address the name resolves to must be public (one private answer refuses the whole name); the first is used
export function pickAddress(addresses: string[]): string | null {
  if (!addresses.length || addresses.length > 32) return null;
  return addresses.every(isPublicAddress) ? addresses[0] : null;
}

export const MAX_BYTES = 2_000_000;
export function request(t: Target): string {
  const path = (t.url.pathname || "/") + t.url.search;
  return `GET ${path} HTTP/1.1\r\nHost: ${t.host}${(t.https ? t.port !== 443 : t.port !== 80) ? ":" + t.port : ""}\r\n`
    + "User-Agent: ZellaBot/1.0 (reads pages its owner approved)\r\nAccept: text/html,application/xhtml+xml,application/xml;q=0.9\r\n"
    + "Accept-Encoding: identity\r\nConnection: close\r\n\r\n";
}

// a whole HTTP/1.1 answer (the connection was closed after it) -> what the crawler's parser reads
export type Answer = { statusCode: number; headers: Record<string, string>; body: string; truncated: boolean };
export function parseAnswer(bytes: Uint8Array): Answer | null {
  // informational answers (100 Continue, 103 Early Hints) come first: skip them to the final answer
  let start = 0, end = -1, head: string[] = [], m: RegExpExecArray | null = null;
  for (let tries = 0; tries < 5; tries++) {
    end = -1;
    for (let i = start; i + 3 < bytes.length && i < start + 65536; i++) if (bytes[i] === 13 && bytes[i + 1] === 10 && bytes[i + 2] === 13 && bytes[i + 3] === 10) { end = i; break; }
    if (end < 0) return null;
    head = new TextDecoder("latin1").decode(bytes.subarray(start, end)).split("\r\n");
    m = /^HTTP\/1\.[01] (\d{3})/.exec(head[0] ?? "");
    if (!m) return null;
    if (!m[1].startsWith("1")) break;
    start = end + 4; m = null;
  }
  if (!m) return null;
  const headers: Record<string, string> = {};
  for (const line of head.slice(1)) {
    const i = line.indexOf(":");
    if (i > 0) { const k = line.slice(0, i).trim().toLowerCase(); if (["content-type", "location", "transfer-encoding", "content-length"].includes(k)) headers[k] = line.slice(i + 1).trim().slice(0, 2000); }
  }
  let body = bytes.subarray(end + 4);
  if (/chunked/i.test(headers["transfer-encoding"] ?? "")) {
    const out: number[] = []; let i = 0;
    while (i < body.length) {
      let j = i; while (j + 1 < body.length && !(body[j] === 13 && body[j + 1] === 10)) j++;
      const size = parseInt(new TextDecoder().decode(body.subarray(i, j)).split(";")[0].trim(), 16);
      if (!Number.isFinite(size) || size <= 0) break;
      const from = j + 2; for (let k = from; k < Math.min(from + size, body.length); k++) out.push(body[k]);
      i = from + size + 2;
    }
    body = new Uint8Array(out);
  } else if (/^\d+$/.test(headers["content-length"] ?? "")) {
    body = body.subarray(0, Number(headers["content-length"]));
  }
  const truncated = body.length >= MAX_BYTES;
  const charset = /charset=([a-z0-9_-]+)/i.exec(headers["content-type"] ?? "")?.[1]?.toLowerCase();
  let text: string;
  try { text = new TextDecoder(charset && charset !== "utf8" ? charset : "utf-8").decode(body.subarray(0, MAX_BYTES)); } catch { text = new TextDecoder().decode(body.subarray(0, MAX_BYTES)); }
  return { statusCode: Number(m[1]), headers: { ...(headers["content-type"] ? { "content-type": headers["content-type"] } : {}), ...(headers.location ? { location: headers.location } : {}) }, body: text, truncated };
}
