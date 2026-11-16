// Admin dashboard, lane D: operations. The server side of the go live checklist (UI-23) and the server configuration
// list Platform operations shows (SET-OAUTH-CHECKS).
//
// Every action runs after index.ts has checked the caller's sign in, two step sign in, platform role and the
// permission listed in OPS_PERMISSIONS. Secrets are reported as set or not set only: a value never leaves the server.
// Nothing here switches anything on; every live switch and job stays the owner's decision.

import type { SupabaseClient } from "@supabase/supabase-js";

type Json = Record<string, unknown>;

export const OPS_PERMISSIONS: Record<string, string> = {
  go_live_checklist: "businesses.view",
};

// Every server secret Zella Voice reads (Supabase secrets are project wide, so this function can see them all).
// `required`: the platform doesn't work without it. `group` places it on the go live checklist.
export type ServerSecret = { key: string; label: string; required: boolean; group: "core" | "providers" | "email" | "calendar" | "automations" };
export const SERVER_SECRETS: ServerSecret[] = [
  { key: "ZELLA_APP_URL", label: "App URL for invitation links", required: true, group: "core" },
  { key: "ZELLA_SERVER_SECRET_KEY", label: "Server key for public pages and webhooks", required: true, group: "core" },
  { key: "ZELLA_ALLOWED_ORIGINS", label: "Websites allowed to call Zella Voice (set at go live)", required: false, group: "core" },
  { key: "STRIPE_WEBHOOK_SECRET", label: "Payment provider webhook signature", required: false, group: "providers" },
  { key: "TELNYX_API_KEY", label: "Telnyx (phone numbers)", required: false, group: "providers" },
  { key: "VAPI_API_KEY", label: "Vapi (voice agents)", required: false, group: "providers" },
  { key: "N8N_WEBHOOK_URL", label: "n8n (automations and emails)", required: false, group: "automations" },
  { key: "ZELLA_LINK_SECRET", label: "Signing key for \"continue my plan\" links", required: false, group: "core" },
  { key: "RESEND_API_KEY", label: "Resend (sends every email)", required: false, group: "email" },
  // calendar-connect (web/supabase/functions/calendar-connect/index.ts) reads these five
  { key: "GOOGLE_CALENDAR_CLIENT_ID", label: "Google Calendar app: client ID", required: false, group: "calendar" },
  { key: "GOOGLE_CALENDAR_CLIENT_SECRET", label: "Google Calendar app: client secret", required: false, group: "calendar" },
  { key: "MICROSOFT_CALENDAR_CLIENT_ID", label: "Microsoft calendar app: client ID", required: false, group: "calendar" },
  { key: "MICROSOFT_CALENDAR_CLIENT_SECRET", label: "Microsoft calendar app: client secret", required: false, group: "calendar" },
  { key: "CALENDAR_REDIRECT_URL", label: "Calendar sign in return address (optional: the function's own address is used when unset)", required: false, group: "calendar" },
];

// The configuration list platform_status returns: whether each value is set, never the value.
export const serverConfiguration = (has: (name: string) => boolean) =>
  SERVER_SECRETS.map(({ key, label, required, group }) => ({ key, label, set: has(key), required, group }));

// Platform settings on the checklist. Addresses report only whether they are set; switches report true or false.
export const CHECKLIST_ADDRESSES = ["app_base_url", "n8n_base_url", "platform_emails_url", "email_from_address", "sms_from_number"] as const;
export const CHECKLIST_SWITCHES = ["n8n_dispatch_enabled", "email_live", "sms_live", "calls_live", "provider_checks_live", "calendar_sync_live", "spam_workflow_live"] as const;

const isSet = (v: unknown) => typeof v === "string" ? v.trim() !== "" : v !== null && v !== undefined && v !== false;

export function opsHandlers(admin: SupabaseClient, _fields: Json, env: (name: string) => string | undefined = (n) => Deno.env.get(n)) {
  const has = (name: string) => Boolean(env(name));

  // Secrets and platform settings for the go live checklist. The web app adds the scheduled jobs and the email
  // triggers from the database (zella_admin_scheduler_health, zella_admin_email_triggers) as the signed in admin.
  const goLiveChecklist = async () => {
    const keys = [...CHECKLIST_ADDRESSES, ...CHECKLIST_SWITCHES];
    const { data, error } = await admin.from("platform_settings").select("key, value").in("key", keys);
    if (error) throw error;
    const value = new Map((data ?? []).map((r: { key: string; value: unknown }) => [r.key, r.value]));
    return {
      secrets: serverConfiguration(has),
      addresses: CHECKLIST_ADDRESSES.map((key) => ({ key, set: isSet(value.get(key)) })),
      // a switch that was never saved is off (that is how the database reads it)
      switches: CHECKLIST_SWITCHES.map((key) => ({ key, on: value.get(key) === true, saved: value.has(key) })),
      checkedAt: new Date().toISOString(),
    };
  };

  const handlers: Record<string, () => Promise<unknown>> = {
    go_live_checklist: goLiveChecklist,
  };
  // reads only so far: nothing to audit
  const audited: Record<string, (result: Json) => unknown> = {};
  return { handlers, audited };
}
