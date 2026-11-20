// Data retention (Settings > Security and privacy > Data retention): names for each kind of data and periods in words.
// Pure: tested in tests/retentionLabels.test.mjs.

export const CLASS_LABELS = {
  call_recordings: ["Call recordings", "The recording link is removed from the call."],
  call_transcripts: ["Call transcripts", "The transcript is removed; the call, its summary and outcome stay."],
  message_bodies: ["Message words", "The words of texts, emails and conversation messages; the record of each message stays."],
  audit_logs: ["Audit and security logs", "Old audit rows are deleted."],
  documents_replaced: ["Replaced verification copies", "Files replaced by a newer copy, counted from the replacement."],
  documents_owner_id_verified: ["Owner identity files", "Counted from verification; the outcome (status, reviewer, date) is kept."],
  documents_cancelled_business: ["Canceled businesses' documents", "Every verification file, counted from cancellation."],
  cancelled_business: ["Canceled businesses", "The whole business, after a final export offer, and never before its retention date."],
};
export const classLabel = (c) => CLASS_LABELS[c]?.[0] ?? c;

// 30 -> "30 days", 730 -> "2 years", 2555 -> "7 years", 365 -> "1 year", 1 -> "1 day".
export function periodWords(days) {
  const d = Number(days);
  if (!Number.isFinite(d) || d <= 0) return "Not set";
  if (Number.isInteger(d) && d % 365 === 0) { const y = d / 365; return `${y} year${y === 1 ? "" : "s"}`; }
  return `${d} day${d === 1 ? "" : "s"}`;
}

export const SOURCE_LABELS = {
  calls: "Calls", sms_messages: "Texts", email_messages: "Emails", conversation_messages: "Conversation messages",
  audit_logs: "Audit rows", business_verification_documents: "Documents", businesses: "Businesses",
};
