import { useEffect, useState } from "react";
import { supabase } from "../supabase";
import { Icon } from "../BusinessUI";
import { callOwnerFunction } from "../CreateBusinessWizard";
import { Pill } from "../OwnerOverview";
import { lastCallLabel, ownerCell, planCell, problemSummary, rowActions, stageCell } from "../businessList";
import { BottomSheet } from "./BottomSheet";
import { SIGNAL_START, signalReduce } from "./phoneHelpers.js";
import { countValue } from "../crm/needsNowSignals.js";

// The admin's phone parts (approved 25 Nov 2026): the counts on Support and Operations (P5), the open incidents for
// the live strip (P13), and a business as a bottom sheet (P12). Platform alerts and incidents are readable by Zella
// Voice admins only (row level security); the open ticket count comes from the same overview the Overview page reads.

// Each reading keeps whether it worked (phoneHelpers signalReduce): a failed read is never shown as "nothing wrong",
// and a later failure marks the last good value as possibly out of date. Without businesses.view nothing is read and
// nothing earlier is returned; without support.manage there is no ticket count.
const EMPTY = { alerts: SIGNAL_START, incidents: SIGNAL_START, tickets: SIGNAL_START };
export function useAdminSignals({ enabled, can }) {
  const [signals, setSignals] = useState(EMPTY);
  const view = enabled && can("businesses.view");
  const support = view && can("support.manage");
  const apply = (key, event) => setSignals((s) => ({ ...s, [key]: signalReduce(s[key], event) }));
  useEffect(() => {
    if (!view) return undefined;
    let live = true;
    apply("alerts", { type: "reset" });
    apply("incidents", { type: "reset" });
    const read = async () => {
      const [alerts, incidents] = await Promise.all([
        Promise.resolve(supabase.from("platform_alerts").select("id, severity").eq("status", "open").limit(200)).catch((error) => ({ data: null, error })),
        Promise.resolve(supabase.from("platform_incidents").select("id, title, status, created_at").eq("status", "open").order("created_at", { ascending: true }).limit(20)).catch((error) => ({ data: null, error })),
      ]);
      if (!live) return;
      apply("alerts", alerts.error || !alerts.data ? { type: "fail" } : { type: "ok", value: alerts.data.filter((a) => a.severity !== "info").length });
      apply("incidents", incidents.error || !incidents.data ? { type: "fail" } : { type: "ok", value: incidents.data });
    };
    read();
    const timer = setInterval(read, 60000);
    return () => { live = false; clearInterval(timer); };
  }, [view]);
  useEffect(() => {
    if (!support) return undefined;
    let live = true;
    apply("tickets", { type: "reset" });
    const read = () => callOwnerFunction("overview_data").then((d) => {
      const n = countValue(d?.stats?.openTickets);   // null, "" or anything not a count is a failed read, a real 0 is not
      if (live) apply("tickets", n === null ? { type: "fail" } : { type: "ok", value: n });
    }, () => { if (live) apply("tickets", { type: "fail" }); });
    read();
    const timer = setInterval(read, 5 * 60000);
    return () => { live = false; clearInterval(timer); };
  }, [support]);
  // what a person may no longer see is never handed on, even for the moment before the next read
  if (!view) return EMPTY;
  return support ? signals : { ...signals, tickets: SIGNAL_START };
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
