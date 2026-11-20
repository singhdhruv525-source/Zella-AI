import { assertEquals } from "jsr:@std/assert@1";
import { clientIp } from "./client_ip.ts";
const h = (o: Record<string, string>) => new Headers(o);
Deno.test("the caller's own first X-Forwarded-For value is never used", () => {
  assertEquals(clientIp(h({ "x-forwarded-for": "1.2.3.4, 203.0.113.50" })), "203.0.113.50");
  assertEquals(clientIp(h({ "x-forwarded-for": "6.6.6.6, 7.7.7.7", "cf-connecting-ip": "198.51.100.9" })), "198.51.100.9");
});
Deno.test("rotating fake values doesn't change the address", () => {
  const ips = new Set([1, 2, 3].map((n) => clientIp(h({ "x-forwarded-for": `10.0.0.${n}, 203.0.113.50` }))));
  assertEquals([...ips], ["203.0.113.50"]);
});
Deno.test("junk is ignored", () => {
  assertEquals(clientIp(h({ "cf-connecting-ip": "not an ip", "x-forwarded-for": "x, <script>" })), null);
  assertEquals(clientIp(h({})), null);
  assertEquals(clientIp(h({ "cf-connecting-ip": "2606:4700::1" })), "2606:4700::1");
});
Deno.test("only complete addresses count; a bad Cloudflare value falls back to the platform hop", () => {
  for (const bad of ["dead", ":::", "999.999.999.999", "1.2.3", "1.2.3.4.5"]) assertEquals(clientIp(h({ "cf-connecting-ip": bad, "x-forwarded-for": "203.0.113.9" })), "203.0.113.9", bad);
  assertEquals(clientIp(h({ "x-forwarded-for": "1.1.1.1, 300.1.1.1" })), null);
  assertEquals(clientIp(h({ "cf-connecting-ip": "::1" })), "::1");
});
