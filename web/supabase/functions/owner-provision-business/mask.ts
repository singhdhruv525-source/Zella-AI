// The one masking rule for contact details admins see on a business's page: the same as the database's
// zella_admin_mask(text) (sql/zella_admin_ops.sql), so the Voice page, which masks in SQL, and the business page agree.
//   empty or null  -> null
//   an email       -> first letter, "…@", the domain               (ada@example.com -> a…@example.com)
//   anything else  -> "…" and the last 4 DIGITS, other characters dropped first   (+1 (555) 010-0123 -> …0123)
// mask_test.ts checks it against fixtures made by zella_admin_mask in the isolated database.
// The Spam page keeps its own older rule in platform.ts ("Unknown" for an empty sender); not changed here.
export function mask(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  const s = String(value);
  if (s === "") return null;
  if (s.includes("@")) {
    const [local, ...rest] = s.split("@");
    return `${local.slice(0, 1)}…@${rest[0] ?? ""}`;
  }
  return `…${s.replace(/\D/g, "").slice(-4)}`;
}

// Free text that may quote an email or a phone number (a provider's error message, an invitation's last error):
// each email and each run of 7 or more digits (spaces, dots, dashes and brackets allowed between them) is masked,
// the rest of the text is kept so the admin can still read what went wrong.
export function maskText(value: unknown): string | null {
  if (value === null || value === undefined || value === "") return null;
  return String(value)
    .replace(/[^\s@<>()"',;:]+@[^\s@<>()"',;:]+/g, (m) => mask(m) ?? "")
    .replace(/\+?\d[\d\s().-]{5,}\d/g, (m) => (m.replace(/\D/g, "").length >= 7 ? mask(m) ?? "" : m));
}
