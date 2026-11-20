import { assert, assertEquals } from "jsr:@std/assert@1";
import { checkUrl, isPublicAddress, parseAnswer, pickAddress, request } from "./logic.ts";

Deno.test("private, loopback, link local, metadata, CGNAT and other special addresses are refused", () => {
  for (const ip of ["127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.169.254", "100.64.0.1", "100.100.100.200",
    "0.0.0.0", "224.0.0.1", "255.255.255.255", "192.0.2.1", "198.18.0.1", "198.51.100.7", "203.0.113.9", "192.0.0.8",
    "::1", "::", "::ffff:127.0.0.1", "::ffff:10.0.0.1", "::ffff:8.8.8.8", "fd00:ec2::254", "fc00::1", "fe80::1", "fec0::1", "ff02::1",
    "64:ff9b::a00:1", "2001:db8::1", "2002:7f00:1::1", "2001::1", "not-an-ip", "1.2.3", "300.1.1.1"]) assert(!isPublicAddress(ip), ip);
  for (const ip of ["8.8.8.8", "1.1.1.1", "172.15.0.1", "172.32.0.1", "100.63.255.255", "100.128.0.1", "2606:4700:4700::1111", "2a00:1450:4001:80b::200e"]) assert(isPublicAddress(ip), ip);
});
Deno.test("one private answer refuses the whole name", () => {
  assertEquals(pickAddress(["93.184.216.34"]), "93.184.216.34");
  assertEquals(pickAddress(["93.184.216.34", "127.0.0.1"]), null);
  assertEquals(pickAddress([]), null);
});
Deno.test("addresses: the crawler's rules plus wildcard DNS services", () => {
  const ok = checkUrl("https://www.shop.com/about?x=1", "shop.com");
  assert(!("error" in ok) && ok.port === 443 && ok.https && ok.host === "www.shop.com");
  for (const [u, h, e] of [["https://127.0.0.1.nip.io/", "127.0.0.1.nip.io", "internal_host"], ["http://a.sslip.io/", "a.sslip.io", "internal_host"],
    ["http://x.localtest.me/", "x.localtest.me", "internal_host"], ["http://lvh.me/", "lvh.me", "internal_host"], ["http://10.0.0.1/", "10.0.0.1", "bad_host"],
    ["http://shop.com:8080/", "shop.com", "bad_port"], ["ftp://shop.com/", "shop.com", "bad_url"], ["https://evil.com/", "shop.com", "other_site"],
    ["https://user@shop.com/", "shop.com", "bad_url"], ["https://printer.local/", "printer.local", "internal_host"]] as const) {
    const r = checkUrl(u, h); assertEquals("error" in r ? r.error : "ok", e, u);
  }
});
Deno.test("the request names the host and asks for a plain, closed answer", () => {
  const t = checkUrl("http://shop.com/a?b=1", "shop.com");
  if ("error" in t) throw new Error(t.error);
  const r = request(t);
  assert(r.startsWith("GET /a?b=1 HTTP/1.1\r\nHost: shop.com\r\n") && r.includes("Connection: close") && r.endsWith("\r\n\r\n"));
});
Deno.test("answers: plain, chunked, redirects and only safe headers", () => {
  const enc = (s: string) => new TextEncoder().encode(s);
  const a = parseAnswer(enc("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nSet-Cookie: x=1\r\nContent-Length: 5\r\n\r\nhello extra"))!;
  assertEquals([a.statusCode, a.body, a.headers], [200, "hello", { "content-type": "text/html; charset=utf-8" }]);
  const c = parseAnswer(enc("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n"))!;
  assertEquals(c.body, "Wikipedia");
  const r = parseAnswer(enc("HTTP/1.1 301 Moved\r\nLocation: https://shop.com/new\r\n\r\n"))!;
  assertEquals([r.statusCode, r.headers.location], [301, "https://shop.com/new"]);
  assertEquals(parseAnswer(enc("garbage")), null);
  const hints = parseAnswer(enc("HTTP/1.1 103 Early Hints\r\nLink: </a.css>; rel=preload\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 2\r\n\r\nok"))!;
  assertEquals([hints.statusCode, hints.body], [200, "ok"]);
});
