import { useState } from "react";
import { callOwnerFunction } from "../../CreateBusinessWizard";
import { Banner, Card, Confirm, Facts, Field, LoadState, Pill, Table, useAsync, when } from "../SettingsKit";
import BusinessPicker from "./BusinessPicker";

// Settings > Legal > Policy configuration: recording on or off per business
// (owner-provision-business retention.ts, sql/zella_recording_policy.sql). Off for every business until a Zella Voice
// owner records legal approval with the caller disclosure line (D-27). The phone assistant doesn't read this yet.

const call = (action, payload) => callOwnerFunction(action, payload);

export default function RecordingPolicy({ me }) {
  const state = useAsync(() => call("recording_policy_get"), []);
  const [dialog, setDialog] = useState(null);
  const owner = me?.role === "zella_owner";
  const manage = Boolean(me?.permissions?.includes("businesses.manage"));
  return (
    <LoadState state={state}>{(p) => (
      <>
        <Card title="Call recording" sub="Off for every business until legal review of recording consent and the caller disclosure (D-27)."
          actions={owner && (p.legal_approved
            ? <button type="button" className="zs-btn sm danger-outline" onClick={() => setDialog({ legal: false })}>Withdraw legal approval</button>
            : <button type="button" className="zs-btn sm" onClick={() => setDialog({ legal: true, disclosure: p.disclosure })}>Record legal approval</button>)}>
          <Facts rows={[
            ["Legal review", p.legal_approved ? <Pill key="l" tone="success">Approved</Pill> : <Pill key="l" tone="warning">Pending legal review</Pill>],
            ["What callers hear when recording is on", p.disclosure ? `"${p.disclosure}"` : "Not set yet. Legal provides the wording."],
            ["Businesses the policy allows to record", p.businesses.filter((b) => b.effective).length],
            ["Phone assistant", "Doesn't read this policy yet. Connecting it to live calls is a separate change that needs its own approval; until then Vapi's own settings decide."],
          ]} />
          {!owner && <p className="zs-muted">Only a Zella Voice owner records the legal review.</p>}
        </Card>
        <Card title="Per business" sub="No row means off."
          actions={manage && <button type="button" className="zs-btn sm" onClick={() => setDialog({ business: "", on: false })}>Set for a business</button>}>
          <Table rows={p.businesses} rowKey={(b) => b.business_id} empty="No business has a recording policy yet, so recording is off for all of them." columns={[
            ["Business", (b) => b.name], ["Policy", (b) => (b.recording_on ? "On" : "Off")],
            ["Allowed by policy", (b) => <Pill tone={b.effective ? "success" : ""}>{b.effective ? "Allowed" : "Off"}</Pill>],
            ["Reason", (b) => b.reason], ["Changed", (b) => when(b.updated_at)],
          ]} />
        </Card>
        {dialog && "legal" in dialog && (
          <Confirm title={dialog.legal ? "Record legal approval for call recording?" : "Withdraw legal approval?"} reason danger={!dialog.legal}
            word={dialog.legal ? "APPROVED" : undefined} confirmLabel={dialog.legal ? "Record approval" : "Withdraw"} onClose={() => setDialog(null)}
            onConfirm={async (reason) => {
              await call("recording_legal_set", { approved: dialog.legal, disclosure: dialog.legal ? dialog.disclosure : p.disclosure, reason, confirm: "APPROVED" });
              state.reload();
            }}>
            {dialog.legal ? (
              <>
                <p>Only once counsel has reviewed recording consent and the caller disclosure. Businesses can then be switched on one by one.</p>
                <Field label="Caller disclosure line" hint="Exactly as legal approved it."><textarea rows={3} value={dialog.disclosure} maxLength={500} onChange={(e) => setDialog({ ...dialog, disclosure: e.target.value })} /></Field>
              </>
            ) : <p>Recording is switched off for every business at once.</p>}
          </Confirm>
        )}
        {dialog && "business" in dialog && (
          <Confirm title="Recording for a business" reason word={dialog.on ? "RECORD" : undefined} confirmLabel="Save" onClose={() => setDialog(null)}
            onConfirm={async (reason) => {
              if (!dialog.business) throw new Error("Choose a business.");
              await call("recording_policy_set", { businessId: dialog.business, on: dialog.on, reason, confirm: "RECORD" });
              state.reload();
            }}>
            <div className="zs-grid">
              <BusinessPicker value={dialog.business} onChange={(business) => setDialog((d) => ({ ...d, business }))} />
              <Field label="Recording"><select value={dialog.on ? "on" : "off"} onChange={(e) => setDialog({ ...dialog, on: e.target.value === "on" })}>
                <option value="off">Off</option><option value="on" disabled={!p.legal_approved}>On{p.legal_approved ? "" : " (after legal review)"}</option></select></Field>
            </div>
            {!p.legal_approved && <Banner tone="warn">Recording can't be switched on until legal approval is recorded.</Banner>}
          </Confirm>
        )}
      </>
    )}</LoadState>
  );
}
