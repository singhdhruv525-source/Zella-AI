// One business's page, People tab. Moved from BusinessDetails.jsx unchanged (BIZ-30); the page shell passes
// what it worked out from business_detail.
import { Pill } from "../OwnerOverview";
import { formatDate, formatDateTime } from "../ownerFormat";
import { Card, Empty } from "./shared";

export default function PeopleTab({ data, invitation, isCancelled, canManage, busy, setPending }) {
  return (
    <div className="op-stack">
      <Card title="Members" description="People with access to this business's workspace.">
        {data.members.length ? (
          <div className="owner-table-wrap" tabIndex={0}>
            <table className="owner-table">
              <thead><tr><th>Name</th><th>Email</th><th>Role</th><th>Status</th><th>Added</th></tr></thead>
              <tbody>
                {data.members.map((m) => (
                  <tr key={m.user_id}>
                    <td>{m.name || "None"}</td>
                    <td>{m.email || "None"}</td>
                    <td className="op-cap">{m.role}</td>
                    <td><Pill tone={m.status === "active" ? "success" : "neutral"}>{m.status}</Pill></td>
                    <td>{formatDate(m.created_at)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <Empty>No members yet. The owner is added when their invitation is sent.</Empty>
        )}
      </Card>

      <Card
        title="Invitations"
        action={
          canManage && invitation && invitation.status !== "accepted" && !isCancelled && (
            <button type="button" className="owner-secondary-button op-small" onClick={() => setPending("resend")} disabled={busy}>
              Resend invitation
            </button>
          )
        }
      >
        {data.invitations.length ? (
          <div className="owner-table-wrap" tabIndex={0}>
            <table className="owner-table">
              <thead><tr><th>Name</th><th>Email</th><th>Role</th><th>Status</th><th>Sent</th><th>Expires</th><th>Last error</th></tr></thead>
              <tbody>
                {data.invitations.map((i) => (
                  <tr key={i.id}>
                    <td>{i.owner_name}</td>
                    <td>{i.email}</td>
                    <td>{i.role === "owner" || !i.role ? "Owner" : i.role[0].toUpperCase() + i.role.slice(1)}</td>
                    <td>
                      <Pill tone={i.status === "accepted" ? "success" : i.status === "failed" || i.status === "expired" ? "danger" : "neutral"}>
                        {i.status}
                      </Pill>
                    </td>
                    <td>{formatDateTime(i.invited_at)}</td>
                    <td>{formatDate(i.expires_at)}</td>
                    <td className="op-muted">{i.last_error || "None"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <Empty>No invitations yet.</Empty>
        )}
      </Card>
    </div>
  );
}
