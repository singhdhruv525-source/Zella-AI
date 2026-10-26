import { useCallback, useEffect, useState } from "react";
import { supabase } from "./supabase";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { formatDateTime } from "./ownerFormat";

// Platform Operations panels for the monitoring the database already does
// (sql/zella_monitoring.sql): provider health, failed events with retry, and
// incidents that tell every business owner. Each database function checks
// is_platform_admin() itself.

const CODES = {
  NOT_ALLOWED: "Only a Zella admin can do this.",
  NOT_RETRYABLE: "This event was already retried or is no longer failed.",
  TITLE_REQUIRED: "Give the incident a title of at least 3 characters.",
  ALREADY_RESOLVED: "This incident is already resolved.",
};
const say = (error) => {
  const message = error?.message ?? String(error);
  const code = Object.keys(CODES).find((k) => message.includes(k));
  return code ? CODES[code] : message;
};

function useAsync(loader) {
  const [state, setState] = useState({ data: null, error: "", loading: true });
  const run = useCallback(async () => {
    setState((s) => ({ ...s, loading: true, error: "" }));
    try {
      setState({ data: await loader(), error: "", loading: false });
    } catch (err) {
      setState((s) => ({ ...s, error: say(err), loading: false }));
    }
  }, [loader]);
  useEffect(() => { run(); }, [run]);
  return { ...state, reload: run };
}

const loadHealth = async () => {
  const { data, error } = await supabase.rpc("zella_platform_health_summary");
  if (error) throw error;
  return data;
};

function HealthPanel() {
  const { data, error, loading } = useAsync(loadHealth);
  const alerts = data?.open_alerts ?? {};
  return (
    <section className="owner-panel op-card">
      <div className="owner-panel-heading"><div><h2>Providers and alerts</h2><p>From the scheduled provider checks and open platform alerts.</p></div></div>
      {error && <div className="owner-form-error op-gap-top">{error}</div>}
      <ul className="op-list">
        {loading && !data && <li><span className="op-muted">Checking...</span></li>}
        {data && <li><div><strong>Open alerts</strong><span>Urgent {alerts.urgent ?? 0} · warning {alerts.warning ?? 0} · info {alerts.info ?? 0}</span></div>
          <Pill tone={alerts.urgent ? "danger" : alerts.warning ? "warning" : "success"}>{alerts.urgent || alerts.warning ? "Needs a look" : "Clear"}</Pill></li>}
        {data && <li><div><strong>Failed events (24 h)</strong><span>Automation events that failed for good</span></div><Pill tone={data.failed_events_24h ? "danger" : "success"}>{data.failed_events_24h || "None"}</Pill></li>}
        {data && <li><div><strong>Businesses with failed texts (24 h)</strong><span>Outbound texts that couldn't be delivered</span></div><Pill tone={data.businesses_with_failed_messages_24h ? "warning" : "success"}>{data.businesses_with_failed_messages_24h || "None"}</Pill></li>}
        {(data?.providers ?? []).map((p) => (
          <li key={p.provider}>
            <div><strong>{p.provider}</strong><span>{p.detail || "—"} · checked {formatDateTime(p.checked_at)}{p.failures_in_a_row ? ` · ${p.failures_in_a_row} failures in a row` : ""}</span></div>
            <Pill tone={p.ok ? "success" : "danger"}>{p.ok ? "OK" : "Failing"}</Pill>
          </li>
        ))}
        {data && !(data.providers ?? []).length && <li><div><strong>Provider checks</strong><span>No results yet. They run once provider_checks_live is on.</span></div></li>}
      </ul>
    </section>
  );
}

const loadFailed = () => callOwnerFunction("failed_events_list", { limit: 50 });

function FailedEventsPanel({ onOpenBusiness }) {
  const { data, error, loading, reload } = useAsync(loadFailed);
  const [busy, setBusy] = useState("");
  const [notice, setNotice] = useState("");
  async function retry(event) {
    setBusy(event.id);
    setNotice("");
    const { error: e } = await supabase.rpc("zella_retry_event", { p_event_id: event.id });
    setBusy("");
    setNotice(e ? say(e) : `${event.event_type} sent back to the queue. It runs on the next dispatcher pass.`);
    if (!e) reload();
  }
  const events = data?.events ?? [];
  return (
    <section className="owner-panel op-card">
      <div className="owner-panel-heading"><div><h2>Failed events</h2><p>Events that ran out of retries. Fix the cause first, then send them back.</p></div></div>
      {error && <div className="owner-form-error op-gap-top">{error}</div>}
      {notice && <div className="owner-form-success op-gap-top" role="status">{notice}</div>}
      <ul className="op-list">
        {loading && !data && <li><span className="op-muted">Loading...</span></li>}
        {data && !events.length && <li><span className="op-muted">No failed events.</span></li>}
        {events.map((e) => (
          <li key={e.id}>
            <div>
              <strong>{e.event_type} <span className="op-muted">from {e.source}</span></strong>
              <span>
                {e.business_name
                  ? <button type="button" className="op-link" onClick={() => onOpenBusiness(e.business_id)}>{e.business_name}</button>
                  : "Unknown business"}
                {" · "}{formatDateTime(e.received_at)} · {e.attempts} attempts
              </span>
              {(e.error_category || e.error_message) && <span>{[e.error_category, e.error_message].filter(Boolean).join(": ")}</span>}
            </div>
            <button type="button" className="owner-secondary-button op-small" disabled={Boolean(busy)} onClick={() => retry(e)}>{busy === e.id ? "Sending..." : "Retry"}</button>
          </li>
        ))}
      </ul>
    </section>
  );
}

const loadIncidents = async () => {
  const { data, error } = await supabase.from("platform_incidents")
    .select("id, title, detail, status, notified_businesses, resolution_note, created_at, resolved_at")
    .order("created_at", { ascending: false }).limit(20);
  if (error) throw error;
  return data ?? [];
};

function IncidentsPanel() {
  const { data, error, loading, reload } = useAsync(loadIncidents);
  const [form, setForm] = useState({ title: "", detail: "" });
  const [notes, setNotes] = useState({});
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState({ text: "", error: "" });

  async function open(event) {
    event.preventDefault();
    if (!window.confirm("Open this incident? Every active business owner is notified now.")) return;
    setBusy(true);
    const { data: id, error: e } = await supabase.rpc("zella_open_incident", { p_title: form.title, p_detail: form.detail || null });
    setBusy(false);
    if (e) return setNotice({ text: "", error: say(e) });
    setForm({ title: "", detail: "" });
    setNotice({ text: id ? "Incident opened and owners notified." : "", error: "" });
    reload();
  }

  async function resolve(incident) {
    if (!window.confirm(`Resolve "${incident.title}"? Every active business owner is told it's fixed.`)) return;
    setBusy(true);
    const { error: e } = await supabase.rpc("zella_resolve_incident", { p_incident_id: incident.id, p_note: notes[incident.id] || null });
    setBusy(false);
    if (e) return setNotice({ text: "", error: say(e) });
    setNotice({ text: "Incident resolved and owners told.", error: "" });
    reload();
  }

  return (
    <section className="owner-panel op-card">
      <div className="owner-panel-heading"><div><h2>Incidents</h2><p>An outage or problem that affects businesses. Opening and resolving one notifies every active owner.</p></div></div>
      {error && <div className="owner-form-error op-gap-top">{error}</div>}
      {notice.error && <div className="owner-form-error op-gap-top" role="alert">{notice.error}</div>}
      {notice.text && <div className="owner-form-success op-gap-top" role="status">{notice.text}</div>}
      <form className="op-card-body op-incident-form" onSubmit={open}>
        <input className="owner-input" placeholder="What's wrong, for example: Text messages delayed" value={form.title} maxLength={200}
          onChange={(e) => setForm({ ...form, title: e.target.value })} aria-label="Incident title" />
        <input className="owner-input" placeholder="Details owners will see (optional)" value={form.detail} maxLength={1000}
          onChange={(e) => setForm({ ...form, detail: e.target.value })} aria-label="Incident details" />
        <button type="submit" className="owner-secondary-button op-small" disabled={busy || form.title.trim().length < 3}>Open incident</button>
      </form>
      <ul className="op-list">
        {loading && !data && <li><span className="op-muted">Loading...</span></li>}
        {data && !data.length && <li><span className="op-muted">No incidents.</span></li>}
        {(data ?? []).map((i) => (
          <li key={i.id}>
            <div>
              <strong>{i.title}</strong>
              <span>Opened {formatDateTime(i.created_at)} · {i.notified_businesses} businesses told{i.resolved_at ? ` · resolved ${formatDateTime(i.resolved_at)}` : ""}</span>
              {i.detail && <span>{i.detail}</span>}
              {i.resolution_note && <span>Fix: {i.resolution_note}</span>}
            </div>
            {i.status === "open" ? (
              <div className="op-inline">
                <input className="owner-input" placeholder="What fixed it (optional)" value={notes[i.id] ?? ""} maxLength={500}
                  onChange={(e) => setNotes({ ...notes, [i.id]: e.target.value })} aria-label="Resolution note" />
                <button type="button" className="owner-secondary-button op-small" disabled={busy} onClick={() => resolve(i)}>Resolve</button>
              </div>
            ) : <Pill tone="success">Resolved</Pill>}
          </li>
        ))}
      </ul>
    </section>
  );
}

export default function PlatformMonitoring({ onOpenBusiness }) {
  return (
    <>
      <div className="op-grid">
        <HealthPanel />
        <FailedEventsPanel onOpenBusiness={onOpenBusiness} />
      </div>
      <IncidentsPanel />
    </>
  );
}
