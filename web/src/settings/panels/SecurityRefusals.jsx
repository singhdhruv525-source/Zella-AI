import { useCallback, useEffect, useRef, useState } from "react";
import { callOwnerFunction } from "../../CreateBusinessWizard";
import { friendlyError } from "../../admin/adminOps";
import { timeAgo } from "../../ownerFormat";
import { refusalReason } from "../../adminAccess";

// ACC-15: refused calls to the admin function in the last 24 hours (security.admin_refused), so an owner can see
// someone trying pages or changes their role doesn't allow. Shown on Users & access to anyone with security.view.
export default function SecurityRefusals() {
  const [data, setData] = useState(null);
  const [error, setError] = useState("");
  const request = useRef(0);   // only the latest load may show its answer or error
  const load = useCallback(async () => {
    const mine = ++request.current;
    setError("");
    try {
      const next = await callOwnerFunction("security_refusals");
      if (mine === request.current) setData(next);
    } catch (err) {
      if (mine !== request.current) return;
      setError(err?.code === "NOT_PERMITTED" ? "" : friendlyError(err));
      setData(err?.code === "NOT_PERMITTED" ? { hidden: true } : null);
    }
  }, []);
  useEffect(() => { load(); }, [load]);
  if (data?.hidden) return null;
  return (
    <section className="owner-panel op-gap" aria-labelledby="refusals-title">
      <div className="owner-panel-heading">
        <div>
          <h2 id="refusals-title">Refused admin requests</h2>
          <p>Calls the server refused in the last 24 hours: not an admin, two step sign in missing, or a role without that permission. Each person and reason is recorded at most 5 times in 10 minutes.</p>
        </div>
        <button type="button" className="owner-secondary-button op-small" onClick={load}>Refresh</button>
      </div>
      {error && <div className="owner-form-error" role="alert">{error}</div>}
      <div className="owner-table-wrap" tabIndex={0}>
        <table className="owner-table">
          <thead><tr><th>When</th><th>Who</th><th>Why</th><th>Asked for</th><th>From</th></tr></thead>
          <tbody>
            {(data?.recent ?? []).map((r, i) => (
              <tr key={`${r.at}-${i}`}>
                <td>{timeAgo(r.at)}</td>
                <td>{r.email ?? "Unknown person"}</td>
                <td>{refusalReason(r)}</td>
                <td>{r.request ?? "Not known"}</td>
                <td>{r.ip ?? "Unknown address"}</td>
              </tr>
            ))}
            {!data?.recent?.length && <tr><td colSpan={5}><div className="op-empty">{data ? "No refused requests in the last 24 hours." : error ? "Couldn't load this list." : "Loading..."}</div></td></tr>}
          </tbody>
        </table>
      </div>
      <div className="owner-panel-footer"><span>{data ? `${data.count24h} in the last 24 hours` : ""}</span></div>
    </section>
  );
}
