import { useState } from "react";
import { callOwnerFunction } from "../../CreateBusinessWizard";
import { Banner, Card, Confirm, Field, LoadState, Pill, Table, useAsync, when } from "../SettingsKit";
import { classLabel } from "./retentionLabels";
import { RUN_STATUS, runActions } from "./purgeRuns";

// Data retention > Purge runs: ask for a run of what the dry run lists, two people approve it (one a Zella Voice
// owner), and one of them runs it with "PURGE <rows>" typed (owner-provision-business retention.ts,
// sql/zella_retention_purge.sql). The server refuses every step that isn't allowed, whatever this page offers.

const call = (action, payload) => callOwnerFunction(action, payload);

export default function PurgeRuns({ me, policies, purgeEnabled, you }) {
  const state = useAsync(() => call("retention_runs"), []);
  const [dialog, setDialog] = useState(null);
  const manage = Boolean(me?.permissions?.includes("security.manage"));
  const approved = policies.filter((p) => p.legal_status === "approved" && p.data_class !== "cancelled_business");
  const ctx = { you, owner: me?.role === "zella_owner", manage, purgeEnabled };
  return (
    <LoadState state={state}>{(runs) => (
      <Card title="Purge runs" sub="Each run removes exactly the rows listed when it was asked for. Two people approve it, one of them a Zella Voice owner."
        actions={manage && <button type="button" className="zs-btn sm" disabled={!approved.length} title={approved.length ? undefined : "No kind of data has legal approval yet"}
          onClick={() => setDialog({ ask: approved[0].data_class })}>Ask for a run</button>}>
        {!approved.length && <p className="zs-muted">No kind of data has legal approval yet, so no run can be asked for.</p>}
        <Table rows={runs} empty="No purge runs yet." columns={[
          ["Data", (r) => (r.business_id ? `${classLabel(r.data_class)}: ${r.business_name ?? "deleted"}` : classLabel(r.data_class))], ["Rows", (r) => r.item_count],
          ["Status", (r) => <Pill tone={RUN_STATUS[r.status]?.[1]}>{RUN_STATUS[r.status]?.[0] ?? r.status}</Pill>],
          ["Asked by", (r) => <span title={r.request_reason}>{r.requested_by_email ?? "Unknown"}, {when(r.created_at)}</span>],
          ["Approved by", (r) => [r.owner_approved_by_email, r.second_approved_by_email].filter(Boolean).join(", ") || "Nobody yet"],
          ["Result", (r) => (r.executed_at ? `${r.removed_count ?? 0} removed, ${when(r.executed_at)}${Number(r.files_left) > 0 ? `; ${r.files_left} files left` : ""}${r.error ? `. ${r.error}` : ""}` : r.error ?? "Not run")],
          ["", (r) => { const a = runActions(r, ctx); return <span className="zs-actions">
            {a.approve && <button type="button" className="zs-btn sm" onClick={() => setDialog({ approve: r })}>Approve</button>}
            {a.run && <button type="button" className="zs-btn sm danger-outline" onClick={() => setDialog({ run: r })}>Run</button>}
            {a.cancel && <button type="button" className="zs-btn sm" onClick={() => setDialog({ cancel: r })}>Cancel</button>}
            {a.retry && <button type="button" className="zs-btn sm" onClick={() => setDialog({ retry: r })}>Remove the files left</button>}
          </span>; }],
        ]} />
        {dialog?.ask && (
          <Confirm title="Ask for a purge run" reason confirmLabel="Ask" onClose={() => setDialog(null)}
            onConfirm={async (reason) => { await call("retention_run_request", { dataClass: dialog.ask, reason }); state.reload(); }}>
            <Field label="Data"><select value={dialog.ask} onChange={(e) => setDialog({ ask: e.target.value })}>
              {approved.map((p) => <option key={p.data_class} value={p.data_class}>{classLabel(p.data_class)}</option>)}</select></Field>
            <p className="zs-muted">The rows the dry run lists now (at most 1000, oldest first) are fixed in the run. Nothing is removed until two people approve it and one of them runs it.</p>
          </Confirm>
        )}
        {dialog?.approve && (
          <Confirm title={`Approve removing ${dialog.approve.item_count} rows of ${classLabel(dialog.approve.data_class).toLowerCase()}?`} reason confirmLabel="Approve" onClose={() => setDialog(null)}
            onConfirm={async (reason) => { await call("retention_run_approve", { id: dialog.approve.id, reason }); state.reload(); }}>
            <p>Asked by {dialog.approve.requested_by_email ?? "another admin"}: {dialog.approve.request_reason}</p>
          </Confirm>
        )}
        {dialog?.run && dialog.run.business_id && (
          <Confirm title={`Delete ${dialog.run.business_name} and everything that belongs to it?`} danger word={dialog.run.business_name ?? ""} confirmLabel="Delete the business"
            onClose={() => setDialog(null)} onConfirm={async () => { await call("business_purge_execute", { id: dialog.run.id, confirmName: dialog.run.business_name }); state.reload(); }}>
            <Banner tone="error">This can't be undone. Its audit history is kept. It is refused while the business has billing records, offer history or phone numbers, or the export offer is under 14 days old.</Banner>
          </Confirm>
        )}
        {dialog?.run && !dialog.run.business_id && (
          <Confirm title={`Remove ${dialog.run.item_count} rows of ${classLabel(dialog.run.data_class).toLowerCase()}?`} danger word={`PURGE ${dialog.run.item_count}`} confirmLabel="Run the purge"
            onClose={() => setDialog(null)} onConfirm={async () => { await call("retention_run_execute", { id: dialog.run.id, confirm: `PURGE ${dialog.run.item_count}` }); state.reload(); }}>
            <Banner tone="error">This can't be undone. Rows that went on a legal hold or are no longer past their period are left alone.</Banner>
          </Confirm>
        )}
        {dialog?.retry && (
          <Confirm title={`Remove the ${dialog.retry.files_left} files left?`} danger confirmLabel="Remove the files" onClose={() => setDialog(null)}
            onConfirm={async () => { await call(dialog.retry.business_id ? "business_purge_files_retry" : "retention_run_files_retry", { id: dialog.retry.id }); state.reload(); }}>
            <p>The rows were already removed when the run ran; only the stored files still listed are removed now. Files of a business placed on a legal hold since then are left alone, and a file storage no longer has counts as removed.</p>
          </Confirm>
        )}
        {dialog?.cancel && (
          <Confirm title="Cancel this run?" reason confirmLabel="Cancel the run" onClose={() => setDialog(null)}
            onConfirm={async (reason) => { await call("retention_run_cancel", { id: dialog.cancel.id, reason }); state.reload(); }}>
            <p>Nothing has been removed by it.</p>
          </Confirm>
        )}
      </Card>
    )}</LoadState>
  );
}
