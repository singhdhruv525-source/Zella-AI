// Messaging, contact lookup (COM-29): what the form must have before asking the server, which checks the same.
export function lookupProblem({ business, query, reason }) {
  const q = String(query ?? "").trim();
  if (!business) return "Choose a business first.";
  const email = /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(q);
  if (!email && (/[a-z@]/i.test(q) || q.replace(/\D/g, "").length < 4)) return "Enter at least the last 4 digits of the number, or the full email address.";
  if (String(reason ?? "").trim().length < 3) return "Give a short reason (it goes in the audit log).";
  return "";
}
