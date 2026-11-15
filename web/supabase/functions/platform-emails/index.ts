// Zella Voice: platform-emails edge function (logic.ts). Called every minute by the database when there is work
// (zella_dispatch_platform_emails), with the secret kept in Vault; the database checks it (zella_platform_emails_check),
// so no secret lives in this function. Deploy with --no-verify-jwt: the caller is the database, not a signed in user.
// Needs: ZELLA_SERVER_SECRET_KEY (server key, as voice-rules), RESEND_API_KEY to send (without it nothing is sent),
// ZELLA_APP_URL for the button in each email (optional).
import { createClient } from "@supabase/supabase-js";
import { runOnce } from "./logic.ts";

const json = (data: unknown, status = 200) => Response.json(data, { status });

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("ZELLA_SERVER_SECRET_KEY");
  if (!url || !key) return json({ error: "Not configured" }, 500);
  const db = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  const secret = req.headers.get("x-zella-secret") ?? "";
  const check = await db.rpc("zella_platform_emails_check", { p_secret: secret.slice(0, 200) });
  if (check.error) return json({ error: "Unavailable" }, 503);
  if (check.data !== true) return json({ error: "Unauthorized" }, 401);

  const setting = async (k: string) => {
    const { data } = await db.from("platform_settings").select("value").eq("key", k).maybeSingle();
    const v = data?.value;
    return typeof v === "string" && v.trim() ? v.trim() : null;
  };
  const resendKey = Deno.env.get("RESEND_API_KEY") ?? "";
  const stats = await runOnce({
    rpc: async (fn, args) => { const r = await db.rpc(fn, args); return { data: r.data, error: r.error }; },
    send: async (body, idempotencyKey) => {
      const res = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${resendKey}`, "Idempotency-Key": idempotencyKey.slice(0, 256) },
        body: JSON.stringify(body), signal: AbortSignal.timeout(10000),
      });
      const out = await res.json().catch(() => ({})) as { id?: string; message?: string; name?: string };
      return { ok: res.ok, status: res.status, id: out.id, error: res.ok ? undefined : `${res.status} ${(out.name ?? out.message ?? "").slice(0, 120)}` };
    },
    from: await setting("email_from_address"),
    canSend: resendKey.length > 0,
    appUrl: Deno.env.get("ZELLA_APP_URL") ?? null,
    supportEmail: await setting("support_email"),
  });
  console.log(JSON.stringify({ platform_emails: stats }));   // counts only, never addresses or content
  return json(stats);
});
