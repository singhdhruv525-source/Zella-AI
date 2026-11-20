import { useState } from "react";
import { callOwnerFunction } from "../../CreateBusinessWizard";
import { Banner, Card, Confirm, Facts, Field, LoadState, Pill, Table, useAsync, when } from "../SettingsKit";
import { CLASS_LABELS, SOURCE_LABELS, classLabel, periodWords } from "./retentionLabels";
import PurgeRuns from "./PurgeRuns";
import BusinessPurge from "./BusinessPurge";
import AccountDeletions from "./AccountDeletions";
import BusinessPicker from "./BusinessPicker";

// Settings > Security and privacy > Data retention: a period per kind of data, legal holds, and a dry run of what a
// purge would remove (owner-provision-business retention.ts, sql/zella_data_retention.sql). Every period is the
// architecture's proposal, pending legal review. The dry run deletes nothing, and no job is scheduled.

const call = (action, payload) => callOwnerFunction(action, payload);

export default function DataRetention({ me }) {
  // the overview loads on its own; the business search is asked only inside the hold dialog
  const state = useAsync(() => call("retention_overview"), []);
  const [dialog, setDialog] = useState(null);
  const [preview, setPreview] = useState(null);
  const [runsKey, setRunsKey] = useState(0);
  const owner = me?.role === "zella_owner";
  const manage = Boolean(me?.permissions?.includes("security.manage"));
  async function dryRun(dataClass) {
    setPreview({ dataClass, loading: true });
    try { setPreview({ dataClass, data: await call("retention_preview", { dataClass }) }); } catch (e) { setPreview({ dataClass, error: e.message }); }
  }
  return (
    <LoadState state={state}>{(o) => (
      <>
        <Card title="Retention periods" sub="Proposed from the architecture and pending legal review. While purges are switched on, the daily job removes recordings and transcripts past their period, for kinds that are legally approved.">
          <Table rows={o.policies} rowKey={(p) => p.data_class} columns={[
            ["Data", (p) => <span title={CLASS_LABELS[p.data_class]?.[1]}>{classLabel(p.data_class)}</span>],
            ["Kept for", (p) => periodWords(p.days)], ["Proposed", (p) => periodWords(p.architecture_days)],
            ["Legal review", (p) => <Pill tone={p.legal_status === "approved" ? "success" : "warning"}>{p.legal_status === "approved" ? "Approved" : "Pending legal review"}</Pill>],
            ["", (p) => <span className="zs-actions">
              <button type="button" className="zs-btn sm" onClick={() => dryRun(p.data_class)}>Dry run</button>
              {owner && <button type="button" className="zs-btn sm" onClick={() => setDialog({ policy: p, days: String(p.days), legalStatus: p.legal_status })}>Change</button>}
            </span>],
          ]} />
          {o.retention_days != null && <p className="zs-muted">A canceled business's retention date is still set from retention_days ({periodWords(o.retention_days)}); a purge never runs before it.</p>}
        </Card>
        {preview && (
          <Card title={`Dry run: ${classLabel(preview.dataClass)}`} sub="What a purge would remove today. Nothing has been deleted."
            actions={<button type="button" className="zs-btn sm" onClick={() => setPreview(null)}>Close</button>}>
            {preview.loading && <p className="zs-muted">Counting…</p>}
            {preview.error && <Banner tone="error">{preview.error}</Banner>}
            {preview.data && (
              <>
                <Facts rows={[["Would remove", preview.data.count], ["Older than", when(preview.data.cutoff)],
                  ...Object.entries(preview.data.by_source).map(([k, v]) => [SOURCE_LABELS[k] ?? k, v]),
                  ["Businesses on a legal hold, left out", preview.data.held_businesses]]} />
                <Table rows={preview.data.sample} rowKey={(r) => `${r.source}:${r.id}`} empty="Nothing is past its period." columns={[
                  ["Kind", (r) => SOURCE_LABELS[r.source] ?? r.source], ["Business", (r) => r.business_name ?? "None"], ["Dated", (r) => when(r.dated)], ["Reference", (r) => <code>{r.id.slice(0, 8)}</code>]]} />
              </>
            )}
          </Card>
        )}
        <Card title="Purges" sub="Each manual purge run needs a Zella Voice owner and a second person to approve it. Account deletions an admin confirmed run on the daily job once this switch is on and their period is legally approved."
          actions={owner && <button type="button" className={`zs-btn sm${o.purge_enabled ? " danger-outline" : ""}`} onClick={() => setDialog({ switchOn: !o.purge_enabled })}>{o.purge_enabled ? "Switch purges off" : "Switch purges on"}</button>}>
          <Facts rows={[["Purges", o.purge_enabled ? "On" : "Off"], ["Schedule", "Manual runs: only when people approve them. Confirmed account deletions and the 90 day removal of recordings and transcripts: the daily job, once on"], ["Setting", "retention_purge_enabled"]]} />
        </Card>
        <BusinessPurge me={me} legalApproved={o.policies.some((p) => p.data_class === "cancelled_business" && p.legal_status === "approved")} onAsked={() => setRunsKey((k) => k + 1)} />
        <AccountDeletions me={me} />
        <PurgeRuns key={runsKey} me={me} policies={o.policies} purgeEnabled={o.purge_enabled} you={o.you} />
        <Card title="Legal holds" sub="Nothing of a business on hold is ever listed for removal, and the business can't be deleted."
          actions={manage && <button type="button" className="zs-btn sm" onClick={() => setDialog({ hold: "" })}>Place a hold</button>}>
          <Table rows={o.holds} empty="No business is on a legal hold." columns={[
            ["Business", (h) => h.business_name], ["Reason", (h) => h.reason], ["Placed", (h) => `${h.placed_by_email ?? "Unknown"}, ${when(h.placed_at)}`],
            ["", (h) => owner && <button type="button" className="zs-btn sm" onClick={() => setDialog({ release: h })}>Release</button>]]} />
        </Card>
        {dialog?.policy && (
          <Confirm title={`Retention for ${classLabel(dialog.policy.data_class).toLowerCase()}`} reason confirmLabel="Save" word={dialog.legalStatus === "approved" ? "APPROVED" : undefined}
            onClose={() => setDialog(null)} onConfirm={async (reason) => {
              await call("retention_policy_set", { dataClass: dialog.policy.data_class, days: Number(dialog.days), legalStatus: dialog.legalStatus, reason, confirm: "APPROVED" });
              state.reload();
            }}>
            <div className="zs-grid">
              <Field label="Days kept" hint={`Proposed: ${dialog.policy.architecture_days}`}><input value={dialog.days} inputMode="numeric" onChange={(e) => setDialog({ ...dialog, days: e.target.value })} /></Field>
              <Field label="Legal review"><select value={dialog.legalStatus} onChange={(e) => setDialog({ ...dialog, legalStatus: e.target.value })}>
                <option value="pending_legal_review">Pending legal review</option><option value="approved">Approved by legal</option></select></Field>
            </div>
            {dialog.legalStatus === "approved" && <Banner tone="warn">Only after counsel has approved this period. A manual purge run of an approved kind still needs two people to approve it; while purges are switched on, the daily job also removes approved recordings and transcripts past their period, and approving the cancelled business period lets it purge confirmed account deletions that are due.</Banner>}
          </Confirm>
        )}
        {dialog && "switchOn" in dialog && (
          <Confirm title={dialog.switchOn ? "Switch purges on?" : "Switch purges off?"} reason danger={dialog.switchOn} word={dialog.switchOn ? "ENABLE PURGES" : undefined}
            confirmLabel={dialog.switchOn ? "Switch on" : "Switch off"} onClose={() => setDialog(null)}
            onConfirm={async (reason) => { await call("retention_switch_set", { on: dialog.switchOn, reason, confirm: "ENABLE PURGES" }); state.reload(); }}>
            <p>{dialog.switchOn ? "Manual purge runs still need legal approval of the period and two people to approve each run. The daily job will also remove recordings and transcripts past 90 days and purge confirmed account deletions past their 30 days, for kinds that are legally approved." : "No purge can run until it is switched on again."}</p>
          </Confirm>
        )}
        {dialog && "hold" in dialog && (
          <Confirm title="Place a legal hold" reason confirmLabel="Place hold" onClose={() => setDialog(null)}
            onConfirm={async (reason) => { if (!dialog.hold) throw new Error("Choose a business."); await call("legal_hold_place", { businessId: dialog.hold, reason }); state.reload(); }}>
            <BusinessPicker value={dialog.hold} onChange={(hold) => setDialog((d) => ({ ...d, hold }))} />
            <p className="zs-muted">Only a Zella Voice owner can release it.</p>
          </Confirm>
        )}
        {dialog?.release && (
          <Confirm title={`Release the hold on ${dialog.release.business_name}?`} reason danger confirmLabel="Release" onClose={() => setDialog(null)}
            onConfirm={async (reason) => { await call("legal_hold_release", { id: dialog.release.id, reason }); state.reload(); }}>
            <p>Its records can then be listed for removal under the periods above.</p>
          </Confirm>
        )}
      </>
    )}</LoadState>
  );
}
