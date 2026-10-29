import { useCallback, useMemo, useState } from "react";
import { navigate } from "../router";
import { EmailConfig, SmsConfig } from "../settings/AdminPanels";
import {
  AlertList, DataTable, Drawer, ErrorNote, Facts, Filters, Metric, NotAvailable, PAGE, PageHeader, Pager, Panel, PERIODS, Pill,
  ProviderHealth, ReasonDialog, Search, Select, Tabs, can, num, pct, rpc, since, useLoad, useOptions, useToast, when, words,
} from "./adminOps";

// Admin page: every text and email Zella recorded, the platform templates and the senders. Data comes from the
// zella_admin_* functions (sql/zella_admin_ops.sql). Previewing a template fills in sample values in the browser;
// nothing on this page sends a message. A retry puts the original reminder or follow-up back in the queue, and the
// sender checks consent, opt-outs and quiet hours again before anything goes out.

const TABS = [["overview", "Overview"], ["sms", "Texts"], ["email", "Emails"], ["templates", "Templates"], ["providers", "Senders & providers"], ["compliance", "Consent & opt-outs"]];
const STATUSES = ["queued", "sent", "delivered", "failed", "received", "dry_run", "blocked"];
const STATUS_LABEL = { dry_run: "Test mode (not sent)", sent: "Accepted by provider", received: "Received" };
const KINDS = { sms: [["reminder", "Reminder"], ["follow_up", "Follow-up"], ["staff_alert", "Staff alert"], ["inbound", "Inbound"], ["other", "Other"]],
  email: [["reminder", "Reminder"], ["follow_up", "Follow-up"], ["owner_email", "Owner email"], ["inbound", "Inbound"], ["other", "Other"]] };
const tone = (s) => (s === "delivered" ? "success" : s === "failed" ? "danger" : s === "blocked" ? "warning" : s === "sent" ? "info" : "neutral");
const statusPill = (s) => <Pill tone={tone(s)}>{STATUS_LABEL[s] ?? words(s)}</Pill>;

export default function MessagingPage({ me, sub, onOpenBusiness }) {
  const tab = TABS.some(([k]) => k === sub) ? sub : "overview";
  const setTab = (k) => navigate(k === "overview" ? "/messaging" : `/messaging/${k}`);
  const [toast, say] = useToast();
  const options = useOptions();
  const [failedFilter, setFailedFilter] = useState(false);
  const openFailed = (channel) => { setFailedFilter(true); setTab(channel); };
  return (
    <section className="owner-page ao-page">
      <PageHeader title="Messaging" description="Texts and emails across every business: what was sent, what failed, the templates they use and the senders." />
      <Tabs tabs={TABS} current={tab} onChange={(k) => { setFailedFilter(false); setTab(k); }} />
      {tab === "overview" && <Overview onTab={setTab} onFailed={openFailed} />}
      {(tab === "sms" || tab === "email") && <Messages key={`${tab}-${failedFilter}`} channel={tab} me={me} options={options.data} failedOnly={failedFilter} say={say} onOpenBusiness={onOpenBusiness} />}
      {tab === "templates" && <Templates options={options.data} say={say} />}
      {tab === "providers" && <Providers me={me} />}
      {tab === "compliance" && <Compliance />}
      {toast}
    </section>
  );
}

function Overview({ onTab, onFailed }) {
  const [days, setDays] = useState(30);
  const data = useLoad(() => rpc("zella_admin_messaging_overview", { p_from: since(days), p_to: null }), [days]);
  const alerts = useLoad(() => rpc("zella_admin_messaging_alerts"), []);
  const o = data.data;
  const open = (a) => (a.link === "scheduler" ? navigate("/automations/infrastructure") : onTab(a.link));
  return (
    <>
      <Filters>
        <Select label="Period" value={String(days)} any={null} onChange={(v) => setDays(Number(v))} options={PERIODS.map(([d, l]) => [String(d), l])} />
        <button type="button" className="owner-secondary-button" onClick={() => { data.reload(); alerts.reload(); }}>Refresh</button>
      </Filters>
      <ErrorNote error={data.error} onRetry={data.reload} />
      {o && (
        <>
          {(!o.live.sms || !o.live.email) && (
            <NotAvailable title="Sending is in test mode">
              {[!o.live.sms && "Texts (sms_live is off)", !o.live.email && "Emails (email_live is off)"].filter(Boolean).join(" and ")}: Zella records each message as "Test mode (not sent)" and nothing reaches customers.
            </NotAvailable>
          )}
          <h3 className="ao-h3">Texts</h3>
          <div className="owner-stat-grid ao-stats">
            <Metric label="Sent" value={num(o.sms.outbound)} note={`${num(o.sms.inbound)} received`} />
            <Metric label="Delivered" value={num(o.sms.delivered)} note={`Delivery rate ${pct(o.sms_delivery_rate)}`} />
            <Metric label="Failed" value={num(o.sms.failed)} tone={o.sms.failed ? "danger" : null} />
            <Metric label="Waiting" value={num(o.sms.queued)} />
            <Metric label="Blocked (consent or spam)" value={num(o.sms.blocked)} />
            <Metric label="Test mode" value={num(o.sms.test_mode)} />
          </div>
          <h3 className="ao-h3">Emails</h3>
          <div className="owner-stat-grid ao-stats">
            <Metric label="Sent" value={num(o.email.outbound)} note={`${num(o.email.inbound)} received`} />
            <Metric label="Accepted by provider" value={num(o.email.accepted)} />
            <Metric label="Delivered" value={num(o.email.delivered)} />
            <Metric label="Failed" value={num(o.email.failed)} tone={o.email.failed ? "danger" : null} />
            <Metric label="Bounced" value={num((o.email_events["email.bounced"] ?? 0) + (o.email_events.bounced ?? 0))} />
            <Metric label="Spam complaints" value={num((o.email_events["email.complained"] ?? 0) + (o.email_events.complained ?? 0))} />
          </div>
          <h3 className="ao-h3">Waiting to send</h3>
          <div className="owner-stat-grid ao-stats">
            <Metric label="Reminders due now" value={num(o.waiting.reminders_due)} tone={o.waiting.reminders_due ? "warning" : null} />
            <Metric label="Follow-ups due now" value={num(o.waiting.followups_due)} tone={o.waiting.followups_due ? "warning" : null} />
            <Metric label="Reminders failed (7 days)" value={num(o.waiting.reminders_failed_7d)} tone={o.waiting.reminders_failed_7d ? "danger" : null} />
            <Metric label="Follow-ups failed (7 days)" value={num(o.waiting.followups_failed_7d)} tone={o.waiting.followups_failed_7d ? "danger" : null} />
          </div>
          {(o.sms.failed > 0 || o.email.failed > 0) && (
            <div className="ao-drawer-actions">
              {o.sms.failed > 0 && <button type="button" className="owner-secondary-button" onClick={() => onFailed("sms")}>See failed texts</button>}
              {o.email.failed > 0 && <button type="button" className="owner-secondary-button" onClick={() => onFailed("email")}>See failed emails</button>}
            </div>
          )}
        </>
      )}
      <div className="ao-two">
        <Panel title="Needs attention"><ErrorNote error={alerts.error} onRetry={alerts.reload} /><AlertList alerts={alerts.data} onOpen={open} /></Panel>
        <Panel title="Providers" action={<button type="button" className="owner-secondary-button" onClick={() => onTab("providers")}>Details</button>}>
          {o && <ProviderHealth rows={o.providers} checksLive={o.checks_live} names={[["telnyx", "Telnyx", "Texts"], ["resend", "Resend", "Emails"]]} />}
        </Panel>
      </div>
    </>
  );
}

function Messages({ channel, me, options, failedOnly, say, onOpenBusiness }) {
  const [f, setF] = useState({ days: 30, business: null, status: failedOnly ? "failed" : null, direction: null, kind: null, q: "", offset: 0 });
  const set = (k) => (v) => setF((x) => ({ ...x, [k]: v, offset: 0 }));
  const setQ = useCallback((v) => setF((x) => ({ ...x, q: v, offset: 0 })), []);
  const list = useLoad(() => rpc("zella_admin_messages", {
    p_channel: channel, p_from: since(f.days), p_to: null, p_business: f.business, p_status: f.status, p_direction: f.direction, p_kind: f.kind,
    p_q: f.q || null, p_limit: PAGE, p_offset: f.offset,
  }), [channel, f]);
  const [open, setOpen] = useState(null);
  const email = channel === "email";
  return (
    <Panel>
      <Filters>
        <Search label={email ? "Email address, subject or provider id" : "Phone number or provider id"} value={f.q} onChange={setQ} placeholder={email ? "Full address" : "At least 4 digits"} />
        <Select label="Period" value={String(f.days)} any={null} onChange={(v) => set("days")(Number(v))} options={PERIODS.map(([d, l]) => [String(d), l])} />
        <Select label="Business" value={f.business} onChange={set("business")} options={(options?.businesses ?? []).map((b) => [b.id, b.name])} />
        <Select label="Status" value={f.status} onChange={set("status")} options={STATUSES.map((s) => [s, STATUS_LABEL[s] ?? words(s)])} />
        <Select label="Direction" value={f.direction} onChange={set("direction")} options={[["outbound", "Sent"], ["inbound", "Received"]]} />
        <Select label="Type" value={f.kind} onChange={set("kind")} options={KINDS[channel]} />
      </Filters>
      <ErrorNote error={list.error} onRetry={list.reload} />
      <DataTable loading={list.loading} rows={list.data?.rows} onRow={(r) => setOpen(r.id)}
        empty={`No ${email ? "emails" : "texts"} in this period match these filters.`}
        columns={[
          ["When", (r) => when(r.created_at)], ["Business", (r) => r.business_name], ["Type", (r) => words(r.kind)],
          [email ? "Address" : "Phone", (r) => (r.direction === "inbound" ? r.from : r.to) ?? "—"],
          ...(email ? [["Subject", (r) => r.subject ?? "—"]] : []),
          ["Status", (r) => statusPill(r.status)], ...(email ? [["Last event", (r) => (r.last_event ? words(r.last_event.replace("email.", "")) : "—")]] : []),
          ["Error", (r) => r.error ?? "—"],
        ]} />
      <Pager total={list.data?.total} offset={f.offset} onChange={(o) => setF((x) => ({ ...x, offset: o }))} />
      {open && <MessageDrawer channel={channel} id={open} me={me} onClose={() => setOpen(null)} onOpenBusiness={onOpenBusiness}
        onRetried={() => { say("Put back in the queue. It is sent on the next run, after consent and quiet hours are checked again."); list.reload(); }} />}
    </Panel>
  );
}

function MessageDrawer({ channel, id, me, onClose, onOpenBusiness, onRetried }) {
  const [withContent, setWithContent] = useState(false);
  const [retry, setRetry] = useState(false);
  const d = useLoad(() => rpc("zella_admin_message_detail", { p_channel: channel, p_id: id, p_with_content: withContent }), [channel, id, withContent]);
  const m = d.data?.message;
  const manage = can(me, "comms.manage");
  return (
    <Drawer title={channel === "email" ? "Email details" : "Text details"} icon={channel === "email" ? "mail" : "sms"} onClose={onClose}>
      <ErrorNote error={d.error} onRetry={d.reload} />
      {!m ? <p className="op-muted">Loading…</p> : (
        <>
          <Facts rows={[["Business", <button key="b" type="button" className="ao-link" onClick={() => onOpenBusiness(m.business_id)}>{m.business_name}</button>],
            ["Direction", m.direction === "inbound" ? "Received" : "Sent"], ["To", m.to], ["From", m.from], m.subject ? ["Subject", m.subject] : null,
            ["Status", statusPill(m.status)], ["Provider id", m.provider_id ? <code key="p">{m.provider_id}</code> : null],
            m.meta?.error || m.meta?.failure_reason ? ["Error", m.meta.error ?? m.meta.failure_reason] : null,
            m.meta?.reminder_id ? ["Sent for", "Appointment reminder"] : m.meta?.task_id ? ["Sent for", "Follow-up"] : null]} />
          <h3 className="ao-h3">Timeline</h3>
          <ol className="ao-timeline">
            {[["Recorded", m.created_at], ["Accepted by provider", m.sent_at], ["Delivered", m.delivered_at]].filter(([, t]) => t).map(([l, t]) => <li key={l}><strong>{l}</strong><span>{when(t)}</span></li>)}
            {(d.data.events ?? []).map((e, i) => <li key={i}><strong>{words(e.type.replace("email.", ""))}</strong><span>{when(e.at)}</span></li>)}
            {m.updated_at && m.updated_at !== m.created_at && <li><strong>Last change</strong><span>{when(m.updated_at)}</span></li>}
          </ol>
          <h3 className="ao-h3">Message</h3>
          {!d.data.content_allowed ? <p className="op-muted">Your admin role can't open message content.</p>
            : !d.data.content ? <button type="button" className="owner-secondary-button" onClick={() => setWithContent(true)}>Show the message (this is recorded in the audit log)</button>
            : <pre className="ao-pre">{d.data.content.body ?? "(empty)"}</pre>}
          <h3 className="ao-h3">Retry</h3>
          {d.data.retry?.ok
            ? manage ? <button type="button" className="owner-primary-button" onClick={() => setRetry(true)}>Retry</button> : <p className="op-muted">It can be retried by an admin who manages communications.</p>
            : <p className="op-muted">Can't retry: {d.data.retry?.why}</p>}
        </>
      )}
      {retry && (
        <ReasonDialog title="Retry this message?" icon="replay" confirmLabel="Put back in the queue" onClose={() => setRetry(false)}
          onConfirm={async (reason) => { await rpc("zella_admin_message_retry", { p_channel: channel, p_id: id, p_reason: reason }); d.reload(); onRetried(); }}>
          <p>Its {d.data.retry.source === "reminder" ? "appointment reminder" : "follow-up"} goes back in the queue (tried {d.data.retry.attempts ?? 0} times so far). The sender checks consent, opt-outs and quiet hours again. The same message can't be sent twice.</p>
        </ReasonDialog>
      )}
    </Drawer>
  );
}

const SAMPLE = { first_name: "Alex", business: "Sample Business", time: "Tue 3:00 PM", date: "Tuesday, March 4", service: "Consultation", link: "https://example.com/link",
  staff: "Sam", phone: "+1 555 010 0000", address: "1 Sample Street", amount: "$40.00", minutes: "15" };
const fill = (text, vars) => String(text ?? "").replace(/\{\{\s*([\w.]+)\s*\}\}/g, (all, k) => (k in vars ? vars[k] : `[${k}]`));

function Templates({ options, say }) {
  const [f, setF] = useState({ q: "", channel: null, scope: "platform", offset: 0 });
  const set = (k) => (v) => setF((x) => ({ ...x, [k]: v, offset: 0 }));
  const setQ = useCallback((v) => setF((x) => ({ ...x, q: v, offset: 0 })), []);
  const list = useLoad(() => rpc("zella_admin_templates", { p_q: f.q || null, p_channel: f.channel, p_scope: f.scope, p_limit: PAGE, p_offset: f.offset }), [f]);
  const [open, setOpen] = useState(null);
  return (
    <Panel description="Platform templates are what every business starts with; industry versions override them for that industry. A business's own copy is changed by that business.">
      <Filters>
        <Search value={f.q} onChange={setQ} placeholder="Key or wording" />
        <Select label="Channel" value={f.channel} onChange={set("channel")} options={[["sms", "Text"], ["email", "Email"]]} />
        <Select label="Whose" value={f.scope} any={null} onChange={set("scope")} options={[["platform", "Platform and industry"], ["business", "Business copies"], ["all", "All"]]} />
      </Filters>
      <ErrorNote error={list.error} onRetry={list.reload} />
      <DataTable loading={list.loading} rows={list.data?.rows} onRow={setOpen} empty="No templates match."
        columns={[
          ["Key", (t) => <code>{t.key}</code>], ["Channel", (t) => (t.channel === "sms" ? "Text" : "Email")], ["Purpose", (t) => words(t.purpose)],
          ["For", (t) => (t.scope === "business" ? t.business_name : t.scope === "industry" ? t.industry_name : "All businesses")],
          ["Version", (t) => t.version], ["Business copies", (t) => (t.scope === "business" ? "—" : num(t.business_copies))], ["Updated", (t) => when(t.created_at)],
        ]} />
      <Pager total={list.data?.total} offset={f.offset} onChange={(o) => setF((x) => ({ ...x, offset: o }))} />
      {open && <TemplateDrawer t={open} canEdit={list.data?.can_edit} options={options} onClose={() => setOpen(null)}
        onSaved={() => { say("Saved as a new version. Messages use it from now on; earlier messages are unchanged."); setOpen(null); list.reload(); }} />}
    </Panel>
  );
}

function TemplateDrawer({ t, canEdit, onClose, onSaved }) {
  const [subject, setSubject] = useState(t.subject ?? "");
  const [body, setBody] = useState(t.body);
  const [confirm, setConfirm] = useState(false);
  const editable = canEdit && t.scope !== "business";
  const used = useMemo(() => [...new Set([...(body + " " + subject).matchAll(/\{\{\s*([^}]*?)\s*\}\}/g)].map((m) => m[1]))], [body, subject]);
  const unknown = used.filter((v) => !t.variables.includes(v));
  const changed = body.trim() !== t.body || (t.channel === "email" && subject.trim() !== (t.subject ?? ""));
  const segments = t.channel === "sms" ? Math.max(1, Math.ceil(fill(body, SAMPLE).length / 160)) : null;
  const insert = (v) => setBody((b) => `${b}{{${v}}}`);
  return (
    <Drawer title={t.key} icon="description" onClose={onClose}>
      <Facts rows={[["Channel", t.channel === "sms" ? "Text" : "Email"], ["Purpose", words(t.purpose)], ["Language", t.locale],
        ["For", t.scope === "business" ? t.business_name : t.scope === "industry" ? `${t.industry_name} businesses` : "All businesses"], ["Version", t.version],
        t.scope !== "business" ? ["Businesses with their own copy", `${t.business_copies} (not changed by saving here)`] : null]} />
      {t.channel === "email" && <label className="owner-field"><span>Subject</span><input value={subject} disabled={!editable} onChange={(e) => setSubject(e.target.value)} /></label>}
      <label className="owner-field"><span>Message</span><textarea rows={7} value={body} disabled={!editable} maxLength={1600} onChange={(e) => setBody(e.target.value)} /></label>
      <div className="ao-chips">
        <span className="op-muted">Variables:</span>
        {t.variables.map((v) => <button key={v} type="button" className="ao-chip" disabled={!editable} onClick={() => insert(v)}>{`{{${v}}}`}</button>)}
      </div>
      {unknown.length > 0 && <div className="owner-form-error">Not available for this message: {unknown.join(", ")}</div>}
      <h3 className="ao-h3">Preview with sample values</h3>
      <div className="ao-preview">
        {t.channel === "email" && <strong>{fill(subject, SAMPLE)}</strong>}
        <pre className="ao-pre">{fill(body, SAMPLE)}</pre>
        <small className="op-muted">{body.length} characters{segments ? ` · about ${segments} text segment${segments === 1 ? "" : "s"}` : ""}. Preview only — nothing is sent.</small>
      </div>
      {editable ? (
        <div className="ao-drawer-actions">
          <button type="button" className="owner-secondary-button" disabled={!changed} onClick={() => { setBody(t.body); setSubject(t.subject ?? ""); }}>Undo changes</button>
          <button type="button" className="owner-primary-button" disabled={!changed || unknown.length > 0} onClick={() => setConfirm(true)}>Save as new version</button>
        </div>
      ) : <p className="op-muted">{t.scope === "business" ? "This is the business's own copy; they change it in their app." : "Your admin role can see templates but not change them."}</p>}
      {confirm && (
        <ReasonDialog title={`Save ${t.key}?`} icon="save" confirmLabel="Save" onClose={() => setConfirm(false)}
          onConfirm={async (reason) => { await rpc("zella_admin_template_save", { p_id: t.id, p_subject: subject, p_body: body, p_reason: reason }); onSaved(); }}>
          <p>Version {t.version} is archived and version {t.version + 1} is used from now on{t.scope === "industry" ? ` for ${t.industry_name} businesses` : " for every business without its own copy"}.</p>
        </ReasonDialog>
      )}
    </Drawer>
  );
}

function Providers({ me }) {
  const data = useLoad(() => rpc("zella_admin_messaging_overview", { p_from: since(1), p_to: null }), []);
  const o = data.data;
  return (
    <>
      <Panel title="Sending switches">
        <ErrorNote error={data.error} onRetry={data.reload} />
        {o && <Facts rows={[["Texts", o.live.sms ? <Pill key="s" tone="success">Live</Pill> : <Pill key="s" tone="warning">Test mode (sms_live off)</Pill>],
          ["Text sender number", o.live.sms_sender_set ? "Set" : "Not set"], ["Emails", o.live.email ? <Pill key="e" tone="success">Live</Pill> : <Pill key="e" tone="warning">Test mode (email_live off)</Pill>],
          ["Email sender address", o.live.email_sender_set ? "Set" : "Not set"], ["Marketing texts", o.live.marketing_texts ? "Allowed" : "Off (transactional only)"]]} />}
        <p className="op-muted">The live switches can't be changed from the app on purpose, so one click can't start messaging customers. They are set in the database (platform_settings) when the business is ready to go live.</p>
      </Panel>
      <Panel title="Connection checks">
        {o && <ProviderHealth rows={o.providers} checksLive={o.checks_live} names={[["telnyx", "Telnyx", "Texts"], ["resend", "Resend", "Emails"]]} />}
        {o && !o.checks_live && <NotAvailable title="Provider checks are off">Status is unknown rather than healthy. A "test connection" button isn't offered: it would need the provider keys in the browser, or a real send.</NotAvailable>}
      </Panel>
      <div className="zs ao-embed">
        <SmsConfig me={me} />
        <EmailConfig me={me} />
      </div>
    </>
  );
}

function Compliance() {
  const d = useLoad(() => rpc("zella_admin_messaging_compliance"), []);
  const c = d.data;
  return (
    <Panel title="Consent & opt-outs" description="Counts across every business. People who opt out (STOP, unsubscribe) aren't messaged again; the sender checks before every message.">
      <ErrorNote error={d.error} onRetry={d.reload} />
      {c && (
        <>
          <div className="owner-stat-grid ao-stats">
            <Metric label="Opted out of texts" value={num(c.opt_outs.sms ?? 0)} />
            <Metric label="Opted out of email" value={num(c.opt_outs.email ?? 0)} />
            <Metric label="Customers: do not email" value={num(c.suppressed_emails)} />
            <Metric label="Customers: do not contact" value={num(c.do_not_contact)} />
            <Metric label="Texts blocked (30 days)" value={num(c.blocked_30d.sms)} />
            <Metric label="Emails blocked (30 days)" value={num(c.blocked_30d.email)} />
            <Metric label="Spam blocks" value={num(c.spam_blocks)} />
          </div>
          <Facts rows={[["Consent records", Object.entries(c.consents).map(([k, v]) => `${words(k)}: ${v}`).join(", ") || "None yet"],
            ["Marketing texts", c.marketing_texts_allowed ? "Allowed (must include how to stop)" : "Off: only transactional texts (reminders, confirmations)"],
            ["STOP / START / HELP", "Handled automatically on inbound texts"]]} />
        </>
      )}
    </Panel>
  );
}
