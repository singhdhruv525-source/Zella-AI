import { useCallback, useEffect, useState } from "react";
import "./OwnerPages.css";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";

export default function ModulesPage({ onNavigate }) {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      setData(await callOwnerFunction("modules_overview"));
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const nameFor = (slug) => data?.modules?.find((m) => m.slug === slug)?.name ?? slug;

  return (
    <section className="owner-page">
      <div className="owner-page-heading">
        <div>
          <div className="owner-eyebrow">CONFIGURATION</div>
          <h1>Modules & features</h1>
          <p>Every CRM module on Zella, which industries offer it, and how many businesses use it.</p>
        </div>
        <div className="op-heading-actions">
          <button type="button" className="owner-secondary-button" onClick={load} disabled={loading}>
            {loading ? "Loading..." : "↻ Refresh"}
          </button>
          <button type="button" className="owner-primary-button" onClick={() => onNavigate("Industry Configuration")}>
            Edit in Industry Configuration
          </button>
        </div>
      </div>

      <div className="wiz-note op-gap">
        Modules are set per industry. To add, rename or stop offering a module, open Industry Configuration.
        Each business's own modules are chosen in its setup.
      </div>

      {error && <div className="owner-form-error op-gap">Could not load modules: {error}</div>}

      <section className="owner-panel">
        <div className="owner-table-wrap">
          <table className="owner-table">
            <thead><tr><th>Module</th><th>Offered in</th><th>Needs</th><th>Businesses using it</th></tr></thead>
            <tbody>
              {(data?.modules ?? []).map((m) => (
                <tr key={m.slug}>
                  <td>
                    <div className="owner-business-cell">
                      <strong>{m.name}</strong>
                      <span>{m.description || m.slug}</span>
                    </div>
                  </td>
                  <td>
                    {m.offeredIn.length ? (
                      <span title={m.offeredIn.join(", ")}>
                        {m.offeredIn.length === data.industries ? "All industries" : `${m.offeredIn.length} industries`}
                      </span>
                    ) : <Pill>Not offered</Pill>}
                    {m.hiddenIn.length > 0 && <div className="op-muted mo-sub">Off in {m.hiddenIn.join(", ")}</div>}
                  </td>
                  <td>{m.requires.length ? m.requires.map(nameFor).join(", ") : <span className="op-muted">—</span>}</td>
                  <td><strong className="op-strong">{m.businesses}</strong></td>
                </tr>
              ))}
              {!data?.modules?.length && (
                <tr><td colSpan={4}><div className="op-empty">{loading ? "Loading modules..." : "No modules configured yet."}</div></td></tr>
              )}
            </tbody>
          </table>
        </div>
      </section>
    </section>
  );
}
