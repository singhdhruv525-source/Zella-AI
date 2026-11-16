// One business's page, Automations tab: every automation with its status, and (UI-09) Pause and Resume with a reason
// through zella_admin_automation_set_status (integrations.manage, audited as automation.paused or .resumed), "Set up"
// for ones not set up (the wizard's Automations step), and a link to the Automations page.
import { useState } from "react";
import AutomationOverview from "../AutomationOverview";
import { navigate } from "../router";
import { rpc } from "../admin/adminOps";
import ActionDialog from "./ActionDialog";
import { Card, describeSettings } from "./shared";

export default function AutomationsTab({ data, b, term, enabledAutomations, can, canManage, onOpenSetup, isCancelled, load }) {
  const [dialog, setDialog] = useState(null);
  const [notice, setNotice] = useState("");
  // BIZ-07: live = went live, not suspended, not cancelled. Resume only then (the Automations page still treats drafts as
  // live until its own rule changes).
  const live = b.onboarding_status === "active" && !b.suspended_at && !b.cancelled_at;
  const canPause = can?.("integrations.manage") && !isCancelled;
  const action = (row) => {
    if (!row) return canManage && !isCancelled ? <button type="button" className="owner-secondary-button op-small" onClick={() => onOpenSetup(b.id)}>Set up</button> : null;
    if (!canPause || !row.id) return null;
    if (row.status === "active") return <button type="button" className="owner-secondary-button op-small" onClick={() => setDialog({ row, to: "paused" })}>Pause</button>;
    if (row.status === "paused" && live) return <button type="button" className="owner-secondary-button op-small" onClick={() => setDialog({ row, to: "active" })}>Resume</button>;
    return null;
  };
  return (
    <Card title="Automations" description={live ? "What this business sends automatically. Turning one on starts it." : "What this business sends automatically. Paused ones start when it goes live."}
      action={<button type="button" className="owner-secondary-button op-small" onClick={() => navigate("/automations")}>Manage in Automations</button>}>
      {notice && <div className="ic-notice" role="status">{notice}</div>}
      <AutomationOverview rows={data.automations} industryName={data.industryName} appointmentWord={String(term("appointment")).toLowerCase()}
        describeSettings={describeSettings} renderAction={action} />
      {enabledAutomations.length > 0 && <p className="op-muted op-gap-top">{enabledAutomations.length} turned on.</p>}
      {dialog && (
        <ActionDialog title={dialog.to === "paused" ? "Pause this automation?" : "Resume this automation?"}
          body={dialog.to === "paused" ? "It stops sending until it is resumed." : "It starts sending again for this live business."}
          button={dialog.to === "paused" ? "Pause" : "Resume"} danger={dialog.to === "paused"} reason={{ min: 3, max: 300 }}
          onRun={(reason) => rpc("zella_admin_automation_set_status", { p_id: dialog.row.id, p_status: dialog.to, p_reason: reason })}
          onDone={async () => { setNotice(dialog.to === "paused" ? "Automation paused." : "Automation resumed."); setDialog(null); await load(); }}
          onClose={() => setDialog(null)} />
      )}
    </Card>
  );
}
