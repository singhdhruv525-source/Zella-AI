import { useState } from "react";
import { supabase } from "./supabase";
import { Field, Pill } from "./BusinessUI";
import { Notice, friendly, useLoad } from "./BusinessShared";

// Offers from Zella for this business. Zella's database decides who qualifies, checks limits and
// dates at the moment of claiming, and only marks a claim paid when a real payment arrives.
// Owners can claim; admins can see. Nothing here changes a price by itself.

const shortDate = (iso, tz) =>
  iso ? new Date(iso).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: tz || undefined }) : "";

function newKey() {
  const rand = typeof crypto !== "undefined" && crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + Math.random().toString(16).slice(2);
  return "biz-" + rand;
}

export function OffersPanel({ workspace }) {
  const canSee = ["owner", "admin"].includes(workspace.role);
  const isOwner = workspace.role === "owner";
  const { data, error, reload } = useLoad(async () => {
    if (!canSee) return null;
    const { data: d, error: e } = await supabase.rpc("zella_offers_for_business", { p_business_id: workspace.id });
    if (e) throw e;
    return d;
  }, [workspace.id, canSee]);
  const [code, setCode] = useState("");
  const [found, setFound] = useState(null);
  const [busy, setBusy] = useState("");
  const [message, setMessage] = useState("");
  // One key per offer for this screen, so a double click or a retry can never claim twice.
  const [keys] = useState(() => new Map());
  const keyFor = (id) => { if (!keys.has(id)) keys.set(id, newKey()); return keys.get(id); };

  if (!canSee) return null;

  async function checkCode(event) {
    event.preventDefault();
    setBusy("code"); setMessage(""); setFound(null);
    const { data: r, error: e } = await supabase.rpc("zella_offer_check_code", { p_business_id: workspace.id, p_code: code.trim() });
    setBusy("");
    if (e) return setMessage(friendly(e));
    if (!r.ok) return setMessage(r.message);
    setFound(r.offer);
  }

  async function claim(offer, withCode) {
    setBusy(offer.id); setMessage("");
    const { data: r, error: e } = await supabase.rpc("zella_offer_claim", {
      p_business_id: workspace.id, p_offer_id: offer.id, p_code: withCode ? code.trim() : null, p_idempotency_key: keyFor(offer.id),
    });
    setBusy("");
    if (e) return setMessage((e.message ?? "").includes("OWNER_ONLY") ? "Only the business owner can claim offers." : friendly(e));
    if (!r.ok) return setMessage(r.message ?? "This offer can't be claimed right now.");
    setMessage(data?.billing_connected
      ? `Claimed. ${offer.summary} is applied when your next payment goes through.`
      : `Claimed. ${offer.summary} is saved for you and applied when online billing starts.`);
    setFound(null); setCode("");
    reload();
  }

  async function cancel(claimed) {
    setBusy(claimed.id); setMessage("");
    const { error: e } = await supabase.rpc("zella_offer_cancel_claim", { p_redemption_id: claimed.id });
    setBusy("");
    if (e) return setMessage(friendly(e));
    setMessage("Claim canceled.");
    reload();
  }

  const available = data?.available ?? [];
  const claimed = data?.claimed ?? [];

  return (
    <section className="ba-panel">
      <div className="ba-panel-head"><div className="ba-panel-title"><div><h2>Offers from Zella</h2><p>Discounts your business qualifies for.</p></div></div></div>
      <div className="ba-panel-body">
        <Notice error={error} onRetry={reload} />

        {claimed.length > 0 && (
          <ul className="ba-offer-list">
            {claimed.map((c) => (
              <li key={c.id} className="ba-offer">
                <div>
                  <strong>{c.name}</strong>
                  <p>{c.summary}</p>
                  <p className="ba-muted">
                    {c.status === "confirmed" ? `Applied ${shortDate(c.confirmed_at)}.` : `Claimed ${shortDate(c.created_at)}. Waiting for your next payment, held until ${shortDate(c.hold_until)}.`}
                  </p>
                </div>
                <div className="ba-offer-side">
                  <Pill tone={c.status === "confirmed" ? "success" : "warning"}>{c.status === "confirmed" ? "Applied" : "Saved for you"}</Pill>
                  {isOwner && c.status === "pending" && (
                    <button type="button" className="ba-link" onClick={() => cancel(c)} disabled={busy === c.id}>Cancel</button>
                  )}
                </div>
              </li>
            ))}
          </ul>
        )}

        {available.length === 0 && claimed.length === 0 && data && (
          <p className="ba-muted">No offers right now. If Zella gave you a code, enter it below.</p>
        )}

        {available.length > 0 && (
          <ul className="ba-offer-list">
            {available.map((o) => (
              <li key={o.id} className="ba-offer">
                <div>
                  <strong>{o.name}</strong>
                  <p>{o.summary}</p>
                  {o.description && <p className="ba-muted">{o.description}</p>}
                  <p className="ba-muted">Ends {shortDate(o.ends_at, o.timezone)}. Your standard price stays the same afterwards.</p>
                </div>
                <div className="ba-offer-side">
                  {isOwner
                    ? <button type="button" className="ba-btn primary sm" onClick={() => claim(o, false)} disabled={busy === o.id}>{busy === o.id ? "Claiming…" : "Claim"}</button>
                    : <span className="ba-muted">The owner can claim this.</span>}
                </div>
              </li>
            ))}
          </ul>
        )}

        <form className="ba-offer-code" onSubmit={checkCode}>
          <Field label="Have a code?">
            <input value={code} maxLength={40} autoComplete="off" onChange={(e) => { setCode(e.target.value); setFound(null); }} placeholder="Enter code" />
          </Field>
          <button type="submit" className="ba-btn sm" disabled={!code.trim() || busy === "code"}>{busy === "code" ? "Checking…" : "Check code"}</button>
        </form>
        {found && (
          <div className="ba-offer">
            <div>
              <strong>{found.name}</strong>
              <p>{found.summary}</p>
              <p className="ba-muted">Ends {shortDate(found.ends_at, found.timezone)}. Your standard price stays the same afterwards.</p>
            </div>
            <div className="ba-offer-side">
              {isOwner
                ? <button type="button" className="ba-btn primary sm" onClick={() => claim(found, true)} disabled={busy === found.id}>{busy === found.id ? "Claiming…" : "Claim"}</button>
                : <span className="ba-muted">The owner can claim this.</span>}
            </div>
          </div>
        )}
        {message && <p className="ba-muted" role="status">{message}</p>}
      </div>
    </section>
  );
}
