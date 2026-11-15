// platform-emails: the one path for emails from Zella Voice to businesses. Pure logic (no network of its own), tested
// in logic_test.ts. One run:
//   1. notifications that go by email (zella_claim_notification_emails) are written from the shared catalogue
//      (email N1, strict: a missing fact stops that email) and queued in the outbox (zella_queue_platform_email),
//      keyed email:N1:<notification>:<person>, so a retry never queues twice
//   2. due outbox emails (zella_claim_platform_emails) are sent through Resend with Idempotency-Key
//      <business>:<key>, and finished with the claim token they came with (zella_finish_platform_email)
// While email_live is off the database hands out nothing to send (rows become test mode). Without a sender address or
// the provider key, step 2 is skipped and nothing is claimed.
// @ts-ignore: plain JavaScript module shared with the web app
import { renderEmail } from "../_shared/businessEmails.js";
// @ts-ignore: plain JavaScript module shared with the web app
import { appPath } from "../_shared/pageKeys.js";

export type Json = Record<string, unknown>;
export type Rpc = (fn: string, args: Json) => Promise<{ data: unknown; error: unknown }>;
export type Deps = {
  rpc: Rpc;
  send: (body: Json, idempotencyKey: string) => Promise<{ ok: boolean; status: number; id?: string; error?: string }>;
  from: string | null;          // platform_settings.email_from_address
  canSend: boolean;             // the provider key is set
  appUrl: string | null;        // ZELLA_APP_URL, for the button
  supportEmail: string | null;  // platform_settings.support_email
};
export type Stats = { notifications: number; queued: number; queueFailed: number; sent: number; sendFailed: number; skippedSend: string | null };

const arr = (v: unknown): Json[] => (Array.isArray(v) ? v.filter((x) => x && typeof x === "object") as Json[] : []);
const str = (v: unknown) => (typeof v === "string" ? v : "");

// the email for one notification and one person
export function notificationEmail(n: Json, appUrl: string | null, supportEmail: string | null) {
  // optional facts are left out when missing (the catalogue then leaves them out of the email)
  const data: Json = { business: str(n.business_name), role: str(n.role), title: str(n.title), severity: str(n.severity),
    pagePath: appPath(str(n.page_key)), mandatory: n.severity === "urgent" };
  if (str(n.body)) data.body = str(n.body);
  if (appUrl) data.appUrl = appUrl;
  if (supportEmail) data.supportEmail = supportEmail;
  return renderEmail("N1", data as never, { strict: true });
}

export async function runOnce(d: Deps): Promise<Stats> {
  const st: Stats = { notifications: 0, queued: 0, queueFailed: 0, sent: 0, sendFailed: 0, skippedSend: null };

  // 1. notifications -> outbox
  const claimed = await d.rpc("zella_claim_notification_emails", { p_limit: 20 });
  const items = claimed.error ? [] : arr(claimed.data);
  const byNote = new Map<string, Json[]>();
  for (const it of items) byNote.set(str(it.notification_id), [...(byNote.get(str(it.notification_id)) ?? []), it]);
  st.notifications = byNote.size;
  for (const [noteId, people] of byNote) {
    let allQueued = true;
    for (const it of people) {
      try {
        const m = notificationEmail(it, d.appUrl, d.supportEmail);
        const q = await d.rpc("zella_queue_platform_email", {
          p_business: it.business_id, p_code: "N1", p_dedupe_key: `email:N1:${noteId}:${str(it.user_id)}`, p_to: it.to,
          p_subject: m.subject, p_html: m.html, p_text: m.text, p_mandatory: m.mandatory, p_user: it.user_id, p_cc: [],
        });
        if (q.error) throw new Error("queue failed");
        st.queued++;
      } catch {
        st.queueFailed++;
        allQueued = false;
      }
    }
    // handed to the outbox: the outbox tracks the delivery from here. A failure leaves the notification claimed; it is
    // claimed again after 30 minutes, and the key stops a second copy for the people already queued.
    if (allQueued) await d.rpc("zella_finish_owner_email", { p_id: noteId, p_result: "sent", p_note: "queued in the platform outbox" });
  }

  // 2. outbox -> provider
  if (!d.canSend || !d.from) { st.skippedSend = !d.canSend ? "no_provider_key" : "no_sender_address"; return st; }
  const due = await d.rpc("zella_claim_platform_emails", { p_limit: 20 });
  for (const e of due.error ? [] : arr(due.data)) {
    const body: Json = { from: d.from, to: [str(e.to_email)], subject: str(e.subject), html: str(e.html), text: str(e.text_body) };
    if (Array.isArray(e.cc) && e.cc.length) body.cc = e.cc;
    let r: { ok: boolean; status: number; id?: string; error?: string };
    try { r = await d.send(body, `${str(e.business_id)}:${str(e.dedupe_key)}`); } catch { r = { ok: false, status: 0, error: "provider unreachable" }; }
    await d.rpc("zella_finish_platform_email", {
      p_id: e.id, p_claim_token: e.claim_token, p_ok: r.ok, p_provider_id: r.id ?? null, p_error: r.ok ? null : (r.error ?? `HTTP ${r.status}`),
    });
    if (r.ok) st.sent++; else st.sendFailed++;
  }
  return st;
}
