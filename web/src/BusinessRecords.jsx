import { useEffect, useMemo, useState } from "react";
import { supabase } from "./supabase";
import { Field, Icon, Modal, Pill, personName } from "./BusinessUI";
import { formatDay, formatTime, timeAgo } from "./businessTime";
import { Empty, Notice, PAGE_SIZE, PageHead, Pager, explain, orThrow, useLoad } from "./BusinessShared";
import { PersonPicker } from "./BusinessWork";

// One set of screens for every industry. The business's record types
// (fields, statuses, names) come from crm_record_types.

const slug = (text) => text.toLowerCase().trim().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "").slice(0, 40);
const toInputDateTime = (value) => {
  if (!value) return "";
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return "";
  const pad = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
};

export function useRecordTypes(workspace, refreshKey) {
  const [state, setState] = useState({ types: [], loaded: false });
  const [version, setVersion] = useState(0);
  useEffect(() => {
    let live = true;
    (async () => {
      // Copies the industry's starting set the first time; never overwrites a business's own settings.
      await supabase.rpc("zella_ensure_crm_types", { p_business_id: workspace.id });
      const { data } = await supabase.from("crm_record_types").select("*").eq("business_id", workspace.id).order("position");
      if (live) setState({ types: data ?? [], loaded: true });
    })();
    return () => { live = false; };
  }, [workspace.id, refreshKey, version]);
  return { ...state, reload: () => setVersion((v) => v + 1) };
}

export function showValue(field, value, tz) {
  if (value === undefined || value === null || value === "") return "—";
  if (field.type === "bool") return value ? "Yes" : "No";
  if (field.type === "date") return formatDay(value, tz);
  if (field.type === "datetime") return `${formatDay(value, tz)} · ${formatTime(value, tz)}`;
  return String(value);
}

function FieldInput({ field, value, onChange }) {
  const v = value ?? "";
  if (field.type === "longtext") return <textarea rows={3} value={v} onChange={(e) => onChange(e.target.value)} />;
  if (field.type === "select") return (
    <select value={v} onChange={(e) => onChange(e.target.value)}>
      <option value="">Choose…</option>
      {field.options.map((o) => <option key={o} value={o}>{o}</option>)}
    </select>
  );
  if (field.type === "bool") return (
    <label className="ba-check"><input type="checkbox" checked={v === true || v === "true"} onChange={(e) => onChange(e.target.checked)} /> Yes</label>
  );
  const htmlType = { number: "number", date: "date", datetime: "datetime-local", phone: "tel", email: "email" }[field.type] ?? "text";
  const shown = field.type === "datetime" ? toInputDateTime(v) : v;
  return <input type={htmlType} value={shown} onChange={(e) => onChange(field.type === "datetime" && e.target.value ? new Date(e.target.value).toISOString() : e.target.value)} />;
}

/* ------------------------------------------------------------------ */
/* One record: create, edit, change status, add notes                    */
/* ------------------------------------------------------------------ */

function RecordModal({ workspace, type, record, canManage, onClose, onSaved, onOpenExisting, onOpenPerson }) {
  const tz = workspace.timezone;
  const isNew = !record;
  const [title, setTitle] = useState(record?.title ?? "");
  const [status, setStatus] = useState(record?.status ?? type.statuses[0]?.key);
  const [person, setPerson] = useState(record?.customers ?? null);
  const [data, setData] = useState(record?.data ?? {});
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [duplicateId, setDuplicateId] = useState(null);
  const events = useLoad(async () => (isNew ? [] : orThrow(await supabase.from("crm_record_events").select("*").eq("record_id", record.id).order("created_at", { ascending: false }).limit(40))), [record?.id]);

  function fail(failure) {
    const match = String(failure?.message ?? "").match(/DUPLICATE:([0-9a-f-]{36})/);
    setDuplicateId(match ? match[1] : null);
    setError(/NOT_VALID/.test(failure?.message ?? "") ? "Something in this form isn't valid. Check the status and fields." : explain(failure));
  }

  async function save(event) {
    event.preventDefault();
    setBusy(true);
    setError("");
    setDuplicateId(null);
    const { error: failure } = await supabase.rpc("zella_save_record", {
      p_business_id: workspace.id, p_type_key: type.key, p_id: record?.id ?? null, p_title: title, p_status: status,
      p_customer_id: type.link_person ? person?.id ?? null : null, p_data: data,
    });
    setBusy(false);
    if (failure) return fail(failure);
    onSaved(isNew ? `${type.singular} added.` : `${type.singular} saved.`);
  }

  async function run(work, message) {
    setBusy(true);
    setError("");
    const { error: failure } = await work();
    setBusy(false);
    if (failure) return fail(failure);
    onSaved(message);
  }

  const closed = type.closed_statuses.includes(record?.status);
  return (
    <Modal wide title={isNew ? `Add ${type.singular.toLowerCase()}` : record.title} description={isNew ? type.notice ?? undefined : `${type.singular} · updated ${timeAgo(record.updated_at)}`} onClose={onClose} busy={busy}
      footer={<>
        {!isNew && canManage && <button type="button" className="ba-btn ghost danger" disabled={busy}
          onClick={() => window.confirm(`Archive this ${type.singular.toLowerCase()}? It will be hidden from the list.`) && run(() => supabase.rpc("zella_archive_record", { p_id: record.id }), `${type.singular} archived.`)}>Archive</button>}
        <button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Close</button>
        <button type="submit" form="ba-record-form" className="ba-btn primary" disabled={busy}>{busy ? "Saving…" : isNew ? `Add ${type.singular.toLowerCase()}` : "Save changes"}</button>
      </>}>
      <form id="ba-record-form" className="ba-modal-body" onSubmit={save}>
        {error && (
          <p className="ba-error" role="alert">
            {error}
            {duplicateId && onOpenExisting && <> <button type="button" className="ba-link" onClick={() => onOpenExisting(duplicateId)}>Open the existing one</button></>}
          </p>
        )}
        {!isNew && type.notice && <p className="ba-muted">{type.notice}</p>}
        <div className="ba-form-grid">
          <Field label={type.title_label} full><input value={title} onChange={(e) => setTitle(e.target.value)} required maxLength={200} /></Field>
          <Field label="Status">
            <select value={status} onChange={(e) => setStatus(e.target.value)}>
              {type.statuses.map((s) => <option key={s.key} value={s.key}>{s.label}</option>)}
            </select>
          </Field>
          {type.fields.map((f) => (
            <Field key={f.key} label={f.required ? f.label : `${f.label}`} full={f.type === "longtext"} hint={f.unique ? "Used to spot duplicates." : undefined}>
              <FieldInput field={f} value={data[f.key]} onChange={(val) => setData({ ...data, [f.key]: val })} />
            </Field>
          ))}
        </div>
        {type.link_person && (
          <PersonPicker label={workspace.terminology?.customer ?? "Person"} value={person} onChange={setPerson} hint="Optional. Links this to someone you already have." />
        )}
        {!isNew && person && onOpenPerson && <button type="button" className="ba-btn sm" onClick={() => onOpenPerson(person.id)}>Open {personName(person) ?? "profile"}</button>}
      </form>
      {!isNew && (
        <div className="ba-modal-body ba-record-history">
          <h3 className="ba-h3">Notes and history</h3>
          <div className="ba-inline-form">
            <input value={note} onChange={(e) => setNote(e.target.value)} placeholder="Add a note" maxLength={2000} />
            <button type="button" className="ba-btn sm" disabled={busy || !note.trim()}
              onClick={async () => { const text = note; setNote(""); await run(() => supabase.rpc("zella_add_record_note", { p_id: record.id, p_note: text }), "Note added."); }}>Add note</button>
          </div>
          {closed && <p className="ba-muted">This one is {type.statuses.find((s) => s.key === record.status)?.label.toLowerCase()}.</p>}
          {(events.data ?? []).length === 0 ? <p className="ba-muted">Nothing yet.</p> : (
            <ul className="ba-history">
              {events.data.map((e) => (
                <li key={e.id}><strong>{{ created: "Added", edited: "Edited", status: "Status changed", note: "Note", archived: "Archived" }[e.kind] ?? e.kind}</strong>{e.detail ? ` · ${e.detail}` : ""}<small>{timeAgo(e.created_at)}</small></li>
              ))}
            </ul>
          )}
        </div>
      )}
    </Modal>
  );
}

/* ------------------------------------------------------------------ */
/* The list page                                                       */
/* ------------------------------------------------------------------ */

export function RecordsPage({ workspace, type, query, refreshKey, canManage, onNotice, onOpenPerson }) {
  const tz = workspace.timezone;
  const [filter, setFilter] = useState("open");
  const [page, setPage] = useState(0);
  const [modal, setModal] = useState(null); // {record} or {new:true}
  const { data, error, loading, reload } = useLoad(async () =>
    orThrow(await supabase.from("crm_records").select("*, customers(id, first_name, last_name, phone, email)")
      .eq("business_id", workspace.id).eq("type_key", type.key).is("archived_at", null).order("updated_at", { ascending: false }).limit(500)),
  [workspace.id, type.key, refreshKey]);

  useEffect(() => { setPage(0); setFilter("open"); }, [type.key]);

  const rows = useMemo(() => {
    const text = (query ?? "").trim().toLowerCase();
    return (data ?? []).filter((r) => {
      const closed = type.closed_statuses.includes(r.status);
      if (filter === "open" && closed) return false;
      if (filter === "closed" && !closed) return false;
      if (!["open", "closed", "all"].includes(filter) && r.status !== filter) return false;
      if (!text) return true;
      return [r.title, personName(r.customers), ...Object.values(r.data ?? {}).map(String)].some((v) => (v ?? "").toLowerCase().includes(text));
    });
  }, [data, filter, query, type]);
  useEffect(() => setPage(0), [filter, query]);
  const pages = Math.max(1, Math.ceil(rows.length / PAGE_SIZE));
  const visible = rows.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE);
  const cols = type.columns.map((k) => type.fields.find((f) => f.key === k)).filter(Boolean);
  const statusOf = (key) => type.statuses.find((s) => s.key === key) ?? { label: key, tone: "" };

  function saved(message) {
    setModal(null);
    onNotice(message);
    reload();
  }
  async function openExisting(id) {
    const row = (data ?? []).find((r) => r.id === id);
    if (row) setModal({ record: row });
  }

  return (
    <>
      <PageHead crumb={`Records / ${type.plural}`} title={type.plural} sub={type.notice ?? `Everything your team tracks as ${type.plural.toLowerCase()}.`}>
        <button type="button" className="ba-btn primary" onClick={() => setModal({ new: true })}><Icon name="add" size="sm" /> Add {type.singular.toLowerCase()}</button>
      </PageHead>
      <Notice error={error} onRetry={reload} />
      <section className="ba-panel">
        <div className="ba-toolbar">
          <span className="ba-muted">Use the search box at the top to find one.</span>
          <label className="ba-select">
            <span>Show</span>
            <select value={filter} onChange={(e) => setFilter(e.target.value)}>
              <option value="open">Open</option>
              <option value="closed">Finished</option>
              <option value="all">All</option>
              {type.statuses.map((s) => <option key={s.key} value={s.key}>{s.label} only</option>)}
            </select>
          </label>
        </div>
        {loading && !data ? <div className="ba-panel-body"><p className="ba-muted">Loading…</p></div> : !rows.length ? (
          <div className="ba-panel-body">
            <Empty title={query || filter !== "open" ? "No matches" : `No ${type.plural.toLowerCase()} yet`}>
              {query || filter !== "open" ? "Try a different search or filter." : `Add the first ${type.singular.toLowerCase()}. Zella's AI receptionist can add them from calls too, once it's live.`}
            </Empty>
          </div>
        ) : (
          <>
            <div className="ba-table-wrap">
              <table className="ba-table">
                <thead><tr><th>{type.title_label}</th><th>Status</th>{cols.map((c) => <th key={c.key}>{c.label}</th>)}{type.link_person && <th>{workspace.terminology?.customer ?? "Person"}</th>}<th>Updated</th></tr></thead>
                <tbody>
                  {visible.map((r) => (
                    <tr key={r.id} onClick={() => setModal({ record: r })} tabIndex={0} onKeyDown={(e) => e.key === "Enter" && setModal({ record: r })}>
                      <td><strong>{r.title}</strong></td>
                      <td><Pill tone={statusOf(r.status).tone}>{statusOf(r.status).label}</Pill></td>
                      {cols.map((c) => <td key={c.key}>{showValue(c, r.data?.[c.key], tz)}</td>)}
                      {type.link_person && <td>{personName(r.customers) ?? "—"}</td>}
                      <td>{timeAgo(r.updated_at)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <Pager page={page} pages={pages} total={rows.length} onPage={setPage} noun={type.singular.toLowerCase()} />
          </>
        )}
      </section>
      {modal && <RecordModal workspace={workspace} type={type} record={modal.record} canManage={canManage} onClose={() => setModal(null)} onSaved={saved} onOpenExisting={openExisting} onOpenPerson={onOpenPerson} />}
    </>
  );
}

/* ------------------------------------------------------------------ */
/* Owners tailor their records                                         */
/* ------------------------------------------------------------------ */

const FIELD_TYPES = [["text", "Short text"], ["longtext", "Long text"], ["select", "Choice list"], ["date", "Date"], ["datetime", "Date and time"], ["number", "Number"], ["phone", "Phone"], ["email", "Email"], ["bool", "Yes / No"]];

function TypeEditor({ workspace, type, onClose, onSaved }) {
  const isNew = !type;
  const [singular, setSingular] = useState(type?.singular ?? "");
  const [plural, setPlural] = useState(type?.plural ?? "");
  const [enabled, setEnabled] = useState(type?.enabled ?? true);
  const [statuses, setStatuses] = useState((type?.statuses ?? [{ key: "open", label: "Open", tone: "warning" }, { key: "done", label: "Done", tone: "success" }]).map((s) => ({ ...s, closed: type ? type.closed_statuses.includes(s.key) : s.key === "done", existing: Boolean(type) })));
  const [fields, setFields] = useState((type?.fields ?? [{ key: "details", label: "Details", type: "longtext" }]).map((f) => ({ ...f, existing: Boolean(type), optionsText: (f.options ?? []).join(", ") })));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const move = (list, set, i, d) => { const j = i + d; if (j < 0 || j >= list.length) return; const c = [...list]; [c[i], c[j]] = [c[j], c[i]]; set(c); };

  async function save(event) {
    event.preventDefault();
    setError("");
    const usedStatus = new Set(statuses.filter((s) => s.existing).map((s) => s.key));
    const outStatuses = statuses.map((s) => {
      let key = s.key;
      if (!s.existing) { key = slug(s.label) || "status"; let n = 2; while (usedStatus.has(key)) key = `${slug(s.label) || "status"}_${n++}`; usedStatus.add(key); }
      return { key, label: s.label.trim(), tone: s.tone ?? (s.closed ? "success" : "info"), closed: s.closed };
    });
    if (outStatuses.some((s) => !s.label)) return setError("Give every status a name.");
    const usedField = new Set(fields.filter((f) => f.existing).map((f) => f.key));
    const outFields = [];
    for (const f of fields) {
      let key = f.key;
      if (!f.existing) { key = slug(f.label) || "field"; let n = 2; while (usedField.has(key)) key = `${slug(f.label) || "field"}_${n++}`; usedField.add(key); }
      if (!f.label.trim()) return setError("Give every field a name.");
      const out = { key, label: f.label.trim(), type: f.type };
      if (f.type === "select") {
        out.options = f.optionsText.split(",").map((t) => t.trim()).filter(Boolean);
        if (!out.options.length) return setError(`Add choices for "${f.label}", separated by commas.`);
      }
      if (f.unique) out.unique = true;
      if (f.required) out.required = true;
      outFields.push(out);
    }
    const key = type?.key ?? (slug(singular) || "records");
    setBusy(true);
    const { error: failure } = await supabase.rpc("zella_save_record_type", {
      p_business_id: workspace.id, p_key: key,
      p_patch: {
        singular: singular.trim(), plural: plural.trim(), enabled,
        statuses: outStatuses.map(({ closed, ...s }) => s), closed_statuses: outStatuses.filter((s) => s.closed).map((s) => s.key),
        fields: outFields, ...(isNew ? {} : {}),
      },
    });
    setBusy(false);
    if (failure) return setError(explain(failure));
    onSaved(isNew ? "Record type added." : "Saved.");
  }

  return (
    <Modal wide title={isNew ? "Add a type of record" : `Edit ${type.plural.toLowerCase()}`} description="Changes apply to your business only." onClose={onClose} busy={busy}
      footer={<><button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button>
        <button type="submit" form="ba-type-form" className="ba-btn primary" disabled={busy}>{busy ? "Saving…" : "Save"}</button></>}>
      <form id="ba-type-form" className="ba-modal-body" onSubmit={save}>
        {error && <p className="ba-error" role="alert">{error}</p>}
        <div className="ba-form-grid">
          <Field label="Name (one)"><input value={singular} onChange={(e) => setSingular(e.target.value)} required maxLength={60} placeholder="Job" /></Field>
          <Field label="Name (many)"><input value={plural} onChange={(e) => setPlural(e.target.value)} required maxLength={60} placeholder="Jobs" /></Field>
          <Field label="Show in the menu" full><label className="ba-check"><input type="checkbox" checked={enabled} onChange={(e) => setEnabled(e.target.checked)} /> Yes. Hiding it keeps all its records.</label></Field>
        </div>

        <h3 className="ba-h3">Statuses</h3>
        <ul className="ba-edit-list">
          {statuses.map((s, i) => (
            <li key={s.key + i}>
              <input value={s.label} onChange={(e) => setStatuses(statuses.map((x, j) => (j === i ? { ...x, label: e.target.value } : x)))} aria-label="Status name" />
              <label className="ba-check"><input type="checkbox" checked={s.closed} onChange={(e) => setStatuses(statuses.map((x, j) => (j === i ? { ...x, closed: e.target.checked } : x)))} /> Finished</label>
              <button type="button" className="ba-btn sm ghost" onClick={() => move(statuses, setStatuses, i, -1)} aria-label="Move up"><Icon name="arrow_upward" size="sm" /></button>
              <button type="button" className="ba-btn sm ghost" onClick={() => move(statuses, setStatuses, i, 1)} aria-label="Move down"><Icon name="arrow_downward" size="sm" /></button>
              {!s.existing && <button type="button" className="ba-btn sm ghost" onClick={() => setStatuses(statuses.filter((_, j) => j !== i))} aria-label="Remove"><Icon name="close" size="sm" /></button>}
            </li>
          ))}
        </ul>
        <button type="button" className="ba-btn sm" onClick={() => setStatuses([...statuses, { key: "", label: "", closed: false, existing: false }])}>Add status</button>

        <h3 className="ba-h3">Fields</h3>
        <p className="ba-muted">Fields that already hold information can be renamed but not removed or changed to another type.</p>
        <ul className="ba-edit-list">
          {fields.map((f, i) => (
            <li key={f.key + i} className="wrap">
              <input value={f.label} onChange={(e) => setFields(fields.map((x, j) => (j === i ? { ...x, label: e.target.value } : x)))} aria-label="Field name" />
              <select value={f.type} disabled={f.existing} onChange={(e) => setFields(fields.map((x, j) => (j === i ? { ...x, type: e.target.value } : x)))} aria-label="Field type">
                {FIELD_TYPES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
              </select>
              {f.type === "select" && <input value={f.optionsText} onChange={(e) => setFields(fields.map((x, j) => (j === i ? { ...x, optionsText: e.target.value } : x)))} placeholder="Choices, separated by commas" aria-label="Choices" />}
              <label className="ba-check"><input type="checkbox" checked={Boolean(f.required)} onChange={(e) => setFields(fields.map((x, j) => (j === i ? { ...x, required: e.target.checked } : x)))} /> Required</label>
              <button type="button" className="ba-btn sm ghost" onClick={() => move(fields, setFields, i, -1)} aria-label="Move up"><Icon name="arrow_upward" size="sm" /></button>
              <button type="button" className="ba-btn sm ghost" onClick={() => move(fields, setFields, i, 1)} aria-label="Move down"><Icon name="arrow_downward" size="sm" /></button>
              {!f.existing && <button type="button" className="ba-btn sm ghost" onClick={() => setFields(fields.filter((_, j) => j !== i))} aria-label="Remove"><Icon name="close" size="sm" /></button>}
            </li>
          ))}
        </ul>
        <button type="button" className="ba-btn sm" onClick={() => setFields([...fields, { key: "", label: "", type: "text", existing: false, optionsText: "" }])}>Add field</button>
      </form>
    </Modal>
  );
}

export function RecordSettingsPage({ workspace, types, canManage, onNotice, onChanged }) {
  const [editing, setEditing] = useState(null); // type, or "new"
  if (!canManage) {
    return (
      <>
        <PageHead crumb="Business operations / Customize records" title="Customize records" sub="Only owners and managers can change how records look." />
        <Empty title="Ask an owner or manager">They can rename records, change statuses and add fields.</Empty>
      </>
    );
  }
  return (
    <>
      <PageHead crumb="Business operations / Customize records" title="Customize records" sub="Rename what you track, change its statuses, and add the fields your team needs. Other businesses are not affected.">
        <button type="button" className="ba-btn primary" onClick={() => setEditing("new")}><Icon name="add" size="sm" /> Add a type of record</button>
      </PageHead>
      <section className="ba-panel">
        {types.length === 0 ? <div className="ba-panel-body"><Empty title="Nothing to customize yet">Your records appear here once your industry is set up.</Empty></div> : (
          <div className="ba-table-wrap">
            <table className="ba-table">
              <thead><tr><th>Record</th><th>Statuses</th><th>Fields</th><th>Menu</th><th /></tr></thead>
              <tbody>
                {types.map((t) => (
                  <tr key={t.id}>
                    <td><strong>{t.plural}</strong><small>{t.singular}</small></td>
                    <td>{t.statuses.map((s) => s.label).join(", ")}</td>
                    <td>{t.fields.map((f) => f.label).join(", ")}</td>
                    <td>{t.enabled ? <Pill tone="success">Shown</Pill> : <Pill>Hidden</Pill>}</td>
                    <td className="ba-actions"><button type="button" className="ba-btn sm" onClick={() => setEditing(t)}>Edit</button></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
      {editing && <TypeEditor workspace={workspace} type={editing === "new" ? null : editing} onClose={() => setEditing(null)} onSaved={(m) => { setEditing(null); onNotice(m); onChanged(); }} />}
    </>
  );
}
