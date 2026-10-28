import { useCallback, useEffect, useMemo, useState } from "react";
import { supabase } from "./supabase";
import { Icon, Pill, personName } from "./BusinessUI";
import { makeTerm, receptionistState } from "./businessWorkspace";
import { useRoster } from "./BusinessLeads";
import { CountUp } from "./CrmMotion";
import { formatLongDate, formatTime, greeting, timeAgo, todayInput, zonedDateTime } from "./businessTime";
import { friendly, noShowNotice, setCheckIn } from "./BusinessShared";
import { RescheduleModal } from "./BusinessForms";
import { CONNECT, todayConfig } from "./todayConfig";

// Today dashboard, built only from this business's real records, read with the member's own session so row level
// security returns this business's data only. Words follow the industry (Reservations, Patients, Technicians ...)
// and todayConfig.js decides the few industry-specific columns and cards. Where Zella has no data source yet it says
// so plainly instead of showing numbers.

const SOURCE = {
  manual: ["Team", "person"], phone: ["Phone", "call"], call: ["Phone", "call"], voice: ["AI receptionist", "smart_toy"],
  walk_in: ["Walk-in", "directions_walk"], website: ["Online", "language"], website_chat: ["Online chat", "chat"],
  google: ["Google", "travel_explore"], meta: ["Meta", "thumb_up"], referral: ["Referral", "group"], other: ["Other", "more_horiz"],
};
const PRIORITY_TONE = { urgent: "danger", high: "warning", normal: "" };

const addDays = (dateStr, n) => {
  const [y, m, d] = dateStr.split("-").map(Number);
  const t = new Date(Date.UTC(y, m - 1, d + n));
  return `${t.getUTCFullYear()}-${String(t.getUTCMonth() + 1).padStart(2, "0")}-${String(t.getUTCDate()).padStart(2, "0")}`;
};
const dayBounds = (dateStr, tz) => ({ start: zonedDateTime(dateStr, "00:00", tz), end: zonedDateTime(addDays(dateStr, 1), "00:00", tz) });
const minutes = (a) => (a.end_time ? Math.round((new Date(a.end_time) - new Date(a.start_time)) / 60000) : null);

// Where a booking is in its day. Final states first.
function stage(a, now) {
  if (a.status === "cancelled") return "cancelled";
  if (a.status === "no_show") return "no_show";
  if (a.status === "completed") return "completed";
  if (a.checked_in_at || a.arrived_at || a.in_service_at) return "arrived";
  return new Date(a.start_time).getTime() < now ? "late" : "upcoming";
}

// Change against the same day last week. upIsGood decides the colour; the words always say which way it went.
function trend(cur, prev, upIsGood = true) {
  if (cur === null || prev === null || prev === undefined) return null;
  if (prev === 0 && cur === 0) return { text: "Same as last week", tone: "" };
  if (prev === 0) return { text: "New vs last week", tone: upIsGood ? "up" : "down", arrow: "arrow_upward" };
  const pct = Math.round(((cur - prev) / prev) * 100);
  if (pct === 0) return { text: "Same as last week", tone: "" };
  const up = pct > 0;
  return { text: `${Math.abs(pct)}% vs last week`, label: `${up ? "Up" : "Down"} ${Math.abs(pct)}% vs last week`, tone: up === upIsGood ? "up" : "down", arrow: up ? "arrow_upward" : "arrow_downward" };
}

function Kpi({ icon, tone, label, value, change, loading }) {
  return (
    <div className="ba-kpi td-kpi">
      <span className={`ba-kpi-icon ${tone}`}><Icon name={icon} /></span>
      <div className="td-kpi-body">
        <span className="td-kpi-label">{label}</span>
        <div className="td-kpi-row">
          <span className="ba-kpi-value">{loading ? "…" : <CountUp value={value} />}</span>
          {change && (
            <span className={`td-trend ${change.tone}`} aria-label={change.label ?? change.text}>
              {change.arrow && <Icon name={change.arrow} size="sm" />}{change.text}
            </span>
          )}
        </div>
      </div>
    </div>
  );
}

// Spam: suspected spam incidents for the selected day, how many still need a look, and the same day last week.
// Real counts from zella_spam_overview (owners, admins and managers only); the whole card opens Spam protection.
const SPAM_ROLES = ["owner", "admin", "manager"];
function SpamKpi({ workspace, day, tz, onOpen }) {
  const [state, setState] = useState({ loading: true });
  const allowed = SPAM_ROLES.includes(workspace.role);
  useEffect(() => {
    if (!allowed) return undefined;
    let live = true;
    const cur = dayBounds(day, tz);
    const prev = dayBounds(addDays(day, -7), tz);
    const ask = (b) => supabase.rpc("zella_spam_overview", { p_business_id: workspace.id, p_from: b.start.toISOString(), p_to: b.end.toISOString() });
    Promise.all([ask(cur), ask(prev)]).then(([a, b]) => {
      if (!live) return;
      if (a.error) {
        const missing = a.error.code === "PGRST202" || /could not find the function/i.test(a.error.message ?? "");
        setState({ loading: false, missing, failed: !missing });
      } else {
        setState({ loading: false, data: a.data, prev: b.error ? null : b.data });
      }
    });
    return () => { live = false; };
  }, [allowed, workspace.id, day, tz]);
  if (!allowed) return null;
  const d = state.data;
  const change = d && state.prev && trend(d.total, state.prev.total, false);
  return (
    <button type="button" className="ba-kpi td-kpi td-kpi-link td-kpi-spam" onClick={onOpen}
      aria-label={d ? `Spam: ${d.total} suspected, ${d.unreviewed} to review. Open Spam protection` : "Open Spam protection"}>
      <span className={`ba-kpi-icon ${d?.unreviewed ? "rose" : ""}`}><Icon name="gpp_maybe" /></span>
      <div className="td-kpi-body">
        <span className="td-kpi-label">Spam</span>
        <div className="td-kpi-row">
          <span className="ba-kpi-value">{state.loading ? "…" : d ? <CountUp value={d.total} /> : "—"}</span>
          {d && d.unreviewed > 0 && <span className="td-spam-new">{d.unreviewed} to review</span>}
          {d && !d.unreviewed && change && (
            <span className={`td-trend ${change.tone}`} aria-label={change.label ?? change.text}>
              {change.arrow && <Icon name={change.arrow} size="sm" />}{change.text}
            </span>
          )}
          {!state.loading && !d && <span className="td-trend">{state.missing ? "Not set up yet" : "Couldn't load"}</span>}
        </div>
      </div>
    </button>
  );
}

function Card({ title, action, children, className = "", tabs }) {
  return (
    <section className={`ba-panel td-card ${className}`}>
      <div className="td-card-head"><h2>{title}</h2>{action}</div>
      {tabs}
      <div className="td-card-body">{children}</div>
    </section>
  );
}

// Calls over the 7 days ending on the chosen day: one bar per day, the chosen day highlighted, from the call records.
// (a calendar date's weekday doesn't depend on the time zone, so it is read at noon UTC)
const weekday = (date) => new Intl.DateTimeFormat("en-US", { weekday: "short", timeZone: "UTC" }).format(new Date(`${date}T12:00:00Z`));
function WeekChart({ week, loading, selected, onOpen }) {
  const total = (week ?? []).reduce((n, d) => n + d.total, 0);
  const max = Math.max(1, ...(week ?? []).map((d) => d.total));
  return (
    <Card title="Calls this week" action={<button type="button" className="ba-btn sm" onClick={onOpen}>View calls</button>}>
      {week && total > 0 ? (
        <>
          <ul className="td-week" aria-label="Calls per day for the last 7 days">
            {week.map((d) => (
              <li key={d.date} className={d.date === selected ? "on" : ""}>
                <span className="td-week-n">{d.total}</span>
                <span className="td-week-bar" style={{ "--h": `${Math.round((d.total / max) * 100)}%` }}
                  role="img" aria-label={`${weekday(d.date)}: ${d.total} calls, ${d.ai} answered by AI, ${d.missed} missed`}
                  title={`${d.total} calls · ${d.ai} by AI · ${d.missed} missed`} />
                <span className="td-week-day">{weekday(d.date)}</span>
              </li>
            ))}
          </ul>
          <p className="td-week-sum">{total} {total === 1 ? "call" : "calls"} · {week.reduce((n, d) => n + d.ai, 0)} answered by AI · {week.reduce((n, d) => n + d.missed, 0)} missed</p>
        </>
      ) : (
        <Empty title={loading ? "Loading…" : "No calls in the last 7 days"}>{!loading && "Each day's calls appear here as a bar."}</Empty>
      )}
    </Card>
  );
}

function Empty({ title, children }) {
  return <div className="ba-empty">{title && <strong>{title}</strong>}{children}</div>;
}

export default function BusinessToday({ workspace, userId, fallbackName, industry, operations = [], onAddLead, onBook, onGo, onNotice, onOpenPerson }) {
  const tz = workspace.timezone;
  const term = makeTerm(workspace);
  const cfg = todayConfig(industry);
  const agent = receptionistState(workspace);
  const roster = useRoster(workspace);
  const known = (n) => (n && n !== "Team member" ? n : "");
  const firstName = String(known(roster.nameOf[userId]) || fallbackName || "").trim().split(/\s+/)[0];

  const today = todayInput(tz);
  const [day, setDay] = useState(today);
  const [tab, setTab] = useState("all");
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [working, setWorking] = useState(null);
  const [moving, setMoving] = useState(null);
  const opsKeys = useMemo(() => operations.filter((t) => t.enabled).slice(0, 2).map((t) => t.key), [operations]);

  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    const id = workspace.id;
    const cur = dayBounds(day, tz);
    const prev = dayBounds(addDays(day, -7), tz);
    const next7 = { start: cur.end, end: dayBounds(addDays(day, 8), tz).start };
    const since90 = new Date(Date.now() - 90 * 864e5).toISOString();
    const iso = (d) => d.toISOString();
    try {
      const results = await Promise.all([
        supabase.from("appointments").select("*").eq("business_id", id).gte("start_time", iso(cur.start)).lt("start_time", iso(cur.end)).order("start_time"),
        supabase.from("appointments").select("id, party_size, status").eq("business_id", id).neq("status", "cancelled").gte("start_time", iso(prev.start)).lt("start_time", iso(prev.end)).limit(2000),
        supabase.from("customers").select("id, first_name, last_name, company_name, phone, email, source, notes, last_contacted_at, created_at").eq("business_id", id)
          .gte("created_at", iso(cur.start)).lt("created_at", iso(cur.end)).order("created_at", { ascending: false }).limit(500),
        supabase.from("customers").select("id", { count: "exact", head: true }).eq("business_id", id).gte("created_at", iso(prev.start)).lt("created_at", iso(prev.end)),
        supabase.from("calls_view").select("id, status, ai_handled, metadata").eq("business_id", id).gte("created_at", iso(cur.start)).lt("created_at", iso(cur.end)).limit(2000),
        supabase.from("calls_view").select("id, status, ai_handled").eq("business_id", id).gte("created_at", iso(prev.start)).lt("created_at", iso(prev.end)).limit(2000),
        // Receptionist activity: the latest calls and AI-handled conversations, whatever the date.
        supabase.from("calls_view").select("id, status, direction, ai_handled, needs_human, from_number, customer_id, created_at, summary, outcome, metadata").eq("business_id", id)
          .order("created_at", { ascending: false }).limit(8),
        supabase.from("conversations").select("id, subject, channel, status, last_message_at, customer_id, ai_handled").eq("business_id", id)
          .order("last_message_at", { ascending: false, nullsFirst: false }).limit(8),
        supabase.from("crm_tasks").select("id, title, body, priority, due_at, customer_id").eq("business_id", id).eq("status", "open")
          .order("due_at", { ascending: true, nullsFirst: false }).limit(6),
        supabase.from("appointments").select("customer_id, status").eq("business_id", id).eq("status", "completed").gte("start_time", since90).not("customer_id", "is", null).limit(3000),
        supabase.from("appointments").select("id, title, start_time, customer_id, status, party_size").eq("business_id", id).neq("status", "cancelled")
          .gte("start_time", iso(next7.start)).lt("start_time", iso(next7.end)).order("start_time").limit(6),
        opsKeys.length
          ? supabase.from("crm_records").select("id, type_key, title, status, due_at, customer_id, updated_at").eq("business_id", id).in("type_key", opsKeys)
            .is("closed_at", null).is("archived_at", null).order("due_at", { ascending: true, nullsFirst: false }).limit(12)
          : Promise.resolve({ data: [] }),
        cfg.staffColumn ? supabase.from("staff_members").select("id, name").eq("business_id", id) : Promise.resolve({ data: [] }),
        // the week chart: every call in the 7 days ending on the chosen day
        supabase.from("calls_view").select("created_at, status, ai_handled").eq("business_id", id)
          .gte("created_at", iso(dayBounds(addDays(day, -6), tz).start)).lt("created_at", iso(cur.end)).limit(5000),
      ]);
      const failed = results.find((r) => r.error);
      if (failed) throw failed.error;
      const [appts, prevAppts, leads, , calls, prevCalls, recentCalls, convos, tasks, visits, upcoming, records, staff, weekCalls] = results.map((r) => r.data ?? []);
      const prevLeadCount = results[3].count ?? 0;

      const visitCount = {};
      for (const v of visits) visitCount[v.customer_id] = (visitCount[v.customer_id] ?? 0) + 1;
      const top = Object.entries(visitCount).sort((a, b) => b[1] - a[1]).slice(0, 5);

      const ids = [...new Set([...appts, ...recentCalls, ...convos, ...tasks, ...upcoming, ...records].map((r) => r.customer_id).concat(top.map(([cid]) => cid)).filter(Boolean))];
      let people = {};
      if (ids.length) {
        const { data: rows, error: e } = await supabase.from("customers").select("id, first_name, last_name, company_name, phone, source").in("id", ids);
        if (e) throw e;
        people = Object.fromEntries((rows ?? []).map((p) => [p.id, p]));
      }
      const withPerson = (r) => ({ ...r, customer: people[r.customer_id] });
      const missedOpen = (rows) => rows.filter((c) => c.status === "missed" && !c.metadata?.followed_up_at).length;

      setData({
        appts: appts.map(withPerson),
        prev: {
          bookings: prevAppts.length, guests: prevAppts.reduce((n, a) => n + (a.party_size ?? 0), 0), leads: prevLeadCount,
          aiCalls: prevCalls.filter((c) => c.ai_handled).length, missed: prevCalls.filter((c) => c.status === "missed").length,
        },
        leads,
        aiCalls: calls.filter((c) => c.ai_handled).length,
        missed: calls.filter((c) => c.status === "missed").length,
        missedOpen: missedOpen(calls),
        activity: [
          ...recentCalls.map((c) => ({ kind: "call", at: c.created_at, ...withPerson(c) })),
          ...convos.filter((c) => c.ai_handled).map((c) => ({ kind: "message", at: c.last_message_at, ...withPerson(c) })),
        ].filter((x) => x.at).sort((a, b) => new Date(b.at) - new Date(a.at)).slice(0, 6),
        tasks: tasks.map(withPerson),
        top: top.map(([cid, n]) => ({ customer: people[cid], id: cid, visits: n })).filter((t) => t.customer),
        upcoming: upcoming.map(withPerson),
        records: records.map(withPerson),
        staff: Object.fromEntries(staff.map((s) => [s.id, s.name])),
        week: Array.from({ length: 7 }, (_, n) => {
          const date = addDays(day, n - 6);
          const rows = weekCalls.filter((c) => todayInput(tz, new Date(c.created_at)) === date);
          return { date, total: rows.length, ai: rows.filter((c) => c.ai_handled).length, missed: rows.filter((c) => c.status === "missed").length };
        }),
      });
    } catch (err) {
      setError(friendly(err));
    } finally {
      setLoading(false);
    }
  }, [workspace.id, day, tz, opsKeys, cfg.staffColumn]);

  useEffect(() => { load(); }, [load]);

  async function act(key, run, message) {
    setWorking(key);
    setError("");
    const { error: e } = await run();
    setWorking(null);
    if (e) { setError(friendly(e)); return; }
    if (message) onNotice(message);
    load();
  }
  async function markNoShow(a) {
    setWorking(`appt-${a.id}`);
    const { error: e } = await supabase.from("appointments").update({ status: "no_show", updated_at: new Date().toISOString() }).eq("id", a.id);
    if (e) { setWorking(null); setError(friendly(e)); return; }
    const message = await noShowNotice(a.id, personName(a.customer) ?? a.title, tz);
    setWorking(null);
    onNotice(message);
    load();
  }
  const setStatus = (a, status, done) => act(`appt-${a.id}`, () => supabase.from("appointments").update({ status, updated_at: new Date().toISOString() }).eq("id", a.id), done);
  const checkIn = (a) => act(`appt-${a.id}`, () => setCheckIn(a.id, !a.checked_in_at), a.checked_in_at ? "Undone." : `${personName(a.customer) ?? a.title}: ${cfg.arrived.toLowerCase()}.`);
  const completeTask = (t) => act(`task-${t.id}`, () => supabase.rpc("zella_complete_task", { p_task_id: t.id }), "Task done.");
  const person = (id, label) => (id && onOpenPerson ? <button type="button" className="ba-namebtn" onClick={() => onOpenPerson(id)}>{label}</button> : <span>{label}</span>);

  const now = Date.now();
  const appts = (data?.appts ?? []).map((a) => ({ ...a, stage: stage(a, now) }));
  const active = appts.filter((a) => !["cancelled", "no_show"].includes(a.stage));
  const guests = active.reduce((n, a) => n + (a.party_size ?? 0), 0);
  const showGuests = cfg.guests;
  const showStaff = cfg.staffColumn && appts.some((a) => a.staff_id);
  const TABS = [["all", "All", appts.length], ["upcoming", "Upcoming", appts.filter((a) => ["upcoming", "late"].includes(a.stage)).length],
    ["arrived", cfg.arrived, appts.filter((a) => a.stage === "arrived").length], ["completed", "Completed", appts.filter((a) => a.stage === "completed").length],
    ["cancelled", "Cancelled", appts.filter((a) => ["cancelled", "no_show"].includes(a.stage)).length]];
  const rows = appts.filter((a) => tab === "all" || (tab === "upcoming" ? ["upcoming", "late"].includes(a.stage) : tab === "cancelled" ? ["cancelled", "no_show"].includes(a.stage) : a.stage === tab));
  const STAGE = { upcoming: ["Upcoming", "info"], late: ["Running late", "danger"], arrived: [cfg.arrived, "success"], completed: ["Completed", ""], cancelled: ["Cancelled", ""], no_show: ["No-show", "danger"] };
  const isToday = day === today;
  const dayLabel = isToday ? "today" : formatLongDate(dayBounds(day, tz).start, tz);
  const p = data?.prev;
  const bookingWord = term("appointments");
  const oneBooking = term("appointment");
  const opsTypes = operations.filter((t) => opsKeys.includes(t.key));

  return (
    <>
      <div className="ba-page-head td-head">
        <div>
          <h1>{greeting(tz)}{firstName ? `, ${firstName}` : ""}!</h1>
          <p>Here's what's happening at {workspace.name} {isToday ? "today" : `on ${dayLabel}`}.</p>
        </div>
        <div className="ba-page-actions">
          <label className="td-date">
            <Icon name="calendar_month" size="sm" />
            <input type="date" value={day} onChange={(e) => e.target.value && setDay(e.target.value)} aria-label="Day to show" />
          </label>
          {!isToday && <button type="button" className="ba-btn" onClick={() => setDay(today)}>Today</button>}
          <button type="button" className="ba-btn primary" onClick={() => onBook()}><Icon name="add" size="sm" />New {oneBooking}</button>
          {cfg.walkIn
            ? <button type="button" className="ba-btn" onClick={() => onBook({ walkIn: true })}><Icon name="directions_walk" size="sm" />Walk-in</button>
            : <button type="button" className="ba-btn" onClick={onAddLead}><Icon name="person_add" size="sm" />Add lead</button>}
          <button type="button" className="ba-btn ghost" onClick={load} disabled={loading} aria-label="Refresh"><Icon name="refresh" size="sm" /></button>
        </div>
      </div>

      {error && <div className="ba-banner error">Couldn't load everything: {error} <button type="button" className="ba-link" onClick={load}>Try again</button></div>}

      <div className="td-kpis">
        <Kpi icon="event" tone="rose" label={`${bookingWord} ${isToday ? "today" : ""}`.trim()} value={active.length} loading={loading && !data} change={p && trend(active.length, p.bookings)} />
        {showGuests && <Kpi icon="groups" tone="indigo" label={`Total ${term("customers").toLowerCase()}`} value={guests} loading={loading && !data} change={p && trend(guests, p.guests)} />}
        <Kpi icon="person_add" tone="amber" label="New leads" value={data?.leads.length ?? 0} loading={loading && !data} change={p && trend(data.leads.length, p.leads)} />
        <Kpi icon="smart_toy" tone="green" label="AI-answered calls" value={data?.aiCalls ?? 0} loading={loading && !data} change={p && trend(data.aiCalls, p.aiCalls)} />
        <Kpi icon="phone_missed" tone="rose" label="Missed calls" value={data?.missed ?? 0} loading={loading && !data} change={p && trend(data.missed, p.missed, false)} />
        <SpamKpi workspace={workspace} day={day} tz={tz} onOpen={() => onGo("spam")} />
      </div>

      <div className="td-grid">
        <Card className="td-span2" title={`${isToday ? "Today's" : ""} ${bookingWord}`.trim()}
          action={<button type="button" className="ba-btn sm" onClick={() => onGo("calendar")}>View calendar</button>}
          tabs={
            <div className="td-tabs" role="tablist" aria-label={`${bookingWord} by status`}>
              {TABS.map(([key, label, n]) => (
                <button key={key} type="button" role="tab" aria-selected={tab === key} className={tab === key ? "active" : ""} onClick={() => setTab(key)}>
                  {label} <span>{n}</span>
                </button>
              ))}
            </div>
          }>
          {rows.length ? (
            <div className="ba-table-wrap">
              <table className="ba-table static td-table">
                <thead><tr>
                  <th>Time</th><th>{term("customer")}</th>{showGuests && <th>{term("customers")}</th>}{showStaff && <th>{term("staff")}</th>}
                  <th>Status</th><th>Notes</th><th><span className="ba-sr">Actions</span></th>
                </tr></thead>
                <tbody>
                  {rows.map((a) => {
                    const [stageLabel, tone] = STAGE[a.stage];
                    const [src, srcIcon] = SOURCE[a.customer?.source] ?? (a.customer?.source ? [a.customer.source, "more_horiz"] : ["—", null]);
                    const busy = working === `appt-${a.id}`;
                    const mins = minutes(a);
                    return (
                      <tr key={a.id}>
                        <td className="td-time">{formatTime(a.start_time, tz)}{mins ? <small>{mins} min</small> : null}</td>
                        <td>{person(a.customer?.id, personName(a.customer) ?? a.title)}
                          <small className="td-sub">{srcIcon && <Icon name={srcIcon} size="sm" />} {src !== "—" ? src : ""}{src !== "—" && personName(a.customer) && a.title ? " · " : ""}{personName(a.customer) ? a.title : ""}</small></td>
                        {showGuests && <td>{a.party_size ?? "—"}</td>}
                        {showStaff && <td>{data.staff[a.staff_id] ?? "—"}</td>}
                        <td><Pill tone={tone}>{stageLabel}</Pill>{a.booking_state === "requested" && <small className="td-sub">Request, not booked</small>}</td>
                        <td className="td-notes">{a.description || a.internal_notes || a.location || ""}</td>
                        <td>
                          <div className="td-actions">
                            {a.customer?.phone && <a className="ba-btn ghost sm" href={`tel:${a.customer.phone}`} aria-label={`Call ${personName(a.customer) ?? ""}`} title="Call"><Icon name="call" size="sm" /></a>}
                            {/* Up to four actions, by state: upcoming = confirm, arrived, reschedule; late = arrived, no-show;
                                arrived = completed, undo. */}
                            {a.stage === "upcoming" && a.status === "scheduled" && <button type="button" className="ba-btn ghost sm" disabled={busy} onClick={() => setStatus(a, "confirmed", `${oneBooking} confirmed.`)} title="Confirm" aria-label="Confirm"><Icon name="check" size="sm" /></button>}
                            {["upcoming", "late"].includes(a.stage) && <button type="button" className="ba-btn ghost sm" disabled={busy} onClick={() => checkIn(a)} title={cfg.arrived} aria-label={`Mark ${cfg.arrived.toLowerCase()}`}><Icon name="how_to_reg" size="sm" /></button>}
                            {a.stage === "upcoming" && <button type="button" className="ba-btn ghost sm" disabled={busy} onClick={() => setMoving(a)} title="Reschedule" aria-label="Reschedule"><Icon name="event_repeat" size="sm" /></button>}
                            {a.stage === "late" && <button type="button" className="ba-btn ghost sm" disabled={busy} onClick={() => markNoShow(a)} title="No-show" aria-label="Mark no-show"><Icon name="person_off" size="sm" /></button>}
                            {a.stage === "arrived" && <button type="button" className="ba-btn ghost sm" disabled={busy} onClick={() => setStatus(a, "completed", `${oneBooking} completed.`)} title="Mark completed" aria-label="Mark completed"><Icon name="task_alt" size="sm" /></button>}
                            {a.stage === "arrived" && a.checked_in_at && <button type="button" className="ba-btn ghost sm" disabled={busy} onClick={() => checkIn(a)} title="Undo" aria-label={`Undo ${cfg.arrived.toLowerCase()}`}><Icon name="undo" size="sm" /></button>}
                          </div>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          ) : (
            <Empty title={loading && !data ? "Loading…" : `No ${bookingWord.toLowerCase()} ${tab === "all" ? dayLabel : "here"}`}>
              {!loading && tab === "all" && `Book one with New ${oneBooking.toLowerCase()}.`}
            </Empty>
          )}
        </Card>

        <Card title="AI Receptionist Activity" action={<Pill tone={agent.tone} dot={agent.live} pulse={agent.live}>{agent.live ? "Live" : agent.label}</Pill>}>
          {data?.activity.length ? (
            <ul className="td-feed">
              {data.activity.map((x) => {
                const who = personName(x.customer) ?? x.from_number ?? "a caller";
                const [icon, tone, text, sub] = x.kind === "message"
                  ? ["sms", "violet", `Replied by ${x.channel === "email" ? "email" : "text"} to ${who}`, x.subject]
                  : x.status === "missed" ? ["phone_missed", "rose", `Missed call from ${who}`, x.metadata?.followed_up_at ? "Followed up" : "Waiting for a call back"]
                    : x.needs_human ? ["support_agent", "amber", `Handed ${who} to a person`, x.summary]
                      : ["call", "green", `${x.ai_handled ? "Answered" : "Call with"} ${who}`, x.summary || x.outcome];
                return (
                  <li key={`${x.kind}-${x.id}`}>
                    <span className={`ba-kpi-icon ${tone}`}><Icon name={icon} size="sm" /></span>
                    <div><strong>{text}</strong>{sub && <small>{String(sub).slice(0, 90)}</small>}</div>
                    <time>{timeAgo(x.at)}</time>
                  </li>
                );
              })}
            </ul>
          ) : (
            <Empty title={loading && !data ? "Loading…" : "No activity yet"}>{!loading && (agent.live ? "Calls and messages your receptionist handles appear here." : "Starts once your AI receptionist is live.")}</Empty>
          )}
        </Card>

        <WeekChart week={data?.week} loading={loading && !data} selected={day} onOpen={() => onGo("calls")} />

        {opsTypes.map((t) => {
          const recs = (data?.records ?? []).filter((r) => r.type_key === t.key).slice(0, 5);
          return (
            <Card key={t.key} title={t.plural} action={<button type="button" className="ba-btn sm" onClick={() => onGo(`rec:${t.key}`)}>View all</button>}>
              {recs.length ? (
                <ul className="td-list">
                  {recs.map((r) => (
                    <li key={r.id}>
                      <div><strong>{r.title}</strong><small>{personName(r.customer) ?? (r.due_at ? `Due ${formatLongDate(r.due_at, tz)}` : `Updated ${timeAgo(r.updated_at)}`)}</small></div>
                      <Pill>{String(r.status).replace(/_/g, " ")}</Pill>
                    </li>
                  ))}
                </ul>
              ) : <Empty title={loading && !data ? "Loading…" : `No open ${t.plural.toLowerCase()}`} />}
            </Card>
          );
        })}

        <Card title={`Top ${term("customers").toLowerCase()}`} action={<button type="button" className="ba-btn sm" onClick={() => onGo("customers")}>View all</button>}>
          {data?.top.length ? (
            <ul className="td-list">
              {data.top.map((t, n) => (
                <li key={t.id}>
                  <span className="ba-avatar">{(personName(t.customer) ?? "?").split(/\s+/).map((w) => w[0]).slice(0, 2).join("").toUpperCase()}</span>
                  <div>{person(t.id, personName(t.customer) ?? "Unnamed")}<small>{t.visits} {t.visits === 1 ? "visit" : "visits"} in 90 days</small></div>
                  {n < 2 && <Icon name="workspace_premium" size="sm" className="td-star" />}
                </li>
              ))}
            </ul>
          ) : <Empty title={loading && !data ? "Loading…" : "No completed visits yet"}>{!loading && `Ranked by completed ${bookingWord.toLowerCase()} in the last 90 days.`}</Empty>}
        </Card>

        <Card title="Tasks & Follow-ups" action={<button type="button" className="ba-btn sm" onClick={() => onGo("tasks")}>View all</button>}>
          {data?.tasks.length ? (
            <ul className="td-list">
              {data.tasks.map((t) => {
                const overdue = t.due_at && new Date(t.due_at).getTime() < now;
                return (
                  <li key={t.id}>
                    <input type="checkbox" aria-label={`Mark "${t.title}" done`} disabled={working === `task-${t.id}`} onChange={() => completeTask(t)} />
                    <div><strong>{t.title}</strong><small>{personName(t.customer) ?? t.body ?? ""}</small></div>
                    <div className="td-right">
                      {t.priority && t.priority !== "normal" && <Pill tone={PRIORITY_TONE[t.priority]}>{t.priority === "urgent" ? "Urgent" : "High"}</Pill>}
                      {t.due_at && <small className={overdue ? "td-overdue" : ""}>{overdue ? "Overdue" : `Due ${formatTime(t.due_at, tz)}`}</small>}
                    </div>
                  </li>
                );
              })}
            </ul>
          ) : <Empty title={loading && !data ? "Loading…" : "Nothing to follow up"}>{!loading && "Tasks from calls, leads and your team appear here."}</Empty>}
        </Card>

        <Card title={`Upcoming ${bookingWord.toLowerCase()}`} action={<button type="button" className="ba-btn sm" onClick={() => onGo("calendar")}>View all</button>}>
          {data?.upcoming.length ? (
            <ul className="td-list">
              {data.upcoming.map((a) => (
                <li key={a.id}>
                  <span className="ba-kpi-icon rose"><Icon name="event" size="sm" /></span>
                  <div><strong>{personName(a.customer) ?? a.title}</strong><small>{formatLongDate(a.start_time, tz)} · {formatTime(a.start_time, tz)}{a.party_size ? ` · ${a.party_size} ${term("customers").toLowerCase()}` : ""}</small></div>
                </li>
              ))}
            </ul>
          ) : <Empty title={loading && !data ? "Loading…" : "Nothing in the next 7 days"} />}
        </Card>

        {cfg.connect.map((key) => {
          const c = CONNECT[key];
          return (
            <Card key={key} title={c.title} className="td-connect">
              <div className="td-connect-body">
                <span className="ba-kpi-icon indigo"><Icon name={c.icon} /></span>
                <p>{c.text}</p>
                {key === "reviews" && <button type="button" className="ba-btn sm" onClick={() => onGo("settings/messages/reviews")}>Review link</button>}
                {key === "tables" && operations.some((t) => t.key === "tables" && t.enabled) && <button type="button" className="ba-btn sm" onClick={() => onGo("rec:tables")}>Open tables</button>}
                {key !== "reviews" && key !== "tables" && <button type="button" className="ba-btn sm" onClick={() => onGo("integrations")}>Integrations</button>}
              </div>
            </Card>
          );
        })}
      </div>

      {moving && (
        <RescheduleModal workspace={workspace} term={term} appt={moving} person={moving.customer}
          onClose={() => setMoving(null)} onSaved={(message) => { setMoving(null); onNotice(message); load(); }} />
      )}
    </>
  );
}
