import { useCallback, useEffect, useMemo, useState } from "react";
import { createPortal } from "react-dom";
import "./OwnerPages.css";
import { supabase } from "./supabase";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { formatDate, formatDateTime, timeAgo } from "./ownerFormat";

// Offers & Promotions. Every rule (eligibility, limits, approvals, start and end) is enforced in the
// database; this page only asks for changes and shows what the database decided.

const STATUS = {
  draft: ["Draft", "neutral"],
  pending_approval: ["Waiting for approval", "warning"],
  scheduled: ["Scheduled", "info"],
  active: ["Active", "success"],
  paused: ["Paused", "warning"],
  expired: ["Ended", "neutral"],
  archived: ["Archived", "neutral"],
};

const TYPES = [
  ["percent_discount", "Percentage discount"],
  ["fixed_discount", "Fixed amount off"],
  ["size_specific", "Business size offer"],
  ["industry_specific", "Industry offer"],
  ["business_specific", "Offer for chosen businesses"],
  ["annual_promo", "Annual plan promotion"],
  ["promo_code", "Promotional code"],
  ["custom_negotiated", "Custom negotiated deal"],
  ["intro_pricing", "Introductory pricing", ["billing"]],
  ["referral", "Referral reward", ["referral_tracking", "billing"]],
  ["win_back", "Win-back offer", ["promo_sending"]],
  ["free_trial", "Free trial", ["billing", "checkout"]],
];

const CHANNELS = [
  ["dashboard", "Business dashboard", "Owners see it in their workspace and can claim it."],
  ["sales", "Applied by Zella", "A Zella admin applies it to a chosen business."],
  ["pricing_page", "Public pricing page", null, ["checkout"]],
  ["signup", "Sign-up", null, ["checkout"]],
  ["checkout", "Checkout", null, ["checkout", "billing"]],
  ["email", "Email campaign", null, ["promo_sending"]],
  ["referral", "Referral link", null, ["referral_tracking"]],
];

const NEEDS = {
  billing: "a payment provider",
  checkout: "online checkout",
  referral_tracking: "referral tracking",
  promo_sending: "promotional sending (switched off)",
};

const RULE_FIELDS = {
  business_size: "Business size",
  industry: "Industry",
  business: "Specific businesses",
  customer_status: "Customer status",
  subscription_status: "Subscription status",
  billing_interval: "Billing interval",
  country: "Country",
  first_purchase: "Has never paid",
  never_redeemed: "Has no other offer",
};

const SIMPLE_VALUES = {
  business_size: [["small", "Small"], ["medium", "Medium"], ["large", "Large"]],
  customer_status: [["new", "New (never subscribed)"], ["existing", "Existing subscriber"], ["former", "Former subscriber"]],
  subscription_status: [["none", "No subscription"], ["trial", "Trial"], ["active", "Active"], ["past_due", "Past due"], ["cancelled", "Cancelled"], ["expired", "Expired"]],
  billing_interval: [["monthly", "Monthly"], ["yearly", "Yearly"]],
};

const ZONES = ["America/New_York", "America/Chicago", "America/Denver", "America/Phoenix", "America/Los_Angeles", "America/Anchorage", "Pacific/Honolulu", "Asia/Kolkata", "UTC"];

const ERRORS = {
  NOT_ALLOWED: "Only Zella admins can do this.",
  OWNER_ONLY: "Only a Zella owner can do this.",
  SECOND_PERSON_NEEDED: "Another Zella owner has to approve an offer you submitted.",
  NOTE_REQUIRED: "Add a short note explaining why.",
  TERMS_LOCKED: "The terms of a submitted offer can't change. Move it back to draft first, or end it and create a new one.",
  CODE_TAKEN: "That code is already used by another offer.",
  END_BEFORE_START: "The end must be after the start.",
  BAD_TIMEZONE: "Choose a valid time zone.",
  BAD_TRANSITION: "That change isn't possible from the offer's current state. Reload and try again.",
  HAS_REDEMPTIONS: "Businesses have already claimed this offer, so it can't go back to draft. End it instead.",
  RULE_UNAVAILABLE: "This rule needs a connection that isn't set up yet.",
  BAD_CONFIG: "One of the settings isn't a valid whole number.",
  NOT_PENDING: "Only a claim that is still waiting for payment can be cancelled.",
  NOT_CONFIRMED: "Only a paid claim can be reversed.",
  OFFER_NOT_FOUND: "This offer no longer exists.",
};

function friendly(error) {
  const msg = String(error?.message ?? error ?? "");
  const key = Object.keys(ERRORS).find((k) => msg.includes(k));
  return key ? ERRORS[key] : msg || "Something went wrong. Please try again.";
}

async function rpc(fn, args) {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw error;
  return data;
}

const statusPill = (s) => {
  const [label, tone] = STATUS[s] ?? [s, "neutral"];
  return <Pill tone={tone}>{label}</Pill>;
};

const missingText = (missing = []) => missing.map((m) => NEEDS[m] ?? m).join(" and ");

// "12.5" -> 1250 basis points; "19.99" -> 1999 cents. Parsed as text, so no rounding surprises.
function toHundredths(text) {
  const t = String(text ?? "").trim();
  if (!/^\d+(\.\d{0,2})?$/.test(t)) return null;
  const [whole, frac = ""] = t.split(".");
  return Number(whole) * 100 + Number((frac + "00").slice(0, 2));
}
const fromHundredths = (n) => (n == null ? "" : (n % 100 === 0 ? String(n / 100) : (n / 100).toFixed(2)));
const money = (cents, currency = "usd") =>
  cents == null ? "Not known" : new Intl.NumberFormat("en-US", { style: "currency", currency: currency.toUpperCase() }).format(cents / 100);

function newIdempotencyKey(prefix) {
  const rand = typeof crypto !== "undefined" && crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + Math.random().toString(16).slice(2);
  return `${prefix}-${rand}`;
}

function Overlay({ title, onClose, busy, children, footer, wide }) {
  useEffect(() => {
    const onKey = (e) => e.key === "Escape" && !busy && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose, busy]);
  return createPortal(
    <div className="owner-modal-overlay" onMouseDown={(e) => e.target === e.currentTarget && !busy && onClose()}>
      <div className={`owner-modal of-modal ${wide ? "wide" : ""}`} role="dialog" aria-modal="true" aria-label={title}>
        <div className="owner-modal-header of-modal-head">
          <h2>{title}</h2>
          <button type="button" className="owner-modal-close" aria-label="Close" onClick={onClose} disabled={busy}>×</button>
        </div>
        <div className="owner-modal-body">{children}</div>
        {footer && <div className="owner-modal-footer">{footer}</div>}
      </div>
    </div>,
    document.body
  );
}

// ------------------------------------------------------------------ page
export default function OffersPage({ onOpenBusiness }) {
  const [tab, setTab] = useState("Offers");
  const [list, setList] = useState(null);
  const [lookups, setLookups] = useState({ businesses: [], industries: [] });
  const [error, setError] = useState("");
  const [filter, setFilter] = useState("open");
  const [editing, setEditing] = useState(null);
  const [openId, setOpenId] = useState(null);
  const [notice, setNotice] = useState("");

  const load = useCallback(async () => {
    setError("");
    try {
      setList(await rpc("zella_offers_list"));
    } catch (err) {
      setError(friendly(err));
      setList({ offers: [], capabilities: {} });
    }
  }, []);

  useEffect(() => {
    load();
    callOwnerFunction("dashboard_data")
      .then((d) => setLookups({
        businesses: (d.businesses ?? []).map((b) => ({ id: b.id, name: b.name })).sort((a, b) => a.name.localeCompare(b.name)),
        industries: (d.industries ?? []).map((i) => ({ id: i.id, name: i.name })),
      }))
      .catch(() => {});
  }, [load]);

  const offers = useMemo(() => {
    const all = list?.offers ?? [];
    if (filter === "open") return all.filter((o) => !["expired", "archived"].includes(o.status));
    if (filter === "all") return all;
    return all.filter((o) => o.status === filter);
  }, [list, filter]);

  const caps = list?.capabilities ?? {};
  const counts = useMemo(() => {
    const c = {};
    for (const o of list?.offers ?? []) c[o.status] = (c[o.status] ?? 0) + 1;
    return c;
  }, [list]);

  return (
    <section className="owner-page">
      <div className="owner-page-heading">
        <div>
          <div className="owner-eyebrow">GROWTH</div>
          <h1>Offers & promotions</h1>
          <p>Create offers for Small, Medium and Large businesses, schedule them, and see who claimed what.</p>
        </div>
        {tab === "Offers" && (
          <button type="button" className="owner-primary-button" onClick={() => setEditing({})}>＋ New offer</button>
        )}
      </div>

      {!caps.billing && (
        <div className="wiz-note op-gap">
          <strong>No payment provider connected yet.</strong> Businesses can claim offers, and each claim waits as
          "Waiting for payment". It becomes "Paid" only when a real payment arrives from the payment provider, and
          an unpaid claim is released after the hold period. Checkout, renewal pricing, referrals, win-back and
          promotional emails show as unavailable until their connections exist.
        </div>
      )}

      {error && <div className="owner-form-error op-gap" role="alert">{error}</div>}
      {notice && <div className="owner-form-success op-gap" role="status">{notice}</div>}

      <div className="op-tabs op-gap" role="tablist">
        {["Offers", "Automation rules", "Monitoring", "Reports"].map((name) => (
          <button key={name} type="button" role="tab" aria-selected={tab === name} className={tab === name ? "active" : ""} onClick={() => setTab(name)}>
            {name}{name === "Offers" && counts.pending_approval ? ` (${counts.pending_approval} to approve)` : ""}
          </button>
        ))}
      </div>

      {tab === "Offers" && (
        <>
          <div className="of-filters op-gap">
            {[["open", "Current"], ["active", "Active"], ["pending_approval", "To approve"], ["scheduled", "Scheduled"], ["paused", "Paused"], ["draft", "Drafts"], ["expired", "Ended"], ["archived", "Archived"], ["all", "All"]].map(([key, label]) => (
              <button key={key} type="button" className={`of-chip ${filter === key ? "on" : ""}`} onClick={() => setFilter(key)}>
                {label}{key !== "open" && key !== "all" && counts[key] ? ` ${counts[key]}` : ""}
              </button>
            ))}
          </div>

          {list === null ? (
            <div className="owner-loading op-gap">Loading offers...</div>
          ) : offers.length === 0 ? (
            <div className="owner-empty-state op-gap">
              <strong>No offers here.</strong>
              <p>Create an offer to reward a group of businesses, or apply a negotiated deal to one business.</p>
            </div>
          ) : (
            <div className="owner-table-wrap op-gap">
              <table className="owner-table">
                <thead>
                  <tr><th>Offer</th><th>Status</th><th>Runs</th><th>Claims</th><th>Where</th><th /></tr>
                </thead>
                <tbody>
                  {offers.map((o) => (
                    <tr key={o.id}>
                      <td>
                        <div className="owner-table-primary">{o.name}</div>
                        <div className="owner-table-secondary">{o.summary}{o.code ? ` · code ${o.code}` : ""}</div>
                        {o.problems?.length > 0 && <div className="of-problem-line">{o.problems.length} thing{o.problems.length > 1 ? "s" : ""} to fix</div>}
                      </td>
                      <td>{statusPill(o.status)}</td>
                      <td>
                        {o.starts_at ? `${formatDate(o.starts_at)} – ${formatDate(o.ends_at)}` : <span className="op-muted">Not scheduled</span>}
                        <div className="owner-table-secondary">{o.timezone}</div>
                      </td>
                      <td>{o.claims}{o.max_redemptions ? ` of ${o.max_redemptions}` : ""}<div className="owner-table-secondary">{o.confirmed} paid</div></td>
                      <td className="owner-table-secondary">{(o.channels ?? []).map((c) => CHANNELS.find((x) => x[0] === c)?.[1] ?? c).join(", ")}</td>
                      <td><button type="button" className="owner-secondary-button op-small" onClick={() => setOpenId(o.id)}>Open</button></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}

      {tab === "Automation rules" && <RulesTab onChanged={load} />}
      {tab === "Monitoring" && <MonitorTab onOpenOffer={(id) => { setTab("Offers"); setOpenId(id); }} />}
      {tab === "Reports" && <ReportsTab />}

      {editing && (
        <OfferEditor
          offerId={editing.id ?? null}
          caps={caps}
          lookups={lookups}
          onClose={() => setEditing(null)}
          onSaved={async (id, msg) => { setEditing(null); setNotice(msg); await load(); setOpenId(id); }}
        />
      )}
      {openId && (
        <OfferDetail
          offerId={openId}
          me={list?.me}
          isOwner={list?.is_owner}
          lookups={lookups}
          onClose={() => setOpenId(null)}
          onEdit={(id) => { setOpenId(null); setEditing({ id }); }}
          onChanged={load}
          onOpenBusiness={onOpenBusiness}
        />
      )}
    </section>
  );
}

// ------------------------------------------------------------------ editor
const blank = () => ({
  name: "", description: "", internal_note: "", offer_type: "percent_discount", discount_kind: "percent",
  percent: "10", amount: "", currency: "usd", duration: "once", duration_months: "3", timezone: "America/New_York",
  start_local: "", end_local: "", max_redemptions: "100", max_per_business: "1", code: "", code_case_sensitive: false,
  stackable: false, channels: ["dashboard"], match: "all", rules: [],
});

function OfferEditor({ offerId, caps, lookups, onClose, onSaved }) {
  const [f, setF] = useState(offerId ? null : blank());
  const [status, setStatus] = useState("draft");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const set = (patch) => setF((cur) => ({ ...cur, ...patch }));
  const termsLocked = status !== "draft";
  const missing = (req = []) => req.filter((r) => !caps?.[r]);

  useEffect(() => {
    if (!offerId) return;
    rpc("zella_offer_detail", { p_id: offerId }).then((d) => {
      const o = d.offer;
      setStatus(o.status);
      setF({
        name: o.name ?? "", description: o.description ?? "", internal_note: o.internal_note ?? "",
        offer_type: o.offer_type, discount_kind: o.discount_kind, percent: fromHundredths(o.percent_off_bp),
        amount: fromHundredths(o.amount_off_cents), currency: o.currency, duration: o.duration,
        duration_months: String(o.duration_months ?? 3), timezone: o.timezone, start_local: o.start_local ?? "",
        end_local: o.end_local ?? "", max_redemptions: o.max_redemptions == null ? "" : String(o.max_redemptions),
        max_per_business: String(o.max_per_business), code: o.code ?? "", code_case_sensitive: o.code_case_sensitive,
        stackable: o.stackable, channels: o.channels ?? [], match: o.eligibility?.match ?? "all",
        rules: (o.eligibility?.rules ?? []).map((r) => ({ ...r })),
      });
    }).catch((err) => setError(friendly(err)));
  }, [offerId]);

  if (!f) {
    return <Overlay title="Edit offer" onClose={onClose}><p className="op-muted">{error || "Loading..."}</p></Overlay>;
  }

  function buildPayload() {
    const words = { name: f.name.trim(), description: f.description.trim(), internal_note: f.internal_note.trim() };
    if (termsLocked) return words;
    const pct = toHundredths(f.percent);
    const cents = toHundredths(f.amount);
    if (f.discount_kind === "percent" && (pct == null || pct < 1 || pct > 10000)) throw new Error("Enter a percentage between 0.01 and 100.");
    if (f.discount_kind === "fixed" && (cents == null || cents < 1)) throw new Error("Enter the amount off, for example 25 or 19.99.");
    const max = f.max_redemptions.trim();
    if (max && !/^\d+$/.test(max)) throw new Error("Total claims must be a whole number, or empty for no limit.");
    if (!/^\d+$/.test(f.max_per_business.trim())) throw new Error("Claims per business must be a whole number.");
    return {
      ...words,
      offer_type: f.offer_type, discount_kind: f.discount_kind,
      percent_off_bp: f.discount_kind === "percent" ? pct : null,
      amount_off_cents: f.discount_kind === "fixed" ? cents : null,
      currency: f.currency, duration: f.duration,
      duration_months: f.duration === "repeating" ? Number(f.duration_months) : null,
      timezone: f.timezone, start_local: f.start_local, end_local: f.end_local,
      max_redemptions: max, max_per_business: f.max_per_business.trim(),
      code: f.code.trim(), code_case_sensitive: f.code_case_sensitive, stackable: f.stackable,
      channels: f.channels,
      eligibility: { match: f.match, rules: f.rules.filter((r) => r.field) },
    };
  }

  async function save(event) {
    event.preventDefault();
    setBusy(true);
    setError("");
    try {
      const id = await rpc("zella_offer_save", { p_id: offerId, p_data: buildPayload() });
      onSaved(id, offerId ? "Offer saved." : "Draft saved. Submit it when it's ready.");
    } catch (err) {
      setError(friendly(err));
      setBusy(false);
    }
  }

  const footer = (
    <>
      <button type="button" className="owner-secondary-button" onClick={onClose} disabled={busy}>Cancel</button>
      <button type="submit" form="offer-form" className="owner-primary-button" disabled={busy || !f.name.trim()}>{busy ? "Saving..." : "Save"}</button>
    </>
  );

  return (
    <Overlay title={offerId ? "Edit offer" : "New offer"} onClose={onClose} busy={busy} footer={footer} wide>
      <form id="offer-form" className="of-form" onSubmit={save}>
        {termsLocked && (
          <div className="wiz-note">This offer has been submitted, so only its name, description and internal note can change. Businesses keep the terms they claimed.</div>
        )}
        <div className="owner-form-grid">
          <label className="owner-field">
            <span>Name *</span>
            <input value={f.name} maxLength={120} onChange={(e) => set({ name: e.target.value })} placeholder="Spring offer for small businesses" />
          </label>
          <label className="owner-field">
            <span>Type</span>
            <select value={f.offer_type} disabled={termsLocked} onChange={(e) => set({ offer_type: e.target.value })}>
              {TYPES.map(([key, label, req]) => {
                const m = missing(req);
                return <option key={key} value={key} disabled={m.length > 0}>{label}{m.length ? ` (needs ${missingText(m)})` : ""}</option>;
              })}
            </select>
          </label>
          <label className="owner-field wiz-field-full">
            <span>What businesses see</span>
            <textarea rows={2} maxLength={1000} value={f.description} onChange={(e) => set({ description: e.target.value })} placeholder="A short, plain description of the offer." />
          </label>
        </div>

        <fieldset className="of-fieldset" disabled={termsLocked}>
          <legend>Discount</legend>
          <div className="owner-form-grid">
            <label className="owner-field">
              <span>Kind</span>
              <select value={f.discount_kind} onChange={(e) => set({ discount_kind: e.target.value })}>
                <option value="percent">Percentage off</option>
                <option value="fixed">Fixed amount off</option>
              </select>
            </label>
            {f.discount_kind === "percent" ? (
              <label className="owner-field">
                <span>Percent off</span>
                <input inputMode="decimal" value={f.percent} onChange={(e) => set({ percent: e.target.value })} placeholder="10" />
              </label>
            ) : (
              <label className="owner-field">
                <span>Amount off ({f.currency.toUpperCase()})</span>
                <input inputMode="decimal" value={f.amount} onChange={(e) => set({ amount: e.target.value })} placeholder="25.00" />
              </label>
            )}
            <label className="owner-field">
              <span>How long</span>
              <select value={f.duration} onChange={(e) => set({ duration: e.target.value })}>
                <option value="once">The next bill only</option>
                <option value="repeating">A number of months</option>
                <option value="forever">For as long as they stay</option>
              </select>
            </label>
            {f.duration === "repeating" && (
              <label className="owner-field">
                <span>Months</span>
                <input type="number" min={1} max={36} value={f.duration_months} onChange={(e) => set({ duration_months: e.target.value })} />
              </label>
            )}
          </div>
          <p className="op-muted of-hint">Standard plan prices never change. The discount is applied by the payment provider once billing is connected.</p>
        </fieldset>

        <fieldset className="of-fieldset" disabled={termsLocked}>
          <legend>When</legend>
          <div className="owner-form-grid">
            <label className="owner-field">
              <span>Starts</span>
              <input type="datetime-local" value={f.start_local} onChange={(e) => set({ start_local: e.target.value })} />
            </label>
            <label className="owner-field">
              <span>Ends</span>
              <input type="datetime-local" value={f.end_local} onChange={(e) => set({ end_local: e.target.value })} />
            </label>
            <label className="owner-field">
              <span>Time zone for these times</span>
              <select value={f.timezone} onChange={(e) => set({ timezone: e.target.value })}>
                {(ZONES.includes(f.timezone) ? ZONES : [f.timezone, ...ZONES]).map((z) => <option key={z} value={z}>{z.replace(/_/g, " ")}</option>)}
              </select>
            </label>
          </div>
        </fieldset>

        <fieldset className="of-fieldset" disabled={termsLocked}>
          <legend>Who can get it</legend>
          <EligibilityEditor match={f.match} rules={f.rules} lookups={lookups}
            onChange={(match, rules) => set({ match, rules })} />
        </fieldset>

        <fieldset className="of-fieldset" disabled={termsLocked}>
          <legend>Limits and code</legend>
          <div className="owner-form-grid">
            <label className="owner-field">
              <span>Total claims (empty = no limit)</span>
              <input inputMode="numeric" value={f.max_redemptions} onChange={(e) => set({ max_redemptions: e.target.value })} />
            </label>
            <label className="owner-field">
              <span>Claims per business</span>
              <input inputMode="numeric" value={f.max_per_business} onChange={(e) => set({ max_per_business: e.target.value })} />
            </label>
            <label className="owner-field">
              <span>Promotional code (optional)</span>
              <input value={f.code} maxLength={40} onChange={(e) => set({ code: e.target.value.replace(/[^A-Za-z0-9_-]/g, "") })} placeholder="SPRING25" />
            </label>
            <label className="owner-field of-check">
              <input type="checkbox" checked={f.code_case_sensitive} onChange={(e) => set({ code_case_sensitive: e.target.checked })} />
              <span>Code must match capital letters exactly</span>
            </label>
            <label className="owner-field of-check wiz-field-full">
              <input type="checkbox" checked={f.stackable} onChange={(e) => set({ stackable: e.target.checked })} />
              <span>Can be combined with another offer waiting for the same business</span>
            </label>
          </div>
        </fieldset>

        <fieldset className="of-fieldset" disabled={termsLocked}>
          <legend>Where it appears</legend>
          <div className="of-channel-list">
            {CHANNELS.map(([key, label, hint, req]) => {
              const m = missing(req);
              const on = f.channels.includes(key);
              return (
                <label key={key} className={`of-check ${m.length ? "off" : ""}`}>
                  <input type="checkbox" disabled={m.length > 0} checked={on && !m.length}
                    onChange={(e) => set({ channels: e.target.checked ? [...f.channels, key] : f.channels.filter((c) => c !== key) })} />
                  <span><strong>{label}</strong>{m.length ? ` (not available yet: needs ${missingText(m)})` : hint ? `. ${hint}` : ""}</span>
                </label>
              );
            })}
          </div>
        </fieldset>

        <label className="owner-field">
          <span>Internal note (only Zella admins see this)</span>
          <textarea rows={2} maxLength={2000} value={f.internal_note} onChange={(e) => set({ internal_note: e.target.value })} />
        </label>

        {error && <div className="owner-form-error" role="alert">{error}</div>}
      </form>
    </Overlay>
  );
}

function EligibilityEditor({ match, rules, lookups, onChange }) {
  const update = (i, patch) => onChange(match, rules.map((r, j) => (j === i ? { ...r, ...patch } : r)));
  const remove = (i) => onChange(match, rules.filter((_, j) => j !== i));
  const used = new Set(rules.map((r) => r.field));
  const optionsFor = (field) =>
    field === "industry" ? lookups.industries.map((i) => [i.id, i.name])
      : field === "business" ? lookups.businesses.map((b) => [b.id, b.name])
      : SIMPLE_VALUES[field] ?? null;

  return (
    <div className="of-rules">
      {rules.length === 0 ? (
        <p className="op-muted">Every active business can get this offer. Add a rule to narrow it down.</p>
      ) : (
        <label className="owner-field of-inline">
          <span>A business qualifies when it matches</span>
          <select value={match} onChange={(e) => onChange(e.target.value, rules)}>
            <option value="all">all of these rules</option>
            <option value="any">any of these rules</option>
          </select>
        </label>
      )}
      {rules.map((r, i) => {
        const opts = optionsFor(r.field);
        const values = r.values ?? [];
        return (
          <div key={i} className="of-rule">
            <div className="of-rule-head">
              <strong>{RULE_FIELDS[r.field]}</strong>
              <button type="button" className="op-link" onClick={() => remove(i)}>Remove</button>
            </div>
            {r.field === "first_purchase" || r.field === "never_redeemed" ? (
              <select value={r.value === false ? "no" : "yes"} onChange={(e) => update(i, { value: e.target.value === "yes" })}>
                <option value="yes">Yes</option>
                <option value="no">No</option>
              </select>
            ) : r.field === "country" ? (
              <input value={values.join(", ")} placeholder="US, CA"
                onChange={(e) => update(i, { values: e.target.value.split(",").map((v) => v.trim().toUpperCase()).filter(Boolean) })} />
            ) : (
              <div className="of-value-grid">
                {(opts ?? []).map(([v, label]) => (
                  <label key={v} className="of-check">
                    <input type="checkbox" checked={values.includes(v)}
                      onChange={(e) => update(i, { values: e.target.checked ? [...values, v] : values.filter((x) => x !== v) })} />
                    <span>{label}</span>
                  </label>
                ))}
                {opts && opts.length === 0 && <span className="op-muted">Nothing to choose from yet.</span>}
              </div>
            )}
          </div>
        );
      })}
      <select className="of-add-rule" value="" onChange={(e) => {
        const field = e.target.value;
        if (!field) return;
        onChange(match, [...rules, field === "first_purchase" || field === "never_redeemed" ? { field, value: true } : { field, values: [] }]);
      }}>
        <option value="">＋ Add a rule...</option>
        {Object.entries(RULE_FIELDS).filter(([k]) => !used.has(k)).map(([k, label]) => <option key={k} value={k}>{label}</option>)}
      </select>
    </div>
  );
}

// ------------------------------------------------------------------ detail
const EVENT_TEXT = {
  created: "Created", edited: "Edited", submit: "Submitted", approve: "Approved", reject: "Sent back to draft",
  pause: "Paused", resume: "Resumed", back_to_draft: "Moved back to draft", archive: "Archived", end_now: "Ended early",
  activated: "Went live", expired: "Ended", activation_failed: "Could not go live", activation_error: "Error while going live",
  expiry_warning: "Ending-soon alert sent", claimed: "Claimed", claim_rejected: "Claim refused", claim_confirmed: "Paid",
  claim_reversed: "Refunded or disputed", claim_cancelled: "Claim cancelled", claim_lapsed: "Claim released (not paid in time)",
  code_rejected: "Code refused",
};
const REDEMPTION = {
  pending: ["Waiting for payment", "warning"], confirmed: ["Paid", "success"], reversed: ["Refunded", "danger"],
  cancelled: ["Cancelled", "neutral"], lapsed: ["Released", "neutral"], failed: ["Failed", "danger"],
};

function OfferDetail({ offerId, me, isOwner, lookups, onClose, onEdit, onChanged, onOpenBusiness }) {
  const [data, setData] = useState(null);
  const [audience, setAudience] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [ask, setAsk] = useState(null); // { action, label, needsNote, danger }
  const [note, setNote] = useState("");
  const [applyTo, setApplyTo] = useState("");
  const [applyNote, setApplyNote] = useState("");
  const [result, setResult] = useState("");

  const load = useCallback(async () => {
    try {
      const d = await rpc("zella_offer_detail", { p_id: offerId });
      setData(d);
      setAudience(await rpc("zella_offer_audience", { p_id: offerId }));
    } catch (err) {
      setError(friendly(err));
    }
  }, [offerId]);
  useEffect(() => { load(); }, [load]);

  async function act(action, extraNote) {
    setBusy(true);
    setError("");
    setResult("");
    try {
      const res = await rpc("zella_offer_transition", { p_id: offerId, p_action: action, p_note: extraNote || null });
      if (res && res.ok === false) {
        setError("Fix these first: " + (res.problems ?? []).join(" "));
      } else {
        setResult(`Done. The offer is now ${STATUS[res?.status]?.[0]?.toLowerCase() ?? res?.status}.`);
      }
      setAsk(null);
      setNote("");
      await load();
      onChanged();
    } catch (err) {
      setError(friendly(err));
    } finally {
      setBusy(false);
    }
  }

  async function apply() {
    setBusy(true);
    setError("");
    setResult("");
    try {
      const res = await rpc("zella_offer_apply_admin", { p_offer_id: offerId, p_business_id: applyTo, p_note: applyNote, p_idempotency_key: newIdempotencyKey("admin") });
      if (res.ok) setResult(res.repeat ? "This was already applied." : "Applied. It waits for the business's next payment.");
      else setError(res.message ?? "Couldn't apply this offer.");
      setApplyTo("");
      setApplyNote("");
      await load();
      onChanged();
    } catch (err) {
      setError(friendly(err));
    } finally {
      setBusy(false);
    }
  }

  async function changeClaim(id, status) {
    const why = window.prompt(status === "cancelled" ? "Why are you cancelling this claim?" : "Why is this paid claim being reversed?");
    if (!why || !why.trim()) return;
    setBusy(true);
    setError("");
    try {
      await rpc("zella_offer_set_redemption", { p_id: id, p_status: status, p_note: why.trim() });
      await load();
      onChanged();
    } catch (err) {
      setError(friendly(err));
    } finally {
      setBusy(false);
    }
  }

  if (!data) return <Overlay title="Offer" onClose={onClose}><p className="op-muted">{error || "Loading..."}</p></Overlay>;
  const o = data.offer;
  const s = o.status;
  const canApprove = isOwner && s === "pending_approval";
  const ownSubmission = o.submitted_by && o.submitted_by === me;
  const actions = [
    s === "draft" && { action: "submit", label: o.needs_approval_now ? "Submit for approval" : "Submit and schedule", primary: true },
    canApprove && { action: "approve", label: "Approve", primary: true },
    canApprove && { action: "reject", label: "Send back", needsNote: true },
    ["scheduled", "active"].includes(s) && { action: "pause", label: "Pause" },
    s === "paused" && { action: "resume", label: "Resume", primary: true },
    ["scheduled", "pending_approval"].includes(s) && { action: "back_to_draft", label: "Back to draft" },
    ["active", "paused", "scheduled"].includes(s) && { action: "end_now", label: "End now", danger: true },
    ["draft", "paused", "expired"].includes(s) && { action: "archive", label: "Archive" },
  ].filter(Boolean);

  return (
    <Overlay title={o.name} onClose={onClose} busy={busy} wide>
      <div className="of-detail">
        <div className="of-detail-top">
          {statusPill(s)}
          <span className="of-summary">{o.summary}</span>
          {o.code && <span className="of-code">Code {o.code}</span>}
        </div>
        {o.description && <p>{o.description}</p>}

        <dl className="op-facts">
          <div><dt>Runs</dt><dd>{o.start_local ? `${o.start_local.replace("T", " ")} → ${o.end_local.replace("T", " ")} (${o.timezone})` : "Not scheduled"}</dd></div>
          <div><dt>Limits</dt><dd>{o.max_redemptions ? `${o.max_redemptions} claims in total` : "No total limit"}, {o.max_per_business} per business{o.stackable ? ", can be combined" : ""}</dd></div>
          <div><dt>Who can get it</dt><dd>{describeEligibility(o.eligibility, lookups)}</dd></div>
          <div><dt>Where</dt><dd>{(o.channels ?? []).map((c) => CHANNELS.find((x) => x[0] === c)?.[1] ?? c).join(", ")}</dd></div>
          <div><dt>Approval</dt><dd>{o.approved_at ? `Approved ${formatDateTime(o.approved_at)}` : o.needs_approval_now ? "Needs a Zella owner's approval" : "Not needed"}</dd></div>
          {audience && <div><dt>Reach today</dt><dd>{audience.eligible} of {audience.total} businesses{audience.missing_size ? ` (${audience.missing_size} have no size set)` : ""}{audience.names?.length ? `: ${audience.names.join(", ")}${audience.eligible > audience.names.length ? "…" : ""}` : ""}</dd></div>}
          {o.internal_note && <div><dt>Internal note</dt><dd>{o.internal_note}</dd></div>}
        </dl>

        {o.problems?.length > 0 && ["draft", "pending_approval", "scheduled", "paused"].includes(s) && (
          <div className="wiz-note">
            <strong>Before this can go live:</strong>
            <ul className="of-list">{o.problems.map((p) => <li key={p}>{p}</li>)}</ul>
          </div>
        )}
        {canApprove && ownSubmission && <p className="op-muted">You submitted this offer. If another Zella owner is active, they have to approve it.</p>}
        {error && <div className="owner-form-error" role="alert">{error}</div>}
        {result && <div className="owner-form-success" role="status">{result}</div>}

        <div className="ic-actions of-actions">
          <button type="button" className="owner-secondary-button" onClick={() => onEdit(offerId)} disabled={busy || s === "archived"}>
            {s === "draft" ? "Edit" : "Edit wording"}
          </button>
          {actions.map((a) => (
            <button key={a.action} type="button" disabled={busy}
              className={a.danger ? "bd-danger-button" : a.primary ? "owner-primary-button" : "owner-secondary-button"}
              onClick={() => (a.needsNote || a.danger || a.action === "approve" || a.action === "submit" ? setAsk(a) : act(a.action))}>
              {a.label}
            </button>
          ))}
        </div>

        {ask && (
          <div className={`bd-confirm ${ask.danger ? "danger" : ""}`}>
            <h3>{ask.label}?</h3>
            <p>
              {ask.action === "end_now" && "New claims stop immediately. Businesses that already claimed keep their terms."}
              {ask.action === "approve" && `This approves ${o.summary} for ${audience ? `${audience.eligible} business${audience.eligible === 1 ? "" : "es"} today` : "the chosen businesses"}. It goes live at its start time.`}
              {ask.action === "submit" && (o.needs_approval_now
                ? "The terms are then locked and a Zella owner has to approve it."
                : `The terms are then locked. It goes live at its start time and can reach ${audience?.eligible ?? "the chosen"} business${audience?.eligible === 1 ? "" : "es"} today.`)}
              {ask.action === "reject" && "It goes back to draft so it can be changed."}
            </p>
            {ask.needsNote && (
              <label className="owner-field">
                <span>Note *</span>
                <input value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} />
              </label>
            )}
            <div className="ic-actions">
              <button type="button" className="owner-secondary-button" onClick={() => { setAsk(null); setNote(""); }} disabled={busy}>Go back</button>
              <button type="button" className={ask.danger ? "bd-danger-button" : "owner-primary-button"} disabled={busy || (ask.needsNote && !note.trim())}
                onClick={() => act(ask.action, note)}>{busy ? "Working..." : ask.label}</button>
            </div>
          </div>
        )}

        {s === "active" && (o.channels ?? []).some((c) => c === "sales" || c === "dashboard") && (
          <div className="wiz-section">
            <div className="wiz-section-head"><div><h3>Apply to a business</h3><p>For negotiated deals. The business must still qualify.</p></div></div>
            <div className="owner-form-grid">
              <label className="owner-field">
                <span>Business</span>
                <select value={applyTo} onChange={(e) => setApplyTo(e.target.value)}>
                  <option value="">Choose...</option>
                  {lookups.businesses.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
                </select>
              </label>
              <label className="owner-field">
                <span>Note (why)</span>
                <input value={applyNote} onChange={(e) => setApplyNote(e.target.value)} maxLength={500} />
              </label>
            </div>
            <div className="ic-actions">
              <button type="button" className="owner-primary-button" disabled={busy || !applyTo} onClick={apply}>Apply offer</button>
            </div>
          </div>
        )}

        <h3 className="of-h3">Claims ({data.redemptions.length})</h3>
        {data.redemptions.length === 0 ? <p className="op-muted">No business has claimed this offer yet.</p> : (
          <div className="owner-table-wrap">
            <table className="owner-table">
              <thead><tr><th>Business</th><th>Status</th><th>Claimed</th><th>How</th><th /></tr></thead>
              <tbody>
                {data.redemptions.map((r) => {
                  const [label, tone] = REDEMPTION[r.status] ?? [r.status, "neutral"];
                  return (
                    <tr key={r.id}>
                      <td>{onOpenBusiness ? <button type="button" className="op-link" onClick={() => { onClose(); onOpenBusiness(r.business_id); }}>{r.business}</button> : r.business}
                        {r.note && <div className="owner-table-secondary">{r.note}</div>}</td>
                      <td><Pill tone={tone}>{label}</Pill>{r.status === "pending" && r.hold_until && <div className="owner-table-secondary">Held until {formatDate(r.hold_until)}</div>}</td>
                      <td>{formatDateTime(r.created_at)}</td>
                      <td>{r.source === "admin" ? "Applied by Zella" : r.source === "code" ? "Code" : "Dashboard"}</td>
                      <td>
                        {r.status === "pending" && <button type="button" className="op-link" disabled={busy} onClick={() => changeClaim(r.id, "cancelled")}>Cancel</button>}
                        {r.status === "confirmed" && <button type="button" className="op-link" disabled={busy} onClick={() => changeClaim(r.id, "reversed")}>Mark reversed</button>}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}

        <h3 className="of-h3">History</h3>
        <ul className="of-history">
          {data.events.map((e) => (
            <li key={e.id}>
              <span>{EVENT_TEXT[e.kind] ?? e.kind}{e.business ? ` · ${e.business}` : ""}{e.detail?.reason ? ` (${String(e.detail.reason).replace(/_/g, " ")})` : ""}{e.detail?.note ? `: ${e.detail.note}` : ""}</span>
              <span className="op-muted">{e.actor ?? "Zella"} · {timeAgo(e.created_at)}</span>
              {e.detail?.problems && <span className="of-problem-line">{e.detail.problems.join(" ")}</span>}
            </li>
          ))}
        </ul>
      </div>
    </Overlay>
  );
}

function describeEligibility(el, lookups) {
  const rules = el?.rules ?? [];
  if (!rules.length) return "Every active business";
  const nameOf = (field, v) =>
    field === "industry" ? lookups.industries.find((i) => i.id === v)?.name ?? "an industry"
      : field === "business" ? lookups.businesses.find((b) => b.id === v)?.name ?? "a business"
      : (SIMPLE_VALUES[field] ?? []).find(([k]) => k === v)?.[1] ?? v;
  const parts = rules.map((r) =>
    r.field === "first_purchase" || r.field === "never_redeemed"
      ? `${RULE_FIELDS[r.field].toLowerCase()}: ${r.value ? "yes" : "no"}`
      : `${RULE_FIELDS[r.field]?.toLowerCase() ?? r.field}: ${(r.values ?? []).map((v) => nameOf(r.field, v)).join(" or ")}`);
  return parts.join(el.match === "any" ? "; or " : "; and ");
}

// ------------------------------------------------------------------ automation rules
const RULES = {
  auto_activate: ["Start offers on time", "Scheduled offers go live at their start time, after a last check that they're valid.", []],
  auto_expire: ["End offers on time", "Offers stop taking claims at their end time. Claims already made keep their terms.", []],
  approval_thresholds: ["Approval for big offers", "Offers above these limits need a Zella owner's approval before they can go live.", [["percent_bp", "Percent off at or above (in hundredths of a percent, 3000 = 30%)"], ["amount_cents", "Amount off at or above (in cents, 10000 = $100)"], ["max_redemptions", "Total claims above"]]],
  claim_hold: ["Release unpaid claims", "A claim that isn't paid within this many days is released, so it stops counting toward limits.", [["days", "Days to hold a claim"]]],
  expiry_warning: ["Ending-soon alert", "Alerts Zella admins before an offer ends.", [["days_before", "Days before the end"]]],
  limit_warning: ["Limit nearly reached", "Alerts Zella admins when this share of the claims has been used.", [["percent", "Percent used"]]],
  unusual_activity: ["Unusual claims", "Alerts Zella admins when an offer gets this many claims in one hour.", [["claims_per_hour", "Claims in one hour"]]],
  completion_report: ["Offer ended summary", "When an offer ends, admins get its claims, payments and what's still waiting.", []],
  abandoned_checkout: ["Abandoned checkout reminder", "Remind a business that started checkout but didn't finish.", [["delay_hours", "Wait (hours)"], ["max_reminders", "Most reminders"]]],
  intro_renewal: ["Introductory price renewal", "Move a business from its introductory price to the agreed renewal price.", []],
  referral: ["Referral rewards", "Reward a business when someone they referred pays for the first time.", []],
  win_back: ["Win-back offers", "Offer former customers a way back, within consent and contact limits.", [["inactive_days", "Days since they left"], ["max_contacts", "Most contacts"]]],
  promo_email: ["Promotional emails", "Email eligible business owners about an offer.", []],
};

function ruleState(r, lastRun) {
  if (r.missing?.length) return ["Unavailable", "neutral"];
  if (!r.enabled) return ["Paused", "warning"];
  if (["auto_activate", "auto_expire"].includes(r.key) && lastRun?.status === "failed") return ["Failed", "danger"];
  return ["Active", "success"];
}

export function RulesTab({ onChanged }) {
  const [data, setData] = useState(null);
  const [edit, setEdit] = useState({});
  const [busy, setBusy] = useState("");
  const [error, setError] = useState("");
  const [msg, setMsg] = useState("");

  const load = useCallback(async () => {
    try { setData(await rpc("zella_offer_rules_list")); } catch (err) { setError(friendly(err)); }
  }, []);
  useEffect(() => { load(); }, [load]);

  async function save(r, enabled) {
    setBusy(r.key);
    setError("");
    setMsg("");
    try {
      const cfg = {};
      for (const [k] of RULES[r.key]?.[2] ?? []) {
        const v = edit[r.key]?.[k];
        if (v !== undefined) {
          if (!/^\d+$/.test(String(v).trim())) throw new Error("BAD_CONFIG");
          cfg[k] = Number(v);
        }
      }
      await rpc("zella_offer_rule_save", { p_key: r.key, p_enabled: enabled, p_config: cfg });
      setEdit((e) => ({ ...e, [r.key]: undefined }));
      setMsg("Saved.");
      await load();
      onChanged();
    } catch (err) {
      setError(friendly(err));
    } finally {
      setBusy("");
    }
  }

  async function runNow() {
    setBusy("run");
    setError("");
    setMsg("");
    try {
      const res = await rpc("zella_offer_retry");
      setMsg(res.status === "skipped" ? "Another run was already in progress." : `Checked. ${res.changed} offer${res.changed === 1 ? "" : "s"} changed, ${res.lapsed} unpaid claim${res.lapsed === 1 ? "" : "s"} released.`);
      await load();
      onChanged();
    } catch (err) {
      setError(friendly(err));
    } finally {
      setBusy("");
    }
  }

  if (!data) return <div className="owner-loading op-gap">{error || "Loading rules..."}</div>;

  return (
    <div className="op-gap">
      <div className={data.scheduler_on ? "owner-form-success" : "wiz-note"}>
        {data.scheduler_on
          ? `The schedule runs every 5 minutes. Last run ${data.last_run ? timeAgo(data.last_run.started_at) : "not yet"}.`
          : "The automatic schedule isn't switched on yet (it starts at go-live). Until then, offers go live and end when you press Run now, when an admin changes an offer, or when someone tries to claim one after it has ended."}
        {" "}<button type="button" className="op-link" onClick={runNow} disabled={busy === "run"}>{busy === "run" ? "Running..." : "Run now"}</button>
      </div>
      {!data.is_owner && <p className="op-muted">Only a Zella owner can change these rules.</p>}
      {error && <div className="owner-form-error" role="alert">{error}</div>}
      {msg && <div className="owner-form-success" role="status">{msg}</div>}

      <div className="of-rule-grid">
        {data.rules.map((r) => {
          const [title, text, fields] = RULES[r.key] ?? [r.key, "", []];
          const [label, tone] = ruleState(r, data.last_run);
          const unavailable = r.missing?.length > 0;
          return (
            <section key={r.key} className="owner-panel of-rule-card">
              <div className="of-rule-card-head">
                <h3>{title}</h3>
                <Pill tone={tone}>{label}</Pill>
              </div>
              <p>{text}</p>
              {unavailable && <p className="op-muted">Needs {missingText(r.missing)}.</p>}
              {fields.length > 0 && (
                <div className="of-rule-fields">
                  {fields.map(([k, lab]) => (
                    <label key={k} className="owner-field">
                      <span>{lab}</span>
                      <input inputMode="numeric" disabled={!data.is_owner || unavailable}
                        value={edit[r.key]?.[k] ?? String(r.config?.[k] ?? "")}
                        onChange={(e) => setEdit((cur) => ({ ...cur, [r.key]: { ...(cur[r.key] ?? {}), [k]: e.target.value } }))} />
                    </label>
                  ))}
                </div>
              )}
              {data.is_owner && !unavailable && (
                <div className="ic-actions">
                  {edit[r.key] && <button type="button" className="owner-primary-button op-small" disabled={busy === r.key} onClick={() => save(r, r.enabled)}>Save settings</button>}
                  <button type="button" className="owner-secondary-button op-small" disabled={busy === r.key} onClick={() => save(r, !r.enabled)}>
                    {r.enabled ? "Pause" : "Turn on"}
                  </button>
                </div>
              )}
              {r.updated_by && <p className="op-muted of-small">Changed by {r.updated_by}, {timeAgo(r.updated_at)}</p>}
            </section>
          );
        })}
      </div>
    </div>
  );
}

// ------------------------------------------------------------------ monitoring
const REASON = {
  not_found: "Wrong or unknown code", paused: "Offer paused", expired: "Offer ended", not_started: "Not started yet",
  not_available_here: "Not offered there", code_required: "Needed a code", not_eligible: "Business didn't qualify",
  already_claimed: "Already claimed", limit_reached: "Limit reached", cannot_combine: "Couldn't be combined",
  too_many_attempts: "Too many code tries",
};

export function MonitorTab({ onOpenOffer }) {
  const [filter, setFilter] = useState("all");
  const [data, setData] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    try { setData(await rpc("zella_offer_monitor", { p_filter: filter, p_limit: 100 })); } catch (err) { setError(friendly(err)); }
  }, [filter]);
  useEffect(() => { load(); }, [load]);

  async function retry() {
    setBusy(true);
    setError("");
    try { await rpc("zella_offer_retry"); await load(); } catch (err) { setError(friendly(err)); } finally { setBusy(false); }
  }

  return (
    <div className="op-gap">
      <div className="of-filters">
        {[["all", "All runs"], ["failed", "Failed"], ["succeeded", "Succeeded"], ["retried", "Retried"], ["pending", "Running"]].map(([k, l]) => (
          <button key={k} type="button" className={`of-chip ${filter === k ? "on" : ""}`} onClick={() => setFilter(k)}>{l}</button>
        ))}
        <button type="button" className="owner-secondary-button op-small" onClick={retry} disabled={busy}>{busy ? "Retrying..." : "Retry now"}</button>
      </div>
      {error && <div className="owner-form-error op-gap" role="alert">{error}</div>}
      {!data ? <div className="owner-loading op-gap">Loading...</div> : (
        <>
          {data.failures.length > 0 && (
            <div className="owner-panel op-gap of-pad">
              <h3>Offers that couldn't go live</h3>
              <ul className="of-history">
                {data.failures.map((f) => (
                  <li key={f.id}>
                    <span><button type="button" className="op-link" onClick={() => onOpenOffer(f.offer_id)}>{f.offer ?? "Offer"}</button></span>
                    <span className="of-problem-line">{(f.detail?.problems ?? [f.detail?.error]).filter(Boolean).join(" ")}</span>
                    <span className="op-muted">{timeAgo(f.created_at)}</span>
                  </li>
                ))}
              </ul>
            </div>
          )}

          <div className="owner-table-wrap op-gap">
            <table className="owner-table">
              <thead><tr><th>Job</th><th>Started by</th><th>When</th><th>Status</th><th>Changed</th><th>Problem</th></tr></thead>
              <tbody>
                {data.runs.length === 0 && <tr><td colSpan={6} className="op-muted">No runs yet.</td></tr>}
                {data.runs.map((r) => (
                  <tr key={r.id}>
                    <td>Offer schedule</td>
                    <td>{r.trigger === "schedule" ? "Schedule" : r.trigger === "retry" ? `Retry (${r.started_by ?? "admin"})` : r.started_by ?? "Admin"}</td>
                    <td>{formatDateTime(r.started_at)}</td>
                    <td><Pill tone={r.status === "succeeded" ? "success" : r.status === "skipped" ? "neutral" : r.status === "running" ? "info" : "danger"}>{r.status}</Pill></td>
                    <td>{r.processed}{r.failures ? ` · ${r.failures} failed` : ""}</td>
                    <td className="owner-table-secondary">{r.error ?? ""}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <div className="owner-panel op-gap of-pad">
            <h3>Refused claims, last 7 days</h3>
            {data.rejections.length === 0 ? <p className="op-muted">None.</p> : (
              <ul className="of-history">
                {data.rejections.map((r) => <li key={r.reason}><span>{REASON[r.reason] ?? r.reason}</span><span>{r.count}</span></li>)}
              </ul>
            )}
          </div>
        </>
      )}
    </div>
  );
}

// ------------------------------------------------------------------ reports
const isoDay = (d) => d.toISOString().slice(0, 10);

export function ReportsTab() {
  const [from, setFrom] = useState(isoDay(new Date(Date.now() - 30 * 864e5)));
  const [to, setTo] = useState(isoDay(new Date()));
  const [data, setData] = useState(null);
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    setError("");
    try {
      const end = new Date(to + "T00:00:00");
      end.setDate(end.getDate() + 1);
      setData(await rpc("zella_offer_report", { p_from: new Date(from + "T00:00:00").toISOString(), p_to: end.toISOString() }));
    } catch (err) {
      setError(friendly(err));
    }
  }, [from, to]);
  useEffect(() => { load(); }, [load]);

  function exportCsv() {
    const rows = [["Offer", "Claims", "Paid", "Gross paid", "Discount given"],
      ...(data?.by_offer ?? []).map((r) => [r.offer_name, r.claims, r.paid, (r.gross_paid_cents / 100).toFixed(2), (r.discount_cents / 100).toFixed(2)])];
    const csv = rows.map((r) => r.map((c) => `"${String(c).replace(/"/g, '""')}"`).join(",")).join("\n");
    const url = URL.createObjectURL(new Blob([csv], { type: "text/csv" }));
    const a = document.createElement("a");
    a.href = url;
    a.download = `zella-offers-${from}-to-${to}.csv`;
    a.click();
    URL.revokeObjectURL(url);
  }

  const t = data?.totals;
  const rate = t && t.claims > 0 ? `${Math.round((t.paid / t.claims) * 100)}%` : "Not enough claims";

  return (
    <div className="op-gap">
      <div className="of-filters">
        <label className="owner-field of-inline"><span>From</span><input type="date" value={from} onChange={(e) => setFrom(e.target.value)} /></label>
        <label className="owner-field of-inline"><span>To</span><input type="date" value={to} onChange={(e) => setTo(e.target.value)} /></label>
        <button type="button" className="owner-secondary-button op-small" onClick={exportCsv} disabled={!data?.by_offer?.length}>Download CSV</button>
      </div>
      {error && <div className="owner-form-error op-gap" role="alert">{error}</div>}
      {t && (
        <>
          <div className="owner-stat-grid op-gap">
            <Stat label="Claims" value={t.claims} note={`${t.pending} waiting for payment`} />
            <Stat label="Paid" value={t.paid} note={`Claim-to-paid: ${rate}`} />
            <Stat label="Gross paid" value={money(t.gross_paid_cents)} note={t.refunded_cents ? `${money(t.refunded_cents)} refunded` : "Payments that confirmed a claim"} />
            <Stat label="Discount given" value={money(t.discount_cents)} note={t.discount_unknown ? `${t.discount_unknown} paid claim(s) without a known plan price` : "On paid claims"} />
          </div>
          <p className="op-muted op-gap of-small">
            Claims are counted by the day they were made. "Paid" means a verified payment from the payment provider confirmed the claim.
            Each payment counts once. Offer views aren't tracked, so there is no view-to-claim rate.
          </p>
          <div className="of-report-grid op-gap">
            <ReportTable title="By offer" cols={["Offer", "Claims", "Paid", "Gross paid"]}
              rows={(data.by_offer ?? []).map((r) => [r.offer_name, r.claims, r.paid, money(r.gross_paid_cents)])} />
            <ReportTable title="By business size" cols={["Size", "Claims", "Paid"]} rows={(data.by_size ?? []).map((r) => [r.size, r.claims, r.paid])} />
            <ReportTable title="By industry" cols={["Industry", "Claims", "Paid"]} rows={(data.by_industry ?? []).map((r) => [r.industry, r.claims, r.paid])} />
            <ReportTable title="By how it was claimed" cols={["Source", "Claims", "Paid"]}
              rows={(data.by_source ?? []).map((r) => [r.source === "admin" ? "Applied by Zella" : r.source === "code" ? "Code" : "Dashboard", r.claims, r.paid])} />
          </div>
        </>
      )}
    </div>
  );
}

function Stat({ label, value, note }) {
  return (
    <div className="owner-stat-card">
      <div className="owner-stat-label">{label}</div>
      <div className="owner-stat-value">{value}</div>
      <div className="owner-stat-note">{note}</div>
    </div>
  );
}

function ReportTable({ title, cols, rows }) {
  return (
    <section className="owner-panel of-pad">
      <h3>{title}</h3>
      {rows.length === 0 ? <p className="op-muted">No claims in these dates.</p> : (
        <table className="owner-table">
          <thead><tr>{cols.map((c) => <th key={c}>{c}</th>)}</tr></thead>
          <tbody>{rows.map((r, i) => <tr key={i}>{r.map((c, j) => <td key={j}>{c}</td>)}</tr>)}</tbody>
        </table>
      )}
    </section>
  );
}
