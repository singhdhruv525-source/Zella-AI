import { useState } from "react";
import { supabase } from "../supabase";
import { friendly } from "../BusinessShared";
import { Banner, Card, Facts, Field, LoadState, Pill, SaveBar, Table, useAsync, useForm } from "./SettingsKit";
import "../billing.css";

// Billing & Subscription for the business owner (REQ-BIL-05). Everything comes from zella_billing_overview, which the
// database answers only for the owner (and billing admins): staff and other businesses are refused there, not here.
// Nothing on these pages charges money: buying packs, invoices and the payment method arrive with online payments.

const RES = { minutes: ["Minutes", "AI call minutes"], texts: ["Texts", "texts"], emails: ["Emails", "emails"] };
const KIND = { rollover: "Rolled over", plan: "Plan", pack: "Pack", buffer: "Reminder buffer" };
const money = (cents) => (cents == null ? "—" : `$${(cents / 100).toLocaleString("en-US", { minimumFractionDigits: cents % 100 ? 2 : 0, maximumFractionDigits: 2 })}`);
const num = (n) => (n == null ? "—" : Number(n).toLocaleString("en-US", { maximumFractionDigits: 1 }));
const LANG = { en: "English", es: "Spanish" };

async function overview(businessId) {
  const { data, error } = await supabase.rpc("zella_billing_overview", { p_business_id: businessId });
  if (error) throw error;
  return data;
}

function ownerOnly(err) {
  return /NOT_ALLOWED/.test(err?.message ?? String(err));
}

export function useBillingOverview(w) {
  return useAsync(() => overview(w.id).catch((err) => { if (ownerOnly(err)) return { notOwner: true }; throw new Error(friendly(err)); }), [w.id]);
}

function NotOwner() {
  return <Card title="Billing is for the business owner" sub="Only the owner can see the plan, prices and usage balances. Ask them, or contact Zella Voice support." />;
}

const day = (iso) => (iso ? new Date(iso).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" }) : "—");

function Meter({ used, included, over }) {
  const pct = included > 0 ? Math.min(100, Math.round((used / included) * 100)) : 0;
  const tone = used >= included && included > 0 ? "danger" : pct >= 80 ? "warning" : "ok";
  return (
    <div className={`zs-meter ${tone}`} role="meter" aria-valuemin={0} aria-valuemax={included || 0} aria-valuenow={Math.min(used, included || 0)}
      aria-label={`${num(used)} of ${num(included)} used${over > 0 ? `, ${num(over)} over` : ""}`}>
      <span style={{ width: `${pct}%` }} />
    </div>
  );
}

function UsageTile({ resource, u }) {
  const [label, unit] = RES[resource];
  if (!u?.configured) {
    return <div className="bp-tile"><div className="bp-tile-top">{label}</div><div className="bp-tile-note">Starts with your first billing period.</div></div>;
  }
  const used = Number(u.used), inc = Number(u.included), over = Number(u.over);
  const out = used >= inc && inc > 0;
  return (
    <div className="bp-tile">
      <div className="bp-tile-top"><span>{label}</span>
        {out ? <Pill tone="danger">Used up</Pill> : u.percent_used >= 80 ? <Pill tone="warning">Over 80%</Pill> : <Pill tone="success">{num(u.percent_used)}% used</Pill>}</div>
      <div className="bp-tile-value">{num(used)} <small>/ {num(inc)}</small></div>
      <Meter used={used} included={inc} over={over} />
      <div className="bp-tile-note">
        {num(u.remaining)} {unit} left{Number(u.buffer) > 0 ? ` · reminder buffer ${num(u.buffer_remaining)} of ${num(u.buffer)}` : ""}{over > 0 ? ` · ${num(over)} over` : ""}
      </div>
    </div>
  );
}

// Settings > Billing and subscription > Current plan
export function BillingPlanPanel({ w }) {
  const state = useBillingOverview(w);
  return (
    <LoadState state={state}>{(o) => {
      if (o.notOwner) return <NotOwner />;
      if (!o.plan) return <Card title="Your plan" sub="Your plan hasn't been set up yet. The Zella Voice team sets it with you before your first payment." />;
      const p = o.plan, s = o.subscription, period = o.period;
      const status = !s ? ["", "Not started"] : s.status === "trial" ? ["accent", `Free trial until ${day(s.trial_end_at)}`]
        : s.status === "active" ? ["success", "Active"] : ["warning", (s.status.charAt(0).toUpperCase() + s.status.slice(1)).replace(/_/g, " ")];
      return (
        <>
          <section className="zs-card"><div className="zs-card-body bp-pad">
            <div className="bp-hero">
              <div>
                <div className="bp-hero-name"><h3>{p.tier === "pro" ? "Pro" : "Base"} plan</h3><Pill tone={status[0]}>{status[1]}</Pill></div>
                <div className="bp-price" style={{ marginTop: 6 }}><strong>{money(p.price_cents)}</strong><span>{p.billing_interval === "yearly" ? "per year" : "per month"} · USD</span></div>
                {p.setup_fee_cents > 0 && <p className="bp-sub">One-time setup fee {money(p.setup_fee_cents)}</p>}
              </div>
              {s?.current_period_end && s.status !== "trial" && <div style={{ textAlign: "right" }}><p className="bp-muted">Next charge</p><strong>{day(s.current_period_end)}</strong></div>}
            </div>
            <div className="bp-chips">
              <span className="bp-chip">{num(p.minutes)} AI minutes / month</span>
              <span className="bp-chip">{num(p.texts)} texts / month</span>
              <span className="bp-chip">{num(p.emails)} emails / month</span>
              <span className="bp-chip">{p.team_seats} {p.team_seats === 1 ? "user" : "users"}</span>
              <span className="bp-chip">{p.phone_numbers} phone {p.phone_numbers === 1 ? "number" : "numbers"}</span>
              <span className="bp-chip">{p.locations} {p.locations === 1 ? "location" : "locations"}</span>
              <span className="bp-chip">{p.languages.map((l) => LANG[l] ?? l).join(" & ")}</span>
            </div>
          </div></section>
          <section className="zs-card">
            <div className="zs-card-head bp-pad-head"><div><h3>This month</h3>
              <p>{period ? `${day(period.from)} – ${day(period.to)} · ${period.days_left} ${period.days_left === 1 ? "day" : "days"} left${period.trial ? " · trial allowance" : ""}` : "Your first billing period hasn't started."}</p></div></div>
            <div className="zs-card-body bp-pad">
            <div className="bp-tiles">{["minutes", "texts", "emails"].map((r) => <UsageTile key={r} resource={r} u={o.usage?.[r]} />)}</div>
            <p className="zs-muted" style={{ margin: "14px 0 0" }}>We tell you at 80% and 100%. A call in progress is never cut. At 100% of texts or emails, appointment confirmations and reminders keep going for a short while (a 5% buffer).</p>
            </div>
          </section>
        </>
      );
    }}</LoadState>
  );
}

// Settings > Billing and subscription > Balances and packs
export function BillingBalancesPanel({ w }) {
  const state = useBillingOverview(w);
  return (
    <LoadState state={state}>{(o) => {
      if (o.notOwner) return <NotOwner />;
      const days = o.period?.days_left;
      return (
        <>
          <Card title="What you have this month" sub="Used in this order: rolled-over minutes, your plan, then packs (oldest first).">
            <Table rows={o.balances} rowKey={(b) => `${b.resource}-${b.kind}-${b.pack ?? ""}-${b.expires_at}`} empty="No balances yet: your first billing period hasn't started."
              columns={[["What", (b) => `${RES[b.resource][0]}: ${KIND[b.kind]}${b.pack ? ` (${b.pack.replace("_", " ")})` : ""}`],
                ["Included", (b) => num(b.granted)], ["Used", (b) => num(b.used)], ["Left", (b) => num(b.remaining)], ["Expires", (b) => day(b.expires_at)]]} />
          </Card>
          <Card title="How rollover works">
            <Facts rows={[["Minutes", "Unused minutes roll over for one month, up to 20% of your plan's minutes (and 20% of each minutes pack), then expire"],
              ["Texts and emails", "Don't roll over; they refresh every month"],
              ["Yearly plans", "Charged once a year; minutes, texts and emails still refresh every month"]]} />
          </Card>
          <Card title="Add-on packs" sub={`Packs last until the end of the month you buy them in${days != null ? ` (${days} ${days === 1 ? "day" : "days"} left now)` : ""}. Only part of a minutes pack rolls over.`}>
            <Table rows={o.packs} rowKey={(p) => p.code} columns={[["Pack", (p) => `${num(p.quantity)} ${RES[p.resource][1]}`], ["Price", (p) => money(p.price_cents)],
              ["Rolls over if unused", (p) => (p.rollover_if_unused > 0 ? `up to ${num(p.rollover_if_unused)} minutes` : "No")]]} />
            <Banner>Packs can't be bought online yet. Ask Zella Voice support to add one.</Banner>
          </Card>
        </>
      );
    }}</LoadState>
  );
}

// Settings > Billing and subscription > Auto-reload (owner only; stored, not active until payments)
export function AutoReloadPanel({ w }) {
  const state = useBillingOverview(w);
  return (
    <LoadState state={state}>{(o) => (o.notOwner ? <NotOwner /> : <AutoReloadForms w={w} o={o} reload={state.reload} />)}</LoadState>
  );
}

function AutoReloadForms({ w, o, reload }) {
  return ["minutes", "texts", "emails"].map((r) => <AutoReloadForm key={r} w={w} resource={r} packs={o.packs.filter((p) => p.resource === r)}
    current={o.auto_reload.find((a) => a.resource === r)} onSaved={reload} />);
}

function AutoReloadForm({ w, resource, packs, current, onSaved }) {
  const form = useForm({ enabled: current?.enabled ?? false, threshold: String(current?.threshold ?? (resource === "minutes" ? 10 : resource === "texts" ? 50 : 500)),
    pack: current?.pack ?? packs[0]?.code ?? "", cap: current ? String(current.monthly_cap_cents / 100) : String((packs[0]?.price_cents ?? 0) / 100 * 2) });
  const [error, setError] = useState("");
  const v = form.values;
  const pack = packs.find((p) => p.code === v.pack);
  const capCents = Math.round(Number(v.cap) * 100);
  const threshold = Number(v.threshold);
  const problem = !(Number.isInteger(threshold) && threshold >= 0) ? "Enter a whole number, 0 or more"
    : !(capCents >= (pack?.price_cents ?? 0)) ? `The monthly limit must be at least one pack (${money(pack?.price_cents)})` : "";
  const save = () => form.save(async (x) => {
    setError("");
    const { error: e } = await supabase.rpc("zella_auto_reload_save", { p_business_id: w.id, p_resource: resource, p_enabled: x.enabled,
      p_threshold: Number(x.threshold), p_pack_code: x.pack, p_monthly_cap_cents: Math.round(Number(x.cap) * 100) });
    if (e) { setError(friendly(e)); throw e; }
    onSaved?.();
  }, "Saved. Automatic reloads start once online payments are switched on.");
  return (
    <Card title={`Auto-reload: ${RES[resource][0].toLowerCase()}`} sub="Off unless you switch it on. A reload never goes over your monthly limit.">
      <div className="zs-grid">
        <label className="zs-check full"><input type="checkbox" checked={v.enabled} onChange={(e) => form.set("enabled")(e.target.checked)} /><span>Buy a pack automatically when I'm running low</span></label>
        <Field label={`When ${RES[resource][1]} left reach`} error={problem.startsWith("Enter") ? problem : ""}><input inputMode="numeric" value={v.threshold} onChange={form.set("threshold")} /></Field>
        <Field label="Buy this pack"><select value={v.pack} onChange={form.set("pack")}>{packs.map((p) => <option key={p.code} value={p.code}>{num(p.quantity)} for {money(p.price_cents)}</option>)}</select></Field>
        <Field label="Monthly limit (USD)" error={problem.startsWith("The") ? problem : ""}><input inputMode="decimal" value={v.cap} onChange={form.set("cap")} /></Field>
      </div>
      <Banner tone="error">{error}</Banner>
      <SaveBar form={form} disabled={Boolean(problem)} onSave={save} />
    </Card>
  );
}
