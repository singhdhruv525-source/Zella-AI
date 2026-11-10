import { useRef } from "react";
import { Icon } from "./BusinessUI";

/* The floor plan: each table drawn where the owner placed it (Settings > Tables and seating), with its chairs, its
   name and seats, and its state from the seating board (zella_table_board). Used by the Tables page, the Today
   dashboard and the layout editor. Positions only change the drawing; availability never depends on them.
   States always show a word and an icon as well as a colour. */

export const FLOOR_STATES = {
  seated: { label: "Occupied", icon: "restaurant" },
  reserved: { label: "Reserved", icon: "event" },
  held: { label: "Held", icon: "hourglass_top" },
  available: { label: "Available", icon: "check_circle" },
  needs_clearing: { label: "Needs clearing", icon: "cleaning_services" },
  unavailable: { label: "Unavailable", icon: "block" },
};
const LEGEND = ["seated", "reserved", "available", "needs_clearing", "unavailable"];

// where a table sits when the owner hasn't placed it yet: an even grid in the board's order
export function autoPlace(tables) {
  const n = tables.length;
  const cols = Math.max(1, Math.min(5, Math.ceil(Math.sqrt(n * 1.6))));
  const rows = Math.max(1, Math.ceil(n / cols));
  return tables.map((t, i) => (t.x != null && t.y != null ? t : {
    ...t, x: cols === 1 ? 50 : 12 + (i % cols) * (76 / (cols - 1)), y: rows === 1 ? 50 : 18 + Math.floor(i / cols) * (64 / (rows - 1)),
  }));
}

// chairs around a table: along the long sides first for squares and rectangles, evenly around for round tables
function chairs(shape, seats) {
  const n = Math.max(1, Math.min(12, seats));
  if (shape === "round") return Array.from({ length: n }, (_, i) => { const a = (2 * Math.PI * i) / n - Math.PI / 2; return { x: 50 + 62 * Math.cos(a), y: 50 + 62 * Math.sin(a), r: a }; });
  const top = Math.ceil(n / 2), bottom = n - top;
  if (n <= 2 && shape !== "rect") return [{ x: 50, y: -14, side: "t" }, { x: 50, y: 114, side: "b" }].slice(0, n);
  const row = (k, y, side) => Array.from({ length: k }, (_, i) => ({ x: ((i + 1) * 100) / (k + 1), y, side }));
  if (n >= 6 && shape !== "rect") { const ends = 2; const rest = n - ends; return [...row(Math.ceil(rest / 2), -14, "t"), ...row(Math.floor(rest / 2), 114, "b"), { x: -14, y: 50, side: "l" }, { x: 114, y: 50, side: "r" }]; }
  return [...row(top, -14, "t"), ...row(bottom, 114, "b")];
}

function size(t, compact) {
  const base = compact ? 0.56 : 1;
  const s = t.seats <= 2 ? 58 : t.seats <= 4 ? 70 : t.seats <= 6 ? 84 : 96;
  const w = t.shape === "rect" ? s * 1.55 : s;
  const min = compact ? 42 : 0;   // small tables stay readable in the dashboard view
  return { w: Math.max(min, Math.round(w * base)), h: Math.max(min, Math.round(s * base)) };
}

export function FloorPlan({ tables, selectedId, onSelect, compact = false, editable = false, onMove, label = "Floor plan", tz, formatTime }) {
  const box = useRef(null);
  const drag = useRef(null);
  const placed = autoPlace(tables);

  const toPercent = (clientX, clientY) => {
    const r = box.current.getBoundingClientRect();
    return { x: Math.min(96, Math.max(4, ((clientX - r.left) / r.width) * 100)), y: Math.min(94, Math.max(6, ((clientY - r.top) / r.height) * 100)) };
  };
  const down = (t) => (e) => { if (!editable) return; e.currentTarget.setPointerCapture(e.pointerId); drag.current = t.id; };
  const move = (t) => (e) => { if (!editable || drag.current !== t.id) return; const p = toPercent(e.clientX, e.clientY); onMove?.(t.id, Math.round(p.x * 10) / 10, Math.round(p.y * 10) / 10); };
  const up = () => { drag.current = null; };
  const key = (t) => (e) => {
    if (!editable) return;
    const step = e.shiftKey ? 5 : 1;
    const d = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step] }[e.key];
    if (!d) return;
    e.preventDefault();
    onMove?.(t.id, Math.min(96, Math.max(4, t.x + d[0])), Math.min(94, Math.max(6, t.y + d[1])));
  };

  return (
    <div className={`fp ${compact ? "compact" : ""} ${editable ? "editable" : ""}`}>
      <div className="fp-room" ref={box} role="group" aria-label={label}>
        {!placed.length && <p className="fp-empty">No tables in this section.</p>}
        {placed.map((t) => {
          const st = FLOOR_STATES[t.state] ?? FLOOR_STATES.available;
          const { w, h } = size(t, compact);
          const sub = t.state === "seated" && t.current ? `${t.current.guest ?? "Guest"}, party of ${t.current.party}`
            : t.next && formatTime ? `next ${formatTime(t.next.at, tz)}` : "";
          return (
            <button key={t.id} type="button"
              className={`fp-table shape-${t.shape ?? "square"} st-${t.state ?? "available"} ${t.id === selectedId ? "selected" : ""}`}
              style={{ left: `${t.x}%`, top: `${t.y}%`, width: w, height: h }}
              onClick={() => onSelect?.(t.id)} onPointerDown={down(t)} onPointerMove={move(t)} onPointerUp={up} onKeyDown={key(t)}
              aria-pressed={selectedId ? t.id === selectedId : undefined}
              aria-label={`${t.name}, ${t.seats} seats, ${st.label}${sub ? `, ${sub}` : ""}${editable ? ". Drag, or use the arrow keys, to move it" : ""}`}>
              {chairs(t.shape, t.seats).map((c, i) => (
                <span key={i} className={`fp-chair ${c.side ?? "round"}`} style={{ left: `${c.x}%`, top: `${c.y}%`, ...(c.r !== undefined ? { transform: `translate(-50%, -50%) rotate(${c.r + Math.PI / 2}rad)` } : {}) }} aria-hidden="true" />
              ))}
              <span className="fp-name">{t.name}</span>
              <span className="fp-seats">({t.seats})</span>
              <span className="fp-state" title={st.label}><Icon name={st.icon} size="sm" /></span>
            </button>
          );
        })}
      </div>
      <ul className="fp-legend" aria-label="Key">
        {LEGEND.map((k) => <li key={k}><span className={`fp-swatch st-${k}`} aria-hidden="true" /><Icon name={FLOOR_STATES[k].icon} size="sm" />{FLOOR_STATES[k].label}</li>)}
      </ul>
    </div>
  );
}
