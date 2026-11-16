import { callOwnerFunction } from "../../CreateBusinessWizard";
import { Card, Facts, LoadState, Needs, Pill, Table, useAsync, when, words } from "../SettingsKit";
import { SettingNumber } from "../AdminPanels";
import { retentionState } from "../../businessLifecycle";

// Settings > Data lifecycle (Lane B): how long a cancelled business's records are kept, every cancelled business with
// its retention date, the ones past it (BIZ-13c), and customer data request counts. Read only: nothing on this page
// deletes a business; a purge waits for the owner's and legal's answer on the retention period (BIZ-13d).

const call = (action, payload) => callOwnerFunction(action, payload);

export default function DataLifecycle({ me }) {
  const state = useAsync(() => call("privacy_overview"), []);
  return (
    <LoadState state={state}>{(p) => {
      const past = (p.cancelled ?? []).filter((b) => b.past_retention);
      return (
        <>
          <SettingNumber me={me} keyName="retention_days" label="Days a canceled business's records are kept" current={p.retentionDays}
            hint={`Pending legal review: the architecture says 30 days after cancellation; the database uses this setting, or 90 when it isn't set${p.retentionSetting === "default" ? " (it isn't set, so 90 applies now)" : ""}. Changing it changes the date for businesses canceled from now on.`} />
          <Card title="Past their retention date" sub="Canceled businesses whose retention date has passed. Nothing is deleted automatically: deleting a canceled business's records waits for the owner and legal review.">
            <Table rows={past} empty="No canceled business is past its retention date." columns={[
              ["Business", (b) => b.name], ["Canceled", (b) => when(b.cancelled_at)], ["Retention date", (b) => when(b.retention_until)],
            ]} />
          </Card>
          <Card title="Canceled businesses" sub="Their records stay until the retention date.">
            <Table rows={p.cancelled ?? []} empty="No canceled businesses." columns={[
              ["Business", (b) => b.name], ["Canceled", (b) => when(b.cancelled_at)], ["Retention date", (b) => (b.retention_until ? when(b.retention_until) : "Not set")],
              ["State", (b) => { const [label, tone] = retentionState(b); return <Pill tone={tone}>{label}</Pill>; }],
            ]} />
          </Card>
          <Card title="Customer data requests across businesses" sub="Counts only. Each business handles its own requests.">
            <Facts rows={[["Open", p.requests.open], ["Overdue", p.requests.overdue], ...Object.entries(p.requests.byKind).map(([k, v]) => [words(k), v])]} />
          </Card>
          <Needs title="Whole business export and deletion jobs aren't built" have="Each business can export or erase individual customers (with a second approval). Canceled businesses are kept, never deleted automatically.">
            Exporting or deleting a whole business needs a job that runs in the background, records its progress, and can be approved and stopped.
          </Needs>
        </>
      );
    }}</LoadState>
  );
}
