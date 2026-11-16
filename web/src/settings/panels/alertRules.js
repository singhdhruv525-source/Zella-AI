// Alert rules editor helpers (SET-ALERT-RULES): the real alert kinds from the shared catalog (PLT-08) joined with the
// saved rules, a rule in plain words, and the form value the database accepts. Pure, so node --test checks them.

export const REPEAT_CHOICES = [[null, "Every time it happens"], [15, "At most every 15 minutes"], [60, "At most every hour"], [240, "At most every 4 hours"], [1440, "At most once a day"]];
export const SEVERITIES = [["", "As raised"], ["info", "Info"], ["warning", "Warning"], ["urgent", "Urgent"]];

// every kind the code raises (catalog alert_kinds), with its rule, whether it is protected and how often it was raised
export function ruleRows(catalog, data) {
  const rules = new Map((data?.rules ?? []).map((r) => [r.kind, r]));
  const protectedKinds = new Set(data?.protected ?? []);
  const seen = data?.seen ?? {};
  const kinds = new Set([...Object.keys(catalog?.alert_kinds ?? {}), ...rules.keys()]);
  return [...kinds].sort().map((kind) => ({
    kind, label: catalog?.alert_kinds?.[kind] ?? kind.replace(/_/g, " "), rule: rules.get(kind) ?? null,
    protected: protectedKinds.has(kind), seen: Number(seen[kind] ?? 0),
  }));
}

const hhmm = (t) => (t ? String(t).slice(0, 5) : "");
// a rule as one short sentence; no rule reads "As raised"
export function ruleSummary(row) {
  const r = row.rule;
  if (!r) return row.protected ? "As raised, always urgent" : "As raised";
  if (!r.enabled) return "Off";
  const parts = [r.severity ? `${r.severity[0].toUpperCase()}${r.severity.slice(1)}` : "As raised",
    r.destination === "bell" ? "bell only" : r.email_permission ? `email to admins with ${r.email_permission}` : "email to every admin"];
  if (r.repeat_minutes) parts.push(REPEAT_CHOICES.find(([m]) => m === r.repeat_minutes)?.[1].toLowerCase() ?? `at most every ${r.repeat_minutes} minutes`);
  if (r.quiet_start) parts.push(`quiet ${hhmm(r.quiet_start)} to ${hhmm(r.quiet_end)}`);
  return parts.join(", ");
}

export const formFrom = (row) => ({
  enabled: row.rule ? row.rule.enabled : true, severity: row.rule?.severity ?? "", destination: row.rule?.destination ?? "bell_and_email",
  email_permission: row.rule?.email_permission ?? "", repeat_minutes: row.rule?.repeat_minutes ?? null,
  quiet: Boolean(row.rule?.quiet_start), quiet_start: hhmm(row.rule?.quiet_start) || "22:00", quiet_end: hhmm(row.rule?.quiet_end) || "07:00",
  quiet_tz: row.rule?.quiet_tz ?? "America/New_York",
});

// what the form may send: a protected kind is always on and never lower than urgent
export function ruleFromForm(f, isProtected) {
  return {
    enabled: isProtected ? true : Boolean(f.enabled),
    severity: isProtected ? (f.severity === "urgent" ? "urgent" : null) : f.severity || null,
    destination: f.destination === "bell" ? "bell" : "bell_and_email",
    email_permission: f.destination === "bell" ? null : f.email_permission || null,
    repeat_minutes: f.repeat_minutes ? Number(f.repeat_minutes) : null,
    quiet_start: f.quiet ? f.quiet_start : null, quiet_end: f.quiet ? f.quiet_end : null, quiet_tz: f.quiet_tz || "America/New_York",
  };
}

// The areas the editor groups rules under, in the order they are shown. Platform takes every kind not listed.
export const AREAS = ["AI receptionist", "Billing", "Calendar", "Messaging", "Offers", "Platform"];
const AREA_KINDS = {
  "AI receptionist": ["agent_failures", "agent_sync_failed", "ai_call_failure", "call_not_summarized", "call_volume_spike", "knowledge_conflict", "knowledge_stale", "reconcile_knowledge_stuck", "repeated_transfer_failures", "lead_capture_failed", "spam_flood", "spam_repeat_offender", "website_page_broken"],
  Billing: ["billing_currency", "billing_event_failed", "billing_event_unmatched", "business_cancelled", "business_suspended", "payment_disputed", "payment_failed", "payment_overdue", "payment_partial_refund", "payment_reversed", "trial_ended", "usage_missing_duration", "usage_processing_failed"],
  Calendar: ["calendar_disconnected", "calendar_sync_failed", "reconcile_calendar"],
  Messaging: ["meta_disconnected", "meta_lead_failed", "meta_permissions_missing", "meta_send_failed", "reconcile_email_stuck", "reconcile_sms_stuck", "sms_failures", "platform_email_held", "stuck_followups"],
};
const AREA_OF = new Map(Object.entries(AREA_KINDS).flatMap(([area, kinds]) => kinds.map((k) => [k, area])));
export const ruleArea = (kind) => AREA_OF.get(kind) ?? (String(kind).startsWith("offer_") ? "Offers" : "Platform");

// rows that match the search and the "only changed" switch, grouped by area in AREAS order (empty areas left out)
export function groupRules(rows, { query = "", changedOnly = false } = {}) {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  const keep = rows.filter((r) => (!changedOnly || r.rule)
    && words.every((w) => `${r.label} ${r.kind.replace(/_/g, " ")} ${ruleArea(r.kind)}`.toLowerCase().includes(w)));
  return AREAS.map((area) => ({ area, rows: keep.filter((r) => ruleArea(r.kind) === area).sort((a, b) => a.label.localeCompare(b.label)) }))
    .filter((g) => g.rows.length);
}
