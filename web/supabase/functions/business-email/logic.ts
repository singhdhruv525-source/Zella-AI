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
export const REASONS = ["NOT_ALLOWED", "BAD_ADDRESS", "FREE_MAILBOX_DOMAIN", "PLATFORM_DOMAIN", "DOMAIN_TAKEN", "NOT_SET_UP", "BAD_PROVIDER_ANSWER"] as const;
export function reason(r: unknown): string {
  return typeof r === "string" && (REASONS as readonly string[]).includes(r) ? r.toLowerCase() : "try_again";
}

export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
