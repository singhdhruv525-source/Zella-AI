// One business's page, Calls tab. Moved from BusinessDetails.jsx unchanged (BIZ-30); the page shell passes
// what it worked out from business_detail.
import { formatDateTime, formatDuration } from "../ownerFormat";
import { Card, Empty } from "./shared";

export default function CallsTab({ data }) {
  return (
    <Card title="Recent calls" description={`${data.callCount} calls recorded`}>
      {data.calls.length ? (
        <div className="owner-table-wrap" tabIndex={0}>
          <table className="owner-table">
            <thead><tr><th>When</th><th>Direction</th><th>From</th><th>To</th><th>Duration</th><th>Handled by</th><th>Status</th></tr></thead>
            <tbody>
              {data.calls.map((c) => (
                <tr key={c.id}>
                  <td>{formatDateTime(c.started_at || c.created_at)}</td>
                  <td className="op-cap">{c.direction}</td>
                  <td>{c.from_number || <span className="op-muted">Not recorded</span>}</td>
                  <td>{c.to_number || <span className="op-muted">Not recorded</span>}</td>
                  <td>{formatDuration(c.duration_seconds)}</td>
                  <td>{c.ai_handled ? "AI" : "Team"}</td>
                  <td className="op-cap">{c.status}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : <Empty>No calls yet. Calls appear once the phone number and AI receptionist are connected.</Empty>}
    </Card>
  );
}
