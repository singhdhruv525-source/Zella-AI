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
