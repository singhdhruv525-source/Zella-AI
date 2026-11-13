import { useEffect, useMemo, useRef, useState } from "react";
import { supabase } from "./supabase";
import { friendlyError } from "./admin/adminOps";

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

export default function PlanStep({ businessId, info, onSaved, onDirty, Section, Field, Badge, Toggle }) {
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
  const toggleLang = (code) => setForm((f) => ({ ...f, languages: f.languages.includes(code) ? f.languages.filter((l) => l !== code) : [...f.languages, code].sort() }));
  const readOnly = !info.can_edit;
  const errors = check && check.ok === false ? check.errors ?? [] : [];
  const bad = (k) => errors.includes(k);
  const est = check?.estimate;
  const s = info.settings ?? {};

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

  return (
    <>
      <Section title="Plan & pricing" description="Every value is set for this business. Base and Pro are labels only; they fill in nothing."
        aside={info.plan ? <Badge tone="success">{`Version ${info.plan.version} saved`}</Badge> : <Badge tone="danger">Not saved yet</Badge>}>
        <fieldset disabled={readOnly} style={{ border: 0, padding: 0, margin: 0, minWidth: 0 }}>
          <div className="owner-form-grid">
            <Field label="Label" required>
              <select value={form.tier} onChange={set("tier")} aria-invalid={bad("tier")}>
                <option value="">Choose</option><option value="base">Base</option><option value="pro">Pro</option>
              </select>
            </Field>
            <Field label="Billing" required>
              <select value={form.billing_interval} onChange={set("billing_interval")}>
                <option value="monthly">Monthly</option><option value="yearly">Yearly (allowances still refresh every month)</option>
              </select>
            </Field>
            <Field label={form.billing_interval === "yearly" ? "Price per year (USD)" : "Price per month (USD)"} required>
              <input inputMode="decimal" value={form.price} onChange={set("price")} aria-invalid={bad("price_cents")} placeholder="e.g. 299" />
            </Field>
            <Field label="Setup fee (USD, once)" required>
              <input inputMode="decimal" value={form.setup_fee} onChange={set("setup_fee")} aria-invalid={bad("setup_fee_cents")} />
            </Field>
            <Field label="AI minutes a month" required><input inputMode="numeric" value={form.minutes} onChange={set("minutes")} aria-invalid={bad("minutes")} /></Field>
            <Field label="Texts a month" required><input inputMode="numeric" value={form.texts} onChange={set("texts")} aria-invalid={bad("texts")} /></Field>
            <Field label="Emails a month" required><input inputMode="numeric" value={form.emails} onChange={set("emails")} aria-invalid={bad("emails")} /></Field>
            <Field label="Users" required><input inputMode="numeric" value={form.team_seats} onChange={set("team_seats")} aria-invalid={bad("team_seats")} /></Field>
            <Field label="Phone numbers" required><input inputMode="numeric" value={form.phone_numbers} onChange={set("phone_numbers")} aria-invalid={bad("phone_numbers")} /></Field>
            <Field label="Locations" required><input inputMode="numeric" value={form.locations} onChange={set("locations")} aria-invalid={bad("locations")} /></Field>
            <Field label="Languages" required bare>
              <div className="wiz-chip-row">
                {[["en", "English"], ["es", "Spanish"]].map(([code, label]) => (
                  <label key={code} className={`wiz-chip ${form.languages.includes(code) ? "on" : ""}`}>
                    <input type="checkbox" checked={form.languages.includes(code)} onChange={() => toggleLang(code)} />{label}
                  </label>
                ))}
              </div>
            </Field>
            <Field label="Free trial" bare hint={`${s.trial_days ?? 5} days with ${s.trial_minutes ?? 20} minutes, ${s.trial_texts ?? 5} texts and ${s.trial_emails ?? 5} emails. The card is taken at the start and charged when the trial ends.`}>
              <Toggle checked={form.trial_enabled} label="Offer the free trial" onChange={(on) => set("trial_enabled")(on)} />
            </Field>
          </div>
        </fieldset>
        {readOnly && <div className="wiz-note">You can see this plan but not change it: changing a plan needs billing.manage.</div>}
      </Section>

      <Section title="Profit check" description={`Estimated monthly cost against the price. Target margin: ${s.target_margin_percent ?? 60}%. Worked out by the database from the cost table.`}
        aside={checking ? <Badge>Checking…</Badge> : check?.ok ? (est?.margin_percent == null ? <Badge>No margin</Badge>
          : <Badge tone={est.margin_percent < 0 ? "danger" : est.margin_percent < (s.target_margin_percent ?? 60) ? "neutral" : "success"}><>{est.margin_percent}% margin</></Badge>) : null}>
        {check?.ok && est && (
          <div className="wiz-review">
            <PlanRow label="Estimated cost a month" value={money(est.monthly_cost_cents)} note={est.costs_complete ? "" : "Some unit costs aren't set, so this is too low"} />
            <PlanRow label="Revenue a month" value={money(est.monthly_revenue_cents)} note={form.billing_interval === "yearly" ? "The yearly price counted as one twelfth" : ""} />
            <PlanRow label="Setup fee" value={money(est.setup_fee_cents)} note="Shown separately, not in the margin" />
          </div>
        )}
        {errors.length > 0 && <div className="owner-form-error" role="alert">Fill in or correct: {errors.map((k) => FIELD_TEXT[k] ?? k).join(", ")}.</div>}
        {check?.failed && <div className="owner-form-error" role="alert">{check.failed}</div>}
        {(check?.warnings ?? []).map((w) => (
          <div key={w.code} className={w.level === "red" ? "owner-form-error" : "wiz-note"} role={w.level === "red" ? "alert" : "status"}>
            {w.level === "red" ? "Warning: " : "Caution: "}{(WARNING_TEXT[w.code] ?? (() => w.code))(w)} A reason is needed to save.
          </div>
        ))}
      </Section>

      {info.versions?.length > 0 && (
        <Section title="Saved versions" description="A change is always a new version; old versions are kept.">
          <div className="wiz-review">
            {info.versions.map((v) => <PlanRow key={v.version} label={`Version ${v.version}`} value={`${v.tier === "pro" ? "Pro" : "Base"} · ${money(v.price_cents)} ${v.billing_interval === "yearly" ? "a year" : "a month"}`} note={new Date(v.saved_at).toLocaleString()} />)}
          </div>
        </Section>
      )}

      {error && <div className="owner-form-error" role="alert">{error}</div>}
      {saved && <div className="wiz-note" role="status">{saved}</div>}
      {!readOnly && (
        <div className="wiz-footer-right" style={{ justifyContent: "flex-end" }}>
          <button type="button" className="owner-primary-button" disabled={checking || !check?.ok || (!dirty && Boolean(info.plan))} onClick={openReview}>
            {info.plan ? "Review changes" : "Review plan"}
          </button>
        </div>
      )}

      {review && <ReviewDialog review={review} setReview={setReview} onConfirm={confirm} onClose={() => { setReview(null); setError(""); }} error={error} />}
    </>
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
