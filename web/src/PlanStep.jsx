import { useEffect, useMemo, useRef, useState } from "react";
import { supabase } from "./supabase";
import { friendlyError } from "./admin/adminOps";
import "./billing.css";

// Create Business > Plan & pricing (ARCHITECTURE §17.1a, REQ-BIL-01, REQ-BIL-55–57). Every value is typed by hand for
// this business; nothing is preset. The profit and limit checks run in the database (zella_plan_evaluate) and the
// page only shows them. Saving goes through zella_admin_plan_save, which only a billing admin (billing.manage) may
// call: it refuses a warning without a written reason, saves a new version and writes the audit record.

const WARNING_TEXT = {
  loss: (w) => `This plan loses money: estimated margin ${w.margin_percent}%.`,
  below_target_margin: (w) => `The estimated margin (${w.margin_percent}%) is below the ${w.target}% target.`,
  minutes_high: (w) => `More than ${Number(w.limit).toLocaleString("en-US")} minutes a month.`,
  price_zero: () => "The price is $0.",
  costs_not_configured: (w) => `The unit costs aren't all set (${(w.detail ?? []).map((d) => d.replace(/_/g, " ")).join(", ")}), so the margin can't be worked out fully.`,
};
const FIELD_TEXT = { tier: "label", billing_interval: "billing", price_cents: "price", setup_fee_cents: "setup fee", minutes: "minutes", texts: "texts",
  emails: "emails", team_seats: "users", phone_numbers: "phone numbers", locations: "locations", languages: "languages", trial_enabled: "trial" };

const money = (cents) => (cents == null ? "—" : `$${(cents / 100).toLocaleString("en-US", { minimumFractionDigits: cents % 100 ? 2 : 0, maximumFractionDigits: 2 })}`);
const dollarsToCents = (v) => (String(v).trim() === "" || !/^\d+(\.\d{1,2})?$/.test(String(v).trim()) ? NaN : Math.round(Number(v) * 100));
const whole = (v) => (String(v).trim() === "" || !/^\d+$/.test(String(v).trim()) ? NaN : Number(v));
const newKey = () => (crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(16).slice(2)}`);

const EMPTY = { tier: "", billing_interval: "monthly", price: "", setup_fee: "0", minutes: "", texts: "", emails: "", team_seats: "", phone_numbers: "1",
  locations: "1", languages: ["en"], trial_enabled: false };

function fromPlan(p) {
  if (!p) return EMPTY;
  return { tier: p.tier, billing_interval: p.billing_interval, price: String(p.price_cents / 100), setup_fee: String(p.setup_fee_cents / 100),
    minutes: String(p.minutes), texts: String(p.texts), emails: String(p.emails), team_seats: String(p.team_seats), phone_numbers: String(p.phone_numbers),
    locations: String(p.locations), languages: p.languages, trial_enabled: p.trial_enabled };
}

function toValues(f) {
  return { tier: f.tier, billing_interval: f.billing_interval, price_cents: dollarsToCents(f.price), setup_fee_cents: dollarsToCents(f.setup_fee),
    minutes: whole(f.minutes), texts: whole(f.texts), emails: whole(f.emails), team_seats: whole(f.team_seats), phone_numbers: whole(f.phone_numbers),
    locations: whole(f.locations), languages: f.languages, trial_enabled: f.trial_enabled };
}

export async function loadPlanInfo(businessId) {
  const { data, error } = await supabase.rpc("zella_admin_plan_get", { p_business_id: businessId });
  if (error) {
    if (/NOT_ALLOWED/.test(error.message)) return { denied: true };
    throw new Error(friendlyError(error));
  }
  return data;
}

export default function PlanStep({ businessId, info, onSaved, onDirty, Section, Badge, Toggle }) {
  const [form, setForm] = useState(() => fromPlan(info?.plan));
  const [check, setCheck] = useState(null);
  const [checking, setChecking] = useState(false);
  const [review, setReview] = useState(null);       // { key, values, result, reasons }
  const [error, setError] = useState("");
  const [saved, setSaved] = useState("");
  const seq = useRef(0);

  const values = useMemo(() => toValues(form), [form]);
  const dirty = JSON.stringify(form) !== JSON.stringify(fromPlan(info?.plan));
  useEffect(() => { onDirty?.(dirty); }, [dirty, onDirty]);

  // the database's check, as values are typed (debounced; only the latest answer is shown)
  useEffect(() => {
    if (!info || info.denied) return undefined;
    const id = ++seq.current;
    const t = setTimeout(async () => {
      setChecking(true);
      const clean = Object.fromEntries(Object.entries(values).map(([k, v]) => [k, typeof v === "number" && Number.isNaN(v) ? null : v]));
      const { data, error: e } = await supabase.rpc("zella_plan_evaluate", { p_values: clean });
      if (id !== seq.current) return;
      setChecking(false);
      setCheck(e ? { ok: false, failed: friendlyError(e) } : data);
    }, 350);
    return () => clearTimeout(t);
  }, [values, info]);

  if (!info) return null;
  if (info.denied) {
    return (
      <Section title="Plan & pricing" description="The plan for this business is set by a billing admin.">
        <div className="wiz-note">You don't have billing permission. A billing admin (billing.manage) must set this business's plan before the owner can be invited.</div>
      </Section>
    );
  }

  const set = (key) => (e) => { setSaved(""); setError(""); setForm((f) => ({ ...f, [key]: e?.target ? (e.target.type === "checkbox" ? e.target.checked : e.target.value) : e })); };
  const toggleLang = (code) => { setSaved(""); setForm((f) => ({ ...f, languages: f.languages.includes(code) ? f.languages.filter((l) => l !== code) : [...f.languages, code].sort() })); };
  const readOnly = !info.can_edit;
  const errors = check && check.ok === false ? check.errors ?? [] : [];
  const bad = (k) => errors.includes(k);
  const est = check?.ok ? check.estimate : null;
  const s = info.settings ?? {};
  const target = s.target_margin_percent ?? 60;
  const yearly = form.billing_interval === "yearly";
  const margin = est?.margin_percent;
  const marginTone = margin == null ? "" : margin < 0 ? "bad" : margin < target ? "caution" : "good";
  const marginWord = margin == null ? "No revenue" : margin < 0 ? "Loses money" : margin < target ? "Below target" : "Healthy";

  function openReview() {
    if (!check?.ok) { setError(check?.failed ?? `Fix: ${errors.map((k) => FIELD_TEXT[k] ?? k).join(", ")}.`); return; }
    setReview({ key: newKey(), values: check.values, result: check, reasons: {} });
  }

  async function confirm() {
    setError("");
    const missing = (review.result.warnings ?? []).filter((w) => (review.reasons[w.code] ?? "").trim().length < 5);
    if (missing.length) { setError("Give a reason (at least 5 characters) for every warning."); return; }
    const { data, error: e } = await supabase.rpc("zella_admin_plan_save", { p_business_id: businessId, p_values: review.values,
      p_acknowledgements: review.reasons, p_idempotency_key: review.key });
    if (e) { setError(friendlyError(e)); return; }
    setReview(null);
    setSaved(data.result === "duplicate" ? `Version ${data.version} was already saved.` : `Saved as version ${data.version}. The owner can now be invited.`);
    onSaved?.();
  }

  const num = (label, k, extra = {}) => <Num label={label} value={form[k]} onChange={set(k)} invalid={bad(extra.errKey ?? k)} prefix={extra.prefix} suffix={extra.suffix} />;

  return (
    <div className="bp-layout">
      <fieldset disabled={readOnly} className="bp-form" style={{ border: 0, padding: 0, margin: 0, minWidth: 0 }}>
        <section className="bp-card">
          <div className="bp-card-head"><div><h3>Pricing</h3><p>Every value is set for this business. Base and Pro are labels only; they fill in nothing.</p></div>
            {info.plan ? <Badge tone="success">{`Version ${info.plan.version} saved`}</Badge> : <Badge tone="danger">Not saved yet</Badge>}</div>
          <div className="bp-grid">
            <Seg label="Label" value={form.tier} options={[["base", "Base"], ["pro", "Pro"]]} onPick={set("tier")} disabled={readOnly} />
            <Seg label="Billing" value={form.billing_interval} options={[["monthly", "Monthly"], ["yearly", "Yearly"]]} onPick={set("billing_interval")} disabled={readOnly} />
            {num(yearly ? "Price per year" : "Price per month", "price", { prefix: "$", suffix: yearly ? "/ year" : "/ month", errKey: "price_cents" })}
            {num("Setup fee", "setup_fee", { prefix: "$", suffix: "once", errKey: "setup_fee_cents" })}
          </div>
          {yearly && <p className="bp-muted" style={{ marginTop: 12 }}>Charged once a year. Minutes, texts and emails still refresh every month.</p>}
        </section>

        <section className="bp-card">
          <div className="bp-card-head"><div><h3>Monthly allowances</h3><p>Refreshed every month. Up to 20% of unused minutes roll over for one month.</p></div></div>
          <div className="bp-grid three">
            {num("AI minutes", "minutes", { suffix: "min" })}
            {num("Texts", "texts", { suffix: "texts" })}
            {num("Emails", "emails", { suffix: "emails" })}
          </div>
        </section>

        <section className="bp-card">
          <div className="bp-card-head"><div><h3>Account</h3><p>Limits checked by the server when the business adds people, numbers or languages.</p></div></div>
          <div className="bp-grid three">
            {num("Users", "team_seats")}
            {num("Phone numbers", "phone_numbers")}
            {num("Locations", "locations")}
          </div>
          <div className="bp-grid" style={{ marginTop: 16 }}>
            <div className="bp-field">
              <span id="plan-langs">Languages</span>
              <div className="bp-seg" role="group" aria-labelledby="plan-langs">
                {[["en", "English"], ["es", "Spanish"]].map(([code, text]) => (
                  <button key={code} type="button" aria-pressed={form.languages.includes(code)} disabled={readOnly} onClick={() => toggleLang(code)}>{text}</button>
                ))}
              </div>
              {bad("languages") && <small style={{ color: "var(--zella-danger)" }}>Choose at least one language.</small>}
            </div>
            <div className="bp-trial">
              <div><strong>Free trial</strong><span>{s.trial_days ?? 5} days · {s.trial_minutes ?? 20} min · {s.trial_texts ?? 5} texts · {s.trial_emails ?? 5} emails. Card taken at the start.</span></div>
              <Toggle checked={form.trial_enabled} label="Offer the free trial" disabled={readOnly} onChange={(on) => set("trial_enabled")(on)} />
            </div>
          </div>
        </section>
        {readOnly && <div className="wiz-note">You can see this plan but not change it: changing a plan needs billing.manage.</div>}
      </fieldset>

      <aside className="bp-card bp-summary" aria-label="Plan summary">
        <div>
          <p className="bp-muted">{form.tier ? (form.tier === "pro" ? "Pro" : "Base") : "Choose a label"} · {yearly ? "billed yearly" : "billed monthly"}</p>
          <div className="bp-price"><strong>{Number.isNaN(values.price_cents) ? "$—" : money(values.price_cents)}</strong><span>{yearly ? "/ year" : "/ month"}</span></div>
          {values.setup_fee_cents > 0 && <p className="bp-sub">+ {money(values.setup_fee_cents)} setup fee</p>}
        </div>
        <div className={`bp-margin ${marginTone}`} aria-live="polite">
          <div><span>Estimated margin</span><br /><strong>{checking && !est ? "…" : margin == null ? "—" : `${margin}%`}</strong></div>
          <Badge tone={marginTone === "good" ? "success" : marginTone === "bad" ? "danger" : "neutral"}><>{marginWord}</></Badge>
        </div>
        {est && (
          <dl className="bp-lines">
            <div><dt>Estimated cost / month</dt><dd>{money(est.monthly_cost_cents)}</dd></div>
            <div><dt>Revenue / month{yearly ? " (1/12)" : ""}</dt><dd>{money(est.monthly_revenue_cents)}</dd></div>
            <div><dt>Target margin</dt><dd>{target}%</dd></div>
          </dl>
        )}
        {errors.length > 0 && <ul className="bp-warn" role="alert"><li className="red"><span>Fill in or correct: {errors.map((k) => FIELD_TEXT[k] ?? k).join(", ")}.</span></li></ul>}
        {check?.failed && <ul className="bp-warn" role="alert"><li className="red">{check.failed}</li></ul>}
        {(check?.warnings ?? []).length > 0 && (
          <ul className="bp-warn">
            {check.warnings.map((w) => (
              <li key={w.code} className={w.level === "red" ? "red" : "caution"}>
                <span><b>{w.level === "red" ? "Warning" : "Caution"}:</b> {(WARNING_TEXT[w.code] ?? (() => w.code))(w)}</span>
              </li>
            ))}
          </ul>
        )}
        {error && <ul className="bp-warn" role="alert"><li className="red">{error}</li></ul>}
        {saved && <div className="wiz-note" role="status">{saved}</div>}
        {!readOnly && (
          <button type="button" className="bp-primary" disabled={checking || !check?.ok || (!dirty && Boolean(info.plan))} onClick={openReview}>
            {info.plan ? "Review changes" : "Review plan"}
          </button>
        )}
        <p className="bp-muted">Warnings never block: each needs a written reason on the review screen, kept in the audit record.</p>
        {info.versions?.length > 0 && (
          <div>
            <p className="bp-muted" style={{ marginBottom: 6 }}>Saved versions</p>
            <ul className="bp-versions">
              {info.versions.map((v) => <li key={v.version}><b>v{v.version} · {v.tier === "pro" ? "Pro" : "Base"} · {money(v.price_cents)}</b><span>{new Date(v.saved_at).toLocaleDateString()}</span></li>)}
            </ul>
          </div>
        )}
      </aside>

      {review && <ReviewDialog review={review} setReview={setReview} onConfirm={confirm} onClose={() => { setReview(null); setError(""); }} error={error} />}
    </div>
  );
}

function Num({ label, value, onChange, invalid, prefix, suffix }) {
  return (
    <label className="bp-field">
      <span>{label}</span>
      <div className="bp-affix" data-invalid={invalid}>
        {prefix && <em aria-hidden="true">{prefix}</em>}
        <input inputMode={prefix ? "decimal" : "numeric"} value={value} onChange={onChange} aria-label={label} aria-invalid={invalid} />
        {suffix && <em aria-hidden="true">{suffix}</em>}
      </div>
    </label>
  );
}

function Seg({ label, value, options, onPick, disabled }) {
  const id = `seg-${label.toLowerCase().replace(/\W+/g, "-")}`;
  return (
    <div className="bp-field">
      <span id={id}>{label}</span>
      <div className="bp-seg" role="group" aria-labelledby={id}>
        {options.map(([v, text]) => <button key={v} type="button" aria-pressed={value === v} disabled={disabled} onClick={() => onPick(v)}>{text}</button>)}
      </div>
    </div>
  );
}

function PlanRow({ label, value, note }) {
  return (
    <div className="wiz-review-row">
      <span className="wiz-review-dot ok" aria-hidden="true">·</span>
      <div><strong>{label}: {value}</strong>{note && <span>{note}</span>}</div>
    </div>
  );
}

function ReviewDialog({ review, setReview, onConfirm, onClose, error }) {
  const v = review.values, est = review.result.estimate, warnings = review.result.warnings ?? [];
  const [busy, setBusy] = useState(false);
  const ref = useRef(null);
  const busyRef = useRef(false);
  useEffect(() => { busyRef.current = busy; }, [busy]);
  // focus stays inside the dialog; Escape goes back to editing; focus returns to where it was
  useEffect(() => {
    const before = document.activeElement;
    ref.current?.querySelector("textarea, button")?.focus();
    const onKey = (event) => {
      if (event.key === "Escape") { event.preventDefault(); if (!busyRef.current) onClose(); return; }
      if (event.key !== "Tab") return;
      const items = [...ref.current.querySelectorAll("textarea, button:not(:disabled)")];
      const first = items[0], last = items[items.length - 1];
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    };
    document.addEventListener("keydown", onKey);
    return () => { document.removeEventListener("keydown", onKey); before?.focus?.(); };
  }, [onClose]);
  const rows = [["Label", v.tier === "pro" ? "Pro" : "Base"], ["Price", `${money(v.price_cents)} ${v.billing_interval === "yearly" ? "a year" : "a month"}`],
    ["Setup fee", money(v.setup_fee_cents)], ["Each month", `${v.minutes.toLocaleString("en-US")} minutes, ${v.texts.toLocaleString("en-US")} texts, ${v.emails.toLocaleString("en-US")} emails`],
    ["Users, numbers, locations", `${v.team_seats}, ${v.phone_numbers}, ${v.locations}`], ["Languages", v.languages.map((l) => (l === "en" ? "English" : "Spanish")).join(" and ")],
    ["Trial", v.trial_enabled ? "On (5 days)" : "Off"], ["Estimated margin", est.margin_percent == null ? "—" : `${est.margin_percent}%`]];
  return (
    <div className="owner-modal-overlay">
      <div className="owner-modal wiz-unsaved-dialog" role="dialog" aria-modal="true" aria-labelledby="plan-review-title" ref={ref}>
        <h3 id="plan-review-title">Review the plan</h3>
        <p>Confirming saves a new version with an audit record of who confirmed it, the values and every warning with its reason.</p>
        <div className="wiz-review">{rows.map(([k, val]) => <PlanRow key={k} label={k} value={val} />)}</div>
        {warnings.map((w) => (
          <label key={w.code} className="owner-field wiz-field-full">
            <span>{(WARNING_TEXT[w.code] ?? (() => w.code))(w)} Reason *</span>
            <textarea rows={2} value={review.reasons[w.code] ?? ""} onChange={(e) => setReview((r) => ({ ...r, reasons: { ...r.reasons, [w.code]: e.target.value } }))} />
          </label>
        ))}
        {error && <div className="owner-form-error" role="alert">{error}</div>}
        <div className="owner-modal-actions">
          <button type="button" className="owner-secondary-button" disabled={busy} onClick={onClose}>Edit</button>
          <button type="button" className="owner-primary-button" disabled={busy}
            onClick={async () => { setBusy(true); try { await onConfirm(); } finally { setBusy(false); } }}>{busy ? "Saving…" : "Confirm and save"}</button>
        </div>
      </div>
    </div>
  );
}
