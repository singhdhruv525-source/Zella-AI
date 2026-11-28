// One business's page, Activity tab: admin and system changes, each with what it was before and after (BIZ-17), the
// total (BIZ-30), and, separately, who opened the business or revealed its contacts (Support access, BIZ-22).
// The server sends this only to admins with audit.view; the tab is hidden for anyone else.
import { actionLabel } from "../copy/auditActions";
import { changeLines } from "./changes";
import { formatDateTime, timeAgo } from "../ownerFormat";
import { Card, Empty } from "./shared";

function Row({ log }) {
  const lines = changeLines(log.old_data, log.new_data);
  return (
    <li>
      <div>
        <strong>{actionLabel(log.action, log.entity_type)}</strong>
        <span>{log.actor ?? (log.user_id ? "Someone not shown here" : "Zella Voice system")}, {formatDateTime(log.created_at)} ({timeAgo(log.created_at)})</span>
        {lines.length > 0 && <ul className="bd-changes">{lines.map((l) => <li key={l}>{l}</li>)}</ul>}
      </div>
    </li>
  );
}

export default function ActivityTab({ data }) {
  const total = typeof data.activityCount === "number" ? data.activityCount : null;
  // null from the server: the list couldn't be read (never shown as "nobody opened it")
  const support = Array.isArray(data.supportAccess) ? data.supportAccess : [];
  const supportUnavailable = data.activityAllowed === true && data.supportAccess === null;
  return (
    <div className="op-stack">
      <Card title="Activity" description={total !== null && total > data.activity.length
        ? `Admin and system changes to this business. The newest ${data.activity.length} of ${total}.`
        : "Admin and system changes to this business."}>
        {data.activity.length ? (
          <ul className="op-list op-activity">{data.activity.map((log) => <Row key={log.id} log={log} />)}</ul>
        ) : <Empty>No activity recorded yet.</Empty>}
      </Card>
      {(Array.isArray(data.supportAccess) || supportUnavailable) && (
        <Card title="Support access" description="Who opened this business, or revealed its contact details, and why.">
          {supportUnavailable ? <Empty>Support access history is unavailable right now. Try again later.</Empty> : support.length ? (
            <ul className="op-list op-activity">{support.map((log) => <Row key={log.id} log={{ ...log, old_data: null }} />)}</ul>
          ) : <Empty>Nobody has opened this business yet.</Empty>}
        </Card>
      )}
    </div>
  );
}
