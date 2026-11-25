import { useEffect, useState } from "react";
import { supabase } from "../supabase";
import { Icon } from "../BusinessUI";
import { callOwnerFunction } from "../CreateBusinessWizard";
import { Pill } from "../OwnerOverview";
import { lastCallLabel, ownerCell, planCell, problemSummary, rowActions, stageCell } from "../businessList";
import { BottomSheet } from "./BottomSheet";

// The admin's phone parts (approved 25 Nov 2026): the counts on Support and Operations (P5), the open incidents for
// the live strip (P13), and a business as a bottom sheet (P12). Platform alerts and incidents are readable by Zella
// Voice admins only (row level security); the open ticket count comes from the same overview the Overview page reads.

export function useAdminSignals({ enabled, can }) {
  const [signals, setSignals] = useState({ alerts: 0, incidents: [], tickets: 0 });
  const view = enabled && can("businesses.view");
  const support = view && can("support.manage");
  useEffect(() => {
    if (!view) return undefined;
    let live = true;
    const read = async () => {
      const [alerts, incidents] = await Promise.all([
        Promise.resolve(supabase.from("platform_alerts").select("id, severity").eq("status", "open").limit(200)).catch(() => ({ data: null })),
        Promise.resolve(supabase.from("platform_incidents").select("id, title, status, created_at").eq("status", "open").order("created_at", { ascending: true }).limit(20)).catch(() => ({ data: null })),
      ]);
      if (!live) return;
      setSignals((s) => ({
        ...s,
        // a failed read keeps the last counts: never shown as "all calm" because it couldn't be read
        alerts: alerts.data ? alerts.data.filter((a) => a.severity !== "info").length : s.alerts,
        incidents: incidents.data ?? s.incidents,
      }));
    };
    read();
    const timer = setInterval(read, 60000);
    return () => { live = false; clearInterval(timer); };
  }, [view]);
  useEffect(() => {
    if (!support) return undefined;
    let live = true;
    const read = () => callOwnerFunction("overview_data").then((d) => {
      const n = Number(d?.stats?.openTickets);
      if (live && Number.isFinite(n)) setSignals((s) => ({ ...s, tickets: n }));
    }).catch(() => {});
    read();
    const timer = setInterval(read, 5 * 60000);
    return () => { live = false; clearInterval(timer); };
  }, [support]);
  return signals;
}

// A business from the list, as a sheet: where it stands, and the ways on (P12).
export function BusinessSheet({ b, canManage, onOpen, onSetup, onClose }) {
  const owner = ownerCell(b.owner);
  const stage = stageCell(b);
  const plan = planCell(b.plan, b.subscription);
  const problems = problemSummary(b.problems);
  const act = rowActions(b, canManage);
  const industry = b.industry_name ?? "No industry";
  const phone = b.owner?.phone;
  return (
    <BottomSheet title={b.name} description={b.owner ? `${industry}, owner ${owner.title}` : industry} onClose={onClose}>
      <div className="pn-sheet-section"><Pill tone={stage.tone}>{stage.label}</Pill></div>
      <div className="pn-facts">
        <div><small>Plan</small><strong>{plan.label || "Not available"}</strong></div>
        <div><small>Stage</small><strong>{stage.label}</strong></div>
        <div><small>Last call</small><strong>{lastCallLabel(b.lastCallAt)}</strong></div>
      </div>
      <div className="pn-sheet-actions" style={{ "--pn-sa": 2 + (phone ? 1 : 0) + (act.main === "setup" ? 1 : 0) }}>
        <button type="button" onClick={() => { onClose(); onOpen(b.id); }}><Icon name="open_in_new" /><span>Open</span></button>
        {act.main === "setup" && <button type="button" onClick={() => { onClose(); onSetup(b.id); }}><Icon name="play_arrow" /><span>Continue setup</span></button>}
        {phone && <a href={`tel:${phone}`}><Icon name="call" /><span>Call owner</span></a>}
        <button type="button" onClick={() => { onClose(); onOpen(b.id, "activity"); }}><Icon name="history" /><span>Activity</span></button>
      </div>
      {problems.count > 0 && (
        <div className="pn-sheet-section">
          <h3>Needs attention</h3>
          <p>{problems.detail || problems.label}</p>
        </div>
      )}
      {stage.note && <div className="pn-sheet-section"><h3>Setup</h3><p>{stage.note}</p></div>}
    </BottomSheet>
  );
}
