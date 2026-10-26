import { useCallback, useEffect, useState } from "react";
import "./OwnerPages.css";
import { supabase } from "./supabase";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { formatDateTime } from "./ownerFormat";
import { navigate } from "./router";

// Admin Settings. Categories live in this page's own menu (the main sidebar keeps
// one Settings item); the address is /settings/<category>. Every value comes from
// the owner-provision-business function, which checks the admin role first.

const ROLE_LABELS = { zella_owner: "Zella owner", super_admin: "Super admin" };

const SECTIONS = [
  ["account", "Profile & account"],
  ["platform", "Platform configuration"],
  ["preferences", "Operational preferences"],
  ["security", "Security & access"],
  ["businesses", "Business management"],
  ["notifications", "Notifications"],
  ["integrations", "Integrations"],
  ["billing", "Subscriptions & billing"],
  ["audit", "Audit logs"],
];

function Row({ title, detail, action }) {
  return (
    <li>
      <div>
        <strong>{title}</strong>
        <span>{detail}</span>
      </div>
      {action}
    </li>
  );
}

function Card({ title, sub, children }) {
  return (
    <section className="owner-panel op-card">
      <div className="owner-panel-heading"><div><h2>{title}</h2>{sub && <p>{sub}</p>}</div></div>
      {children}
    </section>
  );
}

function AccountSection({ data, loading }) {
  const [sent, setSent] = useState("");
  const [busy, setBusy] = useState(false);
  async function reset() {
    setBusy(true);
    const { error } = await supabase.auth.resetPasswordForEmail(data.me.email, { redirectTo: `${window.location.origin}/welcome` });
    setBusy(false);
    setSent(error ? `Couldn't send the link: ${error.message}` : `A link to choose a new password is on its way to ${data.me.email}.`);
  }
  return (
    <Card title="Your account">
      <ul className="op-list">
        <Row title="Email" detail={loading && !data ? "Loading..." : data?.me?.email ?? "—"} />
        <Row title="Role" detail={ROLE_LABELS[data?.me?.role] ?? data?.me?.role ?? "—"} />
        <Row title="Last sign-in" detail={formatDateTime(data?.me?.lastSignInAt)} />
        <Row title="Password" detail={sent || "Change it with a link sent to your email."}
          action={data?.me?.email && !sent && <button type="button" className="owner-secondary-button op-small" onClick={reset} disabled={busy}>{busy ? "Sending..." : "Send link"}</button>} />
      </ul>
    </Card>
  );
}

function PlatformSection({ data }) {
  return (
    <Card title="Server configuration" sub={<>Set with <code>supabase secrets set NAME=value</code>. Values are never shown here.</>}>
      <ul className="op-list">
        {(data?.configuration ?? []).map((c) => (
          <Row key={c.key} title={c.label} detail={c.key}
            action={<Pill tone={c.set ? "success" : c.required ? "danger" : "neutral"}>{c.set ? "Configured" : "Not set"}</Pill>} />
        ))}
        {data?.appUrl && <Row title="Invitation links open" detail={data.appUrl} />}
      </ul>
    </Card>
  );
}

function SettingValue({ row, onSaved }) {
  const shown = typeof row.value === "string" ? row.value : JSON.stringify(row.value);
  const [value, setValue] = useState(shown);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  async function save() {
    setBusy(true);
    setError("");
    try {
      await callOwnerFunction("platform_setting_save", { key: row.key, value });
      onSaved(`${row.label} saved.`);
    } catch (err) {
      setError(err.message);
    } finally {
      setBusy(false);
    }
  }
  return (
    <li>
      <div>
        <strong>{row.label}</strong>
        <span>{row.key} · changed {formatDateTime(row.updated_at)}</span>
        {error && <span className="op-error" role="alert">{error}</span>}
      </div>
      <div className="op-inline">
        <input className="owner-input" aria-label={row.label} value={value} onChange={(e) => setValue(e.target.value)} disabled={busy} />
        <button type="button" className="owner-secondary-button op-small" onClick={save} disabled={busy || value === shown}>{busy ? "Saving..." : "Save"}</button>
      </div>
    </li>
  );
}

function PreferencesSection() {
  const [state, setState] = useState({ data: null, error: "", notice: "" });
  const load = useCallback(async (notice = "") => {
    try {
      setState({ data: await callOwnerFunction("platform_settings_list"), error: "", notice });
    } catch (err) {
      setState((s) => ({ ...s, error: err.message }));
    }
  }, []);
  useEffect(() => { load(); }, [load]);
  const rows = state.data?.settings ?? [];
  const editable = rows.filter((r) => r.label);
  const live = rows.filter((r) => r.live);
  return (
    <>
      {state.error && <div className="owner-form-error op-gap">Could not load platform settings: {state.error}</div>}
      {state.notice && <div className="owner-form-success op-gap" role="status">{state.notice}</div>}
      <Card title="Operational preferences" sub={state.data?.canEdit ? "Applies to every business. Each change is recorded in the audit log." : "Only a Zella owner can change these."}>
        <ul className="op-list">
          {!state.data && !state.error && <Row title="Loading..." detail="" />}
          {editable.map((r) => r.editable
            ? <SettingValue key={`${r.key}:${r.updated_at}`} row={r} onSaved={(m) => load(m)} />
            : <Row key={r.key} title={r.label} detail={`${typeof r.value === "string" ? r.value || "—" : JSON.stringify(r.value)} · ${r.key}`} />)}
        </ul>
      </Card>
      <Card title="Live switches" sub="Real texts, emails and calls start only when these are on. They are switched on at go-live, in the order in n8n/GO-LIVE.md, not from here.">
        <ul className="op-list">
          {live.map((r) => <Row key={r.key} title={r.key} detail={`Changed ${formatDateTime(r.updated_at)}`} action={<Pill tone={r.value === true ? "success" : "neutral"}>{r.value === true ? "On" : "Off"}</Pill>} />)}
          {state.data && !live.length && <Row title="No live switches found" detail="Run the automation SQL files to create them." />}
        </ul>
      </Card>
    </>
  );
}

function LinksSection({ title, sub, rows, onNavigate }) {
  return (
    <Card title={title} sub={sub}>
      <ul className="op-list">
        {rows.map(([page, text, detail, label = "Open"]) => (
          <Row key={page + text} title={text} detail={detail}
            action={<button type="button" className="owner-secondary-button op-small" onClick={() => onNavigate(page)}>{label}</button>} />
        ))}
      </ul>
    </Card>
  );
}

function SecuritySection({ data, onNavigate }) {
  const origins = data?.configuration?.find((c) => c.key === "ZELLA_ALLOWED_ORIGINS");
  return (
    <>
      <LinksSection title="Security & access" onNavigate={onNavigate} rows={[
        ["Users & Access", "Platform admins", "Who can use this dashboard and their roles.", "Manage"],
        ["Audit Logs", "Audit log", "Every admin action is recorded automatically and kept.", "View"],
      ]} />
      <Card title="Checks" sub="Some sign-in settings live in the Supabase dashboard and can't be read from here.">
        <ul className="op-list">
          <Row title="Allowed websites" detail="Which sites may call the browser-facing functions."
            action={<Pill tone={origins?.set ? "success" : "warning"}>{origins?.set ? "Restricted" : "Any site (set at go-live)"}</Pill>} />
          <Row title="Public sign-up and email confirmation" detail="Supabase > Authentication > Sign In / Providers. Zella onboards businesses by invitation, so check sign-ups are off or emails are confirmed." />
          <Row title="Tenant isolation check" detail="Runs daily (zella_tenant_leak_check) and raises a platform alert if any business data is open." />
        </ul>
      </Card>
    </>
  );
}

export default function SettingsPage({ onNavigate, section }) {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const current = SECTIONS.find(([key]) => key === section)?.[0] ?? "account";

  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      setData(await callOwnerFunction("platform_status"));
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const health = data?.health;

  return (
    <section className="owner-page">
      <div className="owner-page-heading">
        <div>
          <div className="owner-eyebrow">SETTINGS</div>
          <h1>Settings</h1>
          <p>Your account and how the Zella platform is configured.</p>
        </div>
      </div>

      {error && <div className="owner-form-error op-gap">Could not load settings: {error}</div>}
      {section && !SECTIONS.some(([key]) => key === section) && <div className="owner-form-error op-gap">That settings page doesn't exist, so here is your account.</div>}

      <div className="op-settings">
        <nav className="op-settings-nav" aria-label="Settings categories">
          {SECTIONS.map(([key, label]) => (
            <button key={key} type="button" className={`owner-nav-item ${current === key ? "active" : ""}`}
              aria-current={current === key ? "page" : undefined} onClick={() => navigate(`/settings/${key}`)}>
              <span>{label}</span>
            </button>
          ))}
        </nav>
        <div className="op-settings-body">
          {current === "account" && <AccountSection data={data} loading={loading} />}
          {current === "platform" && <PlatformSection data={data} />}
          {current === "preferences" && <PreferencesSection />}
          {current === "security" && <SecuritySection data={data} onNavigate={onNavigate} />}
          {current === "businesses" && <LinksSection title="Business management" onNavigate={onNavigate} rows={[
            ["Businesses", "Businesses", health ? `${health.businesses} businesses · ${health.failedSetups} failed setups · ${health.failedInvites} failed invitations` : "All client workspaces."],
            ["Industry Configuration", "Industries & terminology", "Default CRM words, receptionist wording and modules per industry."],
            ["Modules & Features", "Modules", "Which modules exist and how widely they're used."],
            ["AI Agents", "AI agents", "Every business's receptionist and its status."],
          ]} />}
          {current === "notifications" && <LinksSection title="Notifications"
            sub="Platform alerts (failed jobs, provider problems, offers) are emailed to every active admin once email sending is live and a sender address is set under Operational preferences."
            onNavigate={onNavigate} rows={[
              ["Platform Operations", "Platform alerts and health", health ? `${health.urgentTickets} urgent tickets · ${health.brokenIntegrations} broken integrations` : "Open alerts, failed events and incidents.", "Check"],
              ["Support", "Support tickets", "Requests from businesses."],
            ]} />}
          {current === "integrations" && <LinksSection title="Integrations" onNavigate={onNavigate} rows={[
            ["Integrations", "Integrations across businesses", health ? `${health.brokenIntegrations} need attention` : "Connection status for every business."],
          ]} />}
          {current === "billing" && <LinksSection title="Subscriptions & billing" sub="Payment events arrive through the billing webhook once STRIPE_WEBHOOK_SECRET is set." onNavigate={onNavigate} rows={[
            ["Plans & Subscriptions", "Plans", "Plan names, availability and each business's subscription."],
            ["Offers & Promotions", "Offers", "Discounts and promotions."],
          ]} />}
          {current === "audit" && <LinksSection title="Audit logs" onNavigate={onNavigate} rows={[
            ["Audit Logs", "Audit log", health ? `${health.auditLast24h} entries in the last 24 hours` : "Every admin action.", "View"],
          ]} />}
        </div>
      </div>
    </section>
  );
}
