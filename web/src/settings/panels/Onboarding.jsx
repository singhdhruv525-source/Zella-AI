import { useState } from "react";
import { createPortal } from "react-dom";
import { callOwnerFunction } from "../../CreateBusinessWizard";
import { Banner, Card, Confirm, LoadState, Needs, Pill, Table, useAsync, words } from "../SettingsKit";

// Settings > Business onboarding (Lane B): businesses still in setup, what each has in place, and for a Zella Voice
// owner or super admin, Delete draft for a business that never finished setup (BIZ-13a). The server and the database
// check the role, the typed name and that the business is still a draft again; the reason goes in the audit log.

const can = (me, permission) => Boolean(me?.permissions?.includes(permission));
const call = (action, payload) => callOwnerFunction(action, payload);
const CHECKS = [["profile", "Profile"], ["industry", "Industry"], ["receptionist", "AI receptionist"], ["phone", "Phone"], ["owner_invited", "Owner invited"], ["billing", "Billing"]];
// BIZ-13a default (owner can change): who may delete a never finished draft; the server has the same list
export const DRAFT_DELETE_ROLES = ["zella_owner", "super_admin"];
// what a business must not have to be deleted as a draft (the database refuses it otherwise)
const DELETABLE = (b) => !["testing", "ready", "active"].includes(b.onboarding_status) && !b.checks.phone && !b.checks.billing;

export default function Onboarding({ me, openSetup, openBusiness }) {
  const state = useAsync(() => call("onboarding_overview"), []);
  const [notice, setNotice] = useState({ text: "", error: "" });
  const [deleting, setDeleting] = useState(null);
  const mayDelete = DRAFT_DELETE_ROLES.includes(me?.role);
  async function resend(id) {
    try { await call("invitation_resend", { businessId: id }); setNotice({ text: "Invitation sent again.", error: "" }); state.reload(); }
    catch (err) { setNotice({ text: "", error: err.message }); }
  }
  async function remove(b, reason) {
    const r = await call("business_delete_draft", { businessId: b.id, confirmName: b.name, reason });
    setNotice({ text: `${b.name} was deleted.${r.filesLeft ? ` ${r.filesLeft} uploaded files are left for the orphan cleanup.` : ""}`, error: "" });
    state.reload();
  }
  return (
    <>
      <Banner tone="success">{notice.text}</Banner>
      <Banner tone="error">{notice.error}</Banner>
      <Card title="Businesses still in setup" sub="Each check reads the business's real records. A tick means it's in place.">
        <LoadState state={state}>{(d) => (
          <Table rows={d.rows} empty="Every business has finished setup." columns={[
            ["Business", (b) => <button type="button" className="zs-link" onClick={() => openBusiness(b.id)}>{b.name}</button>],
            ["Step", (b) => words(b.onboarding_status)],
            ...CHECKS.map(([key, label]) => [label, (b) => (b.checks[key] ? <Pill tone="success">✓</Pill> : <Pill tone="warning">Missing</Pill>)]),
            ["Failed steps", (b) => (b.failed_steps.length ? b.failed_steps.map((f) => `${words(f.step)}${f.error ? `: ${f.error}` : ""}`).join("; ") : "None")],
            ["", (b) => can(me, "businesses.manage") ? (
              <span className="zs-actions">
                <button type="button" className="zs-btn sm" onClick={() => openSetup(b.id)}>Continue setup</button>
                {!b.checks.owner_invited && <button type="button" className="zs-btn sm" onClick={() => resend(b.id)}>Send owner invite</button>}
                {mayDelete && DELETABLE(b) && <button type="button" className="zs-btn sm danger-outline" onClick={() => setDeleting(b)}>Delete draft</button>}
              </span>) : null],
          ]} />
        )}</LoadState>
      </Card>
      {deleting && createPortal(   // the settings pane is animated, so a fixed dialog inside it would scroll with it
        <Confirm title={`Delete ${deleting.name}?`} danger word={deleting.name} reason confirmLabel="Delete draft"
          onConfirm={(reason) => remove(deleting, reason)} onClose={() => setDeleting(null)}>
          <p>This deletes the draft and everything made for it: its settings, receptionist, modules, uploaded documents and any owner invitation not yet accepted. It can't be undone.</p>
          <p>Its audit history is kept. A business with calls, phone numbers, billing, an accepted owner or finished setup can't be deleted.</p>
        </Confirm>,
        document.body,
      )}
      <Needs title="Automatic retry of failed provisioning steps isn't built" have="Steps stuck for 30 minutes are marked failed every hour and shown above; Continue setup reruns the setup wizard, which only adds what's missing.">
        A safe automatic retry needs each provisioning step (agent, phone number, integrations) to be re-runnable on its own.
      </Needs>
    </>
  );
}
