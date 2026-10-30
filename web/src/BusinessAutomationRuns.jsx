import { useState } from "react";
import { supabase } from "./supabase";
import { Icon, Pill } from "./BusinessUI";
import { formatDay, formatTime, timeAgo } from "./businessTime";
import { explain } from "./BusinessShared";
import { humanize } from "./copy/labels";

/* What each automation does in plain words, and what has actually happened when it ran. */

const CHANNEL = { sms: "text", call: "AI call", sms_and_call: "text and AI call", email: "email" };
const hoursText = (h) => (h < 1 ? `${Math.round(h * 60)} minutes` : h % 24 === 0 ? `${h / 24} day${h === 24 ? "" : "s"}` : `${h} hour${h === 1 ? "" : "s"}`);
const minsText = (m) => (m === 0 ? "straight away" : m >= 60 ? `${m / 60} hour${m === 60 ? "" : "s"}` : `${m} minutes`);


// Industry automations (records, reminders, check-ins) carry their steps in the saved rule.
const label = humanize;
function ruleActions(rule = {}) {
  const parts = [];
  if (rule.message) parts.push(rule.mode === "draft" ? "write a message for a person to check and send" : "send a message");
  if (rule.task) parts.push("create a task for the team");
  if (rule.notify) parts.push("alert the owners");
  return parts.length ? `${parts.join(", ").replace(/^./, (c) => c.toUpperCase())}.` : "—";
}
function describeIndustry(type, cfg) {
  const kind = label(cfg.type_key || "record");
  const noOptOut = "Customers who opted out are never messaged.";
  if (type === "record_status_action") {
    const rules = cfg.rules ?? [];
    return {
      trigger: rules.length ? `A record in ${kind} changes to ${rules.map((r) => `“${label(r.status)}”`).join(" or ")}` : `A record in ${kind} changes status`,
      conditions: noOptOut,
      actions: rules.map((r) => ruleActions(r)).join(" ") || "—",
    };
  }
  if (type === "record_stale") {
    const wait = cfg.after_hours ? hoursText(cfg.after_hours) : hoursText((cfg.after_days ?? 3) * 24);
    return { trigger: `A record in ${kind} stays “${label(cfg.status)}” for ${wait}`, conditions: `The record is still open. ${noOptOut}`, actions: ruleActions(cfg.rule) };
  }
  if (type === "record_due_reminder") {
    const before = cfg.before_hours ? `${hoursText(cfg.before_hours)} before` : cfg.after_hours ? `${hoursText(cfg.after_hours)} after` : "on";
    return { trigger: `${before} the ${label(cfg.due_field || "due date")} of a record in ${kind}`, conditions: `The record is open. ${noOptOut}`, actions: ruleActions(cfg.rule) };
  }
  if (type === "appointment_followup") {
    return { trigger: `${hoursText((cfg.after_days ?? 1) * 24)} after a completed visit`, conditions: noOptOut, actions: ruleActions(cfg.rule) };
  }
  if (type === "service_due") {
    return { trigger: `A customer has not visited for ${cfg.days ?? 180} days`, conditions: `They have no upcoming visit. ${noOptOut}`, actions: "Send a short check-in message." };
  }
  if (type === "seasonal_reminder") {
    return { trigger: "The first week of the chosen months", conditions: `They visited in the last 2 years and have nothing booked. ${noOptOut}`, actions: "Send a short check-in message." };
  }
  return null;
}

export function describe(type, cfg = {}) {
  const ch = CHANNEL[cfg.channel] ?? "message";
  const tries = cfg.max_attempts ? `up to ${cfg.max_attempts} ${cfg.max_attempts === 1 ? "try" : "tries"}` : "a few tries";
  const optOut = "The person hasn't opted out of being contacted.";
  const map = {
    appointment_reminder: {
      trigger: "An appointment is coming up",
      conditions: `The appointment is booked. ${optOut}`,
      actions: `Send a ${ch} reminder ${(cfg.hours_before ?? [24]).map((h) => `${hoursText(h)} before`).join(" and ")}.`,
    },
    appointment_confirmation: {
      trigger: "An appointment is coming up",
      conditions: `The appointment isn't confirmed yet. ${optOut}`,
      actions: `Ask them to confirm by ${ch}, ${hoursText(cfg.hours_before ?? 24)} before.`,
    },
    no_show_follow_up: {
      trigger: "Someone is marked as a no-show",
      conditions: optOut,
      actions: `Reach out by ${ch} ${minsText(cfg.minutes_after ?? 15)} later to offer a new time.`,
    },
    missed_call_follow_up: {
      trigger: "A call is missed",
      conditions: `Calling hours allow it. ${optOut}`,
      actions: `Call back ${minsText(cfg.minutes_after ?? 5)}, ${tries}${cfg.fallback_sms ? ", then send a text" : ""}. A person is asked to step in if nobody answers.`,
    },
    new_lead_callback: {
      trigger: "A new lead comes in",
      conditions: `They have a phone number. ${optOut}`,
      actions: `Call ${minsText(cfg.minutes_after ?? 0)}, ${tries}${cfg.fallback_sms ? ", then send a text" : ""}. The team is told if the lead isn't contacted in time.`,
    },
    post_appointment_follow_up: {
      trigger: "An appointment is completed",
      conditions: optOut,
      actions: `Send a ${ch} ${hoursText(cfg.hours_after ?? 24)} afterwards.`,
    },
    quote_follow_up: {
      trigger: "A quote has been sent",
      conditions: `The quote is still open. ${optOut}`,
      actions: `Follow up by ${ch} after ${hoursText(cfg.hours_after ?? 48)}, ${tries}.`,
    },
    lead_reactivation: {
      trigger: "A lead goes quiet",
      conditions: `Quiet for ${cfg.days_inactive ?? 30} days. ${optOut}`,
      actions: `Reach out by ${ch} to win them back.`,
    },
    waitlist_offer: {
      trigger: "A booking is canceled or a slot opens",
      conditions: "Someone is on the waitlist.",
      actions: `Offer the slot to up to ${cfg.offers ?? 3} people, each for ${cfg.offer_minutes ?? 30} minutes, by ${ch}.`,
    },
    staff_unavailable: {
      trigger: "A team member becomes unavailable",
      conditions: "They have bookings in that time.",
      actions: `Contact affected customers by ${ch} to rebook.`,
    },
  };
  return map[type] ?? describeIndustry(type, cfg) ?? { trigger: "Set by Zella", conditions: "—", actions: "—" };
}

export const RUN_TONE = { completed: "success", failed: "danger", running: "info", queued: "warning", waiting: "warning", cancelled: "" };
export const RUN_LABEL = { completed: "Done", failed: "Failed", running: "Running", queued: "Waiting to run", waiting: "Waiting", cancelled: "Canceled" };

const AUDIT_LABEL = {
  "automation.changed": "Settings or on/off changed",
  "automation.run_retried": "A failed run was retried",
};

export function failureReason(run) {
  if (run.error_message) return run.error_message;
  if (run.last_action_status && run.last_action_status !== "ok") return humanize(run.last_action_status);
  return "No reason was recorded.";
}

export function RunsPanel({ runs, audits, nameOf, people, canManage, tz, onNotice, onChanged }) {
  const [busy, setBusy] = useState("");
  const [error, setError] = useState("");
  const [tab, setTab] = useState("runs");

  async function retry(run) {
    setBusy(run.id);
    setError("");
    const { error: failure } = await supabase.rpc("zella_retry_automation_run", { p_run_id: run.id });
    setBusy("");
    if (failure) return setError(explain(failure));
    onNotice?.("Run queued to try again.");
    onChanged();
  }

  return (
    <div className="ba-runs">
      <div className="ba-segment" role="tablist" aria-label="History">
        <button type="button" role="tab" aria-selected={tab === "runs"} className={tab === "runs" ? "active" : ""} onClick={() => setTab("runs")}>Recent runs ({runs.length})</button>
        <button type="button" role="tab" aria-selected={tab === "audit"} className={tab === "audit" ? "active" : ""} onClick={() => setTab("audit")}>Audit trail ({audits.length})</button>
      </div>
      {error && <p className="ba-error" role="alert">{error}</p>}
      {tab === "runs" ? (!runs.length ? <p className="ba-muted">It hasn't run yet.</p> : (
        <ul className="ba-threads">
          {runs.slice(0, 10).map((r) => (
            <li key={r.id}>
              <span className="ba-thread-icon"><Icon name={r.status === "failed" ? "error" : r.status === "completed" ? "check_circle" : "schedule"} size="sm" /></span>
              <div>
                <strong>{people[r.customer_id] ? [people[r.customer_id].first_name, people[r.customer_id].last_name].filter(Boolean).join(" ") || "Customer" : "Run"} <Pill tone={RUN_TONE[r.status]}>{RUN_LABEL[r.status] ?? r.status}</Pill></strong>
                <small>
                  {formatDay(r.started_at ?? r.created_at, tz)} · {formatTime(r.started_at ?? r.created_at, tz)}
                  {r.attempt_count > 1 ? ` · ${r.attempt_count} attempts` : ""}
                  {r.status === "queued" || r.status === "waiting" ? (r.next_run_at ? ` · next ${formatDay(r.next_run_at, tz)} ${formatTime(r.next_run_at, tz)}` : "") : ""}
                </small>
                {r.status === "failed" && <small className="ba-fail">Why: {failureReason(r)}</small>}
              </div>
              {r.status === "failed" && canManage && (
                <button type="button" className="ba-btn sm" disabled={busy === r.id} onClick={() => retry(r)}><Icon name="replay" size="sm" />{busy === r.id ? "Retrying…" : "Retry"}</button>
              )}
            </li>
          ))}
        </ul>
      )) : (!audits.length ? <p className="ba-muted">No changes recorded.</p> : (
        <ul className="ba-threads">
          {audits.slice(0, 10).map((a) => (
            <li key={a.id}>
              <span className="ba-thread-icon"><Icon name="history" size="sm" /></span>
              <div>
                <strong>{AUDIT_LABEL[a.action] ?? a.action}</strong>
                <small>{nameOf[a.user_id] ?? "A team member"} · {timeAgo(a.created_at)}{a.new_data?.status && a.old_data?.status !== a.new_data.status ? ` · ${a.old_data?.status ?? "—"} to ${a.new_data.status}` : ""}</small>
              </div>
            </li>
          ))}
        </ul>
      ))}
    </div>
  );
}
