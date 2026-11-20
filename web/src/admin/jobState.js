// Scheduled jobs in plain words, from zella_admin_scheduler_health (sql/zella_job_intent.sql adds each job's intended
// state). Pure helpers, so the pages and node --test read jobs the same way. Nothing here switches a job: that is the
// owner's live switch, done at go live (n8n/GO-LIVE.md).

export const JOB_LABELS = {
  zella_dispatch: "Dispatcher",
  zella_jobs_every5: "Every 5 minutes",
  zella_jobs_every15: "Every 15 minutes",
  zella_jobs_hourly: "Hourly",
  zella_jobs_daily: "Daily",
  zella_jobs_weekly: "Weekly",
  zella_cron_cleanup: "Run history cleanup",
  zella_platform_emails: "Emails to businesses",
  zella_spam_hourly: "Spam protection",
  zella_usage_thresholds: "Usage alerts",
  zella_billing_reconcile: "Billing reconcile",
};

export const jobLabel = (name) => JOB_LABELS[name] ?? String(name ?? "").replace(/^zella_/, "").replace(/_/g, " ");

// Every job the health check knows: the real ones, then the ones with an intent but no job created yet.
export function allJobs(health) {
  const jobs = (health?.jobs ?? []).map((j) => ({ ...j, exists: true }));
  const only = (health?.intent_only ?? []).map((j) => ({ ...j, active: false, exists: false }));
  return [...jobs, ...only];
}

// One job's state for a pill and a note: { known, on, tone, label, intent, mismatch }
export function jobState(health, name) {
  if (!health) return { known: false, on: null, tone: "neutral", label: "Unknown", intent: null, mismatch: false };
  const j = allJobs(health).find((x) => x.name === name);
  if (!j) return { known: true, on: false, tone: "neutral", label: "Not created", intent: null, mismatch: false };
  const on = Boolean(j.active) && j.exists;
  const mismatch = j.intent_matches === false;
  const intent = j.intended === "off" ? (j.intent_reason || "Deliberately off")
    : j.intended === "on" ? `Meant to be on${j.intent_reason ? `: ${j.intent_reason}` : ""}` : null;
  const label = !j.exists ? "Not created" : on ? "On" : j.intended === "off" ? "Off on purpose" : "Off";
  return { known: true, on, tone: mismatch ? "warning" : on ? "success" : "neutral", label, intent, mismatch };
}

// The note for a number that depends on a job: null while the job is on (or its state is unknown).
export function jobOffNote(health, name) {
  const s = jobState(health, name);
  if (!s.known || s.on) return null;
  return `Needs the ${jobLabel(name)} job, which is off${s.intent ? ` (${s.intent.toLowerCase()})` : ""}.`;
}
