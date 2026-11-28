import { useRef, useState } from "react";
import { Icon } from "../../BusinessUI";
import { createPortal } from "react-dom";
import { callOwnerFunction } from "../../CreateBusinessWizard";
import { Banner, Card, Confirm, LoadState, Needs, Pill, Table, useAsync, words } from "../SettingsKit";
import { DRAFT_DELETE_ROLES, retryAction, since } from "../../businessLifecycle";

// Settings > Business onboarding (Lane B): businesses still in setup, what each has in place, and for a Zella Voice
// owner or super admin, Delete draft for a business that never finished setup (BIZ-13a). The server and the database
// check the role, the typed name and that the business is still a draft again; the reason goes in the audit log.

const can = (me, permission) => Boolean(me?.permissions?.includes(permission));
const call = (action, payload) => callOwnerFunction(action, payload);
const CHECKS = [["profile", "Profile"], ["industry", "Industry"], ["receptionist", "AI receptionist"], ["phone", "Phone"], ["owner_invited", "Owner invited"], ["billing", "Billing"]];
// what a business must not have to be deleted as a draft (the database refuses it otherwise)
const DELETABLE = (b) => !["testing", "ready", "active"].includes(b.onboarding_status) && !b.checks.phone && !b.checks.billing;

export default function Onboarding({ me, openSetup, openBusiness }) {
  const state = useAsync(() => call("onboarding_overview"), []);
  const [notice, setNotice] = useState({ text: "", error: "" });
  const [deleting, setDeleting] = useState(null);
  const mayDelete = DRAFT_DELETE_ROLES.includes(me?.role);
  // one retry or resend at a time per business: a second click while the first is on its way does nothing
  const [working, setWorking] = useState({});   // business id -> "retry" | "resend"
  const inFlight = useRef(new Set());
  async function once(id, kind, fn) {
    if (inFlight.current.has(id)) return;
    inFlight.current.add(id); setWorking((w) => ({ ...w, [id]: kind }));
    try { await fn(); }
    finally { inFlight.current.delete(id); setWorking((w) => { const n = { ...w }; delete n[id]; return n; }); }
  }
  const retry = (b, step) => once(b.id, "retry", async () => {
    try {
      const r = await call("retry_step", { businessId: b.id, step });
      setNotice(r.status === "done" ? { text: `${words(step)} for ${b.name} is done${r.added ? ` (${r.added} added)` : ""}.`, error: "" } : { text: "", error: r.note || `${words(step)} still needs attention.` });
      state.reload();
    } catch (err) { setNotice({ text: "", error: err.message }); }
  });
  const resend = (id) => once(id, "resend", async () => {
    try { await call("invitation_resend", { businessId: id }); setNotice({ text: "Invitation sent again.", error: "" }); state.reload(); }
    catch (err) { setNotice({ text: "", error: err.message }); }
  });
  async function remove(b, reason) {
    const r = await call("business_delete_draft", { businessId: b.id, confirmName: b.name, reason });
    setNotice({ text: `${b.name} was deleted.${r.filesLeft ? ` ${r.filesLeft} uploaded files are left for the orphan cleanup.` : ""}`, error: "" });
    state.reload();
  }
  return (
    <>
      <Banner tone="success">{notice.text}</Banner>
      <Banner tone="error">{notice.error}</Banner>
      <Card title="Businesses still in setup" sub={`Each check reads the business's real records. A tick means it's in place. A draft with no changes for ${state.data?.abandon_days ?? 30} days shows as Abandoned and raises one alert; nothing is deleted automatically.`}>
        <LoadState state={state}>{(d) => (
          <Table rows={d.rows} empty="Every business has finished setup." columns={[
            ["Business", (b) => <button type="button" className="zs-link" onClick={() => openBusiness(b.id)}>{b.name}</button>],
            ["Step", (b) => words(b.onboarding_status)],
            ["Last change", (b) => <>{since(b.last_activity_at)}{b.abandoned && <> <Pill tone="danger">Abandoned</Pill></>}</>],
            ...CHECKS.map(([key, label]) => [label, (b) => (b.checks[key] ? <Pill tone="success"><Icon name="check" size="sm" /><span className="zs-sr-only">Done</span></Pill> : <Pill tone="warning">Missing</Pill>)]),
            ["Failed steps", (b) => (b.failed_steps.length ? b.failed_steps.map((f) => {
              const act = retryAction(f.step);
              return (
                <div key={f.step}>
                  {words(f.step)}{f.error ? `: ${f.error}` : ""}
                  {can(me, "businesses.manage") && act === "retry" && <> <button type="button" className="zs-btn sm" disabled={Boolean(working[b.id])} onClick={() => retry(b, f.step)}>{working[b.id] === "retry" ? "Retrying…" : "Retry step"}</button></>}
                  {can(me, "businesses.manage") && act === "resend" && <> <button type="button" className="zs-btn sm" disabled={Boolean(working[b.id])} onClick={() => resend(b.id)}>{working[b.id] === "resend" ? "Sending…" : "Send owner invite"}</button></>}
                </div>
              );
            }) : "None")],
            ["", (b) => can(me, "businesses.manage") ? (
              <span className="zs-actions">
                <button type="button" className="zs-btn sm" onClick={() => openSetup(b.id)}>Continue setup</button>
                {!b.checks.owner_invited && <button type="button" className="zs-btn sm" disabled={Boolean(working[b.id])} onClick={() => resend(b.id)}>{working[b.id] === "resend" ? "Sending…" : "Send owner invite"}</button>}
                {mayDelete && DELETABLE(b) && <button type="button" className="zs-btn sm danger-outline" onClick={() => setDeleting(b)}>Delete draft</button>}
              </span>) : null],
          ]} />
        )}</LoadState>
      </Card>
      {deleting && createPortal(   // the settings pane is animated, so a fixed dialog inside it would scroll with it
        <Confirm title={`Delete ${deleting.name}?`} danger word={deleting.name} reason confirmLabel="Delete draft"
          onConfirm={(reason) => remove(deleting, reason)} onClose={() => setDeleting(null)}>
          <p>This deletes the draft and everything made for it: its settings, AI receptionist, modules, uploaded documents and any owner invitation not yet accepted. It can't be undone.</p>
          <p>Its audit history is kept. A business with calls, phone numbers, billing, an accepted owner or finished setup can't be deleted.</p>
        </Confirm>,
        document.body,
      )}
      <Needs title="Automatic retry runs only once the owner switches it on" have="Every setup step is recorded. Modules, the AI receptionist and automations can be retried here with Retry step; the owner invitation email with Send owner invite; anything else with Continue setup.">
        The timed retry retries those three internal steps at most 3 times each, and is off until the owner turns it on. Steps that reach a provider or send an email are never retried on their own.
      </Needs>
    </>
  );
}
