// One business's page, Configuration tab. Moved from BusinessDetails.jsx unchanged (BIZ-30); the page shell passes
// what it worked out from business_detail.
import { Pill } from "../OwnerOverview";
import { BusinessModulesCard, BusinessRecordsCard } from "../BusinessAdminControls";
import { Card, TERM_ROWS } from "./shared";

export default function ConfigurationTab({ data, terms, term, enabledModules, canManage, businessId, load }) {
  return (
    <div className="op-grid">
      <Card title="Terminology" description="How this business's CRM names things.">
        <div className="owner-table-wrap" tabIndex={0}>
          <table className="owner-table">
            <thead><tr><th>Term</th><th>Used here</th><th>Industry default</th></tr></thead>
            <tbody>
              {TERM_ROWS.map(([singular, plural, name]) => {
                const custom = terms.overrides?.[singular] || terms.overrides?.[plural];
                return (
                  <tr key={singular}>
                    <td>{name}</td>
                    <td>
                      <strong className="op-strong">{term(singular)} / {term(plural)}</strong>
                      {custom && <Pill tone="info">Custom</Pill>}
                    </td>
                    <td>{terms.industry?.[singular] || "Not set"} / {terms.industry?.[plural] || "Not set"}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </Card>

      <Card title="Modules" description={`${enabledModules.length} of ${data.modules.length} switched on. Only modules its industry offers are listed.`}>
        <BusinessModulesCard key={data.modules.map((m) => `${m.id}${m.enabled}`).join()} businessId={businessId} modules={data.modules} onSaved={load} canEdit={canManage} />
      </Card>

      <Card title="Industry records" description="Record types from its industry, such as tables, recalls or vehicles. Switching one off hides it; records are kept.">
        <BusinessRecordsCard businessId={businessId} canEdit={canManage} />
      </Card>
    </div>
  );
}
