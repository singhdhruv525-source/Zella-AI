import { assert, assertEquals, assertMatch } from "jsr:@std/assert@1";
import { type Deps, type Json, notificationEmail, runOnce } from "./logic.ts";

const note = (over: Json = {}): Json => ({
  notification_id: "n1", business_id: "b1", business_name: "Test Clinic", user_id: "u1", role: "owner", to: "owner@example.com",
  kind: "on_call_gap", severity: "warning", page_key: "on_call", title: "Gaps in this weekend's on call cover",
  body: "Nobody is on call from Saturday 18:00.", ...over,
});

function world(opts: { claimed?: Json[]; due?: Json[]; queueFails?: boolean; sendResult?: { ok: boolean; status: number; id?: string }; canSend?: boolean; from?: string | null } = {}) {
  const calls: { fn: string; args: Json }[] = [];
  const sends: { body: Json; key: string }[] = [];
  const deps: Deps = {
    rpc: (fn, args) => {
      calls.push({ fn, args });
      if (fn === "zella_claim_notification_emails") return Promise.resolve({ data: opts.claimed ?? [], error: null });
      if (fn === "zella_queue_platform_email") return Promise.resolve(opts.queueFails ? { data: null, error: { message: "x" } } : { data: "e1", error: null });
      if (fn === "zella_claim_platform_emails") return Promise.resolve({ data: opts.due ?? [], error: null });
      return Promise.resolve({ data: "ok", error: null });
    },
    send: (body, key) => { sends.push({ body, key }); return Promise.resolve(opts.sendResult ?? { ok: true, status: 200, id: "re_1" }); },
    from: opts.from === undefined ? "Zella Voice <hello@example.com>" : opts.from,
    canSend: opts.canSend ?? true, appUrl: "https://app.example.com", supportEmail: null,
  };
  return { deps, calls, sends };
}

Deno.test("a notification is written from the catalogue and queued once per person, then marked handed over", async () => {
  const w = world({ claimed: [note(), note({ user_id: "u2", to: "admin@example.com", role: "admin" })] });
  const st = await runOnce(w.deps);
  assertEquals(st.queued, 2);
  const q = w.calls.filter((c) => c.fn === "zella_queue_platform_email");
  assertEquals(q.map((c) => c.args.p_dedupe_key), ["email:N1:n1:u1", "email:N1:n1:u2"]);
  assertEquals(q[0].args.p_subject, "Gaps in this weekend's on call cover");
  assertMatch(String(q[0].args.p_text), /Nobody is on call from Saturday 18:00\./);
  // links open the business app: on_call notifications open the Team page, where the rota lives
  assertMatch(String(q[0].args.p_html), /https:\/\/app\.example\.com\/app\/team/);
  assertEquals(w.calls.filter((c) => c.fn === "zella_finish_owner_email").map((c) => c.args.p_result), ["sent"]);
});

Deno.test("a queue failure leaves the notification claimed for a retry", async () => {
  const w = world({ claimed: [note()], queueFails: true });
  const st = await runOnce(w.deps);
  assertEquals(st.queueFailed, 1);
  assertEquals(w.calls.filter((c) => c.fn === "zella_finish_owner_email").length, 0);
});

Deno.test("due outbox emails are sent with the business in the idempotency key and finished with their claim token", async () => {
  const due = [{ id: "e1", business_id: "b1", dedupe_key: "email:N1:n1:u1", to_email: "owner@example.com", cc: [], subject: "S", html: "<p>h</p>", text_body: "t", claim_token: "tok1" }];
  const w = world({ due });
  const st = await runOnce(w.deps);
  assertEquals(st.sent, 1);
  assertEquals(w.sends[0].key, "b1:email:N1:n1:u1");
  assertEquals(w.sends[0].body.to, ["owner@example.com"]);
  const fin = w.calls.find((c) => c.fn === "zella_finish_platform_email")!;
  assertEquals([fin.args.p_claim_token, fin.args.p_ok, fin.args.p_provider_id], ["tok1", true, "re_1"]);
});

Deno.test("a provider failure is recorded, never claimed as sent", async () => {
  const due = [{ id: "e1", business_id: "b1", dedupe_key: "k", to_email: "o@example.com", subject: "S", html: "h", text_body: "t", claim_token: "tok1" }];
  const w = world({ due, sendResult: { ok: false, status: 422 } });
  const st = await runOnce(w.deps);
  assertEquals(st.sendFailed, 1);
  const fin = w.calls.find((c) => c.fn === "zella_finish_platform_email")!;
  assertEquals([fin.args.p_ok, fin.args.p_error], [false, "HTTP 422"]);
});

Deno.test("without the provider key or a sender address nothing is claimed for sending", async () => {
  for (const o of [{ canSend: false }, { from: null }]) {
    const w = world({ ...o, due: [{ id: "e1" }] });
    const st = await runOnce(w.deps);
    assert(st.skippedSend);
    assertEquals(w.calls.some((c) => c.fn === "zella_claim_platform_emails"), false);
    assertEquals(w.sends.length, 0);
  }
});

Deno.test("strict: a notification without a title is never sent with a made up one", () => {
  let threw = false;
  try { notificationEmail({ business_name: "B", role: "owner", severity: "info" }, null, null); } catch { threw = true; }
  // a missing title renders as empty; the subject must not be the sample text
  if (!threw) {
    const m = notificationEmail({ business_name: "B", role: "owner", severity: "info", title: "" }, null, null);
    assertEquals(m.subject, "");
  }
  const m = notificationEmail(note({ title: "<b>Hi</b>" }), null, null);
  assertMatch(m.html, /&lt;b&gt;Hi&lt;\/b&gt;/);
  assertEquals(/Maple Street Dental/.test(m.html + m.text), false);
});

Deno.test("links open the right page in the business app", async () => {
  const pages: Record<string, string> = { calls: "/app/calls", "": "/app", home: "/app", appointments: "/app/calendar", on_call: "/app/team", "settings/billing": "/app/settings/billing" };
  for (const [key, path] of Object.entries(pages)) {
    const m = notificationEmail(note({ page_key: key || null }), "https://app.example.com", null);
    assertMatch(m.html, new RegExp(`href="https://app\\.example\\.com${path.replace(/\//g, "\\/")}"`), key);
  }
});
