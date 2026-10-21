import { useCallback, useEffect, useMemo, useState } from "react";
import "./OwnerPages.css";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { formatDate } from "./ownerFormat";

const TERM_ROWS = [
  { singular: "customer", plural: "customers", label: "Customers", hint: "People the business serves" },
  { singular: "staff", plural: "staff_plural", label: "Staff", hint: "People who deliver the service" },
  { singular: "service", plural: "services", label: "Services", hint: "What the business offers" },
  { singular: "appointment", plural: "appointments", label: "Appointments", hint: "Booked time slots" },
  { singular: "job", plural: "jobs", label: "Jobs", hint: "Work performed" },
  { singular: "visit", plural: "visits", label: "Visits", hint: "Each visit or service call" },
];

const VOICE_FIELDS = [
  ["caller_role", "Caller is called", "e.g. Patient"],
  ["staff_role", "Staff is called", "e.g. Provider"],
  ["booking_action", "A booking is called", "e.g. Appointment"],
  ["primary_service", "Main service", "e.g. Treatment"],
];

function toDraft(industry) {
  return {
    description: industry.description || "",
    terminology: structuredClone(industry.terminology || {}),
    modules: (industry.modules || []).map((m) => ({
      id: m.id,
      name: m.name,
      description: m.description || "",
      isActive: m.is_active,
      slug: m.slug,
    })),
  };
}

function ModuleRow({ module, onChange, onRemove }) {
  return (
    <div className={`ic-module ${module.isActive ? "" : "off"}`}>
      <div className="ic-module-fields">
        <input
          aria-label="Module name"
          value={module.name}
          placeholder="Module name"
          onChange={(e) => onChange({ ...module, name: e.target.value })}
        />
        <input
          aria-label="Module description"
          value={module.description}
          placeholder="Short description (optional)"
          onChange={(e) => onChange({ ...module, description: e.target.value })}
        />
      </div>
      <div className="ic-module-side">
        {module.id ? (
          <>
            <span className="op-muted">{module.isActive ? "Offered" : "Not offered"}</span>
            <button
              type="button"
              role="switch"
              aria-checked={module.isActive}
              aria-label={`Offer ${module.name || "module"}`}
              className={`wiz-toggle ${module.isActive ? "on" : ""}`}
              onClick={() => onChange({ ...module, isActive: !module.isActive })}
            >
              <span />
            </button>
          </>
        ) : (
          <>
            <Pill tone="info">New</Pill>
            <button type="button" className="wiz-link-danger" onClick={onRemove}>Remove</button>
          </>
        )}
      </div>
    </div>
  );
}

export default function IndustryConfiguration() {
  const [industries, setIndustries] = useState([]);
  const [selectedId, setSelectedId] = useState(null);
  const [draft, setDraft] = useState(null);
  const [pendingId, setPendingId] = useState(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [creating, setCreating] = useState(false);
  const [newIndustry, setNewIndustry] = useState({ name: "", description: "", copyFromId: "" });
  const [filter, setFilter] = useState("");

  const selected = industries.find((i) => i.id === selectedId) || null;

  const load = useCallback(async (keepId) => {
    setLoading(true);
    setError("");
    try {
      const data = await callOwnerFunction("industries_list");
      setIndustries(data.industries);
      const next = data.industries.find((i) => i.id === keepId) || data.industries[0] || null;
      setSelectedId(next?.id ?? null);
      setDraft(next ? toDraft(next) : null);
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load(null);
  }, [load]);

  const dirty = useMemo(() => {
    if (!selected || !draft) return false;
    return JSON.stringify(toDraft(selected)) !== JSON.stringify(draft);
  }, [selected, draft]);

  function select(id) {
    if (id === selectedId) return;
    if (dirty) {
      setPendingId(id);
      return;
    }
    const industry = industries.find((i) => i.id === id);
    setSelectedId(id);
    setDraft(toDraft(industry));
    setNotice("");
    setError("");
    setCreating(false);
  }

  function discardAndSwitch() {
    const industry = industries.find((i) => i.id === pendingId);
    setSelectedId(pendingId);
    setDraft(toDraft(industry));
    setPendingId(null);
    setNotice("");
  }

  const setTerm = (key, value) =>
    setDraft((d) => ({ ...d, terminology: { ...d.terminology, [key]: value } }));

  const setVoice = (key, value) =>
    setDraft((d) => ({
      ...d,
      terminology: { ...d.terminology, voice: { ...(d.terminology.voice || {}), [key]: value } },
    }));

  const setModule = (index, module) =>
    setDraft((d) => ({ ...d, modules: d.modules.map((m, i) => (i === index ? module : m)) }));

  async function save() {
    setSaving(true);
    setError("");
    setNotice("");
    try {
      await callOwnerFunction("industry_save", {
        industryId: selectedId,
        description: draft.description,
        terminology: draft.terminology,
        modules: draft.modules,
      });
      setNotice(`${selected.name} saved.`);
      await load(selectedId);
    } catch (err) {
      setError(err.message);
    } finally {
      setSaving(false);
    }
  }

  async function create(event) {
    event.preventDefault();
    setSaving(true);
    setError("");
    try {
      const data = await callOwnerFunction("industry_create", newIndustry);
      setCreating(false);
      setNewIndustry({ name: "", description: "", copyFromId: "" });
      setNotice(`${data.name} created${data.modules ? ` with ${data.modules} modules` : ""}.`);
      await load(data.industryId);
    } catch (err) {
      setError(err.message);
    } finally {
      setSaving(false);
    }
  }

  const visible = industries.filter((i) => i.name.toLowerCase().includes(filter.trim().toLowerCase()));
  const terms = draft?.terminology || {};
  const voice = terms.voice || {};
  const activeModules = draft?.modules.filter((m) => m.isActive).length ?? 0;

  return (
    <section className="owner-page">
      <div className="owner-page-heading">
        <div>
          <div className="owner-eyebrow">CONFIGURATION</div>
          <h1>Industry configuration</h1>
          <p>Default terminology, AI voice wording and CRM modules each industry starts with.</p>
        </div>
        <button
          type="button"
          className="owner-primary-button"
          onClick={() => {
            setCreating(true);
            setNotice("");
            setError("");
          }}
          disabled={saving}
        >
          ＋ New industry
        </button>
      </div>

      {notice && <div className="ic-notice" role="status">{notice}</div>}
      {error && <div className="owner-form-error op-gap" role="alert">{error}</div>}

      <div className="ic-layout">
        <aside className="owner-panel ic-list">
          <div className="ic-list-search">
            <input
              value={filter}
              onChange={(e) => setFilter(e.target.value)}
              placeholder="Filter industries"
              aria-label="Filter industries"
            />
          </div>
          {loading && !industries.length ? (
            <div className="op-empty">Loading industries...</div>
          ) : visible.length ? (
            <ul>
              {visible.map((industry) => (
                <li key={industry.id}>
                  <button
                    type="button"
                    className={industry.id === selectedId && !creating ? "active" : ""}
                    onClick={() => select(industry.id)}
                  >
                    <strong>{industry.name}</strong>
                    <span>
                      {industry.businessCount} {industry.businessCount === 1 ? "business" : "businesses"} ·{" "}
                      {industry.modules.filter((m) => m.is_active).length} modules
                    </span>
                  </button>
                </li>
              ))}
            </ul>
          ) : (
            <div className="op-empty">{industries.length ? "No matching industries." : "No industries yet."}</div>
          )}
        </aside>

        <div className="ic-editor">
          {pendingId && (
            <div className="ic-warning">
              <span>You have unsaved changes to {selected?.name}.</span>
              <div>
                <button type="button" className="owner-secondary-button op-small" onClick={() => setPendingId(null)}>
                  Keep editing
                </button>
                <button type="button" className="owner-primary-button op-small" onClick={discardAndSwitch}>
                  Discard and switch
                </button>
              </div>
            </div>
          )}

          {creating ? (
            <form className="wiz-section" onSubmit={create}>
              <div className="wiz-section-head">
                <div>
                  <h3>New industry</h3>
                  <p>Start from an existing industry's terminology and modules, then adjust them.</p>
                </div>
              </div>
              <div className="owner-form-grid">
                <label className="owner-field">
                  <span>Industry name *</span>
                  <input
                    value={newIndustry.name}
                    onChange={(e) => setNewIndustry({ ...newIndustry, name: e.target.value })}
                    placeholder="e.g. Cleaning Services"
                    required
                  />
                </label>
                <label className="owner-field">
                  <span>Copy setup from</span>
                  <select
                    value={newIndustry.copyFromId}
                    onChange={(e) => setNewIndustry({ ...newIndustry, copyFromId: e.target.value })}
                  >
                    <option value="">Start empty</option>
                    {industries.map((i) => <option key={i.id} value={i.id}>{i.name}</option>)}
                  </select>
                </label>
                <label className="owner-field wiz-field-full">
                  <span>Description</span>
                  <input
                    value={newIndustry.description}
                    onChange={(e) => setNewIndustry({ ...newIndustry, description: e.target.value })}
                  />
                </label>
              </div>
              <div className="ic-actions">
                <button type="button" className="owner-secondary-button" onClick={() => setCreating(false)} disabled={saving}>
                  Cancel
                </button>
                <button type="submit" className="owner-primary-button" disabled={saving || !newIndustry.name.trim()}>
                  {saving ? "Creating..." : "Create industry"}
                </button>
              </div>
            </form>
          ) : !selected || !draft ? (
            <div className="owner-panel"><div className="op-empty">{loading ? "Loading..." : "Select an industry."}</div></div>
          ) : (
            <>
              <div className="ic-head">
                <div>
                  <h2>{selected.name}</h2>
                  <span className="op-muted">
                    {selected.businessCount} {selected.businessCount === 1 ? "business uses" : "businesses use"} this industry
                    {selected.configUpdatedAt ? ` · updated ${formatDate(selected.configUpdatedAt)}` : ""}
                  </span>
                </div>
              </div>

              {selected.businessCount > 0 && (
                <div className="wiz-note">
                  <strong>How changes apply:</strong> terminology changes show up straight away for businesses in this
                  industry that haven't customised that word. Words a business has customised stay as they are.
                  Module changes only affect what's offered during setup; businesses keep the modules they already have.
                </div>
              )}

              <section className="wiz-section">
                <div className="wiz-section-head">
                  <div>
                    <h3>Description</h3>
                  </div>
                </div>
                <input
                  className="ic-input"
                  value={draft.description}
                  onChange={(e) => setDraft({ ...draft, description: e.target.value })}
                  placeholder="What kind of businesses this covers"
                />
              </section>

              <section className="wiz-section">
                <div className="wiz-section-head">
                  <div>
                    <h3>CRM terminology</h3>
                    <p>The default words every business in this industry sees. Empty boxes fall back to generic words.</p>
                  </div>
                </div>
                <div className="wiz-term-table">
                  <div className="wiz-term-head"><span>Term</span><span>Singular</span><span>Plural</span></div>
                  {TERM_ROWS.map((row) => (
                    <div className="wiz-term-row" key={row.singular}>
                      <div>
                        <strong>{row.label}</strong>
                        <small>{row.hint}</small>
                      </div>
                      {[row.singular, row.plural].map((key) => (
                        <input
                          key={key}
                          aria-label={`${row.label} ${key === row.singular ? "singular" : "plural"}`}
                          value={terms[key] || ""}
                          onChange={(e) => setTerm(key, e.target.value)}
                        />
                      ))}
                    </div>
                  ))}
                </div>
              </section>

              <section className="wiz-section">
                <div className="wiz-section-head">
                  <div>
                    <h3>AI receptionist defaults</h3>
                    <p>Starting wording for new businesses' receptionists. Each business can change its own greeting.</p>
                  </div>
                </div>
                <div className="owner-form-grid">
                  <label className="owner-field wiz-field-full">
                    <span>Default greeting</span>
                    <textarea
                      value={voice.greeting || ""}
                      onChange={(e) => setVoice("greeting", e.target.value)}
                      placeholder="Thank you for calling. How can I help you today?"
                    />
                  </label>
                  {VOICE_FIELDS.map(([key, label, placeholder]) => (
                    <label key={key} className="owner-field">
                      <span>{label}</span>
                      <input value={voice[key] || ""} placeholder={placeholder} onChange={(e) => setVoice(key, e.target.value)} />
                    </label>
                  ))}
                </div>
              </section>

              <section className="wiz-section">
                <div className="wiz-section-head">
                  <div>
                    <h3>Modules</h3>
                    <p>Modules offered to businesses in this industry. Switch one off to stop offering it; modules are never deleted.</p>
                  </div>
                  <Pill>{activeModules} offered</Pill>
                </div>
                <div className="ic-modules">
                  {draft.modules.length === 0 && <div className="wiz-empty">No modules yet.</div>}
                  {draft.modules.map((module, index) => (
                    <ModuleRow
                      key={module.id || `new-${index}`}
                      module={module}
                      onChange={(m) => setModule(index, m)}
                      onRemove={() => setDraft({ ...draft, modules: draft.modules.filter((_, i) => i !== index) })}
                    />
                  ))}
                </div>
                <button
                  type="button"
                  className="owner-secondary-button op-gap-top"
                  onClick={() => setDraft({ ...draft, modules: [...draft.modules, { name: "", description: "", isActive: true }] })}
                >
                  ＋ Add module
                </button>
              </section>

              <div className="wiz-footer">
                <span className="op-muted">{dirty ? "Unsaved changes" : "All changes saved"}</span>
                <div className="wiz-footer-right">
                  <button
                    type="button"
                    className="owner-secondary-button"
                    onClick={() => setDraft(toDraft(selected))}
                    disabled={!dirty || saving}
                  >
                    Discard
                  </button>
                  <button type="button" className="owner-primary-button" onClick={save} disabled={!dirty || saving}>
                    {saving ? "Saving..." : "Save changes"}
                  </button>
                </div>
              </div>
            </>
          )}
        </div>
      </div>
    </section>
  );
}
