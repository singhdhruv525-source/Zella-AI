import { useState } from "react";
import { supabase } from "./supabase";
import { Field, Icon, Pill } from "./BusinessUI";
import { Empty, Notice, PageHead, friendly, useLoad } from "./BusinessShared";
import { EmailField, PhoneField, TimeZoneSelect, UrlField } from "./formFields";
import { checkEmail, checkUrl } from "./formValidation";
import { ReviewLinkPanel } from "./BusinessDrafts";
import { OffersPanel } from "./BusinessOffers";
import { formatDay, formatLongDate } from "./businessTime";
import { makeTerm } from "./businessWorkspace";
import { DATA_RIGHTS_ROLES, DataRightsList } from "./BusinessDataRights";

// Business Settings. Categories sit in the page's own menu (the main sidebar
// keeps its single Settings item); the address is /app/settings/<category>.
// Everything saves through database functions that check the person's role
// themselves (sql/zella_business_settings.sql); the browser never decides access.

const MANAGE = ["owner", "admin"];
const LEAD = ["owner", "admin", "manager"];

const SAY = {
  NAME_REQUIRED: "Enter the business name.",
  BAD_EMAIL: "That email address doesn't look right.",
  BAD_PHONE: "Enter the phone number with its country code, for example +1 555 123 4567.",
  BAD_WEBSITE: "The website must start with https:// (or http://).",
  BAD_COUNTRY: "Choose a country.",
  BAD_TIMEZONE: "Choose a time zone from the list.",
  BAD_HOURS: "Check the opening and closing times.",
  CLOSES_BEFORE_OPENS: "A closing time must be later than the opening time.",
  HOURS_OVERLAP: "Two time ranges on the same day overlap.",
  BAD_DATES: "Check the dates: the last day can't be before the first, and at most a year apart.",
  IN_THE_PAST: "That date has already passed.",
  NO_PHONE: "Add your mobile number under My account first.",
};
const say = (error) => {
  const code = Object.keys(SAY).find((k) => (error?.message ?? "").includes(k));
  return code ? SAY[code] : friendly(error);
};

// Holiday dates are calendar days (no time), so show them as written, never shifted by a time zone.
const calendarDay = (d) => formatDay(`${d}T12:00:00Z`, "UTC");

const DAY_NAMES = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const WEEK_ORDER = [1, 2, 3, 4, 5, 6, 0];

function sections(workspace) {
  const has = (slug) => workspace.modules.includes(slug);
  return [
    { key: "profile", label: "Business profile", icon: "storefront" },
    { key: "hours", label: "Hours & holidays", icon: "schedule" },
    { key: "account", label: "My account", icon: "person" },
    { key: "notifications", label: "Notifications", icon: "notifications" },
    { key: "team", label: "Team & permissions", icon: "badge" },
    { key: "phone", label: "Phone & AI receptionist", icon: "call" },
    { key: "integrations", label: "Calendar & email", icon: "extension" },
    has("automations") && { key: "automations", label: "Automations", icon: "bolt" },
    { key: "messages", label: "Reviews & offers", icon: "campaign" },
    DATA_RIGHTS_ROLES.includes(workspace.role) && { key: "privacy", label: "Privacy requests", icon: "shield_person" },
    { key: "billing", label: "Plan & billing", icon: "credit_card" },
    { key: "industry", label: "Industry preferences", icon: "tune" },
  ].filter(Boolean);
}

function Panel({ title, sub, children, foot }) {
  return (
    <section className="ba-panel">
      <div className="ba-panel-head"><div className="ba-panel-title"><div><h2>{title}</h2>{sub && <p>{sub}</p>}</div></div></div>
      <div className="ba-panel-body">{children}</div>
      {foot && <div className="ba-panel-foot">{foot}</div>}
    </section>
  );
}

function Status({ text, error }) {
  if (error) return <div className="ba-banner error" role="alert"><span>{error}</span></div>;
  return text ? <p className="ba-muted" role="status">{text}</p> : null;
}

/* ---------- Business profile ---------- */
const PROFILE_FIELDS = ["name", "legal_name", "email", "phone", "website", "address_line_1", "address_line_2", "city", "state", "postal_code", "country", "timezone"];

function ProfileSection({ workspace, settings, onSaved }) {
  const canEdit = settings.can_edit_profile;
  const initial = Object.fromEntries(PROFILE_FIELDS.map((k) => [k, settings.business[k] ?? ""]));
  const [form, setForm] = useState(initial);
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState({ text: "", error: "" });
  const [showErrors, setShowErrors] = useState(false);
  const set = (key) => (value) => setForm((f) => ({ ...f, [key]: value?.target ? value.target.value : value }));
  const changed = PROFILE_FIELDS.some((k) => (form[k] ?? "") !== (initial[k] ?? ""));

  async function save(event) {
    event.preventDefault();
    setShowErrors(true);
    const problem = !form.name.trim() ? SAY.NAME_REQUIRED
      : checkEmail(form.email) || checkUrl(form.website) || (String(form.phone).startsWith("?") ? SAY.BAD_PHONE : "");
    if (problem) return setStatus({ text: "", error: problem });
    setBusy(true);
    setStatus({ text: "", error: "" });
    const { error } = await supabase.rpc("zella_save_business_profile", { p_business_id: workspace.id, p_fields: form });
    setBusy(false);
    if (error) return setStatus({ text: "", error: say(error) });
    setStatus({ text: "Saved.", error: "" });
    onSaved();
  }

  return (
    <form onSubmit={save}>
      <Panel
        title="Business profile"
        sub={canEdit ? "Your business details. Your AI receptionist and messages use them." : "Only an owner or admin can change these."}
        foot={canEdit && <><span /><button type="submit" className="ba-btn primary" disabled={busy || !changed}>{busy ? "Saving…" : "Save changes"}</button></>}
      >
        <Status {...status} />
        <fieldset className="ba-form-grid" disabled={!canEdit || busy} style={{ border: 0, padding: 0, margin: 0 }}>
          <Field label="Business name"><input value={form.name} onChange={set("name")} required maxLength={200} /></Field>
          <Field label="Legal name" hint="Optional. If it differs from the name above."><input value={form.legal_name} onChange={set("legal_name")} maxLength={200} /></Field>
          <Field label="Email" bare><EmailField value={form.email} onChange={set("email")} showErrors={showErrors} /></Field>
          <Field label="Phone" bare><PhoneField value={form.phone} onChange={set("phone")} showErrors={showErrors} label="Business phone" /></Field>
          <Field label="Website" bare full><UrlField value={form.website} onChange={set("website")} showErrors={showErrors} /></Field>
          <Field label="Address" full><input value={form.address_line_1} onChange={set("address_line_1")} maxLength={200} autoComplete="address-line1" /></Field>
          <Field label="Address line 2" full><input value={form.address_line_2} onChange={set("address_line_2")} maxLength={200} autoComplete="address-line2" /></Field>
          <Field label="City"><input value={form.city} onChange={set("city")} maxLength={120} autoComplete="address-level2" /></Field>
          <Field label="State or region"><input value={form.state} onChange={set("state")} maxLength={120} autoComplete="address-level1" /></Field>
          <Field label="Postal code"><input value={form.postal_code} onChange={set("postal_code")} maxLength={20} autoComplete="postal-code" /></Field>
          <Field label="Country code" hint="Two letters, for example US or GB."><input value={form.country} onChange={(e) => set("country")(e.target.value.toUpperCase().slice(0, 2))} maxLength={2} autoComplete="country" /></Field>
          <Field label="Time zone" bare full><TimeZoneSelect value={form.timezone || workspace.timezone} onChange={set("timezone")} /></Field>
        </fieldset>
      </Panel>
    </form>
  );
}

/* ---------- Hours & holidays ---------- */
function HoursSection({ workspace, settings, onSaved }) {
  const canEdit = settings.can_edit_hours;
  const toRanges = () => Object.fromEntries(WEEK_ORDER.map((d) => [d, settings.hours.filter((h) => h.weekday === d).map((h) => ({ opens: h.opens, closes: h.closes }))]));
  const [days, setDays] = useState(toRanges);
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState({ text: "", error: "" });
  const [closure, setClosure] = useState({ starts_on: "", ends_on: "", label: "", special: false, opens: "10:00", closes: "14:00" });

  const update = (day, fn) => setDays((all) => ({ ...all, [day]: fn(all[day]) }));
  const notSet = !settings.hours.length;

  async function saveHours() {
    setBusy(true);
    setStatus({ text: "", error: "" });
    const rows = WEEK_ORDER.flatMap((d) => days[d].map((r) => ({ weekday: d, opens: r.opens, closes: r.closes })));
    const { error } = await supabase.rpc("zella_save_business_hours", { p_business_id: workspace.id, p_hours: rows });
    setBusy(false);
    if (error) return setStatus({ text: "", error: say(error) });
    setStatus({ text: rows.length ? "Opening hours saved. Your AI receptionist uses them on the next call." : "Hours cleared. Your AI receptionist won't tell callers you're closed.", error: "" });
    onSaved();
  }

  async function addClosure(event) {
    event.preventDefault();
    setBusy(true);
    setStatus({ text: "", error: "" });
    const { error } = await supabase.rpc("zella_add_business_closure", {
      p_business_id: workspace.id, p_starts_on: closure.starts_on, p_ends_on: closure.ends_on || closure.starts_on,
      p_label: closure.label || (closure.special ? "Special hours" : "Closed"),
      p_opens: closure.special ? closure.opens : null, p_closes: closure.special ? closure.closes : null,
    });
    setBusy(false);
    if (error) return setStatus({ text: "", error: say(error) });
    setClosure({ starts_on: "", ends_on: "", label: "", special: false, opens: "10:00", closes: "14:00" });
    setStatus({ text: "Added.", error: "" });
    onSaved();
  }

  async function removeClosure(c) {
    if (!window.confirm(`Remove "${c.label}" (${calendarDay(c.starts_on)})?`)) return;
    setBusy(true);
    const { error } = await supabase.rpc("zella_delete_business_closure", { p_closure_id: c.id });
    setBusy(false);
    if (error) return setStatus({ text: "", error: say(error) });
    setStatus({ text: "Removed.", error: "" });
    onSaved();
  }

  return (
    <>
      <Panel
        title="Opening hours"
        sub={`In ${(settings.business.timezone || workspace.timezone).replace(/_/g, " ")}. Your AI receptionist uses these to say whether you're open.${canEdit ? "" : " Only an owner, admin or manager can change them."}`}
        foot={canEdit && <><span /><button type="button" className="ba-btn primary" onClick={saveHours} disabled={busy}>{busy ? "Saving…" : "Save hours"}</button></>}
      >
        <Status {...status} />
        {notSet && <p className="ba-muted">Hours aren't set yet. Until they are, callers are never told you're closed.</p>}
        <div className="ba-hours">
          {WEEK_ORDER.map((d) => (
            <div key={d} className="ba-hours-day">
              <strong>{DAY_NAMES[d]}</strong>
              <div>
                {!days[d].length && <span className="ba-muted">Closed</span>}
                {days[d].map((r, i) => (
                  <div key={i} className="ba-hours-range">
                    <input type="time" aria-label={`${DAY_NAMES[d]} opens`} value={r.opens} disabled={!canEdit || busy}
                      onChange={(e) => update(d, (rs) => rs.map((x, j) => (j === i ? { ...x, opens: e.target.value } : x)))} />
                    <span>to</span>
                    <input type="time" aria-label={`${DAY_NAMES[d]} closes`} value={r.closes} disabled={!canEdit || busy}
                      onChange={(e) => update(d, (rs) => rs.map((x, j) => (j === i ? { ...x, closes: e.target.value } : x)))} />
                    {canEdit && <button type="button" className="ba-btn ghost sm" aria-label="Remove these hours" onClick={() => update(d, (rs) => rs.filter((_, j) => j !== i))}><Icon name="close" size="sm" /></button>}
                  </div>
                ))}
                {canEdit && days[d].length < 6 && (
                  <button type="button" className="ba-link" disabled={busy}
                    onClick={() => update(d, (rs) => [...rs, rs.length ? { opens: rs[rs.length - 1].closes, closes: "23:00" } : { opens: "09:00", closes: "17:00" }])}>
                    {days[d].length ? "Add another time" : "Add hours"}
                  </button>
                )}
              </div>
            </div>
          ))}
        </div>
      </Panel>

      <Panel title="Holidays and special days" sub="Days you're closed, or open different hours. Past days drop off the list.">
        {!settings.closures.length ? <Empty title="Nothing planned">Add a holiday so callers hear you're closed that day.</Empty> : (
          <ul className="ba-list">
            {settings.closures.map((c) => (
              <li key={c.id} className="ba-list-row">
                <div>
                  <strong>{c.label}</strong>
                  <small>
                    {calendarDay(c.starts_on)}{c.ends_on !== c.starts_on ? ` – ${calendarDay(c.ends_on)}` : ""}
                    {" · "}{c.opens ? `${c.opens}–${c.closes}` : "Closed all day"}
                  </small>
                </div>
                {canEdit && <button type="button" className="ba-btn sm" onClick={() => removeClosure(c)} disabled={busy}>Remove</button>}
              </li>
            ))}
          </ul>
        )}
        {canEdit && (
          <form className="ba-form-grid" onSubmit={addClosure} style={{ marginTop: 14 }}>
            <Field label="First day"><input type="date" required value={closure.starts_on} onChange={(e) => setClosure({ ...closure, starts_on: e.target.value })} /></Field>
            <Field label="Last day" hint="Leave empty for one day."><input type="date" value={closure.ends_on} min={closure.starts_on || undefined} onChange={(e) => setClosure({ ...closure, ends_on: e.target.value })} /></Field>
            <Field label="Name" hint="For example: Christmas Day"><input value={closure.label} maxLength={80} onChange={(e) => setClosure({ ...closure, label: e.target.value })} /></Field>
            <Field label="That day">
              <select value={closure.special ? "special" : "closed"} onChange={(e) => setClosure({ ...closure, special: e.target.value === "special" })}>
                <option value="closed">Closed all day</option>
                <option value="special">Open special hours</option>
              </select>
            </Field>
            {closure.special && <>
              <Field label="Opens"><input type="time" required value={closure.opens} onChange={(e) => setClosure({ ...closure, opens: e.target.value })} /></Field>
              <Field label="Closes"><input type="time" required value={closure.closes} onChange={(e) => setClosure({ ...closure, closes: e.target.value })} /></Field>
            </>}
            <div className="ba-form-actions full"><button type="submit" className="ba-btn" disabled={busy || !closure.starts_on}>Add day</button></div>
          </form>
        )}
      </Panel>
    </>
  );
}

/* ---------- My account and notifications ---------- */
function AccountSection({ workspace, settings, email, onSignOut, onSaved }) {
  const me = settings.me ?? {};
  const [form, setForm] = useState({ first: me.first_name ?? "", last: me.last_name ?? "", phone: me.phone ?? "" });
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState({ text: "", error: "" });
  const [resetSent, setResetSent] = useState(false);
  const changed = form.first !== (me.first_name ?? "") || form.last !== (me.last_name ?? "") || form.phone !== (me.phone ?? "");

  async function save(event) {
    event.preventDefault();
    if (String(form.phone).startsWith("?")) return setStatus({ text: "", error: SAY.BAD_PHONE });
    setBusy(true);
    setStatus({ text: "", error: "" });
    const { error } = await supabase.rpc("zella_save_my_profile", { p_first_name: form.first, p_last_name: form.last, p_phone: form.phone || null });
    setBusy(false);
    if (error) return setStatus({ text: "", error: say(error) });
    setStatus({ text: "Saved.", error: "" });
    onSaved();
  }

  async function sendReset() {
    setBusy(true);
    const { error } = await supabase.auth.resetPasswordForEmail(email, { redirectTo: `${window.location.origin}/welcome` });
    setBusy(false);
    if (error) return setStatus({ text: "", error: friendly(error) });
    setResetSent(true);
  }

  return (
    <>
      <form onSubmit={save}>
        <Panel title="My account" sub={`Signed in as ${email} · ${workspace.role}`}
          foot={<><span /><button type="submit" className="ba-btn primary" disabled={busy || !changed}>{busy ? "Saving…" : "Save"}</button></>}>
          <Status {...status} />
          <div className="ba-form-grid">
            <Field label="First name"><input value={form.first} maxLength={100} autoComplete="given-name" onChange={(e) => setForm({ ...form, first: e.target.value })} /></Field>
            <Field label="Last name"><input value={form.last} maxLength={100} autoComplete="family-name" onChange={(e) => setForm({ ...form, last: e.target.value })} /></Field>
            <Field label="Mobile number" bare full hint="Urgent alerts are texted here if you switch them on under Notifications.">
              <PhoneField value={form.phone} onChange={(v) => setForm({ ...form, phone: v })} label="Mobile number" />
            </Field>
          </div>
        </Panel>
      </form>
      <Panel title="Password and sign-in"
        foot={<><span /><button type="button" className="ba-btn" onClick={onSignOut}><Icon name="logout" size="sm" />Sign out</button></>}>
        {resetSent
          ? <p className="ba-muted" role="status">A link to choose a new password is on its way to {email}. Open the newest email only, once.</p>
          : <button type="button" className="ba-btn" onClick={sendReset} disabled={busy}>Email me a link to change my password</button>}
      </Panel>
    </>
  );
}

function NotificationsSection({ workspace, settings, onSaved, onGo }) {
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState({ text: "", error: "" });
  const on = Boolean(settings.me?.sms_alerts);
  async function toggle() {
    setBusy(true);
    setStatus({ text: "", error: "" });
    const { error } = await supabase.rpc("zella_set_my_sms_alerts", { p_business_id: workspace.id, p_enabled: !on });
    setBusy(false);
    if (error) return setStatus({ text: "", error: say(error) });
    setStatus({ text: !on ? `Urgent alerts will be texted to ${settings.me?.phone}.` : "Text alerts are off. You'll still see them in the bell.", error: "" });
    onSaved();
  }
  return (
    <Panel title="Notifications" sub="Everything appears in the bell at the top of the page. Urgent ones can also come by text.">
      <Status {...status} />
      <div className="ba-list-row">
        <div>
          <strong>Text me urgent alerts</strong>
          <small>{settings.me?.phone ? `To ${settings.me.phone}. Only for this workspace.` : "Add your mobile number under My account first."}</small>
        </div>
        <button type="button" role="switch" aria-checked={on} aria-label="Text me urgent alerts" disabled={busy || (!on && !settings.me?.phone)}
          className={`ba-switch ${on ? "on" : ""}`} onClick={toggle}><span /></button>
      </div>
      {workspace.modules.includes("automations") && LEAD.includes(workspace.role) && (
        <p className="ba-muted" style={{ marginTop: 12 }}>
          How the owner is told about each automation (text, email or both) is set on each automation.{" "}
          <button type="button" className="ba-link" onClick={() => onGo("automations")}>Open Automations</button>
        </p>
      )}
    </Panel>
  );
}

/* ---------- Sections that live on their own pages ---------- */
function LinkRow({ title, detail, page, onGo, label = "Open" }) {
  return (
    <li className="ba-list-row">
      <div><strong>{title}</strong><small>{detail}</small></div>
      <button type="button" className="ba-btn sm" onClick={() => onGo(page)}>{label}</button>
    </li>
  );
}

function TeamSection({ workspace, onGo }) {
  return (
    <Panel title="Team & permissions" sub="Who works here, their hours, and what each person can do.">
      <ul className="ba-list">
        <LinkRow title="Team" detail="People, working hours and time off." page="team" onGo={onGo} />
        {MANAGE.includes(workspace.role) && <LinkRow title="Team access" detail="Invite people, change roles, remove access." page="access" onGo={onGo} label="Manage" />}
        {MANAGE.includes(workspace.role) && <LinkRow title="Approvals" detail="Sensitive actions waiting for a second owner or admin." page="approvals" onGo={onGo} />}
        {MANAGE.includes(workspace.role) && <LinkRow title="Security log" detail="Sign-ins and sensitive changes." page="security" onGo={onGo} />}
      </ul>
      {!MANAGE.includes(workspace.role) && <p className="ba-muted" style={{ marginTop: 12 }}>Roles and invitations are managed by an owner or admin.</p>}
    </Panel>
  );
}

function PhoneSection({ workspace, onGo }) {
  const hasAgent = workspace.modules.includes("ai-receptionist");
  return (
    <Panel title="Phone & AI receptionist" sub="Your phone number and the assistant that answers it.">
      <dl className="ba-facts">
        <div><dt>Phone line</dt><dd><Pill tone={workspace.phone_connected ? "success" : "warning"}>{workspace.phone_connected ? "Connected" : "Not connected yet"}</Pill></dd></div>
        <div><dt>AI voice</dt><dd><Pill tone={workspace.voice_connected ? "success" : "warning"}>{workspace.voice_connected ? "Connected" : "Not connected yet"}</Pill></dd></div>
        <div><dt>Assistant</dt><dd>{workspace.receptionist?.name ?? "—"}</dd></div>
      </dl>
      {!workspace.phone_connected && <p className="ba-muted" style={{ marginTop: 12 }}>The Zella team connects your phone number (it needs carrier registration). You'll see it here once it's live.</p>}
      {hasAgent && <ul className="ba-list" style={{ marginTop: 12 }}>
        <LinkRow title="AI receptionist" detail="Greeting, personality, what it can book, when it hands over to a person." page="receptionist" onGo={onGo} />
        <LinkRow title="Knowledge" detail="Answers your receptionist gives about services, prices and policies." page="knowledge" onGo={onGo} />
      </ul>}
    </Panel>
  );
}

function IntegrationsSection({ onGo }) {
  return (
    <Panel title="Calendar & email" sub="Connect Google or Outlook calendars and email.">
      <ul className="ba-list">
        <LinkRow title="Integrations" detail="Connection status, test and reconnect." page="integrations" onGo={onGo} />
        <LinkRow title="Lead sources" detail="Website forms and other places leads come from." page="lead-sources" onGo={onGo} />
      </ul>
    </Panel>
  );
}

function AutomationsSection({ onGo }) {
  return (
    <Panel title="Automations" sub="Reminders, follow-ups and callbacks Zella runs for you.">
      <ul className="ba-list"><LinkRow title="Automations" detail="Switch each one on or off and change its timing." page="automations" onGo={onGo} /></ul>
    </Panel>
  );
}

function BillingSection({ workspace, onReload }) {
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState({ text: "", error: "" });
  const state = workspace.cancelled_at ? ["Ended", "danger"] : workspace.suspended_at ? ["Paused", "warning"]
    : workspace.cancel_at ? [`Ends ${formatLongDate(workspace.cancel_at, workspace.timezone)}`, "warning"] : ["Active", "success"];
  async function keepPlan() {
    setBusy(true);
    const { error } = await supabase.rpc("zella_owner_continue_plan", { p_business_id: workspace.id });
    setBusy(false);
    if (error) return setStatus({ text: "", error: friendly(error) });
    setStatus({ text: "Your plan will continue.", error: "" });
    onReload();
  }
  return (
    <Panel title="Plan & billing" sub="Payments and invoices are handled by the Zella team for now.">
      <Status {...status} />
      <dl className="ba-facts"><div><dt>Plan status</dt><dd><Pill tone={state[1]}>{state[0]}</Pill></dd></div></dl>
      {workspace.cancel_at && !workspace.cancelled_at && workspace.role === "owner" && (
        <button type="button" className="ba-btn primary" style={{ marginTop: 12 }} onClick={keepPlan} disabled={busy}>{busy ? "Saving…" : "Keep my plan"}</button>
      )}
    </Panel>
  );
}

function IndustrySection({ workspace, onGo }) {
  const term = makeTerm(workspace);
  const words = [["Customer", "customer"], ["Customers", "customers"], ["Appointment", "appointment"], ["Appointments", "appointments"], ["Staff", "staff_plural"]];
  return (
    <Panel title="Industry preferences" sub={`Set up for ${workspace.industry ?? "your industry"}. These words are used across your workspace and by your AI receptionist.`}>
      <dl className="ba-facts">{words.map(([label, key]) => <div key={key}><dt>{label}</dt><dd>{term(key)}</dd></div>)}</dl>
      {LEAD.includes(workspace.role) && <ul className="ba-list" style={{ marginTop: 12 }}>
        <LinkRow title="Customise records" detail="The extra record types and fields your industry uses." page="record-settings" onGo={onGo} />
      </ul>}
    </Panel>
  );
}

/* ---------- Page ---------- */
export function BusinessSettingsPage({ workspace, email, onSignOut, section, onGo, onReload, onOpenPerson, onNotice }) {
  const list = sections(workspace);
  const current = list.find((s) => s.key === section) ?? list[0];
  const unknown = section && !list.some((s) => s.key === section);
  const { data, error, loading, reload } = useLoad(async () => {
    const { data: result, error: e } = await supabase.rpc("zella_business_settings", { p_business_id: workspace.id });
    if (e) throw new Error(friendly(e));
    return result;
  }, [workspace.id]);
  const needsData = ["profile", "hours", "account", "notifications"].includes(current.key);
  const saved = () => { reload(); if (current.key === "profile") onReload?.(); };

  return (
    <>
      <PageHead crumb="Management / Settings" title="Settings" sub={`${workspace.name} · ${current.label}`} />
      {unknown && <div className="ba-banner"><span>That settings page doesn't exist, so here is {current.label}.</span></div>}
      <div className="ba-settings">
        <nav className="ba-settings-nav" aria-label="Settings categories">
          {list.map((s) => (
            <button key={s.key} type="button" className={`ba-nav-item ${s.key === current.key ? "active" : ""}`}
              ref={s.key === current.key ? (el) => el?.scrollIntoView?.({ block: "nearest", inline: "nearest" }) : undefined}
              aria-current={s.key === current.key ? "page" : undefined} onClick={() => onGo(`settings/${s.key}`)}>
              <Icon name={s.icon} /><span>{s.label}</span>
            </button>
          ))}
        </nav>
        <div className="ba-settings-body">
          {needsData && <Notice error={error} onRetry={reload} />}
          {needsData && loading && !data && <p className="ba-muted">Loading…</p>}
          {needsData && data && current.key === "profile" && <ProfileSection key={JSON.stringify(data.business)} workspace={workspace} settings={data} onSaved={saved} />}
          {needsData && data && current.key === "hours" && <HoursSection key={JSON.stringify(data.hours)} workspace={workspace} settings={data} onSaved={saved} />}
          {needsData && data && current.key === "account" && <AccountSection key={JSON.stringify(data.me)} workspace={workspace} settings={data} email={email} onSignOut={onSignOut} onSaved={saved} />}
          {needsData && data && current.key === "notifications" && <NotificationsSection workspace={workspace} settings={data} onSaved={saved} onGo={onGo} />}
          {current.key === "team" && <TeamSection workspace={workspace} onGo={onGo} />}
          {current.key === "phone" && <PhoneSection workspace={workspace} onGo={onGo} />}
          {current.key === "integrations" && <IntegrationsSection onGo={onGo} />}
          {current.key === "automations" && <AutomationsSection onGo={onGo} />}
          {current.key === "messages" && <div className="ba-grid-2"><ReviewLinkPanel workspace={workspace} /><OffersPanel workspace={workspace} /></div>}
          {current.key === "privacy" && <DataRightsList workspace={workspace} onOpenPerson={onOpenPerson} onNotice={onNotice} />}
          {current.key === "billing" && <BillingSection workspace={workspace} onReload={onReload} />}
          {current.key === "industry" && <IndustrySection workspace={workspace} onGo={onGo} />}
        </div>
      </div>
    </>
  );
}
