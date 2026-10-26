import { useMemo, useRef, useState } from "react";
import { Icon } from "./BusinessUI";
import { personName } from "./BusinessUI";
import { formatTime } from "./businessTime";

// Presentational calendar pieces: an hour grid (day and week views) and a month grid.
// The page that owns the data decides what a click or a drop means.

export const PX_PER_HOUR = 56;
const SNAP_MINUTES = 15;

export function dayInfo(dayRangeFn, tz, offset) {
  const { start, end } = dayRangeFn(tz, offset);
  const dateStr = start.toLocaleDateString("en-CA", { timeZone: tz });
  const [y, m, d] = dateStr.split("-").map(Number);
  return { offset, start, end, dateStr, y, m, d, dow: new Date(Date.UTC(y, m - 1, d)).getUTCDay() };
}

export const minutesInto = (date, dayStart) => (new Date(date).getTime() - dayStart.getTime()) / 60000;

export const hourLabel = (h) => (h === 0 ? "12 AM" : h < 12 ? `${h} AM` : h === 12 ? "12 PM" : `${h - 12} PM`);
export const clockText = (min) => {
  const h = Math.floor(min / 60) % 24;
  const m = Math.round(min % 60);
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
};
const snap = (min) => Math.round(min / SNAP_MINUTES) * SNAP_MINUTES;

// Put overlapping bookings side by side.
function layout(items) {
  const sorted = [...items].sort((a, b) => a.startM - b.startM || b.endM - a.endM);
  const placed = [];
  let cluster = [];
  let clusterEnd = -1;
  const flush = () => {
    const lanes = [];
    for (const it of cluster) {
      let lane = lanes.findIndex((end) => end <= it.startM);
      if (lane === -1) { lane = lanes.length; lanes.push(it.endM); } else lanes[lane] = it.endM;
      it.lane = lane;
    }
    for (const it of cluster) { it.lanes = lanes.length; placed.push(it); }
    cluster = [];
  };
  for (const it of sorted) {
    if (cluster.length && it.startM >= clusterEnd) { flush(); clusterEnd = -1; }
    cluster.push(it);
    clusterEnd = Math.max(clusterEnd, it.endM);
  }
  if (cluster.length) flush();
  return placed;
}

export const canDrag = (appt) => ["scheduled", "confirmed"].includes(appt.status);

/**
 * columns: [{ key, title, sub, dayStart, today, staffId, color, appts, blocks }]
 * Events and blocks are positioned from their time inside dayStart.
 */
export function TimeGrid({
  columns, tz, startMin, endMin, people, staffName, now, onOpen, onOpenBlock, onBook, onMove, term, showStaff = true, guestWord = null,
}) {
  const scale = PX_PER_HOUR / 60;
  const height = (endMin - startMin) * scale;
  const bodies = useRef([]);
  const gesture = useRef(null);
  const justDragged = useRef(false);
  const [drag, setDrag] = useState(null);
  const hours = [];
  for (let m = Math.ceil(startMin / 60) * 60; m < endMin; m += 60) hours.push(m);

  const placedByColumn = useMemo(() => columns.map((c) => layout(
    c.appts.map((a) => {
      const s = minutesInto(a.start_time, c.dayStart);
      const e = Math.max(s + 20, minutesInto(a.end_time, c.dayStart));
      return { a, startM: s, endM: e };
    }),
  )), [columns]);

  function columnAt(clientX) {
    for (let i = 0; i < bodies.current.length; i += 1) {
      const el = bodies.current[i];
      if (!el) continue;
      const r = el.getBoundingClientRect();
      if (clientX >= r.left && clientX <= r.right) return { index: i, rect: r };
    }
    return null;
  }

  function startDrag(event, appt, startM, durM) {
    if (event.button !== 0 || !canDrag(appt) || !onMove) return;
    const box = event.currentTarget.getBoundingClientRect();
    gesture.current = {
      appt, startX: event.clientX, startY: event.clientY, moved: false,
      grab: (event.clientY - box.top) / scale, durM, startM, id: event.pointerId,
    };
    event.currentTarget.setPointerCapture?.(event.pointerId);
  }

  function moveDrag(event) {
    const g = gesture.current;
    if (!g) return;
    if (!g.moved && Math.hypot(event.clientX - g.startX, event.clientY - g.startY) < 6) return;
    g.moved = true;
    const col = columnAt(event.clientX);
    if (!col) return;
    const pointerMin = startMin + (event.clientY - col.rect.top) / scale;
    const top = Math.min(Math.max(snap(pointerMin - g.grab), startMin), endMin - g.durM);
    g.target = { col: col.index, top };
    setDrag({ id: g.appt.id, col: col.index, top, durM: g.durM });
  }

  function endDrag(event, appt) {
    const g = gesture.current;
    gesture.current = null;
    event.currentTarget.releasePointerCapture?.(event.pointerId);
    setDrag(null);
    if (!g) return;
    if (g.moved && g.target) {
      justDragged.current = true;
      setTimeout(() => { justDragged.current = false; }, 0);
      const changed = g.target.col !== columns.findIndex((c) => c.appts.some((x) => x.id === appt.id)) || Math.abs(g.target.top - g.startM) >= 1;
      if (changed) onMove(appt, g.target.col, g.target.top);
      return;
    }
    onOpen(appt);
  }

  function clickBody(event, index) {
    if (justDragged.current || event.target !== event.currentTarget) return;
    const rect = event.currentTarget.getBoundingClientRect();
    const minute = Math.min(Math.max(snap(startMin + (event.clientY - rect.top) / scale - SNAP_MINUTES / 2), startMin), endMin - SNAP_MINUTES);
    onBook?.(index, minute);
  }

  const nowM = now ? minutesInto(now, columns.find((c) => c.today)?.dayStart ?? new Date()) : null;

  return (
    <div className="ba-tg" role="grid" aria-label="Calendar">
      <div className="ba-tg-head" style={{ gridTemplateColumns: `52px repeat(${columns.length}, minmax(112px, 1fr))`, minWidth: 52 + columns.length * 112 }}>
        <span />
        {columns.map((c) => (
          <div key={c.key} className={`ba-tg-title ${c.today ? "today" : ""}`}>
            {c.color && <i style={{ background: c.color }} />}
            <strong>{c.title}</strong>
            {c.sub && <small>{c.sub}</small>}
          </div>
        ))}
      </div>
      <div className="ba-tg-scroll">
        <div className="ba-tg-body" style={{ gridTemplateColumns: `52px repeat(${columns.length}, minmax(112px, 1fr))`, minWidth: 52 + columns.length * 112, height }}>
          <div className="ba-tg-hours">
            {hours.map((m) => <span key={m} style={{ top: (m - startMin) * scale }}>{hourLabel(m / 60)}</span>)}
          </div>
          {columns.map((c, index) => (
            <div
              key={c.key}
              ref={(el) => { bodies.current[index] = el; }}
              className={`ba-tg-col ${c.today ? "today" : ""}`}
              onClick={(e) => clickBody(e, index)}
              title={onBook ? "Click an empty time to book" : undefined}
              style={{ backgroundSize: `100% ${PX_PER_HOUR}px`, backgroundPosition: `0 ${-((startMin % 60) * scale)}px` }}
            >
              {c.blocks.map((b) => {
                const s = Math.max(startMin, minutesInto(b.start_time, c.dayStart));
                const e = Math.min(endMin, minutesInto(b.end_time, c.dayStart));
                if (e <= s) return null;
                return (
                  <button key={b.id} type="button" className="ba-tg-block" style={{ top: (s - startMin) * scale, height: Math.max(18, (e - s) * scale) }}
                    onClick={(ev) => { ev.stopPropagation(); onOpenBlock(b); }}>
                    <Icon name="block" size="sm" /><span>{b.title}{b.staff_id && staffName[b.staff_id] ? `: ${staffName[b.staff_id]}` : ""}</span>
                  </button>
                );
              })}
              {placedByColumn[index].map(({ a, startM, endM, lane, lanes }) => {
                const dragging = drag?.id === a.id;
                const person = personName(people[a.customer_id]);
                const pending = a.booking_state === "requested" || a.booking_state === "tentative";
                return (
                  <div
                    key={a.id}
                    role="button"
                    tabIndex={0}
                    className={`ba-ev ${a.status} ${pending ? "pending-state" : ""} ${a.conflict_note ? "conflict" : ""} ${canDrag(a) && onMove ? "movable" : ""} ${dragging ? "dragging" : ""} ${(endM - startM) * scale < 46 ? "short" : ""}`}
                    style={{
                      top: (startM - startMin) * scale, height: Math.max(22, (endM - startM) * scale - 2),
                      left: `calc(${(lane / lanes) * 100}% + 2px)`, width: `calc(${100 / lanes}% - 4px)`,
                      ...(c.color ? { "--ev": c.color } : {}),
                    }}
                    onPointerDown={(e) => startDrag(e, a, startM, endM - startM)}
                    onPointerMove={moveDrag}
                    onPointerUp={(e) => endDrag(e, a)}
                    onPointerCancel={() => { gesture.current = null; setDrag(null); }}
                    onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); onOpen(a); } }}
                    aria-label={`${a.title}, ${formatTime(a.start_time, tz)}${person ? `, ${person}` : ""}`}
                  >
                    <span className="ba-ev-time">
                      <b>{formatTime(a.start_time, tz)}</b>{endM - startM >= 15 && <span className="ba-ev-len">· {Math.round(endM - startM)} min</span>}
                      {a.checked_in_at && <Icon name="how_to_reg" size="sm" />}{a.conflict_note && <Icon name="warning" size="sm" />}
                      {["zella", "ai_receptionist"].includes(a.metadata?.source) && <Icon name="smart_toy" size="sm" />}
                    </span>
                    <span className="ba-ev-title">{a.booking_state === "requested" ? "Requested: " : a.booking_state === "tentative" ? "Held: " : ""}{person ?? a.title}</span>
                    <span className="ba-ev-who">{[person ? a.appointment_type || a.title : a.appointment_type, showStaff && a.staff_id ? staffName[a.staff_id] : null,
                      guestWord && a.party_size ? `${a.party_size} ${guestWord}` : null, a.status === "cancelled" ? "Cancelled" : a.status === "no_show" ? "No-show" : null].filter(Boolean).join(" · ")}</span>
                  </div>
                );
              })}
              {drag && drag.col === index && (
                <div className="ba-ev ghost" style={{ top: (drag.top - startMin) * scale, height: Math.max(22, drag.durM * scale - 2) }}>
                  <span className="ba-ev-time">{formatTime(new Date(c.dayStart.getTime() + drag.top * 60000), tz)}</span>
                </div>
              )}
              {c.today && nowM !== null && nowM >= startMin && nowM <= endMin && <i className="ba-tg-now" style={{ top: (nowM - startMin) * scale }} />}
            </div>
          ))}
        </div>
      </div>
      {term && <p className="ba-muted ba-tg-hint">Click an empty time to book. Drag a {term.toLowerCase()} to move it.</p>}
    </div>
  );
}

/** cells: [{ key, offset, d, inMonth, today, appts, blocks }] (6 weeks). */
export function MonthGrid({ cells, tz, people, onPickDay, onOpen }) {
  const names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  return (
    <div className="ba-mg" role="grid" aria-label="Month">
      {names.map((n) => <div key={n} className="ba-mg-dow">{n}</div>)}
      {cells.map((c) => {
        const live = c.appts.filter((a) => a.status !== "cancelled");
        return (
          <div key={c.key} className={`ba-mg-cell ${c.inMonth ? "" : "out"} ${c.today ? "today" : ""}`}>
            <button type="button" className="ba-mg-day" onClick={() => onPickDay(c.offset)} aria-label={`Open ${c.key}`}>{c.d}</button>
            {c.blocks.length > 0 && <small className="ba-mg-blocked">Blocked</small>}
            {live.slice(0, 3).map((a) => (
              <button key={a.id} type="button" className={`ba-mg-chip ${a.status}`} onClick={() => onOpen(a)}>
                <b>{formatTime(a.start_time, tz)}</b> {personName(people[a.customer_id]) || a.title}
              </button>
            ))}
            {live.length > 3 && <button type="button" className="ba-mg-more" onClick={() => onPickDay(c.offset)}>+{live.length - 3} more</button>}
          </div>
        );
      })}
    </div>
  );
}
