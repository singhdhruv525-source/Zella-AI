import { useCallback, useEffect, useRef, useState } from "react";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { humanize } from "./copy/labels";
import { friendlyError } from "./admin/adminOps";
import { documentRequestNotice, requestWaitHours } from "./businessLifecycle";

// Verification > Missing documents (UI-11): businesses that haven't sent a required document yet, including ones
// already live ("Live without documents"), and Request documents. The request is audited; the email to the owner (S4)
// is queued in the platform outbox when it is installed and goes out only once email sending is live.

const KIND = { business_registration: "Business registration", owner_identity: "Owner's photo ID" };
const when = (v) => (v ? new Date(v).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" }) : "Never");

export default function MissingDocuments({ onOpenBusiness, refreshKey = 0 }) {
  const [data, setData] = useState(null);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState("");
  const inFlight = useRef(false);
  const load = useCallback(async () => {
    setError("");
    try { setData(await callOwnerFunction("documents_missing")); }
    catch (err) { setData(null); setError(friendlyError(err)); }
  }, []);
  useEffect(() => { load(); }, [load, refreshKey]);   // the page's Refresh reloads this list too
  // the wait shown on a button ends on its own: the page redraws when the earliest wait is over
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const ends = (data?.rows ?? []).map((b) => Date.parse(b.last_requested_at ?? "") + (data.cooldownHours ?? 24) * 3_600_000).filter((t) => Number.isFinite(t) && t > now);
    if (!ends.length) return undefined;
    const t = setTimeout(() => setNow(Date.now()), Math.min(Math.min(...ends) - now + 1000, 3_600_000));
    return () => clearTimeout(t);
  }, [data, now]);

  async function ask(b) {
    if (inFlight.current) return;
    inFlight.current = true; setBusy(b.id); setError(""); setNotice("");
    try {
      const r = await callOwnerFunction("document_request", { businessId: b.id });
      setNotice(documentRequestNotice(r));
      await load();
    } catch (err) { setError(friendlyError(err)); }
    finally { inFlight.current = false; setBusy(""); }
  }

  const rows = data?.rows ?? [];
  return (
    <>
      {error && <div className="owner-form-error op-gap" role="alert">{error}</div>}
      {notice && <div className="vq-notice op-gap" role="status">{notice}</div>}
      <section className="owner-panel">
        <div className="owner-table-wrap" tabIndex={0}>
          <table className="owner-table">
            <thead><tr><th>Business</th><th>Still needed</th><th>Last requested</th><th aria-label="Actions" /></tr></thead>
            <tbody>
              {rows.map((b) => {
                const wait = requestWaitHours(b.last_requested_at, data.cooldownHours, now);
                return (
                  <tr key={b.id}>
                    <td>
                      <div className="owner-business-cell">
                        <button type="button" className="vq-link" onClick={() => onOpenBusiness(b.id)}>{b.name}</button>
                        <span>{b.live ? <Pill tone="danger">Live without documents</Pill> : humanize(b.onboarding_status)}</span>
                      </div>
                    </td>
                    <td>{b.missing.map((k) => KIND[k] ?? humanize(k)).join(", ")}</td>
                    <td>{when(b.last_requested_at)}</td>
                    <td>
                      <div className="vq-actions">
                        <button type="button" className="owner-secondary-button" disabled={busy === b.id || wait > 0} onClick={() => ask(b)}
                          title={wait > 0 ? `Asked recently. You can ask again in ${wait} hours.` : undefined}>
                          {wait > 0 ? `Asked, again in ${wait} h` : "Request documents"}
                        </button>
                      </div>
                    </td>
                  </tr>
                );
              })}
              {!rows.length && (
                <tr><td colSpan={4}><div className="op-empty">{!data ? (error ? "Couldn't load this list." : "Loading...") : data.available === false ? "Document storage isn't set up yet." : "Every business has its required documents."}</div></td></tr>
              )}
            </tbody>
          </table>
        </div>
      </section>
    </>
  );
}
