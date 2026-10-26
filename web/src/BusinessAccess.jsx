import { useState } from "react";
import { supabase } from "./supabase";
import { Field, Icon, Modal, Pill, initials } from "./BusinessUI";
import { timeAgo } from "./businessTime";
import { Empty, Notice, PageHead, friendly, orThrow, plural, useLoad } from "./BusinessShared";

// Approvals, Team access, Failed work and the Security log.
// Every action goes through a Supabase function that checks the person's role itself.

const ERRORS = {
  NOT_ALLOWED: "Only an owner or admin can do this.",
  BAD_EMAIL: "That email address doesn't look right.",
  BAD_ROLE: "Choose a role from the list.",
  ALREADY_A_MEMBER: "That person already has access.",
  ALREADY_INVITED: "That person already has an invitation waiting.",
  ONLY_OWNER_CAN_INVITE_ADMIN: "Only the owner can invite an admin.",
  LAST_OWNER: "This is the only owner. Make someone else an owner first.",
  TARGET_NOT_ACTIVE: "Choose someone who currently has access.",
  NOT_RETRYABLE: "This can't be retried any more.",
  CANNOT_CANCEL: "This invitation is already closed.",
  CANNOT_RESEND: "This invitation is already closed.",
};
const say = (error) => {
  const code = Object.keys(ERRORS).find((k) => (error?.message ?? "").includes(k));
  return code ? ERRORS[code] : friendly(error);
};
// Sends the invitation email and ties the invitation to that person's account (staff-invite function).
async function sendInvitationEmail(invitationId) {
  const { data, error } = await supabase.functions.invoke("staff-invite", { body: { invitationId } });
  if (error) {
    let message = "The invitation email could not be sent. Please try again.";
    try { message = (await error.context?.json())?.error ?? message; } catch { /* keep the general message */ }
    throw new Error(message);
  }
  return data ?? {};
}
const sentMessage = (email, result) => result.existingAccount
  ? `${email} already has a Zella account. They'll see this workspace the next time they sign in.`
  : `Invitation emailed to ${email}. The link works once and the invitation is valid for 14 days.`;

const words = (s) => String(s ?? "").replace(/_/g, " ").replace(/^./, (c) => c.toUpperCase());
const ROLES = [["staff", "Staff"], ["manager", "Manager"], ["viewer", "View only"], ["admin", "Admin"]];

/* ---------- Approvals ---------- */
export function ApprovalsPage({ workspace, refreshKey, onNotice }) {
  const { data, error, loading, reload } = useLoad(async () => {
    const { data: rows, error: e } = await supabase.rpc("zella_pending_approvals", { p_business_id: workspace.id });
    if (e) throw e;
    return rows ?? [];
  }, [workspace.id, refreshKey]);
  const [busy, setBusy] = useState("");

  async function decide(row, approve) {
    setBusy(row.id);
    const { error: e } = await supabase.rpc("zella_decide_approval", { p_approval_id: row.id, p_approve: approve });
    setBusy("");
    if (e) return onNotice(say(e));
    onNotice(approve ? "Approved. The action can go ahead." : "Declined. Nothing was changed.");
    reload();
  }

  return (
    <>
      <PageHead crumb="Management / Approvals" title="Approvals" sub="Sensitive actions wait here until a second person says yes." />
      <Notice error={error} onRetry={reload} />
      <section className="ba-panel">
        {!data?.length ? (
          <div className="ba-panel-body"><Empty title={loading ? "Loading…" : "Nothing waiting"}>When someone asks to erase a customer's data or do something similar, it shows up here.</Empty></div>
        ) : (
          <ul className="ba-threads">
            {data.map((a) => (
              <li key={a.id}>
                <span className="ba-thread-icon"><Icon name="verified_user" size="sm" /></span>
                <div>
                  <strong>{words(a.action)}</strong>
                  <small>Asked {timeAgo(a.created_at)}{a.mine ? " by you" : ""} · expires {timeAgo(a.expires_at)}</small>
                </div>
                <div className="ba-thread-meta">
                  {a.mine ? <Pill tone="warning">Needs another person</Pill> : (
                    <>
                      <button type="button" className="ba-btn sm" disabled={busy === a.id} onClick={() => decide(a, false)}>Decline</button>
                      <button type="button" className="ba-btn primary sm" disabled={busy === a.id} onClick={() => decide(a, true)}>Approve</button>
                    </>
                  )}
                </div>
              </li>
            ))}
          </ul>
        )}
      </section>
    </>
  );
}

/* ---------- Team access ---------- */
function InviteModal({ workspace, onClose, onDone }) {
  const [form, setForm] = useState({ email: "", name: "", role: "staff" });
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState("");
  const set = (k) => (e) => setForm((f) => ({ ...f, [k]: e.target.value }));
  async function save() {
    setBusy(true); setProblem("");
    const email = form.email.trim().toLowerCase();
    const { data: invitationId, error: e } = await supabase.rpc("zella_invite_staff", { p_business_id: workspace.id, p_email: form.email, p_name: form.name, p_role: form.role });
    if (e) { setBusy(false); return setProblem(say(e)); }
    try {
      const result = await sendInvitationEmail(invitationId);
      setBusy(false);
      onDone(sentMessage(email, result));
    } catch (err) {
      setBusy(false);
      // The invitation is saved; it shows in the list with the error and a Send again button.
      onDone(`The invitation for ${email} is saved, but the email didn't go out: ${err.message}`);
    }
  }
  return (
    <Modal title="Invite someone" description="They get an email with a link to join this workspace." onClose={onClose} busy={busy}
      footer={<><button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button>
        <button type="button" className="ba-btn primary" onClick={save} disabled={busy || !form.email.trim()}>{busy ? "Sending…" : "Send invitation"}</button></>}>
      <div className="ba-form">
        {problem && <div className="ba-banner error" role="alert"><span>{problem}</span></div>}
        <Field label="Email"><input type="email" value={form.email} onChange={set("email")} autoFocus /></Field>
        <Field label="Name" hint="Optional."><input value={form.name} onChange={set("name")} /></Field>
        <Field label="Role" hint="Managers can run the day. Admins can also manage access. View only can look but not change.">
          <select value={form.role} onChange={set("role")}>
            {ROLES.filter(([k]) => k !== "admin" || workspace.role === "owner").map(([k, t]) => <option key={k} value={k}>{t}</option>)}
          </select>
        </Field>
      </div>
    </Modal>
  );
}

function RemoveModal({ workspace, member, others, onClose, onDone }) {
  const [to, setTo] = useState("");
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState("");
  async function save() {
    setBusy(true); setProblem("");
    const { error: e } = await supabase.rpc("zella_offboard_member", { p_business_id: workspace.id, p_user_id: member.user_id, p_reassign_to: to || null });
    setBusy(false);
    if (e) return setProblem(say(e));
    onDone(`${member.name || "That person"} no longer has access.${to ? " Their open work was handed over." : " Their open work is now unassigned."}`);
  }
  return (
    <Modal title={`Remove ${member.name || "this person"}?`} description="They can't sign in to this workspace any more. Their history stays." onClose={onClose} busy={busy}
      footer={<><button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Keep access</button>
        <button type="button" className="ba-btn primary" onClick={save} disabled={busy}>{busy ? "Removing…" : "Remove access"}</button></>}>
      <div className="ba-form">
        {problem && <div className="ba-banner error" role="alert"><span>{problem}</span></div>}
        <Field label="Hand their open work to" hint="Leads, callbacks and requests move to this person.">
          <select value={to} onChange={(e) => setTo(e.target.value)}>
            <option value="">Nobody (leave unassigned)</option>
            {others.map((o) => <option key={o.user_id} value={o.user_id}>{o.name || "Team member"}</option>)}
          </select>
        </Field>
      </div>
    </Modal>
  );
}

function HandoverModal({ workspace, people, me, onClose, onDone }) {
  const [form, setForm] = useState({ from: me, to: "", note: "" });
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState("");
  async function save() {
    setBusy(true); setProblem("");
    const { error: e } = await supabase.rpc("zella_create_handover", { p_business_id: workspace.id, p_to_user: form.to, p_note: form.note || null, p_from_user: form.from || null });
    setBusy(false);
    if (e) return setProblem(say(e));
    onDone("Handed over. They've been told.");
  }
  return (
    <Modal title="Hand over work" description="Move open leads, callbacks and requests to someone else, for example at the end of a shift." onClose={onClose} busy={busy}
      footer={<><button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button>
        <button type="button" className="ba-btn primary" onClick={save} disabled={busy || !form.to}>{busy ? "Handing over…" : "Hand over"}</button></>}>
      <div className="ba-form">
        {problem && <div className="ba-banner error" role="alert"><span>{problem}</span></div>}
        <Field label="From">
          <select value={form.from} onChange={(e) => setForm({ ...form, from: e.target.value })}>
            {people.map((p) => <option key={p.user_id} value={p.user_id}>{p.name || "Team member"}{p.user_id === me ? " (you)" : ""}</option>)}
          </select>
        </Field>
        <Field label="To">
          <select value={form.to} onChange={(e) => setForm({ ...form, to: e.target.value })}>
            <option value="">Choose a person</option>
            {people.filter((p) => p.user_id !== form.from).map((p) => <option key={p.user_id} value={p.user_id}>{p.name || "Team member"}</option>)}
          </select>
        </Field>
        <Field label="Note" hint="Optional. They'll see this." full><textarea rows={3} value={form.note} onChange={(e) => setForm({ ...form, note: e.target.value })} /></Field>
      </div>
    </Modal>
  );
}

export function AccessPage({ workspace, refreshKey, onNotice, userId }) {
  const [modal, setModal] = useState(null);
  const canAdmin = ["owner", "admin"].includes(workspace.role);
  const { data, error, loading, reload } = useLoad(async () => {
    const roster = orThrow(await supabase.rpc("zella_team_roster", { p_business_id: workspace.id }));
    let invites = [];
    if (canAdmin) {
      const r = await supabase.rpc("zella_list_invitations", { p_business_id: workspace.id });
      if (r.error) throw r.error;
      invites = r.data ?? [];
    }
    return { roster, invites };
  }, [workspace.id, refreshKey]);

  const done = (message) => { setModal(null); onNotice(message); reload(); };
  async function act(fn, args, message) {
    const { error: e } = await supabase.rpc(fn, args);
    if (e) return onNotice(say(e));
    onNotice(message); reload();
  }
  async function resend(invite) {
    const { error: e } = await supabase.rpc("zella_resend_invitation", { p_invitation_id: invite.id });
    if (e) return onNotice(say(e));
    try {
      onNotice(sentMessage(invite.email, await sendInvitationEmail(invite.id)));
    } catch (err) {
      onNotice(err.message);
    }
    reload();
  }
  const roster = data?.roster ?? [];

  return (
    <>
      <PageHead crumb="Management / Access" title="Team access" sub="Who can sign in, what they can do, and who is waiting to join.">
        <button type="button" className="ba-btn" onClick={() => setModal({ kind: "handover" })}><Icon name="swap_horiz" size="sm" /><span>Hand over work</span></button>
        {canAdmin && <button type="button" className="ba-btn primary" onClick={() => setModal({ kind: "invite" })}><Icon name="person_add" size="sm" /><span>Invite someone</span></button>}
      </PageHead>
      <Notice error={error} onRetry={reload} />

      <section className="ba-panel">
        <div className="ba-panel-head"><div className="ba-panel-title"><div><h2>People with access</h2><p>{loading && !data ? "Loading…" : plural(roster.length, "person", "people")}</p></div></div></div>
        <ul className="ba-threads">
          {roster.map((m) => (
            <li key={m.user_id}>
              <span className="ba-avatar sm">{initials(m.name || "Team member")}</span>
              <div><strong>{m.name || "Team member"}{m.user_id === userId ? " (you)" : ""}</strong></div>
              <div className="ba-thread-meta">
                <Pill tone="indigo">{m.role}</Pill>
                {canAdmin && m.user_id !== userId && m.role !== "owner" && (
                  <button type="button" className="ba-btn sm" onClick={() => setModal({ kind: "remove", member: m })}>Remove</button>
                )}
              </div>
            </li>
          ))}
        </ul>
      </section>

      {canAdmin && (
        <section className="ba-panel ba-gap">
          <div className="ba-panel-head"><div className="ba-panel-title"><div><h2>Waiting to join</h2><p>Invitations that haven't been accepted yet.</p></div></div></div>
          {!data?.invites.length ? (
            <div className="ba-panel-body"><Empty title="No open invitations">Invite someone to give them access.</Empty></div>
          ) : (
            <ul className="ba-threads">
              {data.invites.map((i) => (
                <li key={i.id}>
                  <span className="ba-thread-icon"><Icon name="mail" size="sm" /></span>
                  <div><strong>{i.email}</strong><small>{words(i.role)} · invited {timeAgo(i.invited_at)}{i.status === "expired" ? " · expired" : ""}{i.last_error ? ` · ${i.last_error}` : ""}</small></div>
                  <div className="ba-thread-meta">
                    <button type="button" className="ba-btn sm" onClick={() => resend(i)}>Send again</button>
                    <button type="button" className="ba-btn sm" onClick={() => act("zella_cancel_invitation", { p_invitation_id: i.id }, "Invitation cancelled.")}>Cancel</button>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </section>
      )}

      {modal?.kind === "invite" && <InviteModal workspace={workspace} onClose={() => setModal(null)} onDone={done} />}
      {modal?.kind === "remove" && <RemoveModal workspace={workspace} member={modal.member} others={roster.filter((r) => r.user_id !== modal.member.user_id)} onClose={() => setModal(null)} onDone={done} />}
      {modal?.kind === "handover" && <HandoverModal workspace={workspace} people={roster} me={userId} onClose={() => setModal(null)} onDone={done} />}
    </>
  );
}

/* ---------- Failed work ---------- */
const FAILED = [["tasks", "task", "Follow-up"], ["reminders", "reminder", "Appointment reminder"], ["social", "social", "Social message"]];

export function FailedWorkPage({ workspace, refreshKey, onNotice }) {
  const { data, error, loading, reload } = useLoad(async () => {
    const { data: d, error: e } = await supabase.rpc("zella_failed_work", { p_business_id: workspace.id });
    if (e) throw e;
    return d ?? {};
  }, [workspace.id, refreshKey]);
  const rows = FAILED.flatMap(([key, kind, label]) => (data?.[key] ?? []).map((r) => ({ ...r, kind, label })));

  async function retry(row) {
    const { error: e } = await supabase.rpc("zella_retry_failed", { p_business_id: workspace.id, p_kind: row.kind, p_id: row.id });
    if (e) return onNotice(say(e));
    onNotice("Queued to send again.");
    reload();
  }

  return (
    <>
      <PageHead crumb="Management / Health" title="Messages that didn't send" sub="Anything that failed in the last 7 days. Try again once the cause is fixed, such as a reconnected account." />
      <Notice error={error} onRetry={reload} />
      <section className="ba-panel">
        {!rows.length ? (
          <div className="ba-panel-body"><Empty title={loading ? "Loading…" : "Nothing has failed"}>Messages and reminders are going out as expected.</Empty></div>
        ) : (
          <ul className="ba-threads">
            {rows.map((r) => (
              <li key={`${r.kind}-${r.id}`}>
                <span className="ba-thread-icon"><Icon name="error" size="sm" /></span>
                <div><strong>{r.label}{r.channel ? ` by ${r.channel}` : ""}</strong><small>{words(r.outcome || r.error || r.kind)} · {timeAgo(r.at || r.due_at)}</small></div>
                <div className="ba-thread-meta"><button type="button" className="ba-btn sm" onClick={() => retry(r)}>Try again</button></div>
              </li>
            ))}
          </ul>
        )}
      </section>
    </>
  );
}

/* ---------- Security log ---------- */
export function SecurityLogPage({ workspace, refreshKey }) {
  const { data, error, loading, reload } = useLoad(async () => {
    const { data: d, error: e } = await supabase.rpc("zella_security_log", { p_business_id: workspace.id, p_limit: 100 });
    if (e) throw e;
    return d ?? [];
  }, [workspace.id, refreshKey]);
  return (
    <>
      <PageHead crumb="Management / Security" title="Security log" sub="Who changed what in this workspace. The last 100 changes." />
      <Notice error={error} onRetry={reload} />
      <section className="ba-panel">
        {!data?.length ? (
          <div className="ba-panel-body"><Empty title={loading ? "Loading…" : "Nothing recorded yet"}>Changes to access, plans and customer data will appear here.</Empty></div>
        ) : (
          <ul className="ba-threads">
            {data.map((a) => (
              <li key={a.id}>
                <span className="ba-thread-icon"><Icon name="history" size="sm" /></span>
                <div><strong>{words(a.action)}</strong><small>{a.who} · {timeAgo(a.at)}</small></div>
                <div className="ba-thread-meta">{a.entity_type && <Pill>{words(a.entity_type)}</Pill>}</div>
              </li>
            ))}
          </ul>
        )}
      </section>
    </>
  );
}
