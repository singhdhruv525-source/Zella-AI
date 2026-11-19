// One business's page, Phone & integrations tab. Moved from BusinessDetails.jsx unchanged (BIZ-30); the page shell passes
// what it worked out from business_detail.
import { Pill } from "../OwnerOverview";
import { formatDateTime } from "../ownerFormat";
import { NumbersCard } from "./OverviewCards";
import { Card, Facts, Empty, label } from "./shared";

export default function PhoneTab({ data, setupData, phone, esc, can, businessId }) {
  return (
    <div className="op-stack">
      <Card title="Setup choices" description="What the business asked for during setup.">
        {setupData.integrations ? (
          <Facts items={[
            ["Phone setup", label(phone?.mode)],
            ...(phone?.mode !== "new_number"
              ? [["Forward from", phone?.forward_from || phone?.existing_number], ["Forward when", label(phone?.forward_when)]]
              : []),
            ["Preferred area code", phone?.area_code],
            ["Call transfer number", setupData.integrations.transfer_number],
            ["Calendar", label(setupData.integrations.calendar)],
            ["Email", label(setupData.integrations.email)],
            ["Lead sources", Object.entries(setupData.integrations.lead_sources || {})
              .filter(([, on]) => on).map(([k]) => ({ meta: "Meta", website: "Website", google: "Google" })[k]).join(", ")],
          ]} />
        ) : <Empty>Phone & integrations step not completed yet.</Empty>}
      </Card>

      <NumbersCard numbers={data.numbers} canAssign={can?.("telephony.manage")} businessId={businessId} />
      {esc && <p className="op-muted">Fallback number, where calls go when the AI receptionist can't take them: {esc.fallback_number || "not set"}.</p>}
      <Card title="Connection records" description="Provider connections recorded for this business. Phone numbers above are what calls use; most connections aren't recorded here yet.">
        {data.integrations.length ? (
          <div className="owner-table-wrap" tabIndex={0}>
            <table className="owner-table">
              <thead><tr><th>Provider</th><th>Type</th><th>Status</th><th>Account</th><th>Last sync</th><th>Error</th></tr></thead>
              <tbody>
                {data.integrations.map((i) => (
                  <tr key={i.id}>
                    <td className="op-cap">{i.provider}</td>
                    <td>{i.integration_type}</td>
                    <td><Pill tone={i.status === "active" ? "success" : i.status === "error" ? "danger" : "neutral"}>{i.status}</Pill></td>
                    <td>{i.account_email || <span className="op-muted">Not shown</span>}</td>
                    <td>{formatDateTime(i.last_synced_at)}</td>
                    <td className="op-muted">{i.error_message || "No problems"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : <Empty>Nothing connected yet. Telnyx, Vapi, calendar and lead sources appear here once connected.</Empty>}
      </Card>
    </div>
  );
}
