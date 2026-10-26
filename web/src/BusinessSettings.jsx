import { useState } from "react";
import { supabase } from "./supabase";
import { Icon } from "./BusinessUI";
import { friendly, orThrow } from "./BusinessShared";
import { TimeZoneSelect } from "./formFields";
import { ReviewLinkPanel } from "./BusinessDrafts";
import { OffersPanel } from "./BusinessOffers";
import { makeTerm } from "./businessWorkspace";
import { DATA_RIGHTS_ROLES, DataRightsList } from "./BusinessDataRights";
import { HoursSection } from "./BusinessHours";
import { AccessPage, ApprovalsPage, FailedWorkPage, SecurityLogPage } from "./BusinessAccess";
import { TeamPage } from "./BusinessTeam";
import { KnowledgePage } from "./BusinessKnowledge";
import { RecordSettingsPage } from "./BusinessRecords";
import { IntegrationsPage, LeadSourcesPage, ReportsPage } from "./BusinessMore";
import { AutomationsPage } from "./BusinessControls";
import { ReceptionistEditor } from "./BusinessReceptionist";
import { InboxPage } from "./BusinessInbox";
import SettingsWorkspace from "./settings/SettingsWorkspace";
import { AccountSecurityPanel, MyProfilePanel, SignOutPanel, uploadImage } from "./settings/PersonalPanels";
import { Banner, Card, Confirm, Empty, Facts, Field, LinkRows, LoadState, Needs, Pill, SaveBar, Table, Toggle, useAsync, useForm, when, words } from "./settings/SettingsKit";
import { usePlatformInfo } from "./platformInfo";

// Business Settings: one Settings item in the CRM sidebar opens this workspace,
// with 16 categories at /app/settings/<category>/<page>. Everything saves
// through database functions or row-level-secured tables that check this
// person's membership and role; nothing here reaches another business.

const MANAGE = ["owner", "admin"];
const LEAD = ["owner", "admin", "manager"];
const roleIn = (w, roles) => roles.includes(w.role);
const SAY = {
  NOT_ALLOWED: "Your role can't change this. Ask an owner or admin.", OWNER_ONLY: "Only the business owner can do this.",
  NAME_REQUIRED: "Enter the business name.", BAD_EMAIL: "That email address doesn't look right.",
  BAD_PHONE: "Enter phone numbers with the country code, for example +1 555 123 4567.", BAD_WEBSITE: "The website must start with https:// (or http://).",
  BAD_COUNTRY: "Choose a country.", BAD_TIMEZONE: "Choose a time zone from the list.", SUBJECT_REQUIRED: "Write a short subject.",
  SPEND_LIMIT_REQUIRED: "Set a spending limit to allow paid usage.", BAD_LOGO_URL: "Upload the logo here so it's stored with your workspace.",
  BAD_INPUT: "Something in the form isn't valid.", NO_PHONE: "Add your mobile number under Personal profile first.",
};
const say = (e) => { const m = e?.message ?? String(e); const k = Object.keys(SAY).find((c) => m.includes(c)); return k ? SAY[k] : friendly(e); };
async function rpc(name, args) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw new Error(say(error));
  return data;
}
const settingsOf = (w) => rpc("zella_business_settings", { p_business_id: w.id });
const entitlementsOf = (w) => rpc("zella_business_entitlements", { p_business_id: w.id });
const noRole = (who = "an owner or admin") => <Banner tone="warn">Only {who} can change this. You can see it.</Banner>;

/* ---------- 1. Business profile ---------- */

function ProfileForm({ w, initial, fields, render, title, sub }) {
  const canEdit = roleIn(w, MANAGE);
  const form = useForm(Object.fromEntries(fields.map((k) => [k, initial[k] ?? ""])));
  return (
    <Card title={title} sub={sub}>
      {!canEdit && noRole()}
      <fieldset disabled={!canEdit} style={{ border: 0, padding: 0, margin: 0 }}>{render(form)}</fieldset>
      {canEdit && <SaveBar form={form} onSave={() => form.save(async (v) => {
        const all = { ...initial, ...v };
        await rpc("zella_save_business_profile", { p_business_id: w.id, p_fields: all });
      })} />}
    </Card>
  );
}

function BusinessInfo({ w, onReload }) {
  const state = useAsync(() => settingsOf(w), [w.id]);
  const [logo, setLogo] = useState({ busy: false, error: "", url: null });
  return (
    <LoadState state={state}>{(s) => (
      <>
        <ProfileForm w={w} initial={s.business} title="Business information" sub="Your AI receptionist and your messages use these details."
          fields={["name", "legal_name", "business_type", "description", "website", "email", "phone", "alternate_phone"]}
          render={(f) => (
            <div className="zs-grid">
              <Field label="Business name"><input value={f.values.name} onChange={f.set("name")} maxLength={200} /></Field>
              <Field label="Legal business name"><input value={f.values.legal_name} onChange={f.set("legal_name")} maxLength={200} /></Field>
              <Field label="Industry" hint="Set by the Zella team when your workspace was created."><input value={s.business.industry ?? w.industry ?? ""} disabled readOnly /></Field>
              <Field label="Business type" hint="For example: family clinic, 24-hour plumbing."><input value={f.values.business_type} onChange={f.set("business_type")} maxLength={80} /></Field>
              <Field label="Description" full hint="One or two sentences about what you do."><textarea rows={3} value={f.values.description} onChange={f.set("description")} maxLength={1000} /></Field>
              <Field label="Website"><input value={f.values.website} onChange={f.set("website")} inputMode="url" placeholder="https://" /></Field>
              <Field label="Business email"><input type="email" value={f.values.email} onChange={f.set("email")} /></Field>
              <Field label="Primary phone" hint="With country code."><input value={f.values.phone} onChange={f.set("phone")} inputMode="tel" placeholder="+15551234567" /></Field>
              <Field label="Alternate phone"><input value={f.values.alternate_phone} onChange={f.set("alternate_phone")} inputMode="tel" placeholder="+15551234567" /></Field>
            </div>
          )} />
        <Card title="Business logo" sub="PNG, JPEG or WebP, up to 2 MB. Shown in your workspace.">
          {(() => { const url = logo.url ?? s.business.logo_url; return url ? <img src={url} alt="Business logo" style={{ maxHeight: 64 }} /> : <Empty>No logo yet.</Empty>; })()}
          {roleIn(w, MANAGE) && <p style={{ marginTop: 10 }}>
            <label className="zs-btn sm">{logo.busy ? "Uploading…" : "Upload logo"}
              <input type="file" hidden accept="image/png,image/jpeg,image/webp" disabled={logo.busy} onChange={async (e) => {
                const file = e.target.files?.[0]; if (!file) return;
                setLogo({ busy: true, error: "", url: null });
                try { const url = await uploadImage(`business/${w.id}/logo`, file); await rpc("zella_set_business_logo", { p_business_id: w.id, p_url: url }); setLogo({ busy: false, error: "", url }); onReload?.(); }
                catch (err) { setLogo({ busy: false, error: err.message, url: null }); }
              }} />
            </label>
          </p>}
          <Banner tone="error">{logo.error}</Banner>
        </Card>
      </>
    )}</LoadState>
  );
}

function BusinessAddress({ w }) {
  const state = useAsync(() => settingsOf(w), [w.id]);
  return (
    <LoadState state={state}>{(s) => (
      <>
        <ProfileForm w={w} initial={s.business} title="Business address" fields={["address_line_1", "address_line_2", "city", "state", "postal_code", "country"]}
          render={(f) => (
            <div className="zs-grid">
              <Field label="Street address" full><input value={f.values.address_line_1} onChange={f.set("address_line_1")} autoComplete="address-line1" /></Field>
              <Field label="Suite or unit" full><input value={f.values.address_line_2} onChange={f.set("address_line_2")} autoComplete="address-line2" /></Field>
              <Field label="City"><input value={f.values.city} onChange={f.set("city")} /></Field>
              <Field label="State"><input value={f.values.state} onChange={f.set("state")} /></Field>
              <Field label="ZIP code"><input value={f.values.postal_code} onChange={f.set("postal_code")} inputMode="numeric" /></Field>
              <Field label="Country" hint="Two letters, like US."><input value={f.values.country} maxLength={2} onChange={(e) => f.set("country")(e.target.value.toUpperCase())} /></Field>
            </div>
          )} />
        <Needs title="Service areas aren't a setting yet" have="Add the areas you cover to Knowledge so your AI receptionist can answer questions about them.">A service-area setting needs a list of ZIP codes or cities that booking checks before offering a time.</Needs>
      </>
    )}</LoadState>
  );
}

function BusinessHours({ w }) {
  const state = useAsync(() => settingsOf(w), [w.id]);
  return (
    <>
      <LoadState state={state}>{(s) => <HoursSection key={JSON.stringify(s.hours) + JSON.stringify(s.closures)} workspace={w} settings={s} onSaved={state.reload} />}</LoadState>
      <Card title="Breaks and emergencies">
        <Facts rows={[["Break periods", "Add a second time range on the same day, for example 9–12 and 1–5"], ["Emergency calls", "AI receptionist > Escalation and fallback decides who is alerted at once"]]} />
      </Card>
    </>
  );
}

function TimezoneLocale({ w }) {
  const state = useAsync(() => settingsOf(w), [w.id]);
  return (
    <LoadState state={state}>{(s) => (
      <>
        <ProfileForm w={w} initial={s.business} title="Time zone" sub="Appointments, hours, reminders and reports all use this time zone." fields={["timezone"]}
          render={(f) => <div className="zs-field"><span>Business time zone</span><TimeZoneSelect value={f.values.timezone || w.timezone} onChange={f.set("timezone")} /></div>} />
        <Card title="Formats"><Facts rows={[["Date format", "Oct 26, 2026"], ["Time format", "3:04 PM"], ["Language", "English (US)"], ["Currency", "USD"]]} /></Card>
        <Needs title="Other languages, formats and currencies aren't available yet" have="Everything is in US English and US formats.">They need translated text and a format setting that every screen and message reads.</Needs>
      </>
    )}</LoadState>
  );
}

function Branding({ w, onGo }) {
  return (
    <>
      <Card title="How customers see you">
        <Facts rows={[["Brand name", w.name], ["Text messages", `Sent as ${w.name}`], ["Emails", `Sent with ${w.name} as the sender name`], ["Logo", "Business information"]]} />
      </Card>
      <LinkRows rows={[{ title: "Change the logo or name", detail: "Business information", onClick: () => onGo("settings/profile/info") }]} />
      <Needs title="Brand colours and branded emails aren't available yet" have="Your name and logo are used. Zella's own branding never replaces yours.">They need an email template and booking pages that read your colours.</Needs>
    </>
  );
}

/* ---------- 2. Team ---------- */

const ROLE_ROWS = [
  ["See customers, calendar, calls", ["owner", "admin", "manager", "staff", "viewer"]],
  ["Add and edit customers and appointments", ["owner", "admin", "manager", "staff"]],
  ["Listen to recordings, read transcripts", ["owner", "admin", "manager"]],
  ["Change automations, hours, receptionist", ["owner", "admin", "manager"]],
  ["Business profile, logo, words", ["owner", "admin"]],
  ["Invite people and change roles", ["owner", "admin"]],
  ["Approve sensitive actions, security log", ["owner", "admin"]],
  ["Billing choices, plan changes, cancellation", ["owner"]],
];

function RolesPermissions() {
  const roles = ["owner", "admin", "manager", "staff", "viewer"];
  return (
    <>
      <Card title="What each role can do" sub="Checked by the database on every change, not just hidden in the app. These are business roles; Zella's own admin roles are separate.">
        <div className="zs-table-wrap"><table className="zs-matrix">
          <thead><tr><th>Can…</th>{roles.map((r) => <th key={r}>{words(r === "viewer" ? "view only" : r)}</th>)}</tr></thead>
          <tbody>{ROLE_ROWS.map(([label, who]) => <tr key={label}><td>{label}</td>{roles.map((r) => <td key={r}>{who.includes(r) ? "✓" : "—"}</td>)}</tr>)}</tbody>
        </table></div>
      </Card>
      <Needs title="Custom roles (receptionist, sales, technician) aren't available yet" have="Use Staff for front-desk, sales and field teams, Manager for leads, View only for read-only access.">Custom roles need a permission list per role that every database check reads.</Needs>
    </>
  );
}

/* ---------- 3. AI receptionist ---------- */

function useAgent(w) {
  return useAsync(async () => {
    const agents = orThrow(await supabase.from("ai_agents").select("id, name, status, description, updated_at").eq("business_id", w.id).order("is_default", { ascending: false }));
    const agent = agents[0] ?? null;
    let config = null; let versions = [];
    if (agent && roleIn(w, LEAD)) {
      config = await rpc("zella_agent_config_current", { p_agent_id: agent.id }).catch(() => null);
      versions = orThrow(await supabase.from("agent_config_versions").select("id, version, status, sync_status, created_at, published_at").eq("agent_id", agent.id).order("version", { ascending: false }).limit(5));
    }
    const phones = orThrow(await supabase.from("business_phone_numbers").select("e164, label, status").eq("business_id", w.id));
    return { agent, config, versions, phones };
  }, [w.id]);
}

function ReceptionistOverview({ w }) {
  const state = useAgent(w);
  return (
    <LoadState state={state}>{(d) => d.agent ? (
      <Card title={d.agent.name}>
        <Facts rows={[["Status", words(d.agent.status)], ["Phone number", d.phones.filter((p) => p.status === "active").map((p) => p.e164).join(", ") || "Not connected yet"],
          ["Voice connection", w.voice_connected ? "Connected" : "Not connected yet"], ["Live version", d.versions.find((v) => v.status === "published") ? `Version ${d.versions.find((v) => v.status === "published").version}` : "Set up by Zella"],
          ["Last change", when(d.versions[0]?.created_at ?? d.agent.updated_at)]]} />
      </Card>
    ) : <Empty title="No receptionist yet">The Zella team creates it during setup.</Empty>}</LoadState>
  );
}

function ReceptionistEdit({ w, onNotice }) {
  const state = useAgent(w);
  return (
    <LoadState state={state}>{(d) => (d.agent
      ? <><ReceptionistEditor workspace={w} agent={d.agent} onNotice={onNotice} />
        <Needs title="Voice choice, speaking speed and languages aren't editable here yet" have="The greeting, instructions, personality, tone, after-hours, hand-over and emergency settings above are.">They live in the voice provider's settings (voice_config) and need a list of the voices and languages Vapi supports for your number.</Needs></>
      : <Empty title="No receptionist yet" />)}</LoadState>
  );
}

function ConfigFacts({ w, onGo, pick }) {
  const state = useAgent(w);
  return (
    <LoadState state={state}>{(d) => {
      if (!roleIn(w, LEAD)) return <Banner tone="warn">An owner, admin or manager can see and change how calls are handled.</Banner>;
      const rules = d.config?.escalation_rules ?? {};
      return (
        <>
          <Card title="Current settings" sub="What the receptionist does right now (the live version).">
            <Facts rows={pick(rules, d.config ?? {})} />
          </Card>
          <LinkRows rows={[{ title: "Change these", detail: "Voice and personality: instructions, after-hours, hand-over and emergencies", onClick: () => onGo("settings/receptionist/voice") }]} />
        </>
      );
    }}</LoadState>
  );
}

const callHandling = (r) => [["After hours", { take_message: "Takes a message and creates a callback", book_only: "Only books appointments", info_only: "Only answers questions" }[r.after_hours_mode] ?? "Takes a message"],
  ["Passing calls to a person", r.transfer_enabled === false || !r.transfer_number ? "Off" : `To ${r.transfer_number}${r.transfer_open_hours_only ? " during opening hours" : ""}`],
  ["Questions it can't answer", "Says it doesn't know, offers a callback, and logs the question for Knowledge"], ["Missed calls", "Become callbacks automatically"]];
const escalation = (r) => [["Emergencies", r.emergency_enabled === false ? "Off" : "Flags the call, alerts the owners at once, creates an urgent callback"],
  ["Fallback number", r.fallback_number ?? "Not set"], ["Failed transfer", "Takes a message and creates a callback; never says it connected you"], ["Nobody available", "Creates a callback for the team"]];

function Booking({ w, onGo }) {
  const state = useAgent(w);
  return (
    <LoadState state={state}>{(d) => (
      <>
        <Card title="Booking by phone" sub="The receptionist only offers times the calendar shows as free and never says booked until the calendar confirms.">
          <Facts rows={[["Can book", (d.config?.capabilities ?? []).includes?.("book_appointments") ? "Yes" : "Set by your setup"],
            ["Rules", d.config?.appointment_rules ? JSON.stringify(d.config.appointment_rules).slice(0, 200) : "Your opening hours, team hours and blocked times"]]} />
        </Card>
        <LinkRows rows={[{ title: "Hours and holidays", detail: "Business profile", onClick: () => onGo("settings/profile/hours") }, { title: "Team availability", detail: "Team & access", onClick: () => onGo("settings/team/availability") }]} />
        <Needs title="Minimum notice, buffers and appointment types aren't editable yet" have="Booking uses your hours, each person's working hours and blocked times, and prevents double-booking.">They need an appointment-types table that the booking tool reads.</Needs>
      </>
    )}</LoadState>
  );
}

function AiTesting({ w }) {
  const state = useAsync(() => (roleIn(w, MANAGE) ? supabase.from("ai_eval_cases").select("id, question, expect_contains, expect_none, created_at").eq("business_id", w.id).then(orThrow) : Promise.resolve(null)), [w.id]);
  return (
    <>
      <Card title="Test it yourself" sub="Call your Zella number and try: asking your opening hours, booking a time, asking for a person, and asking something it shouldn't know.">
        <LoadState state={state}>{(rows) => rows === null ? <p className="zs-muted">Saved test questions are visible to owners and admins.</p> : (
          <Table rows={rows} empty="No saved test questions yet." columns={[["Question", (r) => r.question], ["Should say", (r) => (r.expect_none ? "That it doesn't know" : (r.expect_contains ?? []).join(", "))], ["Added", (r) => when(r.created_at)]]} />
        )}</LoadState>
      </Card>
      <Needs title="Running the test questions from here isn't built" have="Publishing checks every version first (instructions present, no secrets, hand-over rules set).">Running them needs a server action that asks the assistant each question and records the result.</Needs>
    </>
  );
}

/* ---------- 4. Phone ---------- */

function PhoneNumbers({ w }) {
  const state = useAgent(w);
  return (
    <LoadState state={state}>{(d) => (
      <Card title="Your numbers">
        <Table rowKey={(p) => p.e164} rows={d.phones} empty="No number connected yet. The Zella team connects it (it needs carrier registration)." columns={[["Number", (p) => p.e164], ["Label", (p) => p.label ?? "—"],
          ["Status", (p) => <Pill tone={p.status === "active" ? "success" : ""}>{words(p.status)}</Pill>], ["Answered by", () => d.agent?.name ?? "AI receptionist"], ["Provider", () => "Telnyx with Vapi"]]} />
      </Card>
    )}</LoadState>
  );
}

function PhoneSetup({ w }) {
  return (
    <>
      <Card title="Setting up your line">
        <Facts rows={[["Status", w.phone_connected ? "Connected" : "Waiting for Zella to connect your number"], ["Keep your existing number", "Forward it to your Zella number: on most carriers dial *72 then the Zella number (check your carrier's instructions)"],
          ["Test", "Call your number after forwarding; the receptionist should answer"]]} />
      </Card>
      <Needs title="Ordering a new number from here isn't available" have="The Zella team orders and connects numbers.">It needs Telnyx number ordering and carrier registration from a server action.</Needs>
    </>
  );
}

function VoiceUsage({ w }) {
  const state = useAsync(() => entitlementsOf(w), [w.id]);
  return <LoadState state={state}>{(e) => <UsageCard e={e} />}</LoadState>;
}

function UsageCard({ e }) {
  const u = e.usage ?? {}; const l = e.limits ?? {};
  const of = (k, unit) => `${u[k] ?? 0}${l[k] != null ? ` of ${l[k]}` : ""} ${unit}${l[k] != null && l[k] > 0 ? ` (${Math.round(((u[k] ?? 0) / l[k]) * 100)}%)` : ""}`;
  return (
    <Card title="This period" sub={`${when(e.period?.from)} to ${when(e.period?.to)}${e.period?.calendar_month ? " (calendar month; no subscription yet)" : ""}. Counted from your records.`}>
      <Facts rows={[["AI voice minutes", of("voice_minutes", "min")], ["Texts sent", of("sms_messages", "")], ["Phone numbers", of("phone_numbers", "")], ["Team seats", of("team_members", "")],
        ["Active automations", of("automations", "")], ["Estimated extra charges", "None: Zella doesn't charge for extra usage yet"]]} />
    </Card>
  );
}

function Recording({ w }) {
  return (
    <>
      <Card title="Recordings and transcripts">
        <Facts rows={[["Who can listen and read", "Owners, admins and managers (checked by the database)"], ["Kept", "With the call, until the customer is erased"], ["Your role", words(w.role)]]} />
      </Card>
      <Needs title="Turning recording off and the spoken disclosure aren't settings yet" have="Recording follows the voice provider's setting for your number.">Laws on recording calls differ by state; some need everyone's consent. Check what applies to you. A switch here needs the phone assistant to read it at the start of every call and say the disclosure.</Needs>
    </>
  );
}

function PhoneTroubleshooting({ w }) {
  const state = useAsync(() => rpc("zella_integration_summary", { p_business_id: w.id }), [w.id]);
  return (
    <LoadState state={state}>{(s) => (
      <Card title="Connection check" sub="Live from your records.">
        <Table rowKey={(i) => i.key} rows={s.items} columns={[["Check", (i) => i.label], ["Result", (i) => <Pill tone={i.ok ? "success" : "warning"}>{i.ok ? "OK" : "Needs attention"}</Pill>], ["Detail", (i) => i.detail]]} />
        <p className="zs-muted" style={{ marginTop: 10 }}>Calls not arriving? Check forwarding on your carrier, then call your Zella number directly. If that fails, contact Zella support (Help & support).</p>
      </Card>
    )}</LoadState>
  );
}

/* ---------- 5. Billing ---------- */

function CurrentPlan({ w, onReload }) {
  const state = useAsync(() => entitlementsOf(w), [w.id]);
  const [busy, setBusy] = useState(false);
  return (
    <LoadState state={state}>{(e) => (
      <>
        <Card title="Your plan">
          <Facts rows={[["Plan", e.plan?.name ?? "No subscription yet"], ["Status", e.subscription ? words(e.subscription.status) : w.cancelled_at ? "Ended" : w.cancel_at ? `Ends ${when(w.cancel_at)}` : "Active"],
            ["Billing", e.subscription ? words(e.subscription.billing_interval) : "—"], ["Renews", when(e.subscription?.current_period_end)], ["Trial ends", when(e.subscription?.trial_end_at)],
            ["Core CRM", "Included in every plan"]]} />
          {w.cancel_at && !w.cancelled_at && w.role === "owner" && <button type="button" className="zs-btn primary" style={{ marginTop: 12 }} disabled={busy}
            onClick={async () => { setBusy(true); try { await rpc("zella_owner_continue_plan", { p_business_id: w.id }); onReload?.(); } finally { setBusy(false); } }}>Keep my plan</button>}
        </Card>
        <UsageCard e={e} />
      </>
    )}</LoadState>
  );
}

function UsageProtection({ w }) {
  const state = useAsync(() => rpc("zella_usage_preferences", { p_business_id: w.id }), [w.id]);
  return <LoadState state={state}>{(p) => <ProtectionForm w={w} p={p} />}</LoadState>;
}

function ProtectionForm({ w, p }) {
  const form = useForm({ mode: p.overage_mode, limit: p.spend_limit_cents != null ? String(p.spend_limit_cents / 100) : "", fallback: p.fallback, thresholds: p.notify_thresholds });
  const [confirm, setConfirm] = useState(false);
  const v = form.values;
  const save = () => form.save(async (x) => {
    await rpc("zella_save_usage_preferences", { p_business_id: w.id, p_thresholds: x.thresholds, p_mode: x.mode,
      p_spend_limit_cents: x.mode === "stop" ? null : Math.round(Number(x.limit) * 100), p_fallback: x.fallback });
  }, "Saved. This is your authorization; Zella never charges more than this.");
  return (
    <Card title="When included AI minutes run out" sub="You decide. Zella never charges for extra usage without this choice from the owner.">
      {!p.can_edit && noRole("the owner")}
      <fieldset disabled={!p.can_edit} style={{ border: 0, padding: 0, margin: 0 }}>
        <div className="zs-grid">
          <Field label="Extra usage" full><select value={v.mode} onChange={form.set("mode")}>
            <option value="stop">Don't allow paid extra usage</option><option value="pay_as_you_go">Pay as you go, up to my limit</option><option value="auto_top_up">Top up automatically, up to my limit</option></select></Field>
          {v.mode !== "stop" && <Field label="Monthly spending limit (USD)" error={v.limit && !(Number(v.limit) > 0) ? "Enter an amount above 0" : ""}><input inputMode="decimal" value={v.limit} onChange={form.set("limit")} /></Field>}
          <Field label="If extra usage isn't allowed"><select value={v.fallback} onChange={form.set("fallback")}>
            <option value="take_message">AI takes a message</option><option value="forward_to_business">Forward calls to the business</option><option value="voicemail_only">Voicemail only</option></select></Field>
          <div className="zs-field full"><span>Tell me at</span><div className="zs-actions">{[50, 70, 80, 90, 100].map((t) => (
            <label key={t} className="zs-check"><input type="checkbox" checked={v.thresholds.includes(t)} onChange={() => form.set("thresholds")(v.thresholds.includes(t) ? v.thresholds.filter((x) => x !== t) : [...v.thresholds, t].sort((a, b) => a - b))} /><span>{t}%</span></label>
          ))}</div></div>
        </div>
      </fieldset>
      {p.authorized_at && <p className="zs-muted">Last authorized {when(p.authorized_at)}.</p>}
      {p.can_edit && <SaveBar form={form} disabled={v.mode !== "stop" && !(Number(v.limit) > 0)} onSave={() => (v.mode !== "stop" ? setConfirm(true) : save())} />}
      {confirm && <Confirm title="Allow paid extra usage?" confirmLabel="Authorize" onClose={() => setConfirm(false)} onConfirm={save}>
        You authorize charges for AI usage beyond your plan, up to ${Number(v.limit).toFixed(2)} a month. Zella doesn't charge for extra usage yet; when it does, this limit applies.
      </Confirm>}
      <Banner>Stopping calls at the limit isn't enforced yet; you'll get the notices you choose above.</Banner>
    </Card>
  );
}

function Rollover({ w }) {
  const state = useAsync(() => entitlementsOf(w), [w.id]);
  return (
    <LoadState state={state}>{(e) => (
      <Card title="Included minutes">
        <Facts rows={[["Included this period", e.limits?.voice_minutes ?? "No limit set"], ["Used", e.usage?.voice_minutes ?? 0],
          ["Remaining", e.limits?.voice_minutes != null ? Math.max(0, e.limits.voice_minutes - (e.usage?.voice_minutes ?? 0)) : "—"], ["Resets", when(e.period?.to)],
          ["Unused minutes", "Don't carry over (no rollover is set for your plan)"], ["Top-up minutes", "No top-ups have been bought"]]} />
      </Card>
    )}</LoadState>
  );
}

function BillingNeeds({ title, have, children }) {
  return <Needs title={title} have={have}>{children}</Needs>;
}

function PlanChanges({ w }) {
  const state = useAsync(async () => ({ plans: orThrow(await supabase.from("plans").select("id, name, description, price_monthly, price_yearly, currency, limits").eq("is_active", true).order("price_monthly", { ascending: true, nullsFirst: false })), e: await entitlementsOf(w) }), [w.id]);
  const [ask, setAsk] = useState(null);
  const [done, setDone] = useState("");
  return (
    <LoadState state={state}>{({ plans, e }) => (
      <>
        <Banner tone="success">{done}</Banner>
        <Card title="Compare plans" sub="Every plan has the full CRM. They differ by included usage and support.">
          <Table rows={plans} empty="Plans aren't published yet. Ask Zella support." columns={[["Plan", (p) => <>{p.name}{e.plan?.id === p.id && <> · <Pill tone="accent">Current</Pill></>}</>],
            ["Monthly", (p) => (p.price_monthly != null ? `$${p.price_monthly}` : "—")], ["Annual", (p) => (p.price_yearly != null ? `$${p.price_yearly}` : "—")],
            ["AI minutes", (p) => p.limits?.voice_minutes ?? "—"], ["Team seats", (p) => p.limits?.team_members ?? "—"], ["Support", (p) => words(p.limits?.support_level ?? "—")],
            ["", (p) => w.role === "owner" && e.plan?.id !== p.id && <button type="button" className="zs-btn sm" onClick={() => setAsk(p)}>Request this plan</button>]]} />
        </Card>
        {ask && <Confirm title={`Request ${ask.name}?`} confirmLabel="Send request" onClose={() => setAsk(null)} onConfirm={async () => {
          await rpc("zella_business_request", { p_business_id: w.id, p_kind: "plan_change", p_subject: `Plan change to ${ask.name}`, p_description: `Requested from Settings. Current plan: ${e.plan?.name ?? "none"}.`, p_details: { plan_id: ask.id } });
          setDone("Request sent. The Zella team confirms the price, any proration and the date it takes effect before changing anything.");
        }}>Nothing changes until the Zella team confirms the price, proration and effective date with you.</Confirm>}
      </>
    )}</LoadState>
  );
}

function Cancellation({ w }) {
  const [open, setOpen] = useState(false);
  const [done, setDone] = useState("");
  if (w.cancelled_at) return <Card title="Your plan has ended" sub="Contact Zella support to start again." />;
  return (
    <>
      <Card title="Cancel your plan" sub="Your workspace and AI receptionist keep working until the end of the paid period. Your records are kept for 90 days afterwards so you can export them or come back.">
        <Banner tone="success">{done}</Banner>
        {w.cancel_at ? <Facts rows={[["Scheduled to end", when(w.cancel_at)]]} /> : w.role === "owner"
          ? <button type="button" className="zs-btn danger-outline" onClick={() => setOpen(true)}>Request cancellation</button>
          : <p className="zs-muted">Only the owner can request cancellation.</p>}
      </Card>
      {open && <Confirm title="Request cancellation?" danger reason confirmLabel="Send request" onClose={() => setOpen(false)} onConfirm={async (reason) => {
        await rpc("zella_business_request", { p_business_id: w.id, p_kind: "cancellation", p_subject: "Cancellation request", p_description: reason });
        setDone("Request sent. The Zella team confirms the end date with you; nothing stops until then.");
      }}>The Zella team will confirm the end date with you before anything stops.</Confirm>}
    </>
  );
}

/* ---------- 6. Calendar ---------- */

function CalendarConnections({ w }) {
  const state = useAsync(() => supabase.from("calendar_connections").select("id, provider, status, account_email, connected_at, last_pushed_at, last_pulled_at, last_error").eq("business_id", w.id).then(orThrow), [w.id]);
  return (
    <LoadState state={state}>{(rows) => (
      <Card title="Connected calendars" sub="Only the status and account are shown; access keys stay on the server.">
        <Table rows={rows} empty="No calendar connected. Google Calendar is connected by the Zella team during setup." columns={[["Calendar", (c) => words(c.provider)], ["Account", (c) => c.account_email ?? "—"],
          ["Status", (c) => <Pill tone={c.status === "active" ? "success" : "warning"}>{words(c.status)}</Pill>], ["Last sync", (c) => when(c.last_pushed_at ?? c.last_pulled_at)], ["Problem", (c) => c.last_error ?? "—"]]} />
      </Card>
    )}</LoadState>
  );
}

function AppointmentSettings({ onGo }) {
  return (
    <>
      <LinkRows rows={[{ title: "Opening hours and holidays", detail: "Business profile > Business hours", onClick: () => onGo("settings/profile/hours") },
        { title: "Who can be booked, and when", detail: "Team & access > Staff availability", onClick: () => onGo("settings/team/availability") },
        { title: "Reminders, confirmations, follow-ups", detail: "Automations", onClick: () => onGo("settings/automations/library") }]} />
      <Needs title="Default length, buffers, minimum notice and booking horizon aren't settings yet" have="Each booking sets its own length; the calendar prevents overlaps with appointments and blocked times.">They need an appointment-types table with these fields that booking reads.</Needs>
    </>
  );
}

/* ---------- 7. CRM ---------- */

function toCsv(rows, columns) {
  const cell = (v) => {
    let s = v === null || v === undefined ? "" : String(v);
    if (/^[=+\-@]/.test(s)) s = `'${s}`;   // stops spreadsheets running it as a formula
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  return [columns.join(","), ...rows.map((r) => columns.map((c) => cell(r[c])).join(","))].join("\n");
}

const EXPORTS = {
  customers: ["Customers", "id, first_name, last_name, company_name, phone, email, source, status, lead_stage, do_not_contact, created_at"],
  appointments: ["Appointments", "id, customer_id, title, status, start_time, end_time, created_at"],
  calls_view: ["Calls", "id, customer_id, direction, status, from_number, to_number, started_at, duration_seconds, ai_handled, outcome"],
};

function DataExport({ w }) {
  const [busy, setBusy] = useState("");
  const [msg, setMsg] = useState({ text: "", error: "" });
  const allowed = roleIn(w, LEAD);
  async function run(table) {
    setBusy(table);
    setMsg({ text: "", error: "" });
    try {
      const cols = EXPORTS[table][1];
      const rows = [];
      for (let from = 0; from < 50000; from += 1000) {
        const page = orThrow(await supabase.from(table).select(cols).eq("business_id", w.id).order("created_at", { ascending: true }).range(from, from + 999));
        rows.push(...page);
        if (page.length < 1000) break;
      }
      const blob = new Blob([toCsv(rows, cols.split(", "))], { type: "text/csv" });
      const a = Object.assign(document.createElement("a"), { href: URL.createObjectURL(blob), download: `${w.name.replace(/[^a-z0-9]+/gi, "-").toLowerCase()}-${table.replace("_view", "")}-${new Date().toISOString().slice(0, 10)}.csv` });
      document.body.appendChild(a); a.click(); a.remove();
      setMsg({ text: `${rows.length} ${EXPORTS[table][0].toLowerCase()} exported. Keep the file safe; it has customers' contact details.`, error: "" });
    } catch (err) { setMsg({ text: "", error: say(err) }); } finally { setBusy(""); }
  }
  return (
    <Card title="Export your records" sub="CSV files with your business's records only. Owners, admins and managers.">
      <Banner tone="success">{msg.text}</Banner><Banner tone="error">{msg.error}</Banner>
      {allowed ? <ul className="zs-rows">{Object.entries(EXPORTS).map(([t, [label]]) => <li key={t}><div><strong>{label}</strong><small>All of them, as CSV</small></div><button type="button" className="zs-btn sm" disabled={Boolean(busy)} onClick={() => run(t)}>{busy === t ? "Exporting…" : "Download"}</button></li>)}</ul>
        : <p className="zs-muted">Your role can't export records.</p>}
    </Card>
  );
}

function CustomerRecords({ w, records, onNotice }) {
  return (
    <>
      <Card title="Duplicate detection" sub="Built in, not a setting.">
        <Facts rows={[["Same phone or email", "Linked to the existing person"], ["Similar but not certain", "A check is added to Tasks for a person to decide"]]} />
      </Card>
      <RecordSettingsPage workspace={w} types={records.types} canManage={roleIn(w, LEAD)} onNotice={onNotice} onChanged={records.reload} />
    </>
  );
}

function Communication({ w }) {
  const state = useAsync(async () => {
    const rows = orThrow(await supabase.from("contact_consents").select("channel, purpose, status").eq("business_id", w.id).limit(5000));
    return rows.reduce((a, r) => { const k = `${r.channel} ${r.purpose} ${r.status}`; a[k] = (a[k] ?? 0) + 1; return a; }, {});
  }, [w.id]);
  return (
    <LoadState state={state}>{(counts) => (
      <Card title="Consent and opt-outs" sub="Recorded automatically (STOP/START replies, unsubscribe links, staff changes). Checked before every message.">
        {Object.keys(counts).length ? <Facts rows={Object.entries(counts).map(([k, v]) => [words(k), v])} /> : <Empty>No consent changes recorded yet.</Empty>}
      </Card>
    )}</LoadState>
  );
}

/* ---------- 8. Industry ---------- */

const TERM_KEYS = [["customer", "One customer"], ["customers", "Customers"], ["appointment", "One appointment"], ["appointments", "Appointments"], ["staff", "One team member"], ["staff_plural", "Team members"],
  ["service", "One service"], ["services", "Services"], ["job", "One job"], ["jobs", "Jobs"]];

function Terminology({ w, onReload }) {
  const term = makeTerm(w);
  const form = useForm(Object.fromEntries(TERM_KEYS.map(([k]) => [k, term(k)])));
  const canEdit = roleIn(w, MANAGE);
  return (
    <Card title="Words your workspace uses" sub={`Starting words come from ${w.industry ?? "your industry"}. Changes show everywhere after saving.`}>
      {!canEdit && noRole()}
      <div className="zs-grid">{TERM_KEYS.map(([k, label]) => <Field key={k} label={label}><input value={form.values[k]} onChange={form.set(k)} maxLength={40} disabled={!canEdit} /></Field>)}</div>
      {canEdit && <SaveBar form={form} onSave={() => form.save(async (v) => { await rpc("zella_save_terminology", { p_business_id: w.id, p_words: v }); onReload?.(); })} />}
    </Card>
  );
}

function IndustryProfile({ w }) {
  return (
    <Card title="Industry profile">
      <Facts rows={[["Industry", w.industry ?? "—"], ["Modules switched on", (w.modules ?? []).map(words).join(", ") || "None"], ["Words", "Industry & business workflows > Terminology"], ["Setup", words(w.onboarding_status ?? "")]]} />
    </Card>
  );
}

function Modules({ w }) {
  return (
    <>
      <Card title="Modules">
        <Table rowKey={(m) => m} rows={w.modules ?? []} empty="No modules switched on." columns={[["Module", (m) => words(m)], ["Status", () => <Pill tone="success">On</Pill>]]} />
      </Card>
      <Needs title="Switching optional modules on or off here isn't available" have="The Zella team sets modules for your industry and plan.">It needs a list of optional modules per plan, checked on the server, so a module can't be switched on outside the plan.</Needs>
    </>
  );
}

/* ---------- 12. Notifications ---------- */

const KINDS = [["daily_summary", "Daily summary", true], ["weekly_review", "Weekly review", true], ["new_lead", "New lead", false], ["lead_overdue", "Lead not followed up", true],
  ["appointment_new", "New appointment", false], ["appointment_cancelled", "Appointment cancelled", false], ["appointment_rescheduled", "Appointment moved", false],
  ["callback_assigned", "Callback assigned to me", false], ["callback_overdue", "Callback overdue", true], ["customer_arrived", "Customer checked in", false],
  ["staff_joined", "Someone joined the team", false], ["approval_requested", "Approval needed", true], ["data_rights_request", "Customer data request", true],
  ["usage_threshold", "AI minutes running low", true], ["reconnect_reminder", "Connection needs fixing", true], ["email_bounced", "Email bounced", false]];

function NotificationPrefs({ w }) {
  const state = useAsync(() => Promise.all([rpc("zella_my_notification_prefs", { p_business_id: w.id }), settingsOf(w)]), [w.id]);
  const [error, setError] = useState("");
  return (
    <LoadState state={state}>{([prefs, s]) => (
      <>
        <Card title="Email me about" sub="Everything also appears in the bell. Defaults: summaries and warnings by email, the rest in the app only.">
          <Banner tone="error">{error}</Banner>
          <ul className="zs-rows">{KINDS.map(([k, label, dflt]) => {
            const on = prefs[k] ?? dflt;
            return <li key={k}><div><strong>{label}</strong><small>{prefs[k] === undefined ? "Default" : "Your choice"}</small></div>
              <Toggle on={on} label={`Email: ${label}`} onChange={async (v) => { try { await rpc("zella_set_my_notification_pref", { p_business_id: w.id, p_kind: k, p_email: v }); state.reload(); } catch (err) { setError(err.message); } }} /></li>;
          })}</ul>
        </Card>
        <Card title="Text me urgent alerts" sub={s.me?.phone ? `To ${s.me.phone}, for this workspace.` : "Add your mobile number in Personal profile first."}>
          <Toggle on={Boolean(s.me?.sms_alerts)} disabled={!s.me?.phone && !s.me?.sms_alerts} label="Text me urgent alerts"
            onChange={async (v) => { try { await rpc("zella_set_my_sms_alerts", { p_business_id: w.id, p_enabled: v }); state.reload(); } catch (err) { setError(err.message); } }} />
        </Card>
        <Needs title="Push notifications aren't available" have="In-app (bell), email and urgent texts.">Push needs the phone app.</Needs>
      </>
    )}</LoadState>
  );
}

function TeamNotificationRules({ onGo }) {
  return (
    <>
      <Card title="Who is told">
        <Facts rows={[["Business-wide alerts", "Owners and admins"], ["Assigned work", "The person it's assigned to"], ["Escalations", "Owners and admins, urgent"], ["Each automation", "Its own 'Tell the owner by' choice (text, email or both)"]]} />
      </Card>
      <LinkRows rows={[{ title: "Per-automation choices", detail: "Automations", onClick: () => onGo("settings/automations/library") }]} />
    </>
  );
}

function UsageNotifications({ w, onGo }) {
  const state = useAsync(() => rpc("zella_usage_preferences", { p_business_id: w.id }), [w.id]);
  return (
    <LoadState state={state}>{(p) => (
      <>
        <Card title="Usage notices"><Facts rows={[["AI minutes", `At ${p.notify_thresholds.join(", ")}% of your allowance`], ["Who", "Owners"], ["Failed payments", "Sent by the payment provider once billing is connected"]]} /></Card>
        <LinkRows rows={[{ title: "Change thresholds", detail: "Billing & subscription > AI usage protection", onClick: () => onGo("settings/billing/protection") }]} />
      </>
    )}</LoadState>
  );
}

function NotificationHistory({ w }) {
  const state = useAsync(() => supabase.from("staff_notifications").select("id, kind, severity, title, delivery_status, created_at, read_at").eq("business_id", w.id).order("created_at", { ascending: false }).limit(50).then(orThrow), [w.id]);
  return (
    <LoadState state={state}>{(rows) => (
      <Card title="Recent notifications" sub="Yours and business-wide ones.">
        <Table rows={rows} empty="No notifications yet." columns={[["When", (n) => when(n.created_at)], ["What", (n) => n.title], ["Type", (n) => words(n.kind)],
          ["Email", (n) => words(n.delivery_status ?? "—")], ["Read", (n) => (n.read_at ? "Yes" : "No")]]} />
      </Card>
    )}</LoadState>
  );
}

/* ---------- 15. Help ---------- */

function HelpCenter() {
  const p = usePlatformInfo();
  return (
    <>
      <Card title="Get help from Zella">
        <Facts rows={[["Email", p.support_email ?? "Not published yet"], ["Phone", p.support_phone ?? "Not published yet"], ["Website", p.website ?? "—"]]} />
      </Card>
      <Needs title="A help center with guides isn't published yet" have="Contact Zella support, or open a support request.">Guides need a documentation site; links will appear here once it exists.</Needs>
    </>
  );
}

function SupportTickets({ w, kind = "support" }) {
  const state = useAsync(() => supabase.from("support_tickets").select("id, subject, status, priority, category, created_at, resolved_at").eq("business_id", w.id).order("created_at", { ascending: false }).limit(50).then(orThrow), [w.id]);
  const form = useForm({ kind, subject: "", description: "", urgent: false });
  const v = form.values;
  return (
    <>
      <Card title={kind === "feedback" ? "Send feedback" : "New support request"}>
        {roleIn(w, ["viewer"]) ? <p className="zs-muted">View-only members can't send requests.</p> : <>
          <div className="zs-grid">
            <Field label="Type"><select value={v.kind} onChange={form.set("kind")}>
              {[["support", "Question or help"], ["issue", "Something isn't working"], ["feature", "Feature request"], ["feedback", "Feedback"]].map(([k, t]) => <option key={k} value={k}>{t}</option>)}</select></Field>
            <Field label="Subject"><input value={v.subject} onChange={form.set("subject")} maxLength={200} /></Field>
            <Field label="Details" full><textarea rows={4} value={v.description} onChange={form.set("description")} maxLength={5000} /></Field>
            {v.kind === "issue" && <label className="zs-check full"><input type="checkbox" checked={v.urgent} onChange={form.set("urgent")} /><span>Urgent: calls or bookings aren't working</span></label>}
          </div>
          <SaveBar form={form} label="Send" disabled={v.subject.trim().length < 3} onSave={() => form.save(async (x) => {
            await rpc("zella_business_request", { p_business_id: w.id, p_kind: x.kind, p_subject: x.subject, p_description: x.description, p_details: { urgent: x.urgent } });
            state.reload();
            return { subject: "", description: "", urgent: false };
          }, "Sent. The Zella team will reply by email.")} />
        </>}
      </Card>
      <LoadState state={state}>{(rows) => (
        <Card title="Your requests">
          <Table rows={rows} empty="No requests yet." columns={[["Subject", (t) => t.subject], ["Type", (t) => words(t.category)], ["Priority", (t) => words(t.priority)],
            ["Status", (t) => <Pill tone={["resolved", "closed"].includes(t.status) ? "success" : "warning"}>{words(t.status)}</Pill>], ["Opened", (t) => when(t.created_at)]]} />
        </Card>
      )}</LoadState>
      <Needs title="Replies and attachments inside Zella aren't available" have="The Zella team replies by email.">A conversation thread needs ticket messages and file storage for attachments.</Needs>
    </>
  );
}

function SystemStatus({ w }) {
  const state = useAsync(() => rpc("zella_integration_summary", { p_business_id: w.id }), [w.id]);
  const p = usePlatformInfo();
  return (
    <LoadState state={state}>{(s) => (
      <>
        {p.maintenance && <Banner tone="warn">{p.maintenance.message}</Banner>}
        <Card title="Your services" sub="Checked live from your records.">
          <Table rowKey={(i) => i.key} rows={[{ key: "ai", label: "AI receptionist", ok: w.receptionist?.status === "active", detail: words(w.receptionist?.status ?? "not set up") }, ...s.items]}
            columns={[["Service", (i) => i.label], ["Status", (i) => <Pill tone={i.ok ? "success" : "warning"}>{i.ok ? "Working" : "Needs attention"}</Pill>], ["Detail", (i) => i.detail]]} />
        </Card>
      </>
    )}</LoadState>
  );
}

/* ---------- 13. Privacy ---------- */

function Privacy({ w, onOpenPerson, onNotice }) {
  return (
    <>
      <Card title="Your data">
        <Facts rows={[["Recordings and transcripts", "Managers and above"], ["Customer data requests", "Logged and handled below, within 30 days"], ["Erasing a customer", "Needs a second owner or admin when you have two"],
          ["If you cancel", "Records kept 90 days, then the Zella team removes them"]]} />
      </Card>
      {roleIn(w, DATA_RIGHTS_ROLES) ? <DataRightsList workspace={w} onOpenPerson={onOpenPerson} onNotice={onNotice} /> : <p className="zs-muted">Managers and above handle customer data requests.</p>}
      <LegalDocs w={w} />
    </>
  );
}

function LegalDocs({ w }) {
  const state = useAsync(async () => {
    const docs = orThrow(await supabase.from("legal_documents").select("id, kind, version, title, body, effective_at, requires_acceptance").order("kind"));
    const accepted = orThrow(await supabase.from("legal_acceptances").select("document_id").eq("business_id", w.id));
    return { docs, accepted: new Set(accepted.map((a) => a.document_id)) };
  }, [w.id]);
  const [open, setOpen] = useState(null);
  const [error, setError] = useState("");
  return (
    <LoadState state={state}>{({ docs, accepted }) => (
      <Card title="Zella's policies" sub="The versions in effect.">
        <Banner tone="error">{error}</Banner>
        <Table rows={docs} empty="No policies published yet." columns={[["Policy", (d) => d.title], ["Version", (d) => d.version], ["Effective", (d) => when(d.effective_at)],
          ["Accepted for this business", (d) => (d.requires_acceptance ? (accepted.has(d.id) ? <Pill tone="success">Accepted</Pill> : roleIn(w, MANAGE)
            ? <button type="button" className="zs-btn sm primary" onClick={async () => { try { await rpc("zella_accept_legal_document", { p_document_id: d.id, p_business_id: w.id }); state.reload(); } catch (err) { setError(err.message); } }}>Read and accept</button>
            : <Pill tone="warning">Waiting for an owner</Pill>) : "Not required")],
          ["", (d) => <button type="button" className="zs-btn sm" onClick={() => setOpen(open === d.id ? null : d.id)}>{open === d.id ? "Hide" : "Read"}</button>]]} />
        {open && <div className="zs-card" style={{ padding: 14, marginTop: 10, whiteSpace: "pre-wrap", maxHeight: 360, overflow: "auto" }}>{docs.find((d) => d.id === open)?.body}</div>}
      </Card>
    )}</LoadState>
  );
}

/* ---------- Registry ---------- */

const page = (key, label, render, keywords = "") => ({ key, label, render, keywords });
const lazyNeeds = (title, have, body) => () => <BillingNeeds title={title} have={have}>{body}</BillingNeeds>;

function registry(w) {
  const lead = roleIn(w, LEAD); const manage = roleIn(w, MANAGE);
  const only = (ok, el) => (ok ? el : <Banner tone="warn">Your role can't open this. Ask an owner or admin.</Banner>);
  return [
    { key: "profile", label: "Business profile", icon: "storefront", items: [
      page("info", "Business information", (c) => <BusinessInfo w={w} onReload={c.onReload} />, "name legal description industry type website email phone logo"),
      page("address", "Business address", () => <BusinessAddress w={w} />, "street suite city state zip country service area"),
      page("hours", "Business hours", () => <BusinessHours w={w} />, "open close holidays breaks special emergency"),
      page("locale", "Time zone and locale", () => <TimezoneLocale w={w} />, "timezone date time format language currency"),
      page("branding", "Branding", (c) => <Branding w={w} onGo={c.onGo} />, "logo colours brand email"),
    ] },
    { key: "team", label: "Team and access", icon: "badge", items: [
      page("members", "Team members", (c) => only(manage, <AccessPage workspace={w} userId={c.userId} refreshKey={0} onNotice={c.onNotice} />), "invite remove role status"),
      page("roles", "Roles and permissions", () => <RolesPermissions />, "owner admin manager staff viewer"),
      page("invitations", "Team invitations", (c) => only(manage, <AccessPage workspace={w} userId={c.userId} refreshKey={0} onNotice={c.onNotice} />), "resend revoke expired"),
      page("availability", "Staff availability", (c) => <TeamPage workspace={w} email={c.email} refreshKey={0} onNotice={c.onNotice} />, "working hours time off"),
      page("security", "Team security", (c) => only(manage, <><SecurityLogPage workspace={w} refreshKey={0} /><ApprovalsPage workspace={w} refreshKey={0} onNotice={c.onNotice} /></>), "access review role history"),
    ] },
    { key: "receptionist", label: "AI receptionist", icon: "record_voice_over", items: [
      page("overview", "Receptionist overview", () => <ReceptionistOverview w={w} />, "status phone version"),
      page("voice", "Voice and personality", (c) => only(lead, <ReceptionistEdit w={w} onNotice={c.onNotice} />), "greeting tone personality instructions voice language"),
      page("knowledge", "Business knowledge", (c) => <KnowledgePage workspace={w} refreshKey={0} onNotice={c.onNotice} />, "services faq policies prices"),
      page("calls", "Call handling", (c) => <ConfigFacts w={w} onGo={c.onGo} pick={(r) => callHandling(r)} />, "after hours transfer message callback missed"),
      page("escalation", "Escalation and fallback", (c) => <ConfigFacts w={w} onGo={c.onGo} pick={(r) => escalation(r)} />, "emergency human handoff voicemail fallback"),
      page("booking", "Appointment booking", (c) => <Booking w={w} onGo={c.onGo} />, "book schedule notice duration"),
      page("testing", "AI testing", () => <AiTesting w={w} />, "test scenarios validation"),
      page("versions", "Version history", (c) => only(lead, <ReceptionistEdit w={w} onNotice={c.onNotice} />), "versions restore"),
    ] },
    { key: "phone", label: "Phone system", icon: "call", items: [
      page("numbers", "Phone numbers", () => <PhoneNumbers w={w} />, "number provider routing"),
      page("setup", "Phone setup", () => <PhoneSetup w={w} />, "forwarding test call"),
      page("routing", "Call routing", (c) => <ConfigFacts w={w} onGo={c.onGo} pick={(r) => [...callHandling(r).slice(0, 2), ...escalation(r).slice(0, 2)]} />, "after hours emergency transfer"),
      page("usage", "Voice usage", () => <VoiceUsage w={w} />, "minutes charges"),
      page("recording", "Call recording and privacy", () => <Recording w={w} />, "recording transcript consent"),
      page("troubleshooting", "Troubleshooting", () => <PhoneTroubleshooting w={w} />, "status failed calls"),
    ] },
    { key: "billing", label: "Billing and subscription", icon: "credit_card", items: [
      page("plan", "Current plan", (c) => <CurrentPlan w={w} onReload={c.onReload} />, "plan renewal status"),
      page("usage", "Usage and charges", () => <VoiceUsage w={w} />, "usage sms voice charges"),
      page("protection", "AI usage protection", () => <UsageProtection w={w} />, "top-up pay as you go spending limit 70 90 100"),
      page("rollover", "Rollover policy", () => <Rollover w={w} />, "reset remaining"),
      page("payment-methods", "Payment methods", lazyNeeds("Payment methods aren't managed in Zella yet", "Nothing is charged from Zella today.", "Adding a card needs the payment provider's secure page; Zella never stores card numbers.")),
      page("invoices", "Invoices", lazyNeeds("Invoices aren't available in Zella yet", "The Zella team sends invoices by email.", "They need the payment provider's invoice records.")),
      page("changes", "Plan changes", () => <PlanChanges w={w} />, "upgrade downgrade compare"),
      page("cancellation", "Cancellation", () => <Cancellation w={w} />, "cancel"),
    ] },
    { key: "calendar", label: "Calendar and appointments", icon: "calendar_today", items: [
      page("connections", "Calendar connections", () => <CalendarConnections w={w} />, "google outlook sync"),
      page("settings", "Appointment settings", (c) => <AppointmentSettings onGo={c.onGo} />, "duration buffer notice"),
      page("types", "Appointment types", lazyNeeds("Appointment types aren't a setting yet", "Each booking has its own title and length.", "They need an appointment-types table (name, length, staff, rules).")),
      page("rules", "Scheduling rules", () => <Card title="How scheduling works"><Facts rows={[["Double-booking", "Prevented: overlapping appointments and blocked times are refused"], ["Staff", "Only during each person's working hours"], ["Time zone", w.timezone.replace(/_/g, " ")], ["Holidays", "Closed days from Business hours"]]} /></Card>, "conflicts holidays"),
      page("notifications", "Appointment notifications", (c) => <AutomationsPage workspace={w} refreshKey={0} onNotice={c.onNotice} />, "reminder confirmation"),
    ] },
    { key: "crm", label: "CRM and customers", icon: "group", items: [
      page("records", "Customer records", (c) => <CustomerRecords w={w} records={c.records} onNotice={c.onNotice} />, "fields duplicate status"),
      page("leads", "Lead management", () => <LeadSourcesPage workspace={w} refreshKey={0} />, "sources assignment"),
      page("pipeline", "Pipeline", lazyNeeds("Pipeline stages aren't editable yet", "Leads move through the fixed stages on the Leads page; changing stage never changes the customer's details.", "Custom stages need a stage list per business that the Leads page and automations read.")),
      page("fields", "Custom fields", (c) => <RecordSettingsPage workspace={w} types={c.records.types} canManage={lead} onNotice={c.onNotice} onChanged={c.records.reload} />, "field type required"),
      page("export", "Import and export", () => <><DataExport w={w} /><BillingNeeds title="Importing isn't available yet" have="Add people one at a time, or ask Zella to import a file for you.">Importing needs a file upload with field mapping, a preview and duplicate checks.</BillingNeeds></>, "csv import export"),
      page("communication", "Customer communication", () => <Communication w={w} />, "consent unsubscribe opt-out"),
    ] },
    { key: "industry", label: "Industry and workflows", icon: "tune", items: [
      page("profile", "Industry profile", () => <IndustryProfile w={w} />, "industry modules"),
      page("terminology", "Terminology", (c) => <Terminology w={w} onReload={c.onReload} />, "words patients customers jobs"),
      page("fields", "Industry fields", (c) => <RecordSettingsPage workspace={w} types={c.records.types} canManage={lead} onNotice={c.onNotice} onChanged={c.records.reload} />, "fields"),
      page("workflows", "Workflow rules", (c) => <AutomationsPage workspace={w} refreshKey={0} onNotice={c.onNotice} />, "rules status follow-up"),
      page("services", "Service catalog", (c) => <KnowledgePage workspace={w} refreshKey={0} onNotice={c.onNotice} />, "services prices"),
      page("modules", "Industry modules", () => <Modules w={w} />, "modules"),
    ] },
    { key: "automations", label: "Automations", icon: "bolt", items: [
      page("library", "Automation library", (c) => <AutomationsPage workspace={w} refreshKey={0} onNotice={c.onNotice} />, "templates active disabled"),
      page("events", "Event-based automations", () => <Card title="What starts an automation"><Facts rows={[["New lead", "Fast callback, follow-ups"], ["Missed call", "Callback and text when allowed"], ["Appointment booked or moved", "Confirmation and reminders"], ["Appointment cancelled", "Waitlist offer"], ["Follow-up due", "Quote and lead follow-ups"], ["Status changes", "Industry rules"]]} /></Card>, "trigger event"),
      page("history", "Automation history", (c) => <AutomationsPage workspace={w} refreshKey={0} onNotice={c.onNotice} />, "runs executions"),
      page("recovery", "Failure recovery", (c) => only(lead, <FailedWorkPage workspace={w} refreshKey={0} onNotice={c.onNotice} />), "failed retry"),
    ] },
    { key: "integrations", label: "Integrations", icon: "extension", items: [
      page("available", "Integrations", (c) => <IntegrationsPage workspace={w} refreshKey={0} onNotice={c.onNotice} />, "google outlook connected accounts health reconnect"),
      page("calendar", "Calendar accounts", () => <CalendarConnections w={w} />, "calendar"),
      page("health", "Integration health", () => <PhoneTroubleshooting w={w} />, "errors sync"),
    ] },
    { key: "messages", label: "SMS, email and messages", icon: "forum", items: [
      page("config", "Messaging setup", () => <Card title="Messaging"><Facts rows={[["Texts", w.phone_connected ? "From your Zella number" : "Start once your number is connected"], ["Email", "Sent with your business name"], ["Marketing texts", "Off"], ["Quiet hours", "Texts wait until morning"]]} /></Card>, "provider sender"),
      page("templates", "Message templates", () => <Templates w={w} />, "sms email templates"),
      page("rules", "Communication rules", () => <Card title="Rules every message follows"><Facts rows={[["Consent", "Checked before every text and email"], ["Opt-out", "STOP, unsubscribe links"], ["Quiet hours", "No texts late at night, business time"], ["Duplicates", "The same message isn't sent twice"]]} /></Card>, "consent quiet hours"),
      page("reviews", "Reviews and offers", () => <div className="zs-cols"><ReviewLinkPanel workspace={w} /><OffersPanel workspace={w} /></div>, "review link offers"),
      page("history", "Delivery history", (c) => <InboxPage workspace={w} refreshKey={0} onNotice={c.onNotice} onOpenPerson={c.onOpenPerson} />, "delivered failed"),
    ] },
    { key: "notifications", label: "Notifications", icon: "notifications", items: [
      page("preferences", "Notification preferences", () => <NotificationPrefs w={w} />, "email sms in-app alerts"),
      page("team", "Team notification rules", (c) => <TeamNotificationRules onGo={c.onGo} />, "roles escalation"),
      page("usage", "Usage notifications", (c) => <UsageNotifications w={w} onGo={c.onGo} />, "70 90 100"),
      page("history", "Notification history", () => <NotificationHistory w={w} />, "read delivered"),
    ] },
    { key: "security", label: "Security and privacy", icon: "shield", items: [
      page("account", "Account security", (c) => <AccountSecurityPanel email={c.email} />, "password mfa sessions"),
      page("team", "Team access", (c) => only(manage, <AccessPage workspace={w} userId={c.userId} refreshKey={0} onNotice={c.onNotice} />), "roles revoke"),
      page("privacy", "Privacy", (c) => <Privacy w={w} onOpenPerson={c.onOpenPerson} onNotice={c.onNotice} />, "recordings export delete policy"),
      page("audit", "Audit history", () => only(manage, <SecurityLogPage workspace={w} refreshKey={0} />), "changes log"),
      page("data", "Data management", () => <DataExport w={w} />, "export retention deletion"),
    ] },
    { key: "reports", label: "Reports and preferences", icon: "monitoring", items: [
      page("dashboard", "Dashboard preferences", lazyNeeds("Dashboard preferences aren't saved yet", "Today opens first; each report remembers its period while you're on it.", "Saving them needs a per-person preferences record.")),
      page("reporting", "Reporting preferences", lazyNeeds("Scheduled reports aren't available yet", "Owners get the daily summary and weekly review (Notifications).", "Custom recipients and schedules need a report schedule table.")),
      page("performance", "Business performance", () => <ReportsPage workspace={w} refreshKey={0} />, "calls leads appointments"),
      page("export", "Data export", () => <DataExport w={w} />, "csv"),
    ] },
    { key: "help", label: "Help and support", icon: "help", items: [
      page("center", "Help center", () => <HelpCenter />, "docs guides"),
      page("tickets", "Support requests", () => <SupportTickets w={w} />, "ticket"),
      page("status", "System status", () => <SystemStatus w={w} />, "status"),
      page("feedback", "Feedback", () => <SupportTickets w={w} kind="feedback" />, "feature issue"),
    ] },
    { key: "me", label: "Personal profile", icon: "person", items: [
      page("profile", "My profile", (c) => <MyProfilePanel email={c.email} />, "name picture"),
      page("security", "Personal security", (c) => <AccountSecurityPanel email={c.email} />, "password mfa"),
      page("preferences", "Personal preferences", () => <NotificationPrefs w={w} />, "notifications"),
      page("logout", "Sign out", (c) => <SignOutPanel who="you" onSignOut={c.onSignOut} />, "logout"),
    ] },
  ];
}

function Templates({ w }) {
  const state = useAsync(() => supabase.from("message_templates").select("id, business_id, key, channel, purpose, subject, body, version, status").order("key").then(orThrow), [w.id]);
  const [open, setOpen] = useState(null);
  return (
    <>
      <LoadState state={state}>{(rows) => (
        <Card title="Templates" sub="Your own versions first, then Zella's starting templates.">
          <Table rows={rows} empty="No templates." columns={[["Message", (t) => words(t.key)], ["Channel", (t) => words(t.channel)], ["Source", (t) => (t.business_id ? "Yours" : "Zella")],
            ["Status", (t) => words(t.status)], ["", (t) => <button type="button" className="zs-btn sm" onClick={() => setOpen(open === t.id ? null : t.id)}>{open === t.id ? "Hide" : "Preview"}</button>]]} />
          {open && (() => { const t = rows.find((x) => x.id === open); return <div className="zs-card" style={{ padding: 12, marginTop: 10 }}>{t.subject && <strong>{t.subject}</strong>}<p style={{ whiteSpace: "pre-wrap" }}>{t.body}</p></div>; })()}
        </Card>
      )}</LoadState>
      <BillingNeeds title="Editing templates here isn't available yet" have="Suggested messages (in the sidebar) can be reviewed before they send.">Editing needs a save step that checks each variable against what the message type supports.</BillingNeeds>
    </>
  );
}

export function BusinessSettingsPage({ workspace, email, userId, records, onSignOut, section, sub, onGo, onReload, onOpenPerson, onNotice }) {
  const reg = registry(workspace);
  return (
    <SettingsWorkspace
      description={`${workspace.name} · ${words(workspace.role)}`}
      registry={reg} category={section} item={sub} base={window.location.pathname.startsWith("/app/preview") ? "/app/preview/settings" : "/app/settings"}
      go={(path) => onGo(path.replace(/^\/app(\/preview)?\//, ""))}
      Icon={({ name }) => <Icon name={name} size="sm" />}
      context={{ email, userId, records, onSignOut, onGo, onReload, onOpenPerson, onNotice }} />
  );
}
