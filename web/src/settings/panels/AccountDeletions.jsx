import { useState } from "react";
import { supabase } from "../../supabase";
import { friendly } from "../../BusinessShared";
import { Card, Confirm, LoadState, Pill, Table, useAsync, when } from "../SettingsKit";

// Data retention > Account deletion requests (sql/zella_account_deletion.sql): owners ask, a Zella Voice admin with
// security.manage confirms (the account is frozen and deleted 30 days later by the daily job, behind the purge switch).
async function rpc(name, args) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw new Error(friendly(error));
  return data;
}
const LABEL = { requested: ["warning", "Waiting for you"], confirmed: ["error", "Frozen"], blocked: ["error", "Waiting: can't delete yet"], cancelled: ["neutral", "Cancelled"], purged: ["neutral", "Deleted"] };

export default function AccountDeletions({ me }) {
  // a missing or malformed answer is an error, never "No requests"
  const state = useAsync(async () => { const rows = await rpc("zella_admin_business_deletion_requests", {}); if (!Array.isArray(rows)) throw new Error("The requests couldn't be loaded."); return rows; }, []);
  const [confirming, setConfirming] = useState(null);
  const manage = Boolean(me?.permissions?.includes("security.manage"));
  return (
    <LoadState state={state}>{(rows) => (
      <Card title="Account deletion requests" sub="Owners ask in their Settings. Confirming freezes the account at once. After 30 days it can be deleted, unless the owner cancels, once purges are switched on, the period is legally approved and no legal hold applies.">
        <Table rows={rows} rowKey={(r) => r.id} empty="No requests." columns={[
          ["Business", (r) => r.business_name], ["Asked", (r) => when(r.requested_at)],
          ["Status", (r) => <Pill tone={LABEL[r.status]?.[0]}>{LABEL[r.status]?.[1] ?? r.status}</Pill>],
          ["Can be deleted from", (r) => (r.purge_after ? when(r.purge_after) : "")], ["Why waiting", (r) => (r.status === "blocked" ? (r.last_error ?? "").replace(/_/g, " ").toLowerCase() : "")],
          ["", (r) => manage && r.status === "requested" && <button type="button" className="zs-btn sm danger" onClick={() => setConfirming(r)}>Confirm</button>],
        ]} />
        {confirming && (
          <Confirm danger reason title={`Confirm deleting ${confirming.business_name}?`} confirmLabel="Confirm and freeze" onClose={() => setConfirming(null)}
            onConfirm={async (reason) => { await rpc("zella_admin_business_deletion_confirm", { p_business_id: confirming.business_id, p_reason: reason }); state.reload(); }}>
            <p>The owner asked: “{confirming.reason}”. Check it with the owner. Confirming freezes the account at once (unless it is already suspended). After 30 days it can be deleted, once purges are switched on, the period is legally approved and no legal hold applies.</p>
          </Confirm>
        )}
      </Card>
    )}</LoadState>
  );
}
