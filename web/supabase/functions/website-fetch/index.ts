// Zella Voice - website-fetch: reads one page of a business's own website for the n8n Website Crawler (security audit
// 18 Nov 2026, 5.4, M9). The crawler used to fetch the address itself after checking only the text of the name, so a
// name that resolves to a private or cloud metadata address could be read back as "website knowledge".
//   POST { url, host }   the server key only (the crawler's Supabase service role credential). The address is checked again
//                        (n8n/src/website-plan.js rules, plus wildcard DNS services such as nip.io), the name is
//                        resolved here, and EVERY address it resolves to must be public (no private, loopback, link
//                        local or metadata, CGNAT, multicast, reserved or IPv6 local ranges). The request then goes
//                        to that exact address (TLS still checks the certificate for the name), so a second DNS answer
//                        can't swap it. No redirects are followed; at most 2 MB is read; 15 seconds in all.
//   Answers { statusCode, headers: { content-type, location }, body } in the shape the crawler's parser reads, or
//   { error } with statusCode 0.
// verify_jwt is off (config.toml): the server key is not a JWT; it is compared here.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { asObject, readJsonLimited } from "../_shared/body.ts";
import { checkUrl, MAX_BYTES, parseAnswer, pickAddress, request, type Target } from "./logic.ts";

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const refused = (error: string) => json({ statusCode: 0, error, headers: {}, body: "" });
function same(a: string, b: string) { if (a.length !== b.length) return false; let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i); return d === 0; }

export type Net = {
  resolve: (host: string) => Promise<string[]>;
  // connect to exactly this address; for https the certificate is checked for `host`
  exchange: (address: string, t: Target, req: string, signal: AbortSignal) => Promise<{ bytes: Uint8Array; remote: string }>;
};

async function readAll(conn: Deno.Conn, signal: AbortSignal): Promise<Uint8Array> {
  const parts: Uint8Array[] = []; let n = 0; const buf = new Uint8Array(32 * 1024);
  while (n < MAX_BYTES + 65536) {
    if (signal.aborted) throw new Error("timeout");
    const r = await conn.read(buf);
    if (r === null) break;
    parts.push(buf.slice(0, r)); n += r;
  }
  const out = new Uint8Array(n); let o = 0; for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}
export const realNet: Net = {
  resolve: async (host) => {
    const [a, aaaa] = await Promise.all([Deno.resolveDns(host, "A").catch(() => [] as string[]), Deno.resolveDns(host, "AAAA").catch(() => [] as string[])]);
    return [...a, ...aaaa];
  },
  exchange: async (address, t, req, signal) => {
    let conn: Deno.Conn = await Deno.connect({ hostname: address, port: t.port });
    const remote = (conn.remoteAddr as Deno.NetAddr).hostname;
    const close = () => { try { conn.close(); } catch { /* closed */ } };
    signal.addEventListener("abort", close, { once: true });
    try {
      if (t.https) conn = await Deno.startTls(conn as Deno.TcpConn, { hostname: t.host });
      await conn.write(new TextEncoder().encode(req));
      return { bytes: await readAll(conn, signal), remote };
    } finally { close(); }
  },
};

export async function handle(req: Request, net: Net = realNet): Promise<Response> {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  // the server key, or the service role key the crawler's n8n credential carries (n8n/README.md)
  const keys = [Deno.env.get("ZELLA_SERVER_SECRET_KEY") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""].filter((k) => k.length >= 20);
  if (!keys.length) return json({ error: "not_configured" }, 503);
  const auth = req.headers.get("authorization") ?? "";
  if (!keys.map((k) => same(auth, `Bearer ${k}`)).includes(true)) return json({ error: "server_only" }, 401);
  const read = await readJsonLimited(req, 8_000);
  const body = read.ok ? asObject(read.value) : null;
  if (!body) return json({ error: "bad_request" }, 400);
  const t = checkUrl(body.url, body.host);
  if ("error" in t) return refused(t.error);
  const signal = AbortSignal.timeout(15_000);
  let addresses: string[];
  try { addresses = await net.resolve(t.host); } catch { return refused("dns_failed"); }
  const address = pickAddress(addresses);
  if (!address) return refused(addresses.length ? "private_address" : "dns_failed");
  try {
    const { bytes, remote } = await net.exchange(address, t, request(t), signal);
    if (remote !== address) return refused("private_address");   // the address actually connected to is the one checked
    const answer = parseAnswer(bytes);
    if (!answer) return refused("bad_answer");
    return json({ statusCode: answer.statusCode, headers: answer.headers, body: answer.body });
  } catch (e) {
    console.error("website-fetch", e instanceof Error ? e.name : "unknown");
    return refused(signal.aborted ? "timeout" : "network");
  }
}

if (import.meta.main) Deno.serve((req) => handle(req));
