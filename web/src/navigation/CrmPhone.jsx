import { useEffect, useState } from "react";
import { supabase } from "../supabase";
import { Icon, personName } from "../BusinessUI";
import { BottomSheet } from "./BottomSheet";
import { needsNowRows } from "./phoneHelpers.js";

// The CRM's phone parts (approved 25 Nov 2026): the "Needs you now" block on Today (P14), the business switcher and
// Quick actions as sheets (P10, P12), and the data the live strip and the More count read (P5, P13). Everything is
// read with the member's own session, so row level security keeps it to this business.

const SPAM_ROLES = ["owner", "admin", "manager"];
const DAY = 864e5;

// Live signals for "Needs you now": the callers waiting for a person, overdue tasks and spam to review. Read on every
// screen size, because the notification bell shows the same items (owner, 25 Nov 2026, crm/needsNowNotes.js); the
// phone also uses them for the live strip, Today's block and the More count. Refreshed with the waiting count, on a
// refresh and every minute.
const WAITING_PAGE = 100;   // read in pages up to a hard cap; callers past it share one summary note in the bell
const WAITING_CAP = 500;
const OVERDUE_LIMIT = 100;
export function useCrmSignals(workspace, { enabled, attention, refreshKey }) {
  const [signals, setSignals] = useState({ oldest: null, waiting: [], waitingMore: 0, overdue: [], spam: 0, complete: {}, at: null });
  const [tick, setTick] = useState(0);
  useEffect(() => {
    if (!enabled) return undefined;
    const timer = setInterval(() => setTick((n) => n + 1), 60000);
    return () => clearInterval(timer);
  }, [enabled]);
  useEffect(() => {
    if (!enabled) return undefined;
    let live = true;
    const id = workspace.id;
    const now = new Date();
    // every waiting call, oldest first, a page at a time up to the cap; the first page also says how many there are
    const page = (from, count) => supabase.from("calls_view").select("id, customer_id, from_number, summary, escalated_at, created_at", count ? { count: "exact" } : undefined)
      .eq("business_id", id).eq("needs_human", true).is("escalation_resolved_at", null)
      .order("escalated_at", { ascending: true, nullsFirst: false }).order("id", { ascending: true }).range(from, from + WAITING_PAGE - 1);
    const waiting = (async () => {
      const first = await page(0, true);
      if (first.error) return first;
      const rows = [...(first.data ?? [])];
      const total = Number.isFinite(first.count) ? first.count : null;
      let last = first.data ?? [];
      while (last.length === WAITING_PAGE && rows.length < WAITING_CAP) {
        const next = await page(rows.length, false);
        if (next.error) return { data: rows, error: next.error, total };
        last = next.data ?? [];
        rows.push(...last);
      }
      return { data: rows.slice(0, WAITING_CAP), total, error: null };
    })();
    const overdue = supabase.from("crm_tasks").select("id, title, due_at, customer_id").eq("business_id", id).eq("status", "open")
      .lt("due_at", now.toISOString()).order("due_at", { ascending: true }).limit(OVERDUE_LIMIT);
    const spam = SPAM_ROLES.includes(workspace.role)
      ? supabase.rpc("zella_spam_overview", { p_business_id: id, p_from: new Date(now.getTime() - 30 * DAY).toISOString(), p_to: now.toISOString() })
      : Promise.resolve({ data: null });
    Promise.all([waiting, overdue, spam].map((p) => Promise.resolve(p).catch((error) => ({ data: null, error })))).then(async ([w, o, s]) => {
      const calls = w.data ?? [];   // a page that failed part way keeps the ones read (the list is then not complete)
      const tasks = o.error ? [] : o.data ?? [];
      const ids = [...new Set([...calls, ...tasks].map((r) => r.customer_id).filter(Boolean))];
      const people = ids.length
        ? await Promise.resolve(supabase.from("customers").select("id, first_name, last_name, company_name").in("id", ids)).catch(() => ({ data: [] }))
        : { data: [] };
      const nameOf = Object.fromEntries((people.data ?? []).map((p) => [p.id, personName(p)]));
      if (!live) return;
      const list = calls.map((c) => ({ id: c.id, name: nameOf[c.customer_id] ?? c.from_number ?? null, since: c.escalated_at ?? c.created_at, summary: c.summary }));
      setSignals({
        oldest: list[0] ?? null,
        waiting: list,
        // callers past the cap (or a count that moved while reading): one summary note, so the bell counts them all
        waitingMore: Number.isFinite(w.total) ? Math.max(0, w.total - list.length) : 0,
        overdue: tasks.map((t) => ({ ...t, who: nameOf[t.customer_id] ?? null })),
        spam: Number(s.data?.unreviewed) || 0,
        // a list read in full: anything missing from it has been dealt with
        complete: { waiting: !w.error && Boolean(w.data) && Number.isFinite(w.total) && calls.length >= w.total, task: !o.error && Boolean(o.data) && tasks.length < OVERDUE_LIMIT },
        at: now.toISOString(),
      });
    });
    return () => { live = false; };
  }, [enabled, workspace.id, workspace.role, attention, refreshKey, tick]);
  return signals;
}

// P14: the top of Today. Shown only when something needs the owner.
export function NeedsYouNow({ attention, signals, onGo }) {
  const rows = needsNowRows({ waiting: attention, oldest: signals.oldest, overdue: signals.overdue, spam: signals.spam });
  if (!rows.length) return null;
  return (
    <section aria-labelledby="pn-now-title">
      <h2 id="pn-now-title" className="pn-list-label">Needs you now</h2>
      <ul className="pn-list">
        {rows.map((r) => (
          <li key={r.key}>
            <button type="button" className="pn-item" onClick={() => onGo(r.page)}>
              <span className={`pn-lead ${r.tone}`}><Icon name={r.icon} /></span>
              <span className="pn-main"><strong>{r.title}</strong><small>{r.sub}</small></span>
              {r.meta && <span className="pn-meta">{r.meta}</span>}
            </button>
          </li>
        ))}
      </ul>
    </section>
  );
}

const initialsOf = (name) => (name || "?").split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0].toUpperCase()).join("");

// The business button in the phone top bar and at the top of the side panel.
export function BusinessButton({ workspace, config, onClick, variant = "top", expanded }) {
  const subtitle = [config?.industry?.name ?? workspace.industry, config?.location].filter(Boolean).join(", ");
  const logo = config?.logo_url ? <img src={config.logo_url} alt="" className="ba-switcher-logo" /> : <span className="ba-switcher-logo" aria-hidden="true">{initialsOf(workspace.name)}</span>;
  if (variant === "card") {
    return (
      <button type="button" className="pn-card-btn" onClick={onClick} aria-haspopup="dialog">
        {logo}
        <span><strong>{workspace.name}</strong>{subtitle && <small>{subtitle}</small>}</span>
        <span className="pn-card-end">Switch</span>
      </button>
    );
  }
  return (
    <button type="button" className="pn-biz" onClick={onClick} aria-haspopup="dialog" aria-expanded={expanded}
      aria-label={`${workspace.name}. Switch business or open its settings`}>
      {logo}
      <span><strong>{workspace.name}</strong>{subtitle && <small>{subtitle}</small>}</span>
      <Icon name="expand_more" />
    </button>
  );
}

// The business switcher as a sheet (P9, P12): the other businesses, then this one's settings (the same as the
// desktop switcher menu).
export function SwitcherSheet({ workspace, workspaces, canManage, onSwitch, onGo, onClose }) {
  const others = workspaces.filter((w) => w.id !== workspace.id);
  const go = (path) => { onClose(); onGo(path); };
  return (
    <BottomSheet title={workspace.name} description="Switch business or open its settings" size="fit" onClose={onClose}>
      {others.length > 0 && (
        <div className="pn-sheet-section">
          <h3>Switch business</h3>
          <div className="pn-menu-list">
            {others.map((w) => (
              <button key={w.id} type="button" className="pn-row-link" onClick={() => { onClose(); onSwitch(w.id); }}>
                <span className="ba-switcher-logo sm" aria-hidden="true">{initialsOf(w.name)}</span>
                <span>{w.name}<small className="ba-muted"> · {w.industry ?? "Industry not set"}</small></span>
              </button>
            ))}
          </div>
        </div>
      )}
      <div className="pn-menu-list">
        <button type="button" className="pn-row-link" onClick={() => go("settings/profile/info")}><Icon name="storefront" /><span>Business profile</span></button>
        <button type="button" className="pn-row-link" onClick={() => go("settings/industry/modules")}><Icon name="widgets" /><span>Modules and industry</span></button>
        {canManage && <button type="button" className="pn-row-link" onClick={() => go("settings/team/members")}><Icon name="group_add" /><span>Team members</span></button>}
        <button type="button" className="pn-row-link" onClick={() => go("settings/billing/plan")}><Icon name="credit_card" /><span>Plan and billing</span></button>
      </div>
    </BottomSheet>
  );
}

// Quick actions from Today's round button (P10): Seat a walk in, Add lead, New task, Tell callers. Only the ones this
// person may use are offered.
export function QuickActionsSheet({ actions, onClose }) {
  return (
    <BottomSheet title="Quick actions" size="fit" onClose={onClose}>
      <div className="pn-sheet-actions" style={{ "--pn-sa": Math.min(4, actions.length) }}>
        {actions.map((a) => (
          <button key={a.key} type="button" onClick={() => { onClose(); a.onClick(); }}>
            <Icon name={a.icon} /><span>{a.label}</span>
          </button>
        ))}
      </div>
    </BottomSheet>
  );
}
