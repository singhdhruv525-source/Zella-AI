import { useState } from "react";
import { callOwnerFunction } from "../../CreateBusinessWizard";
import { Banner, Card, Confirm, Field, LoadState, Table, useAsync, when } from "../SettingsKit";

// Data retention > Canceled businesses past retention (BIZ-13d): the dry run of whole businesses that could be
// deleted, and asking to purge one once the owner was offered a final export (owner-provision-business retention.ts,
// sql/zella_business_purge.sql). Approving and running happen under Purge runs, by two people.

const call = (action, payload) => callOwnerFunction(action, payload);
// now, as the value of a datetime-local field: the viewer's own date and time, to the minute
const nowLocal = () => { const d = new Date(); d.setMinutes(d.getMinutes() - d.getTimezoneOffset()); return d.toISOString().slice(0, 16); };

export default function BusinessPurge({ me, legalApproved, onAsked }) {
  const state = useAsync(() => call("retention_preview", { dataClass: "cancelled_business" }), []);
  const [dialog, setDialog] = useState(null);
  const manage = Boolean(me?.permissions?.includes("security.manage"));
  return (
    <LoadState state={state}>{(p) => (
      <Card title="Canceled businesses past retention" sub="Dry run: listed here, nothing deleted. A business is listed once canceled for the period above and past its retention date, and never while on a legal hold.">
        <Table rows={p.sample} rowKey={(r) => r.id} empty="No canceled business is past its retention date." columns={[
          ["Business", (r) => r.business_name ?? r.id.slice(0, 8)], ["Canceled", (r) => when(r.dated)],
          ["", (r) => manage && <button type="button" className="zs-btn sm" disabled={!legalApproved} title={legalApproved ? undefined : "Pending legal review"}
            onClick={() => setDialog({ business: r, offeredAt: nowLocal(), note: "" })}>Ask to purge</button>],
        ]} />
        {!legalApproved && <p className="zs-muted">The canceled business period is pending legal review, so no purge can be asked for.</p>}
        {dialog && (
          <Confirm title={`Ask to purge ${dialog.business.business_name}?`} reason confirmLabel="Ask" onClose={() => setDialog(null)}
            onConfirm={async (reason) => {
              // the date and time typed are the viewer's own; the browser turns them into an exact moment
              const offered = new Date(dialog.offeredAt);
              if (Number.isNaN(offered.getTime())) throw new Error("Enter when the export was offered.");
              if (offered.getTime() > Date.now()) throw new Error("The export offer can't be in the future.");
              await call("business_purge_request", { businessId: dialog.business.id, exportOfferedAt: offered.toISOString(), exportOfferNote: dialog.note, reason });
              state.reload(); onAsked?.();
            }}>
            <Banner tone="warn">A whole business export isn't built yet. Record how and when you offered the owner a final copy of their data. The purge can run 14 days after that.</Banner>
            <div className="zs-grid">
              <Field label="Export offered at" hint="Your local date and time."><input type="datetime-local" value={dialog.offeredAt} max={nowLocal()} onChange={(e) => setDialog({ ...dialog, offeredAt: e.target.value })} /></Field>
              <Field label="How it was offered"><input value={dialog.note} maxLength={300} placeholder="Emailed the owner on the address on file" onChange={(e) => setDialog({ ...dialog, note: e.target.value })} /></Field>
            </div>
          </Confirm>
        )}
      </Card>
    )}</LoadState>
  );
}
