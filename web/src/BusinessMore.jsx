import { useMemo, useState } from "react";
import { supabase } from "./supabase";
import { Field, Icon, Modal, Pill, initials, personName } from "./BusinessUI";
import { makeTerm } from "./businessWorkspace";
import { dayRange, formatDay, formatTime, timeAgo } from "./businessTime";
import { APPT_LABEL, APPT_TONE, Empty, Notice, PageHead, Segment, SOURCE_LABELS, clock, friendly, loadPeople, noShowNotice, explain, orThrow, plural, setCheckIn, sourceLabel, useLoad, isAnswered } from "./BusinessShared";
import { CallCard, isOpenEscalation } from "./BusinessProfile";
import { RescheduleModal } from "./BusinessForms";
import { MoreReports } from "./BusinessReports";
import { humanize } from "./copy/labels";

// Needs attention, Check-ins, Unified Inbox, Lead sources, Reports and
// Integrations. Everything is calculated from the business's own records.

function NameButton({ person, id, fallback, onOpenPerson }) {
  const name = personName(person) ?? fallback;
  const target = id ?? person?.id;
  if (!target) return <strong>{name}</strong>;
  return <button type="button" className="ba-namebtn strong" onClick={() => onOpenPerson(target)}>{name}</button>;
}

/* ---------------------------------------------------------------- */
/* Needs attention: hand-offs to a human                             */
/* ---------------------------------------------------------------- */

export function AttentionPage({ workspace, refreshKey, onNotice, onOpenPerson, onChanged }) {
  const tz = workspace.timezone;
  const [filter, setFilter] = useState("open");
  const { data, error, loading, reload } = useLoad(async () => {
    const calls = orThrow(await supabase.from("calls_view").select("*").eq("business_id", workspace.id).eq("needs_human", true)
      .order("escalated_at", { ascending: false, nullsFirst: false }).limit(200));
    return { calls, people: await loadPeople(calls.map((c) => c.customer_id)) };
  }, [workspace.id, refreshKey]);

  const calls = data?.calls ?? [];
  const open = calls.filter(isOpenEscalation);
  const rows = filter === "open" ? open : calls.filter((c) => !isOpenEscalation(c));
  const changed = () => { reload(); onChanged?.(); };

  return (
    <>
      <PageHead
        crumb="Calls & messages / Needs attention"
        title="Needs attention"
        sub={open.length ? `${plural(open.length, "caller")} waiting for a person. Your AI receptionist handed these over.` : "Nothing is waiting. Anything your AI receptionist can't handle shows up here."}
      >
        <Segment label="Hand-off filter" value={filter} onChange={setFilter} options={[["open", `Waiting (${open.length})`], ["done", "Handled"]]} />
      </PageHead>
      <Notice error={error} onRetry={reload} />
      {loading && !data ? <p className="ba-muted">Loading…</p> : !rows.length ? (
        <Empty title={filter === "open" ? "All clear" : "No handled hand-offs yet"}>
          {filter === "open" ? "When a caller asks for a person, or the AI can't help, it appears here with the full transcript." : "Handled hand-offs are kept here for your records."}
        </Empty>
      ) : (
        <div className="ba-stack">
          {rows.map((c) => {
            const person = data.people[c.customer_id];
            return (
              <section key={c.id} className="ba-panel ba-attn">
                <div className="ba-attn-head">
                  <div className="ba-person">
                    <div className="ba-avatar sm">{initials(personName(person) ?? c.from_number ?? "?")}</div>
                    <div>
                      <NameButton person={person} fallback={c.from_number ?? "Unknown caller"} onOpenPerson={onOpenPerson} />
                      <small>{person ? c.from_number : ""} {c.escalated_at ? `· handed over ${timeAgo(c.escalated_at)}` : ""}</small>
                    </div>
                  </div>
                  {(person?.phone || c.from_number) && <a className="ba-btn primary sm" href={`tel:${person?.phone ?? c.from_number}`}><Icon name="call" size="sm" />Call now</a>}
                </div>
                <div className="ba-panel-body"><CallCard call={c} tz={tz} defaultOpen onChanged={changed} onNotice={onNotice} /></div>
              </section>
            );
          })}
        </div>
      )}
    </>
  );
}

/* ---------------------------------------------------------------- */
/* Check-ins                                                         */
/* ---------------------------------------------------------------- */

export function WalkInModal({ workspace, staff, hospitality, onClose, onSaved }) {
  const term = makeTerm(workspace);
  const [form, setForm] = useState({ name: "", phone: "", partySize: "", staffId: "", note: "" });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const set = (key) => (e) => setForm({ ...form, [key]: e.target.value });

  async function save(event) {
    event.preventDefault();
    setBusy(true);
    setError("");
    try {
      let customerId = null;
      const name = form.name.trim();
      if (name || form.phone.trim()) {
        const [first, ...rest] = name.split(/\s+/);
        const inserted = await supabase.from("customers").insert({
          business_id: workspace.id, first_name: first || null, last_name: rest.join(" ") || null,
          phone: form.phone.trim() || null, source: "walk_in", status: "active",
        }).select("id").single();
        if (inserted.error) throw inserted.error;
        customerId = inserted.data.id;
      }
      const now = new Date();
      const inserted = await supabase.from("appointments").insert({
        business_id: workspace.id, customer_id: customerId, title: "Walk-in", status: "confirmed",
        start_time: now.toISOString(), end_time: new Date(now.getTime() + 30 * 60000).toISOString(),
        timezone: workspace.timezone, description: form.note.trim() || null,
        checked_in_at: now.toISOString(),
        ...(form.staffId ? { staff_id: form.staffId } : {}),
        ...(form.partySize ? { party_size: Number(form.partySize) } : {}),
      });
      if (inserted.error) throw inserted.error;
      onSaved(`${name || "Walk-in"} checked in.`);
    } catch (err) {
      setError(friendly(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal title="Add walk-in" description="For someone who arrives without a booking. They go straight to Waiting." onClose={onClose} busy={busy}>
      <form className="ba-form-grid ba-modal-body" onSubmit={save}>
        {error && <div className="ba-banner error full">{error}</div>}
        <Field label="Name"><input value={form.name} onChange={set("name")} autoFocus /></Field>
        <Field label="Phone"><input value={form.phone} onChange={set("phone")} inputMode="tel" /></Field>
        {hospitality && <Field label="Party size"><input type="number" min="1" value={form.partySize} onChange={set("partySize")} /></Field>}
        {staff.length > 0 && (
          <Field label={`For (${term("staff").toLowerCase()})`}>
            <select value={form.staffId} onChange={set("staffId")}><option value="">Anyone</option>{staff.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}</select>
          </Field>
        )}
        <Field label="Note" full><input value={form.note} onChange={set("note")} placeholder="Optional" /></Field>
        <div className="full ba-form-actions">
          <button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button>
          <button type="submit" className="ba-btn primary" disabled={busy}>{busy ? "Saving…" : "Check in"}</button>
        </div>
      </form>
    </Modal>
  );
}

/* ---------------------------------------------------------------- */
/* Unified inbox                                                     */
/* ---------------------------------------------------------------- */

/* ---------------------------------------------------------------- */
/* Lead sources                                                      */
/* ---------------------------------------------------------------- */

const RANGES = [["7", "7 days"], ["30", "30 days"], ["90", "90 days"]];

export function LeadSourcesPage({ workspace, refreshKey }) {
  const tz = workspace.timezone;
  const term = makeTerm(workspace);
  const [range, setRange] = useState("30");
  const { data, error, loading, reload } = useLoad(async () => {
    const since = dayRange(tz, -(Number(range) - 1)).start.toISOString();
    const people = orThrow(await supabase.from("customers").select("id, source, created_at, last_contacted_at").eq("business_id", workspace.id).gte("created_at", since).limit(5000));
    const ids = people.map((p) => p.id);
    let booked = new Set();
    if (ids.length) {
      const appts = orThrow(await supabase.from("appointments").select("customer_id").eq("business_id", workspace.id).neq("status", "cancelled").gte("created_at", since).limit(10000));
      booked = new Set(appts.map((a) => a.customer_id).filter(Boolean));
    }
    return { people, booked };
  }, [workspace.id, range, refreshKey]);

  const rows = useMemo(() => {
    const map = {};
    for (const p of data?.people ?? []) {
      const key = p.source || "other";
      map[key] ??= { source: key, leads: 0, contacted: 0, booked: 0 };
      map[key].leads += 1;
      if (p.last_contacted_at) map[key].contacted += 1;
      if (data.booked.has(p.id)) map[key].booked += 1;
    }
    return Object.values(map).sort((a, b) => b.leads - a.leads);
  }, [data]);
  const total = rows.reduce((s, r) => s + r.leads, 0);
  const pct = (n, d) => (d ? `${Math.round((n / d) * 100)}%` : "—");

  return (
    <>
      <PageHead crumb="Business growth / Lead sources" title="Lead sources" sub={`Where new ${term("customers").toLowerCase()} come from, and how many became bookings.`}>
        <Segment label="Date range" value={range} onChange={setRange} options={RANGES} />
      </PageHead>
      <Notice error={error} onRetry={reload} />
      <section className="ba-panel">
        {loading && !data ? <div className="ba-panel-body"><p className="ba-muted">Loading…</p></div> : !rows.length ? (
          <div className="ba-panel-body"><Empty title="No new leads in this period">Leads from calls, your website and the team are counted here.</Empty></div>
        ) : (
          <div className="ba-table-wrap">
            <table className="ba-table static">
              <thead><tr><th>Source</th><th>New leads</th><th>Share</th><th>Contacted</th><th>Booked</th><th>Booked rate</th></tr></thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.source}>
                    <td><strong>{SOURCE_LABELS[r.source] ?? sourceLabel(r.source)}</strong></td>
                    <td>{r.leads}</td>
                    <td><div className="ba-meter" aria-label={pct(r.leads, total)}><span style={{ width: pct(r.leads, total) }} /></div><small>{pct(r.leads, total)}</small></td>
                    <td>{r.contacted} <small>({pct(r.contacted, r.leads)})</small></td>
                    <td>{r.booked}</td>
                    <td>{pct(r.booked, r.leads)}</td>
                  </tr>
                ))}
              </tbody>
              <tfoot><tr><td>Total</td><td>{total}</td><td /><td>{rows.reduce((s, r) => s + r.contacted, 0)}</td><td>{rows.reduce((s, r) => s + r.booked, 0)}</td><td>{pct(rows.reduce((s, r) => s + r.booked, 0), total)}</td></tr></tfoot>
            </table>
          </div>
        )}
      </section>
    </>
  );
}

/* ---------------------------------------------------------------- */
/* Reports                                                           */
/* ---------------------------------------------------------------- */

function Stat({ label, value, note }) {
  return (
    <div className="ba-kpi">
      <div className="ba-kpi-top"><span>{label}</span></div>
      <div className="ba-kpi-value">{value}</div>
      {note && <div className="ba-kpi-note">{note}</div>}
    </div>
  );
}

export function ReportsPage({ workspace, refreshKey }) {
  const tz = workspace.timezone;
  const term = makeTerm(workspace);
  const [range, setRange] = useState("30");
  const { data, error, loading, reload } = useLoad(async () => {
    const days = Number(range);
    const since = dayRange(tz, -(days - 1)).start;
    const sinceIso = since.toISOString();
    const [calls, appts, people] = await Promise.all([
      supabase.from("calls_view").select("*").eq("business_id", workspace.id).gte("created_at", sinceIso).limit(5000),
      supabase.from("appointments").select("*").eq("business_id", workspace.id).gte("start_time", sinceIso).lt("start_time", new Date().toISOString()).limit(5000),
      supabase.from("customers").select("id, created_at").eq("business_id", workspace.id).gte("created_at", sinceIso).limit(5000),
    ]);
    return { calls: orThrow(calls), appts: orThrow(appts), people: orThrow(people), since, days };
  }, [workspace.id, range, refreshKey]);

  const review = useLoad(async () => {
    const { data: d, error: e } = await supabase.rpc("zella_performance_review", { p_business_id: workspace.id, p_days: Number(range) });
    if (e) throw e;
    return d;
  }, [workspace.id, range, refreshKey]);

  const r = useMemo(() => {
    if (!data) return null;
    const answered = data.calls.filter((c) => isAnswered(c.status));
    const ai = data.calls.filter((c) => c.ai_handled);
    const missed = data.calls.filter((c) => c.status === "missed");
    const timed = answered.filter((c) => c.duration_seconds);
    const handoffs = data.calls.filter((c) => c.needs_human);
    const finished = data.appts.filter((a) => ["completed", "no_show"].includes(a.status));
    const noShows = data.appts.filter((a) => a.status === "no_show");
    const counted = data.appts.filter((a) => a.status !== "cancelled");
    // Calls per day for the chart.
    const buckets = Array.from({ length: Math.min(data.days, 30) }, (_, i) => dayRange(tz, -(Math.min(data.days, 30) - 1 - i)));
    const perDay = buckets.map((b) => ({ day: b.start, n: data.calls.filter((c) => new Date(c.created_at) >= b.start && new Date(c.created_at) < b.end).length }));
    return {
      calls: data.calls.length, answered: answered.length, ai: ai.length, missed: missed.length,
      followed: missed.filter((c) => c.metadata?.followed_up_at).length,
      avg: timed.length ? Math.round(timed.reduce((s, c) => s + c.duration_seconds, 0) / timed.length) : null,
      handoffs: handoffs.length, handoffsOpen: handoffs.filter(isOpenEscalation).length,
      booked: counted.length, completed: data.appts.filter((a) => a.status === "completed").length,
      noShows: noShows.length, noShowRate: finished.length ? Math.round((noShows.length / finished.length) * 100) : null,
      checkedIn: counted.filter((a) => a.checked_in_at).length, leads: data.people.length, perDay,
    };
  }, [data, tz]);

  const pct = (n, d) => (d ? `${Math.round((n / d) * 100)}%` : "—");
  const peak = Math.max(1, ...(r?.perDay ?? []).map((d) => d.n));
  return (
    <>
      <PageHead crumb="Business growth / Reports & analytics" title="Reports" sub={`How ${workspace.name} is doing. Every figure comes from your own records.`}>
        <Segment label="Date range" value={range} onChange={setRange} options={RANGES} />
      </PageHead>
      <Notice error={error} onRetry={reload} />
      {loading && !r ? <p className="ba-muted">Loading…</p> : r && (
        <>
          {review.data && (
            <section className="ba-panel ba-gap">
              <div className="ba-panel-head"><div className="ba-panel-title"><div><h2>Zella's review</h2><p>{review.data.issues?.length ? "Things worth a look" : "Nothing needs attention"}</p></div></div></div>
              {review.data.issues?.length > 0 && <ul className="ba-checklist">{review.data.issues.map((t) => <li key={t}>{t}</li>)}</ul>}
            </section>
          )}
          <h2 className="ba-h2">Calls</h2>
          <div className="ba-kpis">
            <Stat label="Total calls" value={r.calls} note={`${r.answered} answered`} />
            <Stat label="Handled by AI" value={pct(r.ai, r.calls)} note={`${r.ai} calls`} />
            <Stat label="Missed" value={r.missed} note={r.missed ? `${r.followed} followed up` : "None missed"} />
            <Stat label="Average call" value={r.avg ? clock(r.avg) : "—"} />
            <Stat label="Handed to a human" value={r.handoffs} note={r.handoffsOpen ? `${r.handoffsOpen} still waiting` : "None waiting"} />
          </div>
          <section className="ba-panel ba-gap">
            <div className="ba-panel-head"><div className="ba-panel-title"><div><h2>Calls per day</h2><p>Last {Math.min(Number(range), 30)} days</p></div></div></div>
            <div className="ba-bars" role="img" aria-label="Calls per day">
              {r.perDay.map((d) => (
                <span key={d.day.toISOString()} title={`${formatDay(d.day, tz)}: ${d.n}`}><i style={{ height: `${Math.max(3, (d.n / peak) * 100)}%` }} /></span>
              ))}
            </div>
          </section>
          <h2 className="ba-h2">{term("appointments")} and people</h2>
          <div className="ba-kpis">
            <Stat label={`${term("appointments")} so far`} value={r.booked} note={`${r.completed} completed`} />
            <Stat label="No-show rate" value={r.noShowRate == null ? "—" : `${r.noShowRate}%`} note={`${r.noShows} no-shows`} />
            <Stat label="Checked in" value={pct(r.checkedIn, r.booked)} note={`${r.checkedIn} arrivals`} />
            <Stat label={`New ${term("customers").toLowerCase()}`} value={r.leads} />
          </div>
        </>
      )}
      <MoreReports workspace={workspace} days={Number(range)} refreshKey={refreshKey} />
    </>
  );
}

/* ---------------------------------------------------------------- */
/* Integrations                                                      */
/* ---------------------------------------------------------------- */

const CATALOG = [
  { match: ["telnyx"], icon: "call", name: "Phone line", text: "Your business number, new or forwarded to Zella." },
  { match: ["vapi"], icon: "record_voice_over", name: "Voice assistant", text: "The AI receptionist that answers your calls." },
  { match: ["google_calendar", "gcal", "google"], not: ["ads", "lead", "profile", "mail"], icon: "calendar_month", name: "Google Calendar", text: "Keeps bookings and your calendar in sync." },
  { match: ["outlook_calendar", "microsoft_calendar", "outlook", "microsoft"], not: ["mail"], icon: "event", name: "Outlook / Microsoft Calendar", text: "Keeps bookings and your calendar in sync." },
  { match: ["gmail", "google_mail"], icon: "mail", name: "Gmail", text: "Sends and reads email from your own address." },
  { match: ["outlook_mail", "microsoft_mail"], icon: "mail", name: "Outlook email", text: "Sends and reads email from your own address." },
  { match: ["whatsapp"], icon: "chat", name: "WhatsApp", text: "Chat with customers on WhatsApp from the inbox." },
  { match: ["google_ads", "google_leads", "google_profile"], icon: "ads_click", name: "Google leads", text: "Brings in leads from Google Ads and your Business Profile." },
  { match: ["meta", "facebook", "instagram"], icon: "campaign", name: "Facebook and Instagram", text: "Brings in leads from your ads and messages." },
  { match: ["website", "form", "web"], icon: "language", name: "Website forms", text: "Sends website enquiries straight into your leads." },
];

const STATUS_TEXT = { active: "Connected", inactive: "Turned off", error: "Needs attention", disconnected: "Removed" };
const STATUS_TONE = { active: "success", inactive: "", error: "warning", disconnected: "" };

function IntegrationCard({ item, row, canManage, loading, onNotice, onChanged, workspace }) {
  const [confirming, setConfirming] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const core = item.match.some((m) => ["telnyx", "vapi"].includes(m));

  async function act(action) {
    setBusy(true);
    setError("");
    const { error: failure } = await supabase.rpc("zella_set_integration", { p_business_id: workspace.id, p_integration_id: row.id, p_action: action });
    setBusy(false);
    if (failure) return setError(/NEEDS_RECONNECT/.test(failure.message) ? "This was removed, so it needs the Zella team to connect it again." : explain(failure));
    setConfirming(false);
    onNotice?.(action === "remove" ? `${item.name} was removed.` : `${item.name} is ${action === "on" ? "on" : "off"}.`);
    onChanged();
  }

  return (
    <section className="ba-panel ba-integration ba-integration-controls">
      <div className="ba-integration-row">
        <span className="ba-thread-icon"><Icon name={item.icon} size="sm" /></span>
        <div><strong>{item.name}</strong><small>{item.text}</small></div>
        <Pill tone={row ? STATUS_TONE[row.status] : ""} dot={row?.status === "active"}>
          {loading ? "…" : row ? STATUS_TEXT[row.status] ?? humanize(row.status) : "Not connected"}
        </Pill>
      </div>
      {row?.account_email && <small className="ba-integration-account">{row.account_email}</small>}
      {canManage && row && (
        <div className="ba-integration-actions">
          {row.status === "disconnected" ? (
            <small>Removed. Ask the Zella team to connect it again.</small>
          ) : confirming ? (
            <div className="ba-confirm" role="alertdialog" aria-label={`Remove ${item.name}`}>
              <p>
                Remove {item.name}? Its saved sign-in details are deleted.
                {core && " Your AI receptionist can't take calls without it."} The Zella team has to connect it again.
              </p>
              <div className="ba-auto-actions">
                <button type="button" className="ba-btn" disabled={busy} onClick={() => setConfirming(false)}>Keep it</button>
                <button type="button" className="ba-btn danger" disabled={busy} onClick={() => act("remove")}>{busy ? "Removing…" : "Yes, remove"}</button>
              </div>
            </div>
          ) : (
            <>
              {row.status === "inactive"
                ? <button type="button" className="ba-btn" disabled={busy} onClick={() => act("on")}>Turn on</button>
                : <button type="button" className="ba-btn" disabled={busy} onClick={() => act("off")}>Turn off</button>}
              <button type="button" className="ba-btn danger-text" disabled={busy} onClick={() => setConfirming(true)}>Remove</button>
            </>
          )}
        </div>
      )}
      {error && <p className="ba-error" role="alert">{error}</p>}
    </section>
  );
}

export function IntegrationsPage({ workspace, refreshKey, onNotice }) {
  const canManage = ["owner", "admin", "manager"].includes(workspace.role);
  const { data, error, loading, reload } = useLoad(async () =>
    orThrow(await supabase.from("integrations").select("id, provider, status, account_email").eq("business_id", workspace.id)), [workspace.id, refreshKey]);
  const rowFor = (item) => (data ?? []).find((r) => {
    const p = (r.provider ?? "").toLowerCase();
    return item.match.some((m) => p.includes(m)) && !(item.not ?? []).some((n) => p.includes(n));
  });
  return (
    <>
      <PageHead crumb="Management / Integrations" title="Integrations"
        sub={canManage ? "Turn any connected service off, back on, or remove it." : "The services connected to your workspace."} />
      <Notice error={error} onRetry={reload} />
      <div className="ba-grid-2">
        {CATALOG.map((item) => (
          <IntegrationCard key={item.name} item={item} row={rowFor(item)} canManage={canManage} loading={loading && !data}
            onNotice={onNotice} onChanged={reload} workspace={workspace} />
        ))}
      </div>
      <p className="ba-muted ba-gap">Want one connected or connected again? Ask the Zella team and it will be set up for you.</p>
    </>
  );
}
