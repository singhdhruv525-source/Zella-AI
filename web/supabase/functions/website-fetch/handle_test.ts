// website-fetch with DNS and the network mocked: nothing connects anywhere.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { handle, type Net } from "./index.ts";

Deno.env.set("ZELLA_SERVER_SECRET_KEY", "server-key-for-tests-only-0123456789");
const AUTH = "Bearer server-key-for-tests-only-0123456789";
const call = (body: unknown, net: Net, auth = AUTH) => handle(new Request("http://fn/website-fetch", { method: "POST", body: JSON.stringify(body), headers: { authorization: auth } }), net);
const page = new TextEncoder().encode("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<title>Hi</title>");
function net(answers: Record<string, string[]>, remote?: string) {
  const used: string[] = [];
  const n: Net = { resolve: async (h) => answers[h] ?? [], exchange: async (address) => { used.push(address); return { bytes: page, remote: remote ?? address }; } };
  return { n, used };
}

Deno.test("only the server key may use it", async () => {
  const { n, used } = net({ "shop.com": ["93.184.216.34"] });
  assertEquals((await call({ url: "https://shop.com/", host: "shop.com" }, n, "Bearer nope")).status, 401);
  assertEquals((await call({ url: "https://shop.com/", host: "shop.com" }, n, "")).status, 401);
  assertEquals(used.length, 0);
});
Deno.test("a public site is read from the checked address, in the crawler's shape", async () => {
  const { n, used } = net({ "shop.com": ["93.184.216.34"] });
  const r = await (await call({ url: "https://shop.com/", host: "shop.com" }, n)).json();
  assertEquals([r.statusCode, r.body, r.headers["content-type"], used], [200, "<title>Hi</title>", "text/html", ["93.184.216.34"]]);
});
Deno.test("a public name that resolves to a private or metadata address is never connected to", async () => {
  for (const ip of ["127.0.0.1", "169.254.169.254", "10.0.0.5", "100.64.1.1", "::1", "fd00:ec2::254"]) {
    const { n, used } = net({ "evil-shop.com": ["93.184.216.34", ip] });
    const r = await (await call({ url: "http://evil-shop.com/", host: "evil-shop.com" }, n)).json();
    assertEquals([r.statusCode, r.error, used.length], [0, "private_address", 0], ip);
  }
});
Deno.test("wildcard DNS names and other bad addresses are refused before DNS", async () => {
  let asked = 0;
  const n: Net = { resolve: async () => { asked++; return ["127.0.0.1"]; }, exchange: async () => { throw new Error("no"); } };
  for (const [url, host] of [["http://127.0.0.1.nip.io/", "127.0.0.1.nip.io"], ["http://shop.com:22/", "shop.com"], ["http://other.com/", "shop.com"]]) {
    assertEquals((await (await call({ url, host }, n)).json()).statusCode, 0);
  }
  assertEquals(asked, 0);
});
Deno.test("an unresolvable name and a connection that lands elsewhere are refused", async () => {
  assertEquals((await (await call({ url: "http://shop.com/", host: "shop.com" }, net({}).n)).json()).error, "dns_failed");
  assertEquals((await (await call({ url: "http://shop.com/", host: "shop.com" }, net({ "shop.com": ["93.184.216.34"] }, "10.0.0.1").n)).json()).error, "private_address");
});
Deno.test("network failures answer statusCode 0, never throw", async () => {
  const n: Net = { resolve: async () => ["93.184.216.34"], exchange: async () => { throw new Error("reset"); } };
  const r = await (await call({ url: "http://shop.com/", host: "shop.com" }, n)).json();
  assert(r.statusCode === 0 && r.error === "network");
  assertEquals((await handle(new Request("http://fn/website-fetch"), n)).status, 405);
});
