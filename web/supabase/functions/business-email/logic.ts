// The business's own email address (docs/ARCHITECTURE.md §14.4): pure pieces of the business-email function,
// unit tested in logic_test.ts. Resend's domains API (https://resend.com/docs/api-reference/domains):
//   POST   /domains              { name }  -> { id, name, status, records: [{ record, name, type, ttl, status, value, priority }] }
//   GET    /domains/{id}                   -> the same
//   POST   /domains/{id}/verify            -> { object: "domain", id }   (Resend checks the DNS records again)
//   GET    /domains                        -> { data: [{ id, name, status }] }
//   DELETE /domains/{id}
// Nothing here logs or returns a key, a token or a provider's own error text (SEC-14).
export const RESEND = "https://api.resend.com";

export type DnsRecord = { record?: string; type: string; name: string; value: string; ttl?: string; priority?: number; status?: string };
export type Domain = { id: string; name: string; status: string; records: DnsRecord[] };

// A domain object from Resend, kept to what the database and the setup page use; null when it isn't one.
export function readDomain(body: unknown): Domain | null {
  if (!body || typeof body !== "object") return null;
  const b = body as Record<string, unknown>;
  if (typeof b.id !== "string" || !/^[A-Za-z0-9_-]{1,100}$/.test(b.id) || typeof b.name !== "string") return null;
  const records = Array.isArray(b.records) ? b.records.flatMap((r) => {
    if (!r || typeof r !== "object") return [];
    const x = r as Record<string, unknown>;
    const type = String(x.type ?? "").toUpperCase();
    if (!["MX", "TXT", "CNAME"].includes(type) || typeof x.name !== "string" || typeof x.value !== "string" || !x.name || !x.value) return [];
    return [{ record: typeof x.record === "string" ? x.record.slice(0, 40) : undefined, type, name: x.name.slice(0, 253), value: x.value.slice(0, 2048),
      ttl: typeof x.ttl === "string" || typeof x.ttl === "number" ? String(x.ttl).slice(0, 20) : undefined,
      priority: typeof x.priority === "number" && Number.isInteger(x.priority) ? x.priority : undefined,
      status: typeof x.status === "string" ? x.status.slice(0, 30) : undefined }];
  }).slice(0, 20) : [];
  return { id: b.id, name: b.name.toLowerCase(), status: typeof b.status === "string" ? b.status : "not_started", records };
}

// Resend's domain states, in the three the setup page shows: verified, failed, or still pending (not started,
// pending, temporary failure: DNS changes can take a while to be seen)
export function domainStatus(s: unknown): "verified" | "failed" | "pending" {
  return s === "verified" ? "verified" : s === "failed" ? "failed" : "pending";
}

// Resend refuses to add a domain it already has in this account ("already exists" or "has been registered")
export function alreadyAdded(status: number, body: unknown): boolean {
  if (![400, 403, 409, 422].includes(status) || !body || typeof body !== "object") return false;
  const m = String((body as Record<string, unknown>).message ?? "");
  return /already (exists|been (added|registered))|has been registered|is already/i.test(m);
}

// the domain with exactly this name in a domains listing
export function findDomain(list: unknown, name: string): string | null {
  const data = list && typeof list === "object" && Array.isArray((list as Record<string, unknown>).data) ? (list as { data: unknown[] }).data : [];
  for (const d of data) {
    if (d && typeof d === "object" && (d as Record<string, unknown>).name === name && typeof (d as Record<string, unknown>).id === "string"
        && /^[A-Za-z0-9_-]{1,100}$/.test(String((d as Record<string, unknown>).id))) return String((d as Record<string, unknown>).id);
  }
  return null;
}

// The database's refusals, as short stable names the page turns into words
export const REASONS = ["NOT_ALLOWED", "BAD_ADDRESS", "FREE_MAILBOX_DOMAIN", "PLATFORM_DOMAIN", "DOMAIN_TAKEN", "NOT_SET_UP", "BAD_PROVIDER_ANSWER",
  // the "Connect your mailbox" link (sql/zella_business_email_mailbox_link.sql)
  "BUSINESS_NOT_ACTIVE", "NO_OWNER", "NO_OWNER_EMAIL", "ALREADY_CONNECTED", "TOO_MANY_LINKS", "MAILBOX_LINK_NOT_FOUND", "MAILBOX_LINK_USED",
  "MAILBOX_LINK_REPLACED", "MAILBOX_LINK_EXPIRED", "MAILBOX_LINK_NOT_YOURS", "NOT_OWNER",
  // removing a pending domain (sql/zella_business_email_pending_domains.sql)
  "REASON_REQUIRED", "NOT_PENDING"] as const;
export function reason(r: unknown): string {
  return typeof r === "string" && (REASONS as readonly string[]).includes(r) ? r.toLowerCase() : "try_again";
}

export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// The "Connect your mailbox" link (owner, 27 Nov 2026): a long random token (32 bytes) that goes only into the email;
// the database keeps its SHA 256 hash. It travels in the address fragment, so it never reaches a server log or a Referer.
export const LINK_TOKEN = /^[A-Za-z0-9_-]{43}$/;
export function newLinkToken(): string {
  return btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32)))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
export async function tokenHash(t: string): Promise<string> {
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(t)))].map((x) => x.toString(16).padStart(2, "0")).join("");
}
// where the link opens: the owner's own Settings page for that business, the token in the fragment
export function mailboxLinkPath(businessId: string, token: string): string {
  return `/app/settings/messages/business-email?business=${businessId.toLowerCase()}#mailbox_link=${token}`;
}
// an address shown back to the admin, partly hidden (BE-5): "ow***@example.com"
export function maskEmail(e: unknown): string {
  const s = typeof e === "string" ? e : "";
  const at = s.indexOf("@");
  return at < 1 ? "" : `${s.slice(0, Math.min(2, at))}***${s.slice(at)}`;
}

// The Resend domain removals the database queued (expired or admin removed pending domains): one DELETE each. 2xx or
// 404 (already gone) is removed; anything else is tried again later by the database.
export function removalOk(status: number): boolean { return (status >= 200 && status < 300) || status === 404; }
