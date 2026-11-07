// Release 3: approvals, milestones and renewals, inspections, exceptions and package credits on a record, the
// follow-through page, and each record type's workflow setting. The server (sql/zella_record_workflows.sql) checks
// every rule; these screens only collect and explain.
import { useEffect, useState } from "react";
import { supabase } from "./supabase";
import { Field, Modal, Pill } from "./BusinessUI";
import { formatDay, timeAgo } from "./businessTime";
import { Empty, Notice, PageHead, useLoad } from "./BusinessShared";
import { showMoney, toMinor } from "./BusinessMoney";
import {
  APPROVAL_KINDS, APPROVAL_LABEL, APPROVAL_METHODS, APPROVAL_STATUS, EXCEPTION_LABEL, INSPECTION_RESULTS, MANUAL_EXCEPTION_KINDS, METHOD_LABEL,
  MILESTONE_KINDS, MILESTONE_LABEL, creditBalance, dueText, inspectionProgress, nextYear, reconcileWorkflowForm, workflowError, workflowForm, workflowParts,
} from "./workflowLogic";

const todayIn = (tz) => new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
const day = (d) => (d ? formatDay(`${d}T12:00:00Z`, "UTC") : "");
const rows = (res) => (res.error ? Promise.reject(res.error) : res.data ?? []);

function useAction(onDone) {
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState("");
  async function run(work, done) {
    if (busy) return false;
    setBusy(true); setProblem("");
    let res;
    try { res = await work(); } catch (err) { res = { error: err }; } finally { setBusy(false); }
    if (res?.error) { setProblem(workflowError(res.error)); onDone?.(); return false; }
    onDone?.(done);
    return true;
  }
  return { busy, problem, setProblem, run };
}

/* ------------------------------------------------------------------ */
/* On a record                                                         */
/* ------------------------------------------------------------------ */

export function RecordWorkflow({ workspace, type, record, onNotice }) {
  const tz = workspace.timezone;
  const today = todayIn(tz);
  const parts = workflowParts(type);
  const canWork = ["owner", "admin", "manager", "staff"].includes(workspace.role);
  const canManage = ["owner", "admin", "manager"].includes(workspace.role);
  const [version, setVersion] = useState(0);
  const reload = () => setVersion((v) => v + 1);
  // done is a message, or { text, moved } when the action may have changed the record's status: the record panel then
  // closes and reloads, so its form can't save the old status over the new one
  const act = useAction((done) => { reload(); if (done) onNotice?.(typeof done === "string" ? done : done.text, typeof done === "object" && done.moved); });
  const data = useLoad(async () => {
    const id = record.id;
    const [approvals, milestones, inspections, exceptions, credits] = await Promise.all([
      canWork && parts.approvals.length ? supabase.from("record_approvals").select("*").eq("record_id", id).order("requested_at", { ascending: false }).then(rows) : [],
      supabase.from("record_milestones").select("*").eq("record_id", id).order("due_on").then(rows),
      parts.inspection ? supabase.from("record_inspections").select("*").eq("record_id", id).order("started_at", { ascending: false }).then(rows) : [],
      supabase.from("record_exceptions").select("*").eq("record_id", id).order("opened_at", { ascending: false }).then(rows),
      parts.credits ? supabase.from("record_credits").select("*").eq("record_id", id).order("created_at").then(rows) : [],
    ]);
    return { approvals, milestones, inspections, exceptions, credits };
  }, [record.id, version]);
  const [modal, setModal] = useState(null);

  // a failed refresh keeps what was shown; a failed first load says so (useLoad words it plainly)
  if (data.error && !data.data) return <Notice error={`Approvals, dates and checklists: ${data.error}`} onRetry={data.reload} />;
  if (!data.data) return <p className="ba-muted">Loading…</p>;
  const d = data.data;
  const open = (d.milestones ?? []).filter((m) => !m.done_at);
  const done = (d.milestones ?? []).filter((m) => m.done_at);
  const openExceptions = d.exceptions.filter((e) => !e.resolved_at);
  const balance = creditBalance(d.credits);
  const unit = parts.credits?.unit ?? "credits";

  return (
    <div className="ba-workflow" data-workflow="ready">
      {act.problem && <p className="ba-error" role="alert">{act.problem}</p>}

      {canWork && parts.approvals.length > 0 && (
        <section aria-label="Approvals">
          <h3 className="ba-h3">Approvals</h3>
          {d.approvals.length === 0 ? <p className="ba-muted">No approvals asked for yet.</p> : (
            <ul className="ba-history" data-list="approvals">
              {d.approvals.map((a) => {
                const [label, tone] = APPROVAL_STATUS[a.status] ?? [a.status, ""];
                const expired = a.status === "requested" && a.expires_on && a.expires_on < today;
                return (
                  <li key={a.id} data-approval={a.title}>
                    <strong>{a.title}</strong> · {APPROVAL_LABEL[a.kind] ?? a.kind}{a.amount_minor ? ` · ${showMoney(a.amount_minor, a.currency)}` : ""}
                    {" "}<Pill tone={expired ? "danger" : tone}>{expired ? "Expired" : label}</Pill>
                    <small>
                      {a.status === "requested" ? `asked ${timeAgo(a.requested_at)}${a.expires_on ? ` · answer by ${day(a.expires_on)}` : ""}` : a.decided_at
                        ? `${METHOD_LABEL[a.method] ?? a.method} · ${timeAgo(a.decided_at)}` : `updated ${timeAgo(a.updated_at)}`}
                    </small>
                    {a.status === "requested" && (
                      <span className="ba-row-actions">
                        {!expired && (a.kind !== "refund" || canManage) && <button type="button" className="ba-btn sm" disabled={act.busy} onClick={() => setModal({ decide: a })}>Record the answer</button>}
                        {(a.kind !== "refund" || canManage) && <button type="button" className="ba-btn sm ghost" disabled={act.busy}
                          onClick={() => act.run(() => supabase.rpc("zella_approval_withdraw", { p_id: a.id }), "Approval request withdrawn.")}>Withdraw</button>}
                      </span>
                    )}
                  </li>
                );
              })}
            </ul>
          )}
          <button type="button" className="ba-btn sm" disabled={act.busy} onClick={() => setModal({ ask: true })}>Ask for approval</button>
        </section>
      )}

      <section aria-label="Milestones and deadlines">
        <h3 className="ba-h3">Milestones, deadlines and renewals</h3>
        {open.length === 0 && done.length === 0 && <p className="ba-muted">Nothing scheduled.</p>}
        {open.length > 0 && (
          <ul className="ba-history" data-list="milestones">
            {open.map((m) => (
              <li key={m.id} data-milestone={m.title}>
                <strong>{m.title}</strong> · {MILESTONE_LABEL[m.kind] ?? m.kind} · {day(m.due_on)}
                {" "}<Pill tone={m.due_on < today ? "danger" : m.due_on === today ? "warning" : ""}>{dueText(m.due_on, today)}</Pill>
                {canWork && (
                  <span className="ba-row-actions">
                    <button type="button" className="ba-btn sm" disabled={act.busy}
                      onClick={() => (m.kind === "renewal" ? setModal({ renew: m }) : act.run(() => supabase.rpc("zella_milestone_done", { p_id: m.id, p_done: true }), `${m.title}: done.`))}>Done</button>
                    <button type="button" className="ba-btn sm ghost" disabled={act.busy} onClick={() => setModal({ milestone: m })}>Change</button>
                  </span>
                )}
              </li>
            ))}
          </ul>
        )}
        {done.length > 0 && <p className="ba-muted">Done: {done.slice(-3).map((m) => m.title).join(", ")}{done.length > 3 ? ` and ${done.length - 3} more` : ""}.</p>}
        {canWork && <button type="button" className="ba-btn sm" disabled={act.busy} onClick={() => setModal({ milestone: {} })}>Add a date</button>}
      </section>

      {parts.inspection && (
        <section aria-label="Inspections">
          <h3 className="ba-h3">{parts.inspection.title}</h3>
          {d.inspections.length === 0 ? <p className="ba-muted">None yet.</p> : (
            <ul className="ba-history" data-list="inspections">
              {d.inspections.map((x) => (
                <li key={x.id} data-inspection={x.outcome}>
                  <strong>{x.title}</strong> · {inspectionProgress(x.items).text}
                  {" "}<Pill tone={x.outcome === "passed" ? "success" : x.outcome === "failed" ? "danger" : "warning"}>{{ passed: "Passed", failed: "Failed", in_progress: "In progress" }[x.outcome]}</Pill>
                  <small>{x.finished_at ? `finished ${timeAgo(x.finished_at)}` : `started ${timeAgo(x.started_at)}`}</small>
                  {canWork && x.outcome === "in_progress" && <span className="ba-row-actions"><button type="button" className="ba-btn sm" onClick={() => setModal({ inspect: x })}>Continue</button></span>}
                </li>
              ))}
            </ul>
          )}
          {canWork && <button type="button" className="ba-btn sm" onClick={() => setModal({ inspect: { title: parts.inspection.title, items: parts.inspection.items.map((label) => ({ label })) } })}>Start {parts.inspection.title.toLowerCase()}</button>}
        </section>
      )}

      <section aria-label="Exceptions">
        <h3 className="ba-h3">Problems and holdups</h3>
        {openExceptions.length === 0 ? <p className="ba-muted">Nothing holding this up.</p> : (
          <ul className="ba-history" data-list="exceptions">
            {openExceptions.map((e) => (
              <li key={e.id} data-exception={e.kind}>
                <strong>{EXCEPTION_LABEL[e.kind] ?? e.kind}</strong>{e.detail ? ` · ${e.detail}` : ""}
                {e.expected_by && <> {" "}<Pill tone={e.expected_by < today ? "danger" : "warning"}>{e.expected_by < today ? `expected ${day(e.expected_by)}: late` : `expected ${day(e.expected_by)}`}</Pill></>}
                <small>opened {timeAgo(e.opened_at)}</small>
                {canWork && <span className="ba-row-actions"><button type="button" className="ba-btn sm" disabled={act.busy} onClick={() => setModal({ resolve: e })}>Resolved</button></span>}
              </li>
            ))}
          </ul>
        )}
        {canWork && <button type="button" className="ba-btn sm" disabled={act.busy} onClick={() => setModal({ flag: true })}>Flag a problem</button>}
      </section>

      {parts.credits && (
        <section aria-label="Credits">
          <h3 className="ba-h3">Credits</h3>
          <p data-balance={balance}><strong>{balance} {unit} left</strong>{d.credits.length > 0 && <span className="ba-muted"> · {d.credits.length} entries</span>}</p>
          {canWork && (
            <div className="ba-row-actions">
              <button type="button" className="ba-btn sm" disabled={act.busy || balance < 1} onClick={() => setModal({ credit: "use" })}>Use</button>
              <button type="button" className="ba-btn sm ghost" disabled={act.busy} onClick={() => setModal({ credit: "refund" })}>Give back</button>
              {canManage && <button type="button" className="ba-btn sm ghost" disabled={act.busy} onClick={() => setModal({ credit: "grant" })}>Add {unit}</button>}
              {canManage && balance > 0 && <button type="button" className="ba-btn sm ghost" disabled={act.busy} onClick={() => setModal({ credit: "expire" })}>Expire</button>}
            </div>
          )}
        </section>
      )}

      {modal?.ask && <AskApproval workspace={workspace} kinds={parts.approvals} canManage={canManage} record={record} onClose={() => setModal(null)} act={act} />}
      {modal?.decide && <DecideApproval approval={modal.decide} record={record} onClose={() => setModal(null)} act={act} />}
      {modal?.milestone && <MilestoneModal record={record} milestone={modal.milestone} workspace={workspace} onClose={() => setModal(null)} act={act} today={today} />}
      {modal?.renew && <RenewModal milestone={modal.renew} onClose={() => setModal(null)} act={act} />}
      {modal?.inspect && <InspectionModal record={record} inspection={modal.inspect} onClose={() => setModal(null)} act={act} />}
      {modal?.flag && <FlagModal record={record} onClose={() => setModal(null)} act={act} today={today} />}
      {modal?.resolve && <ResolveModal exception={modal.resolve} onClose={() => setModal(null)} act={act} />}
      {modal?.credit && <CreditModal record={record} kind={modal.credit} unit={unit} balance={balance} onClose={() => setModal(null)} act={act} />}
    </div>
  );
}

function ActionModal({ title, description, act, onClose, onSubmit, submit, children, wide }) {
  return (
    <Modal title={title} description={description} onClose={onClose} busy={act.busy} wide={wide}
      footer={<><button type="button" className="ba-btn" onClick={onClose} disabled={act.busy}>Cancel</button>
        <button type="submit" form="ba-wf-form" className="ba-btn primary" disabled={act.busy}>{act.busy ? "Saving…" : submit}</button></>}>
      <form id="ba-wf-form" className="ba-modal-body" onSubmit={async (e) => { e.preventDefault(); if (await onSubmit()) onClose(); }}>
        {act.problem && <p className="ba-error" role="alert">{act.problem}</p>}
        {children}
      </form>
    </Modal>
  );
}

function AskApproval({ workspace, kinds, canManage, record, onClose, act }) {
  const allowed = kinds.filter((k) => k !== "refund" || canManage);
  const [f, setF] = useState({ kind: allowed[0] ?? "other", title: "", amount: "", expires: "" });
  const currency = useLoad(async () => {
    const r = await supabase.rpc("zella_business_currency", { p_business_id: workspace.id });
    if (r.error) throw r.error;
    if (!r.data) throw new Error("No currency is set for this business.");
    return r.data;
  }, [workspace.id]);
  // never guessed: an amount is only taken once the business's currency is known
  const cur = currency.data;
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value });
  return (
    <ActionModal title="Ask for approval" description={`For ${record.title}. Nothing is sent to anyone: this records what you're waiting for.`} act={act} onClose={onClose} submit="Save"
      onSubmit={() => {
        if (f.amount.trim() && !cur) { act.setProblem("The business currency couldn't be loaded. Try again, or leave the amount empty."); return false; }
        const minor = f.amount.trim() ? toMinor(f.amount, cur) : null;
        if (f.amount.trim() && !minor) { act.setProblem("Enter the amount like 120.50, or leave it empty."); return false; }
        return act.run(() => supabase.rpc("zella_approval_request", { p_record_id: record.id, p_kind: f.kind, p_title: f.title, p_amount_minor: minor, p_currency: minor ? cur : null,
          p_expires_on: f.expires || null }), { text: "Approval request saved.", moved: ["estimate", "contract", "engagement", "treatment_plan", "endorsement"].includes(f.kind) });
      }}>
      <div className="ba-form-grid">
        <Field label="What for">
          <select value={f.kind} onChange={set("kind")}>{APPROVAL_KINDS.filter(([k]) => allowed.includes(k)).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select>
        </Field>
        <Field label="Title"><input value={f.title} onChange={set("title")} required minLength={2} maxLength={120} placeholder="Front brakes and discs" /></Field>
        <Field label={`Amount (${cur ?? (currency.error ? "unavailable" : "loading…")}, optional)`}><input inputMode="decimal" value={f.amount} onChange={set("amount")} disabled={!cur} /></Field>
        <Field label="Answer needed by (optional)"><input type="date" value={f.expires} onChange={set("expires")} /></Field>
      </div>
    </ActionModal>
  );
}

function DecideApproval({ approval, record, onClose, act }) {
  const internal = approval.kind === "refund";
  const [f, setF] = useState({ decision: "approved", who: "", method: internal ? "internal" : "phone", note: "" });
  const people = useLoad(async () => (internal ? [] : (await supabase.rpc("zella_approval_approvers", { p_record_id: record.id }).then(rows))), [record.id]);
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value });
  const list = people.data ?? [];
  return (
    <ActionModal title={`Answer: ${approval.title}`} description={internal ? "A refund is the business's own decision." : "Record what the customer, or someone they authorized, decided."}
      act={act} onClose={onClose} submit="Save the answer"
      onSubmit={() => act.run(() => supabase.rpc("zella_approval_decide", { p_id: approval.id, p_decision: f.decision, p_method: f.method,
        p_approver_customer_id: internal ? null : f.who || null, p_note: f.note || null }), { text: f.decision === "approved" ? "Approved." : "Declined.", moved: true })}>
      <div className="ba-form-grid">
        <Field label="Answer">
          <select value={f.decision} onChange={set("decision")}><option value="approved">Approved</option><option value="declined">Declined</option></select>
        </Field>
        {!internal && (
          <>
            <Field label="Who answered">
              <select value={f.who} onChange={set("who")} required>
                <option value="">{people.loading ? "Loading…" : people.error ? "Couldn't load who can approve" : list.length ? "Choose…" : "Nobody on file can approve"}</option>
                {list.map((p) => <option key={p.customer_id} value={p.customer_id}>{p.name ?? "Unnamed"}{p.via !== "self" ? ` (${p.via.replace(/_/g, " ")})` : ""}</option>)}
              </select>
            </Field>
            <Field label="How">
              <select value={f.method} onChange={set("method")}>{APPROVAL_METHODS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select>
            </Field>
          </>
        )}
        <Field label="Note (optional)" full><input value={f.note} onChange={set("note")} maxLength={500} /></Field>
      </div>
      {!internal && people.error && <p className="ba-error" role="alert">Couldn't load who can approve: {people.error} <button type="button" className="ba-btn sm" onClick={people.reload}>Try again</button></p>}
      {!internal && !people.loading && !people.error && list.length === 0 && <p className="ba-muted">Link this record to its customer, or add someone under People &amp; consent with the "approve" permission, verified.</p>}
    </ActionModal>
  );
}

function MilestoneModal({ record, milestone, workspace, onClose, act, today }) {
  const isNew = !milestone.id;
  const [f, setF] = useState({ title: milestone.title ?? "", kind: milestone.kind ?? "milestone", due: milestone.due_on ?? today, staff: milestone.staff_id ?? "" });
  const staff = useLoad(async () => supabase.from("staff_members").select("id, name").eq("business_id", workspace.id).eq("is_active", true).order("name").then(rows), [workspace.id]);
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value });
  return (
    <ActionModal title={isNew ? "Add a date" : `Change ${milestone.title}`} act={act} onClose={onClose} submit="Save"
      onSubmit={() => act.run(() => supabase.rpc("zella_milestone_save", { p_record_id: record.id, p_id: milestone.id ?? null, p_title: f.title, p_due_on: f.due || null,
        p_kind: f.kind, p_staff_id: f.staff || null }), isNew ? "Date added." : "Date changed.")}>
      <div className="ba-form-grid">
        <Field label="What"><input value={f.title} onChange={set("title")} required minLength={2} maxLength={120} placeholder="Registration renewal" /></Field>
        <Field label="Kind"><select value={f.kind} onChange={set("kind")}>{MILESTONE_KINDS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></Field>
        <Field label="Due"><input type="date" value={f.due} onChange={set("due")} required /></Field>
        <Field label="Who's on it (optional)">
          <select value={f.staff} onChange={set("staff")} disabled={Boolean(staff.error)}>
            <option value="">{staff.loading ? "Loading…" : staff.error ? "Couldn't load the team" : "Nobody"}</option>
            {(staff.data ?? []).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
          </select>
        </Field>
      </div>
    </ActionModal>
  );
}

function RenewModal({ milestone, onClose, act }) {
  const [next, setNext] = useState(nextYear(milestone.due_on));
  const [roll, setRoll] = useState(true);
  return (
    <ActionModal title={`${milestone.title}: done`} description="Renewals usually come round again." act={act} onClose={onClose} submit="Mark done"
      onSubmit={() => act.run(() => supabase.rpc("zella_milestone_done", { p_id: milestone.id, p_done: true, p_next_due_on: roll ? next : null }), roll ? `Done. Next one due ${day(next)}.` : "Done.")}>
      <label className="ba-check"><input type="checkbox" checked={roll} onChange={(e) => setRoll(e.target.checked)} /> Add the next one</label>
      {roll && <Field label="Next one due"><input type="date" value={next} onChange={(e) => setNext(e.target.value)} required /></Field>}
    </ActionModal>
  );
}

function InspectionModal({ record, inspection, onClose, act }) {
  const [items, setItems] = useState(inspection.items.map((i) => ({ label: i.label, result: i.result ?? "", note: i.note ?? "" })));
  const progress = inspectionProgress(items.map((i) => ({ ...i, result: i.result || null })));
  const payload = () => items.map((i) => ({ label: i.label, result: i.result || null, note: i.note || null }));
  const save = (finish) => act.run(() => supabase.rpc("zella_inspection_save", { p_record_id: record.id, p_id: inspection.id ?? null, p_title: inspection.title, p_items: payload(),
    p_finish: finish, p_expected_updated_at: inspection.updated_at ?? null }), finish ? (progress.failed ? "Finished: failed. A problem has been flagged on this record." : "Finished: passed.") : "Saved. You can finish it later.");
  return (
    <Modal wide title={inspection.title} description={progress.text} onClose={onClose} busy={act.busy}
      footer={<><button type="button" className="ba-btn" onClick={onClose} disabled={act.busy}>Cancel</button>
        <button type="button" className="ba-btn" disabled={act.busy} onClick={async () => (await save(false)) && onClose()}>Save for later</button>
        <button type="button" className="ba-btn primary" disabled={act.busy || !progress.complete} onClick={async () => (await save(true)) && onClose()}>Finish</button></>}>
      <div className="ba-modal-body">
        {act.problem && <p className="ba-error" role="alert">{act.problem}</p>}
        <ul className="ba-check-list">
          {items.map((it, n) => (
            <li key={it.label} data-item={it.label}>
              <span className="ba-check">{it.label}</span>
              <span role="radiogroup" aria-label={it.label}>
                {INSPECTION_RESULTS.map(([k, l]) => (
                  <label key={k} className="ba-check"><input type="radio" name={`insp-${n}`} checked={it.result === k} onChange={() => setItems(items.map((x, j) => (j === n ? { ...x, result: k } : x)))} /> {l}</label>
                ))}
              </span>
              {it.result === "fail" && <input value={it.note} maxLength={300} placeholder="What's wrong" aria-label={`${it.label} note`} onChange={(e) => setItems(items.map((x, j) => (j === n ? { ...x, note: e.target.value } : x)))} />}
            </li>
          ))}
        </ul>
        {!progress.complete && <p className="ba-muted">Answer every item to finish.</p>}
      </div>
    </Modal>
  );
}

function FlagModal({ record, onClose, act, today }) {
  const [f, setF] = useState({ kind: "waiting_parts", detail: "", expected: "" });
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value });
  return (
    <ActionModal title="Flag a problem" description={`On ${record.title}. It shows on the follow-through page until it's resolved.`} act={act} onClose={onClose} submit="Flag it"
      onSubmit={() => act.run(() => supabase.rpc("zella_exception_open", { p_record_id: record.id, p_kind: f.kind, p_detail: f.detail || null, p_expected_by: f.expected || null }), "Problem flagged.")}>
      <div className="ba-form-grid">
        <Field label="What's wrong"><select value={f.kind} onChange={set("kind")}>{MANUAL_EXCEPTION_KINDS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></Field>
        <Field label="Expected sorted by (optional)"><input type="date" min={today} value={f.expected} onChange={set("expected")} /></Field>
        <Field label="Details (optional)" full><input value={f.detail} onChange={set("detail")} maxLength={300} placeholder="Discs on back order" /></Field>
      </div>
    </ActionModal>
  );
}

function ResolveModal({ exception, onClose, act }) {
  const [text, setText] = useState("");
  return (
    <ActionModal title={`Resolved: ${EXCEPTION_LABEL[exception.kind] ?? exception.kind}`} act={act} onClose={onClose} submit="Mark resolved"
      onSubmit={() => act.run(() => supabase.rpc("zella_exception_resolve", { p_id: exception.id, p_resolution: text || null }), "Marked resolved.")}>
      <Field label="How it was sorted (optional)" full><input value={text} onChange={(e) => setText(e.target.value)} maxLength={300} placeholder="Discs arrived" /></Field>
    </ActionModal>
  );
}

function CreditModal({ record, kind, unit, balance, onClose, act }) {
  const [units, setUnits] = useState("1");
  const [note, setNote] = useState("");
  const words = { use: `Use ${unit}`, refund: `Give ${unit} back`, grant: `Add ${unit}`, expire: `Expire ${unit}` };
  return (
    <ActionModal title={words[kind]} description={`${balance} ${unit} left now.`} act={act} onClose={onClose} submit="Save"
      onSubmit={() => act.run(() => supabase.rpc("zella_credit_add", { p_record_id: record.id, p_kind: kind, p_units: Number(units), p_note: note || null, p_expected_balance: balance }), { text: "Saved.", moved: ["use", "expire"].includes(kind) })}>
      <div className="ba-form-grid">
        <Field label="How many"><input type="number" min={1} max={1000} step={1} value={units} onChange={(e) => setUnits(e.target.value)} required /></Field>
        <Field label="Note (optional)"><input value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} /></Field>
      </div>
    </ActionModal>
  );
}

/* ------------------------------------------------------------------ */
/* The follow-through page                                             */
/* ------------------------------------------------------------------ */

export function FollowThroughPage({ workspace, types, refreshKey }) {
  const tz = workspace.timezone;
  const today = todayIn(tz);
  const [days, setDays] = useState(14);
  const due = useLoad(async () => {
    const r = await supabase.rpc("zella_workflow_due", { p_business_id: workspace.id, p_days: days });
    if (r.error) throw r.error;
    return r.data;
  }, [workspace.id, days, refreshKey]);
  const typeName = (key) => types?.find((t) => t.key === key)?.singular ?? "Record";
  const d = due.data;
  return (
    <div className="ba-page" data-follow="ready">
      <PageHead title="Follow-through" sub="Approvals you're waiting on, dates coming up, and problems holding work up, across every kind of record." />
      <label className="ba-check">Dates in the next{" "}
        <select value={days} onChange={(e) => setDays(Number(e.target.value))} aria-label="How many days ahead">{[7, 14, 30, 60, 90].map((n) => <option key={n} value={n}>{n} days</option>)}</select>
      </label>
      {due.error ? (
        <Notice error={due.error} onRetry={due.reload} />
      ) : !d ? <p className="ba-muted">Loading…</p> : (
        <div className="ba-follow-grid">
          {d.approvals !== null && (
            <section className="ba-panel" aria-label="Waiting for approval">
              <h2 className="ba-h3">Waiting for approval ({d.approvals.length})</h2>
              {d.approvals.length === 0 ? <Empty icon="task_alt" title="Nothing waiting" /> : (
                <ul className="ba-history">{d.approvals.map((a) => (
                  <li key={a.id}><strong>{a.title}</strong> · {typeName(a.type_key)}: {a.record}{a.amount_minor ? ` · ${showMoney(a.amount_minor, a.currency)}` : ""}
                    {a.expired ? <> <Pill tone="danger">Expired</Pill></> : a.expires_on ? <> <Pill tone="warning">answer by {day(a.expires_on)}</Pill></> : null}
                    <small>{APPROVAL_LABEL[a.kind] ?? a.kind} · asked {timeAgo(a.requested_at)}</small></li>))}
                </ul>
              )}
            </section>
          )}
          <section className="ba-panel" aria-label="Dates coming up">
            <h2 className="ba-h3">Dates coming up ({d.milestones.length})</h2>
            {d.milestones.length === 0 ? <Empty icon="event_available" title={`Nothing due in the next ${d.days} days`} /> : (
              <ul className="ba-history">{d.milestones.map((m) => (
                <li key={m.id}><strong>{m.title}</strong> · {typeName(m.type_key)}: {m.record} <Pill tone={m.overdue ? "danger" : m.due_on === today ? "warning" : ""}>{dueText(m.due_on, today)}</Pill>
                  <small>{MILESTONE_LABEL[m.kind] ?? m.kind}{m.staff ? ` · ${m.staff}` : ""}</small></li>))}
              </ul>
            )}
          </section>
          <section className="ba-panel" aria-label="Problems holding work up">
            <h2 className="ba-h3">Problems holding work up ({d.exceptions.length})</h2>
            {d.exceptions.length === 0 ? <Empty icon="check_circle" title="Nothing flagged" /> : (
              <ul className="ba-history">{d.exceptions.map((e) => (
                <li key={e.id}><strong>{EXCEPTION_LABEL[e.kind] ?? e.kind}</strong> · {typeName(e.type_key)}: {e.record}{e.detail ? ` · ${e.detail}` : ""}
                  {e.expected_by && <> <Pill tone={e.late ? "danger" : "warning"}>{e.late ? "late" : `expected ${day(e.expected_by)}`}</Pill></>}
                  <small>opened {timeAgo(e.opened_at)}</small></li>))}
              </ul>
            )}
          </section>
          {!d.can_work && <p className="ba-muted">You can see this list but not change it: open a record to see the details.</p>}
        </div>
      )}
    </div>
  );
}

/* ------------------------------------------------------------------ */
/* A record type's workflow setting (in the record-type editor)        */
/* ------------------------------------------------------------------ */

export function WorkflowSettings({ workspace, type, onSaved }) {
  const w = type.workflow ?? {};
  const [form, setForm] = useState(() => workflowForm(w));
  const [base, setBase] = useState(w); // the saved setting the form last synced with
  const [synced, setSynced] = useState(() => workflowForm(w)); // the form as it was at that moment
  const { kinds, inspect, title, items, credits, unit } = form;
  const set = (k) => (v) => setForm((f) => ({ ...f, [k]: v }));
  const [setKinds, setInspect, setTitle, setItems, setCredits, setUnit] = ["kinds", "inspect", "title", "items", "credits", "unit"].map(set);
  // When the saved setting changes under an open editor (a reload after a save, perhaps one made from an editor closed
  // meanwhile), show it, unless there are unsaved changes here: those are kept.
  const wKey = JSON.stringify(w);
  useEffect(() => {
    if (wKey === JSON.stringify(base)) return;
    const after = workflowForm(w);
    setForm((f) => reconcileWorkflowForm(f, synced, after));
    setSynced(after);
    setBase(w);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [wKey]);
  const act = useAction((done) => { if (done) onSaved?.(done); });
  const toggle = (k) => setKinds(kinds.includes(k) ? kinds.filter((x) => x !== k) : [...kinds, k]);
  async function save() {
    const list = items.split("\n").map((t) => t.trim()).filter(Boolean);
    if (inspect && !list.length) { act.setProblem("Add at least one checklist item, one per line."); return; }
    const keep = Object.fromEntries(["requested_status", "approved_status", "declined_status"].filter((k) => w[k] && kinds.length).map((k) => [k, w[k]]));
    const sent = form;
    await act.run(async () => {
      const res = await supabase.rpc("zella_record_workflow_save", { p_business_id: workspace.id, p_type_key: type.key, p_workflow: {
        approvals: kinds, ...keep, inspection: inspect ? { title, items: list } : null,
        credits: credits ? { unit, ...(w.credits?.used_up_status ? { used_up_status: w.credits.used_up_status } : {}) } : null } });
      // the server's tidied copy is now the saved setting: fields not edited since sending show it
      if (!res.error && res.data) {
        const after = workflowForm(res.data);
        setForm((f) => reconcileWorkflowForm(f, sent, after));
        setSynced(after);
        setBase(res.data);
      }
      return res;
    }, "Workflow saved.");
  }
  return (
    <div className="ba-workflow-settings" data-workflow-settings={type.key}>
      <h3 className="ba-h3">Approvals, checklists and credits</h3>
      <p className="ba-muted">Dates and problems are always available. {w.custom ? "These are your own settings." : "These are your industry's starting settings until you save your own."}</p>
      {act.problem && <p className="ba-error" role="alert">{act.problem}</p>}
      <fieldset className="ba-prefs"><legend>Approvals to track</legend>
        {APPROVAL_KINDS.map(([k, l]) => <label key={k} className="ba-check"><input type="checkbox" checked={kinds.includes(k)} onChange={() => toggle(k)} /> {l}</label>)}
      </fieldset>
      <label className="ba-check"><input type="checkbox" checked={inspect} onChange={(e) => setInspect(e.target.checked)} /> A checklist or inspection</label>
      {inspect && (
        <div className="ba-form-grid">
          <Field label="Checklist name"><input value={title} onChange={(e) => setTitle(e.target.value)} maxLength={120} /></Field>
          <Field label="Items, one per line" full><textarea rows={5} value={items} onChange={(e) => setItems(e.target.value)} /></Field>
        </div>
      )}
      <label className="ba-check"><input type="checkbox" checked={credits} onChange={(e) => setCredits(e.target.checked)} /> Count credits (packages, memberships)</label>
      {credits && <Field label="Counted in"><input value={unit} onChange={(e) => setUnit(e.target.value)} maxLength={30} placeholder="sessions" /></Field>}
      <button type="button" className="ba-btn sm primary" disabled={act.busy} onClick={save}>{act.busy ? "Saving…" : "Save workflow"}</button>
    </div>
  );
}

