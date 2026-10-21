import { useCallback, useEffect, useState } from "react";
import "./OwnerPages.css";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { formatDate } from "./ownerFormat";

const SUB_TONE = {
  trial: "info", active: "success", renewal_due: "warning", past_due: "danger",
  grace_period: "warning", cancelled: "neutral", expired: "neutral",
};

const EMPTY_PLAN = { planId: "", name: "", description: "", isActive: true };

function describeJson(value) {
  if (!value || typeof value !== "object") return [];
  if (Array.isArray(value)) return value.map(String);
  return Object.entries(value).map(([k, v]) =>
    typeof v === "boolean" ? `${k.replace(/_/g, " ")}${v ? "" : " (off)"}` : `${k.replace(/_/g, " ")}: ${v}`
  );
}

export default function PlansPage({ onOpenBusiness }) {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [editing, setEditing] = useState(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      setData(await callOwnerFunction("plans_list"));
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  async function save(event) {
    event.preventDefault();
    setBusy(true);
    setError("");
    try {
      await callOwnerFunction("plan_save", editing);
      setEditing(null);
      await load();
    } catch (err) {
      setError(err.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="owner-page">
      <div className="owner-page-heading">
        <div>
          <div className="owner-eyebrow">BILLING</div>
          <h1>Plans & subscriptions</h1>
          <p>The plans businesses can be on, and which business is on which plan.</p>
        </div>
        <button type="button" className="owner-primary-button" onClick={() => setEditing({ ...EMPTY_PLAN })} disabled={busy}>
          ＋ New plan
        </button>
      </div>

      <div className="wiz-note op-gap">
        <strong>Pricing not configured.</strong> Prices haven't been decided, so plans have no amounts here and
        no customer is charged. Billing is connected later, once pricing is final.
      </div>

      {error && <div className="owner-form-error op-gap" role="alert">{error}</div>}

      {editing && (
        <form className="wiz-section op-gap" onSubmit={save}>
          <div className="wiz-section-head"><div><h3>{editing.planId ? "Edit plan" : "New plan"}</h3></div></div>
          <div className="owner-form-grid">
            <label className="owner-field">
              <span>Plan name *</span>
              <input required value={editing.name} onChange={(e) => setEditing({ ...editing, name: e.target.value })} />
            </label>
            <label className="owner-field">
              <span>Available for new businesses</span>
              <select value={editing.isActive ? "yes" : "no"} onChange={(e) => setEditing({ ...editing, isActive: e.target.value === "yes" })}>
                <option value="yes">Yes</option>
                <option value="no">No</option>
              </select>
            </label>
            <label className="owner-field wiz-field-full">
              <span>Description</span>
              <input value={editing.description} onChange={(e) => setEditing({ ...editing, description: e.target.value })} />
            </label>
          </div>
          <div className="ic-actions">
            <button type="button" className="owner-secondary-button" onClick={() => setEditing(null)} disabled={busy}>Cancel</button>
            <button type="submit" className="owner-primary-button" disabled={busy || !editing.name.trim()}>{busy ? "Saving..." : "Save plan"}</button>
          </div>
        </form>
      )}

      <div className="pl-grid op-gap">
        {(data?.plans ?? []).map((p) => {
          const features = describeJson(p.features);
          const limits = describeJson(p.limits);
          return (
            <section key={p.id} className={`owner-panel pl-card ${p.is_active ? "" : "off"}`}>
              <div className="pl-head">
                <div>
                  <h2>{p.name}</h2>
                  {p.description && <p>{p.description}</p>}
                </div>
                <Pill tone={p.is_active ? "success" : "neutral"}>{p.is_active ? "Available" : "Hidden"}</Pill>
              </div>
              <div className="pl-price">Pricing not configured</div>
              {features.length > 0 && (
                <div className="op-rule-block"><h4>Features</h4><ul className="op-bullets">{features.map((f) => <li key={f}>{f}</li>)}</ul></div>
              )}
              {limits.length > 0 && (
                <div className="op-rule-block"><h4>Limits</h4><ul className="op-bullets">{limits.map((f) => <li key={f}>{f}</li>)}</ul></div>
              )}
              <div className="pl-foot">
                <span className="op-muted">{p.subscriptions} {p.subscriptions === 1 ? "business" : "businesses"}</span>
                <button
                  type="button"
                  className="op-link"
                  onClick={() => setEditing({ planId: p.id, name: p.name, description: p.description || "", isActive: p.is_active })}
                >
                  Edit
                </button>
              </div>
            </section>
          );
        })}
        {!data?.plans?.length && (
          <div className="owner-panel"><div className="op-empty">{loading ? "Loading plans..." : "No plans yet."}</div></div>
        )}
      </div>

      <section className="owner-panel">
        <div className="owner-panel-heading">
          <div><h2>Subscriptions</h2><p>Which plan each business is on. Subscription status is separate from setup status.</p></div>
        </div>
        <div className="owner-table-wrap">
          <table className="owner-table">
            <thead><tr><th>Business</th><th>Plan</th><th>Status</th><th>Billing</th><th>Started</th></tr></thead>
            <tbody>
              {(data?.subscriptions ?? []).map((s) => (
                <tr key={s.id}>
                  <td><button type="button" className="op-name" onClick={() => onOpenBusiness(s.business_id)}>{s.business_name}</button></td>
                  <td>{s.plan_name}</td>
                  <td><Pill tone={SUB_TONE[s.status] ?? "neutral"}>{String(s.status ?? "").replace(/_/g, " ")}</Pill></td>
                  <td className="op-cap">{s.billing_interval ?? "—"}</td>
                  <td>{formatDate(s.created_at)}</td>
                </tr>
              ))}
              {!data?.subscriptions?.length && (
                <tr><td colSpan={5}><div className="op-empty">{loading ? "Loading..." : "No subscriptions yet."}</div></td></tr>
              )}
            </tbody>
          </table>
        </div>
      </section>
    </section>
  );
}
