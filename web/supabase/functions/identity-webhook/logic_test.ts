// Signature checks with fake secrets only, and reading Persona shaped events. No provider is called.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { MAX_AGE_SECONDS, persona, sameText, statusFor, verifySignature } from "./logic.ts";
import { sign } from "./test_sign.ts";

const FAKE_SECRET = "fake_test_secret_not_real";
const enc = new TextEncoder();
const now = 1_800_000_000;
const raw = enc.encode('{"data":{"id":"evt_1"}}');

Deno.test("a correct signature over the exact bytes passes", async () => {
  assert(await verifySignature(raw, `t=${now},v1=${await sign(raw, FAKE_SECRET, now)}`, FAKE_SECRET, now));
  assert(await verifySignature(raw, `t=${now}, v1=${(await sign(raw, FAKE_SECRET, now)).toUpperCase()}`, FAKE_SECRET, now));
});

Deno.test("a rotated secret: any matching v1 passes", async () => {
  const header = `t=${now},v1=${await sign(raw, "fake_old_secret", now)} v1=${await sign(raw, FAKE_SECRET, now)}`;
  assert(await verifySignature(raw, header, FAKE_SECRET, now));
});

Deno.test("wrong secret, changed body, wrong time, replay and malformed headers fail", async () => {
  const good = await sign(raw, FAKE_SECRET, now);
  const changed = enc.encode('{"data":{"id":"evt_2"}}');
  const cases: [Uint8Array, string | null, number][] = [
    [raw, `t=${now},v1=${await sign(raw, "fake_other_secret", now)}`, now],
    [changed, `t=${now},v1=${good}`, now],
    [raw, `t=${now + 1},v1=${good}`, now],
    [raw, `t=${now},v1=${good}`, now + MAX_AGE_SECONDS + 1],
    [raw, `t=${now},v1=${good}`, now - MAX_AGE_SECONDS - 1],
    [raw, `v1=${good}`, now],
    [raw, `t=${now}`, now],
    [raw, `t=abc,v1=${good}`, now],
    [raw, `t=${now},v0=${good}`, now],
    [raw, "", now],
    [raw, null, now],
  ];
  for (const [body, header, at] of cases) assertEquals(await verifySignature(body, header, FAKE_SECRET, at), false, String(header));
  assertEquals(await verifySignature(raw, `t=${now},v1=${good}`, "", now), false);   // no secret, never a pass
});

Deno.test("sameText", () => {
  assert(sameText("abc", "abc"));
  assert(!sameText("abc", "abd"));
  assert(!sameText("abc", "abcd"));
});

Deno.test("Persona shaped events become a provider neutral event", () => {
  const ev = (status: string | undefined, name = "inquiry.completed") => ({ data: { type: "event", id: "evt_9", attributes: {
    name, "created-at": "2026-11-16T15:00:00.000Z", payload: { data: { type: "inquiry", id: "inq_1", attributes: { status, "reference-id": "a".repeat(32) } } } } } });
  assertEquals(persona.parseEvent(ev("approved")), { event: { eventId: "evt_9", reference: "a".repeat(32), outcome: "approved", occurredAt: "2026-11-16T15:00:00.000Z" } });
  for (const [s, o] of [["declined", "declined"], ["failed", "pending"], ["needs_review", "needs_review"], ["completed", "pending"], ["expired", "other"], ["weird", "other"]]) {
    assertEquals((persona.parseEvent(ev(s)) as { event: { outcome: string } }).event.outcome, o, s);
  }
  assertEquals((persona.parseEvent(ev(undefined, "inquiry.approved")) as { event: { outcome: string } }).event.outcome, "approved");
  assertEquals(persona.parseEvent({ data: { attributes: {} } }), { invalid: "missing event id" });
  assertEquals(persona.parseEvent(null), { invalid: "missing event id" });
  assertEquals((persona.parseEvent({ data: { id: "evt_x" } }) as { event: { reference: unknown } }).event.reference, null);
});

Deno.test("the database's answer decides what the provider sees", () => {
  assertEquals(statusFor("applied").status, 200);
  assertEquals(statusFor("unmapped").status, 200);   // kept and alerted; a retry would not help
  assertEquals(statusFor("duplicate"), { status: 200, text: "duplicate" });
  assertEquals(statusFor("off"), { status: 503, text: "not_enabled" });
  assertEquals(statusFor(undefined).status, 500);
});
