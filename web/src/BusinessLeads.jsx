import { useEffect, useMemo, useState } from "react";
import { supabase } from "./supabase";
import { Field, Icon, Modal, Pill, initials, personName } from "./BusinessUI";
import { formatDay, formatTime, timeAgo, todayInput, zonedDateTime } from "./businessTime";
import { makeTerm } from "./businessWorkspace";
import { Empty, Notice, PAGE_SIZE, PageHead, Pager, Segment, clock, explain, orThrow, useLoad } from "./BusinessShared";

/* The lead pipeline: a board by status, or a list, with who owns each lead and
   when the next follow-up is due. Details open in a panel so this page stays calm. */

const when = (value, tz) => (value ? `${formatDay(value, tz)} · ${formatTime(value, tz)}` : "—");
const PRIORITY_TONE = { urgent: "danger", high: "warning", normal: "" };
const PRIORITY_LABEL = { urgent: "Urgent", high: "High", normal: "Normal" };

// The five statuses people think in. The database keeps a few finer ones.
export const COLUMNS = [
  { key: "new", label: "New", stages: ["new"], set: "new" },
  { key: "contacted", label: "Contacted", stages: ["contacted"], set: "contacted" },
  { key: "qualified", label: "Qualified", stages: ["qualified", "quote_sent"], set: "qualified" },
  { key: "converted", label: "Converted", stages: ["won"], set: "won" },
  { key: "lost", label: "Lost", stages: ["lost", "unqualified"], set: "lost" },
];
const CLOSED = ["won", "lost", "unqualified"];

export const SOURCE_GROUPS = [
  ["ai_call", "AI call"], ["website", "Website"], ["referral", "Referral"], ["manual", "Manual entry"],
];
export function sourceGroup(source) {
  const s = (source ?? "").toLowerCase();
  if (/call|phone|voice|ai|receptionist/.test(s)) return "ai_call";
  if (/web|form|site|online|chat/.test(s)) return "website";
  if (/refer/.test(s)) return "referral";
  return "manual";
}
const sourceName = (source) => SOURCE_GROUPS.find(([k]) => k === sourceGroup(source))[1];

// A lead is anyone with a lead status, plus recent people who were never given one.
export function leadStage(p) {
  if (p.lead_stage) return p.lead_stage;
  return p.last_contacted_at ? "contacted" : "new";
}
const isLead = (p) => Boolean(p.lead_stage) || Date.now() - new Date(p.created_at).getTime() < 30 * 86400000;
export function isOverdue(p, now = Date.now()) {
  const stage = leadStage(p);
  if (CLOSED.includes(stage)) return false;
  if (p.next_follow_up_at && new Date(p.next_follow_up_at).getTime() < now) return true;
  return stage === "new" && p.contact_deadline_at && new Date(p.contact_deadline_at).getTime() < now;
}

export function useRoster(workspace) {
  const { data } = useLoad(async () => {
    const res = await supabase.rpc("zella_team_roster", { p_business_id: workspace.id });
    return res.error || !Array.isArray(res.data) ? [] : res.data;
  }, [workspace.id]);
  const list = data ?? [];
  return { list, nameOf: Object.fromEntries(list.map((m) => [m.user_id, m.name])) };
}

export function Assignee({ id, nameOf }) {
  if (!id) return <span className="ba-muted">Unassigned</span>;
  const name = nameOf[id] ?? "Team member";
  return <span className="ba-assignee"><span className="ba-avatar xs">{initials(name)}</span>{name}</span>;
}

/* ------------------------------------------------------------------ */

function LeadCard({ p, tz, nameOf, onOpen }) {
  const name = personName(p) ?? "Unnamed";
  const over = isOverdue(p);
  return (
    <button type="button" className={`ba-lead ${over ? "overdue" : ""}`} onClick={() => onOpen(p.id)}>
      <span className="ba-lead-top">
        <strong>{name}</strong>
        {p.priority && p.priority !== "normal" && <Pill tone={PRIORITY_TONE[p.priority]}>{PRIORITY_LABEL[p.priority]}</Pill>}
      </span>
      <small>{sourceName(p.source)} · {p.last_contacted_at ? `contacted ${timeAgo(p.last_contacted_at)}` : "not contacted"}</small>
      <span className="ba-lead-foot">
        {over
          ? <span className="ba-flag"><Icon name="schedule" size="sm" />Overdue</span>
          : p.next_follow_up_at ? <span className="ba-muted"><Icon name="event" size="sm" />{formatDay(p.next_follow_up_at, tz)}</span> : <span />}
        <Assignee id={p.assigned_to} nameOf={nameOf} />
      </span>
    </button>
  );
}

export function LeadsPage({ workspace, query, refreshKey, onNotice, onOpenPerson }) {
  const tz = workspace.timezone;
  const [view, setView] = useState("pipeline");
  const [filter, setFilter] = useState("all");
  const [source, setSource] = useState("all");
  const [assignee, setAssignee] = useState("all");
  const [openId, setOpenId] = useState(null);
  const [page, setPage] = useState(0);
  const roster = useRoster(workspace);

  const { data, error, loading, reload } = useLoad(async () =>
    orThrow(await supabase.from("customers").select("*").eq("business_id", workspace.id).order("created_at", { ascending: false }).limit(1000)),
  [workspace.id, refreshKey]);

  const [me, setMe] = useState(null);
  useEffect(() => { supabase.auth.getUser().then(({ data: u }) => setMe(u?.user?.id ?? null)).catch(() => {}); }, []);

  const leads = useMemo(() => {
    const q = (query ?? "").trim().toLowerCase();
    return (data ?? []).filter(isLead).filter((p) => {
      const stage = leadStage(p);
      if (filter === "follow" && (CLOSED.includes(stage) || !(stage === "new" || p.next_follow_up_at || isOverdue(p)))) return false;
      if (filter === "overdue" && !isOverdue(p)) return false;
      if (filter === "mine" && p.assigned_to !== me) return false;
      if (source !== "all" && sourceGroup(p.source) !== source) return false;
      if (assignee === "none" ? p.assigned_to : assignee !== "all" && p.assigned_to !== assignee) return false;
      if (!q) return true;
      return [personName(p), p.phone, p.email, p.company_name].some((v) => v && v.toLowerCase().includes(q));
    });
  }, [data, filter, source, assignee, query, me]);

  const overdueCount = (data ?? []).filter(isLead).filter((p) => isOverdue(p)).length;
  useEffect(() => setPage(0), [filter, source, assignee, query, view]);
  const pages = Math.max(1, Math.ceil(leads.length / PAGE_SIZE));
  const visible = leads.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE);
  const changed = () => reload();

  return (
    <>
      <PageHead crumb="Core / Leads" title="Leads"
        sub={overdueCount ? `${overdueCount} ${overdueCount === 1 ? "lead is" : "leads are"} overdue for a follow-up.` : "Everyone who reached out, by where they are and who is following up."}>
        <Segment label="Lead view" value={view} onChange={setView} options={[["pipeline", "Pipeline"], ["list", "List"]]} />
      </PageHead>

      <Notice error={error} onRetry={reload} />
      <div className="ba-toolbar ba-lead-tools">
        <Segment label="Lead filter" value={filter} onChange={setFilter}
          options={[["all", "All"], ["follow", "Needs follow-up"], ["overdue", `Overdue${overdueCount ? ` (${overdueCount})` : ""}`], ["mine", "Mine"]]} />
        <label className="ba-select"><span>Source</span>
          <select value={source} onChange={(e) => setSource(e.target.value)}>
            <option value="all">All sources</option>
            {SOURCE_GROUPS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}
          </select>
        </label>
        {roster.list.length > 0 && (
          <label className="ba-select"><span>Assigned to</span>
            <select value={assignee} onChange={(e) => setAssignee(e.target.value)}>
              <option value="all">Anyone</option><option value="none">Unassigned</option>
              {roster.list.map((m) => <option key={m.user_id} value={m.user_id}>{m.name}</option>)}
            </select>
          </label>
        )}
      </div>

      {loading && !data ? <p className="ba-muted">Loading…</p> : !leads.length ? (
        <Empty title={query || filter !== "all" || source !== "all" || assignee !== "all" ? "No matches" : "No leads yet"}>
          New leads from calls, your website and the team will appear here.
        </Empty>
      ) : view === "pipeline" ? (
        <div className="ba-board" role="list">
          {COLUMNS.map((col) => {
            const items = leads.filter((p) => col.stages.includes(leadStage(p)));
            return (
              <section key={col.key} className="ba-board-col" role="listitem" aria-label={col.label}>
                <header><strong>{col.label}</strong><span>{items.length}</span></header>
                <div className="ba-board-list">
                  {items.slice(0, 40).map((p) => <LeadCard key={p.id} p={p} tz={tz} nameOf={roster.nameOf} onOpen={setOpenId} />)}
                  {items.length > 40 && <p className="ba-muted">+{items.length - 40} more. Use a filter to narrow down.</p>}
                  {!items.length && <p className="ba-muted ba-board-empty">None</p>}
                </div>
              </section>
            );
          })}
        </div>
      ) : (
        <section className="ba-panel">
          <div className="ba-table-wrap">
            <table className="ba-table">
              <thead><tr><th>Name</th><th>Status</th><th>Source</th><th>Assigned to</th><th>Next follow-up</th><th>Last contact</th><th>Priority</th></tr></thead>
              <tbody>
                {visible.map((p) => {
                  const name = personName(p) ?? "Unnamed";
                  const stage = leadStage(p);
                  const col = COLUMNS.find((c) => c.stages.includes(stage)) ?? COLUMNS[0];
                  return (
                    <tr key={p.id} tabIndex={0} onClick={() => setOpenId(p.id)} onKeyDown={(e) => e.key === "Enter" && setOpenId(p.id)}>
                      <td><div className="ba-person"><div className="ba-avatar sm">{initials(name)}</div><div><strong>{name}</strong><small>{p.phone ?? p.email ?? ""}</small></div></div></td>
                      <td><Pill tone={stage === "won" ? "success" : stage === "lost" || stage === "unqualified" ? "danger" : "warning"}>{stage === "unqualified" ? "Not a fit" : col.label}</Pill></td>
                      <td>{sourceName(p.source)}</td>
                      <td><Assignee id={p.assigned_to} nameOf={roster.nameOf} /></td>
                      <td>{isOverdue(p) ? <span className="ba-flag">Overdue{p.next_follow_up_at ? ` · ${formatDay(p.next_follow_up_at, tz)}` : ""}</span> : p.next_follow_up_at ? when(p.next_follow_up_at, tz) : "—"}</td>
                      <td>{p.last_contacted_at ? timeAgo(p.last_contacted_at) : <span className="ba-flag">Not yet</span>}</td>
                      <td>{p.priority && p.priority !== "normal" ? <Pill tone={PRIORITY_TONE[p.priority]}>{PRIORITY_LABEL[p.priority]}</Pill> : "Normal"}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          <Pager page={page} pages={pages} total={leads.length} onPage={setPage} noun="lead" />
        </section>
      )}

      {openId && (
        <LeadPanel
          key={openId}
          person={(data ?? []).find((p) => p.id === openId)}
          workspace={workspace}
          roster={roster}
          onClose={() => setOpenId(null)}
          onChanged={changed}
          onNotice={onNotice}
          onOpenProfile={(id) => { setOpenId(null); onOpenPerson(id); }}
        />
      )}
    </>
  );
}

/* ------------------------------------------------------------------ */

function LeadPanel({ person, workspace, roster, onClose, onChanged, onNotice, onOpenProfile }) {
  const tz = workspace.timezone;
  const term = makeTerm(workspace);
  const [busy, setBusy] = useState("");
  const [error, setError] = useState("");
  const [note, setNote] = useState("");
  const [lostReason, setLostReason] = useState(null);
  const [plan, setPlan] = useState(() => {
    const d = person?.next_follow_up_at ? new Date(person.next_follow_up_at) : null;
    return {
      assigned: person?.assigned_to ?? "", priority: person?.priority ?? "normal",
      date: d ? d.toLocaleDateString("en-CA", { timeZone: tz }) : "",
      time: d ? d.toLocaleTimeString("en-GB", { timeZone: tz, hour: "2-digit", minute: "2-digit" }) : "09:00",
    };
  });
  const [cb, setCb] = useState({ open: false, date: todayInput(tz), time: "10:00", summary: "" });

  const { data, loading, reload } = useLoad(async () => {
    if (!person) return null;
    const [calls, tasks, cbs] = await Promise.all([
      supabase.from("calls").select("id, status, started_at, created_at, duration_seconds, ai_handled, summary, needs_human").eq("customer_id", person.id).order("created_at", { ascending: false }).limit(10),
      supabase.from("crm_tasks").select("*").eq("customer_id", person.id).eq("status", "open").order("due_at", { ascending: true, nullsFirst: false }).limit(20),
      supabase.from("callbacks").select("*").eq("customer_id", person.id).not("status", "in", "(completed,cancelled)").order("due_at").limit(10),
    ]);
    return { calls: calls.error ? [] : calls.data, tasks: tasks.error ? [] : tasks.data, cbs: cbs.error ? [] : cbs.data };
  }, [person?.id]);

  if (!person) return null;
  const name = personName(person) ?? "Unnamed";
  const stage = leadStage(person);

  async function run(key, work, message, after) {
    setBusy(key);
    setError("");
    const { error: failure } = await work();
    setBusy("");
    if (failure) { setError(explain(failure)); return false; }
    onNotice?.(message);
    onChanged();
    reload();
    after?.();
    return true;
  }
  const move = (col) => {
    if (col.key === "lost") return setLostReason("");
    return run(`stage-${col.key}`, () => supabase.rpc("zella_set_lead_stage", { p_customer_id: person.id, p_stage: col.set }), `${name} marked ${col.label.toLowerCase()}.`);
  };
  async function savePlan(event) {
    event.preventDefault();
    const ownerChanged = plan.assigned !== (person.assigned_to ?? "");
    if (ownerChanged) {
      const ok = await run("assign", () => supabase.rpc("zella_assign_lead", { p_customer_id: person.id, p_user_id: plan.assigned || null }), "Assignment saved.");
      if (!ok) return;
    }
    await run("plan", () => supabase.rpc("zella_set_lead_plan", {
      p_customer_id: person.id, p_priority: plan.priority,
      p_next_follow_up_at: plan.date ? zonedDateTime(plan.date, plan.time || "09:00", tz).toISOString() : null,
      p_clear_follow_up: !plan.date,
    }), "Follow-up plan saved.");
  }
  const addNote = (event) => {
    event.preventDefault();
    if (!note.trim()) return;
    run("note", () => supabase.rpc("zella_add_lead_note", { p_customer_id: person.id, p_note: note.trim() }), "Note added.", () => setNote(""));
  };
  const scheduleCallback = (event) => {
    event.preventDefault();
    if (!person.phone) return setError("Add a phone number to this lead first.");
    run("cb", () => supabase.rpc("zella_staff_create_callback", {
      p_business_id: workspace.id, p_contact_number: person.phone, p_customer_id: person.id,
      p_summary: cb.summary.trim() || null, p_preferred_at: zonedDateTime(cb.date, cb.time, tz).toISOString(), p_priority: plan.priority,
    }), "Callback scheduled.", () => setCb({ ...cb, open: false, summary: "" }));
  };

  const col = COLUMNS.find((c) => c.stages.includes(stage)) ?? COLUMNS[0];
  return (
    <Modal wide title={name} onClose={onClose} busy={Boolean(busy)}
      description={`${sourceName(person.source)} · added ${timeAgo(person.created_at)}${person.last_contacted_at ? ` · last contact ${timeAgo(person.last_contacted_at)}` : " · not contacted yet"}`}>
      <div className="ba-modal-body">
        {error && <p className="ba-error" role="alert">{error}</p>}
        <div className="ba-kn-head">
          <Pill tone={stage === "won" ? "success" : stage === "lost" || stage === "unqualified" ? "danger" : "warning"}>{stage === "unqualified" ? "Not a fit" : col.label}</Pill>
          {isOverdue(person) && <span className="ba-flag"><Icon name="schedule" size="sm" />Follow-up overdue</span>}
          {person.phone && <a className="ba-btn sm" href={`tel:${person.phone}`}><Icon name="call" size="sm" />{person.phone}</a>}
          <button type="button" className="ba-btn sm" onClick={() => onOpenProfile(person.id)}>Full profile</button>
        </div>
        {stage === "lost" && person.lost_reason && <p className="ba-item-text">Lost: {person.lost_reason}</p>}

        <div className="ba-form-actions wrap" role="group" aria-label="Move lead">
          {COLUMNS.filter((c) => c.key !== col.key).map((c) => (
            <button key={c.key} type="button" className={`ba-btn sm ${c.key === "lost" ? "danger-outline" : ""}`} disabled={Boolean(busy)} onClick={() => move(c)}>
              {c.key === "converted" ? "Mark converted" : c.key === "lost" ? "Mark lost" : `Move to ${c.label.toLowerCase()}`}
            </button>
          ))}
        </div>
        {lostReason !== null && (
          <form className="ba-inline-form" onSubmit={(e) => { e.preventDefault(); run("lost", () => supabase.rpc("zella_set_lead_stage", { p_customer_id: person.id, p_stage: "lost", p_reason: lostReason }), `${name} marked lost.`, () => setLostReason(null)); }}>
            <input autoFocus value={lostReason} onChange={(e) => setLostReason(e.target.value)} placeholder="Why was it lost?" aria-label="Reason lost" />
            <button type="submit" className="ba-btn sm primary" disabled={!lostReason.trim() || Boolean(busy)}>Save</button>
            <button type="button" className="ba-btn sm" onClick={() => setLostReason(null)}>Cancel</button>
          </form>
        )}

        <h3 className="ba-sub">Follow-up</h3>
        <form className="ba-form-grid" onSubmit={savePlan}>
          <Field label="Assigned to">
            <select value={plan.assigned} onChange={(e) => setPlan({ ...plan, assigned: e.target.value })}>
              <option value="">Unassigned</option>
              {roster.list.map((m) => <option key={m.user_id} value={m.user_id}>{m.name}</option>)}
            </select>
          </Field>
          <Field label="Priority">
            <select value={plan.priority} onChange={(e) => setPlan({ ...plan, priority: e.target.value })}>
              <option value="normal">Normal</option><option value="high">High</option><option value="urgent">Urgent</option>
            </select>
          </Field>
          <Field label="Next follow-up day" hint="Leave empty for none."><input type="date" value={plan.date} onChange={(e) => setPlan({ ...plan, date: e.target.value })} /></Field>
          <Field label="Time"><input type="time" value={plan.time} disabled={!plan.date} onChange={(e) => setPlan({ ...plan, time: e.target.value })} /></Field>
          <div className="full ba-form-actions"><button type="submit" className="ba-btn primary sm" disabled={Boolean(busy)}>{busy === "plan" || busy === "assign" ? "Saving…" : "Save follow-up"}</button></div>
        </form>

        <h3 className="ba-sub">Callback</h3>
        {data?.cbs.length > 0 && (
          <ul className="ba-threads">
            {data.cbs.map((c) => <li key={c.id}><span className="ba-thread-icon"><Icon name="phone_callback" size="sm" /></span><div><strong>Call back {when(c.due_at, tz)}</strong><small>{c.attempts} of {c.max_attempts} tries{c.summary ? ` · ${c.summary}` : ""}</small></div></li>)}
          </ul>
        )}
        {!cb.open ? (
          <div className="ba-form-actions"><button type="button" className="ba-btn sm" onClick={() => setCb({ ...cb, open: true })}><Icon name="add_call" size="sm" />Schedule a callback</button></div>
        ) : (
          <form className="ba-form-grid" onSubmit={scheduleCallback}>
            <Field label="Day"><input type="date" min={todayInput(tz)} value={cb.date} onChange={(e) => setCb({ ...cb, date: e.target.value })} required /></Field>
            <Field label="Time"><input type="time" value={cb.time} onChange={(e) => setCb({ ...cb, time: e.target.value })} required /></Field>
            <Field label="What is it about?" full><input value={cb.summary} onChange={(e) => setCb({ ...cb, summary: e.target.value })} placeholder="Optional" /></Field>
            <div className="full ba-form-actions">
              <button type="submit" className="ba-btn primary sm" disabled={Boolean(busy)}>Schedule</button>
              <button type="button" className="ba-btn sm" onClick={() => setCb({ ...cb, open: false })}>Cancel</button>
            </div>
          </form>
        )}

        <h3 className="ba-sub">Notes</h3>
        <form className="ba-inline-form" onSubmit={addNote}>
          <input value={note} onChange={(e) => setNote(e.target.value)} placeholder="Add a note for the team" aria-label="New note" />
          <button type="submit" className="ba-btn sm" disabled={!note.trim() || Boolean(busy)}>Add note</button>
        </form>
        {person.notes ? <p className="ba-item-text ba-notes">{person.notes}</p> : <p className="ba-muted">No notes yet.</p>}

        <h3 className="ba-sub">Open to-dos</h3>
        {!data?.tasks.length ? <p className="ba-muted">{loading && !data ? "Loading…" : "Nothing open."}</p> : (
          <ul className="ba-threads">
            {data.tasks.map((t) => <li key={t.id}><span className="ba-thread-icon"><Icon name="task_alt" size="sm" /></span><div><strong>{t.title}</strong><small>{t.due_at ? `Due ${when(t.due_at, tz)}` : "No due time"}{t.assigned_to && roster.nameOf[t.assigned_to] ? ` · ${roster.nameOf[t.assigned_to]}` : ""}</small></div></li>)}
          </ul>
        )}

        <h3 className="ba-sub">Call history</h3>
        {!data?.calls.length ? <p className="ba-muted">{loading && !data ? "Loading…" : `No calls from this ${term("customer").toLowerCase()} yet.`}</p> : (
          <ul className="ba-threads">
            {data.calls.map((c) => (
              <li key={c.id}>
                <span className="ba-thread-icon"><Icon name={c.status === "missed" ? "phone_missed" : "call"} size="sm" /></span>
                <div>
                  <strong>{c.status === "missed" ? "Missed call" : c.ai_handled ? "Answered by the AI receptionist" : "Answered by the team"}</strong>
                  <small>{when(c.started_at ?? c.created_at, tz)} · {clock(c.duration_seconds)}</small>
                  {c.summary && <small>{c.summary}</small>}
                </div>
                {c.needs_human && <Pill tone="danger">Needs a human</Pill>}
              </li>
            ))}
          </ul>
        )}
      </div>
    </Modal>
  );
}
