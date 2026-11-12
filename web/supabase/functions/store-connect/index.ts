// Zella Voice - connect a business's Shopify store for order status (sql/zella_store_orders.sql).
//   POST { action: "connect", business_id, shop_domain, access_token }   signed-in owner or admin
// The token is the Admin API access token of a custom app the owner creates in their Shopify admin with read-only
// scopes. It is checked with Shopify (the store answers, and the scopes order lookup needs are granted) before it is
// stored by the database with the server key. It is never logged or sent back.
// verify_jwt is off (config.toml), like the other functions that check the caller through the database.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { withCors } from "../_shared/cors.ts";

export const SHOPIFY_API_VERSION = "2026-07";
export const NEEDED_SCOPES = ["read_orders", "read_customers"];
// Which websites may read the answer comes from the shared origin policy (withCors, below), like the other
// browser-facing functions; this function still checks the sign-in token and zella_store_can_manage itself.
const json = (body: unknown, status: number) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

export async function handle(req: Request): Promise<Response> {
  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);
  const base = Deno.env.get("SUPABASE_URL"), server = Deno.env.get("ZELLA_SERVER_SECRET_KEY"), anon = Deno.env.get("SUPABASE_ANON_KEY");
  if (!base || !server || !anon) return json({ ok: false, error: "not_configured" }, 503);
  let b: Record<string, unknown>;
  try { b = await req.json(); } catch { return json({ ok: false, error: "bad_json" }, 400); }
  const biz = String(b.business_id ?? ""), shop = String(b.shop_domain ?? "").trim().toLowerCase().replace(/^https?:\/\//, "").replace(/\/.*$/, ""), token = String(b.access_token ?? "").trim();
  if (b.action !== "connect" || !/^[0-9a-f-]{36}$/i.test(biz)) return json({ ok: false, error: "bad_request" }, 400);
  if (!/^[a-z0-9][a-z0-9-]{0,60}\.myshopify\.com$/.test(shop)) return json({ ok: false, error: "bad_shop_domain" }, 400);
  if (!/^[A-Za-z0-9_-]{20,200}$/.test(token)) return json({ ok: false, error: "bad_token" }, 400);
  const auth = req.headers.get("authorization") ?? "";
  if (!/^Bearer\s+\S+/i.test(auth) || auth.includes(server)) return json({ ok: false, error: "sign_in_required" }, 401);
  const who = await fetch(`${base}/auth/v1/user`, { headers: { apikey: anon, Authorization: auth } });
  if (!who.ok) return json({ ok: false, error: "sign_in_required" }, 401);
  const user = await who.json();
  const can = await fetch(`${base}/rest/v1/rpc/zella_store_can_manage`, { method: "POST", headers: { "Content-Type": "application/json", apikey: anon, Authorization: auth }, body: JSON.stringify({ p_business_id: biz }) });
  if (!can.ok || (await can.json()) !== true) return json({ ok: false, error: "not_allowed" }, 403);

  // the store answers with this token, and has granted what order lookup needs
  const ask = (path: string) => fetch(`https://${shop}${path}`, { headers: { "X-Shopify-Access-Token": token, Accept: "application/json" }, signal: AbortSignal.timeout(8000) }).catch(() => null);
  const shopRes = await ask(`/admin/api/${SHOPIFY_API_VERSION}/shop.json`);
  if (!shopRes) return json({ ok: false, error: "store_unreachable" }, 502);
  if (shopRes.status === 401 || shopRes.status === 403) return json({ ok: false, error: "token_refused" }, 400);
  if (shopRes.status === 404) return json({ ok: false, error: "store_not_found" }, 400);
  if (!shopRes.ok) return json({ ok: false, error: "store_unreachable" }, 502);
  const shopName = String((await shopRes.json().catch(() => ({})))?.shop?.name ?? "").slice(0, 120) || null;
  const scopeRes = await ask("/admin/oauth/access_scopes.json");
  const granted: string[] = scopeRes?.ok ? ((await scopeRes.json().catch(() => ({})))?.access_scopes ?? []).map((s: { handle?: string }) => String(s?.handle ?? "")) : [];
  // write scopes imply read; anything beyond reading orders and customers isn't needed, so it's reported to the owner
  const has = (s: string) => granted.includes(s) || granted.includes(s.replace("read_", "write_"));
  const missing = NEEDED_SCOPES.filter((s) => !has(s));
  if (missing.length) return json({ ok: false, error: "missing_scopes", missing }, 400);
  const extra = granted.filter((s) => s.startsWith("write_"));

  const saved = await fetch(`${base}/rest/v1/rpc/zella_store_connect`, {
    method: "POST", headers: { "Content-Type": "application/json", apikey: server, Authorization: `Bearer ${server}` },
    body: JSON.stringify({ p_business_id: biz, p_actor: String(user.id), p_shop_domain: shop, p_access_token: token, p_shop_name: shopName }),
  }).catch(() => null);
  if (!saved?.ok) return json({ ok: false, error: saved && /NOT_ALLOWED/.test(await saved.text()) ? "not_allowed" : "try_again" }, saved ? 400 : 503);
  return json({ ok: true, shop: shop, shop_name: shopName, more_access_than_needed: extra }, 200);
}

if (import.meta.main) Deno.serve(withCors(handle));
