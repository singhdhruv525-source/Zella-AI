// The one go live checklist (UI-23): server secrets, settings, scheduled jobs and live switches in one list. Pure, so
// node --test checks it. Inputs:
//   server   go_live_checklist (owner-provision-business, ops.ts): secrets set or not, addresses set or not, switches
//   health   zella_admin_scheduler_health: jobs with their intended state, and whether the n8n secret is stored
//   triggers zella_admin_email_triggers: the two platform email triggers on, off or not created
// Any input can be missing (not loaded, or not applied yet): its rows then read "Not checked", never "Ready".
// Nothing here turns anything on. Jobs, switches and triggers are the owner's live switches.
import { allJobs, jobLabel, jobState } from "./jobState.js";
import { LIVE_SWITCHES } from "../copy/liveSwitches.js";

const ADDRESSES = {
  app_base_url: ["App address (customer links)", "The https address used in links sent to customers"],
  n8n_base_url: ["n8n address", "Where the database sends work for n8n"],
  platform_emails_url: ["Email sender function address", "Where the database wakes the function that sends emails to businesses"],
  email_from_address: ["Email sender address", "The address emails are sent from"],
  sms_from_number: ["Text sender number", "The number texts are sent from"],
};
const SWITCHES = {
  n8n_dispatch_enabled: ["Dispatcher switch", "Lets the database hand due work to n8n"],
  email_live: ["Emails live", "Off means test mode: nothing is sent"],
  sms_live: ["Texts live", "Off means test mode: nothing is sent"],
  calls_live: ["AI calls live", "Off means the AI places no outbound calls"],
  provider_checks_live: ["Provider checks", "Checks that Telnyx, Vapi and Resend answer"],
  calendar_sync_live: ["Calendar sync", "Bookings sync with Google and Microsoft calendars"],
  spam_workflow_live: ["Spam protection workflow", "Spam checks on calls and messages"],
};
const GROUP_TITLES = { core: "Server", providers: "Providers", email: "Email", calendar: "Calendar apps", automations: "Automations" };

// detail: plain words shown on the page; hint: the setting, secret or job behind it, only as a tooltip (UI-21)
const row = (key, label, detail, hint, state, extra = {}) => ({ key, label, detail, hint, state, note: null, approval: false, ...extra });
const unknown = (key, label, hint) => row(key, label, "Not checked: this part of the check didn't load", hint, "unknown");

export function goLiveChecklist({ server, health, triggers } = {}) {
  const secrets = (server?.secrets ?? []).map((s) => {
    const area = GROUP_TITLES[s.group] ?? "Server";
    if (s.key === "CALENDAR_REDIRECT_URL" && !s.set) return row(s.key, s.label, `${area}: not set, so the default address is used`, `Secret ${s.key}`, "ready");
    return row(s.key, s.label, `${area}${s.required ? ", required" : ""}`, `Secret ${s.key}`, s.set ? "ready" : "not_ready", { required: s.required });
  });
  const addr = new Map((server?.addresses ?? []).map((a) => [a.key, a.set]));
  const settings = Object.entries(ADDRESSES).map(([k, [label, help]]) =>
    addr.has(k) ? row(k, label, help, `Setting ${k}`, addr.get(k) ? "ready" : "not_ready") : unknown(k, label, `Setting ${k}`));
  settings.push(health
    ? row("zella_n8n_secret", "n8n secret stored in the database", "The shared secret n8n checks, kept in the database vault", "Vault secret zella_n8n_secret", health.n8n_secret_stored ? "ready" : "not_ready")
    : unknown("zella_n8n_secret", "n8n secret stored in the database", "Vault secret zella_n8n_secret"));
  const jobs = health ? allJobs(health).map((j) => {
    const st = jobState(health, j.name);
    const state = st.on ? "ready" : j.intended === "off" ? "off_on_purpose" : "not_ready";
    return row(j.name, `${jobLabel(j.name)} job`, j.drives ?? "A scheduled job", `Scheduled job ${j.name}`, state,
      { approval: true, note: st.mismatch ? "Not as intended" : st.intent ?? (j.exists ? null : "Not created") });
  }) : [unknown("jobs", "Scheduled jobs", "From the scheduler health check")];
  const sw = new Map((server?.switches ?? []).map((s) => [s.key, s.on]));
  const switches = Object.entries(SWITCHES).map(([k, [label, help]]) =>
    sw.has(k) ? row(k, LIVE_SWITCHES[k]?.thing ? `${LIVE_SWITCHES[k].thing} live` : label, help, `Setting ${k}`, sw.get(k) ? "ready" : "not_ready", { approval: true })
      : { ...unknown(k, label, `Setting ${k}`), approval: true });
  for (const t of ["platform_emails", "staff_notifications"]) {
    const label = t === "platform_emails" ? "Wake the sender for new emails to businesses" : "Wake the sender for new notification emails";
    const hint = `Database trigger zella_kick_platform_emails on ${t}`;
    if (!triggers) { switches.push({ ...unknown(`trigger_${t}`, label, hint), approval: true }); continue; }
    const v = triggers[t];
    switches.push(row(`trigger_${t}`, label, "Sends at once instead of waiting for the minute job", hint, v === true ? "ready" : "not_ready",
      { approval: true, note: v === null || v === undefined ? "Not created" : null }));
  }
  const groups = [
    { key: "secrets", title: "Server secrets", note: "Set or not set only. Values never leave the server.", rows: secrets.length ? secrets : [unknown("secrets", "Server secrets", "From the server configuration check")] },
    { key: "settings", title: "Settings", rows: settings },
    { key: "jobs", title: "Scheduled jobs", note: "Each one is switched on by the owner at go live.", rows: jobs },
    { key: "switches", title: "Live switches", note: "Each one is switched on by the owner at go live.", rows: switches },
  ];
  const all = groups.flatMap((g) => g.rows);
  return {
    groups,
    ready: all.filter((r) => r.state === "ready").length,
    total: all.length,
    unknown: all.filter((r) => r.state === "unknown").length,
    approvals: all.filter((r) => r.approval && r.state !== "ready").length,
  };
}

export const STATE_PILL = {
  ready: ["success", "Ready"],
  not_ready: ["warning", "Not yet"],
  off_on_purpose: ["neutral", "Off on purpose"],
  unknown: ["neutral", "Not checked"],
};
