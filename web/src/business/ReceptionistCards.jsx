// AI receptionist tab: how calls are routed (UI-07) and what callers actually get (COM-03), from business_detail.
// The page describes a test call; it never places one.
import { Pill } from "../OwnerOverview";
import { navigate } from "../router";
import { formatDateTime } from "../ownerFormat";
import { humanize } from "../copy/labels";
import { Card, Empty, Facts } from "./shared";

const yesNo = (v) => (v ? "Yes" : "No");

export function RoutingCard({ routing }) {
  if (!routing) return null;
  return (
    <Card title="Call routing" description="Where a caller goes when they ask for a person, as the Voice page shows it."
      action={<button type="button" className="owner-secondary-button op-small" onClick={() => navigate("/voice/routing")}>Open call routing</button>}>
      <Facts items={[
        ["Put callers through", yesNo(routing.transfer_enabled)],
        ["Transfer number", routing.transfer_number],
        ["Fallback number", routing.fallback_number],
        ["Route", humanize(routing.transfer_route)],
        ["Only during opening hours", yesNo(routing.transfer_open_hours_only)],
        ["Opening hours saved", yesNo(routing.has_hours)],
      ]} />
      <p className="op-muted bd-hint">To test: call the business's Zella Voice number, ask for a person, and check the call reaches the transfer number (or the fallback number when nobody answers).</p>
    </Card>
  );
}

export function CallersGetCard({ deliveries }) {
  if (!deliveries) return null;
  if (!deliveries.available) return <Card title="What callers get"><Empty>Not available right now. The Zella Voice team can check why.</Empty></Card>;
  // the status facts only from a status read that answered (statusAvailable); otherwise they are unknown, never "no
  // call served yet". Older servers without the flag: a status object counts as answered.
  const statusOk = deliveries.statusAvailable ?? (deliveries.status != null);
  const st = statusOk ? deliveries.status ?? {} : {};
  const unknown = "Not known right now";
  const last = st.delivery?.last_served;
  const counts = deliveries.counts;
  return (
    <Card title="What callers get" description="The receptionist settings calls were last given, compared with what the next call gets now.">
      <Facts items={[
        ["Settings for the next call", !statusOk ? unknown : st.current_config_hash ? `Configuration ${String(st.current_config_hash).slice(0, 8)}` : "Not worked out"],
        ["Last call served", !statusOk ? unknown : last ? `${formatDateTime(last.at)}, ${last.is_current ? "same settings as now" : "older settings"}` : "No call served yet"],
        ["Published version", !statusOk ? unknown : st.version ? `${humanize(st.version.sync_status ?? "saved")}, ${formatDateTime(st.version.published_at)}` : "None published"],
        ["Last time a call couldn't be served", !statusOk ? unknown : st.last_problem ? `${formatDateTime(st.last_problem.at)}: ${(st.last_problem.problems ?? []).map(humanize).join(", ") || "no reason given"}` : "Never"],
        [`Not ready in the last ${deliveries.lastDays} days`, counts ? String(counts.not_ready) : "Not known"],
      ]} />
      {last && <p className="bd-hint">{last.is_current ? <Pill tone="success">Calls get the current settings</Pill> : <Pill tone="warning">The next call gets newer settings</Pill>}</p>}
    </Card>
  );
}
