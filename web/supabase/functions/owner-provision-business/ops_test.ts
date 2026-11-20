import { assertEquals, assert } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import { CHECKLIST_SWITCHES, OPS_PERMISSIONS, SERVER_SECRETS, opsHandlers, serverConfiguration } from "./ops.ts";
import { PERMISSIONS } from "./settings.ts";

const SECRET_VALUE = "sk_live_must_never_leave_the_server_123";
const env = (set: string[]) => (name: string) => (set.includes(name) ? SECRET_VALUE : undefined);
const settings = (rows: { key: string; value: unknown }[]) => {
  const asked: string[][] = [];
  const admin = { from: (table: string) => ({ select: () => ({ in: async (_c: string, keys: string[]) => {
    assertEquals(table, "platform_settings"); asked.push(keys);
    return { data: rows.filter((r) => keys.includes(r.key)), error: null };
  } }) }) } as unknown as SupabaseClient;
  return { admin, asked };
};

Deno.test("every secret the platform reads is listed, including the email key and the five calendar app names", () => {
  const keys = SERVER_SECRETS.map((s) => s.key);
  for (const k of ["ZELLA_APP_URL", "ZELLA_SERVER_SECRET_KEY", "RESEND_API_KEY", "N8N_WEBHOOK_URL", "VAPI_API_KEY", "TELNYX_API_KEY", "STRIPE_WEBHOOK_SECRET",
    "GOOGLE_CALENDAR_CLIENT_ID", "GOOGLE_CALENDAR_CLIENT_SECRET", "MICROSOFT_CALENDAR_CLIENT_ID", "MICROSOFT_CALENDAR_CLIENT_SECRET", "CALENDAR_REDIRECT_URL"]) {
    assert(keys.includes(k), `${k} missing`);
  }
  assertEquals(new Set(keys).size, keys.length, "no name twice");
  for (const s of SERVER_SECRETS) assert(!/[‐-—]|\s-\s/.test(s.label), `dash in ${s.label}`);
});

Deno.test("the configuration list says set or not set only, never a value", () => {
  const rows = serverConfiguration((n) => n === "RESEND_API_KEY");
  assertEquals(rows.find((r) => r.key === "RESEND_API_KEY")?.set, true);
  assertEquals(rows.find((r) => r.key === "GOOGLE_CALENDAR_CLIENT_ID")?.set, false);
  for (const r of rows) assertEquals(Object.keys(r).sort(), ["group", "key", "label", "required", "set"]);
});

Deno.test("go_live_checklist returns presence and switch states, never a secret or setting value", async () => {
  const { admin, asked } = settings([
    { key: "platform_emails_url", value: "https://example.test/functions/v1/platform-emails" },
    { key: "email_from_address", value: "" },
    { key: "email_live", value: true },
    { key: "sms_live", value: false },
    { key: "n8n_dispatch_enabled", value: "true" },
  ]);
  const out = await opsHandlers(admin, {}, env(["RESEND_API_KEY", "ZELLA_APP_URL", "GOOGLE_CALENDAR_CLIENT_SECRET"])).handlers.go_live_checklist() as Record<string, any>;
  const text = JSON.stringify(out);
  assert(!text.includes(SECRET_VALUE), "a secret value leaked");
  assert(!text.includes("example.test"), "a setting value leaked");
  assertEquals(out.secrets.find((s: any) => s.key === "RESEND_API_KEY").set, true);
  assertEquals(out.secrets.find((s: any) => s.key === "GOOGLE_CALENDAR_CLIENT_SECRET").set, true);
  assertEquals(out.secrets.find((s: any) => s.key === "TELNYX_API_KEY").set, false);
  const addr = Object.fromEntries(out.addresses.map((a: any) => [a.key, a.set]));
  assertEquals(addr, { app_base_url: false, n8n_base_url: false, platform_emails_url: true, email_from_address: false, sms_from_number: false });
  const sw = Object.fromEntries(out.switches.map((s: any) => [s.key, s.on]));
  assertEquals(sw.email_live, true);
  assertEquals(sw.sms_live, false);
  assertEquals(sw.n8n_dispatch_enabled, false, "only a true boolean counts as on");
  assertEquals(sw.calls_live, false, "never saved reads off");
  assertEquals(out.switches.length, CHECKLIST_SWITCHES.length);
  assertEquals(asked.length, 1);
});

Deno.test("a settings read error is passed on, not turned into an all clear", async () => {
  const admin = { from: () => ({ select: () => ({ in: async () => ({ data: null, error: new Error("db down") }) }) }) } as unknown as SupabaseClient;
  let failed = false;
  try { await opsHandlers(admin, {}, env([])).handlers.go_live_checklist(); } catch { failed = true; }
  assert(failed);
});

Deno.test("every ops action needs a named permission, and none clashes with another module's action", () => {
  const known = new Set(Object.values(PERMISSIONS));
  for (const [action, permission] of Object.entries(OPS_PERMISSIONS)) {
    assert(known.has(permission), `${action}: ${permission} is not a known permission`);
    assertEquals(PERMISSIONS[action], undefined, `${action} is also in settings.ts`);
  }
  const { handlers } = opsHandlers({} as SupabaseClient, {}, env([]));
  assertEquals(Object.keys(handlers).sort(), Object.keys(OPS_PERMISSIONS).sort());
});
