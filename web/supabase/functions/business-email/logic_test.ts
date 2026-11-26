// business-email's pure pieces: Resend's answers read safely, its states in three words, refusals in short names.
import { assertEquals } from "jsr:@std/assert@1";
import { alreadyAdded, domainStatus, findDomain, readDomain, reason } from "./logic.ts";

Deno.test("a Resend domain is kept to the fields the page and the database use", () => {
  const d = readDomain({ id: "d_1", name: "Salon.example.test", status: "not_started", region: "us-east-1", records: [
    { record: "SPF", name: "send", type: "MX", ttl: "Auto", status: "not_started", value: "feedback-smtp.us-east-1.amazonses.com", priority: 10, extra: "x" },
    { record: "DKIM", name: "resend._domainkey", type: "txt", ttl: "Auto", status: "not_started", value: "p=MIGf" },
    { type: "A", name: "x", value: "1.2.3.4" }, { type: "TXT", name: "", value: "v" }, "junk", null] });
  assertEquals(d, { id: "d_1", name: "salon.example.test", status: "not_started", records: [
    { record: "SPF", type: "MX", name: "send", value: "feedback-smtp.us-east-1.amazonses.com", ttl: "Auto", priority: 10, status: "not_started" },
    { record: "DKIM", type: "TXT", name: "resend._domainkey", value: "p=MIGf", ttl: "Auto", priority: undefined, status: "not_started" }] });
});
Deno.test("anything that isn't a domain object is refused", () => {
  for (const b of [null, "x", {}, { id: "bad id!", name: "a.b" }, { id: "d1" }, { id: 5, name: "a.b" }]) assertEquals(readDomain(b), null);
});
Deno.test("Resend's states, in the page's three", () => {
  assertEquals(["verified", "failed", "pending", "not_started", "temporary_failure", undefined].map(domainStatus), ["verified", "failed", "pending", "pending", "pending", "pending"]);
});
Deno.test("a domain Resend already has is recognised; other refusals aren't", () => {
  assertEquals(alreadyAdded(403, { message: "The domain salon.example.test has been registered already." }), true);
  assertEquals(alreadyAdded(409, { message: "Domain already exists" }), true);
  assertEquals(alreadyAdded(422, { message: "Invalid domain" }), false);
  assertEquals(alreadyAdded(500, { message: "already exists" }), false);
  assertEquals(alreadyAdded(409, null), false);
});
Deno.test("a listing gives the exact domain only", () => {
  const list = { data: [{ id: "d_2", name: "other.example.test" }, { id: "d_3", name: "salon.example.test" }, { id: "x y", name: "bad.example.test" }] };
  assertEquals([findDomain(list, "salon.example.test"), findDomain(list, "example.test"), findDomain(list, "bad.example.test"), findDomain(null, "a")], ["d_3", null, null, null]);
});
Deno.test("database refusals become short names; anything else is try again", () => {
  assertEquals([reason("DOMAIN_TAKEN"), reason("FREE_MAILBOX_DOMAIN"), reason("relation x does not exist"), reason(undefined)], ["domain_taken", "free_mailbox_domain", "try_again", "try_again"]);
});
