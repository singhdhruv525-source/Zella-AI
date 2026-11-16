// One business's page, People tab. Moved from BusinessDetails.jsx unchanged (BIZ-30); the page shell passes
// what it worked out from business_detail.
import { useState } from "react";
import { Pill } from "../OwnerOverview";
import { callOwnerFunction } from "../CreateBusinessWizard";
import ActionDialog from "./ActionDialog";
import { resendAt } from "./people";
import { formatDate, formatDateTime } from "../ownerFormat";
import { Card, Empty } from "./shared";

export default function PeopleTab({ data, invitation, isCancelled, canManage, busy, setPending, businessId, load }) {
  // UI-06: last sign in and two step status, sent only to admins with businesses.manage
  const signIn = data.signInFactsAllowed === true;
  const [dialog, setDialog] = useState(null);
  const [revealed, setRevealed] = useState(null);   // BIZ-22: for this response only, never kept
  const [notice, setNotice] = useState("");
  const call = (action, extra) => (reason) => callOwnerFunction(action, { businessId, reason, ...extra });
  const done = (text) => async (r) => { setDialog(null); setNotice(text + (r?.auditWarning ? ` ${r.auditWarning}` : "")); await load(); };
  const owner = (data.invitations ?? []).find((i) => (i.role ?? "owner") === "owner" && i.id === invitation?.id) ?? invitation;
  const retryAt = resendAt(owner?.invited_at, new Date());
  const emailOf = (kind, id, masked) => revealed?.[kind]?.find((x) => (x.user_id ?? x.id) === id)?.email ?? masked;
  const DIALOGS = {
    reveal: { title: "Show contact details?", body: "Emails, callers' numbers and connection accounts for this business are shown on this page until you leave it. Your reason is recorded first.",
      button: "Show", reason: { min: 10, max: 300 }, run: call("business_contacts_reveal"), onDone: (r) => { setDialog(null); setRevealed(r); } },
    cancel: { title: "Cancel the owner's invitation?", body: "The link stops working and the invited seat is removed, so the same person can be invited again.",
      button: "Cancel invitation", danger: true, reason: { min: 10, max: 300 }, run: call("invitation_cancel"), onDone: done("The owner's invitation is canceled.") },
  };
  const memberDialog = (m, kind) => kind === "status"
    ? { title: m.status === "active" ? "Deactivate this member?" : "Reactivate this member?",
        body: m.status === "active" ? "They lose access to this business's workspace until they are reactivated." : "They get access to this business's workspace again.",
        button: m.status === "active" ? "Deactivate" : "Reactivate", danger: m.status === "active", reason: { min: 10, max: 300 },
        run: call("member_set_status", { userId: m.user_id, status: m.status === "active" ? "suspended" : "active" }), onDone: done("Member access updated.") }
    : { title: "Reset this member's two step sign in?", body: "Their authenticator is removed and they set a new one up at their next sign in. Do this only after the identity check (call back the business's number on record).",
        button: "Reset two step", danger: true, reason: { min: 10, max: 300 }, needsCheck: true,
        run: (reason) => callOwnerFunction("member_mfa_reset", { businessId, userId: m.user_id, reason, identityChecked: true }), onDone: done("Two step sign in reset.") };
  const [checked, setChecked] = useState(false);
  const d = dialog && (typeof dialog === "string" ? DIALOGS[dialog] : dialog);
  return (
    <div className="op-stack">
      {notice && <div className="ic-notice" role="status">{notice}</div>}
      {canManage && data.contactsMasked && (
        <div className="bd-reveal">
          {revealed ? <span className="op-muted">Contact details shown for this visit. Leaving the page hides them again.</span>
            : <button type="button" className="owner-secondary-button op-small" onClick={() => setDialog("reveal")}>Show contact details</button>}
        </div>
      )}
      {d && (
        <ActionDialog title={d.title} body={d.body} button={d.button} danger={d.danger} reason={d.reason} ready={!d.needsCheck || checked}
          onRun={d.run} onDone={d.onDone} onClose={() => { setDialog(null); setChecked(false); }}>
          {d.needsCheck && (
            <label className="bd-check"><input type="checkbox" checked={checked} onChange={(e) => setChecked(e.target.checked)} /> I checked who is asking, as the identity check says</label>
          )}
        </ActionDialog>
      )}
      <Card title="Members" description="People with access to this business's workspace.">
        {data.members.length ? (
          <div className="owner-table-wrap" tabIndex={0}>
            <table className="owner-table">
              <thead><tr><th>Name</th><th>Email</th><th>Role</th><th>Status</th><th>Added</th>{signIn && <><th>Last sign in</th><th>Two step</th></>}{canManage && <th aria-label="Actions" />}</tr></thead>
              <tbody>
                {data.members.map((m) => (
                  <tr key={m.user_id}>
                    <td>{m.name || <span className="op-muted">No name yet</span>}</td>
                    <td>{emailOf("members", m.user_id, m.email) || <span className="op-muted">Not known</span>}</td>
                    <td className="op-cap">{m.role}</td>
                    <td><Pill tone={m.status === "active" ? "success" : "neutral"}>{m.status}</Pill></td>
                    <td>{formatDate(m.created_at)}</td>
                    {signIn && <>
                      <td>{m.last_sign_in_at ? formatDateTime(m.last_sign_in_at) : <span className="op-muted">Never</span>}</td>
                      <td>{m.two_step ? <Pill tone="success">On</Pill> : <Pill tone="neutral">Off</Pill>}</td>
                    </>}
                    {canManage && (
                      <td className="bd-row-actions">
                        {["active", "suspended"].includes(m.status) && (
                          <button type="button" className="owner-secondary-button op-small" onClick={() => setDialog(memberDialog(m, "status"))}>{m.status === "active" ? "Deactivate" : "Reactivate"}</button>
                        )}
                        {m.two_step && <button type="button" className="owner-secondary-button op-small" onClick={() => setDialog(memberDialog(m, "mfa"))}>Reset two step</button>}
                      </td>
                    )}
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
            <div className="bd-row-actions">
              <button type="button" className="owner-secondary-button op-small" onClick={() => setPending("resend")} disabled={busy || Boolean(retryAt)}
                title={retryAt ? `Can be sent again at ${formatDateTime(retryAt)}` : undefined}>
                Resend invitation
              </button>
              <button type="button" className="wiz-link-danger" onClick={() => setDialog("cancel")} disabled={busy}>Cancel invitation</button>
            </div>
          )
        }
      >
        {retryAt && canManage && <p className="op-muted bd-hint">An invitation went out a few minutes ago. It can be sent again at {formatDateTime(retryAt)}.</p>}
        {data.invitations.length ? (
          <div className="owner-table-wrap" tabIndex={0}>
            <table className="owner-table">
              <thead><tr><th>Name</th><th>Email</th><th>Role</th><th>Status</th><th>Sent</th><th>Expires</th><th>Last error</th></tr></thead>
              <tbody>
                {data.invitations.map((i) => (
                  <tr key={i.id}>
                    <td>{i.owner_name}</td>
                    <td>{emailOf("invitations", i.id, i.email)}</td>
                    <td>{i.role === "owner" || !i.role ? "Owner" : i.role[0].toUpperCase() + i.role.slice(1)}</td>
                    <td>
                      <Pill tone={i.status === "accepted" ? "success" : i.status === "failed" || i.status === "expired" ? "danger" : "neutral"}>
                        {i.status}
                      </Pill>
                    </td>
                    <td>{formatDateTime(i.invited_at)}</td>
                    <td>{formatDate(i.expires_at)}</td>
                    <td className="op-muted">{i.last_error || "No problems"}</td>
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
