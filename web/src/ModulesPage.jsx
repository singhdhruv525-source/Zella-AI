import "./OwnerPages.css";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { LoadNotice, UpdatedAt, useRefreshable } from "./admin/loadState";
import { emptyText } from "./admin/loadStatus";

const loadModules = () => callOwnerFunction("modules_overview");

export default function ModulesPage({ onNavigate }) {
  const state = useRefreshable(loadModules);
  const { data, loading } = state;
  const load = state.reload;

  const nameFor = (slug) => data?.modules?.find((m) => m.slug === slug)?.name ?? slug;

  return (
    <section className="owner-page">
      <div className="owner-page-heading">
        <div>
          <div className="owner-eyebrow">Configuration</div>
          <h1>Modules & features</h1>
          <p>Every CRM module on Zella, which industries offer it, and how many businesses use it.</p>
        </div>
        <div className="op-heading-actions">
          <UpdatedAt r={state} />
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

      <LoadNotice r={state} what="the module catalog" />

      <section className="owner-panel">
        <div className="owner-table-wrap" tabIndex={0}>
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
                <tr><td colSpan={4}><div className="op-empty">{emptyText(state, Array.isArray(data?.modules) ? "No modules configured yet." : "Not reported.", "the module catalog")}</div></td></tr>
              )}
            </tbody>
          </table>
        </div>
      </section>
    </section>
  );
}
