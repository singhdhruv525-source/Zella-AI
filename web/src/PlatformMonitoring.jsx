import { useCallback, useEffect, useRef, useState } from "react";
import { supabase } from "./supabase";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { formatDateTime } from "./ownerFormat";
import { ReasonDialog } from "./admin/adminOps";
import IncidentDialog from "./admin/IncidentDialog";
import { Icon } from "./BusinessUI";
import "./PlatformMonitoring.css";

// Platform Operations panels for the monitoring the database already does
// (sql/zella_monitoring.sql): provider health, failed events with retry, and
// incidents that tell every business owner. Each database function checks
// is_platform_admin() itself.

const CODES = {
  NOT_ALLOWED: "Only a Zella Voice admin can do this.",
  NOT_RETRYABLE: "This event was already retried or is no longer failed.",
  TITLE_REQUIRED: "Give the incident a title of at least 3 characters.",
  ALREADY_RESOLVED: "This incident is already resolved.",
  NOT_OPEN: "Only an open incident can be changed.",
  BAD_INPUT: "Write at least 3 characters.",
  PUBLIC_MESSAGE_REQUIRED: "Write at least 10 characters for the public status page.",
  PUBLIC_MESSAGE_TOO_LONG: "Keep the public message under 500 characters.",
};
const say = (error) => {
  const message = error?.message ?? String(error);
  const code = Object.keys(CODES).find((k) => message.includes(k));
  return code ? CODES[code] : message;
};

// Blank values read the same everywhere: a short quiet phrase that fits ("Not recorded", "Not set", "Never"), never an empty cell.
function EmptyValue({ label = "Not recorded" }) {
  return <span className="empty-value">{label}</span>;
}
const clock = (d) => (d ? d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" }) : "");
const told = (n) => (Number.isInteger(n) && n > 0 ? `${n.toLocaleString()} ${n === 1 ? "business" : "businesses"} told` : "No businesses told");

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

export function HealthPanel() {
  const { data, error, loading } = useAsync(loadHealth);
  const rawAlerts = data?.open_alerts;
  const validAlerts = rawAlerts && typeof rawAlerts === "object" && !Array.isArray(rawAlerts);
  const alerts = Object.fromEntries(["urgent", "warning", "info"].map((k) => [k,
    validAlerts ? (Object.hasOwn(rawAlerts, k) ? rawAlerts[k] : 0) : null]));
  const counted = Object.values(alerts).every((n) => Number.isInteger(n) && n >= 0);
  const count = (k) => (Number.isInteger(alerts[k]) && alerts[k] >= 0 ? alerts[k] : <EmptyValue label="Unknown" />);
  return (
    <section className="owner-panel op-card pm-panel">
      <div className="owner-panel-heading"><div><h2>Providers and alerts</h2><p>From the scheduled provider checks and open platform alerts.</p></div></div>
      {error && <div className="owner-form-error op-gap-top">{error}</div>}
      <ul className="op-list">
        {loading && !data && <li><span className="op-muted">Checking…</span></li>}
        {data && <li><div><strong>Open alerts</strong><span>Urgent {count("urgent")} · Warning {count("warning")} · Info {count("info")}</span></div>
          <Pill tone={!counted ? "neutral" : alerts.urgent ? "danger" : alerts.warning ? "warning" : "success"}>{!counted ? "Unknown" : alerts.urgent || alerts.warning ? "Needs a look" : "Clear"}</Pill></li>}
        {data && <li><div><strong>Failed events, last 24 hours</strong><span>Automation events that failed for good</span></div><Pill tone={data.failed_events_24h ? "danger" : "success"}>{data.failed_events_24h || "No failures"}</Pill></li>}
        {data && <li><div><strong>Businesses with failed texts, last 24 hours</strong><span>Outbound texts that couldn't be delivered</span></div><Pill tone={data.businesses_with_failed_messages_24h ? "warning" : "success"}>{data.businesses_with_failed_messages_24h || "No failures"}</Pill></li>}
        {(data?.providers ?? []).map((p) => (
          <li key={p.provider}>
            <div><strong>{p.provider}</strong><span>{p.detail || <EmptyValue label="No detail recorded" />} · Checked {formatDateTime(p.checked_at)}{p.failures_in_a_row ? ` · ${p.failures_in_a_row} failures in a row` : ""}</span></div>
            <Pill tone={p.ok ? "success" : "danger"}>{p.ok ? "OK" : "Failing"}</Pill>
          </li>
        ))}
        {data && !(data.providers ?? []).length && <li><div><strong>Provider checks</strong><span>No results yet. They run once provider_checks_live is on.</span></div><Pill tone="neutral">Not checked</Pill></li>}
      </ul>
    </section>
  );
}

const loadFailed = () => callOwnerFunction("failed_events_list", { limit: 50 });

export function FailedEventsPanel({ onOpenBusiness }) {
  const { data, error, loading, reload } = useAsync(loadFailed);
  const [notice, setNotice] = useState("");
  const [retrying, setRetrying] = useState(null);
  // OPS-05: the server refuses a retry that could repeat a message, and keeps the reason in the audit log
  async function retry(event, reason) {
    const { error: e } = await supabase.rpc("zella_retry_event", { p_event_id: event.id, p_reason: reason });
    if (e) throw e;
    setNotice(`${event.event_type} sent back to the queue. It runs on the next dispatcher pass.`);
    reload();
  }
  const events = data?.events ?? [];
  return (
    <section className="owner-panel op-card pm-panel">
      <div className="owner-panel-heading"><div><h2>Failed events</h2><p>Events that ran out of retries. Fix the cause first, then send them back.</p></div></div>
      {error && <div className="owner-form-error op-gap-top">{error}</div>}
      {notice && <div className="owner-form-success op-gap-top" role="status">{notice}</div>}
      <ul className="op-list">
        {loading && !data && <li><span className="op-muted">Loading…</span></li>}
        {data && !events.length && <li className="inc-empty"><Icon name="check_circle" size="sm" /><span>No failed events.</span></li>}
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
              {(e.error_category || e.error_message) && <span className="pm-error">{[e.error_category, e.error_message].filter(Boolean).join(": ")}</span>}
            </div>
            <button type="button" className="owner-secondary-button inc-sm" onClick={() => { setNotice(""); setRetrying(e); }}>Retry</button>
          </li>
        ))}
      </ul>
      {retrying && (
        <ReasonDialog title="Send this event back to the queue?" icon="replay" confirmLabel="Send back"
          onConfirm={(reason) => retry(retrying, reason)} onClose={() => setRetrying(null)}>
          <p>{retrying.event_type} for {retrying.business_name ?? "an unknown business"} runs again on the next dispatcher pass. Fix the cause first.
            It is refused if an earlier run already did part of the work, for example sent a message.</p>
        </ReasonDialog>
      )}
    </section>
  );
}

const INCIDENT_COLUMNS = "id, title, detail, status, notified_businesses, resolution_note, created_at, resolved_at";
const PAGE = 20;
// OPS-12: newest first (ties by id), PAGE at a time. Load more reads the incidents after the last one shown, so a new
// incident opened meanwhile can't shift the page and repeat or skip one. is_public / public_message / component come
// with sql/zella_status.sql; without it the list still loads.
const loadIncidents = async (after = null) => {
  const query = (columns) => {
    let q = supabase.from("platform_incidents").select(columns).order("created_at", { ascending: false }).order("id", { ascending: false }).limit(PAGE);
    if (after) q = q.or(`created_at.lt."${after.created_at}",and(created_at.eq."${after.created_at}",id.lt.${after.id})`);
    return q;
  };
  let result = await query(`${INCIDENT_COLUMNS}, is_public, public_message, component`);
  if (result.error) result = await query(INCIDENT_COLUMNS);
  if (result.error) throw result.error;
  return result.data ?? [];
};
const STATUS_PARTS = [["", "No specific part"], ["phone", "Phone assistant"], ["texts", "Text messages"], ["email", "Email"], ["automations", "Reminders and follow ups"], ["app", "Zella Voice app"]];
const missingFn = (e) => /does not exist|Could not find the function|PGRST202/i.test(e?.message ?? "");

// OPS-12: an incident's timeline, newest UPDATES_PAGE first (shown oldest to newest), Load older reads the ones before
// the oldest shown with a (created_at, id) cursor. Updates are internal; owners are told only when "Tell all active
// businesses" is ticked. The draft, the post on its way and its error are kept by the panel per incident (post), and
// the panel posts, so closing and reopening the timeline while a post is pending can't send it twice, keeps the draft
// and the error, and the reopened timeline reads the new update once it is saved (post.version).
const UPDATES_PAGE = 50;
function IncidentTimeline({ incident, busy, post, onDraft, onPost }) {
  const [rows, setRows] = useState(null);
  const [more, setMore] = useState(false);
  const [readError, setReadError] = useState("");
  const [newestPending, setNewestPending] = useState(true);
  // The newest page and older pages are counted apart. An older page starts only while no newest page is on its way
  // (read at click time, from the ref) and is dropped if a newest page started after it; the newest page clears the
  // pending flag whenever it is the latest newest read, whatever older reads did meanwhile.
  const newest = useRef({ n: 0, pending: false });
  const older = useRef(0);
  const read = useCallback(async (before = null) => {
    if (before && newest.current.pending) return;
    const mineNewest = before ? newest.current.n : ++newest.current.n;
    const mineOlder = before ? ++older.current : older.current;
    if (!before) { newest.current.pending = true; setNewestPending(true); }
    let q = supabase.from("platform_incident_updates").select("id, body, notified_businesses, created_at").eq("incident_id", incident.id)
      .order("created_at", { ascending: false }).order("id", { ascending: false }).limit(UPDATES_PAGE);
    if (before) q = q.or(`created_at.lt."${before.created_at}",and(created_at.eq."${before.created_at}",id.lt.${before.id})`);
    const { data, error: e } = await q;
    if (mineNewest !== newest.current.n) return;          // a newer newest page is on its way: it decides
    if (before && mineOlder !== older.current) return;     // a later older page replaced this one
    if (!before) { newest.current.pending = false; setNewestPending(false); }
    if (e) { setReadError(missingFn(e) || /platform_incident_updates/.test(e.message) ? "Incident updates need the latest database update (sql/zella_incident_updates.sql)." : say(e)); if (!before) setRows([]); return; }
    setReadError("");   // a read clears only its own error, never a failed post's
    const page = [...(data ?? [])].reverse();
    setRows((current) => (before ? [...page, ...(current ?? [])] : page));
    setMore((data ?? []).length === UPDATES_PAGE);
  }, [incident.id]);
  // the newest page on opening, and again whenever a post for this incident is saved (also one sent before a reopen)
  useEffect(() => { read(); }, [read, post.version]);
  const oldest = rows?.[0];
  return (
    <div className="op-incident-timeline inc-timeline">
      {readError && <span className="owner-form-error" role="alert">{readError}</span>}
      {post.error && <span className="owner-form-error" role="alert">{post.error}</span>}
      {/* not while the newest page is being read: an older page must follow the newest one, never replace its reload */}
      {more && oldest && <button type="button" className="inc-link" disabled={newestPending} onClick={() => read({ created_at: oldest.created_at, id: oldest.id })}>Load older updates</button>}
      {rows && !rows.length && !readError && <span className="inc-update"><EmptyValue label="No updates yet" /></span>}
      {(rows ?? []).map((u) => (
        <span key={u.id} className="inc-update">
          <span className="inc-update-time">{formatDateTime(u.created_at)}{u.notified_businesses ? <>, {told(u.notified_businesses)}</> : ""}</span>
          <span className="inc-update-body">{u.body}</span>
        </span>
      ))}
      {incident.status === "open" && (
        <span className="inc-post">
          {/* read only while posting, so the text that is cleared afterwards is always the text that was posted */}
          <input className="owner-input" placeholder="What's happening now (for the Zella Voice team)" value={post.text} maxLength={1000} readOnly={post.posting} onChange={(e) => onDraft({ text: e.target.value })} aria-label={`Update for ${incident.title}`} />
          <label className="inc-check"><input type="checkbox" checked={post.notify} disabled={post.posting} onChange={(e) => onDraft({ notify: e.target.checked })} /> Tell all active businesses</label>
          <button type="button" className="owner-secondary-button inc-sm" disabled={busy || post.posting || post.text.trim().length < 3} onClick={onPost}>{post.posting ? "Posting…" : "Post update"}</button>
        </span>
      )}
    </div>
  );
}
const NO_POST = { text: "", notify: false, posting: false, error: "", version: 0, ref: null, refText: null, refNotify: null };

export function IncidentsPanel() {
  const [list, setList] = useState({ data: null, error: "", loading: true, more: false, at: null });
  const [form, setForm] = useState({ title: "", detail: "" });
  const [notes, setNotes] = useState({});
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState({ text: "", error: "" });
  const [dialog, setDialog] = useState(null);   // { kind: "open" | "publish" | "resolve" | "edit", incident?, similar? }
  const [open, setOpen] = useState({});          // incident id -> timeline shown
  const [edit, setEdit] = useState(null);        // { id, title, detail }
  const [posts, setPosts] = useState({});        // incident id -> { text, notify, posting, error, version }
  const inFlight = useRef(new Set());             // incident ids with a post on its way (also before the next render)
  const setPost = (id, patch) => setPosts((all) => ({ ...all, [id]: { ...NO_POST, ...all[id], ...patch } }));
  async function postUpdate(incident) {
    const draft = { ...NO_POST, ...posts[incident.id] };
    if (inFlight.current.has(incident.id)) return;
    inFlight.current.add(incident.id);
    // one id per update: sending the same update again (after a lost answer) returns the saved one and tells nobody
    // twice; a changed text or choice is a new update with a new id
    const same = draft.ref && draft.refText === draft.text && draft.refNotify === draft.notify;
    const ref = same ? draft.ref : crypto.randomUUID();
    setPost(incident.id, { posting: true, error: "", ref, refText: draft.text, refNotify: draft.notify });
    const { data: r, error: e } = await supabase.rpc("zella_incident_post_update", { p_incident: incident.id, p_body: draft.text, p_notify: draft.notify, p_ref: ref });
    inFlight.current.delete(incident.id);
    // the text stays, to try again
    if (e) return setPost(incident.id, { posting: false, error: /NOT_OPEN/.test(e.message ?? "") ? "This incident is resolved, so it takes no more updates." : say(e) });
    setPosts((all) => ({ ...all, [incident.id]: { ...NO_POST, version: (all[incident.id]?.version ?? 0) + 1 } }));
    // what the database says happened, not what the box said
    const n = Number(r?.notified_businesses);
    setNotice({ text: !Number.isFinite(n) ? "Update posted." : n > 0 ? `Update posted. The owners of ${n === 1 ? "1 business were" : `${n.toLocaleString()} businesses were`} told in the app.` : "Update posted. No owner was told.", error: "" });
  }

  // Every load gets a number; a reload makes any older load (a page still on its way) stale, and a stale answer or error
  // is dropped, so a page from before a reload is never added to the new list.
  const request = useRef(0);
  const reload = useCallback(async (append = false) => {
    const mine = ++request.current;
    setList((l) => ({ ...l, loading: true, error: "" }));
    try {
      const last = append ? list.data?.[list.data.length - 1] ?? null : null;
      const rows = await loadIncidents(last);
      if (mine !== request.current) return;
      setList((l) => ({ data: append ? [...(l.data ?? []), ...rows] : rows, error: "", loading: false, more: rows.length === PAGE, at: new Date() }));
    } catch (err) {
      if (mine !== request.current) return;
      setList((l) => ({ ...l, error: say(err), loading: false }));
    }
  }, [list.data]);
  useEffect(() => { reload(false); }, []);
  const done = (text) => { setNotice({ text, error: "" }); reload(false); };

  // SIMILAR_OPEN: another open incident looks like the same problem; the dialog shows it and offers Open anyway
  async function openIncident(force) {
    const { data: r, error: e } = await supabase.rpc("zella_open_incident_checked", { p_title: form.title, p_detail: form.detail || null, p_force: force });
    if (e && missingFn(e)) {
      const { error: e2 } = await supabase.rpc("zella_open_incident", { p_title: form.title, p_detail: form.detail || null });
      if (e2) throw new Error(say(e2));
    } else if (e) throw new Error(say(e));
    else if (r && r.opened === false) { setDialog({ kind: "open", similar: r.similar ?? [] }); return ""; }
    setForm({ title: "", detail: "" });
    done("Incident opened and owners notified.");
  }

  async function publish(incident, on, message) {
    setBusy(true);
    const { error: e } = await supabase.rpc("zella_set_incident_public", {
      p_incident_id: incident.id, p_public: on, p_message: on ? message : null, p_component: on ? (parts[incident.id] ?? incident.component ?? "") || null : null,
    });
    setBusy(false);
    if (e) throw new Error(say(e));
    done(on ? "Shown on the public status page (/status)." : "Taken off the status page.");
  }
  const [parts, setParts] = useState({});

  async function resolve(incident) {
    const { error: e } = await supabase.rpc("zella_resolve_incident", { p_incident_id: incident.id, p_note: notes[incident.id] || null });
    if (e) throw new Error(say(e));
    done("Incident resolved and owners told.");
  }

  async function saveEdit() {
    const saving = edit;
    setBusy(true);
    const { data: changed, error: e } = await supabase.rpc("zella_incident_edit", { p_incident: saving.id, p_title: saving.title, p_detail: saving.detail || null });
    setBusy(false);
    if (e) return setNotice({ text: "", error: missingFn(e) ? "Editing needs the latest database update (sql/zella_incident_updates.sql)." : say(e) });
    // close only the editor this save was for
    setEdit((current) => (current?.id === saving.id ? null : current));
    if (changed === false) return setNotice({ text: "No changes to save.", error: "" });
    done("Incident updated. Nobody was notified.");
  }

  const { data, error, loading } = list;
  const openCount = (data ?? []).filter((i) => i.status === "open").length;
  const partLabel = (v) => STATUS_PARTS.find(([k]) => k === (v ?? ""))?.[1];
  return (
    <section className="owner-panel op-card inc-panel">
      <div className="owner-panel-heading inc-head">
        <div>
          <div className="inc-eyebrow">Operations</div>
          <h2>Incidents</h2>
          <p>Outages or problems that affect businesses. Opening or resolving one notifies every active owner.</p>
        </div>
        <div className="inc-head-actions">
          {list.at && <span className="inc-updated" title={formatDateTime(list.at)}>Updated {clock(list.at)}</span>}
          <button type="button" className="owner-secondary-button inc-sm" disabled={loading} onClick={() => reload(false)}>
            <Icon name="refresh" size="sm" />{loading && data ? "Refreshing…" : "Refresh"}
          </button>
        </div>
      </div>
      {(error || notice.error || notice.text) && (
        <div className="inc-notices">
          {error && <div className="owner-form-error">{error}</div>}
          {notice.error && <div className="owner-form-error" role="alert">{notice.error}</div>}
          {notice.text && <div className="owner-form-success" role="status">{notice.text}</div>}
        </div>
      )}
      <form className="inc-new" onSubmit={(e) => { e.preventDefault(); setDialog({ kind: "open" }); }}>
        <label className="inc-field inc-field-title">
          <span>What's wrong</span>
          <input className="owner-input" placeholder="For example: Text messages delayed" value={form.title} maxLength={200}
            onChange={(e) => setForm({ ...form, title: e.target.value })} aria-label="Incident title" />
        </label>
        <label className="inc-field">
          <span>Details owners will see <em>(optional)</em></span>
          <input className="owner-input" placeholder="What owners should know" value={form.detail} maxLength={1000}
            onChange={(e) => setForm({ ...form, detail: e.target.value })} aria-label="Incident details" />
        </label>
        <button type="submit" className="owner-secondary-button inc-open-button" disabled={busy || form.title.trim().length < 3}>
          <Icon name="campaign" size="sm" />Open incident
        </button>
      </form>
      <ul className="op-list inc-list">
        {loading && !data && <li><span className="op-muted">Loading…</span></li>}
        {data && !data.length && !error && <li className="inc-empty"><Icon name="check_circle" size="sm" /><span>No incidents. Everything is running normally.</span></li>}
        {(data ?? []).map((i) => (
          <li key={i.id} className={`inc-row${i.status === "open" ? " is-open" : ""}`}>
            <div className="inc-main">
              {edit?.id === i.id ? (
                <span className="inc-edit">
                  {/* read only while saving, so the draft that closes is always the one that was saved */}
                  <input className="owner-input" value={edit.title} maxLength={200} readOnly={busy} onChange={(e) => setEdit({ ...edit, title: e.target.value })} aria-label="Incident title" />
                  <input className="owner-input" value={edit.detail} maxLength={1000} readOnly={busy} placeholder="Details owners will see" onChange={(e) => setEdit({ ...edit, detail: e.target.value })} aria-label="Incident details" />
                  <span className="inc-edit-actions">
                    <button type="button" className="owner-secondary-button inc-sm" disabled={busy} onClick={() => setEdit(null)}>Cancel</button>
                    <button type="button" className="owner-primary-button inc-sm" disabled={busy || edit.title.trim().length < 3} onClick={saveEdit}>Save</button>
                  </span>
                </span>
              ) : (
                <span className="inc-title-line">
                  <strong className="inc-title">{i.title}</strong>
                  <Pill tone={i.status === "open" ? "danger" : "success"}>{i.status === "open" ? "Open" : "Resolved"}</Pill>
                  {i.is_public && <Pill tone="info">On status page</Pill>}
                </span>
              )}
              <span className="inc-meta">
                Opened {formatDateTime(i.created_at)}<span aria-hidden="true"> · </span>{told(i.notified_businesses)}
                {i.resolved_at && <><span aria-hidden="true"> · </span>Resolved {formatDateTime(i.resolved_at)}</>}
              </span>
              {i.detail && edit?.id !== i.id && <span className="inc-detail">{i.detail}</span>}
              {i.resolution_note && <span className="inc-detail"><b>Fix:</b> {i.resolution_note}</span>}
              {i.is_public && (
                <span className="inc-public">
                  <Icon name="public" size="sm" />
                  <span>{i.public_message ? `“${i.public_message}”` : <EmptyValue label="No public message" />}{partLabel(i.component) && i.component ? ` (${partLabel(i.component)})` : ""}</span>
                </span>
              )}
              <span className="inc-actions">
                <button type="button" className="inc-link" aria-expanded={Boolean(open[i.id])} onClick={() => setOpen({ ...open, [i.id]: !open[i.id] })}>
                  <Icon name={open[i.id] ? "expand_less" : "expand_more"} size="sm" />{open[i.id] ? "Hide updates" : "Updates"}
                </button>
                {i.status === "open" && edit?.id !== i.id && <button type="button" className="inc-link" disabled={busy} onClick={() => setEdit({ id: i.id, title: i.title, detail: i.detail ?? "" })}>Edit</button>}
                {"is_public" in i && (i.is_public
                  ? <button type="button" className="inc-link" disabled={busy} onClick={() => publish(i, false).catch((e) => setNotice({ text: "", error: e.message }))}>Remove from status page</button>
                  : <button type="button" className="inc-link" disabled={busy} onClick={() => setDialog({ kind: "publish", incident: i })}>Show on status page</button>)}
              </span>
              {open[i.id] && <IncidentTimeline incident={i} busy={busy} post={{ ...NO_POST, ...posts[i.id] }}
                onDraft={(patch) => setPost(i.id, patch)} onPost={() => postUpdate(i)} />}
            </div>
            {i.status === "open" && (
              <div className="inc-resolve">
                <input className="owner-input" placeholder="What fixed it (optional)" value={notes[i.id] ?? ""} maxLength={500}
                  onChange={(e) => setNotes({ ...notes, [i.id]: e.target.value })} aria-label="Resolution note" />
                <button type="button" className="owner-secondary-button inc-sm" disabled={busy} onClick={() => setDialog({ kind: "resolve", incident: i })}>Resolve</button>
              </div>
            )}
          </li>
        ))}
      </ul>
      {data && data.length > 0 && (
        <div className="inc-foot">
          <span>{list.more ? `Showing the newest ${data.length.toLocaleString()}` : `${data.length.toLocaleString()} shown`}{openCount ? `, ${openCount} open` : ""}</span>
          {list.more && <button type="button" className="owner-secondary-button inc-sm" disabled={loading} onClick={() => reload(true)}>{loading ? "Loading…" : "Load more"}</button>}
        </div>
      )}

      {dialog?.kind === "open" && (
        <IncidentDialog title={dialog.similar ? "This looks like an incident that's already open" : "Open this incident?"} confirmLabel={dialog.similar ? "Open anyway" : "Open incident"}
          onClose={() => setDialog(null)} onConfirm={() => openIncident(Boolean(dialog.similar))}>
          {dialog.similar ? (
            <>
              <p>Already open:</p>
              <ul>{dialog.similar.map((x) => <li key={x.id}>{x.title} (opened {formatDateTime(x.created_at)})</li>)}</ul>
              <p>Post an update on it instead, or open a new one only if this is a different problem. Every active business owner is notified.</p>
            </>
          ) : <p>“{form.title}”. Every active business owner is notified now.</p>}
        </IncidentDialog>
      )}
      {dialog?.kind === "publish" && (
        <IncidentDialog title="Show on the public status page?" icon="public" confirmLabel="Show on status page" onClose={() => setDialog(null)}
          field={{ label: "What the status page says", min: 10, max: 500, placeholder: "For example: Some text messages are delayed. We are working on it.", tooShort: "Write at least 10 characters for the public status page." }}
          onConfirm={(message) => publish(dialog.incident, true, message)}>
          <p>Anyone can read this. Write it for the public, with no internal details.</p>
          <label className="owner-field ao-reason">
            <span>Affected part</span>
            <select className="owner-input" value={parts[dialog.incident.id] ?? dialog.incident.component ?? ""} onChange={(e) => setParts({ ...parts, [dialog.incident.id]: e.target.value })} aria-label="Affected part">
              {STATUS_PARTS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
            </select>
          </label>
        </IncidentDialog>
      )}
      {dialog?.kind === "resolve" && (
        <IncidentDialog title={`Resolve “${dialog.incident.title}”?`} icon="task_alt" confirmLabel="Resolve" onClose={() => setDialog(null)} onConfirm={() => resolve(dialog.incident)}>
          <p>Every active business owner is told it's fixed.</p>
        </IncidentDialog>
      )}
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
