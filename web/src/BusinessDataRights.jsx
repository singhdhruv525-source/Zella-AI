import { useState } from "react";
import { supabase } from "./supabase";
import { Field, Pill, personName } from "./BusinessUI";
import { Empty, Notice, friendly, loadPeople, orThrow, useLoad } from "./BusinessShared";
import { formatDay } from "./businessTime";

// Customer data requests: a customer asks to see, correct, stop the use of, or
// erase their information (sql/zella_data_rights.sql). Managers log them; an
// owner or admin carries them out. Erasing needs a second owner or admin to
// approve when the business has two (zella_approval_ok), and every step is in
// the audit log. Nothing is erased until the request is carried out.

export const DATA_RIGHTS_ROLES = ["owner", "admin", "manager"];
const CAN_HANDLE = ["owner", "admin"];

const KINDS = {
  export: ["A copy of their information", "Download their details, calls, messages and appointments as a file."],
  correct: ["Correct their information", "Fix their details on the Overview tab, then mark this done."],
  stop_use: ["Stop using their information", "Switch on Do not contact on the Overview tab, then mark this done."],
  erase: ["Erase their information", "Removes their name, contact details, messages, recordings and notes. This can't be undone."],
};

const SAY = {
  NOT_ALLOWED: "Only an owner or admin can carry out a request.",
  ALREADY_HANDLED: "This request was already handled.",
  NO_CUSTOMER: "This request isn't linked to a customer, so there is nothing to export or erase.",
  REASON_REQUIRED: "Give a reason for turning the request down.",
  NOT_FOUND: "This request or customer no longer exists.",
};
const say = (error) => {
  const code = Object.keys(SAY).find((k) => (error?.message ?? "").includes(k));
  return code ? SAY[code] : friendly(error);
};

function download(name, data) {
  const blob = new Blob([JSON.stringify(data, null, 2)], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  const a = Object.assign(document.createElement("a"), { href: url, download: name });
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function RequestRow({ request, person, workspace, onDone, onNotice, onOpenPerson }) {
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState("");
  const canHandle = CAN_HANDLE.includes(workspace.role);
  const [label] = KINDS[request.kind] ?? [request.kind];
  const who = personName(person) ?? request.requester_name ?? "Unknown customer";
  const late = request.status === "open" && new Date(request.due_at) < new Date();

  async function askForApproval() {
    // One pending request per customer is enough; don't ask twice.
    const pending = await supabase.rpc("zella_pending_approvals", { p_business_id: workspace.id });
    const already = (pending.data ?? []).some((a) => a.action === "erase_customer" && a.details?.customer_id === request.customer_id);
    if (!already) {
      const { error } = await supabase.rpc("zella_request_approval", {
        p_business_id: workspace.id, p_action: "erase_customer", p_entity_id: request.customer_id,
        p_details: { customer_id: request.customer_id, request_id: request.id, name: who },
      });
      if (error) throw error;
    }
    return already;
  }

  async function carryOut() {
    if (request.kind === "erase" && !window.confirm(`Erase ${who}'s information? Their name, contact details, message text, call recordings, transcripts and notes are removed for good. Appointment and call dates stay, without their details.`)) return;
    setBusy(true);
    setProblem("");
    const { data, error } = await supabase.rpc("zella_fulfil_data_rights_request", { p_request_id: request.id, p_note: null });
    if (error && /APPROVAL_REQUIRED/.test(error.message)) {
      try {
        const already = await askForApproval();
        onNotice?.(already
          ? "A second owner or admin still has to approve this. It's waiting in Approvals."
          : "A second owner or admin must approve erasing this person. They've been asked in Approvals; come back here once it's approved.");
      } catch (err) {
        setProblem(say(err));
      }
      setBusy(false);
      return;
    }
    setBusy(false);
    if (error) return setProblem(say(error));
    if (request.kind === "export") {
      download(`customer-data-${(who || "customer").replace(/[^a-z0-9]+/gi, "-").toLowerCase()}-${new Date().toISOString().slice(0, 10)}.json`, data);
      onNotice?.("The file is downloaded. Send it to the customer securely, then delete your copy.");
    } else {
      onNotice?.(request.kind === "erase" ? `${who}'s information was erased.` : "Marked as done.");
    }
    onDone();
  }

  async function reject() {
    const reason = window.prompt("Why is this request being turned down? The reason is kept with the request.");
    if (reason === null) return;
    setBusy(true);
    setProblem("");
    const { error } = await supabase.rpc("zella_reject_data_rights_request", { p_request_id: request.id, p_reason: reason });
    setBusy(false);
    if (error) return setProblem(say(error));
    onNotice?.("Request turned down.");
    onDone();
  }

  return (
    <li className="ba-list-row">
      <div>
        <strong>{label}{onOpenPerson && request.customer_id ? <> · <button type="button" className="ba-link" onClick={() => onOpenPerson(request.customer_id)}>{who}</button></> : ""}</strong>
        <small>
          Logged {formatDay(request.created_at, workspace.timezone)}
          {request.status === "open" ? ` · due ${formatDay(request.due_at, workspace.timezone)}` : ` · ${request.status === "done" ? "done" : "turned down"} ${formatDay(request.handled_at, workspace.timezone)}`}
          {request.requester_contact ? ` · ${request.requester_contact}` : ""}
          {request.note ? ` · ${request.note}` : ""}
        </small>
        {problem && <small className="ba-error" role="alert">{problem}</small>}
      </div>
      {request.status === "open" ? (
        canHandle ? (
          <div className="ba-form-actions">
            <button type="button" className={`ba-btn sm ${request.kind === "erase" ? "danger-outline" : "primary"}`} onClick={carryOut} disabled={busy}>
              {busy ? "Working…" : request.kind === "export" ? "Download file" : request.kind === "erase" ? "Erase" : "Mark done"}
            </button>
            <button type="button" className="ba-btn sm" onClick={reject} disabled={busy}>Turn down</button>
          </div>
        ) : <Pill tone={late ? "danger" : "warning"}>{late ? "Overdue" : "Open"}</Pill>
      ) : <Pill tone={request.status === "done" ? "success" : ""}>{request.status === "done" ? "Done" : "Turned down"}</Pill>}
    </li>
  );
}

// On a person's profile: their requests and a form to log a new one.
export function PersonDataRights({ person, workspace, onChanged, onNotice }) {
  const [form, setForm] = useState({ kind: "export", contact: person.email || person.phone || "", note: "" });
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState("");
  const { data, error, reload } = useLoad(async () => orThrow(await supabase.from("data_rights_requests")
    .select("*").eq("business_id", workspace.id).eq("customer_id", person.id).order("created_at", { ascending: false })), [person.id]);

  async function log(event) {
    event.preventDefault();
    setBusy(true);
    setProblem("");
    const { error: e } = await supabase.rpc("zella_log_data_rights_request", {
      p_business_id: workspace.id, p_kind: form.kind, p_customer_id: person.id,
      p_name: personName(person), p_contact: form.contact.trim() || null, p_note: form.note.trim() || null,
    });
    setBusy(false);
    if (e) return setProblem(say(e));
    setForm((f) => ({ ...f, note: "" }));
    onNotice?.("Request logged. It's due in 30 days, and the owners have been told.");
    reload();
  }

  const done = () => { reload(); onChanged?.(); };
  return (
    <div className="ba-form">
      <Notice error={error} onRetry={reload} />
      {data && !data.length && <Empty title="No requests">If this person asks for a copy of their information, or to have it corrected or erased, log it here.</Empty>}
      {!!data?.length && <ul className="ba-list">{data.map((r) => <RequestRow key={r.id} request={r} person={person} workspace={workspace} onDone={done} onNotice={onNotice} />)}</ul>}
      <form className="ba-form-grid" onSubmit={log}>
        <Field label="They asked for" full>
          <select value={form.kind} onChange={(e) => setForm({ ...form, kind: e.target.value })}>
            {Object.entries(KINDS).map(([k, [text]]) => <option key={k} value={k}>{text}</option>)}
          </select>
        </Field>
        <p className="ba-muted full">{KINDS[form.kind][1]}</p>
        <Field label="How to reach them about it"><input value={form.contact} maxLength={200} onChange={(e) => setForm({ ...form, contact: e.target.value })} /></Field>
        <Field label="Note" hint="Optional. How they asked and when."><input value={form.note} maxLength={1000} onChange={(e) => setForm({ ...form, note: e.target.value })} /></Field>
        {problem && <div className="ba-banner error full" role="alert"><span>{problem}</span></div>}
        <div className="full ba-form-actions"><button type="submit" className="ba-btn" disabled={busy}>{busy ? "Logging…" : "Log request"}</button></div>
      </form>
    </div>
  );
}

// Settings > Privacy requests: every open request in the business.
export function DataRightsList({ workspace, onOpenPerson, onNotice }) {
  const [show, setShow] = useState("open");
  const { data, error, loading, reload } = useLoad(async () => {
    let q = supabase.from("data_rights_requests").select("*").eq("business_id", workspace.id).order("due_at", { ascending: true }).limit(100);
    if (show === "open") q = q.eq("status", "open");
    const rows = orThrow(await q);
    return { rows, people: await loadPeople(rows.map((r) => r.customer_id)) };
  }, [workspace.id, show]);
  return (
    <section className="ba-panel">
      <div className="ba-panel-head"><div className="ba-panel-title"><div><h2>Privacy requests</h2><p>Customers asking for a copy of their information, a correction, or erasure. Reply within 30 days.</p></div></div>
        <select value={show} onChange={(e) => setShow(e.target.value)} aria-label="Show"><option value="open">Open</option><option value="all">All</option></select>
      </div>
      <div className="ba-panel-body">
        <Notice error={error} onRetry={reload} />
        {loading && !data && <p className="ba-muted">Loading…</p>}
        {data && !data.rows.length && <Empty title={show === "open" ? "No open requests" : "No requests yet"}>Requests are logged from a customer's profile, on the Privacy tab.</Empty>}
        {!!data?.rows.length && <ul className="ba-list">{data.rows.map((r) => (
          <RequestRow key={r.id} request={r} person={data.people[r.customer_id]} workspace={workspace} onDone={reload} onNotice={onNotice} onOpenPerson={onOpenPerson} />
        ))}</ul>}
      </div>
    </section>
  );
}
