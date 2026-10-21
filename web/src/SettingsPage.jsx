import { useCallback, useEffect, useState } from "react";
import "./OwnerPages.css";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { formatDateTime } from "./ownerFormat";

const ROLE_LABELS = { zella_owner: "Zella owner", super_admin: "Super admin" };

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

export default function SettingsPage({ onNavigate }) {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

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

  const go = (page, text) => (
    <button type="button" className="owner-secondary-button op-small" onClick={() => onNavigate(page)}>{text}</button>
  );

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

      <div className="op-grid">
        <section className="owner-panel op-card">
          <div className="owner-panel-heading"><div><h2>Your account</h2></div></div>
          <ul className="op-list">
            <Row title="Email" detail={loading && !data ? "Loading..." : data?.me?.email ?? "—"} />
            <Row title="Role" detail={ROLE_LABELS[data?.me?.role] ?? data?.me?.role ?? "—"} />
            <Row title="Last sign-in" detail={formatDateTime(data?.me?.lastSignInAt)} />
          </ul>
        </section>

        <section className="owner-panel op-card">
          <div className="owner-panel-heading">
            <div>
              <h2>Server configuration</h2>
              <p>Set with <code>supabase secrets set NAME=value</code>. Values are never shown here.</p>
            </div>
          </div>
          <ul className="op-list">
            {(data?.configuration ?? []).map((c) => (
              <Row
                key={c.key}
                title={c.label}
                detail={c.key}
                action={<Pill tone={c.set ? "success" : c.required ? "danger" : "neutral"}>{c.set ? "Configured" : "Not set"}</Pill>}
              />
            ))}
            {data?.appUrl && <Row title="Invitation links open" detail={data.appUrl} />}
          </ul>
        </section>
      </div>

      <section className="owner-panel op-card">
        <div className="owner-panel-heading"><div><h2>Platform settings</h2><p>Where each part of Zella is configured.</p></div></div>
        <ul className="op-list">
          <Row title="Platform admins" detail="Who can use this dashboard and their roles." action={go("Users & Access", "Manage")} />
          <Row title="Industries & terminology" detail="Default CRM words, receptionist wording and modules per industry." action={go("Industry Configuration", "Open")} />
          <Row title="Modules" detail="Which modules exist and how widely they're used." action={go("Modules & Features", "Open")} />
          <Row title="Plans" detail="Plan names and availability. Pricing is not configured yet." action={go("Plans & Subscriptions", "Open")} />
          <Row title="Audit log" detail="Every admin action is recorded automatically and kept." action={go("Audit Logs", "View")} />
          <Row title="System health" detail="Failed setups, invitations, integrations and urgent tickets." action={go("Platform Operations", "Check")} />
        </ul>
      </section>
    </section>
  );
}
