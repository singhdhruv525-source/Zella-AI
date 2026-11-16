// Test helper: signs a body the way the provider would, with a fake secret.
const enc = new TextEncoder();
export async function sign(raw: string | Uint8Array, secret: string, t: number) {
  const bytes = typeof raw === "string" ? enc.encode(raw) : raw;
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const prefix = enc.encode(`${t}.`), all = new Uint8Array(prefix.length + bytes.length);
  all.set(prefix); all.set(bytes, prefix.length);
  return [...new Uint8Array(await crypto.subtle.sign("HMAC", key, all))].map((x) => x.toString(16).padStart(2, "0")).join("");
}
