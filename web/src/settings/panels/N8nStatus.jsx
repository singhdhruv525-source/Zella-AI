import { callOwnerFunction } from "../../CreateBusinessWizard";
import { Card, LoadState, Pill, Table, useAsync, when } from "../SettingsKit";

// n8n's own view of each Zella Voice workflow (AUTO-N8N-STATUS): active in n8n or not, and its last execution. Read on
// the server with an n8n API key kept as a secret (owner-provision-business n8n_status); the key never reaches the
// browser. Until the owner sets the key and the address, it says "Not connected yet".
const RUN = { success: ["success", "Succeeded"], error: ["danger", "Failed"], crashed: ["danger", "Failed"], running: ["warning", "Running"], waiting: ["warning", "Waiting"], canceled: ["neutral", "Cancelled"] };

export default function N8nStatus() {
  const state = useAsync(() => callOwnerFunction("n8n_status"), []);
  return (
    <LoadState state={state}>{(s) => {
      if (!s.configured) {
        return (
          <Card title="n8n's own status" sub="Whether each workflow is active in n8n, and how its last run went." actions={<Pill tone="neutral">Not connected yet</Pill>}>
            <p className="zs-muted" data-n8n-status="not_connected">Reading this needs an n8n API key and the n8n address, set by the owner as server secrets. Until then nothing is read from n8n. Workflow runs Zella Voice records are under Runs.</p>
          </Card>
        );
      }
      if (!s.ok) {
        return (
          <Card title="n8n's own status" actions={<Pill tone="danger">Not read</Pill>}>
            <p className="zs-muted" data-n8n-status="error" role="alert">{s.error}. Nothing here is confirmed.</p>
          </Card>
        );
      }
      return (
        <Card title="n8n's own status" sub={`Read from n8n ${when(s.checkedAt)}. ${s.workflows.filter((w) => w.active).length} of ${s.workflows.length} workflows active.`}>
          <div data-n8n-status="ok">
            <Table rowKey={(w) => w.id} rows={s.workflows} empty="n8n has no Zella Voice workflows."
              columns={[["Workflow", (w) => w.name], ["In n8n", (w) => <Pill tone={w.active ? "success" : "warning"}>{w.active ? "Active" : "Inactive"}</Pill>],
                ["Last run", (w) => { if (!w.lastExecution) return "Never"; const [tone, label] = RUN[w.lastExecution.status] ?? ["neutral", "Unknown"];
                  return <span><Pill tone={tone}>{label}</Pill> {when(w.lastExecution.stoppedAt ?? w.lastExecution.startedAt)}</span>; }]]} />
          </div>
        </Card>
      );
    }}</LoadState>
  );
}
