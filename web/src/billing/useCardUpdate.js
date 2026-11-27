import { useRef, useState } from "react";

// Opens Stripe's Customer Portal for a card update (billing-api card_update_start: card update only); Stripe sends the
// owner back to the Payments page. One key per attempt, a new one after a failure.
const newKey = () => (globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`).replace(/[^A-Za-z0-9_-]/g, "");
export function useCardUpdate(api, businessId) {
  const key = useRef(newKey());
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  async function run() {
    if (busy || !businessId) return;
    setBusy(true); setError("");
    try { const r = await api.cardUpdateStart(businessId, key.current); window.location.assign(r.url); }
    catch (err) { key.current = newKey(); setError(err?.words ?? err?.message ?? "Something went wrong. Please try again."); setBusy(false); }
  }
  return { run, busy, error };
}
