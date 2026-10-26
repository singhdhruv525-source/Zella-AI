import { useCallback, useEffect, useMemo, useState } from "react";
import { createPortal } from "react-dom";
import { supabase } from "./supabase";
import { Field, Icon, Modal, Pill, personName } from "./BusinessUI";
import { Empty, Notice, PageHead, friendly, loadPeople, orThrow } from "./BusinessShared";
import { formatDay, formatTime, timeAgo } from "./businessTime";
import { useRoster } from "./BusinessLeads";

// Spam protection: one inbox for suspicious calls, texts, emails and bookings, with the reasons each was flagged,
// review decisions, block and allow lists, and this business's settings. Everything is read with the member's own
// session (row level security: owners, admins and managers of this business only) and changed through functions
// that check the role again in the database. Message bodies, transcripts and recordings are never copied into
// incidents; the details panel reads them from their own records, under those records' access rules.

const PAGE = 25;
const RANGES = [["1", "Today"], ["7", "7 days"], ["30", "30 days"], ["90", "90 days"]];
const CHANNELS = { call: ["call", "Call"], sms: ["sms", "Text"], email: ["mail", "Email"], booking: ["event", "Booking"], web: ["language", "Web"], other: ["help", "Other"] };
const STATUS = {
  new: ["warning", "New"], under_review: ["info", "Under review"], confirmed_spam: ["danger", "Confirmed spam"],
  false_positive: ["success", "Not spam"], resolved: ["neutral", "Resolved"], escalated: ["danger", "Escalated"],
};
const RISK = { high: ["danger", "High"], medium: ["warning", "Medium"], low: ["neutral", "Low"] };
const ACTION = { allowed: "Allowed", flagged: "Flagged for review", held: "Held for the team to confirm", screened: "Screened by the AI", restricted: "Temporarily restricted", blocked: "Blocked" };
const EVENT = { detected: "Detected", occurrence: "Happened again", status: "Status changed", note: "Note", listed: "Added to a list", unlisted: "Removed from a list", assigned: "Assigned", notified: "Team notified" };
const ref = (id) => `#${String(id).slice(0, 8).toUpperCase()}`;
const sinceDays = (days) => { const d = new Date(); d.setHours(0, 0, 0, 0); d.setDate(d.getDate() - (Number(days) - 1)); return d; };
const missingFn = (e) => e && (e.code === "PGRST202" || e.code === "PGRST205" || e.code === "42P01" || /could not find|does not exist/i.test(e.message ?? ""));

export default function SpamPage({ workspace, onNotice, onOpenPerson }) {
  const [tab, setTab] = useState("inbox");
  const [range, setRange] = useState("7");
  const [overview, setOverview] = useState({ loading: true });
  const [setup, setSetup] = useState(null);
  const from = useMemo(() => sinceDays(range), [range]);

  const loadOverview = useCallback(async () => {
    setOverview((o) => ({ ...o, loading: true }));
    const [ov, st] = await Promise.all([
      supabase.rpc("zella_spam_overview", { p_business_id: workspace.id, p_from: from.toISOString(), p_to: new Date(Date.now() + 60000).toISOString() }),
      supabase.rpc("zella_spam_settings_get", { p_business_id: workspace.id }),
    ]);
    setSetup(st.error ? null : st.data);
    if (ov.error) setOverview({ loading: false, missing: missingFn(ov.error), error: missingFn(ov.error) ? "" : friendly(ov.error) });
    else setOverview({ loading: false, data: ov.data });
  }, [workspace.id, from]);

  useEffect(() => { loadOverview(); }, [loadOverview]);

  if (overview.missing) {
    return (
      <>
        <PageHead crumb="Calls & Messages / Spam protection" title="Spam protection" />
        <Empty icon="gpp_maybe" title="Spam protection isn't set up yet">The Zella team needs to apply its latest database update. Nothing is being missed: until then, calls, texts and emails work as usual.</Empty>
      </>
    );
  }

  return (
    <>
      <PageHead crumb="Calls & Messages / Spam protection" title="Spam protection" sub="Suspicious calls, texts, emails and bookings in one place, with why each was flagged.">
        <div className="ba-segment" role="group" aria-label="Date range">
          {RANGES.map(([v, label]) => <button key={v} type="button" className={range === v ? "active" : ""} aria-pressed={range === v} onClick={() => setRange(v)}>{label}</button>)}
        </div>
      </PageHead>
      <Notice error={overview.error} onRetry={loadOverview} />
      <Overview data={overview.data} loading={overview.loading} channels={setup?.channels} />

      <div className="td-tabs sp-tabs" role="tablist" aria-label="Spam protection sections">
        {[["inbox", "Inbox"], ["lists", "Block and allow lists"], ["settings", "Settings"]].map(([k, label]) => (
          <button key={k} type="button" role="tab" aria-selected={tab === k} className={tab === k ? "active" : ""} onClick={() => setTab(k)}>{label}</button>
        ))}
      </div>
      {tab === "inbox" && <Inbox workspace={workspace} from={from} onChanged={loadOverview} onNotice={onNotice} onOpenPerson={onOpenPerson} />}
      {tab === "lists" && <Lists workspace={workspace} onNotice={onNotice} />}
      {tab === "settings" && <Settings workspace={workspace} setup={setup} onSaved={(d) => { setSetup(d); onNotice("Spam protection settings saved."); }} />}
    </>
  );
}

function Overview({ data, loading, channels }) {
  const v = (k) => (loading && !data ? "…" : data?.[k] ?? 0);
  const ch = data?.by_channel ?? {};
  const cmp = data && data.previous_total !== null && data.previous_total !== undefined
    ? data.total === data.previous_total ? "Same as the previous period"
      : `${data.total > data.previous_total ? "Up" : "Down"} from ${data.previous_total} before`
    : null;
  const tiles = [
    ["gpp_maybe", "rose", "Incidents", v("total"), cmp],
    ["pending_actions", "amber", "To review", v("unreviewed"), data ? `${data.new} new` : null],
    ["report", "rose", "Confirmed spam", v("confirmed"), null],
    ["verified", "green", "Not spam", v("false_positive"), null],
    ["block", "", "Blocked or screened", v("blocked"), data?.held ? `${data.held} bookings held` : null],
  ];
  const max = Math.max(1, ...(data?.daily ?? []).map((d) => d.count));
  return (
    <>
      <div className="td-kpis sp-kpis">
        {tiles.map(([icon, tone, label, value, sub]) => (
          <div key={label} className="ba-kpi td-kpi">
            <span className={`ba-kpi-icon ${tone}`}><Icon name={icon} /></span>
            <div className="td-kpi-body">
              <span className="td-kpi-label">{label}</span>
              <div className="td-kpi-row"><span className="ba-kpi-value">{value}</span>{sub && <span className="td-trend">{sub}</span>}</div>
            </div>
          </div>
        ))}
      </div>
      <div className="sp-strip">
        <div className="ba-panel sp-channels">
          <h3>By channel</h3>
          <ul>
            {["call", "sms", "email", "booking"].map((k) => (
              <li key={k} className={channels && channels[k] === false ? "off" : ""}>
                <Icon name={CHANNELS[k][0]} size="sm" />
                <span>{CHANNELS[k][1]}{k === "booking" ? "s" : k === "sms" ? "s" : k === "email" ? "s" : "s"}</span>
                {channels && channels[k] === false ? <small>Not connected</small> : <strong>{loading && !data ? "…" : ch[k] ?? 0}</strong>}
              </li>
            ))}
            {(ch.other ?? 0) > 0 && <li><Icon name="help" size="sm" /><span>Other</span><strong>{ch.other}</strong></li>}
          </ul>
        </div>
        <div className="ba-panel sp-chart" aria-label="Incidents per day">
          <h3>Incidents per day</h3>
          {data?.daily?.length ? (
            <div className="sp-bars">
              {data.daily.map((d) => (
                <div key={d.day} className="sp-bar" title={`${d.day}: ${d.count}`}>
                  <span style={{ height: `${Math.max(6, (d.count / max) * 100)}%` }} />
                  <small>{d.day.slice(5)}</small>
                </div>
              ))}
            </div>
          ) : <p className="ba-muted sp-quiet">{loading ? "Loading…" : "No suspicious activity in this period."}</p>}
        </div>
      </div>
    </>
  );
}

function Inbox({ workspace, from, onChanged, onNotice, onOpenPerson }) {
  const [filters, setFilters] = useState({ q: "", channel: "", risk: "", status: "open", sort: "recent" });
  const [page, setPage] = useState(0);
  const [state, setState] = useState({ loading: true, rows: [], total: 0 });
  const [people, setPeople] = useState({});
  const [picked, setPicked] = useState([]);
  const [open, setOpen] = useState(null);
  const [busy, setBusy] = useState(false);
  const roster = useRoster(workspace);
  const set = (k) => (e) => { setFilters({ ...filters, [k]: e.target.value }); setPage(0); setPicked([]); };

  const load = useCallback(async () => {
    setState((s) => ({ ...s, loading: true, error: "" }));
    let q = supabase.from("spam_incidents").select("*", { count: "exact" }).eq("business_id", workspace.id).gte("last_seen_at", from.toISOString());
    if (filters.channel) q = q.eq("channel", filters.channel);
    if (filters.risk) q = q.eq("risk_level", filters.risk);
    if (filters.status === "open") q = q.in("status", ["new", "under_review", "escalated"]);
    else if (filters.status) q = q.eq("status", filters.status);
    const term = filters.q.trim().replace(/[%,()]/g, "");
    if (term) q = q.or(`sender.ilike.%${term.replace(/\D/g, "") || term}%,sender_display.ilike.%${term}%`);
    q = filters.sort === "risk" ? q.order("risk_score", { ascending: false }).order("last_seen_at", { ascending: false }) : q.order("last_seen_at", { ascending: false });
    const res = await q.range(page * PAGE, page * PAGE + PAGE - 1);
    if (res.error) { setState({ loading: false, rows: [], total: 0, error: friendly(res.error) }); return; }
    setState({ loading: false, rows: res.data ?? [], total: res.count ?? 0 });
    try { setPeople(await loadPeople((res.data ?? []).map((r) => r.customer_id))); } catch { setPeople({}); }
  }, [workspace.id, from, filters, page]);

  useEffect(() => { load(); }, [load]);

  async function bulk(status) {
    setBusy(true);
    let done = 0;
    for (const id of picked) {
      const { error } = await supabase.rpc("zella_spam_review", { p_incident_id: id, p_status: status, p_note: null, p_block: false });
      if (error) { onNotice(friendly(error)); break; }
      done += 1;
    }
    setBusy(false);
    setPicked([]);
    if (done) onNotice(`${done} incident${done === 1 ? "" : "s"} marked ${STATUS[status][1].toLowerCase()}.`);
    load(); onChanged();
  }

  const pages = Math.max(1, Math.ceil(state.total / PAGE));
  const allOnPage = state.rows.length > 0 && state.rows.every((r) => picked.includes(r.id));

  return (
    <section className="ba-panel sp-inbox">
      <div className="sp-filters">
        <label className="ba-search"><Icon name="search" size="sm" /><input value={filters.q} onChange={set("q")} placeholder="Search number or address" aria-label="Search incidents" /></label>
        <select value={filters.channel} onChange={set("channel")} aria-label="Channel"><option value="">All channels</option>{Object.entries(CHANNELS).map(([k, [, l]]) => <option key={k} value={k}>{l}</option>)}</select>
        <select value={filters.risk} onChange={set("risk")} aria-label="Risk"><option value="">Any risk</option><option value="high">High</option><option value="medium">Medium</option><option value="low">Low</option></select>
        <select value={filters.status} onChange={set("status")} aria-label="Status"><option value="open">Needs attention</option><option value="">Any status</option>{Object.entries(STATUS).map(([k, [, l]]) => <option key={k} value={k}>{l}</option>)}</select>
        <select value={filters.sort} onChange={set("sort")} aria-label="Sort"><option value="recent">Most recent</option><option value="risk">Highest risk</option></select>
      </div>

      {picked.length > 0 && (
        <div className="sp-bulk" role="region" aria-label="Bulk actions">
          <strong>{picked.length} selected</strong>
          <button type="button" className="ba-btn sm" disabled={busy} onClick={() => bulk("under_review")}>Mark under review</button>
          <button type="button" className="ba-btn sm" disabled={busy} onClick={() => bulk("resolved")}>Resolve</button>
          <button type="button" className="ba-btn sm" disabled={busy} onClick={() => bulk("false_positive")}>Not spam</button>
          <button type="button" className="ba-link" onClick={() => setPicked([])}>Clear</button>
        </div>
      )}

      <Notice error={state.error} onRetry={load} />
      {state.rows.length ? (
        <div className="ba-table-wrap">
          <table className="ba-table sp-table">
            <thead><tr>
              <th className="sp-check"><input type="checkbox" aria-label="Select all on this page" checked={allOnPage} onChange={(e) => setPicked(e.target.checked ? state.rows.map((r) => r.id) : [])} /></th>
              <th>Incident</th><th>From</th><th>Risk</th><th>Why</th><th>Status</th><th>Last seen</th>
            </tr></thead>
            <tbody>
              {state.rows.map((r) => {
                const person = people[r.customer_id];
                return (
                  <tr key={r.id} className="sp-row" onClick={() => setOpen(r)}>
                    <td className="sp-check" onClick={(e) => e.stopPropagation()}>
                      <input type="checkbox" aria-label={`Select ${ref(r.id)}`} checked={picked.includes(r.id)} onChange={(e) => setPicked(e.target.checked ? [...picked, r.id] : picked.filter((x) => x !== r.id))} />
                    </td>
                    <td><span className="sp-chan"><Icon name={CHANNELS[r.channel]?.[0] ?? "help"} size="sm" />{CHANNELS[r.channel]?.[1] ?? r.channel}</span><small className="ba-muted sp-ref">{ref(r.id)}</small></td>
                    <td><strong>{person ? personName(person) : r.sender_display || r.sender}</strong>{person && <small className="ba-muted sp-ref">{r.sender_display || r.sender}</small>}</td>
                    <td><Pill tone={RISK[r.risk_level][0]}>{RISK[r.risk_level][1]} · {r.risk_score}</Pill></td>
                    <td className="sp-why">{(r.reasons ?? []).slice(0, 2).map((x) => x.label).join("; ") || "—"}{r.occurrences > 1 && <small className="ba-muted"> ×{r.occurrences}</small>}</td>
                    <td><Pill tone={STATUS[r.status][0]}>{STATUS[r.status][1]}</Pill></td>
                    <td>{timeAgo(r.last_seen_at)}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      ) : !state.loading && (
        <Empty icon="verified_user" title={filters.status === "open" && !filters.q && !filters.channel && !filters.risk ? "Nothing needs attention" : "No incidents match"}>
          {filters.status === "open" ? "Suspicious calls, texts, emails and bookings show up here when Zella flags them." : "Try another filter or a longer date range."}
        </Empty>
      )}
      {state.loading && !state.rows.length && <p className="ba-muted sp-quiet">Loading incidents…</p>}
      {state.total > PAGE && (
        <div className="sp-pager">
          <span className="ba-muted">{page * PAGE + 1}–{Math.min(state.total, page * PAGE + PAGE)} of {state.total}</span>
          <button type="button" className="ba-btn sm" disabled={page === 0} onClick={() => setPage(page - 1)}>Previous</button>
          <button type="button" className="ba-btn sm" disabled={page + 1 >= pages} onClick={() => setPage(page + 1)}>Next</button>
        </div>
      )}

      {open && (
        <IncidentPanel workspace={workspace} incident={open} person={people[open.customer_id]} roster={roster}
          onClose={() => setOpen(null)} onChanged={() => { load(); onChanged(); }} onNotice={onNotice} onOpenPerson={onOpenPerson} />
      )}
    </section>
  );
}

// What the source record itself says, read under that record's own access rules.
function useSource(incident) {
  const [src, setSrc] = useState({ loading: true });
  useEffect(() => {
    let live = true;
    const id = incident.last_source_id;
    const table = incident.last_source_table;
    const q = {
      calls: () => supabase.from("calls_view").select("id, started_at, duration_seconds, status, outcome, ai_handled, summary, recording_url, transcript").eq("id", id).maybeSingle(),
      sms_messages: () => supabase.from("sms_messages").select("id, from_number, to_number, message_body, status, created_at, delivered_at").eq("id", id).maybeSingle(),
      email_messages: () => supabase.from("email_messages").select("id, from_email, to_email, subject, body_text, status, created_at").eq("id", id).maybeSingle(),
      appointments: () => supabase.from("appointments").select("id, title, start_time, end_time, status, booking_state, created_at, metadata").eq("id", id).maybeSingle(),
    }[table];
    if (!id || !q) { setSrc({ loading: false, none: true }); return undefined; }
    q().then(({ data, error }) => live && setSrc({ loading: false, data, error: error ? friendly(error) : "", table }));
    return () => { live = false; };
  }, [incident.last_source_id, incident.last_source_table]);
  return src;
}

function IncidentPanel({ workspace, incident, person, roster, onClose, onChanged, onNotice, onOpenPerson }) {
  const [inc, setInc] = useState(incident);
  const [events, setEvents] = useState([]);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [confirming, setConfirming] = useState(null);
  const [listed, setListed] = useState(null);
  const src = useSource(inc);
  const canBlock = inc.sender && inc.sender !== "unknown";
  const listChannel = ["call", "sms", "email", "booking"].includes(inc.channel) ? inc.channel : "all";

  const reload = useCallback(async () => {
    const [i, e, l] = await Promise.all([
      supabase.from("spam_incidents").select("*").eq("id", incident.id).maybeSingle(),
      supabase.from("spam_incident_events").select("*").eq("incident_id", incident.id).order("created_at", { ascending: false }).limit(100),
      supabase.from("spam_list_entries").select("id, list, channel, source, expires_at").eq("business_id", workspace.id).eq("value", incident.sender).is("removed_at", null),
    ]);
    if (i.data) setInc(i.data);
    setEvents(e.data ?? []);
    setListed((l.data ?? []).find((x) => (x.channel === listChannel || x.channel === "all") && (!x.expires_at || new Date(x.expires_at) > new Date())) ?? null);
  }, [incident.id, incident.sender, workspace.id, listChannel]);

  useEffect(() => { reload(); }, [reload]);
  useEffect(() => {
    const onKey = (e) => { if (e.key === "Escape" && !busy && !confirming) onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [busy, confirming, onClose]);

  async function act(fn, message) {
    setBusy(true);
    const { error } = await fn();
    setBusy(false);
    if (error) { onNotice(friendly(error)); return false; }
    if (message) onNotice(message);
    await reload();
    onChanged();
    return true;
  }
  const review = (status, block = false, text = null) => act(() => supabase.rpc("zella_spam_review", { p_incident_id: inc.id, p_status: status, p_note: text, p_block: block }),
    `${ref(inc.id)} marked ${STATUS[status][1].toLowerCase()}${block ? " and the sender blocked" : ""}.`);

  const box = (
    <div className="bp-backdrop" onMouseDown={(e) => e.target === e.currentTarget && !busy && !confirming && onClose()}>
      <aside className="bp-panel" role="dialog" aria-modal="true" aria-label={`Incident ${ref(inc.id)}`} tabIndex={-1}>
        <header className="bp-head">
          <div>
            <small><Icon name={CHANNELS[inc.channel]?.[0] ?? "help"} size="sm" /> {CHANNELS[inc.channel]?.[1]} incident {ref(inc.id)}</small>
            <h2>{person ? personName(person) : inc.sender_display || inc.sender}</h2>
            <p>First {formatDay(inc.first_seen_at, workspace.timezone)} {formatTime(inc.first_seen_at, workspace.timezone)} · last {timeAgo(inc.last_seen_at)}{inc.occurrences > 1 ? ` · ${inc.occurrences} times` : ""}</p>
          </div>
          <button type="button" className="ba-btn ghost sm" onClick={onClose} aria-label="Close"><Icon name="close" size="sm" /></button>
        </header>

        <div className="bp-body">
          <section className="bp-section">
            <h3>Why it was flagged</h3>
            <div className="sp-badges">
              <Pill tone={RISK[inc.risk_level][0]}>{RISK[inc.risk_level][1]} risk · {inc.risk_score}</Pill>
              <Pill tone={STATUS[inc.status][0]}>{STATUS[inc.status][1]}</Pill>
              <Pill>{ACTION[inc.action]}</Pill>
              {listed && <Pill tone={listed.list === "block" ? "danger" : "success"}>{listed.list === "block" ? `Blocked for ${listed.channel === "all" ? "all channels" : CHANNELS[listed.channel]?.[1].toLowerCase()}` : "Allowed"}{listed.expires_at ? ` until ${formatDay(listed.expires_at, workspace.timezone)}` : ""}</Pill>}
            </div>
            <ul className="sp-reasons">
              {(inc.reasons ?? []).map((r) => <li key={r.code}><span>{r.label}</span><small>+{r.points}</small></li>)}
            </ul>
            <p className="ba-muted sp-small">Caller ID and sender addresses can be faked, so a number or address alone is never treated as proof.</p>
          </section>

          <section className="bp-section">
            <h3>Who</h3>
            <dl className="bp-rows">
              <div className="bp-row"><dt>{inc.channel === "email" ? "Address" : "Number"}</dt><dd>{inc.sender_display || inc.sender}</dd></div>
              <div className="bp-row"><dt>Customer</dt><dd>{person ? <button type="button" className="ba-namebtn" onClick={() => onOpenPerson(person.id)}>{personName(person)}</button> : "Not a saved customer"}</dd></div>
              <div className="bp-row"><dt>Reviewer</dt><dd>
                <select value={inc.assigned_to ?? ""} disabled={busy} aria-label="Reviewer"
                  onChange={(e) => act(() => supabase.rpc("zella_spam_assign", { p_incident_id: inc.id, p_user_id: e.target.value || null }), "Reviewer updated.")}>
                  <option value="">Unassigned</option>
                  {roster.list.map((m) => <option key={m.user_id} value={m.user_id}>{m.name}</option>)}
                </select>
              </dd></div>
            </dl>
          </section>

          <section className="bp-section">
            <h3>{inc.channel === "call" ? "The call" : inc.channel === "sms" ? "The text" : inc.channel === "email" ? "The email" : inc.channel === "booking" ? "The booking" : "Source"}{inc.occurrences > 1 ? " (most recent)" : ""}</h3>
            <SourceDetails src={src} tz={workspace.timezone} />
          </section>

          <section className="bp-section">
            <h3>History</h3>
            <ul className="bp-feed">
              {events.map((e) => (
                <li key={e.id}>
                  <Icon name={e.kind === "note" ? "sticky_note_2" : e.kind === "status" ? "swap_horiz" : e.kind === "listed" || e.kind === "unlisted" ? "block" : "history"} size="sm" />
                  <span>
                    {EVENT[e.kind] ?? e.kind}
                    {e.kind === "status" && `: ${STATUS[e.from_status]?.[1] ?? e.from_status} → ${STATUS[e.to_status]?.[1] ?? e.to_status}`}
                    {(e.kind === "listed" || e.kind === "unlisted") && e.detail?.list && `: ${e.detail.list} (${e.detail.channel}${e.detail.temporary_hours ? `, ${e.detail.temporary_hours} h` : ""})`}
                    {e.actor && ` · ${roster.nameOf[e.actor] ?? "Team member"}`}
                    {e.note && <em className="sp-note">{e.note}</em>}
                  </span>
                  <time>{timeAgo(e.created_at)}</time>
                </li>
              ))}
            </ul>
            <div className="sp-add-note">
              <textarea rows={2} maxLength={1000} value={note} onChange={(e) => setNote(e.target.value)} placeholder="Add an internal note" aria-label="Internal note" />
              <button type="button" className="ba-btn sm" disabled={busy || !note.trim()} onClick={() => act(() => supabase.rpc("zella_spam_note", { p_incident_id: inc.id, p_note: note }), "Note added.").then((ok) => ok && setNote(""))}>Add note</button>
            </div>
          </section>
        </div>

        <footer className="bp-foot">
          {inc.status !== "under_review" && <button type="button" className="ba-btn" disabled={busy} onClick={() => review("under_review")}><Icon name="visibility" size="sm" />Under review</button>}
          {inc.status !== "confirmed_spam" && <button type="button" className="ba-btn danger-outline" disabled={busy} onClick={() => setConfirming("confirm")}><Icon name="report" size="sm" />Confirm spam</button>}
          {inc.status !== "false_positive" && <button type="button" className="ba-btn" disabled={busy} onClick={() => review("false_positive")}><Icon name="verified" size="sm" />Not spam</button>}
          {inc.status !== "escalated" && <button type="button" className="ba-btn" disabled={busy} onClick={() => review("escalated")}><Icon name="priority_high" size="sm" />Escalate</button>}
          {inc.status !== "resolved" && <button type="button" className="ba-btn primary" disabled={busy} onClick={() => review("resolved")}><Icon name="task_alt" size="sm" />Resolve</button>}
          {canBlock && (listed?.list === "block"
            ? <button type="button" className="ba-btn" disabled={busy} onClick={() => setConfirming("unblock")}><Icon name="lock_open" size="sm" />Unblock</button>
            : <button type="button" className="ba-btn danger-outline" disabled={busy} onClick={() => setConfirming("block")}><Icon name="block" size="sm" />Block sender</button>)}
        </footer>
      </aside>
    </div>
  );

  const host = typeof document !== "undefined" ? document.querySelector(".ba-root") : null;
  return (
    <>
      {host ? createPortal(box, host) : box}
      {confirming === "confirm" && (
        <ConfirmBox title="Confirm this is spam?" icon="report" tone="danger" busy={busy} onClose={() => setConfirming(null)}
          text={`The incident is marked confirmed spam.${canBlock ? ` You can also block ${inc.sender_display || inc.sender} for ${CHANNELS[inc.channel]?.[1].toLowerCase() ?? "this channel"} only; other channels aren't affected.` : ""}`}
          actions={[
            canBlock && ["Confirm and block", "danger", () => review("confirmed_spam", true).then(() => setConfirming(null))],
            ["Confirm only", "", () => review("confirmed_spam").then(() => setConfirming(null))],
          ].filter(Boolean)} />
      )}
      {confirming === "block" && (
        <ConfirmBox title={`Block ${inc.sender_display || inc.sender}?`} icon="block" tone="danger" busy={busy} onClose={() => setConfirming(null)}
          text={`Blocked for ${listChannel === "all" ? "every channel" : CHANNELS[listChannel][1].toLowerCase() + "s only"}. Their ${listChannel === "call" ? "calls are ended politely by the AI" : listChannel === "booking" ? "bookings wait for the team to confirm" : "messages are flagged and get no automatic replies"}. You can unblock at any time.`}
          actions={[["Block", "danger", () => act(() => supabase.rpc("zella_spam_list_add", { p_business_id: workspace.id, p_list: "block", p_channel: listChannel, p_value: inc.sender, p_reason: `From incident ${ref(inc.id)}`, p_hours: null, p_incident_id: inc.id }), "Sender blocked.").then(() => setConfirming(null))]]} />
      )}
      {confirming === "unblock" && (
        <ConfirmBox title={`Unblock ${inc.sender_display || inc.sender}?`} icon="lock_open" busy={busy} onClose={() => setConfirming(null)}
          text={listed?.source === "auto" ? "This was an automatic temporary restriction." : "They'll be treated like any other sender again."}
          actions={[["Unblock", "", () => act(() => supabase.rpc("zella_spam_list_remove", { p_entry_id: listed.id }), "Sender unblocked.").then(() => setConfirming(null))]]} />
      )}
    </>
  );
}

function SourceDetails({ src, tz }) {
  if (src.loading) return <p className="ba-muted">Loading…</p>;
  if (src.none) return <p className="ba-muted">No source record is linked to this incident.</p>;
  if (src.error) return <p className="ba-muted">Couldn't load it: {src.error}</p>;
  const d = src.data;
  if (!d) return <p className="ba-muted">Not available: it was removed, or your access doesn't include it.</p>;
  const when = (v) => (v ? `${formatDay(v, tz)}, ${formatTime(v, tz)}` : "—");
  const rows = {
    calls: [["When", when(d.started_at)], ["Length", d.duration_seconds ? `${Math.round(d.duration_seconds / 60)} min ${d.duration_seconds % 60} s` : "—"],
      ["Outcome", d.outcome || d.status || "—"], ["Answered by", d.ai_handled ? "AI receptionist" : "Team"], ["Summary", d.summary || "—"]],
    sms_messages: [["From", d.from_number], ["To", d.to_number], ["When", when(d.created_at)], ["Delivery", d.status || "—"]],
    email_messages: [["From", d.from_email], ["To", d.to_email], ["Subject", d.subject || "(no subject)"], ["When", when(d.created_at)]],
    appointments: [["Requested", d.title], ["For", when(d.start_time)], ["Booked", when(d.created_at)], ["State", d.booking_state === "requested" ? "Waiting for the team to confirm" : d.status]],
  }[src.table];
  const body = src.table === "sms_messages" ? d.message_body : src.table === "email_messages" ? (d.body_text ?? "").slice(0, 2000) : null;
  return (
    <>
      <dl className="bp-rows">{rows.map(([k, v]) => <div key={k} className="bp-row"><dt>{k}</dt><dd>{v}</dd></div>)}</dl>
      {body && <p className="ba-note pre sp-body">{body}</p>}
      {src.table === "calls" && (d.recording_url || d.transcript) && (
        <p className="sp-small">
          {d.recording_url && <a className="ba-link" href={d.recording_url} target="_blank" rel="noopener noreferrer">Recording</a>}
          {d.recording_url && d.transcript && " · "}
          {d.transcript && <span>Transcript available in Calls</span>}
        </p>
      )}
      {src.table === "appointments" && d.metadata?.spam_hold && <p className="ba-muted sp-small">Kept as a request because of the reasons above. Confirm it from the calendar if it's genuine.</p>}
    </>
  );
}

function ConfirmBox({ title, text, icon, tone, actions, busy, onClose }) {
  return (
    <Modal title={title} icon={icon} tone={tone} onClose={onClose} busy={busy}
      footer={<>
        <button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button>
        {actions.map(([label, kind, run]) => <button key={label} type="button" className={`ba-btn ${kind === "danger" ? "danger" : "primary"}`} disabled={busy} onClick={run}>{label}</button>)}
      </>}>
      <div className="ba-modal-body"><p className="sp-small">{text}</p></div>
    </Modal>
  );
}

const LIST_CHANNELS = [["call", "Calls"], ["sms", "Texts"], ["email", "Emails"], ["booking", "Bookings"], ["all", "All channels"]];
const DURATIONS = [["", "Until removed"], ["24", "24 hours"], ["168", "7 days"], ["720", "30 days"]];

function Lists({ workspace, onNotice }) {
  const [rows, setRows] = useState(null);
  const [error, setError] = useState("");
  const [form, setForm] = useState({ list: "block", channel: "call", value: "", reason: "", hours: "" });
  const [busy, setBusy] = useState(false);
  const [removing, setRemoving] = useState(null);

  const load = useCallback(async () => {
    try {
      setRows(orThrow(await supabase.from("spam_list_entries").select("*").eq("business_id", workspace.id).is("removed_at", null).order("created_at", { ascending: false }).limit(500)));
      setError("");
    } catch (e) { setError(friendly(e)); }
  }, [workspace.id]);
  useEffect(() => { load(); }, [load]);

  async function add(e) {
    e.preventDefault();
    setBusy(true);
    const { error: err } = await supabase.rpc("zella_spam_list_add", { p_business_id: workspace.id, p_list: form.list, p_channel: form.channel, p_value: form.value, p_reason: form.reason || null, p_hours: form.hours ? Number(form.hours) : null, p_incident_id: null });
    setBusy(false);
    if (err) {
      onNotice(/BAD_VALUE/.test(err.message) ? "Enter a phone number, an email address or a domain like example.com."
        : /CHANNEL_MISMATCH/.test(err.message) ? "Phone numbers go with calls or texts, and addresses with email." : friendly(err));
      return;
    }
    onNotice(form.list === "block" ? "Added to the block list." : "Added to the allow list.");
    setForm({ ...form, value: "", reason: "" });
    load();
  }

  const live = (rows ?? []).filter((r) => !r.expires_at || new Date(r.expires_at) > new Date());
  return (
    <section className="ba-panel sp-lists">
      <form className="sp-list-form" onSubmit={add}>
        <Field label="List"><select value={form.list} onChange={(e) => setForm({ ...form, list: e.target.value })}><option value="block">Block</option><option value="allow">Allow (never flag)</option></select></Field>
        <Field label="Channel"><select value={form.channel} onChange={(e) => setForm({ ...form, channel: e.target.value })}>{LIST_CHANNELS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></Field>
        <Field label="Number, email or domain"><input value={form.value} placeholder="+1 555 0100, name@x.com or x.com" required
          onChange={(e) => {
            const value = e.target.value;
            const looksAddress = /@|^[^\d\s+()-]+\.[a-z]{2,}$/i.test(value.trim());
            // Keep the channel sensible for what's typed: addresses go with email, numbers with calls.
            const channel = looksAddress && ["call", "sms"].includes(form.channel) ? "email" : !looksAddress && form.channel === "email" && /\d{3}/.test(value) ? "call" : form.channel;
            setForm({ ...form, value, channel });
          }} /></Field>
        <Field label="For how long"><select value={form.hours} onChange={(e) => setForm({ ...form, hours: e.target.value })}>{DURATIONS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></Field>
        <Field label="Reason (optional)"><input value={form.reason} maxLength={300} onChange={(e) => setForm({ ...form, reason: e.target.value })} /></Field>
        <button type="submit" className="ba-btn primary" disabled={busy || !form.value.trim()}><Icon name="add" size="sm" />Add</button>
      </form>
      <p className="ba-muted sp-small">Blocking is per channel: blocking a number for texts doesn't block its calls unless you choose all channels. Zella's own platform rules also apply and aren't listed here.</p>
      <Notice error={error} onRetry={load} />
      {live.length ? (
        <div className="ba-table-wrap">
          <table className="ba-table static">
            <thead><tr><th>List</th><th>Sender</th><th>Channel</th><th>Added</th><th>Until</th><th>Reason</th><th><span className="ba-sr">Actions</span></th></tr></thead>
            <tbody>
              {live.map((r) => (
                <tr key={r.id}>
                  <td><Pill tone={r.list === "block" ? "danger" : "success"}>{r.list === "block" ? "Blocked" : "Allowed"}</Pill></td>
                  <td>{r.value}</td>
                  <td>{LIST_CHANNELS.find(([k]) => k === r.channel)?.[1] ?? r.channel}</td>
                  <td>{timeAgo(r.created_at)}{r.source !== "manual" && <small className="ba-muted"> · {r.source === "auto" ? "automatic" : "from an incident"}</small>}</td>
                  <td>{r.expires_at ? formatDay(r.expires_at, workspace.timezone) : "Until removed"}</td>
                  <td>{r.reason || "—"}</td>
                  <td><button type="button" className="ba-btn sm" onClick={() => setRemoving(r)}>Remove</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : rows && <Empty icon="list_alt" title="No list entries">Block a sender here or from an incident. Allowed senders are never flagged by this business's checks.</Empty>}
      {removing && (
        <ConfirmBox title={`Remove ${removing.value}?`} icon="playlist_remove" busy={busy} onClose={() => setRemoving(null)}
          text={removing.list === "block" ? "They'll be treated like any other sender again." : "They'll be checked like any other sender again."}
          actions={[["Remove", "", async () => {
            setBusy(true);
            const { error: err } = await supabase.rpc("zella_spam_list_remove", { p_entry_id: removing.id });
            setBusy(false);
            if (err) onNotice(friendly(err)); else onNotice("Removed.");
            setRemoving(null);
            load();
          }]]} />
      )}
    </section>
  );
}

function Settings({ workspace, setup, onSaved }) {
  const [form, setForm] = useState(setup?.settings ?? null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  useEffect(() => { setForm(setup?.settings ?? null); }, [setup]);
  if (!setup || !form) return <section className="ba-panel"><p className="ba-muted sp-quiet">Loading settings…</p></section>;
  const can = setup.can_edit;
  const ch = setup.channels ?? {};
  const set = (k, v) => setForm({ ...form, [k]: v });
  const num = (k, lo, hi) => (e) => set(k, Math.max(lo, Math.min(hi, Number(e.target.value) || lo)));
  const toggle = (k, label, hint, disabled) => (
    <label className={`sp-toggle ${disabled ? "off" : ""}`}>
      <input type="checkbox" checked={Boolean(form[k])} disabled={!can || disabled || busy} onChange={(e) => set(k, e.target.checked)} />
      <span><strong>{label}</strong><small>{disabled ? "Not connected for this business" : hint}</small></span>
    </label>
  );

  async function save() {
    setBusy(true);
    setError("");
    const keys = ["enabled", "call_screening", "ai_spam_handling", "repeat_call_limit", "repeat_window_minutes", "sms_monitoring", "sms_flood_limit", "email_monitoring", "email_flood_limit", "booking_protection", "booking_daily_limit", "auto_restrict", "notify_high_risk"];
    const { data, error: err } = await supabase.rpc("zella_spam_settings_save", { p_business_id: workspace.id, p_settings: Object.fromEntries(keys.map((k) => [k, form[k]])) });
    setBusy(false);
    if (err) { setError(friendly(err)); return; }
    onSaved({ ...setup, settings: data, saved: true });
  }

  return (
    <section className="ba-panel sp-settings">
      {!can && <div className="ba-banner"><span>Only owners and admins can change these settings.</span></div>}
      {error && <div className="ba-banner error">{error}</div>}
      {toggle("enabled", "Spam protection for this business", "Checks calls, texts, emails and bookings for spam. Zella's platform rules and limits always apply, even when this is off.")}
      <fieldset className="sp-group" disabled={!form.enabled}>
        <legend>Calls</legend>
        {ch.call === false ? <p className="ba-muted sp-small">Calls aren't connected for this business.</p> : (
          <div className="sp-grid">
            <Field label="High-risk callers"><select value={form.call_screening} disabled={!can} onChange={(e) => set("call_screening", e.target.value)}><option value="flag">Answer and flag for review</option><option value="screen">Screen: the AI doesn't help them</option></select></Field>
            <Field label="When screened, the AI"><select value={form.ai_spam_handling} disabled={!can} onChange={(e) => set("ai_spam_handling", e.target.value)}><option value="end_politely">Ends the call politely</option><option value="take_message">Takes a short message only</option></select></Field>
            <Field label="Flag after this many calls"><input type="number" min={2} max={50} value={form.repeat_call_limit} disabled={!can} onChange={num("repeat_call_limit", 2, 50)} /></Field>
            <Field label="Within (minutes)"><input type="number" min={5} max={1440} value={form.repeat_window_minutes} disabled={!can} onChange={num("repeat_window_minutes", 5, 1440)} /></Field>
          </div>
        )}
      </fieldset>
      <fieldset className="sp-group" disabled={!form.enabled}>
        <legend>Texts and email</legend>
        {toggle("sms_monitoring", "Watch incoming texts", "Floods, suspicious links and spam wording.", ch.sms === false)}
        {form.sms_monitoring && ch.sms !== false && <Field label="Flag after this many texts in the window"><input type="number" min={3} max={200} value={form.sms_flood_limit} disabled={!can} onChange={num("sms_flood_limit", 3, 200)} /></Field>}
        {toggle("email_monitoring", "Watch incoming email", "Floods, suspicious links and the email provider's own spam verdict.", ch.email === false)}
        {form.email_monitoring && ch.email !== false && <Field label="Flag after this many emails in the window"><input type="number" min={3} max={200} value={form.email_flood_limit} disabled={!can} onChange={num("email_flood_limit", 3, 200)} /></Field>}
      </fieldset>
      <fieldset className="sp-group" disabled={!form.enabled}>
        <legend>Bookings</legend>
        {toggle("booking_protection", "Hold suspicious bookings", "Bookings from blocked contacts, or too many from one contact in a day, wait for the team to confirm. Team bookings are never held.", ch.booking === false)}
        {form.booking_protection && ch.booking !== false && <Field label="Bookings allowed per contact per day"><input type="number" min={1} max={20} value={form.booking_daily_limit} disabled={!can} onChange={num("booking_daily_limit", 1, 20)} /></Field>}
      </fieldset>
      <fieldset className="sp-group" disabled={!form.enabled}>
        <legend>Responses and alerts</legend>
        {toggle("auto_restrict", "Temporarily restrict clear abuse", "Only with two or more signals at high risk, for 24 hours, on that channel. Never permanent; undo by marking it not spam.")}
        {toggle("notify_high_risk", "Tell the team about high-risk incidents", "A few alerts an hour at most, without message content.")}
      </fieldset>
      {can && <div className="sp-save"><button type="button" className="ba-btn primary" disabled={busy} onClick={save}>{busy ? "Saving…" : "Save settings"}</button></div>}
    </section>
  );
}
