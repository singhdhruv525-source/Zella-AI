// The automation list shown to the admin on a business's Automations tab. It lists every automation
// (even ones not set up yet), the ones preferred for the industry first, and how the owner is told.
import { CATALOG, NOTIFY_LABEL, catalogEntry, isPreferred, orderTypes } from "./automationCatalog";
import { Pill } from "./OwnerOverview";

export default function AutomationOverview({ rows, industryName, appointmentWord = "appointment", describeSettings }) {
  const list = rows ?? [];
  const baseTypes = CATALOG.map(([t]) => t);
  // The ten standard automations (listed even when not set up) plus each industry rule, preferred first.
  const items = [
    ...baseTypes.map((type) => ({ key: type, type, row: list.find((r) => r.trigger_type === type) ?? null })),
    ...list.filter((r) => !baseTypes.includes(r.trigger_type)).map((row, i) => ({ key: row.id ?? `${row.trigger_type}-${i}`, type: row.trigger_type, row })),
  ];
  const order = orderTypes(items.map((i) => i.type), industryName);
  items.sort((a, b) => (isPreferred(b.type, industryName) - isPreferred(a.type, industryName)) || (order.indexOf(a.type) - order.indexOf(b.type)));
  return (
    <div className="owner-table-wrap">
      <table className="owner-table">
        <thead><tr><th>Automation</th><th>Status</th><th>Tells owner by</th><th>Settings</th></tr></thead>
        <tbody>
          {items.map(({ key, type, row }) => {
            const entry = catalogEntry(type);
            const name = row?.name || (entry ? entry[1](appointmentWord) : type);
            const on = row && row.status !== "disabled";
            const cfg = row?.trigger_config ?? {};
            return (
              <tr key={key}>
                <td>
                  <strong className="op-strong">{name}</strong>
                  {industryName && isPreferred(type, industryName) && <> <Pill tone="success">Preferred for this business</Pill></>}
                  {entry && <div className="op-muted">{entry[2](appointmentWord)}</div>}
                  {!entry && row?.description && <div className="op-muted">{row.description}</div>}
                </td>
                <td>{row ? <Pill tone={row.status === "active" ? "success" : row.status === "paused" ? "info" : "neutral"}>{row.status === "disabled" ? "off" : row.status}</Pill> : <span className="op-muted">Not set up</span>}</td>
                <td>{on ? NOTIFY_LABEL[cfg.notify_via] ?? "Text and email" : "—"}</td>
                <td>{on ? (entry ? describeSettings(cfg) : "Industry rule") : "—"}</td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
