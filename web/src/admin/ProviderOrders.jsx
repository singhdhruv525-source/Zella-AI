import { useState } from "react";
import { callOwnerFunction } from "../CreateBusinessWizard";
import { ORDER_KIND as KIND, ORDER_STATUS as STATUS, orderActions, ordersBlocked } from "./numberOrders";
import { DataTable, ErrorNote, Facts, NotAvailable, Panel, Pill, ReasonDialog, can, useLoad, useOptions, when } from "./adminOps";

// Voice & numbers > Providers: buying and releasing numbers through Telnyx and Vapi, one approved order at a time, and
// the providers' own error logs (owner-provision-business providers.ts, sql/zella_number_orders.sql).
// An admin with telephony.manage asks; a Zella Voice owner who didn't ask approves, and only then is the provider
// called. Off until both keys are set and an owner switches number orders on; the server refuses everything until
// then, whatever this page shows.

const newKey = () => (globalThis.crypto?.randomUUID ? crypto.randomUUID() : `${Date.now().toString(16).padStart(8, "0").slice(-8)}-0000-4000-8000-${Math.random().toString(16).slice(2, 14).padEnd(12, "0")}`);

export default function ProviderOrders({ me, say = () => {} }) {
  const data = useLoad(() => callOwnerFunction("provider_overview"), []);
  const [dialog, setDialog] = useState(null);
  const manage = can(me, "telephony.manage");
  const owner = me?.role === "zella_owner";
  const o = data.data;
  const blocked = ordersBlocked(o);
  const done = (m) => { say(m); data.reload(); };
  return (
    <>
      <Panel title="Buy and release numbers" description="An admin asks, a Zella Voice owner who didn't ask approves, and only then is Telnyx or Vapi called. Every step is in the audit log."
        action={manage && o && <span className="ao-actions">
          <button type="button" className="owner-secondary-button" disabled={Boolean(blocked)} onClick={() => setDialog({ kind: "purchase", key: newKey() })}>Buy a number</button>
          <button type="button" className="owner-secondary-button" disabled={Boolean(blocked)} onClick={() => setDialog({ kind: "release", key: newKey() })}>Release a number</button>
        </span>}>
        <ErrorNote error={data.error} onRetry={data.reload} />
        {o && (
          <>
            <Facts rows={[["Telnyx key", o.telnyx ? "Added" : "Not added"], ["Vapi key", o.vapi ? "Added" : "Not added"],
              ["Number orders", o.enabled ? "On" : "Off"], ["Bought numbers added to Vapi", o.vapiImport ? "Yes" : "No, the Vapi credential for Telnyx isn't set"]]} />
            {blocked && <NotAvailable title="Not connected yet" tip="Setting number_orders_enabled">{blocked} Until then nothing is bought, released or sent to a provider.</NotAvailable>}
            <DataTable rows={o.orders} empty="No number orders yet." columns={[
              ["Number", (r) => r.e164], ["Order", (r) => KIND[r.kind]], ["For", (r) => r.business_name ?? "None"],
              ["Status", (r) => <Pill tone={STATUS[r.status]?.[1]}>{STATUS[r.status]?.[0] ?? r.status}</Pill>],
              ["Asked by", (r) => <span title={r.request_reason}>{r.requested_by_email ?? "Unknown"}<br /><span className="op-muted">{r.request_reason}</span></span>],
              ["Decided", (r) => (r.decided_at ? <span title={r.decision_reason ?? ""}>{r.decided_by_email ?? "Unknown"}, {when(r.decided_at)}</span> : "Not yet")],
              ["Provider", (r) => r.error ?? (r.provider_order_id || r.provider_number_id ? [r.provider_order_id, r.vapi_phone_number_id].filter(Boolean).join(", ") : "None")],
              ["", (r) => { const a = orderActions(r, { you: o.you, owner, manage, blocked }); return (a.approve || a.reject || a.cancel) && <span className="ao-actions">
                {a.reject && <button type="button" className="owner-secondary-button" disabled={!a.approve} title={a.approve ? undefined : blocked} onClick={() => setDialog({ decide: r, approve: true })}>Approve</button>}
                {a.reject && <button type="button" className="owner-secondary-button" onClick={() => setDialog({ decide: r, approve: false })}>Reject</button>}
                {a.cancel && <button type="button" className="owner-secondary-button" onClick={() => setDialog({ cancel: r })}>Cancel</button>}
              </span>; }],
            ]} />
          </>
        )}
      </Panel>
      <ProviderErrors manage={manage} />
      {dialog?.kind && <OrderDialog dialog={dialog} onClose={() => setDialog(null)} onDone={done} />}
      {dialog?.decide && (
        <ReasonDialog title={dialog.approve ? `${KIND[dialog.decide.kind]} ${dialog.decide.e164}?` : `Reject the order for ${dialog.decide.e164}?`} icon={dialog.approve ? "shopping_cart" : "block"}
          danger={dialog.approve} word={dialog.approve ? dialog.decide.e164 : undefined} confirmLabel={dialog.approve ? (dialog.decide.kind === "purchase" ? "Approve and buy" : "Approve and release") : "Reject"}
          onClose={() => setDialog(null)} onConfirm={async (reason) => {
            const r = await callOwnerFunction("number_order_decide", { id: dialog.decide.id, approve: dialog.approve, reason, confirm: dialog.decide.e164 });
            done(dialog.approve ? (r.order?.status === "completed" ? "Done at the provider." : "Recorded. Check the order's status.") : "Order rejected.");
          }}>
          <p>Asked by {dialog.decide.requested_by_email ?? "another admin"}: {dialog.decide.request_reason}</p>
          {dialog.approve && (dialog.decide.kind === "purchase"
            ? <p>Telnyx is asked to buy this number now, which costs money every month until it is released. It is then added to Vapi. Assign it to a business on Numbers afterwards.</p>
            : <p>The number is removed from Vapi and released at Telnyx. It can't be got back.</p>)}
        </ReasonDialog>
      )}
      {dialog?.cancel && (
        <ReasonDialog title={`Cancel the order for ${dialog.cancel.e164}?`} icon="close" confirmLabel="Cancel the order" onClose={() => setDialog(null)}
          onConfirm={async (reason) => { await callOwnerFunction("number_order_cancel", { id: dialog.cancel.id, reason }); done("Order cancelled."); }}>
          <p>Nothing has been sent to a provider for this order.</p>
        </ReasonDialog>
      )}
    </>
  );
}

function OrderDialog({ dialog, onClose, onDone }) {
  const options = useOptions();
  const [f, setF] = useState({ e164: "", businessId: "", areaCode: "", vapiPhoneNumberId: "" });
  const [found, setFound] = useState(null);
  const [searching, setSearching] = useState("");
  const buy = dialog.kind === "purchase";
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value });
  async function search() {
    setSearching("Searching…");
    try { const r = await callOwnerFunction("number_search", { areaCode: f.areaCode }); setFound(r.rows); setSearching(r.rows.length ? "" : "No numbers found for that area code."); }
    catch (e) { setSearching(e.message); }
  }
  return (
    <ReasonDialog title={buy ? "Ask to buy a number" : "Ask to release a number"} icon={buy ? "add_call" : "phone_disabled"} word={buy ? "BUY" : "RELEASE"} danger={!buy}
      confirmLabel="Send to an owner" onClose={onClose}
      onConfirm={async (reason) => {
        const e164 = f.e164.replace(/[\s()-]/g, "");
        if (!/^\+[1-9]\d{7,14}$/.test(e164)) throw new Error(buy ? "Search and choose a number first." : "Enter the number with its country code, like +15551234567.");
        await callOwnerFunction("number_order_request", { kind: dialog.kind, e164, businessId: f.businessId || null, vapiPhoneNumberId: f.vapiPhoneNumberId || null, reason, confirm: buy ? "BUY" : "RELEASE", key: dialog.key });
        onDone("Sent. A Zella Voice owner who didn't ask approves it before anything is bought or released.");
      }}>
      <div className="ao-form">
        {buy ? (
          <>
            <label className="owner-field"><span>Area code</span>
              <span className="ao-actions"><input value={f.areaCode} onChange={set("areaCode")} inputMode="numeric" maxLength={3} placeholder="415" />
                <button type="button" className="owner-secondary-button" onClick={search}>Search</button></span></label>
            {searching && <p className="op-muted" role="status">{searching}</p>}
            {found?.length > 0 && <label className="owner-field"><span>Number</span>
              <select value={f.e164} onChange={set("e164")}><option value="">Choose…</option>
                {found.map((n) => <option key={n.e164} value={n.e164}>{n.e164}{n.region ? `, ${n.region}` : ""}{n.monthly ? `, ${n.monthly} ${n.currency ?? ""} a month` : ""}</option>)}</select></label>}
            <label className="owner-field"><span>For business (optional)</span>
              <select value={f.businessId} onChange={set("businessId")}><option value="">None yet</option>
                {(options.data?.businesses ?? []).map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}</select></label>
          </>
        ) : (
          <>
            <label className="owner-field"><span>Number</span><input value={f.e164} onChange={set("e164")} placeholder="+15551234567" /></label>
            <label className="owner-field"><span>Vapi phone number id (if it is in Vapi)</span><input value={f.vapiPhoneNumberId} onChange={set("vapiPhoneNumberId")} /></label>
            <p className="op-muted">Release it from Zella Voice on Numbers first. A number still assigned to a business is refused.</p>
          </>
        )}
      </div>
    </ReasonDialog>
  );
}

function ProviderErrors({ manage }) {
  const [state, setState] = useState(null);
  async function load() {
    setState({ loading: true });
    try { setState({ data: await callOwnerFunction("provider_errors") }); } catch (e) { setState({ error: e.message }); }
  }
  const part = (name, p) => !p.connected ? <NotAvailable title={`${name} isn't connected yet`}>Its key isn't added on the server, so its errors can't be read.</NotAvailable>
    : <>{p.error && <ErrorNote error={`${name}: ${p.error}`} />}<DataTable rows={p.rows} rowKey={(r) => r.ref ?? r.at} empty={`No recent errors at ${name}.`} columns={[
      ["When", (r) => when(r.at)], ["What", (r) => r.code ?? "Unknown"], ["Detail", (r) => r.detail ?? r.number ?? "None"], ["Reference", (r) => r.ref ? <code>{r.ref}</code> : "None"]]} /></>;
  return (
    <Panel title="Provider error logs" description="Read from Telnyx and Vapi when you ask; nothing is stored. Caller numbers are shortened."
      action={manage && <button type="button" className="owner-secondary-button" onClick={load} disabled={state?.loading}>{state?.data ? "Refresh" : "Load errors"}</button>}>
      {!manage && <p className="op-muted">Reading provider errors needs telephony.manage.</p>}
      {state?.loading && <p className="op-muted">Loading…</p>}
      <ErrorNote error={state?.error} onRetry={load} />
      {state?.data && <>{part("Vapi", state.data.vapi)}{part("Telnyx", state.data.telnyx)}</>}
    </Panel>
  );
}
