// The caller's IP address for rate limits and audit rows (security audit 18 Nov 2026, 6.1, M10).
// The FIRST X-Forwarded-For value is whatever the caller wrote, so it is never used. Supabase's edge functions sit
// behind Cloudflare, which sets CF-Connecting-IP to the address that connected to it and overwrites any value the
// caller sent; the platform's own proxies append to X-Forwarded-For, so its LAST value is the nearest hop the platform
// added. Suspected, not confirmed on the live gateway (no production deploys in this change): check once with a test
// function that echoes these headers, and if Cloudflare is not in front, CF-Connecting-IP must be dropped here.
// a complete IPv4 (each part 0 to 255) or IPv6 literal, nothing else
export function isIp(v: string): boolean {
  const four = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(v);
  if (four) return four.slice(1).every((x) => Number(x) <= 255);
  if (!/^[0-9a-f:.]{2,45}$/i.test(v) || !v.includes(":")) return false;
  try { return new URL(`http://[${v}]/`).hostname.length > 2; } catch { return false; }
}
export function clientIp(headers: Headers): string | null {
  const cf = (headers.get("cf-connecting-ip") ?? "").trim();
  if (isIp(cf)) return cf.toLowerCase();
  const parts = (headers.get("x-forwarded-for") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  const last = parts[parts.length - 1] ?? "";
  return isIp(last) ? last.toLowerCase() : null;
}
