import { useCallback, useEffect, useState } from "react";
import { createPortal } from "react-dom";
import "./OwnerPages.css";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { Icon } from "./BusinessUI";
import { humanize } from "./copy/labels";
import { friendlyError } from "./admin/adminOps";

// Admin > Security & Abuse. Spam and abuse across every business: totals, where it's coming from, which businesses
// have protection on, the platform defaults new businesses start with, and platform-wide block rules.
// Senders are masked and no message text, transcript or note is sent to this page; each business reviews its own
// incidents in its CRM. Every change here is checked on the server (security.manage / platform.configure) and audited.

const CHANNEL = { call: "Calls", sms: "Texts", email: "Email", booking: "Bookings", web: "Web", other: "Other" };
const STATUS = {
  new: ["warning", "New"], under_review: ["warning", "Under review"], escalated: ["danger", "Escalated"],
  confirmed_spam: ["danger", "Confirmed spam"], false_positive: ["success", "Not spam"], resolved: ["neutral", "Resolved"],
};
const RISK = { high: "danger", medium: "warning", low: "neutral" };
const ACTION = { allowed: "Allowed", flagged: "Flagged", held: "Held for review", screened: "Screened", restricted: "Restricted", blocked: "Blocked" };
const REASON = {
  blocklisted: "On a block list", allowlisted: "On the allow list", repeat_contact: "Repeated contact", flood: "Flooding", suspicious_link: "Suspicious link", many_links: "Many links",
  spam_phrase: "Spam wording", ai_manipulation: "Tried to manipulate the AI", provider_flag: "Flagged by provider", no_caller_id: "No caller ID",
  booking_limit: "Too many bookings",
};
const POLICY = [
  ["Detection", [
    ["repeat_call_limit", "Calls from one number before flagging", "calls"],
    ["repeat_window_minutes", "…within", "minutes"],
    ["sms_flood_limit", "Texts from one number per hour before flagging", "texts"],
    ["email_flood_limit", "Emails from one sender per hour before flagging", "emails"],
    ["booking_daily_limit", "Online bookings per contact per day", "bookings"],
  ]],
  ["Risk scores", [
    ["medium_score", "Medium risk from score", "points"],
    ["high_score", "High risk from score", "points"],
    ["auto_restrict_hours", "Automatic restriction lasts", "hours"],
  ]],
  ["Alerts and retention", [
    ["calls_per_hour_alert", "Alert admins when a business gets this many calls in an hour", "calls"],
    ["incidents_per_day_alert", "Alert admins when one sender reaches this many contacts in a day", "contacts"],
    ["notify_cooldown_per_hour", "Most high-risk emails to a business per hour", "emails"],
    ["retention_days", "Keep incidents for", "days"],
  ]],
];
const TABS = [["overview", "Overview"], ["incidents", "Incidents"], ["coverage", "Protection by business"], ["policy", "Platform defaults"], ["rules", "Global block rules"], ["automation", "Automation"]];
const when = (v) => (v ? new Date(v).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" }) : "—");

function NotSetUp() {
  return (
    <div className="wiz-note op-gap">
      Spam protection isn't set up in the database yet. Apply <strong>sql/zella_spam_protection.sql</strong> (after a backup); incidents,
      defaults and rules then appear here.
    </div>
  );
}

export default function SecurityAbuse({ permissions, onOpenBusiness }) {
  const can = (p) => !permissions || permissions.includes(p);
  const [tab, setTab] = useState("overview");
  const [days, setDays] = useState(30);
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");

  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      setData(await callOwnerFunction("spam_admin_overview", { days }));
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setLoading(false);
    }
  }, [days]);
  useEffect(() => { load(); }, [load]);

  const t = data?.totals ?? {};
  return (
    <section className="owner-page">
      <div className="owner-page-heading">
        <div>
          <div className="owner-eyebrow">Operations</div>
          <h1>Security &amp; Abuse</h1>
          <p>Spam and abuse across every business. Senders are masked; message text stays with each business.</p>
        </div>
        <div className="op-heading-actions">
          <select className="sa-select" value={days} onChange={(e) => setDays(Number(e.target.value))} aria-label="Period">
            <option value={1}>Last 24 hours</option>
            <option value={7}>Last 7 days</option>
            <option value={30}>Last 30 days</option>
            <option value={90}>Last 90 days</option>
          </select>
          <button type="button" className="owner-secondary-button" onClick={load} disabled={loading}>{loading ? "Loading..." : "↻ Refresh"}</button>
        </div>
      </div>

      {error && <div className="owner-form-error op-gap" role="alert">{error}</div>}
      {notice && <div className="vq-notice op-gap" role="status">{notice}</div>}
      {data && !data.available && <NotSetUp />}

      {data?.available && (
        <>
          <div className="vq-stats sa-stats op-gap">
            {[["Incidents", t.incidents, "gpp_maybe", "warning"], ["Waiting for review", t.open, "pending_actions", "warning"], ["High risk", t.high, "report", "danger"],
              ["Blocked or screened", t.blocked, "block", "danger"], ["Confirmed spam", t.confirmed, "verified", "success"],
              ["Marked not spam", t.false_positive, "undo", "neutral"]].map(([label, n, icon, tone]) => (
              <div key={label} className="vq-stat sa-stat">
                <span className={`vq-stat-icon ${tone}`}><Icon name={icon} /></span>
                <span><strong>{n ?? 0}</strong><small>{label}</small></span>
              </div>
            ))}
          </div>

          <div className="op-tabs" role="tablist">
            {TABS.map(([key, label]) => (
              <button key={key} type="button" role="tab" aria-selected={tab === key} className={tab === key ? "active" : ""} onClick={() => { setTab(key); setNotice(""); }}>{label}</button>
            ))}
          </div>

          {tab === "overview" && <Overview data={data} onOpenBusiness={onOpenBusiness} />}
          {tab === "incidents" && <Incidents days={days} onOpenBusiness={onOpenBusiness} />}
          {tab === "coverage" && <Coverage rows={data.coverage} onOpenBusiness={onOpenBusiness} />}
          {tab === "policy" && <Policy policy={data.policy} canSave={can("platform.configure")} onSaved={(m) => { setNotice(m); load(); }} />}
          {tab === "rules" && <Rules canManage={can("security.manage")} onChanged={setNotice} />}
          {tab === "automation" && <Automation info={data.automation} canSave={can("platform.configure")} onSaved={(m) => { setNotice(m); load(); }} />}
        </>
      )}
    </section>
  );
}

function Overview({ data, onOpenBusiness }) {
  const t = data.totals;
  const reviewed = t.confirmed + t.false_positive;
  return (
    <div className="sa-grid">
      <section className="owner-panel sa-panel">
        <h2>Detection accuracy</h2>
        {reviewed ? (
          <>
            <p className="sa-big">{t.accuracy}%</p>
            <p className="op-muted">
              Of {reviewed} incident{reviewed === 1 ? "" : "s"} businesses reviewed, {t.confirmed} were spam and {t.false_positive} were
              not (false-positive rate {100 - t.accuracy}%). A high false-positive rate means the defaults are too strict.
            </p>
          </>
        ) : (
          <p className="op-muted">No incidents have been reviewed in this period, so there's nothing to measure yet.</p>
        )}
      </section>

      <section className="owner-panel sa-panel">
        <h2>By channel</h2>
        <ul className="sa-list">
          {Object.entries(CHANNEL).map(([key, label]) => (
            <li key={key}><span>{label}</span><strong>{data.by_channel?.[key] ?? 0}</strong></li>
          ))}
        </ul>
      </section>

      <section className="owner-panel sa-panel">
        <h2>Most affected businesses</h2>
        {data.top?.length ? (
          <ul className="sa-list">
            {data.top.map((b) => (
              <li key={b.business_id}>
                <button type="button" className="vq-link" onClick={() => onOpenBusiness(b.business_id)}>{b.name}</button>
                <span className="op-muted">{b.high} high · {b.open} open</span>
                <strong>{b.total}</strong>
              </li>
            ))}
          </ul>
        ) : <p className="op-muted">No incidents in this period.</p>}
      </section>

      <section className="owner-panel sa-panel">
        <h2>Open abuse alerts</h2>
        {data.alerts?.length ? (
          <ul className="sa-list">
            {data.alerts.map((a) => (
              <li key={a.id} className="sa-alert">
                <span>
                  <strong>{a.title}</strong>
                  <small className="op-muted">{a.business_name ? `${a.business_name} · ` : ""}{a.detail} · {when(a.last_seen_at)}</small>
                </span>
                <Pill tone={a.status === "open" ? "warning" : "neutral"}>{a.status}</Pill>
              </li>
            ))}
          </ul>
        ) : <p className="op-muted">No open flood or call-volume alerts. These also appear in Platform Operations.</p>}
      </section>
    </div>
  );
}

function Incidents({ days, onOpenBusiness }) {
  const [filters, setFilters] = useState({ channel: "", status: "", risk_level: "", businessId: "" });
  const [page, setPage] = useState(0);
  const [res, setRes] = useState(null);
  const [error, setError] = useState("");
  const [open, setOpen] = useState(null);

  useEffect(() => {
    let live = true;
    setError("");
    callOwnerFunction("spam_admin_incidents", { days, page, ...filters })
      .then((r) => live && setRes(r))
      .catch((err) => live && setError(friendlyError(err)));
    return () => { live = false; };
  }, [days, page, filters]);

  const set = (k, v) => { setFilters((f) => ({ ...f, [k]: v })); setPage(0); };
  const rows = res?.rows ?? [];
  const pages = Math.max(1, Math.ceil((res?.total ?? 0) / 50));
  return (
    <section className="owner-panel">
      <div className="sa-filters">
        <select value={filters.channel} onChange={(e) => set("channel", e.target.value)} aria-label="Channel">
          <option value="">All channels</option>
          {Object.entries(CHANNEL).map(([k, l]) => <option key={k} value={k}>{l}</option>)}
        </select>
        <select value={filters.status} onChange={(e) => set("status", e.target.value)} aria-label="Status">
          <option value="">All statuses</option>
          {Object.entries(STATUS).map(([k, [, l]]) => <option key={k} value={k}>{l}</option>)}
        </select>
        <select value={filters.risk_level} onChange={(e) => set("risk_level", e.target.value)} aria-label="Risk">
          <option value="">All risk levels</option>
          <option value="high">High</option><option value="medium">Medium</option><option value="low">Low</option>
        </select>
        {filters.businessId && (
          <button type="button" className="owner-secondary-button" onClick={() => set("businessId", "")}>
            {rows[0]?.business_name ?? "This business"} ✕
          </button>
        )}
      </div>
      {error && <div className="owner-form-error" role="alert">{error}</div>}
      <div className="owner-table-wrap">
        <table className="owner-table">
          <thead><tr><th>Business</th><th>Channel</th><th>Sender</th><th>Risk</th><th>Action</th><th>Status</th><th>Last seen</th></tr></thead>
          <tbody>
            {rows.map((r) => {
              const [tone, label] = STATUS[r.status] ?? ["neutral", r.status];
              return (
                <tr key={r.id} className="sa-row" onClick={() => setOpen(r.id)}>
                  <td><button type="button" className="vq-link" onClick={(e) => { e.stopPropagation(); set("businessId", r.business_id); }} title="Show only this business">{r.business_name}</button></td>
                  <td>{CHANNEL[r.channel] ?? r.channel}</td>
                  <td>{r.sender}{r.occurrences > 1 && <small className="op-muted"> ×{r.occurrences}</small>}</td>
                  <td><Pill tone={RISK[r.risk_level]}>{`${r.risk_level} · ${r.risk_score}`}</Pill></td>
                  <td>{ACTION[r.action] ?? r.action}</td>
                  <td><Pill tone={tone}>{label}</Pill></td>
                  <td>{when(r.last_seen_at)}</td>
                </tr>
              );
            })}
            {!rows.length && <tr><td colSpan={7}><div className="op-empty">{res ? "No incidents match." : "Loading incidents..."}</div></td></tr>}
          </tbody>
        </table>
      </div>
      {pages > 1 && (
        <div className="sa-pager">
          <button type="button" className="owner-secondary-button" disabled={page === 0} onClick={() => setPage(page - 1)}>Previous</button>
          <span className="op-muted">Page {page + 1} of {pages} · {res.total} incidents</span>
          <button type="button" className="owner-secondary-button" disabled={page + 1 >= pages} onClick={() => setPage(page + 1)}>Next</button>
        </div>
      )}
      {open && <IncidentDrawer id={open} onClose={() => setOpen(null)} onOpenBusiness={onOpenBusiness} />}
    </section>
  );
}

const EVENT = { detected: "Detected", occurrence: "Contacted again", status: "Status changed", note: "Note added", assigned: "Assigned", listed: "Added to a list", unlisted: "Removed from a list", notified: "Team notified" };

function IncidentDrawer({ id, onClose, onOpenBusiness }) {
  const [res, setRes] = useState(null);
  const [error, setError] = useState("");
  useEffect(() => {
    callOwnerFunction("spam_admin_incident", { incidentId: id }).then(setRes).catch((err) => setError(friendlyError(err)));
  }, [id]);
  const inc = res?.incident;
  return createPortal(
    <div className="owner-modal-overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="owner-modal sa-drawer" role="dialog" aria-modal="true" aria-label="Incident">
        <div className="zs-dialog-head">
          <span className="zs-dialog-icon"><Icon name="gpp_maybe" /></span>
          <h3>{inc ? `${CHANNEL[inc.channel] ?? inc.channel} from ${inc.sender}` : "Incident"}</h3>
        </div>
        {error && <div className="owner-form-error" role="alert">{error}</div>}
        {!inc && !error && <p className="op-muted">Loading...</p>}
        {inc && (
          <>
            <div className="sa-badges">
              <Pill tone={RISK[inc.risk_level]}>{`${inc.risk_level} risk · ${inc.risk_score}`}</Pill>
              <Pill tone={(STATUS[inc.status] ?? ["neutral"])[0]}>{(STATUS[inc.status] ?? [null, inc.status])[1]}</Pill>
              <Pill>{ACTION[inc.action] ?? inc.action}</Pill>
            </div>
            <h4>Why</h4>
            <ul className="sa-reasons">
              {(inc.reasons ?? []).map((r, i) => <li key={i}>{r.label ?? REASON[r.code] ?? r.code}{r.points ? ` (+${r.points})` : ""}</li>)}
              {!inc.reasons?.length && <li className="op-muted">No signals recorded.</li>}
            </ul>
            <p className="op-muted">
              {inc.occurrences} contact{inc.occurrences === 1 ? "" : "s"} · first {when(inc.first_seen_at)} · last {when(inc.last_seen_at)}
            </p>
            <h4>History</h4>
            <ol className="sa-history">
              {res.events.map((e, i) => (
                <li key={i}>
                  <strong>{EVENT[e.kind] ?? e.kind}</strong>
                  {e.to_status && <> → {(STATUS[e.to_status] ?? [null, e.to_status])[1]}</>}
                  {e.detail?.list && <> ({e.detail.list} list, {e.detail.channel})</>}
                  <small className="op-muted"> · {e.by_team ? "by the business team" : "automatic"} · {when(e.created_at)}{e.has_note ? " · note kept private to the business" : ""}</small>
                </li>
              ))}
            </ol>
            <p className="op-muted sa-small">Message text, transcripts and notes stay with the business. To act on this incident, the business reviews it in its CRM.</p>
          </>
        )}
        <div className="ic-actions">
          {inc && <button type="button" className="owner-secondary-button" onClick={() => { onClose(); onOpenBusiness(inc.business_id); }}>Open business</button>}
          <button type="button" className="owner-primary-button" onClick={onClose}>Close</button>
        </div>
      </div>
    </div>,
    document.body
  );
}

function Coverage({ rows, onOpenBusiness }) {
  const [filter, setFilter] = useState("all");
  const list = (rows ?? []).filter((r) => filter === "all" || (filter === "off" ? r.protection === "off" : r.protection !== "off"));
  const off = (rows ?? []).filter((r) => r.protection === "off").length;
  return (
    <section className="owner-panel">
      <div className="sa-filters">
        <select value={filter} onChange={(e) => setFilter(e.target.value)} aria-label="Protection">
          <option value="all">All businesses ({rows?.length ?? 0})</option>
          <option value="on">Protection on ({(rows?.length ?? 0) - off})</option>
          <option value="off">Protection off ({off})</option>
        </select>
        <span className="op-muted">"On by default" means the business hasn't changed its spam settings and uses the platform defaults.</span>
      </div>
      <div className="owner-table-wrap">
        <table className="owner-table">
          <thead><tr><th>Business</th><th>Protection</th><th>Suspicious callers</th><th>Last changed</th></tr></thead>
          <tbody>
            {list.map((r) => (
              <tr key={r.business_id}>
                <td>
                  <div className="owner-business-cell">
                    <button type="button" className="vq-link" onClick={() => onOpenBusiness(r.business_id)}>{r.name}</button>
                    <span>{r.suspended ? "Suspended" : r.status ? humanize(r.status) : ""}</span>
                  </div>
                </td>
                <td><Pill tone={r.protection === "off" ? "danger" : "success"}>{r.protection === "off" ? "Off" : r.protection === "on" ? "On" : "On by default"}</Pill></td>
                <td>{r.call_screening === "screen" ? "Screened by the AI" : "Flagged for review"}</td>
                <td>{when(r.updated_at)}</td>
              </tr>
            ))}
            {!list.length && <tr><td colSpan={4}><div className="op-empty">No businesses here.</div></td></tr>}
          </tbody>
        </table>
      </div>
    </section>
  );
}

function Policy({ policy, canSave, onSaved }) {
  const [form, setForm] = useState(() => ({ ...policy }));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const dirty = Object.keys(form).some((k) => String(form[k]) !== String(policy?.[k]));

  async function save() {
    setBusy(true);
    setError("");
    try {
      const out = {};
      for (const [, fields] of POLICY) for (const [k] of fields) if (form[k] !== undefined && form[k] !== "") out[k] = Number(form[k]);
      await callOwnerFunction("spam_admin_policy_save", { policy: out });
      onSaved("Platform defaults saved. Businesses that haven't changed their own spam settings use them straight away.");
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="owner-panel sa-panel">
      <p className="op-muted">
        Defaults for every business. A business that saves its own limits in its spam settings keeps its own; score bands, alert levels and
        retention always come from here.
      </p>
      {POLICY.map(([title, fields]) => (
        <fieldset key={title} className="sa-fieldset">
          <legend>{title}</legend>
          {fields.map(([k, label, unit]) => (
            <label key={k} className="sa-field">
              <span>{label}</span>
              <span className="sa-input">
                <input type="number" value={form[k] ?? ""} disabled={!canSave || busy} onChange={(e) => setForm({ ...form, [k]: e.target.value })} aria-label={label} />
                <small>{unit}</small>
              </span>
            </label>
          ))}
        </fieldset>
      ))}
      {error && <div className="owner-form-error" role="alert">{error}</div>}
      <div className="ic-actions">
        {!canSave && <span className="op-muted">Your role can view these but not change them.</span>}
        {canSave && <button type="button" className="owner-secondary-button" disabled={!dirty || busy} onClick={() => setForm({ ...policy })}>Undo changes</button>}
        {canSave && <button type="button" className="owner-primary-button" disabled={!dirty || busy} onClick={save}>{busy ? "Saving..." : "Save defaults"}</button>}
      </div>
    </section>
  );
}

function Rules({ canManage, onChanged }) {
  const [rules, setRules] = useState(null);
  const [error, setError] = useState("");
  const [form, setForm] = useState({ value: "", channel: "all", reason: "", hours: "" });
  const [busy, setBusy] = useState(false);
  const [removing, setRemoving] = useState(null);

  const load = useCallback(() => {
    callOwnerFunction("spam_admin_rules").then((r) => setRules(r.rules ?? [])).catch((err) => setError(friendlyError(err)));
  }, []);
  useEffect(() => { load(); }, [load]);

  async function add(e) {
    e.preventDefault();
    setBusy(true);
    setError("");
    try {
      await callOwnerFunction("spam_admin_rule_add", { ...form, hours: form.hours ? Number(form.hours) : null });
      onChanged("Rule added. It applies to every business straight away.");
      setForm({ value: "", channel: "all", reason: "", hours: "" });
      load();
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  async function remove(rule) {
    setBusy(true);
    setError("");
    try {
      await callOwnerFunction("spam_admin_rule_remove", { ruleId: rule.id });
      onChanged("Rule removed.");
      setRemoving(null);
      load();
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  // Phone numbers go with calls or texts, addresses with email; switch the channel to match what's typed.
  function setValue(value) {
    const v = value.trim();
    const isAddress = v.includes("@") || /[a-z]\.[a-z]{2,}$/i.test(v);
    const channel = isAddress && ["call", "sms"].includes(form.channel) ? "email" : !isAddress && /\d{7}/.test(v.replace(/\D/g, "")) && form.channel === "email" ? "call" : form.channel;
    setForm({ ...form, value, channel });
  }

  return (
    <section className="owner-panel sa-panel">
      <p className="op-muted">
        Block a phone number, email address or domain for every business, for example a number confirmed as spam at several businesses.
        Use this sparingly: a business can't override a platform rule. Each rule needs a reason and is written to the audit log.
      </p>
      {canManage && (
        <form className="sa-rule-form" onSubmit={add}>
          <input value={form.value} onChange={(e) => setValue(e.target.value)} placeholder="Phone, email or domain" aria-label="Phone, email or domain" maxLength={254} />
          <select value={form.channel} onChange={(e) => setForm({ ...form, channel: e.target.value })} aria-label="Channel">
            <option value="all">Every channel</option><option value="call">Calls</option><option value="sms">Texts</option>
            <option value="email">Email</option><option value="booking">Bookings</option>
          </select>
          <select value={form.hours} onChange={(e) => setForm({ ...form, hours: e.target.value })} aria-label="Duration">
            <option value="">Until removed</option><option value="24">24 hours</option><option value="168">7 days</option><option value="720">30 days</option>
          </select>
          <input value={form.reason} onChange={(e) => setForm({ ...form, reason: e.target.value })} placeholder="Reason (required)" aria-label="Reason" maxLength={300} />
          <button type="submit" className="owner-primary-button" disabled={busy || !form.value.trim() || !form.reason.trim()}>Add rule</button>
        </form>
      )}
      {error && <div className="owner-form-error" role="alert">{error}</div>}
      <div className="owner-table-wrap">
        <table className="owner-table">
          <thead><tr><th>Value</th><th>Channel</th><th>Reason</th><th>Expires</th><th>Added</th><th aria-label="Actions" /></tr></thead>
          <tbody>
            {(rules ?? []).map((r) => (
              <tr key={r.id}>
                <td><strong>{r.value}</strong> <small className="op-muted">{r.value_type}</small></td>
                <td>{r.channel === "all" ? "Every channel" : CHANNEL[r.channel] ?? r.channel}</td>
                <td>{r.reason}</td>
                <td>{r.expires_at ? when(r.expires_at) : "Never"}</td>
                <td>{when(r.created_at)}</td>
                <td>{canManage && <button type="button" className="bd-danger-button" onClick={() => setRemoving(r)}>Remove</button>}</td>
              </tr>
            ))}
            {rules && !rules.length && <tr><td colSpan={6}><div className="op-empty">No platform-wide rules. Businesses manage their own block lists.</div></td></tr>}
            {!rules && <tr><td colSpan={6}><div className="op-empty">Loading rules...</div></td></tr>}
          </tbody>
        </table>
      </div>
      {removing && createPortal(
        <div className="owner-modal-overlay" onMouseDown={(e) => e.target === e.currentTarget && !busy && setRemoving(null)}>
          <div className="bd-confirm owner-modal danger" role="dialog" aria-modal="true" aria-label="Remove rule">
            <div className="zs-dialog-head">
              <span className="zs-dialog-icon"><Icon name="lock_open" /></span>
              <h3>Remove the rule for {removing.value}?</h3>
            </div>
            <p>Contacts from {removing.value} will reach every business again, unless a business has blocked it itself.</p>
            <div className="ic-actions">
              <button type="button" className="owner-secondary-button" onClick={() => setRemoving(null)} disabled={busy}>Go back</button>
              <button type="button" className="bd-danger-button" disabled={busy} onClick={() => remove(removing)}>{busy ? "Removing..." : "Remove rule"}</button>
            </div>
          </div>
        </div>,
        document.body
      )}
    </section>
  );
}

// The Spam Response workflow in n8n: follow-up only (alerts, repeat-offender checks, AI second opinion, weekly
// summaries). Blocking, screening and rate limits never wait for it. Switching it on or off is audited.
function Automation({ info, canSave, onSaved }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [limit, setLimit] = useState(info?.ai_monthly_limit ?? 200);
  const [confirmAi, setConfirmAi] = useState(false);
  if (!info?.available) {
    return <section className="owner-panel sa-panel"><p className="op-muted">The automation columns come with the current <strong>sql/zella_spam_protection.sql</strong>. Apply it (after a backup) to see the queue here.</p></section>;
  }
  async function save(patch, message) {
    setBusy(true);
    setError("");
    try {
      await callOwnerFunction("spam_admin_automation_save", { automation: patch });
      setConfirmAi(false);
      onSaved(message);
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }
  const q = info.queue ?? {};
  return (
    <section className="owner-panel sa-panel">
      <p className="op-muted">
        The <strong>Zella - Spam Response</strong> workflow in n8n handles follow-up for incidents the database has already detected, scored and
        (for calls) screened: severity-based alerts, repeat-offender checks, an optional AI second opinion and weekly summaries. Blocking, screening
        and rate limits never wait for it. If it doesn't run within 15 minutes, high-risk alerts are sent by the database instead.
      </p>
      {error && <div className="owner-form-error" role="alert">{error}</div>}
      <ul className="sa-list">
        <li>
          <span className="sa-stack"><strong>Spam Response workflow</strong><small className="op-muted">{info.live ? "On: medium and high incidents are queued for it" : "Off: everything is handled in the database, as before"}</small></span>
          <Pill tone={info.live ? "success" : "neutral"}>{info.live ? "On" : "Off"}</Pill>
          {canSave && <button type="button" className="owner-secondary-button" disabled={busy} onClick={() => save({ live: !info.live }, info.live ? "Spam Response switched off." : "Spam Response switched on. Make sure the workflow is published in n8n.")}>{info.live ? "Switch off" : "Switch on"}</button>}
        </li>
        <li>
          <span className="sa-stack"><strong>AI second opinion</strong><small className="op-muted">{info.ai_live ? `On (${info.ai_model ?? "default model"}), for businesses that opt in` : "Off"}. Only medium-risk texts and emails, details removed first; never blocks anyone.</small></span>
          <Pill tone={info.ai_live ? "success" : "neutral"}>{info.ai_live ? "On" : "Off"}</Pill>
          {canSave && <button type="button" className="owner-secondary-button" disabled={busy} onClick={() => (info.ai_live ? save({ ai_live: false }, "AI second opinion switched off.") : setConfirmAi(true))}>{info.ai_live ? "Switch off" : "Switch on"}</button>}
        </li>
        <li>
          <span className="sa-stack"><strong>n8n</strong><small className="op-muted">{info.n8n_connected ? (info.last_run ? `Last called ${when(info.last_run)} · ${info.runs_total} runs in total` : "Address set; not called yet") : "No n8n address set: the workflow can't be called"}</small></span>
          <Pill tone={info.n8n_connected ? (info.last_run ? "success" : "warning") : "danger"}>{info.n8n_connected ? (info.last_run ? "Connected" : "Waiting") : "Not connected"}</Pill>
        </li>
      </ul>
      <h2 className="sa-h2">Queue for this period</h2>
      <div className="vq-stats sa-stats">
        {[["Waiting", q.pending, "schedule", "warning"], ["Running", q.processing, "sync", "neutral"], ["Done", q.done, "task_alt", "success"], ["Failed", q.failed, "error", "danger"],
          ["Sent by the database instead", q.fallback, "shield", "neutral"], ["AI reviewed", q.ai_reviewed, "psychology", "neutral"]].map(([label, n, icon, tone]) => (
          <div key={label} className="vq-stat sa-stat"><span className={`vq-stat-icon ${tone}`}><Icon name={icon} /></span><span><strong>{n ?? 0}</strong><small>{label}</small></span></div>
        ))}
      </div>
      {canSave && (
        <label className="sa-field">
          <span>AI reviews per business per month</span>
          <span className="sa-input">
            <input type="number" min={0} max={10000} value={limit} disabled={busy} onChange={(e) => setLimit(e.target.value)} aria-label="AI reviews per business per month" />
            <button type="button" className="owner-secondary-button" disabled={busy || Number(limit) === Number(info.ai_monthly_limit)} onClick={() => save({ ai_monthly_limit: Number(limit) }, "AI review limit saved.")}>Save</button>
          </span>
        </label>
      )}
      {!canSave && <p className="op-muted">Your role can view this but not change it.</p>}
      {confirmAi && createPortal(
        <div className="owner-modal-overlay" onMouseDown={(e) => e.target === e.currentTarget && !busy && setConfirmAi(false)}>
          <div className="bd-confirm owner-modal" role="dialog" aria-modal="true" aria-label="Switch on AI second opinion">
            <div className="zs-dialog-head"><span className="zs-dialog-icon"><Icon name="psychology" /></span><h3>Switch on AI second opinion?</h3></div>
            <p>For businesses that opt in, medium-risk texts and emails are sent to the AI provider (Anthropic) with names, numbers and email addresses removed first.
              The answer is shown to the team as a suggestion and never blocks anyone. Add the Anthropic key to the "Ask AI" box in n8n first.</p>
            <div className="ic-actions">
              <button type="button" className="owner-secondary-button" onClick={() => setConfirmAi(false)} disabled={busy}>Go back</button>
              <button type="button" className="owner-primary-button" disabled={busy} onClick={() => save({ ai_live: true }, "AI second opinion switched on.")}>{busy ? "Saving..." : "Switch on"}</button>
            </div>
          </div>
        </div>,
        document.body
      )}
    </section>
  );
}
