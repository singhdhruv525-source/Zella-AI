import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import "./OwnerPages.css";
import "./IndustryConfiguration.css";
import { Icon } from "./BusinessUI";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { formatDate } from "./ownerFormat";
import IndustryRecords from "./IndustryRecords";
import { ReasonDialog, friendlyError } from "./admin/adminOps";
import { businessWord, modulesLosingUsers, readIndustriesAnswer, switchesOff } from "./industryModules";
import { CATALOG } from "./automationCatalog";
import { emptyAutomations } from "./industryAutomations";

// CFG-05: how each industry books (industries.booking_model), in words.
const BOOKING_LABELS = {
  staff_appointment: "Appointments with a team member", class: "Classes", table: "Table reservations", stay: "Stays",
  consultation: "Consultations", viewing: "Viewings", field_job: "Jobs at the customer's place", none: "No bookings (orders only)", general: "General appointments",
};

const TERM_ROWS = [
  { singular: "customer", plural: "customers", label: "Customers", hint: "People the business serves" },
  { singular: "staff", plural: "staff_plural", label: "Staff", hint: "People who deliver the service" },
  { singular: "service", plural: "services", label: "Services", hint: "What the business offers" },
  { singular: "appointment", plural: "appointments", label: "Appointments", hint: "Booked time slots" },
  { singular: "job", plural: "jobs", label: "Jobs", hint: "Work performed" },
  { singular: "visit", plural: "visits", label: "Visits", hint: "Each visit or service call" },
];

const VOICE_FIELDS = [
  ["caller_role", "Caller is called", "For example, Patient"],
  ["staff_role", "Staff is called", "For example, Provider"],
  ["booking_action", "A booking is called", "For example, Appointment"],
  ["primary_service", "Main service", "For example, Treatment"],
];

function toDraft(industry) {
  return {
    description: industry.description || "",
    bookingModel: industry.bookingModel ?? "",
    automationDefaults: industry.automationDefaults ? structuredClone(industry.automationDefaults) : null,
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

function ModuleRow({ module, users, onChange, onRemove }) {
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
            <span className="op-muted">
              {module.isActive ? "Offered" : "Not offered"}
              {users !== undefined && `, ${users ? `on for ${businessWord(users)}` : "no business has it on"}`}
            </span>
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
  const [loadFailed, setLoadFailed] = useState(false);   // the list didn't load: not the same as "no industries"
  const [selectedId, setSelectedId] = useState(null);
  const [draft, setDraftState] = useState(null);
  const [pendingId, setPendingId] = useState(null);
  const [pendingReload, setPendingReload] = useState(false);   // Try again would replace unsaved changes: ask first
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [creating, setCreating] = useState(false);
  const [newIndustry, setNewIndustry] = useState({ name: "", description: "", copyFromId: "" });
  const [filter, setFilter] = useState("");
  const [usageRead, setUsageRead] = useState({ id: null, at: null, modules: null });   // module id -> businesses with it on
  const [usageTick, setUsageTick] = useState(0);   // a refused switch off counts again, keeping the draft
  const [confirm, setConfirm] = useState(null);       // { kind: "modules" | "active" | "sensitive", ... }
  const [me, setMe] = useState(null);
  const [industryData, setIndustryData] = useState(false);   // the industry data migration is applied
  useEffect(() => {
    let live = true;
    callOwnerFunction("me_admin").then((m) => live && setMe(m)).catch(() => live && setMe(null));
    return () => { live = false; };
  }, []);

  const selected = industries.find((i) => i.id === selectedId) || null;

  // Counts what the person does in the editor (edits and switching industry), so a list answer that arrives after
  // they changed something never replaces their work.
  const changesRef = useRef(0);
  const selectedRef = useRef(null);
  useEffect(() => { selectedRef.current = selectedId; }, [selectedId]);
  const setDraft = (value) => {
    changesRef.current += 1;
    setDraftState(value);
  };

  const load = useCallback(async (keepId) => {
    const changesAtStart = changesRef.current;
    setLoading(true);
    setError("");
    try {
      const data = readIndustriesAnswer(await callOwnerFunction("industries_list"));
      if (!data) throw new Error("EMPTY_ANSWER");
      setIndustries(data.industries);
      setIndustryData(data.industryData);
      setLoadFailed(false);
      // Changed while this was loading: keep the open industry and its draft as they are, if it is still in the list.
      if (changesRef.current !== changesAtStart && data.industries.some((i) => i.id === selectedRef.current)) return;
      const next = data.industries.find((i) => i.id === keepId) || data.industries[0] || null;
      setSelectedId(next?.id ?? null);
      setDraftState(next ? toDraft(next) : null);
    } catch {
      // One plain message with Try again in the list (A40, A41), never the raw error text.
      setLoadFailed(true);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load(null);
  }, [load]);

  // Per module counts for the open industry (read in pages on the server, so they stay right past 1,000 rows).
  useEffect(() => {
    if (!selectedId) return undefined;
    let live = true;
    callOwnerFunction("industry_module_usage", { industryId: selectedId })
      // a missing or malformed answer is "couldn't count", never "no business uses it"
      .then((data) => live && setUsageRead({ id: selectedId, at: industries, tick: usageTick,
        modules: data?.modules && typeof data.modules === "object" && !Array.isArray(data.modules) ? data.modules : undefined }))
      .catch(() => live && setUsageRead({ id: selectedId, at: industries, tick: usageTick, modules: undefined }));
    return () => { live = false; };
  }, [selectedId, industries, usageTick]);
  // null while counting, undefined when the count failed
  const usage = usageRead.id === selectedId && usageRead.at === industries && usageRead.tick === usageTick ? usageRead.modules : null;

  const dirty = useMemo(() => {
    if (!selected || !draft) return false;
    return JSON.stringify(toDraft(selected)) !== JSON.stringify(draft);
  }, [selected, draft]);

  function select(id) {
    if (id === selectedId) return;
    if (dirty) {
      setPendingReload(false);
      setPendingId(id);
      return;
    }
    const industry = industries.find((i) => i.id === id);
    changesRef.current += 1;
    setSelectedId(id);
    setDraftState(toDraft(industry));
    setNotice("");
    setError("");
    setCreating(false);
  }

  function discardAndSwitch() {
    const industry = industries.find((i) => i.id === pendingId);
    changesRef.current += 1;
    setSelectedId(pendingId);
    setDraftState(toDraft(industry));
    setPendingId(null);
    setNotice("");
  }

  // Try again after a failed refresh: a successful answer replaces the open draft, so unsaved changes are confirmed first.
  function retry() {
    if (dirty) {
      setPendingId(null);
      setPendingReload(true);
      return;
    }
    load(selectedId);
  }

  function discardAndReload() {
    setPendingReload(false);
    setNotice("");
    load(selectedId);
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

  function save() {
    setError("");
    setNotice("");
    const switchingOff = switchesOff(selected.modules, draft.modules);
    if (switchingOff && usage === undefined) return setError("Couldn't count the businesses using these modules. Reload the page before switching one off.");
    if (switchingOff && usage === null) return setError("Still counting the businesses using these modules. Try again in a moment.");
    const losing = modulesLosingUsers(selected.modules, draft.modules, usage);
    if (losing.length) return setConfirm({ kind: "modules", losing });
    return send([], "").catch((err) => {
      // 409: businesses started using a module since it was counted. Count again (the draft stays), so the next Save
      // shows who loses it and asks for confirmation.
      if (err?.status === 409) {
        setUsageTick((t) => t + 1);
        return setError("Some businesses have started using a module you are switching off. Save again to see who loses it.");
      }
      return setError(friendlyError(err));
    });
  }

  // Errors go back to the caller: the confirm dialog shows them in place, a plain save shows them on the page.
  async function send(confirmOff, reason) {
    setSaving(true);
    try {
      await callOwnerFunction("industry_save", {
        industryId: selectedId,
        description: draft.description,
        terminology: draft.terminology,
        modules: draft.modules,
        confirmOff,
        reason,
        ...(industryData ? { bookingModel: draft.bookingModel || null, automationDefaults: draft.automationDefaults } : {}),
      });
      setNotice(`${selected.name} saved.`);
      await load(selectedId);
    } finally {
      setSaving(false);
    }
  }

  async function setSensitive(sensitive, reason) {
    const data = await callOwnerFunction("industry_set_sensitive", { industryId: selectedId, sensitive, reason, confirm: true });
    setNotice(`${data.name} is ${sensitive ? "sensitive: staff never see call transcripts" : "no longer sensitive: staff may see call transcripts where the owner allows"}.`);
    await load(selectedId);
  }

  async function setActive(active, reason) {
    const data = await callOwnerFunction("industry_set_active", { industryId: selectedId, active, reason });
    setNotice(`${data.name} is ${active ? "active again and offered for new businesses" : "inactive. It isn't offered for new businesses"}.`);
    await load(selectedId);
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
      setError(friendlyError(err));
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
          <div className="owner-eyebrow">Configuration</div>
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
          <Icon name="add" size="sm" />New industry
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
            <div className="op-empty">Loading industries…</div>
          ) : loadFailed && !loading ? (
            <div className="op-empty" role="alert">
              Industries didn't load.{" "}
              <button type="button" className="owner-secondary-button" onClick={retry}>Try again</button>
            </div>
          ) : visible.length ? (
            <ul>
              {visible.map((industry) => (
                <li key={industry.id}>
                  <button
                    type="button"
                    className={industry.id === selectedId && !creating ? "active" : ""}
                    onClick={() => select(industry.id)}
                  >
                    <strong>{industry.name}{!industry.is_active && <> <Pill tone="warning">Inactive</Pill></>}</strong>
                    <span>
                      {businessWord(industry.businessCount)},{" "}
                      {industry.modules.filter((m) => m.is_active).length} modules
                    </span>
                  </button>
                </li>
              ))}
            </ul>
          ) : (
            <div className="op-empty">{industries.length ? "No matching industries." : (
              <>No industries yet.{" "}<button type="button" className="owner-secondary-button op-small" disabled={saving} onClick={() => { setCreating(true); setNotice(""); setError(""); }}>New industry</button></>
            )}</div>
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

          {pendingReload && dirty && (
            <div className="ic-warning">
              <span>You have unsaved changes to {selected?.name}. Loading the list again replaces them.</span>
              <div>
                <button type="button" className="owner-secondary-button op-small" onClick={() => setPendingReload(false)}>
                  Keep editing
                </button>
                <button type="button" className="owner-primary-button op-small" onClick={discardAndReload}>
                  Discard and reload
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
                    placeholder="For example, Cleaning Services"
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
                  {saving ? "Creating…" : "Create industry"}
                </button>
              </div>
            </form>
          ) : !selected || !draft ? (
            (loadFailed && !loading ? null : <div className="owner-panel"><div className="op-empty">{loading ? "Loading…" : "Select an industry."}</div></div>)
          ) : (
            <>
              <header className="ic-detail-head">
                <div className="ic-detail-title">
                  <h2>
                    {selected.name}
                    {!selected.is_active && <Pill tone="warning">Inactive</Pill>}
                  </h2>
                  <p className="ic-detail-meta">
                    {businessWord(selected.businessCount)}
                    {selected.configUpdatedAt ? `, Updated ${formatDate(selected.configUpdatedAt)}` : ""}
                    {!selected.is_active && ", Not offered when a business is created"}
                  </p>
                </div>
                {!selected.is_active && (
                  <div className="ic-detail-actions">
                    {dirty && <span className="ic-disabled-reason">Save or discard your changes first</span>}
                    <button
                      type="button"
                      className="owner-secondary-button"
                      onClick={() => { setNotice(""); setError(""); setConfirm({ kind: "active", active: true }); }}
                      disabled={saving || dirty}
                    >
                      Reactivate
                    </button>
                  </div>
                )}
              </header>

              {selected.businessCount > 0 && (
                <div className="ic-apply" role="note">
                  <Icon name="info" className="ic-apply-icon" />
                  <div>
                    <p>
                      <strong>How changes apply.</strong> New words show up straight away for businesses in this
                      industry, unless a business has customized that word.
                      Switching a module off removes it from every business that has it on, and you see how many before it saves.
                    </p>
                    <details className="ic-apply-more">
                      <summary>More about changes</summary>
                      <p>
                        Words a business has customized stay as they are. Switching a module off removes it at once from
                        every business in this industry that has it on. Switching it back on gives it back to them.
                      </p>
                    </details>
                  </div>
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

              {industryData && (
                <section className="wiz-section">
                  <div className="wiz-section-head">
                    <div>
                      <h3>Privacy and booking</h3>
                      <p>Stored for this industry and read by the server, so a new industry gets them too.</p>
                    </div>
                  </div>
                  <div className="ic-module">
                    <div className="ic-module-fields">
                      <strong>Sensitive industry</strong>
                      <span className="op-muted">{selected.sensitive
                        ? "Staff never see call transcripts in this industry. New industries start sensitive."
                        : "Staff may see call transcripts where the business owner allows it."}</span>
                    </div>
                    <div className="ic-module-side">
                      <Pill tone={selected.sensitive ? "warning" : "neutral"}>{selected.sensitive ? "Sensitive" : "Not sensitive"}</Pill>
                      {me?.role === "zella_owner" ? (
                        <button type="button" className="owner-secondary-button op-small" disabled={saving || dirty}
                          title={dirty ? "Save or discard your changes first" : undefined}
                          onClick={() => { setNotice(""); setError(""); setConfirm({ kind: "sensitive", sensitive: !selected.sensitive }); }}>
                          {selected.sensitive ? "Turn off" : "Turn on"}
                        </button>
                      ) : <span className="op-muted">Only a Zella Voice owner can change this</span>}
                    </div>
                  </div>
                  <label className="owner-field op-gap-top">
                    <span>Booking model</span>
                    <select value={draft.bookingModel} onChange={(e) => setDraft({ ...draft, bookingModel: e.target.value })}>
                      <option value="">Not set</option>
                      {Object.entries(BOOKING_LABELS).map(([k, label]) => <option key={k} value={k}>{label}</option>)}
                    </select>
                  </label>
                </section>
              )}

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
                    <p>Starting wording for new businesses' AI receptionists. Each business can change its own greeting.</p>
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
                    <p>Modules offered to businesses in this industry. Switching one off stops offering it and removes it from every business that has it on. Modules are never deleted.</p>
                  </div>
                  <Pill>{activeModules} offered</Pill>
                </div>
                <div className="ic-modules">
                  {draft.modules.length === 0 && <div className="wiz-empty">No modules yet.</div>}
                  {draft.modules.map((module, index) => (
                    <ModuleRow
                      key={module.id || `new-${index}`}
                      module={module}
                      users={module.id && usage ? usage[module.id] ?? 0 : undefined}
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
                  <Icon name="add" size="sm" />Add module
                </button>
              </section>

              {industryData && (
                <section className="wiz-section">
                  <div className="wiz-section-head">
                    <div>
                      <h3>Default automations</h3>
                      <p>Which automations a new business in this industry starts with. Each business can still change its own.
                        {draft.automationDefaults ? "" : " Not set for this industry, so it uses the standard set below."}</p>
                    </div>
                  </div>
                  <div className="ic-modules">
                    {CATALOG.map(([type, title]) => {
                      const set = draft.automationDefaults ?? emptyAutomations();
                      const on = Boolean(set[type]?.enabled);
                      return (
                        <div key={type} className={`ic-module ${on ? "" : "off"}`}>
                          <div className="ic-module-fields"><strong>{(([c, ...rest]) => c.toUpperCase() + rest.join(""))(title("Appointment"))}</strong></div>
                          <div className="ic-module-side">
                            <span className="op-muted">{on ? "On" : "Off"}</span>
                            <button type="button" role="switch" aria-checked={on} aria-label={`Start new businesses with ${title("appointment")}`}
                              className={`wiz-toggle ${on ? "on" : ""}`}
                              onClick={() => {
                                const next = structuredClone(set);
                                next[type] = { enabled: !on, settings: next[type]?.settings ?? {} };
                                setDraft({ ...draft, automationDefaults: next });
                              }}>
                              <span />
                            </button>
                          </div>
                        </div>
                      );
                    })}
                  </div>
                </section>
              )}

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
                    {saving ? "Saving…" : "Save changes"}
                  </button>
                </div>
              </div>

              <IndustryRecords key={selected.id} industryId={selected.id} industryName={selected.name} />

              {selected.is_active && (
                <section className="wiz-section ic-danger" aria-labelledby="ic-danger-title">
                  <h3 id="ic-danger-title">Danger zone</h3>
                  <div className="ic-danger-row">
                    <div>
                      <strong>Deactivate {selected.name}</strong>
                      <small>
                        It stops being offered when a business is created. The {businessWord(selected.businessCount)} already
                        in it keep working as they are.
                      </small>
                    </div>
                    <div className="ic-danger-action">
                      {dirty && <span className="ic-disabled-reason">Save or discard your changes first</span>}
                      <button
                        type="button"
                        className="owner-secondary-button ic-danger-button"
                        onClick={() => { setNotice(""); setError(""); setConfirm({ kind: "active", active: false }); }}
                        disabled={saving || dirty}
                      >
                        Deactivate
                      </button>
                    </div>
                  </div>
                </section>
              )}

              {confirm?.kind === "modules" && (
                <ReasonDialog
                  title="Switch modules off for every business?"
                  icon="toggle_off"
                  danger
                  confirmLabel="Switch off and save"
                  onClose={() => setConfirm(null)}
                  onConfirm={(reason) => send(confirm.losing.map((m) => m.id), reason)}
                >
                  <p>Saving removes these modules at once from the businesses in {selected.name} that have them on:</p>
                  <ul>
                    {confirm.losing.map((m) => <li key={m.id}><strong>{businessWord(m.businesses)}</strong> lose {m.name}</li>)}
                  </ul>
                  <p>Their data stays. Switching a module back on gives it back to them.</p>
                </ReasonDialog>
              )}
              {confirm?.kind === "sensitive" && (
                <ReasonDialog
                  title={confirm.sensitive ? `Make ${selected.name} sensitive?` : `Turn off sensitive for ${selected.name}?`}
                  icon={confirm.sensitive ? "lock" : "lock_open"}
                  danger={!confirm.sensitive}
                  word={confirm.sensitive ? undefined : "TURN OFF"}
                  confirmLabel={confirm.sensitive ? "Make sensitive" : "Turn off"}
                  onClose={() => setConfirm(null)}
                  onConfirm={(reason) => setSensitive(confirm.sensitive, reason)}
                >
                  {confirm.sensitive
                    ? <p>Staff in the {businessWord(selected.businessCount)} in {selected.name} will no longer see call transcripts.</p>
                    : <p>Staff in the {businessWord(selected.businessCount)} in {selected.name} may then read call transcripts, where each owner allows it. Only do this after checking the industry handles no private health, legal or financial details.</p>}
                </ReasonDialog>
              )}
              {confirm?.kind === "active" && (
                <ReasonDialog
                  title={confirm.active ? `Reactivate ${selected.name}?` : `Deactivate ${selected.name}?`}
                  icon={confirm.active ? "toggle_on" : "toggle_off"}
                  danger={!confirm.active}
                  confirmLabel={confirm.active ? "Reactivate" : "Deactivate"}
                  onClose={() => setConfirm(null)}
                  onConfirm={(reason) => setActive(confirm.active, reason)}
                >
                  {confirm.active
                    ? <p>{selected.name} will be offered again when a business is created.</p>
                    : <p>{selected.name} won't be offered when a business is created. The {businessWord(selected.businessCount)} already in it keep working as they are, with their modules and words.</p>}
                </ReasonDialog>
              )}
            </>
          )}
        </div>
      </div>
    </section>
  );
}
