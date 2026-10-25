import { useCallback, useEffect, useState } from "react";
import { supabase } from "./supabase";
import { Icon, Pill, personName } from "./BusinessUI";
import { makeTerm, receptionistState } from "./businessWorkspace";
import { useRoster } from "./BusinessLeads";
import TodayWelcome from "./TodayWelcome";
import { CountUp } from "./CrmMotion";
import { welcomeStyle, zellaNote } from "./todayGreeting";
import { dayRange, formatLongDate, formatTime, greeting, timeAgo } from "./businessTime";
import { friendly, noShowNotice, setCheckIn } from "./BusinessShared";
import { RescheduleModal } from "./BusinessForms";

// Today dashboard (Stitch design), built only from real records. Everything is
// read with the member's own session, so Row Level Security returns this
// business's data only. Where Zella has no data yet, it says so.

const RANGES = [
  ["today", "Today"],
  ["yesterday", "Yesterday"],
  ["week", "Last 7 days"],
];

const SOURCE_LABELS = {
  manual: "Team", phone: "Phone", walk_in: "Walk-in", website: "Website", google: "Google",
  meta: "Meta", referral: "Referral", call: "Call", voice: "Voice AI", other: "Other",
};

const APPT_TONE = { scheduled: "warning", confirmed: "success", completed: "info", cancelled: "", no_show: "danger" };
const APPT_LABEL = { scheduled: "Scheduled", confirmed: "Confirmed", completed: "Completed", cancelled: "Cancelled", no_show: "No-show" };

function rangeBounds(range, tz) {
  if (range === "yesterday") return dayRange(tz, -1);
  if (range === "week") return { start: dayRange(tz, -6).start, end: dayRange(tz, 0).end };
  return dayRange(tz, 0);
}

function plural(n, word) {
  return `${n} ${word}${n === 1 ? "" : "s"}`;
}

function duration(seconds) {
  if (!seconds && seconds !== 0) return "—";
  return `${Math.floor(seconds / 60)}:${String(Math.round(seconds % 60)).padStart(2, "0")}`;
}

function Kpi({ label, icon, color, value, children }) {
  return (
    <div className="ba-kpi">
      <div className="ba-kpi-top">
        <span>{label}</span>
        <span className={`ba-kpi-icon ${color}`}><Icon name={icon} size="sm" /></span>
      </div>
      <div className="ba-kpi-value"><CountUp value={value} /></div>
      {children}
    </div>
  );
}

function Panel({ icon, color, title, subtitle, action, tabs, children, foot }) {
  return (
    <section className="ba-panel">
      <div className="ba-panel-head">
        <div className="ba-panel-title">
          <span className={`ba-kpi-icon ${color}`}><Icon name={icon} size="sm" /></span>
          <div>
            <h2>{title}</h2>
            {subtitle && <p>{subtitle}</p>}
          </div>
        </div>
        {action}
      </div>
      {tabs}
      <div className="ba-panel-body">{children}</div>
      {foot && <div className="ba-panel-foot">{foot}</div>}
    </section>
  );
}

function Empty({ title, children }) {
  return (
    <div className="ba-empty">
      {title && <strong>{title}</strong>}
      {children}
    </div>
  );
}

export default function BusinessToday({ workspace, userId, fallbackName, onAddLead, onBook, onNotice, onOpenPerson }) {
  const tz = workspace.timezone;
  const roster = useRoster(workspace);
  const known = (n) => (n && n !== "Team member" ? n : "");
  const firstName = String(known(roster.nameOf[userId]) || fallbackName || "").trim().split(/\s+/)[0];
  const owner = known(roster.list.find((m) => m.role === "owner")?.name);
  const [style] = useState(() => welcomeStyle());
  const term = makeTerm(workspace);
  const agent = receptionistState(workspace);
  const [range, setRange] = useState("today");
  const [tab, setTab] = useState("leads");
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [working, setWorking] = useState(null);
  const [moving, setMoving] = useState(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    const id = workspace.id;
    const bounds = rangeBounds(range, tz);
    const today = dayRange(tz, 0);
    const weekStart = dayRange(tz, -6).start;
    const head = { count: "exact", head: true };

    try {
      const results = await Promise.all([
        supabase.from("appointments")
          .select("*")
          .eq("business_id", id)
          .gte("start_time", today.start.toISOString())
          .lt("start_time", today.end.toISOString())
          .order("start_time"),
        supabase.from("customers")
          .select("id, first_name, last_name, company_name, phone, email, source, notes, last_contacted_at, created_at")
          .eq("business_id", id)
          .gte("created_at", bounds.start.toISOString())
          .lt("created_at", bounds.end.toISOString())
          .order("created_at", { ascending: false })
          .limit(500),
        supabase.from("calls_view")
          .select("id, status, ai_handled, duration_seconds, from_number, customer_id, created_at, metadata")
          .eq("business_id", id)
          .gte("created_at", bounds.start.toISOString())
          .lt("created_at", bounds.end.toISOString())
          .order("created_at", { ascending: false })
          .limit(500),
        supabase.from("appointments").select("id", head)
          .eq("business_id", id)
          .eq("status", "no_show")
          .gte("start_time", weekStart.toISOString()),
        supabase.from("conversations")
          .select("id, subject, channel, status, last_message_at, customer_id, ai_handled")
          .eq("business_id", id)
          .in("status", ["open", "pending"])
          .order("last_message_at", { ascending: false, nullsFirst: false })
          .limit(20),
        supabase.from("calls_view")
          .select("id, direction, status, ai_handled, duration_seconds, from_number, customer_id, created_at, transcript, metadata")
          .eq("business_id", id)
          .order("created_at", { ascending: false })
          .limit(1),
        supabase.from("automations")
          .select("id, name, status, trigger_type")
          .eq("business_id", id)
          .neq("status", "disabled")
          .order("name"),
      ]);

      const failed = results.find((r) => r.error);
      if (failed) throw failed.error;
      const [appointments, leads, calls, noShows, conversations, lastCall, automations] = results;

      // Names for customers referenced by appointments, calls and conversations.
      const ids = [...new Set([
        ...(appointments.data ?? []).map((a) => a.customer_id),
        ...(calls.data ?? []).map((c) => c.customer_id),
        ...(conversations.data ?? []).map((c) => c.customer_id),
        ...(lastCall.data ?? []).map((c) => c.customer_id),
      ].filter(Boolean))];

      let people = {};
      if (ids.length) {
        const { data: rows, error: peopleError } = await supabase
          .from("customers")
          .select("id, first_name, last_name, company_name, phone")
          .in("id", ids);
        if (peopleError) throw peopleError;
        people = Object.fromEntries((rows ?? []).map((p) => [p.id, p]));
      }

      const callRows = calls.data ?? [];
      const answeredWithTime = callRows.filter((c) => c.duration_seconds);
      const missed = callRows.filter((c) => c.status === "missed");
      const missedOpen = missed.filter((c) => !c.metadata?.followed_up_at);
      const leadRows = leads.data ?? [];
      const sourceCounts = {};
      for (const lead of leadRows) {
        const key = lead.source || "other";
        sourceCounts[key] = (sourceCounts[key] ?? 0) + 1;
      }

      setData({
        appointments: (appointments.data ?? []).map((a) => ({ ...a, customer: people[a.customer_id] })),
        leads: leadRows,
        sources: Object.entries(sourceCounts).sort((a, b) => b[1] - a[1]),
        uncontacted: leadRows.filter((l) => !l.last_contacted_at),
        aiCalls: callRows.filter((c) => c.ai_handled).length,
        totalCalls: callRows.length,
        avgDuration: answeredWithTime.length
          ? answeredWithTime.reduce((sum, c) => sum + c.duration_seconds, 0) / answeredWithTime.length
          : null,
        missed: missed.map((c) => ({ ...c, customer: people[c.customer_id] })),
        missedOpen: missedOpen.map((c) => ({ ...c, customer: people[c.customer_id] })),
        noShows: noShows.count ?? 0,
        conversations: (conversations.data ?? []).map((c) => ({ ...c, customer: people[c.customer_id] })),
        lastCall: lastCall.data?.[0] ? { ...lastCall.data[0], customer: people[lastCall.data[0].customer_id] } : null,
        automations: automations.data ?? [],
        loadedAt: new Date(),
      });
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }, [workspace.id, range, tz]);

  useEffect(() => {
    load();
  }, [load]);

  async function act(key, run, message) {
    setWorking(key);
    setError("");
    const { error: actError } = await run();
    setWorking(null);
    if (actError) {
      setError(friendly(actError));
      return;
    }
    if (message) onNotice(message);
    load();
  }

  async function markNoShow(appt) {
    setWorking(`appt-${appt.id}`);
    setError("");
    const { error: updateError } = await supabase.from("appointments")
      .update({ status: "no_show", updated_at: new Date().toISOString() }).eq("id", appt.id);
    if (updateError) {
      setWorking(null);
      setError(friendly(updateError));
      return;
    }
    const message = await noShowNotice(appt.id, personName(appt.customer) ?? appt.title, tz);
    setWorking(null);
    onNotice(message);
    load();
  }

  const setAppointment = (appt, status) => status === "no_show"
    ? markNoShow(appt)
    : act(`appt-${appt.id}`, () => supabase.from("appointments")
      .update({ status, updated_at: new Date().toISOString() })
      .eq("id", appt.id), `${appt.title} marked ${APPT_LABEL[status].toLowerCase()}.`);

  const toggleCheckIn = (appt) =>
    act(`appt-${appt.id}`, () => setCheckIn(appt.id, !appt.checked_in_at),
      appt.checked_in_at ? "Check-in undone." : `${personName(appt.customer) ?? appt.title} checked in.`);

  const nameLink = (id, label) => (id && onOpenPerson
    ? <button type="button" className="ba-namebtn" onClick={() => onOpenPerson(id)}>{label}</button>
    : <span>{label}</span>);

  const markContacted = (lead) =>
    act(`lead-${lead.id}`, () => supabase.from("customers")
      .update({ last_contacted_at: new Date().toISOString(), updated_at: new Date().toISOString() })
      .eq("id", lead.id), `${personName(lead) ?? "Lead"} marked as contacted.`);

  const markCalledBack = (call) =>
    act(`call-${call.id}`, () => supabase.from("calls")
      .update({ metadata: { ...(call.metadata ?? {}), followed_up_at: new Date().toISOString() }, updated_at: new Date().toISOString() })
      .eq("id", call.id), "Missed call marked as followed up.");

  const show = (v) => (loading && !data ? "…" : v);
  const appts = data?.appointments ?? [];
  const activeAppts = appts.filter((a) => a.status !== "cancelled");
  const counts = Object.fromEntries(Object.keys(APPT_LABEL).map((k) => [k, appts.filter((a) => a.status === k).length]));
  const now = Date.now();
  const recovery = (data?.noShows ?? 0) + (data?.missedOpen?.length ?? 0) + (data?.uncontacted?.length ?? 0);
  const rangeLabel = RANGES.find(([k]) => k === range)[1].toLowerCase();
  const pct = (n) => (activeAppts.length ? `${(n / activeAppts.length) * 100}%` : "0%");

  const nextAppt = activeAppts.find((a) => new Date(a.start_time).getTime() > now);
  const note = zellaNote({
    loaded: Boolean(data), live: agent.live, missedOpen: data?.missedOpen?.length ?? 0, uncontacted: data?.uncontacted?.length ?? 0,
    waiting: data?.conversations?.length ?? 0, appointments: activeAppts.length, nextTime: nextAppt ? formatTime(nextAppt.start_time, tz) : "",
    aiCalls: data?.aiCalls ?? 0, rangeLabel,
  });

  return (
    <>
      <TodayWelcome
        heading={style ? `Welcome back${firstName ? `, ${firstName}` : ""}.` : `${greeting(tz)}${firstName ? `, ${firstName}` : ""}.`}
        business={workspace.name} owner={owner} note={note} partOfDay={greeting(tz).replace("Good ", "")}
        date={`${formatLongDate(new Date(), tz)} (${tz.replace("_", " ")})`}
      />
      <div className="ba-page-head">
        <div>
          <div className="ba-crumb">Core / Today</div>
        </div>
        <div className="ba-page-actions">
          <div className="ba-segment" role="tablist" aria-label="Time range">
            {RANGES.map(([key, label]) => (
              <button key={key} type="button" role="tab" aria-selected={range === key} className={range === key ? "active" : ""} onClick={() => setRange(key)}>
                {label}
              </button>
            ))}
          </div>
          <button type="button" className="ba-btn" onClick={load} disabled={loading} title="Refresh">
            <Icon name="refresh" size="sm" />
          </button>
        </div>
      </div>

      {error && <div className="ba-banner error">Couldn't load everything: {error}</div>}

      <div className="ba-kpis">
        <Kpi label={`New leads ${rangeLabel}`} icon="group_add" color="indigo" value={show(data?.leads?.length ?? 0)}>
          <div className="ba-kpi-note">
            {data?.sources?.length
              ? data.sources.slice(0, 3).map(([s, n]) => `${n} ${SOURCE_LABELS[s] ?? s}`).join(" · ")
              : "No new leads yet"}
          </div>
        </Kpi>
        <Kpi label="AI-answered calls" icon="smart_toy" color="amber" value={show(data?.aiCalls ?? 0)}>
          <div className="ba-kpi-note">
            {data?.totalCalls
              ? `${data.totalCalls} calls · ${data.missed.length} missed · avg ${duration(data.avgDuration)}`
              : agent.live ? "No calls yet" : "Starts when your AI receptionist goes live"}
          </div>
        </Kpi>
        <Kpi label={`${term("appointments")} today`} icon="calendar_month" color="blue" value={show(activeAppts.length)}>
          <div className="ba-kpi-note">
            {counts.completed} done · {counts.confirmed} confirmed · {counts.scheduled} scheduled{counts.no_show ? ` · ${counts.no_show} no-show` : ""}
          </div>
          <div className="ba-bar" aria-hidden="true">
            <span className="done" style={{ width: pct(counts.completed) }} />
            <span className="confirmed" style={{ width: pct(counts.confirmed) }} />
            <span className="scheduled" style={{ width: pct(counts.scheduled) }} />
            <span className="noshow" style={{ width: pct(counts.no_show) }} />
          </div>
        </Kpi>
        <Kpi label="Missed calls" icon="phone_missed" color="rose" value={show(data?.missedOpen?.length ?? 0)}>
          <div className="ba-kpi-note">
            {data?.missed?.length ? `${data.missed.length} missed ${rangeLabel} · ${data.missedOpen.length} still to call back` : `None ${rangeLabel}`}
          </div>
        </Kpi>
        <Kpi label="Recovery queue" icon="restart_alt" color="violet" value={show(recovery)}>
          <div className="ba-kpi-note">
            {data ? `${plural(data.noShows, "no-show")} (7 days) · ${plural(data.missedOpen.length, "missed call")} · ${plural(data.uncontacted.length, "lead")} not contacted` : ""}
          </div>
        </Kpi>
        <Kpi label="Open conversations" icon="forum" color="green" value={show(data?.conversations?.length ?? 0)}>
          <div className="ba-kpi-note">{data?.conversations?.length ? "Waiting on a reply or follow-up" : "Nothing waiting"}</div>
        </Kpi>
      </div>

      <div className="ba-columns">
        {/* Column 1: today's schedule */}
        <Panel
          icon="event_available"
          color="blue"
          title={`Today's ${term("appointments").toLowerCase()}`}
          subtitle={formatLongDate(new Date(), tz)}
          action={<button type="button" className="ba-btn primary sm" onClick={onBook}><Icon name="add" size="sm" />Book</button>}
          foot={<><span>{counts.completed} completed today</span><span>{plural(counts.no_show, "no-show")}</span></>}
        >
          {appts.length ? appts.map((a) => {
            const late = ["scheduled", "confirmed"].includes(a.status) && new Date(a.start_time).getTime() < now;
            const name = personName(a.customer);
            const busy = working === `appt-${a.id}`;
            return (
              <article key={a.id} className={`ba-item ${late ? "alert" : ""} ${a.status === "cancelled" ? "muted" : ""}`}>
                <div className="ba-item-top">
                  <div className="ba-item-name">
                    <span className="ba-dot" style={{ color: late ? "var(--ba-danger)" : a.status === "confirmed" ? "var(--ba-success)" : "var(--ba-warning)" }} />
                    {nameLink(a.customer?.id, name ?? a.title)}
                  </div>
                  <span className="ba-item-time">{formatTime(a.start_time, tz)}</span>
                </div>
                <div className="ba-item-meta">
                  <span>{name ? a.title : `No ${term("customer").toLowerCase()} linked`}</span>
                  {a.location && <span>· {a.location}</span>}
                  <Pill tone={late ? "danger" : APPT_TONE[a.status]}>{late ? "Running late" : APPT_LABEL[a.status]}</Pill>
                  {a.checked_in_at && <Pill tone="success">Arrived {formatTime(a.checked_in_at, tz)}</Pill>}
                </div>
                {["scheduled", "confirmed"].includes(a.status) && (
                  <div className="ba-item-actions">
                    <button type="button" className={`ba-btn sm ${a.checked_in_at ? "" : "primary"}`} disabled={busy} onClick={() => toggleCheckIn(a)}>
                      <Icon name={a.checked_in_at ? "undo" : "how_to_reg"} size="sm" />{a.checked_in_at ? "Undo check-in" : "Check in"}
                    </button>
                    {a.status === "scheduled" && !late && (
                      <button type="button" className="ba-btn sm" disabled={busy} onClick={() => setAppointment(a, "confirmed")}>Confirm</button>
                    )}
                    <button type="button" className="ba-btn sm" disabled={busy} onClick={() => setAppointment(a, "completed")}>Mark done</button>
                    <button type="button" className="ba-btn sm" disabled={busy} onClick={() => setMoving(a)}><Icon name="event_repeat" size="sm" />Reschedule</button>
                    {late && (
                      <button type="button" className="ba-btn sm danger-outline" disabled={busy} onClick={() => setAppointment(a, "no_show")}>No-show</button>
                    )}
                    {a.customer?.phone && <a className="ba-btn sm" href={`tel:${a.customer.phone}`}><Icon name="call" size="sm" />Call</a>}
                  </div>
                )}
              </article>
            );
          }) : (
            <Empty title={loading && !data ? "Loading..." : `No ${term("appointments").toLowerCase()} today`}>
              {!loading && "Book one from the button above."}
            </Empty>
          )}
        </Panel>

        {/* Column 2: leads, missed calls, inbox */}
        <Panel
          icon="bolt"
          color="indigo"
          title="Follow-ups"
          subtitle="Who to contact next"
          action={<button type="button" className="ba-btn sm" onClick={onAddLead}><Icon name="person_add" size="sm" />Lead</button>}
          tabs={
            <div className="ba-panel-tabs">
              <div className="ba-segment" role="tablist">
                {[
                  ["leads", `New leads (${data?.uncontacted?.length ?? 0})`],
                  ["missed", `Missed calls (${data?.missedOpen?.length ?? 0})`],
                  ["inbox", `Inbox (${data?.conversations?.length ?? 0})`],
                ].map(([key, label]) => (
                  <button key={key} type="button" role="tab" aria-selected={tab === key} className={tab === key ? "active" : ""} onClick={() => setTab(key)}>
                    {label}
                  </button>
                ))}
              </div>
            </div>
          }
        >
          {tab === "leads" && (data?.leads?.length ? data.leads.slice(0, 12).map((lead) => {
            const contacted = Boolean(lead.last_contacted_at);
            const busy = working === `lead-${lead.id}`;
            return (
              <article key={lead.id} className="ba-item">
                <div className="ba-item-top">
                  <div className="ba-item-name">
                    {lead.source && <Pill tone="indigo">{SOURCE_LABELS[lead.source] ?? lead.source}</Pill>}
                    {nameLink(lead.id, personName(lead) ?? lead.phone ?? lead.email ?? "Unnamed lead")}
                  </div>
                  <Pill tone={contacted ? "success" : "warning"}>{contacted ? "Contacted" : "Needs contact"}</Pill>
                </div>
                {lead.notes && <p className="ba-item-text">{lead.notes.length > 160 ? `${lead.notes.slice(0, 160)}…` : lead.notes}</p>}
                <div className="ba-item-meta">
                  <span>{[lead.phone, lead.email].filter(Boolean).join(" · ") || "No contact details"}</span>
                  <span>· {timeAgo(lead.created_at)}</span>
                </div>
                <div className="ba-item-actions">
                  {lead.phone && <a className="ba-btn sm primary" href={`tel:${lead.phone}`}><Icon name="call" size="sm" />Call</a>}
                  {lead.email && <a className="ba-btn sm" href={`mailto:${lead.email}`}><Icon name="mail" size="sm" />Email</a>}
                  {!contacted && <button type="button" className="ba-btn sm" disabled={busy} onClick={() => markContacted(lead)}>Mark contacted</button>}
                </div>
              </article>
            );
          }) : (
            <Empty title={loading && !data ? "Loading..." : `No new leads ${rangeLabel}`}>
              {!loading && "Leads from calls, your website and ads appear here once those are connected."}
            </Empty>
          ))}

          {tab === "missed" && (data?.missed?.length ? data.missed.map((call) => {
            const done = Boolean(call.metadata?.followed_up_at);
            const busy = working === `call-${call.id}`;
            return (
              <article key={call.id} className={`ba-item ${done ? "muted" : ""}`}>
                <div className="ba-item-top">
                  <div className="ba-item-name">
                    <Icon name="phone_missed" size="sm" />
                    {nameLink(call.customer?.id, personName(call.customer) ?? call.from_number ?? "Unknown caller")}
                  </div>
                  <span className="ba-item-time">{timeAgo(call.created_at)}</span>
                </div>
                <div className="ba-item-meta">
                  {personName(call.customer) && call.from_number && <span>{call.from_number}</span>}
                  <Pill tone={done ? "success" : "danger"}>{done ? "Followed up" : "Call back"}</Pill>
                </div>
                {!done && (
                  <div className="ba-item-actions">
                    {call.from_number && <a className="ba-btn sm primary" href={`tel:${call.from_number}`}><Icon name="call" size="sm" />Call back</a>}
                    <button type="button" className="ba-btn sm" disabled={busy} onClick={() => markCalledBack(call)}>Mark done</button>
                  </div>
                )}
              </article>
            );
          }) : (
            <Empty title={loading && !data ? "Loading..." : `No missed calls ${rangeLabel}`}>
              {!loading && !agent.live && "Calls are recorded once your phone line is connected."}
            </Empty>
          ))}

          {tab === "inbox" && (data?.conversations?.length ? data.conversations.map((c) => (
            <article key={c.id} className="ba-item">
              <div className="ba-item-top">
                <div className="ba-item-name">
                  <Pill tone="indigo">{c.channel}</Pill>
                  {nameLink(c.customer?.id, personName(c.customer) ?? c.subject ?? "Conversation")}
                </div>
                <span className="ba-item-time">{timeAgo(c.last_message_at)}</span>
              </div>
              <div className="ba-item-meta">
                {c.subject && <span>{c.subject}</span>}
                <Pill tone={c.status === "pending" ? "warning" : "info"}>{c.status}</Pill>
                {c.ai_handled && <Pill tone="violet">AI</Pill>}
              </div>
            </article>
          )) : (
            <Empty title={loading && !data ? "Loading..." : "Inbox is clear"}>
              {!loading && "Texts, emails and chats that need a reply show up here."}
            </Empty>
          ))}
        </Panel>

        {/* Column 3: AI receptionist */}
        <Panel
          icon="record_voice_over"
          color="green"
          title="Voice receptionist"
          subtitle={workspace.receptionist?.name ?? "AI receptionist"}
          action={<Pill tone={agent.tone} dot={agent.live} pulse={agent.live}>{agent.label}</Pill>}
        >
          <div className="ba-status-row">
            <span>Phone line</span>
            <Pill tone={workspace.phone_connected ? "success" : ""}>{workspace.phone_connected ? "Connected" : "Not connected"}</Pill>
          </div>
          <div className="ba-status-row">
            <span>Voice agent</span>
            <Pill tone={workspace.voice_connected ? "success" : ""}>{workspace.voice_connected ? "Connected" : "Not connected"}</Pill>
          </div>

          <div className="ba-section-label">Last call</div>
          {data?.lastCall ? (
            <article className="ba-item">
              <div className="ba-item-top">
                <div className="ba-item-name">
                  <Icon name={data.lastCall.direction === "outbound" ? "call_made" : "call_received"} size="sm" />
                  <span>{personName(data.lastCall.customer) ?? data.lastCall.from_number ?? "Caller"}</span>
                </div>
                <span className="ba-item-time">{timeAgo(data.lastCall.created_at)} · {duration(data.lastCall.duration_seconds)}</span>
              </div>
              {(data.lastCall.metadata?.summary || data.lastCall.transcript) && (
                <p className="ba-quote">
                  {(data.lastCall.metadata?.summary || data.lastCall.transcript).slice(0, 320)}
                  {(data.lastCall.metadata?.summary || data.lastCall.transcript).length > 320 ? "…" : ""}
                </p>
              )}
              <div className="ba-item-meta">
                <Pill tone={data.lastCall.status === "missed" ? "danger" : "success"}>{data.lastCall.status}</Pill>
                {data.lastCall.ai_handled && <Pill tone="violet">Handled by AI</Pill>}
              </div>
            </article>
          ) : (
            <Empty>{loading && !data ? "Loading..." : "No calls yet. Your receptionist's calls and summaries will appear here."}</Empty>
          )}

          <div className="ba-section-label">Automations</div>
          {data?.automations?.length ? data.automations.map((a) => (
            <div key={a.id} className="ba-status-row">
              <span>{a.name}</span>
              <Pill tone={a.status === "active" ? "success" : "warning"} dot={a.status === "active"}>
                {a.status === "active" ? "Running" : "Paused"}
              </Pill>
            </div>
          )) : (
            <Empty>{loading && !data ? "Loading..." : "No automations turned on."}</Empty>
          )}
        </Panel>
      </div>

      <div className="ba-strip">
        <span className={agent.live ? "ok" : "off"}><Icon name="smart_toy" size="sm" /><strong>AI receptionist:</strong> {agent.label}</span>
        <span className={workspace.phone_connected ? "ok" : "off"}><Icon name="call" size="sm" /><strong>Phone:</strong> {workspace.phone_connected ? "Connected" : "Not connected"}</span>
        <span><Icon name="schedule" size="sm" /><strong>Updated:</strong> {data ? timeAgo(data.loadedAt) : "—"}</span>
      </div>

      {moving && (
        <RescheduleModal
          workspace={workspace}
          term={term}
          appt={moving}
          person={moving.customer}
          onClose={() => setMoving(null)}
          onSaved={(message) => { setMoving(null); onNotice(message); load(); }}
        />
      )}
    </>
  );
}
