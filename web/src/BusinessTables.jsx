import { useMemo, useState } from "react";
import { supabase } from "./supabase";
import { Field, Icon, Modal, Pill } from "./BusinessUI";
import { formatTime } from "./businessTime";
import { Empty, Notice, PageHead, Segment, explain, useLoad } from "./BusinessShared";
import { FloorPlan, autoPlace } from "./FloorPlan";

/* Tables: the live seating board for businesses with "Tables and seating" on (sql/zella_tables.sql).
   Everything here comes from the database's own engine: zella_table_board for what each table is doing now and
   next, zella_table_action for every change (seat, walk-in, move, depart, clear, block, waitlist), and the same
   availability rules the AI receptionist uses. Nothing is decided in the browser: a move onto a taken table, or a
   walk-in that doesn't fit, is refused by the server and the reason is shown. */

// State labels always carry text and an icon, never colour alone.
export const TABLE_STATES = {
  available: { label: "Available", icon: "check_circle", tone: "success" },
  held: { label: "Held", icon: "hourglass_top", tone: "warning" },
  reserved: { label: "Reserved", icon: "event", tone: "info" },
  seated: { label: "Seated", icon: "restaurant", tone: "" },
  needs_clearing: { label: "Clearing", icon: "cleaning_services", tone: "warning" },
  unavailable: { label: "Unavailable", icon: "block", tone: "danger" },
};
const RES_STATUS = {
  confirmed: "Confirmed", arrived: "Arrived", seated: "Seated", completed: "Completed", no_show: "No-show", held: "Held", requested: "Needs the team",
};
const SOURCES = { ai_call: "AI call", walk_in: "Walk-in", staff: "Team", website: "Website" };
const EDIT_ROLES = ["owner", "admin", "manager", "staff"];

const say = (e) => {
  const m = e?.message ?? String(e);
  if (/SLOT_TAKEN/.test(m)) return "Those tables are taken then, or don't seat the party. Pick other tables or another time.";
  if (/TABLES_DO_NOT_FIT/.test(m)) return "Those tables don't seat this party, or aren't an allowed combination.";
  if (/TABLE_HAS_RESERVATIONS/.test(m)) return "That table has reservations in that time. Move them first; blocking never displaces a booking.";
  if (/PARTY_SIZE_REQUIRED/.test(m)) return "Enter how many people.";
  if (/NAME_REQUIRED/.test(m)) return "Enter a name for the waitlist.";
  if (/NOT_ALLOWED/.test(m)) return "Your role can't change tables.";
  return explain(e);
};

// today's date in the business's time zone, as YYYY-MM-DD
const todayIn = (tz) => new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
// a local date and HH:MM in the business's time zone -> an instant (the board asks "what is happening at this moment")
function instantAt(date, hhmm, tz) {
  const guess = new Date(`${date}T${hhmm}:00Z`);
  const offset = (d) => {
    const p = Object.fromEntries(new Intl.DateTimeFormat("en-US", { timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" })
      .formatToParts(d).map((x) => [x.type, x.value]));
    return Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute) - d.getTime();
  };
  return new Date(guess.getTime() - offset(new Date(guess.getTime() - offset(guess))));   // twice, so daylight-saving days are right
}
const clock = (hhmm) => { const [h, m] = hhmm.split(":").map(Number); return new Date(2000, 0, 1, h, m).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }); };
const minutesSince = (iso) => Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 60000));

async function servicesFor(workspace, date) {
  const r = await supabase.rpc("zella_business_settings", { p_business_id: workspace.id });
  if (r.error) throw r.error;
  const weekday = new Date(`${date}T12:00:00Z`).getUTCDay();
  return (r.data?.hours ?? []).filter((h) => h.weekday === weekday).map((h) => ({ key: `${h.opens}-${h.closes}`, opens: h.opens, closes: h.closes }));
}

async function loadBoard(workspace, date, period) {
  const tz = workspace.timezone;
  const today = date === todayIn(tz);
  const at = today ? new Date() : instantAt(date, period?.opens ?? "12:00", tz);
  const board = await supabase.rpc("zella_table_board", { p_business_id: workspace.id, p_at: at.toISOString() });
  if (board.error) throw board.error;
  const data = board.data;
  // another day: tables have no physical state yet, only what is booked
  if (!today) data.tables = data.tables.map((t) => (["seated", "needs_clearing"].includes(t.state) ? { ...t, state: "available" } : t));
  return { ...data, today };
}

export function TablesPage({ workspace, refreshKey, onNotice, onBook }) {
  const tz = workspace.timezone;
  const canEdit = EDIT_ROLES.includes(workspace.role);
  const [date, setDate] = useState(() => todayIn(tz));
  const [serviceKey, setServiceKey] = useState("all");
  const [section, setSection] = useState("all");
  const [view, setView] = useState("floor");
  const [planSection, setPlanSection] = useState(null);
  const [selected, setSelected] = useState(null);
  const [modal, setModal] = useState(null);   // { kind, ... }
  const [working, setWorking] = useState(false);
  const [problem, setProblem] = useState("");
  const [history, setHistory] = useState(null);

  const services = useLoad(() => servicesFor(workspace, date), [workspace.id, date]);
  const period = (services.data ?? []).find((s) => s.key === serviceKey) ?? null;
  const board = useLoad(() => loadBoard(workspace, date, period), [workspace.id, date, serviceKey, refreshKey, services.data?.length]);

  const data = board.data;
  const inPeriod = (iso) => {
    if (!period) return true;
    const t = new Intl.DateTimeFormat("en-GB", { timeZone: tz, hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(new Date(iso));
    return t >= period.opens && t < period.closes;
  };
  const tables = useMemo(() => (data?.tables ?? []).filter((t) => section === "all" || t.section === section), [data, section]);
  const reservations = useMemo(() => (data?.reservations ?? []).filter((r) => inPeriod(r.at)
    && (section === "all" || r.tables.length === 0 || tables.some((t) => r.tables.includes(t.name)))), [data, section, serviceKey, tables]);   // eslint-disable-line react-hooks/exhaustive-deps
  // the cards count what the filters show: these tables, and reservations in this service
  const counts = useMemo(() => {
    const c = { available: 0, reserved: 0, seated: 0, needs_clearing: 0 };
    for (const t of tables) if (c[t.state] !== undefined) c[t.state] += 1;
    c.reservedLater = reservations.filter((r) => ["confirmed", "held"].includes(r.status)).length;
    return c;
  }, [tables, reservations]);
  const current = selected ? (data?.tables ?? []).find((t) => t.id === selected) : null;

  async function act(action, args, message) {
    setWorking(true); setProblem("");
    const { data: out, error } = await supabase.rpc("zella_table_action", { p_business_id: workspace.id, p_action: action, p_args: args });
    setWorking(false);
    if (error) { setProblem(say(error)); return null; }
    if (message) onNotice?.(typeof message === "function" ? message(out) : message);
    setModal(null);
    board.reload();
    return out ?? {};
  }
  async function attendance(appointmentId, action, reason, message) {
    setWorking(true); setProblem("");
    const { error } = await supabase.rpc("zella_set_attendance", { p_appointment_id: appointmentId, p_action: action, p_reason: reason ?? null, p_staff_id: null });
    setWorking(false);
    if (error) { setProblem(say(error)); return; }
    onNotice?.(message); setModal(null); board.reload();
  }
  async function showHistory(table) {
    const out = await act("history", { table_id: table.id });
    if (out) setHistory({ table, events: out.events ?? [] });
  }

  return (
    <>
      <PageHead crumb="Service" title="Tables" sub={data ? `${data.today ? "Now" : "Planned"} · ${tables.length} table${tables.length === 1 ? "" : "s"}` : "Live seating"}>
        {canEdit && <button type="button" className="ba-btn" onClick={() => onBook?.()}><Icon name="event" size="sm" />Reservation</button>}
        {canEdit && data?.today && <button type="button" className="ba-btn primary" onClick={() => setModal({ kind: "walk_in" })}><Icon name="directions_walk" size="sm" />Walk-in</button>}
      </PageHead>

      <div className="tb-filters" role="group" aria-label="Filters">
        <Field label="Date"><input type="date" value={date} onChange={(e) => { setDate(e.target.value || todayIn(tz)); setServiceKey("all"); }} /></Field>
        <Field label="Service">
          <select value={serviceKey} onChange={(e) => setServiceKey(e.target.value)} disabled={!services.data?.length}>
            <option value="all">All day</option>
            {(services.data ?? []).map((s) => <option key={s.key} value={s.key}>{clock(s.opens)} – {clock(s.closes)}</option>)}
          </select>
        </Field>
        {(data?.sections?.length ?? 0) > 1 && (
          <Field label="Section">
            <select value={section} onChange={(e) => setSection(e.target.value)}>
              <option value="all">All sections</option>
              {data.sections.map((s) => <option key={s}>{s}</option>)}
            </select>
          </Field>
        )}
        <div className="tb-view"><Segment label="View" value={view} onChange={setView} options={[["floor", "Floor plan"], ["cards", "Cards"], ["list", "List"]]} /></div>
      </div>

      <Notice error={board.error} onRetry={board.reload} />
      {problem && <div className="ba-banner error" role="alert"><span>{problem}</span><button type="button" className="ba-btn sm" onClick={() => setProblem("")}>Dismiss</button></div>}

      {board.loading && !data ? <div className="tb-loading" aria-busy="true">Loading tables…</div> : !data ? null : !(data.tables ?? []).length ? (
        <Empty title="No tables yet" icon="table_restaurant">
          {["owner", "admin", "manager"].includes(workspace.role)
            ? <>Add your tables in Settings → Tables and seating. Until then reservations work as before.</>
            : <>An owner or manager adds the tables in Settings.</>}
        </Empty>
      ) : (
        <>
          <div className="tb-cards" aria-label="Summary">
            <Count icon="check_circle" tone="green" label="Available" value={counts.available} note={data.today ? "now" : "at the start of service"} />
            <Count icon="event" tone="blue" label="Reserved" value={counts.reservedLater} note={`${counts.reserved} arriving within 30 min`} />
            <Count icon="restaurant" tone="indigo" label="Seated" value={counts.seated} note={data.today ? "now" : "—"} />
            <Count icon="cleaning_services" tone="amber" label="Clearing" value={counts.needs_clearing} note={data.today ? "waiting to be reset" : "—"} />
          </div>

          <div className="tb-layout">
            <section className="ba-panel tb-board" aria-label="Tables">
              {view === "floor" ? (() => {
                const secs = [...new Set(tables.map((t) => t.section))];
                const show = secs.includes(planSection) ? planSection : secs[0];
                return (
                  <>
                    {secs.length > 1 && <div className="fp-tabs"><Segment label="Section" value={show} onChange={setPlanSection} options={secs.map((x) => [x, x])} /></div>}
                    <FloorPlan tables={tables.filter((t) => t.section === show)} selectedId={selected} onSelect={(id) => setSelected(id === selected ? null : id)}
                      label={`${show} floor plan`} tz={tz} formatTime={formatTime} />
                  </>
                );
              })() : view === "cards" ? (
                [...new Set(tables.map((t) => t.section))].map((sec) => (
                  <div key={sec} className="tb-section">
                    <h2 className="tb-section-title">{sec}</h2>
                    <div className="tb-grid">
                      {tables.filter((t) => t.section === sec).map((t) => (
                        <TableCard key={t.id} t={t} tz={tz} selected={t.id === selected} onSelect={() => setSelected(t.id === selected ? null : t.id)} />
                      ))}
                    </div>
                  </div>
                ))
              ) : (
                <table className="tb-list">
                  <thead><tr><th scope="col">Table</th><th scope="col">Section</th><th scope="col">Seats</th><th scope="col">State</th><th scope="col">Now</th><th scope="col">Next</th></tr></thead>
                  <tbody>
                    {tables.map((t) => (
                      <tr key={t.id} className={t.id === selected ? "selected" : ""}>
                        <th scope="row"><button type="button" className="ba-link" onClick={() => setSelected(t.id)}>{t.name}</button></th>
                        <td>{t.section}</td><td>{t.min_party > 1 ? `${t.min_party}–${t.seats}` : t.seats}</td>
                        <td><StateLabel state={t.state} /></td>
                        <td>{t.current ? `${t.current.guest ?? "Guest"} · ${t.current.party}` : t.available_until ? `Free until ${formatTime(t.available_until, tz)}` : "—"}</td>
                        <td>{t.next ? `${formatTime(t.next.at, tz)} · ${t.next.guest ?? "Guest"} · ${t.next.party}` : "—"}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </section>

            <aside className="tb-side">
              {current && (
                <TablePanel t={current} tz={tz} today={data.today} canEdit={canEdit} working={working}
                  reservations={(data.reservations ?? []).filter((r) => r.tables.includes(current.name) && !["completed", "no_show"].includes(r.status))}
                  onClose={() => setSelected(null)}
                  onSeat={(id) => act("seat", { appointment_id: id }, "Seated.")}
                  onWalkIn={() => setModal({ kind: "walk_in", tableId: current.id })}
                  onDepart={(id) => act("depart", { appointment_id: id }, `${current.name} needs clearing.`)}
                  onClear={() => act("clear", { table_id: current.id }, (out) => (out?.waitlist_fits?.length ? `${current.name} is ready. ${out.waitlist_fits.length} waiting part${out.waitlist_fits.length === 1 ? "y fits" : "ies fit"} it.` : `${current.name} is ready.`))}
                  onBlock={() => setModal({ kind: "block", table: current })}
                  onUnblock={() => setModal({ kind: "unblock", table: current })}
                  onMove={(r) => setModal({ kind: "move", reservation: r })}
                  onHistory={() => showHistory(current)} />
              )}
              <WaitlistPanel entries={data.waitlist ?? []} canEdit={canEdit && data.today} working={working}
                onAdd={() => setModal({ kind: "waitlist" })}
                onSeat={(w) => setModal({ kind: "walk_in", waitlist: w })}
                onRemove={async (w) => { const { error } = await supabase.rpc("zella_remove_waitlist_entry", { p_id: w.id }); if (error) setProblem(say(error)); else { onNotice?.("Removed from the waitlist."); board.reload(); } }} />
            </aside>
          </div>

          <section className="ba-panel tb-timeline" aria-label="Reservations">
            <div className="ba-panel-head"><h2>Reservations</h2><p>{period ? `${clock(period.opens)} – ${clock(period.closes)}` : "All day"} · {reservations.length}</p></div>
            {!reservations.length ? <Empty title="No reservations in this period" icon="event_available" /> : (
              <ul className="tb-res">
                {reservations.map((r) => (
                  <li key={r.id} className="tb-res-row">
                    <span className="tb-res-time">{formatTime(r.at, tz)}</span>
                    <span className="tb-res-main">
                      <strong>{r.guest ?? "Guest"}</strong> · party of {r.party ?? "?"}{r.tables.length ? ` · ${r.tables.join(" + ")}` : ""}
                      <small>{RES_STATUS[r.status] ?? r.status} · {SOURCES[r.source] ?? "Team"}{r.preferences ? ` · prefers ${r.preferences}` : ""}{r.requests ? ` · ${r.requests}` : ""}</small>
                    </span>
                    {canEdit && data.today && ["confirmed", "arrived"].includes(r.status) && (
                      <span className="ba-form-actions">
                        {r.status === "confirmed" && <button type="button" className="ba-btn sm" disabled={working} onClick={() => attendance(r.id, "arrived", null, `${r.guest ?? "Guest"} arrived.`)}>Arrived</button>}
                        <button type="button" className="ba-btn sm" disabled={working} onClick={() => act("seat", { appointment_id: r.id }, `${r.guest ?? "Guest"} seated.`)}>Seat</button>
                        <button type="button" className="ba-btn sm" disabled={working} onClick={() => setModal({ kind: "move", reservation: r })}>Move</button>
                        <button type="button" className="ba-btn sm danger-outline" disabled={working} onClick={() => setModal({ kind: "close", reservation: r })}>No-show / cancel</button>
                      </span>
                    )}
                  </li>
                ))}
              </ul>
            )}
          </section>
        </>
      )}

      {modal?.kind === "walk_in" && <WalkInModal tables={(data?.tables ?? []).filter((t) => t.state === "available")} preset={modal} working={working} onClose={() => setModal(null)}
        onSubmit={(args) => act("walk_in", args, (out) => `Seated at ${(data?.tables ?? []).filter((t) => (out?.tables ?? []).includes(t.id)).map((t) => t.name).join(" + ") || "a table"}.`)} />}
      {modal?.kind === "waitlist" && <WaitlistModal working={working} onClose={() => setModal(null)} onSubmit={(args) => act("waitlist_add", args, `${args.name} is on the waitlist.`)} />}
      {modal?.kind === "move" && <MoveModal reservation={modal.reservation} tables={data?.tables ?? []} working={working} onClose={() => setModal(null)}
        onSubmit={(ids) => act("move", { appointment_id: modal.reservation.id, table_ids: ids }, "Tables changed.")} />}
      {modal?.kind === "block" && <BlockModal table={modal.table} tz={tz} date={date} working={working} onClose={() => setModal(null)}
        onSubmit={(args) => act("block", { table_id: modal.table.id, ...args }, `${modal.table.name} is blocked.`)} />}
      {modal?.kind === "unblock" && <Modal title={`Unblock ${modal.table.name}?`} onClose={() => setModal(null)} busy={working}
        footer={<><button type="button" className="ba-btn" onClick={() => setModal(null)}>Keep blocked</button><button type="button" className="ba-btn primary" disabled={working} onClick={() => unblock(modal.table)}>Unblock</button></>}>
        <p>{modal.table.block?.reason ? `Blocked: ${modal.table.block.reason}.` : "Blocked."} It becomes available for seating and reservations again.</p></Modal>}
      {modal?.kind === "close" && <CloseModal reservation={modal.reservation} working={working} onClose={() => setModal(null)}
        onSubmit={(action, reason) => attendance(modal.reservation.id, action, reason, action === "no_show" ? "Marked as a no-show." : "Reservation cancelled.")} />}
      {history && <Modal title={`${history.table.name}: activity`} onClose={() => setHistory(null)} wide>
        {!history.events.length ? <Empty title="Nothing recorded yet" icon="history" /> : (
          <ul className="tb-history">{history.events.map((e, i) => (
            <li key={i}><span>{new Date(e.at).toLocaleString([], { timeZone: tz, dateStyle: "medium", timeStyle: "short" })}</span>
              <strong>{e.action.replace(/_/g, " ")}</strong><span>{e.by ?? "Zella Voice"}</span></li>))}</ul>
        )}
      </Modal>}
    </>
  );

  async function unblock(table) {
    const { data: rows, error } = await supabase.from("table_blocks").select("id").eq("table_id", table.id).lte("starts_at", new Date().toISOString()).gt("ends_at", new Date().toISOString()).limit(1);
    if (error || !rows?.length) return setProblem(error ? say(error) : "That block has already ended.");
    act("unblock", { block_id: rows[0].id }, `${table.name} is available again.`);
  }
}

function Count({ icon, tone, label, value, note }) {
  return (
    <div className="ba-kpi tb-count">
      <div className="ba-kpi-top"><span>{label}</span><span className={`ba-kpi-icon ${tone}`}><Icon name={icon} /></span></div>
      <div className="ba-kpi-value">{value}</div>
      {note && <div className="ba-kpi-note">{note}</div>}
    </div>
  );
}

function StateLabel({ state }) {
  const s = TABLE_STATES[state] ?? { label: state, icon: "help" };
  return <Pill tone={s.tone}><Icon name={s.icon} size="sm" />{s.label}</Pill>;
}

function TableCard({ t, tz, selected, onSelect }) {
  const s = TABLE_STATES[t.state] ?? TABLE_STATES.available;
  return (
    <button type="button" className={`tb-card state-${t.state} ${selected ? "selected" : ""}`} onClick={onSelect} aria-pressed={selected}
      aria-label={`${t.name}, ${t.seats} seats, ${s.label}${t.next ? `, next at ${formatTime(t.next.at, tz)}` : ""}`}>
      <span className="tb-card-head"><strong>{t.name}</strong><span>{t.min_party > 1 ? `${t.min_party}–${t.seats}` : t.seats} seats</span></span>
      <span className="tb-card-state"><Icon name={s.icon} size="sm" />{s.label}</span>
      <span className="tb-card-body">
        {t.state === "seated" && t.current ? <>{formatTime(t.current.since, tz)} · {t.current.guest ?? "Guest"}<br />Party of {t.current.party}</>
          : t.state === "unavailable" ? <>{t.block?.reason ?? "Blocked"}{t.block?.until ? ` · until ${formatTime(t.block.until, tz)}` : ""}</>
          : t.state === "needs_clearing" ? <>Since {formatTime(t.clearing_since, tz)}</>
          : t.next ? <>{t.state === "available" ? `Free until ${formatTime(t.next.at, tz)}` : `${formatTime(t.next.at, tz)} · ${t.next.guest ?? "Guest"}`}<br />Next: party of {t.next.party}</>
          : "Free for the rest of the day"}
      </span>
      {t.attributes?.length > 0 && <span className="tb-card-tags">{t.attributes.join(" · ")}</span>}
    </button>
  );
}

function TablePanel({ t, tz, today, canEdit, working, reservations, onClose, onSeat, onWalkIn, onDepart, onClear, onBlock, onUnblock, onMove, onHistory }) {
  const next = reservations.find((r) => r.status !== "seated");
  return (
    <section className="ba-panel tb-panel" aria-label={`Table ${t.name}`}>
      <div className="ba-panel-head">
        <div><h2>{t.name} · {t.min_party > 1 ? `${t.min_party}–${t.seats}` : t.seats} seats</h2><p>{t.section}{t.attributes?.length ? ` · ${t.attributes.join(", ")}` : ""}</p></div>
        <button type="button" className="ba-icon-btn" onClick={onClose} aria-label="Close"><Icon name="close" /></button>
      </div>
      <div className="tb-panel-body">
        <StateLabel state={t.state} />
        {t.current && <p><strong>{t.current.guest ?? "Guest"}</strong> · party of {t.current.party} · seated {formatTime(t.current.since, tz)}
          {new Date(t.current.expected_end) < new Date() ? <><br /><span className="tb-warn">Past the expected end ({formatTime(t.current.expected_end, tz)}). The next booking stays assigned; move it if needed.</span></> : ` · until about ${formatTime(t.current.expected_end, tz)}`}</p>}
        <h3>Coming up</h3>
        {!reservations.length ? <p className="ba-muted">No more reservations today.</p> : (
          <ul className="tb-mini">{reservations.map((r) => <li key={r.id}>{formatTime(r.at, tz)} · {r.guest ?? "Guest"} · {r.party} · {RES_STATUS[r.status] ?? r.status}
            {canEdit && today && <button type="button" className="ba-link" onClick={() => onMove(r)}>Move</button>}</li>)}</ul>
        )}
        {canEdit && today && (
          <div className="tb-actions">
            {t.state === "seated" && t.current && <button type="button" className="ba-btn sm primary" disabled={working} onClick={() => onDepart(t.current.appointment_id)}>Guests left</button>}
            {t.state === "needs_clearing" && <button type="button" className="ba-btn sm primary" disabled={working} onClick={onClear}>Cleared, ready</button>}
            {["available", "reserved", "held"].includes(t.state) && next && <button type="button" className="ba-btn sm primary" disabled={working} onClick={() => onSeat(next.id)}>Seat {next.guest ?? "next party"}</button>}
            {t.state === "available" && <button type="button" className="ba-btn sm" disabled={working} onClick={onWalkIn}>Seat a walk-in here</button>}
            {t.state === "unavailable" ? <button type="button" className="ba-btn sm" disabled={working} onClick={onUnblock}>Unblock</button>
              : <button type="button" className="ba-btn sm" disabled={working} onClick={onBlock}>Block…</button>}
            <button type="button" className="ba-btn sm" disabled={working} onClick={onHistory}>History</button>
          </div>
        )}
      </div>
    </section>
  );
}

function WaitlistPanel({ entries, canEdit, working, onAdd, onSeat, onRemove }) {
  return (
    <section className="ba-panel tb-wait" aria-label="Waitlist">
      <div className="ba-panel-head"><div><h2>Waitlist</h2><p>{entries.length} waiting</p></div>
        {canEdit && <button type="button" className="ba-btn sm" onClick={onAdd}><Icon name="add" size="sm" />Add</button>}</div>
      {!entries.length ? <Empty title="Nobody is waiting" icon="hourglass_empty" /> : (
        <ul className="tb-mini">
          {entries.map((w) => (
            <li key={w.id}>
              <span><strong>{w.guest ?? "Guest"}</strong> · {w.party ?? "?"} · waiting {minutesSince(w.joined)} min{w.preferences ? ` · ${w.preferences}` : ""}
                <small>{w.fits_now?.length ? `Fits now: ${w.fits_now.join(" + ")}` : "No table free for them yet"}{w.contact_ok ? " · may be contacted" : " · don't contact"}</small></span>
              {canEdit && <span className="ba-form-actions">
                <button type="button" className="ba-btn sm" disabled={working || !w.fits_now?.length} onClick={() => onSeat(w)}>Seat</button>
                <button type="button" className="ba-btn sm danger-outline" disabled={working} onClick={() => onRemove(w)}>Remove</button></span>}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

function WalkInModal({ tables, preset, working, onClose, onSubmit }) {
  const [party, setParty] = useState(preset.waitlist?.party ? String(preset.waitlist.party) : "2");
  const [name, setName] = useState(preset.waitlist?.guest ?? "");
  const [phone, setPhone] = useState("");
  const [tableId, setTableId] = useState(preset.tableId ?? "");
  const [notes, setNotes] = useState("");
  return (
    <Modal title={preset.waitlist ? `Seat ${preset.waitlist.guest ?? "waiting party"}` : "Seat a walk-in"} onClose={onClose} busy={working}
      footer={<><button type="button" className="ba-btn" onClick={onClose}>Cancel</button>
        <button type="button" className="ba-btn primary" disabled={working || !(Number(party) >= 1)}
          onClick={() => onSubmit({ party_size: Number(party), name: name.trim() || undefined, phone: phone.trim() || undefined, notes: notes.trim() || undefined,
            ...(tableId ? { table_ids: [tableId] } : {}), ...(preset.waitlist ? { waitlist_id: preset.waitlist.id } : {}) })}>Seat now</button></>}>
      <div className="ba-form-grid">
        <Field label="Party size"><input type="number" min={1} max={100} value={party} onChange={(e) => setParty(e.target.value)} autoFocus /></Field>
        <Field label="Table" hint="Leave on Best fit and Zella picks the smallest free table or combination.">
          <select value={tableId} onChange={(e) => setTableId(e.target.value)}>
            <option value="">Best fit</option>
            {tables.map((t) => <option key={t.id} value={t.id}>{t.name} · {t.seats} seats</option>)}
          </select>
        </Field>
        {!preset.waitlist && <Field label="Name (optional)"><input value={name} onChange={(e) => setName(e.target.value)} maxLength={80} /></Field>}
        {!preset.waitlist && <Field label="Phone (optional)"><input value={phone} onChange={(e) => setPhone(e.target.value)} inputMode="tel" /></Field>}
        <Field label="Notes for the team" full hint="Seating or dietary requests. Recording a dietary request doesn't mean the kitchen can guarantee it."><input value={notes} onChange={(e) => setNotes(e.target.value)} maxLength={500} /></Field>
      </div>
    </Modal>
  );
}

function WaitlistModal({ working, onClose, onSubmit }) {
  const [f, setF] = useState({ name: "", phone: "", party: "2", preferences: "", contact_ok: false });
  const set = (k) => (e) => setF({ ...f, [k]: e.target.type === "checkbox" ? e.target.checked : e.target.value });
  return (
    <Modal title="Add to the waitlist" onClose={onClose} busy={working}
      footer={<><button type="button" className="ba-btn" onClick={onClose}>Cancel</button>
        <button type="button" className="ba-btn primary" disabled={working || !f.name.trim() || !(Number(f.party) >= 1)}
          onClick={() => onSubmit({ name: f.name.trim(), phone: f.phone.trim() || undefined, party_size: Number(f.party), preferences: f.preferences.trim() || undefined, contact_ok: f.contact_ok })}>Add</button></>}>
      <div className="ba-form-grid">
        <Field label="Name"><input value={f.name} onChange={set("name")} maxLength={80} autoFocus /></Field>
        <Field label="Party size"><input type="number" min={1} max={100} value={f.party} onChange={set("party")} /></Field>
        <Field label="Phone"><input value={f.phone} onChange={set("phone")} inputMode="tel" /></Field>
        <Field label="Preferences"><input value={f.preferences} onChange={set("preferences")} maxLength={300} placeholder="e.g. patio, high chair" /></Field>
        <Field label="Contact" full><label className="ba-check"><input type="checkbox" checked={f.contact_ok} onChange={set("contact_ok")} /> They agreed to be texted when a table is ready</label></Field>
      </div>
      <p className="ba-muted">Waiting times aren't promised. Tell guests any wait is an estimate.</p>
    </Modal>
  );
}

function MoveModal({ reservation, tables, working, onClose, onSubmit }) {
  const [ids, setIds] = useState(() => tables.filter((t) => reservation.tables.includes(t.name)).map((t) => t.id));
  const toggle = (id) => setIds(ids.includes(id) ? ids.filter((x) => x !== id) : [...ids, id]);
  return (
    <Modal title={`Tables for ${reservation.guest ?? "this party"} · party of ${reservation.party}`} onClose={onClose} busy={working}
      description="Pick one table or an allowed combination. Zella refuses tables another booking already has; nobody is moved without you seeing it."
      footer={<><button type="button" className="ba-btn" onClick={onClose}>Cancel</button><button type="button" className="ba-btn primary" disabled={working || !ids.length} onClick={() => onSubmit(ids)}>Save tables</button></>}>
      <fieldset className="tb-pick"><legend className="ba-sr-only">Tables</legend>
        {tables.map((t) => (
          <label key={t.id} className={ids.includes(t.id) ? "on" : ""}><input type="checkbox" checked={ids.includes(t.id)} onChange={() => toggle(t.id)} />
            {t.name} · {t.seats} seats · {TABLE_STATES[t.state]?.label ?? t.state}</label>
        ))}
      </fieldset>
    </Modal>
  );
}

function BlockModal({ table, tz, date, working, onClose, onSubmit }) {
  const [from, setFrom] = useState(""); const [until, setUntil] = useState("23:59"); const [reason, setReason] = useState("");
  return (
    <Modal title={`Block ${table.name}`} onClose={onClose} busy={working} description="A block is refused if a reservation already has this table in that time."
      footer={<><button type="button" className="ba-btn" onClick={onClose}>Cancel</button>
        <button type="button" className="ba-btn primary" disabled={working || !until}
          onClick={() => onSubmit({ starts_at: from ? instantAt(date, from, tz).toISOString() : undefined, ends_at: instantAt(date, until, tz).toISOString(), reason: reason.trim() || undefined })}>Block</button></>}>
      <div className="ba-form-grid">
        <Field label="From" hint="Empty means now"><input type="time" value={from} onChange={(e) => setFrom(e.target.value)} /></Field>
        <Field label="Until"><input type="time" value={until} onChange={(e) => setUntil(e.target.value)} /></Field>
        <Field label="Reason" full><input value={reason} onChange={(e) => setReason(e.target.value)} maxLength={200} placeholder="e.g. broken chair, private event" /></Field>
      </div>
    </Modal>
  );
}

function CloseModal({ reservation, working, onClose, onSubmit }) {
  const [action, setAction] = useState("no_show"); const [reason, setReason] = useState("");
  return (
    <Modal title={`${reservation.guest ?? "Reservation"} · ${reservation.party} people`} onClose={onClose} busy={working}
      footer={<><button type="button" className="ba-btn" onClick={onClose}>Back</button>
        <button type="button" className="ba-btn danger" disabled={working || !reason.trim()} onClick={() => onSubmit(action, reason.trim())}>{action === "no_show" ? "Mark no-show" : "Cancel reservation"}</button></>}>
      <Segment label="What happened" value={action} onChange={setAction} options={[["no_show", "Didn't come"], ["cancelled", "Canceled"]]} />
      <Field label="Reason" full><input value={reason} onChange={(e) => setReason(e.target.value)} maxLength={200} autoFocus /></Field>
    </Modal>
  );
}

/* Settings → Tables and seating: the tables, the combinations allowed and the seating rules. Owners, admins and
   managers only (the server checks too). A change that would leave a booked party without valid tables is refused
   and the affected bookings are listed; nothing is changed silently. */
export function TableSetup({ workspace, onNotice }) {
  const canEdit = ["owner", "admin", "manager"].includes(workspace.role);
  const state = useLoad(async () => {
    const r = await supabase.rpc("zella_tables", { p_business_id: workspace.id });
    if (r.error) throw r.error;
    return r.data;
  }, [workspace.id]);
  const [rows, setRows] = useState(null);
  const [combos, setCombos] = useState(null);
  const [problem, setProblem] = useState(null);
  const [busy, setBusy] = useState(false);
  const data = state.data;
  const list = rows ?? (data?.tables ?? []).filter((t) => t.active).map((t) => ({ ...t, attributes: (t.attributes ?? []).join(", ") }));
  const comboList = combos ?? (data?.combinations ?? []).filter((c) => c.active);
  const setRow = (i, k, v) => setRows(list.map((r, j) => (j === i ? { ...r, [k]: v } : r)));
  const move = (i, d) => { const next = [...list]; const [x] = next.splice(i, 1); next.splice(i + d, 0, x); setRows(next); };
  const [planSection, setPlanSection] = useState(null);
  const sectionOf = (t) => (t.section || "Main dining room");
  // every row with its drawn position: placed by the owner, or where the plan shows it until then
  const placedRows = () => {
    const out = list.map((t, i) => ({ ...t, _i: i, seats: Number(t.max_party) || 1 }));
    for (const sec of [...new Set(out.map(sectionOf))]) {
      autoPlace(out.filter((t) => sectionOf(t) === sec)).forEach((p) => { out[p._i] = { ...out[p._i], x: p.x, y: p.y }; });
    }
    return out;
  };
  const moveOnPlan = (key, x, y) => setRows(list.map((r, j) => ((r.id ?? `new-${j}`) === key ? { ...r, x, y } : r)));

  async function save(rpc, payload, message, reset) {
    setBusy(true); setProblem(null);
    const { error } = await supabase.rpc(rpc, { p_business_id: workspace.id, ...payload });
    setBusy(false);
    if (error) {
      let affected = [];
      try { affected = JSON.parse(error.details ?? "[]"); } catch { affected = []; }
      setProblem(/AFFECTS_RESERVATIONS/.test(error.message) ? { text: "Not saved: these reservations would no longer fit. Move or cancel them first, then save again.", affected } : { text: say(error), affected: [] });
      return;
    }
    reset(); onNotice?.(message); state.reload();
  }

  if (state.error) return <Notice error={state.error} onRetry={state.reload} />;
  if (!data) return <div className="tb-loading" aria-busy="true">Loading…</div>;
  return (
    <div className="tb-setup">
      {problem && (
        <div className="ba-banner error" role="alert"><span>{problem.text}
          {problem.affected.length > 0 && <ul>{problem.affected.map((a) => <li key={a.appointment_id}>{new Date(a.at).toLocaleString([], { timeZone: workspace.timezone, dateStyle: "medium", timeStyle: "short" })} · party of {a.party} · {(a.tables ?? []).join(" + ")}</li>)}</ul>}</span></div>
      )}
      <section className="ba-panel">
        <div className="ba-panel-head"><div><h2>Tables</h2><p>Order here is the order on the board. Attributes are comma-separated (accessible, window, booth). Tables you remove are switched off, never deleted.</p></div></div>
        <div className="tb-setup-rows">
          {list.map((t, i) => (
            <div key={t.id ?? `new-${i}`} className="tb-setup-row">
              <Field label="Name"><input value={t.name} onChange={(e) => setRow(i, "name", e.target.value)} maxLength={40} disabled={!canEdit} /></Field>
              <Field label="Section"><input value={t.section ?? ""} onChange={(e) => setRow(i, "section", e.target.value)} maxLength={40} placeholder="Main dining room" disabled={!canEdit} /></Field>
              <Field label="Smallest party"><input type="number" min={1} max={100} value={t.min_party} onChange={(e) => setRow(i, "min_party", e.target.value)} disabled={!canEdit} /></Field>
              <Field label="Seats"><input type="number" min={1} max={100} value={t.max_party} onChange={(e) => setRow(i, "max_party", e.target.value)} disabled={!canEdit} /></Field>
              <Field label="Shape"><select value={t.shape ?? "square"} onChange={(e) => setRow(i, "shape", e.target.value)} disabled={!canEdit}>
                <option value="square">Square</option><option value="round">Round</option><option value="rect">Long</option></select></Field>
              <Field label="Attributes"><input value={t.attributes} onChange={(e) => setRow(i, "attributes", e.target.value)} disabled={!canEdit} /></Field>
              {canEdit && <div className="tb-setup-move">
                <button type="button" className="ba-icon-btn" aria-label={`Move ${t.name} up`} disabled={i === 0} onClick={() => move(i, -1)}><Icon name="arrow_upward" /></button>
                <button type="button" className="ba-icon-btn" aria-label={`Move ${t.name} down`} disabled={i === list.length - 1} onClick={() => move(i, 1)}><Icon name="arrow_downward" /></button>
                <button type="button" className="ba-icon-btn" aria-label={`Remove ${t.name}`} onClick={() => setRows(list.filter((_, j) => j !== i))}><Icon name="delete" /></button>
              </div>}
            </div>
          ))}
        </div>
        {canEdit && <div className="ba-form-actions">
          <button type="button" className="ba-btn" onClick={() => setRows([...list, { name: `T${String(list.length + 1).padStart(2, "0")}`, section: list.at(-1)?.section ?? "Main dining room", min_party: 1, max_party: 2, attributes: "" }])}><Icon name="add" size="sm" />Add table</button>
          <button type="button" className="ba-btn primary" disabled={busy || rows === null} onClick={() => save("zella_save_tables", {
            p_tables: placedRows().map((t) => ({ id: t.id, name: t.name, section: t.section, min_party: Number(t.min_party) || 1, max_party: Number(t.max_party), active: true,
              shape: t.shape ?? "square", x: t.x, y: t.y,
              attributes: String(t.attributes ?? "").split(",").map((x) => x.trim()).filter(Boolean) })) }, "Tables saved. The AI receptionist uses them from its next availability check.", () => setRows(null))}>Save tables</button>
        </div>}
      </section>

      <section className="ba-panel">
        <div className="ba-panel-head"><div><h2>Floor plan</h2><p>Drag tables to where they are in the room, or select one and use the arrow keys (Shift moves further). Save tables to keep it.</p></div></div>
        <div className="tb-plan-edit">
          {(() => {
            const rowsNow = placedRows();
            const secs = [...new Set(rowsNow.map(sectionOf))];
            const show = secs.includes(planSection) ? planSection : secs[0];
            return (
              <>
                {secs.length > 1 && <div className="fp-tabs"><Segment label="Section" value={show} onChange={setPlanSection} options={secs.map((x) => [x, x])} /></div>}
                <FloorPlan tables={rowsNow.filter((t) => sectionOf(t) === show).map((t) => ({ ...t, id: t.id ?? `new-${t._i}`, state: "available" }))}
                  editable={canEdit} onMove={moveOnPlan} label={`${show ?? "Room"} layout editor`} />
              </>
            );
          })()}
        </div>
      </section>

      <section className="ba-panel">
        <div className="ba-panel-head"><div><h2>Combinations</h2><p>Tables that may be joined for one party, and how many people they really seat together.</p></div></div>
        {!comboList.length && <Empty title="No combinations" icon="join_inner">Without combinations, each party gets one table.</Empty>}
        <div className="tb-setup-rows">
          {comboList.map((c, i) => (
            <div key={c.id ?? `c-${i}`} className="tb-setup-row combo">
              <fieldset className="tb-pick inline"><legend>Tables</legend>
                {(data.tables ?? []).filter((t) => t.active).map((t) => (
                  <label key={t.id} className={c.table_ids.includes(t.id) ? "on" : ""}><input type="checkbox" disabled={!canEdit} checked={c.table_ids.includes(t.id)}
                    onChange={() => setCombos(comboList.map((x, j) => (j === i ? { ...x, table_ids: x.table_ids.includes(t.id) ? x.table_ids.filter((y) => y !== t.id) : [...x.table_ids, t.id] } : x)))} />{t.name}</label>
                ))}
              </fieldset>
              <Field label="Smallest party"><input type="number" min={1} max={100} value={c.min_party} disabled={!canEdit} onChange={(e) => setCombos(comboList.map((x, j) => (j === i ? { ...x, min_party: e.target.value } : x)))} /></Field>
              <Field label="Seats together"><input type="number" min={1} max={100} value={c.max_party} disabled={!canEdit} onChange={(e) => setCombos(comboList.map((x, j) => (j === i ? { ...x, max_party: e.target.value } : x)))} /></Field>
              {canEdit && <button type="button" className="ba-icon-btn" aria-label="Remove combination" onClick={() => setCombos(comboList.filter((_, j) => j !== i))}><Icon name="delete" /></button>}
            </div>
          ))}
        </div>
        {canEdit && <div className="ba-form-actions">
          <button type="button" className="ba-btn" onClick={() => setCombos([...comboList, { table_ids: [], min_party: 3, max_party: 4 }])}><Icon name="add" size="sm" />Add combination</button>
          <button type="button" className="ba-btn primary" disabled={busy || combos === null} onClick={() => save("zella_save_combinations", {
            p_combinations: comboList.map((c) => ({ table_ids: c.table_ids, min_party: Number(c.min_party) || 1, max_party: Number(c.max_party) })) }, "Combinations saved.", () => setCombos(null))}>Save combinations</button>
        </div>}
      </section>

      <section className="ba-panel">
        <div className="ba-panel-head"><div><h2>Seating rules</h2><p>Set in Receptionist → Booking rules, which the AI and the CRM both follow.</p></div></div>
        <ul className="tb-mini">
          <li>Table time: {data.duration_minutes} minutes (the usual reservation length)</li>
          <li>Reset between parties: {data.buffer_minutes} minutes (the gap between bookings)</li>
          <li>Largest party the AI books itself: {data.max_party_ai || "none yet"}; larger parties go to the team</li>
          <li>Opening hours and holidays: Settings → Hours and holidays</li>
        </ul>
      </section>
    </div>
  );
}
