import { useState } from "react";
import { supabase } from "../supabase";
import { friendly } from "../BusinessShared";
import { Banner, Card, Confirm, LoadState, useAsync, when } from "./SettingsKit";

// Settings > Privacy > Delete this account (owner, sql/zella_account_deletion.sql): the owner asks, Zella Voice
// confirms, the account is frozen, and everything is deleted 30 days later unless the owner cancels.
async function rpc(name, args) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw new Error(friendly(error));
  return data;
}

export default function DeleteAccount({ w }) {
  const state = useAsync(() => rpc("zella_business_deletion_status", { p_business_id: w.id }), [w.id]);
  const [asking, setAsking] = useState(false);
  const [cancelling, setCancelling] = useState(false);
  const owner = w.role === "owner";
  return (
    <LoadState state={state}>{(s) => (
      <Card title="Delete this account" sub="Everything for this business is deleted: customers, calls, messages, bookings, files and settings. Audit history is kept without your details.">
        {!s?.status && <p className="zs-muted">You can ask Zella Voice to delete this account. Nothing changes until Zella Voice confirms. Then the account is frozen at once (calls are no longer answered and automations stop) and deleted 30 days later. You can cancel until then.</p>}
        {s?.status === "requested" && <Banner tone="warn">You asked to delete this account on {when(s.requested_at)}. Zella Voice will confirm it with you.</Banner>}
        {s?.status === "confirmed" && <Banner tone="error">This account is frozen and will be deleted on {when(s.purge_after)}.</Banner>}
        {s?.status === "blocked" && <Banner tone="error">This account is frozen. It can't be deleted yet: Zella Voice has been told why and will contact you.</Banner>}
        {owner ? (
          s?.status
            ? <button type="button" className="zs-btn" onClick={() => setCancelling(true)}>Cancel the deletion</button>
            : <button type="button" className="zs-btn danger" onClick={() => setAsking(true)}>Ask to delete this account</button>
        ) : <p className="zs-muted">Only the owner can ask to delete the account.</p>}
        {asking && (
          <Confirm danger title={`Delete ${w.name}?`} word={w.name} reason confirmLabel="Ask to delete" onClose={() => setAsking(false)}
            onConfirm={async (reason) => { await rpc("zella_business_deletion_request", { p_business_id: w.id, p_confirm_name: w.name, p_reason: reason }); state.reload(); }}>
            <p>Zella Voice confirms the request with you first. Once confirmed, the account is frozen and everything is deleted after 30 days.</p>
          </Confirm>
        )}
        {cancelling && (
          <Confirm title="Cancel the deletion?" confirmLabel="Keep my account" onClose={() => setCancelling(false)}
            onConfirm={async () => { await rpc("zella_business_deletion_cancel", { p_business_id: w.id }); state.reload(); }}>
            <p>The account stays, and if it was frozen it starts working again.</p>
          </Confirm>
        )}
      </Card>
    )}</LoadState>
  );
}
