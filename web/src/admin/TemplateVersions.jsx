import { useState } from "react";
import { ReasonDialog, rpc } from "./adminOps";

// Messaging > Templates (UI-20): make an industry or Spanish version of a platform template, or retire one, so
// senders fall back to the platform version. The English platform version every sender uses can't be retired. The
// database checks the permission (comms.manage), the wording and the variables again and audits each change.

export const LOCALES = [["en-US", "English"], ["es-US", "Spanish"]];
// Retiring is for overrides only: an industry version, or a platform version in another language.
export const canRetire = (t) => t.scope === "industry" || (t.scope === "platform" && t.locale !== "en-US");

export function NewVersion({ t, industries, onDone, onCancel }) {
  const [industry, setIndustry] = useState("");
  const [locale, setLocale] = useState("en-US");
  const [subject, setSubject] = useState(t.subject ?? "");
  const [body, setBody] = useState(t.body);
  const [confirm, setConfirm] = useState(false);
  const same = !industry && locale === t.locale;
  const label = `${industry ? `${industries.find((i) => i.id === industry)?.name ?? "Industry"} businesses` : "every business"} in ${LOCALES.find(([k]) => k === locale)?.[1]}`;
  return (
    <section className="ao-new-version" aria-label="New version">
      <h3 className="ao-h3">New version of {t.key}</h3>
      <label className="owner-field"><span>For</span>
        <select value={industry} onChange={(e) => setIndustry(e.target.value)}>
          <option value="">All businesses</option>
          {industries.map((i) => <option key={i.id} value={i.id}>{i.name} businesses</option>)}
        </select>
      </label>
      <label className="owner-field"><span>Language</span>
        <select value={locale} onChange={(e) => setLocale(e.target.value)}>{LOCALES.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select>
      </label>
      {t.channel === "email" && <label className="owner-field"><span>Subject</span><input value={subject} onChange={(e) => setSubject(e.target.value)} /></label>}
      <label className="owner-field"><span>Message</span><textarea rows={6} value={body} maxLength={1600} onChange={(e) => setBody(e.target.value)} /></label>
      {same && <p className="op-muted">Choose an industry or another language: this one is the platform version itself.</p>}
      <div className="ao-drawer-actions">
        <button type="button" className="owner-secondary-button" onClick={onCancel}>Cancel</button>
        <button type="button" className="owner-primary-button" disabled={same || !body.trim()} onClick={() => setConfirm(true)}>Create version</button>
      </div>
      {confirm && (
        <ReasonDialog title={`Create ${t.key} for ${label}?`} icon="add" confirmLabel="Create" onClose={() => setConfirm(false)}
          onConfirm={async (reason) => {
            await rpc("zella_admin_template_create", { p_key: t.key, p_channel: t.channel, p_industry: industry || null, p_locale: locale, p_subject: subject, p_body: body, p_reason: reason });
            onDone(`Created. Messages to ${label} use it from now on.`);
          }}>
          <p>Senders use it for {label}, unless a business has its own copy.</p>
        </ReasonDialog>
      )}
    </section>
  );
}

export function RetireVersion({ t, onDone, onClose }) {
  return (
    <ReasonDialog title={`Retire ${t.key}${t.scope === "industry" ? ` for ${t.industry_name}` : ` in ${t.locale}`}?`} icon="archive" danger confirmLabel="Retire" onClose={onClose}
      onConfirm={async (reason) => { await rpc("zella_admin_template_retire", { p_id: t.id, p_reason: reason }); onDone("Retired. Those messages use the platform version from now on."); }}>
      <p>It is archived, not deleted. {t.scope === "industry" ? `${t.industry_name} businesses` : "Messages in this language"} fall back to the platform version.</p>
    </ReasonDialog>
  );
}
