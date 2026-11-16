// Admin dashboard: buying and releasing phone numbers through Telnyx and Vapi, and the providers' own error logs
// (docs/ADMIN_AUDIT_2026-11-16.md VOICE-PROVIDERS).
//
// Every action runs after index.ts has checked the caller's sign in, two step sign in, platform role and the
// permission listed in PROVIDER_PERMISSIONS. The order itself lives in the database (sql/zella_number_orders.sql),
// whose functions check the admin again: an admin with telephony.manage asks, a Zella Voice owner who did not ask
// approves, and only then is the provider called, once (claim), with the answer recorded (finish). Every step is
// audited by those functions in the same transaction.
//
// Switched off until the owner adds both keys and turns on number_orders_enabled: until then every order and search
// is refused with "Not connected yet", and nothing is sent anywhere. The provider addresses can be changed with
// TELNYX_API_BASE and VAPI_API_BASE (tests point them at local fakes); only https is accepted, except for a local
// address. Keys never leave the server.

import type { SupabaseClient } from "@supabase/supabase-js";
import type { PlatformKit } from "./platform.ts";

type Json = Record<string, unknown>;

export const PROVIDER_PERMISSIONS: Record<string, string> = {
  provider_overview: "businesses.view",
  number_search: "telephony.manage",
  number_order_request: "telephony.manage",
  number_order_decide: "telephony.manage",
  number_order_cancel: "telephony.manage",
  provider_errors: "telephony.manage",
};

export const NOT_CONNECTED = "Not connected yet. Buying and releasing numbers starts once the Telnyx and Vapi keys are added and a Zella Voice owner switches number orders on.";
export const ORDERS_OFF = "Number orders are switched off. A Zella Voice owner switches them on in Platform settings (number_orders_enabled).";
// What the admin types to confirm. The server checks it too, so a script can't skip it.
export const CONFIRM_WORD: Record<string, string> = { purchase: "BUY", release: "RELEASE" };
export const PROVIDER_TIMEOUT_MS = 10_000;

const DEFAULT_TELNYX = "https://api.telnyx.com/v2";
const DEFAULT_VAPI = "https://api.vapi.ai";

export type ProviderDeps = {
  env: { get(key: string): string | undefined };
  fetch: typeof fetch;
  timeoutMs?: number;
};

// A provider address: https only, or http on this machine (local fakes in tests). Anything else falls back to the
// provider's real address, so a typo never sends a key somewhere unexpected.
export function providerBase(value: string | undefined, fallback: string): string {
  const v = (value ?? "").trim().replace(/\/+$/, "");
  if (!v) return fallback;
  try {
    const u = new URL(v);
    if (u.protocol === "https:" || (u.protocol === "http:" && ["127.0.0.1", "localhost"].includes(u.hostname))) return v;
  } catch { /* fall through */ }
  return fallback;
}

export function providerConfig(env: ProviderDeps["env"]) {
  const val = (k: string) => (env.get(k) ?? "").trim();
  return {
    telnyxKey: val("TELNYX_API_KEY"), vapiKey: val("VAPI_API_KEY"),
    telnyxBase: providerBase(env.get("TELNYX_API_BASE"), DEFAULT_TELNYX), vapiBase: providerBase(env.get("VAPI_API_BASE"), DEFAULT_VAPI),
    connectionId: val("TELNYX_CONNECTION_ID"), messagingProfileId: val("TELNYX_MESSAGING_PROFILE_ID"), vapiCredentialId: val("VAPI_TELNYX_CREDENTIAL_ID"),
  };
}

// Database refusals in words, with the status the admin gets.
const REFUSALS: Record<string, [string, number]> = {
  NOT_ALLOWED: ["Your admin role doesn't allow this.", 403],
  OWNER_REQUIRED: ["Only a Zella Voice owner can approve a number order.", 403],
  SECOND_PERSON_REQUIRED: ["Someone else has to approve this: the person who asked can't approve their own order.", 403],
  REASON_REQUIRED: ["Give a short reason (it goes in the audit log).", 400],
  KEY_REQUIRED: ["Something went wrong preparing the order. Close the dialog and try again.", 400],
  KEY_REUSED: ["Something went wrong preparing the order. Close the dialog and try again.", 409],
  INVALID_NUMBER: ["Enter the number with its country code, like +15551234567.", 400],
  INVALID_KIND: ["Choose buy or release.", 400],
  BUSINESS_NOT_FOUND: ["That business wasn't found.", 404],
  ALREADY_OURS: ["Zella Voice already has this number.", 409],
  RELEASE_IN_USE: ["This number is still assigned in Zella Voice. Pause and release it on Numbers first.", 409],
  ORDER_OPEN: ["There is already an open order for this number.", 409],
  NOT_FOUND: ["Order not found.", 404],
  NOT_PENDING: ["This order has already been decided.", 409],
  NOT_APPROVED: ["This order isn't approved, or is already being placed.", 409],
  NOT_PLACING: ["This order isn't being placed.", 409],
};

const mask = (n: unknown) => (typeof n === "string" && n.length > 4 ? `…${n.replace(/\D/g, "").slice(-4)}` : null);
const clip = (v: unknown, max = 300) => (typeof v === "string" ? v.slice(0, max) : v == null ? null : String(v).slice(0, max));

// What a provider said went wrong, in at most 300 characters, without echoing anything we sent.
function providerMessage(body: unknown, status: number): string {
  const b = (body && typeof body === "object" ? body : {}) as Json;
  const errs = Array.isArray(b.errors) ? b.errors as Json[] : [];
  const m = errs[0]?.detail ?? errs[0]?.title ?? b.message ?? b.error;
  return `${status}: ${clip(Array.isArray(m) ? m.join("; ") : m ?? "no details")}`;
}

class ProviderLost extends Error {}   // the request may have reached the provider, but no answer came back

export function providerHandlers(admin: SupabaseClient, fields: Json, kit: PlatformKit, userId: string, role: string | null,
  deps: ProviderDeps = { env: Deno.env, fetch: (...a) => fetch(...a) }) {
  const { text, InputError } = kit;
  const cfg = providerConfig(deps.env);
  const connected = Boolean(cfg.telnyxKey && cfg.vapiKey);

  const rpc = async (fn: string, args: Json) => {
    const { data, error } = await admin.rpc(fn, args);
    if (error) {
      const code = Object.keys(REFUSALS).find((c) => String(error.message ?? "").includes(c));
      if (code) throw new InputError(REFUSALS[code][0], REFUSALS[code][1]);
      throw error;
    }
    return data as Json;
  };

  const enabled = async () => {
    const { data, error } = await admin.from("platform_settings").select("value").eq("key", "number_orders_enabled").maybeSingle();
    if (error) throw error;
    return data?.value === true;
  };

  // Refused, and nothing sent, unless both keys are set and the owner switched orders on.
  const requireLive = async () => {
    if (!connected) throw new InputError(NOT_CONNECTED, 409);
    if (!(await enabled())) throw new InputError(ORDERS_OFF, 409);
  };

  const send = async (which: "telnyx" | "vapi", path: string, init: RequestInit = {}) => {
    const base = which === "telnyx" ? cfg.telnyxBase : cfg.vapiBase;
    const key = which === "telnyx" ? cfg.telnyxKey : cfg.vapiKey;
    let res: Response;
    try {
      res = await deps.fetch(`${base}${path}`, {
        ...init,
        headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json", Accept: "application/json" },
        signal: AbortSignal.timeout(deps.timeoutMs ?? PROVIDER_TIMEOUT_MS),
      });
    } catch (e) {
      throw new ProviderLost(`${which === "telnyx" ? "Telnyx" : "Vapi"} didn't answer (${(e as Error).name})`);
    }
    const body = res.status === 204 ? {} : await res.json().catch(() => ({}));
    return { ok: res.ok, status: res.status, body: body as Json };
  };

  const provider_overview = async () => {
    const orders = await rpc("zella_number_orders_list", { p_actor: userId, p_limit: 50 });
    return {
      telnyx: Boolean(cfg.telnyxKey), vapi: Boolean(cfg.vapiKey), connected, enabled: await enabled(),
      vapiImport: Boolean(cfg.vapiCredentialId), orders, you: userId, confirmWords: CONFIRM_WORD,
    };
  };

  const number_search = async () => {
    await requireLive();
    const area = text(fields.areaCode, 3);
    if (!/^[2-9]\d{2}$/.test(area)) throw new InputError("Enter a three digit US area code, like 415.");
    const q = new URLSearchParams({ "filter[country_code]": "US", "filter[national_destination_code]": area, "filter[limit]": "10" });
    q.append("filter[features][]", "voice"); q.append("filter[features][]", "sms");
    let r;
    try { r = await send("telnyx", `/available_phone_numbers?${q}`); }
    catch (e) { if (e instanceof ProviderLost) throw new InputError(e.message, 502); throw e; }
    if (!r.ok) throw new InputError(`Telnyx refused the search (${providerMessage(r.body, r.status)})`, 502);
    const rows = (Array.isArray(r.body.data) ? r.body.data as Json[] : []).map((n) => {
      const region = (Array.isArray(n.region_information) ? n.region_information as Json[] : []).map((x) => x.region_name).filter(Boolean).join(", ");
      const cost = (n.cost_information ?? {}) as Json;
      return { e164: clip(n.phone_number, 20), region: clip(region, 100), monthly: cost.monthly_cost ?? null, upfront: cost.upfront_cost ?? null, currency: cost.currency ?? null };
    }).filter((n) => typeof n.e164 === "string" && /^\+[1-9]\d{7,14}$/.test(n.e164));
    return { rows };
  };

  const number_order_request = async () => {
    const kind = text(fields.kind, 10);
    if (!CONFIRM_WORD[kind]) throw new InputError("Choose buy or release.");
    if (text(fields.confirm, 20) !== CONFIRM_WORD[kind]) throw new InputError(`Type ${CONFIRM_WORD[kind]} to confirm.`);
    const key = text(fields.key, 40);
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(key)) throw new InputError(REFUSALS.KEY_REQUIRED[0]);
    await requireLive();
    const order = await rpc("zella_number_order_request", {
      p_actor: userId, p_kind: kind, p_e164: text(fields.e164, 30), p_business: text(fields.businessId, 40) || null,
      p_vapi_id: kind === "release" ? text(fields.vapiPhoneNumberId, 100) || null : null, p_reason: text(fields.reason, 300), p_key: key,
    });
    return { order };
  };

  const placePurchase = async (o: Json): Promise<[string, Json]> => {
    const body: Json = { phone_numbers: [{ phone_number: o.e164 }], customer_reference: `zella-voice-${o.id}` };
    if (cfg.connectionId) body.connection_id = cfg.connectionId;
    if (cfg.messagingProfileId) body.messaging_profile_id = cfg.messagingProfileId;
    const t = await send("telnyx", "/number_orders", { method: "POST", body: JSON.stringify(body) });
    if (!t.ok) return ["failed", { error: `Telnyx refused the order (${providerMessage(t.body, t.status)})` }];
    const d = (t.body.data ?? {}) as Json;
    const numberId = clip(((Array.isArray(d.phone_numbers) ? d.phone_numbers[0] : null) as Json | null)?.id, 100);
    const out: Json = { orderId: clip(d.id, 100), numberId };
    if (d.status === "failure") return ["failed", { ...out, error: "Telnyx couldn't complete the order" }];
    if (!cfg.vapiCredentialId) return ["completed", { ...out, error: "Bought at Telnyx. Not added to Vapi: VAPI_TELNYX_CREDENTIAL_ID isn't set." }];
    try {
      const v = await send("vapi", "/phone-number", { method: "POST", body: JSON.stringify({ provider: "telnyx", number: o.e164, credentialId: cfg.vapiCredentialId, name: `Zella Voice ${o.e164}` }) });
      if (!v.ok) return ["completed", { ...out, error: `Bought at Telnyx, but adding it to Vapi failed (${providerMessage(v.body, v.status)})` }];
      return ["completed", { ...out, vapiId: clip(v.body.id, 100) }];
    } catch (e) {
      if (e instanceof ProviderLost) return ["needs_check", { ...out, error: `Bought at Telnyx; ${e.message} when adding it. Check the Vapi dashboard.` }];
      throw e;
    }
  };

  const placeRelease = async (o: Json): Promise<[string, Json]> => {
    if (o.vapi_phone_number_id) {
      const v = await send("vapi", `/phone-number/${encodeURIComponent(String(o.vapi_phone_number_id))}`, { method: "DELETE" });
      if (!v.ok && v.status !== 404) return ["failed", { error: `Vapi refused to remove it (${providerMessage(v.body, v.status)}). Nothing changed at Telnyx.` }];
    }
    const found = await send("telnyx", `/phone_numbers?${new URLSearchParams({ "filter[phone_number]": String(o.e164) })}`);
    if (!found.ok) return ["failed", { error: `Telnyx refused the lookup (${providerMessage(found.body, found.status)})` }];
    const id = clip(((Array.isArray(found.body.data) ? found.body.data[0] : null) as Json | null)?.id, 100);
    if (!id) return ["failed", { error: "Telnyx has no such number on this account" }];
    const t = await send("telnyx", `/phone_numbers/${encodeURIComponent(id)}`, { method: "DELETE" });
    if (!t.ok) return ["failed", { numberId: id, error: `Telnyx refused the release (${providerMessage(t.body, t.status)})` }];
    return ["completed", { numberId: id }];
  };

  const number_order_decide = async () => {
    // index.ts checked telephony.manage; the database checks again that this is an owner who didn't ask.
    if (role !== "zella_owner") throw new InputError(REFUSALS.OWNER_REQUIRED[0], 403);
    const id = kit.requireId(fields.id, "order");
    const approve = fields.approve === true;
    if (fields.approve !== true && fields.approve !== false) throw new InputError("Choose approve or reject.");
    const reason = text(fields.reason, 300);
    if (!approve) return { order: await rpc("zella_number_order_decide", { p_actor: userId, p_id: id, p_approve: false, p_reason: reason }) };
    await requireLive();
    const { data: row, error } = await admin.from("number_orders").select("e164").eq("id", id).maybeSingle();
    if (error) throw error;
    if (!row) throw new InputError(REFUSALS.NOT_FOUND[0], 404);
    if (text(fields.confirm, 20) !== row.e164) throw new InputError(`Type ${row.e164} to confirm.`);
    await rpc("zella_number_order_decide", { p_actor: userId, p_id: id, p_approve: true, p_reason: reason });
    const o = await rpc("zella_number_order_claim", { p_actor: userId, p_id: id });
    let outcome: string, r: Json;
    try {
      [outcome, r] = o.kind === "purchase" ? await placePurchase(o) : await placeRelease(o);
    } catch (e) {
      if (!(e instanceof ProviderLost)) {
        await rpc("zella_number_order_finish", { p_actor: userId, p_id: id, p_outcome: "needs_check", p_order_id: null, p_number_id: null, p_vapi_id: null, p_error: "Stopped by an unexpected error. Check the provider dashboards." });
        throw e;
      }
      [outcome, r] = ["needs_check", { error: `${e.message}. It may have gone through: check the Telnyx and Vapi dashboards, then record the outcome.` }];
    }
    const order = await rpc("zella_number_order_finish", {
      p_actor: userId, p_id: id, p_outcome: outcome, p_order_id: r.orderId ?? null, p_number_id: r.numberId ?? null, p_vapi_id: r.vapiId ?? null, p_error: r.error ?? null,
    });
    return { order };
  };

  const number_order_cancel = async () => ({
    order: await rpc("zella_number_order_cancel", { p_actor: userId, p_id: kit.requireId(fields.id, "order"), p_reason: text(fields.reason, 300) }),
  });

  // Read only. Calls that ended with an error at Vapi, and webhook deliveries Telnyx couldn't make. Caller numbers are
  // masked; nothing is stored.
  const provider_errors = async () => {
    const out: Json = { telnyx: { connected: Boolean(cfg.telnyxKey), rows: [] as Json[] }, vapi: { connected: Boolean(cfg.vapiKey), rows: [] as Json[] } };
    const read = async (which: "telnyx" | "vapi", path: string, pick: (body: Json) => Json[]) => {
      try {
        const r = await send(which, path);
        (out[which] as Json).rows = r.ok ? pick(r.body).slice(0, 50) : [];
        if (!r.ok) (out[which] as Json).error = providerMessage(r.body, r.status);
      } catch (e) {
        if (!(e instanceof ProviderLost)) throw e;
        (out[which] as Json).error = e.message;
      }
    };
    await Promise.all([
      cfg.vapiKey ? read("vapi", "/call?limit=100", (b) => (Array.isArray(b) ? b as Json[] : [])
        .filter((c) => /error|fail|pipeline/i.test(String(c.endedReason ?? "")))
        .map((c) => ({ at: c.endedAt ?? c.createdAt ?? null, code: clip(c.endedReason, 120), ref: clip(c.id, 100), number: mask((c.customer as Json | undefined)?.number) }))) : null,
      cfg.telnyxKey ? read("telnyx", `/webhook_deliveries?${new URLSearchParams({ "filter[status][eq]": "failed", "page[size]": "25" })}`, (b) => (Array.isArray(b.data) ? b.data as Json[] : [])
        .map((d) => ({ at: d.finished_at ?? d.started_at ?? null, code: clip(((d.webhook ?? {}) as Json).event_type, 120),
          detail: clip(((Array.isArray(d.errors) ? d.errors[0] : null) as Json | null)?.title, 200), ref: clip(d.id, 100) }))) : null,
    ]);
    return out;
  };

  const handlers: Record<string, () => Promise<unknown>> = {
    provider_overview, number_search, number_order_request, number_order_decide, number_order_cancel, provider_errors,
  };
  // Every order step is audited by its database function, in the same transaction, so nothing is added here.
  const audited: Record<string, (r: Json) => Json> = {};
  return { handlers, audited };
}
