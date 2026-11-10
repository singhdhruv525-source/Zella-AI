import { useCallback, useEffect, useMemo, useState } from "react";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { Icon } from "./BusinessUI";
import { friendlyError } from "./admin/adminOps";

// Industry records: the record types a business in this industry gets in its CRM, beyond customers and bookings
// (a restaurant's tables and events, a dental practice's recalls, a garage's vehicles). Kept per industry in
// industry_crm_presets. New types reach existing businesses of the industry the next time their CRM opens; a
// business's own copy of an existing type is never overwritten, so its records and customisations are safe.
// Keys are fixed once saved, because businesses' records refer to them.

const FIELD_TYPES = [["text", "Short text"], ["longtext", "Long text"], ["number", "Number"], ["date", "Date"], ["datetime", "Date and time"], ["select", "Choice"], ["phone", "Phone"], ["bool", "Yes / no"]];
const TONES = [["", "Grey"], ["info", "Blue"], ["success", "Green"], ["warning", "Amber"], ["danger", "Red"]];
const keyFrom = (label) => label.toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "").replace(/^(\d)/, "x_$1").slice(0, 40);

const blankType = () => ({ key: "", singular: "", plural: "", icon: "folder", title_label: "Name", link_person: true, notice: "", fields: [], statuses: [{ key: "open", label: "Open", tone: "info" }, { key: "closed", label: "Closed", tone: "" }], closed_statuses: ["closed"], columns: [], isNew: true });

function withEditState(types) {
  return types.map((t) => ({
    ...t, notice: t.notice ?? "", title_label: t.title_label ?? "Name", link_person: t.link_person !== false,
    fields: (t.fields ?? []).map((f) => ({ ...f, optionsText: (f.options ?? []).join(", ") })),
    statuses: t.statuses ?? [], closed_statuses: t.closed_statuses ?? [], columns: t.columns ?? [],
  }));
}

function forSave(types) {
  return types.map((t) => ({
    key: t.key || keyFrom(t.plural || t.singular), singular: t.singular, plural: t.plural, icon: t.icon, title_label: t.title_label,
    link_person: t.link_person, notice: t.notice,
    fields: t.fields.map((f) => ({ key: f.key || keyFrom(f.label), label: f.label, type: f.type, required: Boolean(f.required), unique: Boolean(f.unique),
      ...(f.type === "select" ? { options: f.optionsText.split(",").map((o) => o.trim()).filter(Boolean) } : {}) })),
    statuses: t.statuses.map((s) => ({ key: s.key || keyFrom(s.label), label: s.label, tone: s.tone })),
    closed_statuses: t.closed_statuses, columns: t.columns,
  }));
}

export default function IndustryRecords({ industryId, industryName }) {
  const [data, setData] = useState(null);
  const [types, setTypes] = useState([]);
  const [open, setOpen] = useState(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");

  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const d = await callOwnerFunction("industry_records_get", { industryId });
      setData(d);
      setTypes(withEditState(d.types));
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setLoading(false);
    }
  }, [industryId]);

  useEffect(() => { load(); }, [load]);

  const dirty = useMemo(() => data && JSON.stringify(forSave(types)) !== JSON.stringify(forSave(withEditState(data.types))), [data, types]);
  const setType = (i, patch) => setTypes(types.map((t, n) => (n === i ? { ...t, ...patch } : t)));
  const setField = (i, j, patch) => setType(i, { fields: types[i].fields.map((f, n) => (n === j ? { ...f, ...patch } : f)) });
  const setStatus = (i, j, patch) => setType(i, { statuses: types[i].statuses.map((s, n) => (n === j ? { ...s, ...patch } : s)) });
  const toggleIn = (list, key, on) => (on ? [...new Set([...list, key])] : list.filter((k) => k !== key));

  async function save() {
    setSaving(true);
    setError("");
    setNotice("");
    try {
      const r = await callOwnerFunction("industry_records_save", { industryId, types: forSave(types) });
      setNotice(r.created ? `${industryName} now has its own record types.` : "Record types saved.");
      await load();
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setSaving(false);
    }
  }

  return (
    <section className="wiz-section ir">
      <div className="wiz-section-head">
        <div>
          <h3>Industry records</h3>
          <p>What businesses in this industry keep track of besides customers and bookings, with their own fields and statuses.</p>
        </div>
        {data && <Pill tone={data.usesGeneral ? "warning" : "info"}>{data.usesGeneral ? "Using the general set" : `${types.length} record types`}</Pill>}
      </div>

      {loading && !data && <div className="op-empty">Loading record types...</div>}
      {error && <div className="owner-form-error op-gap" role="alert">{error}</div>}
      {notice && <div className="vq-notice op-gap" role="status">{notice}</div>}

      {data && (
        <>
          {data.usesGeneral && <div className="wiz-note">This industry has no record types of its own, so its businesses get the general set shown below. Saving gives {industryName} its own copy to change.</div>}
          {data.sharedWith.length > 0 && <div className="wiz-note"><strong>Shared:</strong> {data.sharedWith.join(", ")} use{data.sharedWith.length === 1 ? "s" : ""} the same record types. Changes here apply to them too.</div>}
          {data.businesses > 0 && <div className="wiz-note">New record types appear for this industry's {data.businesses} business{data.businesses === 1 ? "" : "es"} the next time their CRM opens. Changes to an existing type apply to new businesses; a business's own copy is never overwritten.</div>}

          <div className="ir-list">
            {types.map((t, i) => (
              <div key={t.key || `new-${i}`} className={`ir-type ${open === i ? "open" : ""}`}>
                <button type="button" className="ir-type-head" onClick={() => setOpen(open === i ? null : i)} aria-expanded={open === i}>
                  <span className="ir-icon"><Icon name={t.icon || "folder"} /></span>
                  <span className="ir-type-title">
                    <strong>{t.plural || "New record type"}</strong>
                    <small>{t.fields.length} field{t.fields.length === 1 ? "" : "s"} · {t.statuses.length} status{t.statuses.length === 1 ? "" : "es"}{t.isNew ? " · not saved yet" : ` · key ${t.key}`}</small>
                  </span>
                  <span className="ir-chevron" aria-hidden="true">›</span>
                </button>

                {open === i && (
                  <div className="ir-body">
                    <div className="owner-form-grid">
                      <label className="owner-field"><span>Singular</span><input value={t.singular} onChange={(e) => setType(i, { singular: e.target.value })} placeholder="e.g. Table" /></label>
                      <label className="owner-field"><span>Plural</span><input value={t.plural} onChange={(e) => setType(i, { plural: e.target.value })} placeholder="e.g. Tables" /></label>
                      <label className="owner-field"><span>Icon</span><input value={t.icon} onChange={(e) => setType(i, { icon: e.target.value.trim() })} placeholder="table_restaurant" /><small className="wiz-hint">A Material Symbols name. Preview: <Icon name={t.icon || "folder"} size="sm" /></small></label>
                      <label className="owner-field"><span>Each record's name is called</span><input value={t.title_label} onChange={(e) => setType(i, { title_label: e.target.value })} /></label>
                      <label className="owner-field wiz-field-full"><span>Notice shown on the page</span><input value={t.notice} onChange={(e) => setType(i, { notice: e.target.value })} placeholder="e.g. Keep clinical records in your practice system." /></label>
                      <label className="wiz-inline-check"><input type="checkbox" checked={t.link_person} onChange={(e) => setType(i, { link_person: e.target.checked })} /> Records can be linked to a customer</label>
                    </div>

                    <h4 className="ir-sub">Fields</h4>
                    <div className="ir-rows">
                      {t.fields.map((f, j) => (
                        <div key={j} className="ir-row">
                          <input aria-label="Field label" value={f.label} placeholder="Label" onChange={(e) => setField(i, j, { label: e.target.value })} />
                          <select aria-label="Field type" value={f.type} onChange={(e) => setField(i, j, { type: e.target.value })}>
                            {FIELD_TYPES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                          </select>
                          {f.type === "select"
                            ? <input aria-label="Choices" value={f.optionsText} placeholder="Choices, separated by commas" onChange={(e) => setField(i, j, { optionsText: e.target.value })} />
                            : <span className="op-muted ir-key">{f.key || keyFrom(f.label) || "—"}</span>}
                          <label className="wiz-inline-check"><input type="checkbox" checked={Boolean(f.required)} onChange={(e) => setField(i, j, { required: e.target.checked })} /> Required</label>
                          <label className="wiz-inline-check"><input type="checkbox" checked={t.columns.includes(f.key || keyFrom(f.label))} onChange={(e) => setType(i, { columns: toggleIn(t.columns, f.key || keyFrom(f.label), e.target.checked) })} /> In list</label>
                          <button type="button" className="wiz-link-danger" onClick={() => setType(i, { fields: t.fields.filter((_, n) => n !== j), columns: t.columns.filter((c) => c !== (f.key || keyFrom(f.label))) })}>Remove</button>
                        </div>
                      ))}
                      <button type="button" className="owner-secondary-button" onClick={() => setType(i, { fields: [...t.fields, { key: "", label: "", type: "text", optionsText: "" }] })}>＋ Add field</button>
                    </div>

                    <h4 className="ir-sub">Statuses</h4>
                    <div className="ir-rows">
                      {t.statuses.map((s, j) => (
                        <div key={j} className="ir-row">
                          <input aria-label="Status label" value={s.label} placeholder="Label" onChange={(e) => setStatus(i, j, { label: e.target.value })} />
                          <select aria-label="Color" value={s.tone} onChange={(e) => setStatus(i, j, { tone: e.target.value })}>
                            {TONES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                          </select>
                          <span className="op-muted ir-key">{s.key || keyFrom(s.label) || "—"}</span>
                          <label className="wiz-inline-check"><input type="checkbox" checked={t.closed_statuses.includes(s.key || keyFrom(s.label))} onChange={(e) => setType(i, { closed_statuses: toggleIn(t.closed_statuses, s.key || keyFrom(s.label), e.target.checked) })} /> Counts as done</label>
                          <span />
                          <button type="button" className="wiz-link-danger" disabled={t.statuses.length < 2} onClick={() => setType(i, { statuses: t.statuses.filter((_, n) => n !== j) })}>Remove</button>
                        </div>
                      ))}
                      <button type="button" className="owner-secondary-button" onClick={() => setType(i, { statuses: [...t.statuses, { key: "", label: "", tone: "" }] })}>＋ Add status</button>
                    </div>

                    <div className="ir-type-foot">
                      <button type="button" className="wiz-link-danger" onClick={() => { setTypes(types.filter((_, n) => n !== i)); setOpen(null); }}>
                        Remove this record type{t.isNew ? "" : " from the industry"}
                      </button>
                      {!t.isNew && <small className="op-muted">Businesses that already have it keep it and its records.</small>}
                    </div>
                  </div>
                )}
              </div>
            ))}
            {!types.length && <div className="wiz-empty">No record types. Businesses in this industry only use customers and bookings.</div>}
          </div>

          <div className="ir-actions">
            <button type="button" className="owner-secondary-button" disabled={types.length >= 12} onClick={() => { setTypes([...types, blankType()]); setOpen(types.length); }}>＋ Add record type</button>
            <span className="ir-grow" />
            <button type="button" className="owner-secondary-button" disabled={!dirty || saving} onClick={() => setTypes(withEditState(data.types))}>Discard</button>
            <button type="button" className="owner-primary-button" disabled={!dirty || saving} onClick={save}>{saving ? "Saving..." : "Save record types"}</button>
          </div>
        </>
      )}
    </section>
  );
}
