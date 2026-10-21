import { useMemo, useState } from "react";
import { supabase } from "./supabase";
import { Field, Icon, Modal, Pill, initials, personName } from "./BusinessUI";
import { makeTerm } from "./businessWorkspace";
import { dayRange, formatDay, formatTime, timeAgo } from "./businessTime";
import {
  APPT_LABEL, APPT_TONE, Empty, Notice, PageHead, Segment, SOURCE_LABELS, clock, friendly, loadPeople, noShowNotice,
  orThrow, plural, setCheckIn, sourceLabel, useLoad,
} from "./BusinessShared";
import { CallCard, isOpenEscalation } from "./BusinessProfile";
import { RescheduleModal } from "./BusinessForms";

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
    const calls = orThrow(await supabase.from("calls").select("*").eq("business_id", workspace.id).eq("needs_human", true)
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
        crumb="Communications / Needs attention"
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

function WalkInModal({ workspace, staff, hospitality, onClose, onSaved }) {
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

export function CheckInsPage({ workspace, refreshKey, onNotice, onOpenPerson, onChanged }) {
  const tz = workspace.timezone;
  const term = makeTerm(workspace);
  const hospitality = /restaurant|cafe|café|bar\b|food|dining|hotel|catering/i.test(`${workspace.industry ?? ""} ${term("appointment")}`);
  const [walkIn, setWalkIn] = useState(false);
  const [working, setWorking] = useState(null);
  const [moving, setMoving] = useState(null);
  const { data, error, loading, reload } = useLoad(async () => {
    const today = dayRange(tz, 0);
    const appts = orThrow(await supabase.from("appointments").select("*").eq("business_id", workspace.id)
      .gte("start_time", today.start.toISOString()).lt("start_time", today.end.toISOString()).order("start_time"));
    const staffResult = await supabase.from("staff_members").select("id, name, color").eq("business_id", workspace.id);
    return { appts, staff: staffResult.error ? [] : staffResult.data ?? [], people: await loadPeople(appts.map((a) => a.customer_id)) };
  }, [workspace.id, refreshKey]);

  const staffName = Object.fromEntries((data?.staff ?? []).map((m) => [m.id, m.name]));
  const live = (data?.appts ?? []).filter((a) => ["scheduled", "confirmed"].includes(a.status));
  const waiting = live.filter((a) => a.checked_in_at);
  const expected = live.filter((a) => !a.checked_in_at);
  const done = (data?.appts ?? []).filter((a) => ["completed", "no_show", "cancelled"].includes(a.status));
  const nowMs = Date.now();

  async function run(id, task, message) {
    setWorking(id);
    const { error: updateError } = await task();
    setWorking(null);
    if (updateError) return onNotice(friendly(updateError));
    if (message) onNotice(message);
    reload();
    onChanged?.();
  }
  const setStatus = async (a, status, message) => {
    if (status !== "no_show") return run(a.id, () => supabase.from("appointments").update({ status, updated_at: new Date().toISOString() }).eq("id", a.id), message);
    setWorking(a.id);
    const { error: updateError } = await supabase.from("appointments").update({ status, updated_at: new Date().toISOString() }).eq("id", a.id);
    if (updateError) { setWorking(null); return onNotice(friendly(updateError)); }
    const text = await noShowNotice(a.id, personName(data.people[a.customer_id]) ?? a.title, tz);
    setWorking(null);
    onNotice(text);
    reload();
    onChanged?.();
  };

  const Card = ({ a, column }) => {
    const person = data.people[a.customer_id];
    const late = column === "expected" && new Date(a.start_time).getTime() < nowMs - 10 * 60000;
    const busy = working === a.id;
    return (
      <article className={`ba-item ${late ? "alert" : ""}`}>
        <div className="ba-item-top">
          <div className="ba-item-name"><NameButton person={person} fallback={a.title} onOpenPerson={onOpenPerson} /></div>
          <span className="ba-item-time">{formatTime(a.start_time, tz)}</span>
        </div>
        <div className="ba-item-meta">
          <span>{a.title}</span>
          {staffName[a.staff_id] && <span>· {staffName[a.staff_id]}</span>}
          {a.party_size && <span>· party of {a.party_size}</span>}
          {column === "waiting" && <Pill tone="success">Waiting {Math.max(0, Math.round((nowMs - new Date(a.checked_in_at).getTime()) / 60000))} min</Pill>}
          {late && <Pill tone="danger">Late</Pill>}
          {column === "done" && <Pill tone={APPT_TONE[a.status]}>{APPT_LABEL[a.status]}</Pill>}
        </div>
        {column === "expected" && (
          <div className="ba-item-actions">
            <button type="button" className="ba-btn sm primary" disabled={busy} onClick={() => run(a.id, () => setCheckIn(a.id, true), `${personName(person) ?? "Guest"} checked in.`)}><Icon name="how_to_reg" size="sm" />Check in</button>
            {person?.phone && <a className="ba-btn sm" href={`tel:${person.phone}`}><Icon name="call" size="sm" />Call</a>}
            <button type="button" className="ba-btn sm" disabled={busy} onClick={() => setMoving(a)}><Icon name="event_repeat" size="sm" />Reschedule</button>
            {late && <button type="button" className="ba-btn sm danger-outline" disabled={busy} onClick={() => setStatus(a, "no_show", `${a.title} marked no-show.`)}>No-show</button>}
          </div>
        )}
        {column === "waiting" && (
          <div className="ba-item-actions">
            <button type="button" className="ba-btn sm primary" disabled={busy} onClick={() => setStatus(a, "completed", `${a.title} marked done.`)}>Mark done</button>
            <button type="button" className="ba-btn sm" disabled={busy} onClick={() => run(a.id, () => setCheckIn(a.id, false), "Check-in undone.")}>Undo</button>
          </div>
        )}
      </article>
    );
  };

  const Column = ({ title, icon, items, column, emptyText }) => (
    <section className="ba-panel">
      <div className="ba-panel-head"><div className="ba-panel-title"><span className="ba-kpi-icon indigo"><Icon name={icon} size="sm" /></span><div><h2>{title}</h2><p>{plural(items.length, "person", "people")}</p></div></div></div>
      <div className="ba-panel-body">{items.length ? items.map((a) => <Card key={a.id} a={a} column={column} />) : <Empty>{emptyText}</Empty>}</div>
    </section>
  );

  return (
    <>
      <PageHead crumb="Core / Check-ins" title="Check-ins" sub={`Who has arrived, who is still expected, and who is done today (${tz.replace("_", " ")}).`}>
        <button type="button" className="ba-btn primary" onClick={() => setWalkIn(true)}><Icon name="directions_walk" size="sm" /><span>Add walk-in</span></button>
      </PageHead>
      <Notice error={error} onRetry={reload} />
      {loading && !data ? <p className="ba-muted">Loading…</p> : (
        <div className="ba-columns">
          <Column title="Waiting now" icon="hourglass_top" items={waiting} column="waiting" emptyText="Nobody has checked in yet." />
          <Column title="Expected" icon="schedule" items={expected} column="expected" emptyText={`No more ${term("appointments").toLowerCase()} expected today.`} />
          <Column title="Done today" icon="task_alt" items={done} column="done" emptyText="Nothing finished yet." />
        </div>
      )}
      {moving && (
        <RescheduleModal
          workspace={workspace}
          term={term}
          appt={moving}
          person={data?.people?.[moving.customer_id]}
          onClose={() => setMoving(null)}
          onSaved={(message) => { setMoving(null); onNotice(message); reload(); onChanged?.(); }}
        />
      )}
      {walkIn && (
        <WalkInModal
          workspace={workspace}
          staff={data?.staff ?? []}
          hospitality={hospitality}
          onClose={() => setWalkIn(false)}
          onSaved={(message) => { setWalkIn(false); onNotice(message); reload(); onChanged?.(); }}
        />
      )}
    </>
  );
}

/* ---------------------------------------------------------------- */
/* Unified inbox                                                     */
/* ---------------------------------------------------------------- */

export function InboxPage({ workspace, refreshKey, onOpenPerson }) {
  const tz = workspace.timezone;
  const [filter, setFilter] = useState("all");
  const { data, error, loading, reload } = useLoad(async () => {
    const [calls, convos] = await Promise.all([
      supabase.from("calls").select("*").eq("business_id", workspace.id).order("created_at", { ascending: false }).limit(100),
      supabase.from("conversations").select("*").eq("business_id", workspace.id).order("last_message_at", { ascending: false, nullsFirst: false }).limit(100),
    ]);
    const c = orThrow(calls);
    const v = orThrow(convos);
    return { items: [
      ...c.map((x) => ({ key: `c${x.id}`, kind: "call", at: x.created_at, customer_id: x.customer_id, call: x })),
      ...v.map((x) => ({ key: `v${x.id}`, kind: "convo", at: x.last_message_at ?? x.created_at, customer_id: x.customer_id, convo: x })),
    ].filter((i) => i.at).sort((a, b) => new Date(b.at) - new Date(a.at)),
    people: await loadPeople([...c, ...v].map((x) => x.customer_id)) };
  }, [workspace.id, refreshKey]);

  const rows = (data?.items ?? []).filter((i) =>
    filter === "calls" ? i.kind === "call" : filter === "messages" ? i.kind === "convo"
      : filter === "human" ? i.kind === "call" && isOpenEscalation(i.call)
        : filter === "missed" ? i.kind === "call" && i.call.status === "missed" : true);

  return (
    <>
      <PageHead crumb="Communications / Unified Inbox" title="Unified inbox" sub="Every call, text and email in one list, newest first.">
        <Segment label="Inbox filter" value={filter} onChange={setFilter} options={[["all", "All"], ["calls", "Calls"], ["messages", "Messages"], ["missed", "Missed"], ["human", "Needs a human"]]} />
      </PageHead>
      <Notice error={error} onRetry={reload} />
      <section className="ba-panel">
        {loading && !data ? <div className="ba-panel-body"><p className="ba-muted">Loading…</p></div> : !rows.length ? (
          <div className="ba-panel-body"><Empty title="Nothing here yet">Calls and messages appear as soon as your phone line and messaging are live.</Empty></div>
        ) : (
          <ul className="ba-threads">
            {rows.slice(0, 150).map((i) => {
              const person = data.people[i.customer_id];
              const isCall = i.kind === "call";
              const missed = isCall && i.call.status === "missed";
              return (
                <li key={i.key}>
                  <span className={`ba-thread-icon ${missed ? "bad" : ""}`}><Icon name={isCall ? (missed ? "phone_missed" : "call") : "chat"} size="sm" /></span>
                  <div>
                    <NameButton person={person} fallback={isCall ? i.call.from_number ?? "Unknown caller" : "Unknown contact"} onOpenPerson={onOpenPerson} />
                    <small>
                      {isCall
                        ? `${missed ? "Missed call" : `${i.call.ai_handled ? "AI answered" : "Team answered"} · ${clock(i.call.duration_seconds)}`}${i.call.summary ? ` · ${i.call.summary}` : ""}`
                        : `${i.convo.channel ?? "Message"}${i.convo.subject ? `: ${i.convo.subject}` : ""}`}
                    </small>
                  </div>
                  <div className="ba-thread-meta">
                    {isCall && isOpenEscalation(i.call) && <Pill tone="danger">Needs a human</Pill>}
                    {isCall && i.call.recording_url && <Icon name="graphic_eq" size="sm" />}
                    {!isCall && <Pill tone={i.convo.status === "open" ? "warning" : ""}>{i.convo.status}</Pill>}
                    <span title={`${formatDay(i.at, tz)} ${formatTime(i.at, tz)}`}>{timeAgo(i.at)}</span>
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </section>
    </>
  );
}

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
      <PageHead crumb="Communications / Lead sources" title="Lead sources" sub={`Where new ${term("customers").toLowerCase()} come from, and how many became bookings.`}>
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
      supabase.from("calls").select("*").eq("business_id", workspace.id).gte("created_at", sinceIso).limit(5000),
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
    const answered = data.calls.filter((c) => c.status !== "missed");
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
      <PageHead crumb="Management / Reports" title="Reports" sub={`How ${workspace.name} is doing. Every figure comes from your own records.`}>
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
    </>
  );
}

/* ---------------------------------------------------------------- */
/* Integrations                                                      */
/* ---------------------------------------------------------------- */

const CATALOG = [
  { match: ["telnyx"], icon: "call", name: "Phone line", text: "Your business number, new or forwarded to Zella." },
  { match: ["vapi"], icon: "record_voice_over", name: "Voice assistant", text: "The AI receptionist that answers your calls." },
  { match: ["google_calendar", "google"], icon: "calendar_month", name: "Google Calendar", text: "Keeps bookings and your calendar in sync." },
  { match: ["outlook", "microsoft"], icon: "event", name: "Outlook Calendar", text: "Keeps bookings and your calendar in sync." },
  { match: ["meta", "facebook", "instagram"], icon: "campaign", name: "Facebook and Instagram", text: "Brings in leads from your ads and messages." },
  { match: ["website", "form", "web"], icon: "language", name: "Website forms", text: "Sends website enquiries straight into your leads." },
];

export function IntegrationsPage({ workspace, refreshKey }) {
  const { data, error, loading, reload } = useLoad(async () =>
    orThrow(await supabase.from("integrations").select("*").eq("business_id", workspace.id)), [workspace.id, refreshKey]);
  const rowFor = (item) => (data ?? []).find((r) => item.match.some((m) => (r.provider ?? "").toLowerCase().includes(m)));
  return (
    <>
      <PageHead crumb="Management / Integrations" title="Integrations" sub="The services connected to your workspace. Zella connects these for you." />
      <Notice error={error} onRetry={reload} />
      <div className="ba-grid-2">
        {CATALOG.map((item) => {
          const row = rowFor(item);
          const connected = row?.status === "active";
          return (
            <section key={item.name} className="ba-panel ba-integration">
              <span className="ba-thread-icon"><Icon name={item.icon} size="sm" /></span>
              <div><strong>{item.name}</strong><small>{item.text}</small></div>
              <Pill tone={connected ? "success" : row ? "warning" : ""} dot={connected}>
                {loading && !data ? "…" : connected ? "Connected" : row ? row.status.replace(/_/g, " ") : "Not connected"}
              </Pill>
            </section>
          );
        })}
      </div>
      <p className="ba-muted ba-gap">Want one connected? Ask the Zella team and it will be set up for you.</p>
    </>
  );
}
