// One business's page, Activity tab. Moved from BusinessDetails.jsx unchanged (BIZ-30); the page shell passes
// what it worked out from business_detail.
import { actionLabel } from "../copy/auditActions";
import { formatDateTime, timeAgo } from "../ownerFormat";
import { Card, Empty } from "./shared";

export default function ActivityTab({ data }) {
  return (
    <Card title="Activity" description="Admin actions on this business.">
      {data.activity.length ? (
        <ul className="op-list op-activity">
          {data.activity.map((log) => (
            <li key={log.id}>
              <div>
                <strong>{actionLabel(log.action, log.entity_type)}</strong>
                <span>{log.actor ?? "Unknown user"} · {formatDateTime(log.created_at)} ({timeAgo(log.created_at)})</span>
              </div>
            </li>
          ))}
        </ul>
      ) : <Empty>No activity recorded yet.</Empty>}
    </Card>
  );
}
