import { useCallback, useEffect, useState } from "react";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { Icon } from "./BusinessUI";

// Admin control over one business's CRM: which of its industry's modules it has, and which of its industry record
// types (tables, recalls, vehicles ...) are switched on. Module dependencies are checked by the server; switching a
// record type off hides it in the business's CRM and keeps its records.

const NEEDS = { "ai-receptionist": ["calls"], "ai-appointments": ["calendar"], "ai-follow-up": ["automations"], "ai-sales": ["calls"], "ai-support": ["calls"] };

function Switch({ on, label, disabled, onChange }) {
  return (
    <button type="button" role="switch" aria-checked={on} aria-label={label} disabled={disabled} className={`bac-switch ${on ? "on" : ""}`} onClick={() => onChange(!on)}>
      <span />
    </button>
  );
}

export function BusinessModulesCard({ businessId, modules, onSaved }) {
  const [draft, setDraft] = useState(() => Object.fromEntries(modules.map((m) => [m.id, m.enabled])));
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const dirty = modules.some((m) => draft[m.id] !== m.enabled);
  const bySlug = Object.fromEntries(modules.map((m) => [m.slug, m]));

  // Turning a module on turns on what it needs; turning one off is refused while another needs it.
  function toggle(m, on) {
    const next = { ...draft, [m.id]: on };
    if (on) {
      const stack = [m.slug];
      while (stack.length) for (const dep of NEEDS[stack.pop()] ?? []) if (bySlug[dep] && !next[bySlug[dep].id]) { next[bySlug[dep].id] = true; stack.push(dep); }
    }
    setDraft(next);
  }
  const neededBy = (m) => modules.filter((o) => draft[o.id] && (NEEDS[o.slug] ?? []).includes(m.slug));

  async function save() {
    setSaving(true);
    setError("");
    setNotice("");
    try {
      await callOwnerFunction("setup_save_modules", { businessId, enabledModuleIds: modules.filter((m) => draft[m.id]).map((m) => m.id), advance: false });
      setNotice("Modules saved. The business sees the change the next time its CRM loads.");
      await onSaved?.();
    } catch (err) {
      setError(err.message);
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="bac">
      {!modules.length && <div className="op-empty">No modules are offered for this industry. Add them in Industry Configuration.</div>}
      <div className="bac-list">
        {modules.map((m) => {
          const needed = neededBy(m);
          return (
            <div key={m.id} className={`bac-row ${draft[m.id] ? "on" : ""}`}>
              <div>
                <strong>{m.name}</strong>
                <small>{needed.length && draft[m.id] ? `Needed by ${needed.map((n) => n.name).join(", ")}` : m.description || m.slug}</small>
              </div>
              <Switch on={Boolean(draft[m.id])} label={m.name} disabled={saving || (draft[m.id] && needed.length > 0)} onChange={(on) => toggle(m, on)} />
            </div>
          );
        })}
      </div>
      {error && <div className="owner-form-error op-gap-top" role="alert">{error}</div>}
      {notice && <div className="vq-notice op-gap-top" role="status">{notice}</div>}
      {modules.length > 0 && (
        <div className="bac-actions">
          <button type="button" className="owner-secondary-button" disabled={!dirty || saving} onClick={() => setDraft(Object.fromEntries(modules.map((m) => [m.id, m.enabled])))}>Discard</button>
          <button type="button" className="owner-primary-button" disabled={!dirty || saving} onClick={save}>{saving ? "Saving..." : "Save modules"}</button>
        </div>
      )}
    </div>
  );
}

export function BusinessRecordsCard({ businessId }) {
  const [data, setData] = useState(null);
  const [draft, setDraft] = useState({});
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");

  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const d = await callOwnerFunction("business_records_get", { businessId });
      setData(d);
      setDraft(Object.fromEntries(d.types.map((t) => [t.key, t.enabled])));
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }, [businessId]);

  useEffect(() => { load(); }, [load]);

  const dirty = data?.types.some((t) => draft[t.key] !== t.enabled);

  async function save() {
    setSaving(true);
    setError("");
    setNotice("");
    try {
      const r = await callOwnerFunction("business_records_save", { businessId, enabled: draft });
      setNotice(r.changes.length ? `${r.changes.length} record type${r.changes.length === 1 ? "" : "s"} updated.` : "Nothing changed.");
      await load();
    } catch (err) {
      setError(err.message);
    } finally {
      setSaving(false);
    }
  }

  if (loading && !data) return <div className="op-empty">Loading record types...</div>;
  return (
    <div className="bac">
      {error && <div className="owner-form-error" role="alert">{error}</div>}
      {data && !data.types.length && (
        <div className="op-empty">
          {["testing", "ready", "active", "paused"].includes(data.status)
            ? "This business's industry has no record types."
            : "Record types are added when setup is finished."}
        </div>
      )}
      <div className="bac-list">
        {(data?.types ?? []).map((t) => (
          <div key={t.key} className={`bac-row ${draft[t.key] ? "on" : ""}`}>
            <span className="ir-icon"><Icon name={t.icon || "folder"} /></span>
            <div>
              <strong>{t.plural}</strong>
              <small>{t.records} record{t.records === 1 ? "" : "s"}{!draft[t.key] && t.records ? " · kept while hidden" : ""}</small>
            </div>
            {t.preset_key && <Pill>{t.preset_key.replace(/_/g, " ")}</Pill>}
            <Switch on={Boolean(draft[t.key])} label={t.plural} disabled={saving} onChange={(on) => setDraft({ ...draft, [t.key]: on })} />
          </div>
        ))}
      </div>
      {notice && <div className="vq-notice op-gap-top" role="status">{notice}</div>}
      {data?.types.length > 0 && (
        <div className="bac-actions">
          <button type="button" className="owner-secondary-button" disabled={!dirty || saving} onClick={() => setDraft(Object.fromEntries(data.types.map((t) => [t.key, t.enabled])))}>Discard</button>
          <button type="button" className="owner-primary-button" disabled={!dirty || saving} onClick={save}>{saving ? "Saving..." : "Save record types"}</button>
        </div>
      )}
    </div>
  );
}
