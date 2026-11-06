// Release 1: People & consent for a person or a record (a child, pet, unit, policy, matter ...).
// Who is linked, what each may do, whether that has been verified, and consents given or refused. Every change goes
// through the server's checked functions (sql/zella_relationships.sql); the screen only shows what the server says.
import { useRef, useState } from "react";
import { supabase } from "./supabase";
import { Field, Icon, Pill } from "./BusinessUI";
import { formatDay } from "./businessTime";
import { useLoad } from "./BusinessShared";
import { PersonPicker } from "./BusinessWork";
import {
  CONSENT_KINDS, CONSENT_LABEL, CONSENT_STATE, KIND_LABEL, METHODS, METHOD_LABEL, PERMISSIONS, PERMISSION_LABEL, STATE,
  consentGivers, peopleError, personLabel, suggestedKinds,
} from "./peopleLogic";

const today = () => new Date().toISOString().slice(0, 10);
// end dates are calendar dates (no time): shown as stored, never shifted by a time zone
const calendarDay = (d) => formatDay(`${d}T12:00:00Z`, "UTC");

// subject: { customer } for a person, or { recordId, typeKey, title } for a record
export function PeopleAndConsent({ workspace, subject, onNotice }) {
  const customerId = subject.customer?.id ?? null;
  const recordId = subject.recordId ?? null;
  const tz = workspace.timezone;
  const panel = useLoad(async () => {
    const res = await supabase.rpc("zella_people_panel", { p_business_id: workspace.id, p_customer_id: customerId, p_record_id: recordId });
    if (res.error) throw new Error(peopleError(res.error));
    const d = res.data;
    // anything but the expected shape is treated as "couldn't load", never drawn half-empty
    if (!d || !Array.isArray(d.relationships) || !Array.isArray(d.consents)) throw new Error("People & consent couldn't be loaded. Try again.");
    return { ...d, authorized_for: Array.isArray(d.authorized_for) ? d.authorized_for : [] };
  }, [workspace.id, customerId, recordId]);
  const [editing, setEditing] = useState(null);   // null | "new" | relationship
  const [verifying, setVerifying] = useState(null);
  const [consenting, setConsenting] = useState(false);
  const [problem, setProblem] = useState("");
  const [done, setDone] = useState("");
  const [busy, setBusy] = useState(false);
  const inFlight = useRef(false);

  // one change at a time; the panel reloads from the server afterwards
  async function run(fn, args, done) {
    if (inFlight.current) return false;
    inFlight.current = true; setBusy(true); setProblem(""); setDone("");
    const res = await supabase.rpc(fn, args);
    inFlight.current = false; setBusy(false);
    // a refusal reloads the panel too, so it shows the current state (e.g. a link someone else just changed)
    if (res.error) { setProblem(peopleError(res.error)); panel.reload(); return false; }
    setDone(done);
    onNotice?.(done);
    panel.reload();
    return true;
  }

  if (panel.loading && !panel.data) return <p className="ba-muted">Loading people and consent…</p>;
  if (panel.error && !panel.data) {
    return (
      <div className="ba-error" role="alert" data-people="failed">
        {panel.error} <button type="button" className="ba-btn sm" onClick={panel.reload}>Try again</button>
      </div>
    );
  }
  const p = panel.data;
  const active = p.relationships.filter((r) => r.state !== "revoked");
  const past = p.relationships.filter((r) => r.state === "revoked");

  return (
    <div className="ba-people" data-people="ready">
      {panel.error && <p className="ba-error" role="status">The latest refresh failed: showing what was loaded before. <button type="button" className="ba-btn sm" onClick={panel.reload}>Try again</button></p>}
      {problem && <p className="ba-error" role="alert">{problem}</p>}
      {done && <p className="ba-notice ba-small" role="status">{done}</p>}

      <h3 className="ba-sub">People who may act for {subject.customer ? personLabel(subject.customer) : subject.title}</h3>
      <p className="ba-muted ba-small">
        A link gives nothing until it is verified, and nothing after its end date or once revoked.
        {p.sensitive && " In this industry only owners, admins and managers can verify."}
      </p>
      {p.primary_contact && <p className="ba-small"><strong>Primary contact:</strong> {personLabel(p.primary_contact)} (may act for this record)</p>}
      {active.length ? (
        <ul className="ba-people-list">
          {active.map((r) => {
            const [tone, label] = STATE[r.state] ?? ["neutral", r.state];
            return (
              <li key={r.id} data-relationship={r.state}>
                <div>
                  <strong>{personLabel(r.person)}</strong> · {KIND_LABEL[r.kind] ?? r.kind} <Pill tone={tone}>{label}</Pill>
                  <small>
                    {r.permissions.length ? r.permissions.map((x) => PERMISSION_LABEL[x] ?? x).join(" · ") : "No permissions"}
                    {r.valid_until ? ` · until ${calendarDay(r.valid_until)}` : ""}
                    {r.state === "active" && r.verification_method ? ` · ${METHOD_LABEL[r.verification_method] ?? r.verification_method}` : ""}
                  </small>
                  {r.note && <small>{r.note}</small>}
                </div>
                {p.can_edit && (
                  <div className="ba-people-actions">
                    {r.state === "unverified" && p.can_verify && <button type="button" className="ba-btn sm primary" disabled={busy} onClick={() => setVerifying(r)}>Verify</button>}
                    <button type="button" className="ba-btn sm" disabled={busy} onClick={() => setEditing(r)}>Edit</button>
                    <button type="button" className="ba-btn sm ghost" disabled={busy} onClick={async () => {
                      const reason = window.prompt(`Revoke ${personLabel(r.person)}'s link? They can no longer act for this ${subject.customer ? "person" : "record"}. Reason (optional):`);
                      if (reason === null) return;
                      await run("zella_relationship_revoke", { p_id: r.id, p_reason: reason }, `${personLabel(r.person)}'s link was revoked.`);
                    }}>Revoke</button>
                  </div>
                )}
              </li>
            );
          })}
        </ul>
      ) : <p className="ba-muted">Nobody is linked yet.</p>}
      {p.can_edit && editing === null && <button type="button" className="ba-btn sm" onClick={() => setEditing("new")}><Icon name="person_add" size="sm" /> Link a person</button>}

      {verifying && <VerifyForm key={verifying.id} rel={verifying} busy={busy} onCancel={() => setVerifying(null)}
        onSave={async (method) => { await run("zella_relationship_verify", {
          // exactly what the verifier is looking at; the server refuses if the link changed since (CHANGED)
          p_id: verifying.id, p_method: method, p_related_customer_id: verifying.person.id, p_kind: verifying.kind, p_permissions: verifying.permissions,
        }, `${personLabel(verifying.person)} is verified.`);
          setVerifying(null);   // on success, or to show the link as it is now (the panel reloads either way)
        }} />}
      {editing && <RelationshipForm key={editing === "new" ? "new" : editing.id} workspace={workspace} subject={subject} rel={editing === "new" ? null : editing} busy={busy}
        onCancel={() => setEditing(null)}
        onSave={async (form) => {
          const ok = await run("zella_relationship_save", {
            p_business_id: workspace.id, p_id: form.id ?? null, p_customer_id: customerId, p_record_id: recordId,
            p_related_customer_id: form.person?.id ?? null, p_kind: form.kind, p_permissions: form.permissions,
            p_valid_until: form.valid_until || null, p_note: form.note || null,
          }, form.id ? "Link updated. If you widened what they may do, it needs verifying again." : "Person linked. Verify them before they can act.");
          if (ok) setEditing(null);
        }} />}

      {past.length > 0 && (
        <details className="ba-people-past"><summary>Revoked ({past.length})</summary>
          <ul className="ba-people-list">{past.map((r) => <li key={r.id}><div><strong>{personLabel(r.person)}</strong> · {KIND_LABEL[r.kind] ?? r.kind}<small>Revoked {formatDay(r.revoked_at, tz)}</small></div></li>)}</ul>
        </details>
      )}

      {subject.customer && p.authorized_for.length > 0 && (
        <>
          <h3 className="ba-sub">{personLabel(subject.customer)} is linked to</h3>
          <ul className="ba-people-list">
            {p.authorized_for.map((r) => {
              const [tone, label] = STATE[r.state] ?? ["neutral", r.state];
              return <li key={r.id}><div><strong>{r.subject.name || "Unnamed"}</strong> · {KIND_LABEL[r.kind] ?? r.kind} <Pill tone={tone}>{label}</Pill><small>{r.permissions.map((x) => PERMISSION_LABEL[x] ?? x).join(" · ") || "No permissions"}</small></div></li>;
            })}
          </ul>
        </>
      )}

      <h3 className="ba-sub">Consent</h3>
      {p.consents.length ? (
        <ul className="ba-people-list">
          {p.consents.map((k) => {
            const [tone, label] = CONSENT_STATE[k.state] ?? ["neutral", k.state];
            return (
              <li key={k.id} data-consent={k.state}>
                <div>
                  <strong>{CONSENT_LABEL[k.kind] ?? k.kind}</strong>{k.scope ? `: ${k.scope}` : ""} <Pill tone={tone}>{label}</Pill>
                  <small>By {personLabel(k.given_by)} · {formatDay(k.given_at, tz)}{k.expires_at ? ` · until ${calendarDay(k.expires_at)}` : ""}{k.evidence ? ` · ${k.evidence}` : ""}</small>
                </div>
                {p.can_edit && k.state === "active" && (
                  <div className="ba-people-actions">
                    <button type="button" className="ba-btn sm ghost" disabled={busy} onClick={async () => {
                      const reason = window.prompt("Record that this consent was withdrawn? Reason (optional):");
                      if (reason === null) return;
                      await run("zella_consent_revoke", { p_id: k.id, p_reason: reason }, "Consent withdrawn.");
                    }}>Withdrawn</button>
                  </div>
                )}
              </li>
            );
          })}
        </ul>
      ) : <p className="ba-muted">No consent recorded.</p>}
      {p.can_edit && !consenting && <button type="button" className="ba-btn sm" onClick={() => setConsenting(true)}><Icon name="fact_check" size="sm" /> Record consent</button>}
      {consenting && <ConsentForm givers={consentGivers(p, subject)} busy={busy} onCancel={() => setConsenting(false)}
        onSave={async (f) => {
          const ok = await run("zella_consent_record", {
            p_business_id: workspace.id, p_customer_id: customerId, p_record_id: recordId, p_kind: f.kind, p_status: f.status,
            p_given_by_customer_id: f.givenBy, p_scope: f.scope || null, p_expires_at: f.expires || null, p_evidence: f.evidence || null,
          }, f.status === "granted" ? "Consent recorded." : "Refusal recorded.");
          if (ok) setConsenting(false);
        }} />}
      {!p.can_edit && <p className="ba-muted ba-small">You can view this. Changes need a staff member or above.</p>}
    </div>
  );
}

function RelationshipForm({ workspace, subject, rel, busy, onCancel, onSave }) {
  const [form, setForm] = useState(() => ({ id: rel?.id, person: rel?.person ?? null, kind: rel?.kind ?? suggestedKinds(subject)[0][0],
    permissions: rel?.permissions ?? ["discuss"], valid_until: rel?.valid_until ?? "", note: rel?.note ?? "" }));
  const toggle = (perm) => setForm((f) => ({ ...f, permissions: f.permissions.includes(perm) ? f.permissions.filter((x) => x !== perm) : [...f.permissions, perm] }));
  return (
    <form className="ba-people-form" aria-label={rel ? "Edit link" : "Link a person"} onSubmit={(e) => { e.preventDefault(); if (form.person && !busy) onSave(form); }}>
      <PersonPicker businessId={workspace.id} label="Person" value={form.person} onChange={(person) => setForm((f) => ({ ...f, person }))}
        hint="Someone already in your list. Add them as a contact first if they aren't." />
      <Field label="Relationship">
        <select value={form.kind} onChange={(e) => setForm((f) => ({ ...f, kind: e.target.value }))}>
          {suggestedKinds(subject).map(([k, label]) => <option key={k} value={k}>{label}</option>)}
        </select>
      </Field>
      <fieldset className="ba-prefs"><legend>They may</legend>
        {PERMISSIONS.map(([k, label]) => <label key={k} className="ba-check"><input type="checkbox" checked={form.permissions.includes(k)} onChange={() => toggle(k)} /><span>{label}</span></label>)}
      </fieldset>
      <Field label="Until (optional)"><input type="date" min={today()} value={form.valid_until ?? ""} onChange={(e) => setForm((f) => ({ ...f, valid_until: e.target.value }))} /></Field>
      <Field label="Note (optional)" full><input value={form.note ?? ""} maxLength={500} onChange={(e) => setForm((f) => ({ ...f, note: e.target.value }))} placeholder="e.g. picks up on Fridays" /></Field>
      {rel && <p className="ba-muted ba-small">Changing the person, the relationship or adding permissions means verifying them again.</p>}
      <div className="ba-form-actions">
        <button type="button" className="ba-btn" onClick={onCancel} disabled={busy}>Cancel</button>
        <button type="submit" className="ba-btn primary" disabled={busy || !form.person}>{busy ? "Saving…" : rel ? "Save link" : "Link person"}</button>
      </div>
    </form>
  );
}

function VerifyForm({ rel, busy, onCancel, onSave }) {
  const [method, setMethod] = useState("");
  return (
    <form className="ba-people-form" aria-label={`Verify ${personLabel(rel.person)}`} onSubmit={(e) => { e.preventDefault(); if (method && !busy) onSave(method); }}>
      <p><strong>Verify {personLabel(rel.person)}</strong> as {(KIND_LABEL[rel.kind] ?? rel.kind).toLowerCase()}: {rel.permissions.map((x) => PERMISSION_LABEL[x] ?? x).join(", ") || "no permissions"}.</p>
      <Field label="How did you verify them?">
        <select value={method} onChange={(e) => setMethod(e.target.value)} required>
          <option value="">Choose…</option>
          {METHODS.map(([k, label]) => <option key={k} value={k}>{label}</option>)}
        </select>
      </Field>
      <div className="ba-form-actions">
        <button type="button" className="ba-btn" onClick={onCancel} disabled={busy}>Cancel</button>
        <button type="submit" className="ba-btn primary" disabled={busy || !method}>{busy ? "Saving…" : "Mark verified"}</button>
      </div>
    </form>
  );
}

function ConsentForm({ givers, busy, onCancel, onSave }) {
  const [f, setF] = useState({ kind: "treatment", status: "granted", givenBy: givers[0]?.id ?? "", scope: "", expires: "", evidence: "" });
  const set = (k) => (e) => setF((x) => ({ ...x, [k]: e.target.value }));
  // the givers list reloads with the panel: a choice that is no longer eligible counts as no choice
  const givenBy = givers.some((g) => g.id === f.givenBy) ? f.givenBy : "";
  return (
    <form className="ba-people-form" aria-label="Record consent" onSubmit={(e) => { e.preventDefault(); if (givenBy && !busy) onSave({ ...f, givenBy }); }}>
      <Field label="Consent for"><select value={f.kind} onChange={set("kind")}>{CONSENT_KINDS.map(([k, label]) => <option key={k} value={k}>{label}</option>)}</select></Field>
      <Field label="Answer"><select value={f.status} onChange={set("status")}><option value="granted">Given</option><option value="refused">Refused</option></select></Field>
      <Field label="Given by">
        {givers.length ? (
          <select value={givenBy} onChange={set("givenBy")}>
            {!givenBy && <option value="" disabled>Choose…</option>}
            {givers.map((g) => <option key={g.id} value={g.id}>{g.label}</option>)}
          </select>
        )
          : <p className="ba-muted ba-small">Nobody here can give consent yet: link and verify someone allowed to approve.</p>}
      </Field>
      <Field label="What exactly (optional)"><input value={f.scope} maxLength={300} onChange={set("scope")} placeholder="e.g. class photos only" /></Field>
      <Field label="Until (optional)"><input type="date" min={today()} value={f.expires} onChange={set("expires")} /></Field>
      <Field label="Evidence (optional)"><input value={f.evidence} maxLength={500} onChange={set("evidence")} placeholder="e.g. signed form, 6 Nov" /></Field>
      <div className="ba-form-actions">
        <button type="button" className="ba-btn" onClick={onCancel} disabled={busy}>Cancel</button>
        <button type="submit" className="ba-btn primary" disabled={busy || !givenBy}>{busy ? "Saving…" : "Record"}</button>
      </div>
    </form>
  );
}
