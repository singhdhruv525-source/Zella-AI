import { useCallback, useEffect, useState } from "react";
import { supabase } from "./supabase";
import { Icon, Pill } from "./BusinessUI";
import { formatDay, formatTime, timeAgo } from "./businessTime";
import { friendly } from "./BusinessShared";

// The messages Zella sends for one booking: its confirmation and reminders (appointment_reminders) and its follow-ups
// (followup_tasks: no-show, thank-you). Every line shows what really happened, as the sending workflows recorded it.
// Nothing here sends anything: sending is done by the database and the n8n workflows. When texting or email is not
// connected yet, the workflows record "not sent" and this says so, instead of showing the message as delivered.
// A failed message can be retried by an owner, admin or manager (zella_retry_failed). Each message keeps one send
// record, so a retry never sends a second copy of something that already went out.

const RETRY_ROLES = ["owner", "admin", "manager"];
const TASK_LABEL = {
  no_show_follow_up: "No-show follow-up", post_visit_thank_you: "Thank-you after the visit", post_appointment_follow_up: "Follow-up after the visit",
  review_request: "Review request", reschedule_offer: "Offer to rebook", appointment_followup: "Follow-up",
};
const CHANNEL = { sms: ["sms", "Text"], email: ["mail", "Email"], call: ["call", "Call"], voice: ["call", "Call"] };
const words = (s) => String(s ?? "").replace(/_/g, " ").replace(/^./, (c) => c.toUpperCase());

// What one reminder or task line says, from its recorded status and reason.
function outcome(row, status, oneWord) {
  const reason = String(row.error ?? row.outcome_notes ?? row.outcome ?? "");
  if (row.status === "sent" || row.status === "completed" || row.status === "done") {
    const at = row.sent_at ?? row.completed_at;
    return { tone: "success", icon: "done_all", text: `Sent${at ? ` ${timeAgo(at)}` : ""}` };
  }
  if (row.status === "pending" || row.status === "claimed" || row.status === "processing") {
    const when = `${formatDay(row.due_at, row.tz)}, ${formatTime(row.due_at, row.tz)}`;
    if (status && !status.scheduler) return { tone: "neutral", icon: "schedule", text: `Due ${when}. Automatic sending isn't switched on yet, so it waits.` };
    if (status && row.channel === "sms" && !status.texts) return { tone: "neutral", icon: "schedule", text: `Due ${when}. Texting isn't connected yet, so it won't go out.` };
    if (status && row.channel === "email" && !status.emails) return { tone: "neutral", icon: "schedule", text: `Due ${when}. Email isn't connected yet, so it won't go out.` };
    return { tone: "info", icon: "schedule", text: `Due ${when}` };
  }
  if (row.status === "failed") return { tone: "danger", icon: "error", text: `Failed${reason ? `: ${words(reason)}` : ""}`, retry: true };
  if (row.status === "cancelled") {
    return { tone: "neutral", icon: "block", text: reason === "replaced" ? `Replaced after the ${oneWord.toLowerCase()} changed` : `Not needed${reason ? `: ${words(reason)}` : ""}` };
  }
  if (reason.startsWith("dry_run")) return { tone: "warning", icon: "science", text: "Not sent: test mode, no provider is connected yet" };
  if (reason === "cannot_contact") return { tone: "warning", icon: "do_not_disturb_on", text: "Not sent: no phone or email the customer agreed to be contacted on" };
  return { tone: "warning", icon: "do_not_disturb_on", text: `Not sent${reason ? `: ${words(reason)}` : ""}` };
}

export function BookingMessages({ workspace, appt, tz, term }) {
  const [data, setData] = useState(null);
  const [busyId, setBusyId] = useState(null);
  const [error, setError] = useState("");
  const oneWord = term("appointment");

  const load = useCallback(async () => {
    const [reminders, tasks, status] = await Promise.all([
      supabase.from("appointment_reminders").select("id, kind, channel, hours_before, due_at, status, attempts, sent_at, error")
        .eq("business_id", workspace.id).eq("appointment_id", appt.id).order("due_at"),
      supabase.from("followup_tasks").select("id, kind, channel, due_at, status, attempts, outcome, outcome_notes, completed_at")
        .eq("business_id", workspace.id).eq("appointment_id", appt.id).order("due_at"),
      supabase.rpc("zella_messaging_status", { p_business_id: workspace.id }),
    ]);
    setData({
      rows: [
        ...(reminders.data ?? []).map((r) => ({ ...r, retryKind: "reminder", label: r.kind === "confirmation" ? `${oneWord} confirmation` : `Reminder${r.hours_before ? ` (${r.hours_before < 1 ? `${Math.round(r.hours_before * 60)} min` : `${Number(r.hours_before)} h`} before)` : ""}` })),
        ...(tasks.data ?? []).map((t) => ({ ...t, retryKind: "task", label: TASK_LABEL[t.kind] ?? words(t.kind) })),
      ].map((r) => ({ ...r, tz })),
      failedToLoad: Boolean(reminders.error && tasks.error),
      // Older databases don't have the status function yet: the lines still show, without the connection notes.
      status: status.error ? null : status.data,
    });
  }, [workspace.id, appt.id, oneWord, tz]);

  useEffect(() => { load(); }, [load]);

  async function retry(row) {
    setBusyId(row.id);
    setError("");
    const { error: e } = await supabase.rpc("zella_retry_failed", { p_business_id: workspace.id, p_kind: row.retryKind, p_id: row.id });
    setBusyId(null);
    if (e) {
      setError(String(e.message).includes("NOT_RETRYABLE") ? "This one can't be retried any more (it already went, or the time has passed)." : friendly(e));
      return;
    }
    load();
  }

  if (!data) return <p className="ba-muted bp-loading">Loading messages…</p>;
  const { rows, status } = data;
  const auto = status?.automations ?? {};
  const off = status ? [!status.texts && "texts", !status.emails && "emails"].filter(Boolean) : [];
  const canRetry = RETRY_ROLES.includes(workspace.role);

  return (
    <>
      {status && (off.length > 0 || !status.scheduler) && (
        <div className="bp-callout">
          <Icon name="info" size="sm" />
          <span>
            {off.length === 2 ? "Texts and emails aren't" : off.length ? `${words(off[0])} aren't` : "Messages aren't"} being sent yet
            {off.length ? ": no provider is connected" : ": automatic sending is switched off"}. Zella records each message it would send, and
            marks it not sent. Nothing is shown as delivered unless it really went.
          </span>
        </div>
      )}
      {error && <div className="ba-banner error">{error}</div>}
      {rows.length ? (
        <ul className="bp-msgs">
          {rows.map((row) => {
            const o = outcome(row, status, oneWord);
            const [icon, channel] = CHANNEL[row.channel] ?? ["notifications", words(row.channel || "Message")];
            return (
              <li key={`${row.retryKind}${row.id}`} className={`bp-msg ${o.tone}`}>
                <span className="bp-msg-icon"><Icon name={icon} size="sm" /></span>
                <span className="bp-msg-main">
                  <strong>{row.label}</strong>
                  <small><Icon name={o.icon} size="sm" />{o.text}</small>
                </span>
                <Pill tone={o.tone}>{channel}</Pill>
                {o.retry && canRetry && <button type="button" className="ba-btn sm" disabled={busyId === row.id} onClick={() => retry(row)}><Icon name="refresh" size="sm" />{busyId === row.id ? "Retrying…" : "Retry"}</button>}
              </li>
            );
          })}
        </ul>
      ) : (
        <div className="bp-empty">
          <Icon name="forward_to_inbox" />
          <p>
            {data.failedToLoad ? "Messages couldn't be loaded." : `No messages for this ${oneWord.toLowerCase()}.`}
            {!data.failedToLoad && status && auto.appointment_reminder !== "active" && auto.appointment_confirmation !== "active"
              ? " Confirmations and reminders are off for this business. Turn them on in Automations." : ""}
          </p>
        </div>
      )}
    </>
  );
}
