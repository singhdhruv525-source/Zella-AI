import { useState } from "react";
import { supabase } from "../supabase";
import { callOwnerFunction } from "../CreateBusinessWizard";
import { TimeZoneSelect } from "../formFields";
import { uploadImage } from "./PersonalPanels";
import { Banner, Card, Confirm, Empty, Facts, Field, LinkRows, LoadState, Needs, Pill, SaveBar, Table, Toggle, money, useAsync, useForm, when, words } from "./SettingsKit";

// Admin Settings content. Every panel reads and writes through the
// owner-provision-business function, which checks the admin's role and
// permission first; buttons the role can't use are hidden, and the server
// refuses them anyway.

export const can = (me, permission) => Boolean(me?.permissions?.includes(permission));
const call = (action, payload) => callOwnerFunction(action, payload);
const moneyMap = (m) => (m && Object.keys(m).length ? Object.entries(m).map(([c, v]) => money(v, c)).join(" + ") : money(0));
const ROLE_NOTE = "Your admin role can see this but not change it.";

/* ---------------- 1. General ---------------- */

export function PlatformProfile({ me }) {
  const state = useAsync(() => call("platform_profile_get"), []);
  return <LoadState state={state}>{(d) => <ProfileForm initial={d.profile} canEdit={can(me, "platform.configure")} />}</LoadState>;
}

function ProfileForm({ initial, canEdit }) {
  const form = useForm({
    display_name: initial.display_name ?? "Zella AI", legal_name: initial.legal_name ?? "", support_email: initial.support_email ?? "",
    support_phone: initial.support_phone ?? "", website: initial.website ?? "", address: initial.address ?? "",
    country: initial.country ?? "US", timezone: initial.timezone ?? "America/New_York", currency: initial.currency ?? "USD",
  });
  const f = form.values;
  return (
    <Card title="Platform profile" sub="Zella's own details, shown on sign-in pages and to businesses in Help. Each business's own details are separate.">
      {!canEdit && <Banner tone="warn">{ROLE_NOTE}</Banner>}
      <fieldset disabled={!canEdit} style={{ border: 0, padding: 0, margin: 0 }}>
        <div className="zs-grid">
          <Field label="Display name"><input value={f.display_name} onChange={form.set("display_name")} maxLength={80} /></Field>
          <Field label="Legal company name"><input value={f.legal_name} onChange={form.set("legal_name")} maxLength={200} /></Field>
          <Field label="Support email"><input type="email" value={f.support_email} onChange={form.set("support_email")} /></Field>
          <Field label="Support phone" hint="With country code, like +15551234567."><input value={f.support_phone} onChange={form.set("support_phone")} inputMode="tel" /></Field>
          <Field label="Website" hint="https:// address"><input value={f.website} onChange={form.set("website")} inputMode="url" /></Field>
          <Field label="Business address" full><input value={f.address} onChange={form.set("address")} maxLength={300} /></Field>
          <Field label="Default country" hint="Two letters, like US."><input value={f.country} maxLength={2} onChange={(e) => form.set("country")(e.target.value.toUpperCase())} /></Field>
          <Field label="Default currency">
            <select value={f.currency} onChange={form.set("currency")}>{["USD", "CAD", "GBP", "EUR", "AUD"].map((c) => <option key={c}>{c}</option>)}</select>
          </Field>
          <div className="zs-field full"><span>Default platform time zone</span><TimeZoneSelect value={f.timezone} onChange={form.set("timezone")} /></div>
        </div>
      </fieldset>
      <Facts rows={[["Date format", "US, for example Oct 26, 2026"], ["Time format", "12-hour, for example 3:04 PM"], ["Default language", "English (US)"]]} />
      {canEdit && <SaveBar form={form} onSave={() => form.save(async (v) => (await call("platform_profile_save", { section: "profile", values: v })).value)} />}
    </Card>
  );
}

export function Branding({ me }) {
  const state = useAsync(() => call("platform_profile_get"), []);
  return (
    <>
      <LoadState state={state}>{(d) => <BrandingForm initial={d.branding} canEdit={can(me, "platform.configure")} />}</LoadState>
      <Needs title="Themes, accent colour, typography, density and dashboard layout aren't adjustable yet"
        have="Zella uses one fixed theme (Oat & Slate). Making it adjustable needs a theme layer that reads saved settings instead of fixed CSS. Each business's branding stays its own either way.">
        These would change the look for every admin and business, so they need that theme layer first.
      </Needs>
      <Needs title="Email branding isn't adjustable yet" have="Emails are plain text with a simple layout (sql/zella_owner_emails.sql).">
        Branded emails need an HTML template that reads the platform logo and colours.
      </Needs>
    </>
  );
}

function BrandingForm({ initial, canEdit }) {
  const form = useForm({ logo_url: initial.logo_url ?? "", login_headline: initial.login_headline ?? "" });
  const [upload, setUpload] = useState({ busy: false, error: "" });
  return (
    <Card title="Logo and sign-in page" sub="Shown on the admin and business sign-in pages. PNG, JPEG or WebP, up to 2 MB.">
      {!canEdit && <Banner tone="warn">{ROLE_NOTE}</Banner>}
      <div className="zs-cols">
        <div>
          <Field label="Sign-in page headline" hint="Optional. Shown under the logo."><input value={form.values.login_headline} onChange={form.set("login_headline")} maxLength={120} disabled={!canEdit} /></Field>
          {canEdit && (
            <p style={{ marginTop: 12 }}>
              <label className="zs-btn sm">{upload.busy ? "Uploading…" : form.values.logo_url ? "Replace logo" : "Upload logo"}
                <input type="file" hidden accept="image/png,image/jpeg,image/webp" disabled={upload.busy} onChange={async (e) => {
                  const file = e.target.files?.[0]; if (!file) return;
                  setUpload({ busy: true, error: "" });
                  try { form.set("logo_url")(await uploadImage("platform/logo", file)); setUpload({ busy: false, error: "" }); }
                  catch (err) { setUpload({ busy: false, error: err.message }); }
                }} />
              </label>{" "}
              {form.values.logo_url && <button type="button" className="zs-btn sm" onClick={() => form.set("logo_url")("")}>Remove</button>}
            </p>
          )}
          <Banner tone="error">{upload.error}</Banner>
        </div>
        <div className="zs-card" style={{ padding: 16, textAlign: "center" }}>
          <small className="zs-muted">Preview</small>
          <div style={{ marginTop: 8 }}>{form.values.logo_url ? <img src={form.values.logo_url} alt="Logo preview" style={{ maxHeight: 56, maxWidth: "100%" }} /> : <strong>zella ai</strong>}</div>
          {form.values.login_headline && <p className="zs-muted">{form.values.login_headline}</p>}
        </div>
      </div>
      {canEdit && <SaveBar form={form} onSave={() => form.save(async (v) => (await call("platform_profile_save", { section: "branding", values: v })).value)} />}
    </Card>
  );
}

export function Localization() {
  const state = useAsync(() => call("platform_profile_get"), []);
  return (
    <LoadState state={state}>{(d) => (
      <>
        <Card title="What the app supports today">
          <Facts rows={[
            ["Languages", "English (US) only"], ["Date format", "Oct 26, 2026"], ["Time format", "3:04 PM"],
            ["Currency", `${d.profile.currency ?? "USD"} (from Platform profile)`], ["Platform time zone", (d.profile.timezone ?? "America/New_York").replace(/_/g, " ")],
            ["Business times", "Each business's own time zone"],
          ]} />
        </Card>
        <Needs title="Other languages aren't available yet" have="Every screen, text message and email is written in English.">
          Supporting another language needs translated copies of the app's text, texts and emails, plus a language setting that each screen reads.
          The AI receptionist's own language handling is separate (AI providers).
        </Needs>
      </>
    )}</LoadState>
  );
}

export function Maintenance({ me }) {
  const state = useAsync(() => call("platform_profile_get"), []);
  const allowed = ["zella_owner", "super_admin"].includes(me?.role);
  return <LoadState state={state}>{(d) => <MaintenanceForm initial={d.maintenance} allowed={allowed} reload={state.reload} />}</LoadState>;
}

const localInput = (v) => (v ? new Date(new Date(v).getTime() - new Date(v).getTimezoneOffset() * 60000).toISOString().slice(0, 16) : "");

function MaintenanceForm({ initial, allowed, reload }) {
  const [draft, setDraft] = useState({ message: initial.message ?? "", starts: localInput(initial.starts_at), ends: localInput(initial.ends_at) });
  const [confirm, setConfirm] = useState(null);
  const active = Boolean(initial.active) && (!initial.ends_at || new Date(initial.ends_at) > new Date());
  const now = active && (!initial.starts_at || new Date(initial.starts_at) <= new Date());
  const save = (on) => async (reason) => {
    await call("maintenance_save", { active: on, message: draft.message, startsAt: draft.starts ? new Date(draft.starts).toISOString() : null,
      endsAt: draft.ends ? new Date(draft.ends).toISOString() : null, reason });
    reload();
  };
  return (
    <>
      <Card title="Status">
        <Facts rows={[["Maintenance notice", now ? <Pill tone="warning">Showing now</Pill> : active ? <Pill tone="accent">Scheduled</Pill> : <Pill>Off</Pill>],
          ["Message", initial.message], ["Starts", when(initial.starts_at)], ["Ends", when(initial.ends_at)], ["Last changed", when(initial.set_at)]]} />
      </Card>
      <Card title="Announce maintenance" sub="Shows a notice on every sign-in page, in the admin dashboard and in every business's workspace. It does not stop the app or block saving.">
        {!allowed && <Banner tone="warn">Only a Zella owner or super admin can change maintenance.</Banner>}
        <fieldset disabled={!allowed} style={{ border: 0, padding: 0, margin: 0 }}>
          <div className="zs-grid">
            <Field label="Message people will see" full><textarea rows={2} maxLength={300} value={draft.message} onChange={(e) => setDraft({ ...draft, message: e.target.value })} placeholder="Zella will be unavailable from 10 PM to 11 PM ET for an upgrade." /></Field>
            <Field label="Starts" hint="Empty: now"><input type="datetime-local" value={draft.starts} onChange={(e) => setDraft({ ...draft, starts: e.target.value })} /></Field>
            <Field label="Ends" hint="Empty: until you turn it off"><input type="datetime-local" value={draft.ends} onChange={(e) => setDraft({ ...draft, ends: e.target.value })} /></Field>
          </div>
        </fieldset>
        {allowed && (
          <div className="zs-savebar">
            <span className="zs-savebar-state" />
            {active && <button type="button" className="zs-btn" onClick={() => setConfirm("off")}>Turn off</button>}
            <button type="button" className="zs-btn primary" disabled={!draft.message.trim()} onClick={() => setConfirm("on")}>{active ? "Update notice" : "Turn on"}</button>
          </div>
        )}
      </Card>
      <Needs title="Read-only mode isn't available" have="The notice above tells everyone; nothing is blocked.">
        Blocking changes during maintenance needs a check in every database function and screen that saves something.
      </Needs>
      {confirm && <Confirm title={confirm === "on" ? "Show the maintenance notice?" : "Turn the maintenance notice off?"} reason word={confirm === "on" ? "MAINTENANCE" : undefined}
        confirmLabel={confirm === "on" ? "Show notice" : "Turn off"} onClose={() => setConfirm(null)} onConfirm={save(confirm === "on")}>
        {confirm === "on" ? "Every admin and every business will see it on their next page load." : "The notice disappears for everyone."}
      </Confirm>}
    </>
  );
}

/* ---------------- 2. Businesses ---------------- */

const STATUS_OPTIONS = [["", "Any status"], ["live", "Live"], ["setup", "In setup"], ["suspended", "Suspended"], ["cancelling", "Cancelling"], ["cancelled", "Cancelled"]];
const businessState = (b) => b.cancelled_at ? ["Cancelled", "danger"] : b.suspended_at ? ["Suspended", "danger"] : b.cancel_at ? ["Cancelling", "warning"] : b.onboarding_status === "active" ? ["Live", "success"] : ["In setup", "accent"];

export function AllBusinesses({ openBusiness }) {
  const [filters, setFilters] = useState({ q: "", industryId: "", planId: "", status: "", onboarding: "", createdFrom: "", createdTo: "", page: 0 });
  const [expanded, setExpanded] = useState(null);
  const state = useAsync(() => call("tenants_search", { ...filters, createdFrom: filters.createdFrom || null, createdTo: filters.createdTo || null }), [JSON.stringify(filters)]);
  const set = (k) => (e) => setFilters({ ...filters, [k]: e.target.value, page: 0 });
  const d = state.data;
  return (
    <Card title="All businesses" sub="Search and filter every workspace. Open one for its full page and lifecycle actions.">
      <div className="zs-grid">
        <Field label="Search by name"><input type="search" value={filters.q} onChange={set("q")} /></Field>
        <Field label="Industry"><select value={filters.industryId} onChange={set("industryId")}><option value="">Any industry</option>{(d?.industries ?? []).map((i) => <option key={i.id} value={i.id}>{i.name}</option>)}</select></Field>
        <Field label="Plan"><select value={filters.planId} onChange={set("planId")}><option value="">Any plan</option>{(d?.plans ?? []).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select></Field>
        <Field label="Status"><select value={filters.status} onChange={set("status")}>{STATUS_OPTIONS.map(([v, t]) => <option key={v} value={v}>{t}</option>)}</select></Field>
        <Field label="Onboarding step"><select value={filters.onboarding} onChange={set("onboarding")}>
          <option value="">Any step</option>
          {["started", "business_info", "industry_setup", "owner_setup", "plan_setup", "ai_setup", "communications_setup", "calendar_setup", "automation_setup", "team_setup", "customer_import", "testing", "ready", "active", "paused", "failed"].map((s) => <option key={s} value={s}>{words(s)}</option>)}
        </select></Field>
        <Field label="Created from"><input type="date" value={filters.createdFrom} onChange={set("createdFrom")} /></Field>
        <Field label="Created before"><input type="date" value={filters.createdTo} onChange={set("createdTo")} /></Field>
      </div>
      <div style={{ marginTop: 12 }}>
        <LoadState state={state}>{(r) => (
          <>
            <Table rows={r.rows} empty="No businesses match." columns={[
              ["Business", (b) => <button type="button" className="zs-link" onClick={() => openBusiness(b.id)}>{b.name}</button>],
              ["Industry", (b) => b.industry ?? "—"],
              ["Status", (b) => { const [t, tone] = businessState(b); return <Pill tone={tone}>{t}</Pill>; }],
              ["Plan", (b) => (b.subscription ? `${b.subscription.plan ?? "Plan"} · ${words(b.subscription.status)}` : "No subscription")],
              ["Team", (b) => b.members],
              ["Integrations", (b) => (b.integrations.total ? `${b.integrations.total}${b.integrations.failing ? ` · ${b.integrations.failing} failing` : ""}` : "None")],
              ["Created", (b) => when(b.created_at)],
              ["", (b) => <button type="button" className="zs-btn sm" onClick={() => setExpanded(expanded === b.id ? null : b.id)}>{expanded === b.id ? "Hide" : "Summary"}</button>],
            ]} />
            {expanded && <TenantSummary businessId={expanded} />}
            <Pager page={r.page} size={r.size} total={r.total} onPage={(page) => setFilters({ ...filters, page })} />
          </>
        )}</LoadState>
      </div>
    </Card>
  );
}

export function Pager({ page, size, total, onPage }) {
  const pages = Math.max(1, Math.ceil(total / size));
  if (pages <= 1) return <p className="zs-muted" style={{ marginTop: 8 }}>{total} shown</p>;
  return (
    <div className="zs-savebar">
      <span className="zs-savebar-state">{total} total · page {page + 1} of {pages}</span>
      <button type="button" className="zs-btn sm" disabled={page === 0} onClick={() => onPage(page - 1)}>Previous</button>
      <button type="button" className="zs-btn sm" disabled={page + 1 >= pages} onClick={() => onPage(page + 1)}>Next</button>
    </div>
  );
}

export function TenantSummary({ businessId }) {
  const state = useAsync(() => call("tenant_summary", { businessId }), [businessId]);
  return (
    <div className="zs-card" style={{ marginTop: 12 }}>
      <div className="zs-card-body">
        <LoadState state={state}>{(s) => (
          <div className="zs-cols">
            <div>
              <h3 style={{ margin: "0 0 6px", fontSize: 14 }}>Plan and usage this period</h3>
              <Facts rows={[["Plan", s.entitlements?.plan?.name ?? (s.subscription ? "Plan" : "No subscription")], ["Status", s.subscription ? words(s.subscription.status) : "—"],
                ["AI minutes", `${s.entitlements?.usage?.voice_minutes ?? 0}${s.entitlements?.limits?.voice_minutes ? ` of ${s.entitlements.limits.voice_minutes}` : ""}`],
                ["Texts sent", s.entitlements?.usage?.sms_messages ?? 0], ["Team seats used", s.entitlements?.usage?.team_members ?? 0]]} />
            </div>
            <div>
              <h3 style={{ margin: "0 0 6px", fontSize: 14 }}>Team</h3>
              {s.members.length ? <ul className="zs-rows">{s.members.map((m) => <li key={m.user_id}><div><strong>{m.email ?? "Member"}</strong><small>{words(m.role)} · {m.status} · last sign-in {when(m.last_sign_in_at)}</small></div></li>)}</ul> : <Empty>No members yet.</Empty>}
            </div>
            <div>
              <h3 style={{ margin: "0 0 6px", fontSize: 14 }}>Integrations</h3>
              {s.integrations.length ? <ul className="zs-rows">{s.integrations.map((i) => <li key={i.provider}><div><strong>{words(i.provider)}</strong><small>{words(i.status)}{i.last_error ? ` · ${i.last_error}` : ""}</small></div></li>)}</ul> : <Empty>None connected.</Empty>}
            </div>
            <div>
              <h3 style={{ margin: "0 0 6px", fontSize: 14 }}>Recent activity</h3>
              {s.activity.length ? <ul className="zs-rows">{s.activity.map((a, n) => <li key={n}><div><strong>{words(a.action.replace(/\./g, " "))}</strong><small>{when(a.created_at)}</small></div></li>)}</ul> : <Empty>No recorded activity.</Empty>}
            </div>
          </div>
        )}</LoadState>
      </div>
    </div>
  );
}

const CHECKS = [["profile", "Profile"], ["industry", "Industry"], ["receptionist", "AI receptionist"], ["phone", "Phone"], ["owner_invited", "Owner invited"], ["billing", "Billing"]];

export function Onboarding({ me, openSetup, openBusiness }) {
  const state = useAsync(() => call("onboarding_overview"), []);
  const [notice, setNotice] = useState({ text: "", error: "" });
  async function resend(id) {
    try { await call("invitation_resend", { businessId: id }); setNotice({ text: "Invitation sent again.", error: "" }); state.reload(); }
    catch (err) { setNotice({ text: "", error: err.message }); }
  }
  return (
    <>
      <Banner tone="success">{notice.text}</Banner>
      <Banner tone="error">{notice.error}</Banner>
      <Card title="Businesses still in setup" sub="Each check reads the business's real records. A tick means it's in place.">
        <LoadState state={state}>{(d) => (
          <Table rows={d.rows} empty="Every business has finished setup." columns={[
            ["Business", (b) => <button type="button" className="zs-link" onClick={() => openBusiness(b.id)}>{b.name}</button>],
            ["Step", (b) => words(b.onboarding_status)],
            ...CHECKS.map(([key, label]) => [label, (b) => (b.checks[key] ? <Pill tone="success">✓</Pill> : <Pill tone="warning">Missing</Pill>)]),
            ["Failed steps", (b) => (b.failed_steps.length ? b.failed_steps.map((f) => `${words(f.step)}${f.error ? `: ${f.error}` : ""}`).join("; ") : "—")],
            ["", (b) => can(me, "businesses.manage") ? (
              <span className="zs-actions">
                <button type="button" className="zs-btn sm" onClick={() => openSetup(b.id)}>Continue setup</button>
                {!b.checks.owner_invited && <button type="button" className="zs-btn sm" onClick={() => resend(b.id)}>Send owner invite</button>}
              </span>) : null],
          ]} />
        )}</LoadState>
      </Card>
      <Needs title="Automatic retry of failed provisioning steps isn't built" have="Steps stuck for 30 minutes are marked failed every hour and shown above; Continue setup re-runs the setup wizard, which only adds what's missing.">
        A safe automatic retry needs each provisioning step (agent, phone number, integrations) to be re-runnable on its own.
      </Needs>
    </>
  );
}

export function Lifecycle({ openBusiness }) {
  const state = useAsync(() => Promise.all(["suspended", "cancelling", "cancelled"].map((status) => call("tenants_search", { status }))), []);
  return (
    <>
      <Card title="How status changes work" sub="Suspend, reactivate, cancel and undo cancel are on each business's page. Each one asks for confirmation and is written to the audit log.">
        <Facts rows={[["Suspended", "Workspace and AI receptionist stop; nothing is deleted"], ["Cancelling", "Ends on the scheduled date; can be undone"],
          ["Cancelled", "Stopped; records kept for the retention period (Data lifecycle)"]]} />
      </Card>
      <LoadState state={state}>{([s, c, x]) => (
        <Card title="Businesses not live">
          <Table rows={[...s.rows, ...c.rows, ...x.rows]} empty="Every business is live or in setup." columns={[
            ["Business", (b) => <button type="button" className="zs-link" onClick={() => openBusiness(b.id)}>{b.name}</button>],
            ["Status", (b) => { const [t, tone] = businessState(b); return <Pill tone={tone}>{t}</Pill>; }],
            ["Since", (b) => when(b.cancelled_at ?? b.suspended_at ?? b.cancel_at)],
          ]} />
        </Card>
      )}</LoadState>
      <Needs title="Deactivation and deletion requests aren't separate states yet" have="Cancelled businesses are kept until their retention date; nothing is deleted automatically from the admin dashboard.">
        Pending deletion and deletion requested need a deletion request record, a second-person approval and a deletion job that can be stopped.
      </Needs>
    </>
  );
}

export function BusinessDetailsPicker({ openBusiness }) {
  const [q, setQ] = useState("");
  const [pick, setPick] = useState(null);
  const state = useAsync(() => (q.trim().length >= 2 ? call("tenants_search", { q }) : Promise.resolve({ rows: [] })), [q]);
  return (
    <Card title="Look up a business" sub="Type at least two letters of the name.">
      <Field label="Business name"><input type="search" value={q} onChange={(e) => setQ(e.target.value)} /></Field>
      <LoadState state={state}>{(r) => (
        <ul className="zs-rows">{r.rows.map((b) => (
          <li key={b.id}><div><strong>{b.name}</strong><small>{b.industry ?? "—"} · {[b.city, b.state].filter(Boolean).join(", ") || "No address"} · created {when(b.created_at)}</small></div>
            <span className="zs-actions"><button type="button" className="zs-btn sm" onClick={() => setPick(b.id)}>Summary</button>
              <button type="button" className="zs-btn sm" onClick={() => openBusiness(b.id)}>Full page</button></span></li>
        ))}</ul>
      )}</LoadState>
      {pick && <TenantSummary businessId={pick} />}
    </Card>
  );
}

export function Provisioning({ openBusiness }) {
  const state = useAsync(() => call("onboarding_overview"), []);
  return (
    <>
      <Card title="How a new business is set up" sub="The setup wizard creates one isolated workspace per business. No sample customers, calls or appointments are added.">
        <Facts rows={[["Workspace", "Created with the business record"], ["Industry defaults", "Words, modules and starter automations from the chosen industry"],
          ["AI receptionist", "Created in the AI step"], ["Telephony", "Assigned under Voice, telephony & usage"], ["Repeats", "Saving a step again updates it; it never makes a second business or member"]]} />
      </Card>
      <LoadState state={state}>{(d) => {
        const failed = d.rows.filter((b) => b.failed_steps.length);
        return (
          <Card title="Provisioning errors">
            <Table rows={failed} empty="No failed provisioning steps." columns={[
              ["Business", (b) => <button type="button" className="zs-link" onClick={() => openBusiness(b.id)}>{b.name}</button>],
              ["Step", (b) => b.failed_steps.map((f) => words(f.step)).join(", ")],
              ["Error", (b) => b.failed_steps.map((f) => f.error ?? "—").join("; ")],
              ["When", (b) => when(b.failed_steps[0]?.at)],
            ]} />
          </Card>
        );
      }}</LoadState>
    </>
  );
}

export function DataLifecycle({ me }) {
  const state = useAsync(() => Promise.all([call("privacy_overview"), call("tenants_search", { status: "cancelled" })]), []);
  return (
    <LoadState state={state}>{([p, c]) => (
      <>
        <SettingNumber me={me} keyName="retention_days" label="Days a cancelled business's records are kept" current={p.retentionDays} />
        <Card title="Cancelled businesses" sub="Their records stay until the retention date.">
          <Table rows={c.rows} empty="No cancelled businesses." columns={[["Business", (b) => b.name], ["Cancelled", (b) => when(b.cancelled_at)]]} />
        </Card>
        <Card title="Customer data requests across businesses" sub="Counts only. Each business handles its own requests.">
          <Facts rows={[["Open", p.requests.open], ["Overdue", p.requests.overdue], ...Object.entries(p.requests.byKind).map(([k, v]) => [words(k), v])]} />
        </Card>
        <Needs title="Whole-business export and deletion jobs aren't built" have="Each business can export or erase individual customers (with a second approval). Cancelled businesses are kept, never deleted automatically.">
          Exporting or deleting a whole business needs a job that runs in the background, records its progress, and can be approved and stopped.
        </Needs>
      </>
    )}</LoadState>
  );
}

// One editable platform setting (owner only on the server).
export function SettingNumber({ me, keyName, label, current, hint }) {
  const form = useForm({ value: String(current ?? "") });
  const owner = me?.role === "zella_owner";
  return (
    <Card title={label} sub={hint}>
      <div className="zs-grid"><Field label={label} hint={owner ? `Setting ${keyName}` : "Only a Zella owner can change this."}><input value={form.values.value} onChange={form.set("value")} inputMode="numeric" disabled={!owner} /></Field></div>
      {owner && <SaveBar form={form} onSave={() => form.save(async (v) => { await call("platform_setting_save", { key: keyName, value: v.value }); })} />}
    </Card>
  );
}

/* ---------------- 3. Users and access ---------------- */

export function Administrators({ onNavigate }) {
  const state = useAsync(() => call("admins_security"), []);
  const [q, setQ] = useState("");
  return (
    <>
      <LinkRows rows={[{ title: "Invite, change roles and deactivate", detail: "On the Users & Access page.", onClick: () => onNavigate("Users & Access"), label: "Open" }]} />
      <Card title="Platform administrators">
        <Field label="Search"><input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Email or role" /></Field>
        <LoadState state={state}>{(d) => (
          <Table rowKey={(a) => a.user_id} rows={d.admins.filter((a) => `${a.email} ${a.roleLabel}`.toLowerCase().includes(q.toLowerCase()))} columns={[
            ["Admin", (a) => a.email ?? a.user_id], ["Role", (a) => a.roleLabel], ["Access", (a) => (a.is_active ? <Pill tone="success">Active</Pill> : <Pill>Off</Pill>)],
            ["Two-step sign-in", (a) => (a.mfa ? <Pill tone="success">On</Pill> : <Pill tone="warning">Off</Pill>)],
            ["Last sign-in", (a) => when(a.last_sign_in_at)], ["Last admin action", (a) => (a.lastAction ? `${words(a.lastAction.action.replace(/\./g, " "))} · ${when(a.lastAction.created_at)}` : "—")],
          ]} />
        )}</LoadState>
      </Card>
    </>
  );
}

export function PlatformRoles({ me }) {
  const state = useAsync(() => call("roles_get"), []);
  return <LoadState state={state}>{(d) => <RoleMatrix data={d} reload={state.reload} canEdit={d.canEdit && can(me, "roles.manage")} />}</LoadState>;
}

function RoleMatrix({ data, reload, canEdit }) {
  const initial = Object.fromEntries(data.roles.map((r) => [r.key, r.permissions]));
  const form = useForm(initial);
  const toggle = (role, perm) => form.setValues((v) => ({ ...v, [role]: v[role].includes(perm) ? v[role].filter((p) => p !== perm) : [...v[role], perm] }));
  return (
    <Card title="Permission matrix" sub="Zella owner and super admin are fixed. The five restricted roles only get what is ticked. Checked on the server for every action.">
      {!canEdit && <Banner tone="warn">Only a Zella owner can change role permissions.</Banner>}
      <div className="zs-table-wrap">
        <table className="zs-matrix">
          <thead><tr><th>Permission</th>{data.roles.map((r) => <th key={r.key}>{r.label}<br /><small className="zs-muted">{r.admins} admin{r.admins === 1 ? "" : "s"}</small></th>)}</tr></thead>
          <tbody>{data.catalog.map(([perm, label]) => (
            <tr key={perm}><td>{label}<br /><small className="zs-muted">{perm}</small></td>
              {data.roles.map((r) => (
                <td key={r.key}><input type="checkbox" aria-label={`${r.label}: ${label}`} checked={form.values[r.key].includes(perm)} disabled={r.fixed || !canEdit} onChange={() => toggle(r.key, perm)} /></td>
              ))}</tr>
          ))}
            <tr><td>Manage admins and roles<br /><small className="zs-muted">admins.manage, roles.manage</small></td>{data.roles.map((r) => <td key={r.key}><input type="checkbox" checked={r.key === "zella_owner"} disabled readOnly aria-label={`${r.label}: manage admins`} /></td>)}</tr>
          </tbody>
        </table>
      </div>
      {canEdit && <SaveBar form={form} onSave={() => form.save(async (v) => {
        for (const r of data.roles.filter((x) => !x.fixed)) {
          if (JSON.stringify([...v[r.key]].sort()) !== JSON.stringify([...initial[r.key]].sort())) await call("roles_save", { role: r.key, permissions: v[r.key] });
        }
        reload();
      })} />}
    </Card>
  );
}

export function Permissions() {
  const state = useAsync(() => call("roles_get"), []);
  return (
    <LoadState state={state}>{(d) => (
      <>
        <Card title="What each permission covers" sub="Platform roles only. Business roles (owner, admin, manager, staff, viewer) are separate and set inside each business.">
          <ul className="zs-rows">{d.catalog.map(([p, label]) => <li key={p}><div><strong>{label}</strong><small>{p}</small></div></li>)}
            <li><div><strong>Manage admins and roles</strong><small>Zella owner only</small></div></li></ul>
        </Card>
        <Card title="Where it's enforced">
          <Facts rows={[["Admin dashboard actions", "owner-provision-business checks the role and permission before every action"],
            ["Direct database tools (health, incidents, offers)", "Need a Zella owner or super admin (is_platform_admin)"],
            ["Business data", "Row level security and role checks inside each business"]]} />
        </Card>
      </>
    )}</LoadState>
  );
}

export function AuthPolicies() {
  const state = useAsync(() => call("security_overview"), []);
  return (
    <>
      <Card title="What's in place">
        <LoadState state={state}>{(s) => (
          <Facts rows={[["Password rules (Zella screens)", "At least 8 characters with upper and lower case letters and a number"],
            ["Two-step sign-in", "Authenticator apps. Admins who turn it on must use it; the server checks"],
            ["Admins without two-step sign-in", `${s.adminsWithoutMfa} of ${s.adminCount}`],
            ["Sign-in options", "Email and password; Google, Microsoft, Apple and Okta buttons work once switched on in Supabase"],
            ["Account recovery", "Email reset link (one use)"]]} />
        )}</LoadState>
      </Card>
      <Needs title="Session length, sign-up policy, leaked-password checks and failed sign-in monitoring are set in Supabase, not here"
        have="Supabase dashboard > Authentication. The security advisor reports leaked-password protection is currently off; turning it on is recommended.">
        Supabase doesn't let the app read or change these settings, and sign-in attempt logs aren't stored in the database for this project.
        Showing them here would need the Supabase Management API with a server-side token.
      </Needs>
    </>
  );
}

/* ---------------- 4. Plans ---------------- */

const NUMBER_LIMITS = [["voice_minutes", "AI voice minutes per period"], ["sms_messages", "Texts per period"], ["phone_numbers", "Phone numbers"], ["team_members", "Team seats (including the owner)"],
  ["locations", "Business locations"], ["automations", "Active automations"], ["integrations", "Connected integrations"]];
const CHOICE_LIMITS = [["reporting", "Reporting", ["standard", "advanced"]], ["support_level", "Support level", ["standard", "priority", "dedicated"]], ["onboarding", "Onboarding service", ["self", "guided", "done_for_you"]]];

export function PlanManagement({ me, onNavigate }) {
  const state = useAsync(() => call("plans_list"), []);
  return (
    <>
      <LinkRows rows={[{ title: "Create, rename and archive plans", detail: "On the Plans & Subscriptions page. Archiving keeps every existing subscription.", onClick: () => onNavigate("Plans & Subscriptions") }]} />
      <LoadState state={state}>{(d) => (
        <Card title="Plans">
          <Table rows={d.plans ?? []} empty="No plans yet. Create one on the Plans & Subscriptions page." columns={[
            ["Plan", (p) => p.name], ["Identifier", (p) => p.slug ?? "—"], ["Monthly", (p) => (p.price_monthly != null ? money(p.price_monthly, p.currency) : "Not set")],
            ["Annual", (p) => (p.price_yearly != null ? money(p.price_yearly, p.currency) : "Not set")], ["Status", (p) => (p.is_active ? <Pill tone="success">Available</Pill> : <Pill>Archived</Pill>)],
          ]} />
        </Card>
      )}</LoadState>
      <Needs title="Setup fees, trial eligibility and public visibility aren't plan fields yet" have={can(me, "plans.manage") ? "Prices and allowances are set under Plan entitlements." : "Prices and allowances are shown under Plan entitlements."}>
        The plans table has prices, currency, allowances and an available/archived flag. The others need new columns and a public pricing page that reads them.
      </Needs>
    </>
  );
}

export function PlanEntitlements({ me }) {
  const state = useAsync(() => call("plans_list"), []);
  const [planId, setPlanId] = useState("");
  return (
    <LoadState state={state}>{(d) => {
      const plans = d.plans ?? [];
      const plan = plans.find((p) => p.id === planId) ?? plans[0];
      if (!plan) return <Empty title="No plans yet">Create a plan first.</Empty>;
      return (
        <>
          <Card title="Core CRM is included in every plan" sub="Leads, customers, calendar, calls, tasks, automations, reports and the AI receptionist are never switched off by plan. Plans differ only by the allowances below." />
          <Field label="Plan"><select value={plan.id} onChange={(e) => setPlanId(e.target.value)}>{plans.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select></Field>
          <EntitlementForm key={plan.id} plan={plan} canEdit={can(me, "plans.manage")} onSaved={state.reload} />
        </>
      );
    }}</LoadState>
  );
}

function EntitlementForm({ plan, canEdit, onSaved }) {
  const limits = plan.limits ?? {};
  const form = useForm({
    priceMonthly: plan.price_monthly ?? "", priceYearly: plan.price_yearly ?? "", currency: plan.currency ?? "USD",
    ...Object.fromEntries(NUMBER_LIMITS.map(([k]) => [k, limits[k] ?? ""])), ...Object.fromEntries(CHOICE_LIMITS.map(([k]) => [k, limits[k] ?? ""])),
  });
  const v = form.values;
  return (
    <Card title={`${plan.name}: prices and allowances`} sub="Empty means no limit. Team seats and phone numbers are enforced in the database; the others are shown to businesses and used for usage notices.">
      {!canEdit && <Banner tone="warn">{ROLE_NOTE}</Banner>}
      <fieldset disabled={!canEdit} style={{ border: 0, padding: 0, margin: 0 }}>
        <div className="zs-grid">
          <Field label="Monthly price"><input inputMode="decimal" value={v.priceMonthly} onChange={form.set("priceMonthly")} /></Field>
          <Field label="Annual price"><input inputMode="decimal" value={v.priceYearly} onChange={form.set("priceYearly")} /></Field>
          <Field label="Currency"><select value={v.currency} onChange={form.set("currency")}>{["USD", "CAD", "GBP", "EUR", "AUD"].map((c) => <option key={c}>{c}</option>)}</select></Field>
          {NUMBER_LIMITS.map(([k, label]) => <Field key={k} label={label}><input inputMode="numeric" value={v[k]} onChange={form.set(k)} placeholder="No limit" /></Field>)}
          {CHOICE_LIMITS.map(([k, label, options]) => (
            <Field key={k} label={label}><select value={v[k]} onChange={form.set(k)}><option value="">Not set</option>{options.map((o) => <option key={o} value={o}>{words(o)}</option>)}</select></Field>
          ))}
        </div>
      </fieldset>
      {canEdit && <SaveBar form={form} onSave={() => form.save(async (x) => {
        await call("plan_entitlements_save", { planId: plan.id, priceMonthly: x.priceMonthly, priceYearly: x.priceYearly, currency: x.currency,
          limits: Object.fromEntries([...NUMBER_LIMITS, ...CHOICE_LIMITS].map(([k]) => [k, x[k]])) });
        onSaved();
      })} />}
    </Card>
  );
}

const SUB_STATUSES = ["", "trial", "active", "renewal_due", "past_due", "grace_period", "cancelled", "expired"];

export function Subscriptions() {
  const [status, setStatus] = useState("");
  const [page, setPage] = useState(0);
  const state = useAsync(() => call("subscriptions_list", { status, page }), [status, page]);
  return (
    <Card title="Subscriptions">
      <Field label="Status"><select value={status} onChange={(e) => { setStatus(e.target.value); setPage(0); }}>{SUB_STATUSES.map((s) => <option key={s} value={s}>{s ? words(s) : "All"}</option>)}</select></Field>
      <LoadState state={state}>{(d) => (
        <>
          <Table rows={d.rows} empty="No subscriptions yet. They appear when billing is connected." columns={[
            ["Business", (s) => s.business_name ?? "—"], ["Plan", (s) => s.plan ?? "—"], ["Status", (s) => words(s.status)], ["Billing", (s) => words(s.billing_interval)],
            ["Renews", (s) => when(s.current_period_end)], ["Trial ends", (s) => when(s.trial_end_at)], ["Grace ends", (s) => when(s.grace_period_end_at)],
            ["Cancelled", (s) => (s.cancelled_at ? `${when(s.cancelled_at)}${s.cancellation_reason ? ` · ${s.cancellation_reason}` : ""}` : "—")],
          ]} />
          <Pager page={d.page} size={d.size} total={d.total} onPage={setPage} />
        </>
      )}</LoadState>
    </Card>
  );
}

export function TrialsPromotions({ onNavigate, onGo }) {
  return (
    <>
      <LinkRows rows={[{ title: "Promotion codes and discounts", detail: "Discount type and value, start and end, redemption limits, eligibility and approval: on the Offers & Promotions page.", onClick: () => onNavigate("Offers & Promotions") },
        { title: "Offer automation rules", detail: "Starting and ending on time, approval limits, unpaid claim hold and alerts.", onClick: () => onGo("offers/rules") },
        { title: "Trial-ending notices", detail: "When owners are told a trial is ending.", onClick: () => onGo("general/operations") }]} />
      <Needs title="Trial length and eligible plans aren't configurable yet" have="Trials come from the payment provider's subscription (trial start and end dates are stored). Trial-ending notices use the trial_notice_days setting.">
        Zella-side trials need a trial length per plan and a sign-up flow that starts the trial.
      </Needs>
    </>
  );
}

export function EntitlementEnforcement() {
  return (
    <>
      <Card title="Where allowances are enforced" sub="All checks run in the database, never only in the browser or in n8n.">
        <Facts rows={[["Team seats", "Blocked when an invitation would go over (TEAM_LIMIT_REACHED)"], ["Phone numbers", "Blocked when activating a number would go over"],
          ["AI voice minutes", "Owners are told at 70, 90 and 100% (or their own thresholds), hourly"], ["No plan", "No limits apply until a business has a subscription"],
          ["Core CRM", "Never limited by plan"]]} />
      </Card>
      <Needs title="Stopping AI calls when minutes run out isn't enforced yet" have="Usage is counted from recorded calls; notices go out; each business's choice (stop, pay as you go, top up) is saved.">
        Stopping or redirecting a call needs the phone assistant's start-of-call request (Vapi assistant request) to ask the database first. That request isn't wired yet.
      </Needs>
    </>
  );
}

/* ---------------- 5. Billing ---------------- */

export function BillingOverview() {
  const state = useAsync(() => call("billing_overview"), []);
  return (
    <LoadState state={state}>{(b) => (
      <>
        {!b.provider && <Banner tone="warn">No payment provider is connected (STRIPE_WEBHOOK_SECRET isn't set), so there are no billing records yet. Every figure below comes from real records and will stay at zero until then.</Banner>}
        <Card title="Revenue" sub="Monthly recurring revenue: each active, renewing, past-due or grace-period subscription at its plan's monthly price (annual price ÷ 12).">
          <Facts rows={[["Monthly recurring revenue", moneyMap(b.mrr)], ["Annual recurring revenue", moneyMap(b.arr)], ["Active paid subscriptions", b.activePaid],
            ["Trials now", b.trials], ["Trials that converted", `${b.trialConversions.converted} of ${b.trialConversions.ended} ended`]]} />
        </Card>
        <Card title="Last 30 days">
          <Facts rows={[["Payments received", moneyMap(b.payments30d.succeeded)], ["Refunded", moneyMap(b.payments30d.refunded)], ["Failed payments", b.payments30d.failed],
            ["Past due now", b.pastDue], ["Cancellations", b.cancelled30d], ["Billing events received", b.events30d]]} />
        </Card>
        <Needs title="Outstanding balances aren't available" have="Payments and failures are recorded from the payment provider's webhook.">Balances need invoices from the payment provider.</Needs>
      </>
    )}</LoadState>
  );
}

export function Payments({ status: fixed }) {
  const [status, setStatus] = useState(fixed ?? "");
  const [page, setPage] = useState(0);
  const state = useAsync(() => call("payments_list", { status, page }), [status, page]);
  return (
    <Card title={fixed === "refunded" ? "Refunded payments" : "Payments"} sub="From the payment provider. Card numbers are never stored; only the provider's reference.">
      {!fixed && <Field label="Status"><select value={status} onChange={(e) => { setStatus(e.target.value); setPage(0); }}>
        {["", "pending", "processing", "succeeded", "failed", "refunded", "cancelled"].map((s) => <option key={s} value={s}>{s ? words(s) : "All"}</option>)}</select></Field>}
      <LoadState state={state}>{(d) => (
        <>
          <Table rows={d.rows} empty="No payments recorded yet." columns={[
            ["Date", (p) => when(p.paid_at ?? p.created_at)], ["Business", (p) => p.business_name ?? "—"], ["Amount", (p) => money(p.amount, p.currency)],
            ["Status", (p) => words(p.status)], ["Provider reference", (p) => (p.external_payment_id ? <code>{p.external_payment_id}</code> : "—")], ["Reason", (p) => p.failure_reason ?? "—"],
          ]} />
          <Pager page={d.page} size={d.size} total={d.total} onPage={setPage} />
        </>
      )}</LoadState>
    </Card>
  );
}

export function Invoices() {
  return <Needs title="Invoices aren't stored in Zella yet" have="Payments (with the provider's reference) are recorded under Payments.">Invoice records, tax lines and downloadable PDFs come from the payment provider. They need the provider's invoice events added to the billing webhook and an invoices table.</Needs>;
}

export function Refunds() {
  return (
    <>
      <Payments status="refunded" />
      <Needs title="Refund requests and approvals aren't built" have="Refunds made in the payment provider arrive through the webhook and appear above.">
        Issuing a refund from Zella needs the payment provider's API with a server-side key, an approval step, and an audit entry. Credits and adjustments need the same.
      </Needs>
    </>
  );
}

export function BillingConfig({ me }) {
  const state = useAsync(() => Promise.all([call("billing_overview"), call("platform_settings_list"), call("platform_profile_get")]), []);
  return (
    <LoadState state={state}>{([b, s, p]) => {
      const val = (k) => s.settings.find((x) => x.key === k)?.value;
      return (
        <>
          <Card title="Payment provider">
            <Facts rows={[["Provider", b.provider ? "Stripe (webhook connected)" : "Not connected"], ["Currency", p.profile.currency ?? "USD"],
              ["Auto-pause unpaid workspaces", val("payment_auto_suspend") === true ? "On" : "Off"]]} />
          </Card>
          <SettingNumber me={me} keyName="payment_grace_days" label="Grace days after a failed payment" current={val("payment_grace_days")} />
          <SettingNumber me={me} keyName="payment_suspend_after_days" label="Days past due before a workspace is paused" current={val("payment_suspend_after_days")} />
          <Needs title="Tax, invoice numbering, payment retries and billing email templates are set in the payment provider" have="Grace and pause rules above are Zella's; the provider handles card retries.">
            Managing them from here needs the provider's API.
          </Needs>
        </>
      );
    }}</LoadState>
  );
}

/* ---------------- 6. AI ---------------- */

export function AiProviders({ me }) {
  const state = useAsync(() => Promise.all([call("platform_settings_list"), call("platform_status"), supabase.rpc("zella_platform_health_summary").then((r) => r.data ?? null)]), []);
  return (
    <LoadState state={state}>{([s, status, health]) => {
      const row = (k) => s.settings.find((x) => x.key === k);
      const vapi = status.configuration?.find((c) => c.key === "VAPI_API_KEY");
      return (
        <>
          <Card title="Providers">
            <Facts rows={[["Voice (calls)", vapi?.set ? "Vapi: key configured" : "Vapi: key not set"],
              ["Phone assistant model", `${row("voice_llm_provider")?.value ?? "—"} · ${row("voice_llm_model")?.value ?? "—"}`],
              ["Call summaries", `${row("call_intel_model")?.value ?? "—"} · ${row("call_intel_live")?.value === true ? "on" : "off"}`],
              ["Knowledge drafting", `${row("knowledge_ai_model")?.value ?? "—"} · ${row("knowledge_ai_live")?.value === true ? "on" : "off"}`],
              ...((health?.providers ?? []).map((p) => [`${p.provider} health`, `${p.ok ? "OK" : "Failing"} · checked ${when(p.checked_at)}`]))]} />
            {!(health?.providers ?? []).length && <p className="zs-muted">No provider health checks have run yet (they run once provider_checks_live is on).</p>}
          </Card>
          {["voice_llm_provider", "voice_llm_model", "call_intel_model", "knowledge_ai_model"].map((k) => row(k) && (
            <SettingText key={k} me={me} row={row(k)} />
          ))}
          <Needs title="Usage and error reporting per AI provider isn't collected yet" have="AI tool calls and their results are recorded per business (ai_tool_calls).">
            Provider-side usage and costs need each provider's usage API.
          </Needs>
        </>
      );
    }}</LoadState>
  );
}

function SettingText({ me, row, hint = "Checked by the provider on first use." }) {
  const form = useForm({ value: typeof row.value === "string" ? row.value : Array.isArray(row.value) ? row.value.join(", ") : JSON.stringify(row.value) });
  const owner = me?.role === "zella_owner";
  return (
    <Card title={row.label ?? row.key} sub={`${row.key} · changed ${when(row.updated_at)}`}>
      <div className="zs-grid"><Field label="Value" hint={owner ? hint : "Only a Zella owner can change this."}><input value={form.values.value} onChange={form.set("value")} disabled={!owner} /></Field></div>
      {owner && <SaveBar form={form} onSave={() => form.save(async (v) => { await call("platform_setting_save", { key: row.key, value: v.value }); })} />}
    </Card>
  );
}

export function AgentRegistry({ onNavigate }) {
  const state = useAsync(() => call("agents_list"), []);
  return (
    <>
      <LinkRows rows={[{ title: "All AI agents", detail: "Every business's receptionist, its status and setup.", onClick: () => onNavigate("AI Agents") }]} />
      <LoadState state={state}>{(d) => (
        <Card title="Agents">
          <Table rowKey={(a) => a.agentId} rows={d.agents ?? []} empty="No agents yet." columns={[["Agent", (a) => a.name], ["Business", (a) => a.businessName ?? "—"],
            ["Industry", (a) => a.industry ?? "—"], ["Status", (a) => words(a.status)], ["Setup checks", (a) => `${a.ready} of ${Object.keys(a.checks ?? {}).length}`]]} />
        </Card>
      )}</LoadState>
    </>
  );
}

export function AgentConfiguration({ onNavigate }) {
  return (
    <>
      <Card title="How receptionist settings are layered" sub="Global changes never overwrite a business's own instructions.">
        <Facts rows={[["Industry defaults", "Words, starter wording and modules per industry (Industry Configuration)"], ["Each business", "Its own versions: draft, check, publish, restore (business Settings, AI receptionist)"],
          ["Deployment", "A published version is synced to Vapi by n8n; it's live when the sync succeeds"]]} />
      </Card>
      <LinkRows rows={[{ title: "Industry defaults", detail: "Industry Configuration page", onClick: () => onNavigate("Industry Configuration") }]} />
      <Needs title="A global default prompt that rolls out to businesses isn't built" have="Each business edits and publishes its own receptionist; nothing global overwrites it.">
        Rolling out a global change safely needs a migration that creates a draft in every business for its owner to approve.
      </Needs>
    </>
  );
}

export function AiTesting() {
  return <Needs title="AI evaluation results aren't shown here yet" have="Each business can store test questions with expected answers (ai_eval_cases), and the database can run them (zella_brain_run_evals). Tool calls record whether their result was verified (ai_tool_calls.verified).">An admin view needs a server action that runs and stores evaluations across businesses with a defined pass rule (expected text present, nothing invented).</Needs>;
}

export function AiGuardrails() {
  return (
    <Card title="Guardrails in place" sub="These are built into the phone assistant's tools and the database, not settings.">
      <Facts rows={[["Knowledge", "Answers only from knowledge the business approved; otherwise says it doesn't know and logs the question"],
        ["Bookings", "Never says booked until the calendar confirms; checks free time first"], ["Transfers", "Only to a number the business set, only when someone is reachable; otherwise a callback is created"],
        ["Actions", "Every tool call is recorded with its result (ai_tool_calls)"], ["Sensitive data", "Recordings and transcripts are for managers and above; secrets in instructions are rejected"],
        ["Prompt injection", "Tool inputs are checked by the database, never run as instructions"]]} />
    </Card>
  );
}

/* ---------------- 7. Telephony ---------------- */

export function TelephonyProviders() {
  const state = useAsync(() => Promise.all([call("numbers_list"), call("platform_settings_list")]), []);
  return (
    <LoadState state={state}>{([n, s]) => {
      const val = (k) => s.settings.find((x) => x.key === k)?.value;
      return (
        <>
          <Card title="Providers">
            <Facts rows={[["Telnyx (numbers, texts)", n.telnyx ? "Key configured" : "Key not set"], ["Vapi (AI voice)", n.vapi ? "Key configured" : "Key not set"],
              ["Numbers in Zella", n.rows.length], ["Outbound calls", val("calls_live") === true ? "On" : "Off (calls_live)"], ["Inbound routing", "Vapi answers each assigned number with that business's receptionist"]]} />
          </Card>
          <Needs title="Buying numbers and provider error logs aren't built" have="Numbers bought in Telnyx/Vapi are assigned to businesses under Phone numbers.">
            Ordering numbers and reading provider errors need the Telnyx and Vapi APIs from a server action.
          </Needs>
        </>
      );
    }}</LoadState>
  );
}

export function PhoneNumbers({ me }) {
  const state = useAsync(() => Promise.all([call("numbers_list"), call("tenants_search", {})]), []);
  const [edit, setEdit] = useState(null);
  const [confirm, setConfirm] = useState(null);
  const manage = can(me, "telephony.manage");
  return (
    <LoadState state={state}>{([n, t]) => (
      <>
        <Card title="Phone numbers" actions={manage && <button type="button" className="zs-btn sm primary" onClick={() => setEdit({ e164: "", businessId: "", vapiPhoneNumberId: "", label: "" })}>Assign a number</button>}>
          <Table rows={n.rows} empty="No numbers assigned yet." columns={[
            ["Number", (r) => r.e164], ["Business", (r) => r.business_name ?? "—"], ["Label", (r) => r.label ?? "—"], ["Provider id", (r) => r.vapi_phone_number_id ? <code>{r.vapi_phone_number_id}</code> : "—"],
            ["Status", (r) => <Pill tone={r.status === "active" ? "success" : ""}>{words(r.status)}</Pill>], ["Added", (r) => when(r.created_at)],
            ["", (r) => manage && <span className="zs-actions">
              <button type="button" className="zs-btn sm" onClick={() => setEdit({ id: r.id, e164: r.e164, businessId: r.business_id, vapiPhoneNumberId: r.vapi_phone_number_id ?? "", label: r.label ?? "" })}>Reassign</button>
              <button type="button" className="zs-btn sm" onClick={() => setConfirm(r)}>{r.status === "active" ? "Pause" : "Activate"}</button></span>],
          ]} />
        </Card>
        {edit && <Confirm title={edit.id ? "Reassign this number?" : "Assign a number"} reason={Boolean(edit.id)} confirmLabel="Save" onClose={() => setEdit(null)}
          onConfirm={async (reason) => { await call("number_assign", { ...edit, reason }); state.reload(); }}>
          <div className="zs-grid">
            <Field label="Number" hint="With country code"><input value={edit.e164} onChange={(e) => setEdit({ ...edit, e164: e.target.value })} disabled={Boolean(edit.id)} /></Field>
            <Field label="Business"><select value={edit.businessId} onChange={(e) => setEdit({ ...edit, businessId: e.target.value })}><option value="">Choose…</option>{t.rows.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}</select></Field>
            <Field label="Vapi phone number id" hint="From the Vapi dashboard"><input value={edit.vapiPhoneNumberId} onChange={(e) => setEdit({ ...edit, vapiPhoneNumberId: e.target.value })} /></Field>
            <Field label="Label"><input value={edit.label} onChange={(e) => setEdit({ ...edit, label: e.target.value })} placeholder="Main line" /></Field>
          </div>
          {edit.id && <p className="zs-muted">Calls to this number will reach the new business's receptionist once Vapi is updated.</p>}
        </Confirm>}
        {confirm && <Confirm title={confirm.status === "active" ? `Pause ${confirm.e164}?` : `Activate ${confirm.e164}?`} reason confirmLabel={confirm.status === "active" ? "Pause" : "Activate"} danger={confirm.status === "active"}
          onClose={() => setConfirm(null)} onConfirm={async (reason) => { await call("number_set_status", { id: confirm.id, status: confirm.status === "active" ? "paused" : "active", reason }); state.reload(); }}>
          {confirm.status === "active" ? "Zella stops treating this as the business's number. Releasing it at the carrier is done in Telnyx." : "The business's plan must include another number."}
        </Confirm>}
      </>
    )}</LoadState>
  );
}

export function VoiceUsage() {
  const [range, setRange] = useState(30);
  const state = useAsync(() => call("usage_summary", { from: new Date(Date.now() - range * 86400000).toISOString() }), [range]);
  return (
    <Card title="AI voice usage" sub="From recorded calls answered by the AI. Costs are estimates from the pricing inputs (Voice cost configuration), not provider charges.">
      <Field label="Period"><select value={range} onChange={(e) => setRange(Number(e.target.value))}>{[7, 30, 90].map((d) => <option key={d} value={d}>Last {d} days</option>)}</select></Field>
      <LoadState state={state}>{(u) => (
        <>
          <Facts rows={[["Calls", u.voice.calls], ["Minutes", u.voice.minutes], ["Estimated cost", u.voice.priced ? moneyMap(u.voice.estimated_cost) : "No pricing inputs yet"],
            ["Provider-reported usage", u.providerReportedAvailable ? Object.entries(u.providerReported).map(([k, v]) => `${words(k)}: ${v}`).join(", ") : "Not available yet"],
            ["Reconciliation", u.providerReportedAvailable ? "Compare the two figures above" : "Needs provider-reported usage"]]} />
          <h3 style={{ fontSize: 14, margin: "14px 0 6px" }}>By business</h3>
          <Table rowKey={(b) => b.business_id} rows={u.voice.by_business} empty="No AI calls in this period." columns={[["Business", (b) => b.name], ["Calls", (b) => b.calls], ["Minutes", (b) => b.minutes]]} />
          <h3 style={{ fontSize: 14, margin: "14px 0 6px" }}>Estimated by provider</h3>
          <Table rowKey={(p) => p.provider + p.currency} rows={u.voice.by_provider} empty="No priced usage." columns={[["Provider", (p) => words(p.provider)], ["Estimated", (p) => money(p.estimated_cost, p.currency)]]} />
        </>
      )}</LoadState>
    </Card>
  );
}

export function VoiceCosts({ me }) {
  const state = useAsync(() => call("voice_pricing_list"), []);
  const [add, setAdd] = useState(null);
  const manage = can(me, "billing.manage");
  return (
    <>
      <Card title="Pricing inputs" sub="Each change is a new version from its effective date; earlier calls keep the price that applied then."
        actions={manage && <button type="button" className="zs-btn sm primary" onClick={() => setAdd({ provider: "vapi", unitCost: "", currency: "USD", incrementSeconds: 60, effectiveFrom: "", note: "" })}>Add a price</button>}>
        <LoadState state={state}>{(d) => (
          <Table rows={d.rows} empty="No prices entered. Voice costs can't be estimated until you add the providers' per-minute prices." columns={[
            ["Provider", (r) => words(r.provider)], ["Per minute", (r) => money(r.unit_cost, r.currency)], ["Billed per", (r) => `${r.billing_increment_seconds} s`],
            ["Effective from", (r) => when(r.effective_from)], ["Note", (r) => r.note ?? "—"],
          ]} />
        )}</LoadState>
      </Card>
      {add && <Confirm title="Add a price" confirmLabel="Add" onClose={() => setAdd(null)} onConfirm={async () => {
        await call("voice_pricing_add", { ...add, effectiveFrom: add.effectiveFrom ? new Date(add.effectiveFrom).toISOString() : null }); state.reload();
      }}>
        <div className="zs-grid">
          <Field label="Provider"><select value={add.provider} onChange={(e) => setAdd({ ...add, provider: e.target.value })}>{["vapi", "telnyx", "twilio", "llm", "other"].map((p) => <option key={p} value={p}>{words(p)}</option>)}</select></Field>
          <Field label="Price per minute"><input inputMode="decimal" value={add.unitCost} onChange={(e) => setAdd({ ...add, unitCost: e.target.value })} placeholder="0.05" /></Field>
          <Field label="Currency"><select value={add.currency} onChange={(e) => setAdd({ ...add, currency: e.target.value })}>{["USD", "CAD", "GBP", "EUR", "AUD"].map((c) => <option key={c}>{c}</option>)}</select></Field>
          <Field label="Billed in steps of (seconds)"><input inputMode="numeric" value={add.incrementSeconds} onChange={(e) => setAdd({ ...add, incrementSeconds: e.target.value })} /></Field>
          <Field label="Effective from" hint="Empty: now"><input type="datetime-local" value={add.effectiveFrom} onChange={(e) => setAdd({ ...add, effectiveFrom: e.target.value })} /></Field>
          <Field label="Note"><input value={add.note} onChange={(e) => setAdd({ ...add, note: e.target.value })} placeholder="From the provider's pricing page" /></Field>
        </div>
      </Confirm>}
    </>
  );
}

export function UsageLimits() {
  return (
    <>
      <Card title="Usage limits" sub="Allowances come from each plan; each business owner chooses what happens past them.">
        <Facts rows={[["Included allowances", "Plans, subscriptions & entitlements > Plan entitlements"], ["Business choice", "Stop, pay as you go, or automatic top-up, with a spending limit (the owner authorizes it)"],
          ["Notices", "70, 90 and 100% to the owners"], ["Additional usage rates", "Voice cost configuration"]]} />
      </Card>
      <Needs title="Charging for extra usage and cutting off calls aren't built" have="Choices and limits are saved and audited; nothing is ever charged from Zella today.">
        Charging needs the payment provider; cutting off needs the start-of-call check described under Entitlement enforcement.
      </Needs>
    </>
  );
}

/* ---------------- 8. Communications ---------------- */

export function SmsConfig({ me }) {
  const state = useAsync(() => call("comms_overview"), []);
  return (
    <LoadState state={state}>{(c) => (
      <>
        <Card title="Text messages">
          <Facts rows={[["Provider", `${c.sms.provider}${c.sms.configured ? " (key configured)" : " (key not set)"}`], ["Sending", c.sms.live ? "On" : "Off (sms_live)"], ["Sender number", c.sms.from || "Not set"],
            ["Sent, last 7 days", c.sms.sent7d], ["Failed, last 7 days", c.sms.failed7d], ["People who opted out", c.optOuts],
            ["Message types", "Transactional only (marketing texts are off)"], ["Opt-out", "STOP, START and HELP handled automatically"]]} />
        </Card>
        <SettingTextKey me={me} keyName="sms_from_number" label="Sender number" />
      </>
    )}</LoadState>
  );
}

function SettingTextKey({ me, keyName, label }) {
  const state = useAsync(() => call("platform_settings_list"), []);
  return <LoadState state={state}>{(s) => { const row = s.settings.find((x) => x.key === keyName); return row ? <SettingText me={me} row={{ ...row, label }} /> : null; }}</LoadState>;
}

export function EmailConfig({ me }) {
  const state = useAsync(() => call("comms_overview"), []);
  return (
    <LoadState state={state}>{(c) => (
      <>
        <Card title="Email">
          <Facts rows={[["Provider", c.email.provider], ["Sending", c.email.live ? "On" : "Off (email_live)"], ["Sender", c.email.from || "Not set"],
            ...Object.entries(c.email.events30d).map(([k, v]) => [`${words(k)} (30 days)`, v]), ["Reply-to", "Replies go to the inbound address of each business"]]} />
        </Card>
        <SettingTextKey me={me} keyName="email_from_address" label="Sender address" />
      </>
    )}</LoadState>
  );
}

export function Templates() {
  const state = useAsync(() => call("comms_overview"), []);
  const [open, setOpen] = useState(null);
  return (
    <>
      <LoadState state={state}>{(c) => (
        <Card title="Platform message templates" sub="Templates every business starts with. Businesses can have their own versions.">
          <Table rows={c.templates} empty="No platform templates." columns={[["Key", (t) => t.key], ["Channel", (t) => words(t.channel)], ["Purpose", (t) => words(t.purpose)],
            ["Version", (t) => t.version], ["Status", (t) => words(t.status)], ["", (t) => <button type="button" className="zs-btn sm" onClick={() => setOpen(open === t.id ? null : t.id)}>{open === t.id ? "Hide" : "Preview"}</button>]]} />
          {open && (() => { const t = c.templates.find((x) => x.id === open); return <div className="zs-card" style={{ padding: 12, marginTop: 10 }}>{t.subject && <strong>{t.subject}</strong>}<pre style={{ whiteSpace: "pre-wrap", font: "inherit" }}>{t.body}</pre><small className="zs-muted">Variables: {(t.body.match(/\{\{\s*[\w.]+\s*\}\}/g) ?? []).join(", ") || "none"}</small></div>; })()}
        </Card>
      )}</LoadState>
      <Needs title="Editing platform templates here isn't built" have="Templates are versioned in the database (message_templates) and previewed above.">
        Editing needs a server action that saves a new version and checks every variable against the list each message type supports.
      </Needs>
    </>
  );
}

export function DeliveryMonitoring({ onNavigate }) {
  const state = useAsync(() => call("comms_overview"), []);
  return (
    <LoadState state={state}>{(c) => (
      <>
        <Card title="Delivery">
          <Facts rows={[["Texts failed (7 days)", c.sms.failed7d], ["Email bounces (30 days)", c.email.events30d.bounced ?? c.email.events30d["email.bounced"] ?? 0],
            ["Spam complaints (30 days)", c.email.events30d.complained ?? c.email.events30d["email.complained"] ?? 0], ["Suppressed contacts", c.optOuts]]} />
        </Card>
        <LinkRows rows={[{ title: "Failed events and retries", detail: "Platform Operations", onClick: () => onNavigate("Platform Operations") }]} />
      </>
    )}</LoadState>
  );
}

/* ---------------- 9. Integrations and automation ---------------- */

export function IntegrationRegistry({ onNavigate }) {
  const state = useAsync(() => call("integrations_overview"), []);
  return (
    <>
      <LinkRows rows={[{ title: "Integrations across businesses", detail: "Integrations page", onClick: () => onNavigate("Integrations") }]} />
      <LoadState state={state}>{(d) => (
        <Card title="Connections">
          <Table rows={d.connections ?? []} empty="No integrations connected yet." columns={[["Provider", (i) => words(i.provider)], ["Business", (i) => i.business_name ?? "—"],
            ["Status", (i) => words(i.status)], ["Last sync", (i) => when(i.last_synced_at)], ["Last error", (i) => i.last_error ?? i.error_message ?? "—"]]} />
        </Card>
      )}</LoadState>
    </>
  );
}

export function OauthApps() {
  return <Needs title="OAuth app settings are kept outside Zella" have="Google Calendar connections are stored per business (calendar_connections), with tokens in the database vault; only status and the account email are ever shown.">Client IDs and secrets live in Google Cloud and in Supabase secrets. Showing whether they're set needs those secret names added to the server configuration check.</Needs>;
}

export function N8nConfig() {
  const state = useAsync(() => call("automation_overview"), []);
  return (
    <LoadState state={state}>{(a) => (
      <>
        <Card title="n8n">
          <Facts rows={[["Webhook address", a.n8n.url ? "Set" : "Not set"], ["Database dispatcher", a.n8n.dispatchEnabled ? "On" : "Off"], ["n8n address in database", a.n8n.baseUrlSet ? "Set" : "Not set"],
            ["Dead letters", a.deadLetters]]} />
        </Card>
        <Card title="Dispatcher state" sub="What the database sent to each n8n workflow most recently.">
          <Table rowKey={(r) => r.workflow ?? r.key ?? JSON.stringify(r)} rows={a.dispatch} empty="Nothing dispatched yet." columns={Object.keys(a.dispatch[0] ?? { workflow: 1 }).slice(0, 6).map((k) => [words(k), (r) => (typeof r[k] === "string" && /T\d\d:/.test(r[k]) ? when(r[k]) : String(r[k] ?? "—"))])} />
        </Card>
        <Needs title="n8n workflow activation and execution logs aren't read from n8n" have="Workflow runs are recorded in Zella (workflow_executions) and shown under Automation monitoring.">Reading n8n's own status needs the n8n API with a server-side key.</Needs>
      </>
    )}</LoadState>
  );
}

export function AutomationMonitoring({ openBusiness }) {
  const state = useAsync(() => call("automation_overview"), []);
  return (
    <LoadState state={state}>{(a) => (
      <>
        <Card title="Workflow runs, last 7 days">
          <Table rowKey={(w) => w.key} rows={a.workflows} empty="No runs recorded." columns={[["Workflow", (w) => w.key], ["Runs", (w) => w.total], ["Failed", (w) => (w.failed ? <Pill tone="danger">{w.failed}</Pill> : 0)],
            ["Success rate", (w) => `${Math.round(((w.total - w.failed) / w.total) * 100)}%`], ["Average time", (w) => (w.avgSeconds != null ? `${w.avgSeconds} s` : "—")]]} />
        </Card>
        <Card title="Recent failures">
          <Table rows={a.failures} empty="No failed runs." columns={[["When", (f) => when(f.started_at)], ["Workflow", (f) => f.workflow_key],
            ["Business", (f) => (f.business_name ? <button type="button" className="zs-link" onClick={() => openBusiness(f.business_id)}>{f.business_name}</button> : "—")],
            ["Retries", (f) => f.retry_count], ["Error", (f) => [f.error_category, f.error_message].filter(Boolean).join(": ") || "—"], ["Correlation id", (f) => <code>{String(f.correlation_id ?? "").slice(0, 8)}</code>]]} />
        </Card>
      </>
    )}</LoadState>
  );
}

const WEBHOOKS = [
  ["/webhook/zella/events", "Event gateway (Telnyx texts and calls)", "Shared secret header"], ["/webhook/zella/vapi", "Vapi call results", "Shared secret header"],
  ["/webhook/zella/vapi-tools", "Vapi assistant tools", "Shared secret header"], ["/webhook/zella/vapi-booking", "Vapi booking", "Shared secret header"],
  ["/webhook/zella/vapi-voice", "Vapi call rules", "Shared secret header"], ["/webhook/zella/vapi-brain", "Vapi knowledge tools", "Shared secret header"],
  ["/webhook/zella/resend", "Resend email events", "Svix signature"], ["/webhook/zella/inbound-email", "Resend inbound email", "Svix signature + key"],
  ["/webhook/zella/meta", "Meta (Facebook, Instagram, WhatsApp)", "Verify token + X-Hub-Signature-256"], ["functions/v1/billing-webhook", "Payment provider", "Stripe signature, 5-minute window, one event once"],
  ["functions/v1/website-lead", "Website forms", "Per-business form key, allowed websites, rate limits"],
];

export function Webhooks() {
  return (
    <>
      <Card title="Inbound webhooks" sub="From the n8n workflow files and edge functions in the repository. Each business's events are tied to that business on arrival.">
        <Table rowKey={(w) => w[0]} rows={WEBHOOKS} columns={[["Endpoint", (w) => <code>{w[0]}</code>], ["Used by", (w) => w[1]], ["How it's verified", (w) => w[2]]]} />
      </Card>
      <Needs title="Webhook delivery logs and outbound webhooks for businesses aren't built" have="Incoming events are stored once each (automation_events), with failures and retries under Platform Operations.">Outbound webhooks need endpoint registration, signing keys per business and a delivery log.</Needs>
    </>
  );
}

/* ---------------- 10. Security ---------------- */

export function SecurityOverview() {
  const state = useAsync(() => call("security_overview"), []);
  return (
    <LoadState state={state}>{(s) => (
      <>
        <Card title="Right now">
          <Facts rows={[["Tables without row security", s.rls ? s.rls.without_rls.length : "—"], ["Business data open to everyone", s.leak ? (s.leak.open_policies?.length ?? 0) + (s.leak.anon_can_read?.length ?? 0) : "—"],
            ["Admins without two-step sign-in", `${s.adminsWithoutMfa} of ${s.adminCount}`], ["Stored integration credentials", `${s.integrationSecrets} (values never shown)`]]} />
        </Card>
        <Card title="Recent security changes">
          <Table rowKey={(a) => a.created_at + a.action} rows={s.recent} empty="No security changes recorded." columns={[["When", (a) => when(a.created_at)], ["Change", (a) => words(a.action.replace(/\./g, " "))]]} />
        </Card>
        <Needs title="Failed sign-in attempts and suspicious activity aren't visible here" have="Supabase keeps its own auth logs (Supabase dashboard > Logs).">The project doesn't store auth events in the database, so they'd need the Supabase Management API.</Needs>
      </>
    )}</LoadState>
  );
}

export function DataIsolation() {
  const state = useAsync(() => call("security_overview"), []);
  return (
    <LoadState state={state}>{(s) => (
      <>
        <Card title="Row level security" sub={`Checked ${when(s.rls?.checked_at)}. There's no control here to turn it off.`}>
          <Facts rows={[["Tables", s.rls?.tables], ["With row security", s.rls?.with_rls], ["Tables holding business data", s.rls?.with_business_id], ["Policies", s.rls?.policies]]} />
          {s.rls?.without_rls?.length > 0 && <Banner tone="warn">Without row security: {s.rls.without_rls.join(", ")}</Banner>}
        </Card>
        <Card title="Tenant isolation check" sub="Runs daily and raises a platform alert if anything is found.">
          <Facts rows={[["Business tables without row security", (s.leak?.no_row_security ?? []).join(", ") || "None"], ["Policies open to everyone", (s.leak?.open_policies ?? []).join(", ") || "None"],
            ["Business tables anonymous users can read", (s.leak?.anon_can_read ?? []).join(", ") || "None"]]} />
        </Card>
        <Needs title="Automated cross-tenant access tests aren't run from here" have="The SQL tests in the repository sign in as one business and try to read another's data; run them before each release.">A scheduled cross-tenant test needs test users in a separate test project.</Needs>
      </>
    )}</LoadState>
  );
}

export function Secrets() {
  const state = useAsync(() => Promise.all([call("platform_status"), call("security_overview")]), []);
  return (
    <LoadState state={state}>{([p, s]) => (
      <>
        <Card title="Server secrets" sub="Set with supabase secrets set NAME=value. Only whether each is set is shown, never the value.">
          <Table rowKey={(c) => c.key} rows={p.configuration ?? []} columns={[["Secret", (c) => <code>{c.key}</code>], ["Used for", (c) => c.label], ["Status", (c) => <Pill tone={c.set ? "success" : c.required ? "danger" : ""}>{c.set ? "Set" : "Not set"}</Pill>]]} />
        </Card>
        <Card title="Business credentials"><Facts rows={[["Stored integration credentials", s.integrationSecrets], ["Where", "Database vault and integration_secrets, readable only by the server"]]} /></Card>
        <Needs title="Rotation dates and expiry alerts aren't tracked" have="Provider connection checks raise alerts when a key stops working.">Tracking rotation needs a record of when each secret was last changed; Supabase doesn't expose that.</Needs>
      </>
    )}</LoadState>
  );
}

export function Retention({ me }) {
  const state = useAsync(() => call("privacy_overview"), []);
  return (
    <LoadState state={state}>{(p) => (
      <>
        <SettingNumber me={me} keyName="retention_days" label="Days a cancelled business's records are kept" current={p.retentionDays} />
        <Card title="Other records">
          <Facts rows={[["Customer erasure", "Per customer, with a second approval when a business has two owners or admins"], ["Audit log", "Kept; no automatic deletion"],
            ["Call recordings and transcripts", "Kept with the call until the customer is erased"]]} />
        </Card>
        <Needs title="Separate retention for recordings, transcripts and audit logs isn't built" have="Everything above.">It needs a scheduled job per record type that deletes or redacts after the configured days, with a log of what it removed.</Needs>
      </>
    )}</LoadState>
  );
}

export function PrivacyControls({ onGo }) {
  const state = useAsync(() => call("privacy_overview"), []);
  return (
    <LoadState state={state}>{(p) => (
      <>
        <Card title="Customer data requests" sub="Each business logs and handles its own (export, correct, stop use, erase), within 30 days.">
          <Facts rows={[["Open", p.requests.open], ["Overdue", p.requests.overdue]]} />
        </Card>
        <LinkRows rows={[{ title: "Privacy policy, recording consent and acceptance records", detail: "Legal, policy & platform documents", onClick: () => onGo("legal/documents") }]} />
      </>
    )}</LoadState>
  );
}

export function SecurityAudit({ onNavigate }) {
  return <LinkRows rows={[{ title: "Audit log", detail: "Every admin action, permission change, billing change, provider change, suspension, export and erasure. Only the server can add entries; nobody can edit them.", onClick: () => onNavigate("Audit Logs"), label: "Open" }]} />;
}

/* ---------------- 11. Notifications ---------------- */

export function AdminNotifications() {
  const state = useAsync(async () => {
    const { data, error } = await supabase.rpc("zella_my_admin_alert_email");
    if (error) throw error;
    return data;
  }, []);
  const [error, setError] = useState("");
  return (
    <>
      <Card title="Email digest of platform alerts" sub="Failed onboarding, payment failures, cancellations, provider outages, telephony and integration failures, security findings and automation failures raise platform alerts.">
        <LoadState state={state}>{(on) => (
          <div className="zs-savebar" style={{ borderTop: 0, marginTop: 0 }}>
            <span className="zs-savebar-state">{on ? "You get the email digest." : "You don't get the email digest. Alerts still show in Notification history."}</span>
            <Toggle on={on} label="Email me platform alerts" onChange={async (v) => {
              const { error: e } = await supabase.rpc("zella_my_admin_alert_email", { p_enabled: v });
              if (e) setError(e.message); else state.reload();
            }} />
          </div>
        )}</LoadState>
        <Banner tone="error">{error}</Banner>
      </Card>
      <Needs title="New business registrations don't raise an alert" have="Businesses are created by admins in the setup wizard, so there's no self-sign-up to alert on.">If self-sign-up is added, it should raise a platform alert too.</Needs>
    </>
  );
}

export function AlertRules() {
  return <Needs title="Alert rules aren't editable yet" have="Each alert is raised by the database check that found the problem, with its own severity and a de-duplication key so repeats are counted, not resent.">Editable rules need a rules table (condition, severity, destination, frequency, quiet window) that every check reads before raising an alert.</Needs>;
}

export function NotificationChannels() {
  const state = useAsync(() => call("comms_overview"), []);
  return (
    <LoadState state={state}>{(c) => (
      <Card title="Channels">
        <Facts rows={[["In the dashboard", "Notification history"], ["Email", c.email.live && c.email.from ? `On, from ${c.email.from}` : "Off until email_live is on and a sender is set"]]} />
      </Card>
    )}</LoadState>
  );
}

export function NotificationHistory({ me }) {
  const [status, setStatus] = useState("open");
  const [page, setPage] = useState(0);
  const state = useAsync(() => call("alerts_list", { status, page }), [status, page]);
  const act = async (id, to) => { await call("alert_set", { id, status: to }); state.reload(); };
  return (
    <Card title="Platform alerts">
      <Field label="Show"><select value={status} onChange={(e) => { setStatus(e.target.value); setPage(0); }}>{[["open", "Open"], ["acknowledged", "Acknowledged"], ["resolved", "Resolved"], ["", "All"]].map(([v, t]) => <option key={v} value={v}>{t}</option>)}</select></Field>
      <LoadState state={state}>{(d) => (
        <>
          <Table rows={d.rows} empty="No alerts." columns={[["Alert", (a) => <><strong>{a.title}</strong>{a.detail && <><br /><small className="zs-muted">{a.detail}</small></>}</>],
            ["Severity", (a) => <Pill tone={a.severity === "urgent" ? "danger" : a.severity === "warning" ? "warning" : ""}>{words(a.severity)}</Pill>], ["Business", (a) => a.business_name ?? "Platform"],
            ["Seen", (a) => `${when(a.last_seen_at)}${a.occurrences > 1 ? ` · ${a.occurrences}×` : ""}`], ["Emailed", (a) => (a.notified_at ? when(a.notified_at) : "Not yet")], ["Status", (a) => words(a.status)],
            ["", (a) => can(me, "support.manage") && a.status !== "resolved" && <span className="zs-actions">
              {a.status === "open" && <button type="button" className="zs-btn sm" onClick={() => act(a.id, "acknowledged")}>Acknowledge</button>}
              <button type="button" className="zs-btn sm" onClick={() => act(a.id, "resolved")}>Resolve</button></span>]]} />
          <Pager page={d.page} size={d.size} total={d.total} onPage={setPage} />
        </>
      )}</LoadState>
    </Card>
  );
}

/* ---------------- 13. Analytics ---------------- */

export function GlobalAnalytics() {
  const state = useAsync(() => call("analytics_overview"), []);
  return (
    <LoadState state={state}>{(a) => (
      <>
        <Card title="Last six months" sub="Counted from the records' creation dates.">
          <Table rowKey={(m) => m.month} rows={a.months} columns={[["Month", (m) => m.month], ["New businesses", (m) => m.businesses], ["New subscriptions", (m) => m.subscriptions], ["AI-answered calls", (m) => m.aiCalls]]} />
        </Card>
        <Card title="Now">
          <Facts rows={[["Businesses", a.businesses.total], ["Cancelled", a.businesses.cancelled],
            ["Customer retention", a.businesses.total ? `${Math.round(((a.businesses.total - a.businesses.cancelled) / a.businesses.total) * 100)}% not cancelled` : "—"],
            ["Automation success (30 days)", a.automation30d.total ? `${Math.round((a.automation30d.succeeded / a.automation30d.total) * 100)}% of ${a.automation30d.total} runs` : "No runs"],
            ["Integrations failing", `${a.integrations.failing} of ${a.integrations.total}`]]} />
        </Card>
      </>
    )}</LoadState>
  );
}

export function ReportingConfig() {
  return <Needs title="Scheduled reports and report permissions aren't built" have="Reports are computed live when opened; each definition is written under its figure.">Scheduled reports need a schedule table, a report runner and an email template.</Needs>;
}

export function DataQuality() {
  const state = useAsync(() => call("data_quality"), []);
  return (
    <LoadState state={state}>{(q) => (
      <Card title="Data quality" sub="Each figure is a count of real records that need attention.">
        <Facts rows={[["Possible duplicate customers (open reviews)", q.duplicatesOpen], ["Members without a business", q.membersWithoutBusiness], ["Billing events not matched to a business", q.billingEventsUnmatched],
          ["Businesses in setup for over 7 days", q.onboardingStalled], ["Usage records without a subscription", q.usageWithoutSubscription]]} />
      </Card>
    )}</LoadState>
  );
}

/* ---------------- 14. Legal ---------------- */

const LEGAL_LABELS = { terms: "Terms of Service", privacy: "Privacy Policy", acceptable_use: "Acceptable Use Policy", dpa: "Data Processing Agreement", cookies: "Cookie Policy", ai_disclosure: "AI disclosure", recording_consent: "Recording and consent" };

export function LegalDocuments({ me }) {
  const state = useAsync(() => call("legal_list"), []);
  const [edit, setEdit] = useState(null);
  const manage = can(me, "legal.manage");
  return (
    <>
      <Card title="Documents" sub="Draft and edit here. Publishing needs a review step; businesses are never marked as having accepted anything automatically."
        actions={manage && <button type="button" className="zs-btn sm primary" onClick={() => setEdit({ kind: "terms", version: "1.0", title: "Terms of Service", body: "", requiresAcceptance: true, effectiveAt: "" })}>New draft</button>}>
        <LoadState state={state}>{(d) => (
          <Table rows={d.docs} empty="No documents yet." columns={[["Document", (x) => LEGAL_LABELS[x.kind]], ["Version", (x) => x.version], ["Title", (x) => x.title],
            ["Status", (x) => <Pill tone={x.status === "published" ? "success" : x.status === "in_review" ? "warning" : ""}>{words(x.status)}</Pill>], ["Effective", (x) => when(x.effective_at)],
            ["Acceptances", (x) => (x.requires_acceptance ? x.acceptances : "Not required")],
            ["", (x) => manage && x.status === "draft" && <button type="button" className="zs-btn sm" onClick={() => setEdit({ id: x.id, kind: x.kind, version: x.version, title: x.title, body: x.body, requiresAcceptance: x.requires_acceptance, effectiveAt: localInput(x.effective_at) })}>Edit</button>]]} />
        )}</LoadState>
      </Card>
      {edit && <LegalEditor edit={edit} onClose={() => setEdit(null)} onSaved={() => { setEdit(null); state.reload(); }} />}
    </>
  );
}

function LegalEditor({ edit, onClose, onSaved }) {
  const form = useForm(edit);
  const v = form.values;
  return (
    <Card title={edit.id ? "Edit draft" : "New draft"}>
      <div className="zs-grid">
        <Field label="Document"><select value={v.kind} onChange={(e) => form.setValues({ ...v, kind: e.target.value, title: LEGAL_LABELS[e.target.value] })} disabled={Boolean(edit.id)}>{Object.entries(LEGAL_LABELS).map(([k, t]) => <option key={k} value={k}>{t}</option>)}</select></Field>
        <Field label="Version"><input value={v.version} onChange={form.set("version")} disabled={Boolean(edit.id)} /></Field>
        <Field label="Title"><input value={v.title} onChange={form.set("title")} /></Field>
        <Field label="Effective date"><input type="datetime-local" value={v.effectiveAt} onChange={form.set("effectiveAt")} /></Field>
        <label className="zs-check full"><input type="checkbox" checked={v.requiresAcceptance} onChange={form.set("requiresAcceptance")} /><span>Business owners must accept this version</span></label>
        <Field label="Text" full><textarea rows={14} value={v.body} onChange={form.set("body")} /></Field>
      </div>
      <div className="zs-savebar">
        <span className="zs-savebar-state">{form.status.error && <span className="zs-error-text">{form.status.error}</span>}</span>
        <button type="button" className="zs-btn" onClick={() => { form.cancel(); onClose(); }}>Cancel</button>
        <button type="button" className="zs-btn primary" disabled={form.busy} onClick={() => form.save(async (x) => {
          await call("legal_save", { ...x, effectiveAt: x.effectiveAt ? new Date(x.effectiveAt).toISOString() : null });
          onSaved();
        })}>{form.busy ? "Saving…" : "Save draft"}</button>
      </div>
    </Card>
  );
}

export function LegalVersioning({ me }) {
  const state = useAsync(() => call("legal_list"), []);
  const [move, setMove] = useState(null);
  const manage = can(me, "legal.manage");
  const next = { draft: [["in_review", "Send for review"]], in_review: [["draft", "Back to draft"], ["published", "Publish"]], published: [["retired", "Retire"]] };
  return (
    <>
      <LoadState state={state}>{(d) => (
        <Card title="Versions and review" sub="Draft → in review → published → retired. Publishing a version retires the one before it.">
          <Table rows={d.docs} empty="No documents yet." columns={[["Document", (x) => `${LEGAL_LABELS[x.kind]} ${x.version}`], ["Status", (x) => words(x.status)],
            ["Published", (x) => when(x.published_at)], ["Effective", (x) => when(x.effective_at)], ["Acceptance", (x) => (x.requires_acceptance ? `Required · ${x.acceptances} accepted` : "Not required")],
            ["", (x) => manage && <span className="zs-actions">{(next[x.status] ?? []).map(([to, label]) => <button key={to} type="button" className={`zs-btn sm ${to === "published" ? "primary" : ""}`} onClick={() => setMove({ doc: x, to, label })}>{label}</button>)}</span>]]} />
        </Card>
      )}</LoadState>
      {move && <Confirm title={`${move.label}: ${LEGAL_LABELS[move.doc.kind]} ${move.doc.version}?`} confirmLabel={move.label} word={move.to === "published" ? "PUBLISH" : undefined}
        onClose={() => setMove(null)} onConfirm={async () => { await call("legal_transition", { id: move.doc.id, to: move.to, confirmReviewed: move.to === "published" }); state.reload(); }}>
        {move.to === "published" ? "Confirm the text has been reviewed (for example by your lawyer). Businesses will see it; if acceptance is required they'll be asked to accept it themselves." : "The status changes and the change is logged."}
      </Confirm>}
    </>
  );
}

export function PolicyConfig({ onGo }) {
  return (
    <>
      <LinkRows rows={[{ title: "Retention", detail: "Security & privacy > Data retention", onClick: () => onGo("security/retention") },
        { title: "Recording and consent text", detail: "Publish it as the Recording and consent document", onClick: () => onGo("legal/documents") }]} />
      <Needs title="A recording on/off policy per business isn't built" have="Recordings come from the voice provider's settings; access is limited to managers and above.">It needs a recording switch the phone assistant reads at the start of each call, and a disclosure line it says when recording is on.</Needs>
    </>
  );
}

/* ---------------- 15. Developer ---------------- */

export function ApiManagement() {
  return <Needs title="There's no public API yet" have="The apps talk to Supabase with each person's sign-in; partners use the webhooks listed under Webhook management.">API applications need keys with scopes, owned by a business, stored hashed, with last-used tracking and revocation.</Needs>;
}

export function Environment() {
  const state = useAsync(() => Promise.all([call("dev_overview"), call("platform_status")]), []);
  return (
    <LoadState state={state}>{([d, p]) => (
      <>
        <Card title="Environment"><Facts rows={[["Environment", d.environment], ["App address for links", p.appUrl ?? "Not set"], ["Configuration last changed", when(d.configVersion)]]} /></Card>
        <Card title="Configuration check">
          <Table rowKey={(c) => c.key} rows={p.configuration ?? []} columns={[["Setting", (c) => <code>{c.key}</code>], ["Status", (c) => <Pill tone={c.set ? "success" : c.required ? "danger" : ""}>{c.set ? "Set" : c.required ? "Missing (required)" : "Not set"}</Pill>]]} />
        </Card>
        <Banner>Server environment variables can't be changed from the dashboard; use supabase secrets set.</Banner>
      </>
    )}</LoadState>
  );
}

export function SystemConfig() {
  const state = useAsync(() => call("dev_overview"), []);
  return (
    <LoadState state={state}>{(d) => (
      <>
        <Card title="Feature switches" sub="Read-only here. They're switched on at go-live in order (n8n/GO-LIVE.md).">
          <Table rowKey={(f) => f.key} rows={d.flags} columns={[["Switch", (f) => <code>{f.key}</code>], ["State", (f) => <Pill tone={f.on ? "success" : ""}>{f.on ? "On" : "Off"}</Pill>], ["Changed", (f) => when(f.updated_at)]]} />
        </Card>
        <Card title="Change history">
          <Table rowKey={(h) => h.created_at + h.action} rows={d.history} empty="No configuration changes recorded yet." columns={[["When", (h) => when(h.created_at)], ["Change", (h) => words(h.action.replace(/\./g, " "))],
            ["What", (h) => h.new_data?.key ?? h.new_data?.section ?? h.new_data?.role ?? "—"]]} />
        </Card>
      </>
    )}</LoadState>
  );
}

/* ---------------- Operational rules ---------------- */

// Timings and thresholds the scheduled checks read from platform_settings. Saved by a Zella owner; each value is
// checked by the admin function before it is stored, and the jobs pick it up on their next run.
const OPERATIONAL = [
  ["Leads and tasks", [
    ["response_time_minutes", "How fast a new lead should get a reply. Late replies show on reports and in alerts."],
    ["task_overdue_grace_minutes", "Extra minutes before a task counts as overdue."],
    ["task_escalate_hours", "Overdue tasks are sent to the business owner after this long."],
    ["team_summary_hour", "Hour of the day (business time) the daily team summary is sent."],
  ]],
  ["Calls", [
    ["missed_call_max_seconds", "Calls shorter than this count as missed and get a callback."],
    ["transfer_failure_threshold", "Failed transfers to a person, in a day, before Zella flags the business."],
    ["call_intel_monthly_limit", "Calls per business per month that the AI summarises."],
  ]],
  ["AI quality and knowledge", [
    ["ai_low_confidence_questions", "Unsure answers in one call before the call is flagged for review."],
    ["knowledge_repeat_threshold", "Times the same question is asked before it is suggested as new knowledge."],
    ["response_sample_rate", "Share of AI conversations picked for quality review: 0.1 is one in ten."],
  ]],
  ["Onboarding and trials", [
    ["invitation_reminder_hours", "Hours after an owner invitation that reminders go out, for example 24, 72."],
    ["setup_incomplete_after_days", "Days after creation before an unfinished setup is flagged."],
    ["trial_notice_days", "Days before a trial ends that the owner is told, for example 7, 3, 1."],
  ]],
];

export function OperationalRules({ me }) {
  const state = useAsync(() => call("platform_settings_list"), []);
  return (
    <LoadState state={state}>{(s) => (
      <>
        {me?.role !== "zella_owner" && <Banner tone="warn">Only a Zella owner can change these. You can see the current values.</Banner>}
        {OPERATIONAL.map(([group, keys]) => (
          <div key={group}>
            <h3 className="zs-group">{group}</h3>
            {keys.map(([k, hint]) => {
              const row = s.settings.find((x) => x.key === k);
              return row
                ? <SettingText key={k} me={me} row={row} hint={hint} />
                : <Banner key={k} tone="warn"><code>{k}</code> isn't in platform settings yet. The migration that adds it hasn't been applied.</Banner>;
            })}
          </div>
        ))}
      </>
    )}</LoadState>
  );
}

/* ---------------- Offers and promotions ---------------- */

const FULL_ADMIN = ["zella_owner", "super_admin"];
const OFFER_STATUS = [["active", "Active"], ["pending_approval", "Waiting for approval"], ["scheduled", "Scheduled"], ["paused", "Paused"], ["draft", "Drafts"], ["expired", "Ended"], ["archived", "Archived"]];
const OFFER_CAPS = [
  ["billing", "Payments", "Claims become Paid when a real payment arrives from the payment provider."],
  ["checkout", "Self-serve checkout", "Needed for checkout prices and abandoned checkout reminders."],
  ["referral_tracking", "Referral links", "Needed for referral rewards."],
  ["promo_sending", "Promotional sending", "Needed for promotional emails and win-back."],
];

// Offers are run by the database for Zella owners and super admins only (is_platform_admin).
export function OffersGate({ me, children }) {
  if (!FULL_ADMIN.includes(me?.role)) return <Banner tone="warn">Offers and promotions are managed by Zella owners and super admins. Your role ({me?.roleLabel}) can't open them.</Banner>;
  return children;
}

export function OffersOverview({ onNavigate }) {
  const state = useAsync(async () => {
    const { data, error } = await supabase.rpc("zella_offers_list");
    if (error) throw new Error(error.message);
    return data;
  }, []);
  return (
    <LoadState state={state}>{(d) => {
      const count = (st) => d.offers.filter((o) => o.status === st).length;
      const problems = d.offers.filter((o) => o.problems?.length);
      return (
        <>
          <Card title="Offers" sub="Discounts, promo codes and deals for businesses. Created, approved and scheduled on the Offers & Promotions page."
            actions={<button type="button" className="zs-btn sm primary" onClick={() => onNavigate("Offers & Promotions")}>Open Offers & Promotions</button>}>
            <Facts rows={[...OFFER_STATUS.map(([k, label]) => [label, count(k)]),
              ["Claims waiting for payment", d.offers.reduce((n, o) => n + (o.claims - o.confirmed), 0)], ["Paid claims", d.offers.reduce((n, o) => n + o.confirmed, 0)]]} />
          </Card>
          {problems.length > 0 && (
            <Card title="Offers that can't go live yet" sub="Fix these on the Offers & Promotions page.">
              <Table rows={problems} columns={[["Offer", (o) => o.name], ["Status", (o) => words(o.status)], ["To fix", (o) => o.problems.join(" ")]]} />
            </Card>
          )}
          <Card title="What offers can use" sub="Rules and offer types that need a missing connection stay switched off.">
            <Table rowKey={(c) => c[0]} rows={OFFER_CAPS} columns={[["Connection", (c) => c[1]], ["State", (c) => <Pill tone={d.capabilities?.[c[0]] ? "success" : "warning"}>{d.capabilities?.[c[0]] ? "Available" : "Not connected"}</Pill>], ["Used for", (c) => c[2]]]} />
          </Card>
          <Card title="Who can do what">
            <Facts rows={[["Create and edit drafts", "Zella owners and super admins"], ["Approve offers over the limits", "Zella owners"], ["Change automation rules", "Zella owners"],
              ["Claim an offer", "The business owner, in their Settings (Billing > Offers and promo codes)"], ["Prices", "Never changed by an offer alone: a claim is Paid only when the payment arrives"]]} />
          </Card>
        </>
      );
    }}</LoadState>
  );
}
