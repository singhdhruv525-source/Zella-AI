import { useCallback, useEffect, useState } from "react";
import "./OwnerPages.css";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { formatDate, timeAgo } from "./ownerFormat";

const ROLE_LABELS = { zella_owner: "Zella owner", super_admin: "Super admin" };

export default function UsersAccess() {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [inviting, setInviting] = useState(false);
  const [invite, setInvite] = useState({ email: "", role: "super_admin" });
  const [confirm, setConfirm] = useState(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      setData(await callOwnerFunction("admins_list"));
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const isOwner = data?.me?.role === "zella_owner";

  async function run(action, payload, success) {
    setBusy(true);
    setError("");
    setNotice("");
    try {
      const result = await callOwnerFunction(action, payload);
      setNotice(success(result));
      setConfirm(null);
      await load();
      return true;
    } catch (err) {
      setError(err.message);
      return false;
    } finally {
      setBusy(false);
    }
  }

  async function submitInvite(event) {
    event.preventDefault();
    const ok = await run("admin_invite", invite, (r) =>
      r.invited
        ? `Invitation emailed to ${r.email}.`
        : `${r.email} already had a Zella login and can now use the admin dashboard.`
    );
    if (ok) {
      setInviting(false);
      setInvite({ email: "", role: "super_admin" });
    }
  }

  return (
    <section className="owner-page">
      <div className="owner-page-heading">
        <div>
          <div className="owner-eyebrow">ACCESS</div>
          <h1>Users & access</h1>
          <p>People who can use this Zella admin dashboard. Business owners and staff are managed inside each business.</p>
        </div>
        {isOwner && (
          <button type="button" className="owner-primary-button" onClick={() => setInviting(true)} disabled={busy}>
            ＋ Add admin
          </button>
        )}
      </div>

      {notice && <div className="ic-notice" role="status">{notice}</div>}
      {error && <div className="owner-form-error op-gap" role="alert">{error}</div>}

      {data && !isOwner && (
        <div className="wiz-note op-gap">You can view platform admins. Only a Zella owner can add or remove them.</div>
      )}

      {inviting && (
        <form className="wiz-section op-gap" onSubmit={submitInvite}>
          <div className="wiz-section-head">
            <div>
              <h3>Add a platform admin</h3>
              <p>They get full access to every client business. If they don't have a Zella login yet, they're emailed an invitation.</p>
            </div>
          </div>
          <div className="owner-form-grid">
            <label className="owner-field">
              <span>Email *</span>
              <input type="email" required value={invite.email} onChange={(e) => setInvite({ ...invite, email: e.target.value })} />
            </label>
            <label className="owner-field">
              <span>Role</span>
              <select value={invite.role} onChange={(e) => setInvite({ ...invite, role: e.target.value })}>
                <option value="super_admin">Super admin: manages businesses and setup</option>
                <option value="zella_owner">Zella owner: also manages admins</option>
              </select>
            </label>
          </div>
          <div className="ic-actions">
            <button type="button" className="owner-secondary-button" onClick={() => setInviting(false)} disabled={busy}>Cancel</button>
            <button type="submit" className="owner-primary-button" disabled={busy || !invite.email.trim()}>
              {busy ? "Adding..." : "Add admin"}
            </button>
          </div>
        </form>
      )}

      {confirm && (
        <div className="ic-warning op-gap">
          <span>{confirm.message}</span>
          <div>
            <button type="button" className="owner-secondary-button op-small" onClick={() => setConfirm(null)} disabled={busy}>Cancel</button>
            <button type="button" className="owner-primary-button op-small" onClick={confirm.run} disabled={busy}>
              {busy ? "Saving..." : confirm.label}
            </button>
          </div>
        </div>
      )}

      <section className="owner-panel">
        <div className="owner-table-wrap">
          <table className="owner-table">
            <thead>
              <tr><th>Admin</th><th>Role</th><th>Status</th><th>Last sign-in</th><th>Added</th><th /></tr>
            </thead>
            <tbody>
              {(data?.admins ?? []).map((a) => (
                <tr key={a.user_id}>
                  <td>
                    <div className="owner-business-cell">
                      <strong>{a.email ?? a.user_id}{a.isYou ? " (you)" : ""}</strong>
                      {a.added_by && <span>Added by {a.added_by}</span>}
                    </div>
                  </td>
                  <td>
                    {isOwner && !a.isYou && a.is_active ? (
                      <select
                        className="us-role"
                        value={a.role}
                        disabled={busy}
                        aria-label={`Role for ${a.email}`}
                        onChange={(e) => {
                          const role = e.target.value;
                          setConfirm({
                            message: `Change ${a.email} to ${ROLE_LABELS[role]}?`,
                            label: "Change role",
                            run: () => run("admin_update", { userId: a.user_id, role }, () => `${a.email} is now a ${ROLE_LABELS[role]}.`),
                          });
                        }}
                      >
                        <option value="super_admin">Super admin</option>
                        <option value="zella_owner">Zella owner</option>
                      </select>
                    ) : (
                      ROLE_LABELS[a.role] ?? a.role
                    )}
                  </td>
                  <td><Pill tone={a.is_active ? "success" : "neutral"}>{a.is_active ? "Active" : "Removed"}</Pill></td>
                  <td>{a.last_sign_in_at ? timeAgo(a.last_sign_in_at) : "Never"}</td>
                  <td>{formatDate(a.created_at)}</td>
                  <td>
                    {isOwner && !a.isYou && (
                      <button
                        type="button"
                        className={a.is_active ? "wiz-link-danger us-action" : "op-link"}
                        disabled={busy}
                        onClick={() =>
                          setConfirm(
                            a.is_active
                              ? {
                                  message: `Remove ${a.email}'s access to the Zella admin dashboard?`,
                                  label: "Remove access",
                                  run: () => run("admin_update", { userId: a.user_id, isActive: false }, () => `${a.email} no longer has admin access.`),
                                }
                              : {
                                  message: `Give ${a.email} admin access again?`,
                                  label: "Restore access",
                                  run: () => run("admin_update", { userId: a.user_id, isActive: true }, () => `${a.email} has admin access again.`),
                                }
                          )
                        }
                      >
                        {a.is_active ? "Remove access" : "Restore access"}
                      </button>
                    )}
                  </td>
                </tr>
              ))}
              {!data?.admins?.length && (
                <tr><td colSpan={6}><div className="op-empty">{loading ? "Loading admins..." : "No platform admins found."}</div></td></tr>
              )}
            </tbody>
          </table>
        </div>
        <div className="owner-panel-footer">
          <span>{data?.admins?.filter((a) => a.is_active).length ?? 0} active admins</span>
          <span>Zella always keeps at least one active owner, and nobody can change their own access.</span>
        </div>
      </section>
    </section>
  );
}
