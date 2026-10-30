import { useCallback, useEffect, useState } from "react";
import "./OwnerPages.css";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { actionLabel, stageLabel, stageTone, timeAgo, formatDate } from "./ownerFormat";
import { humanize } from "./copy/labels";
import { friendlyError } from "./admin/adminOps";

const ATTENTION_LABELS = {
  invitation_failed: "Invitation failed",
  invitation_expired: "Invitation expired",
  integration_error: "Integration problem",
  setup_failed: "Setup failed",
};

function Metric({ label, value, note }) {
  return (
    <div className="owner-stat-card">
      <div className="owner-stat-top"><span>{label}</span></div>
      <div className="owner-stat-value">{value}</div>
      {note && <div className="owner-stat-note">{note}</div>}
    </div>
  );
}

function Panel({ title, description, action, children }) {
  return (
    <section className="owner-panel">
      <div className="owner-panel-heading">
        <div>
          <h2>{title}</h2>
          {description && <p>{description}</p>}
        </div>
        {action}
      </div>
      {children}
    </section>
  );
}

export function Pill({ tone = "neutral", children }) {
  // Sentence case for plain status words ("past_due" -> "Past due"); anything else is shown as given.
  const text = typeof children === "string" ? humanize(children) : children;
  return <span className={`op-pill op-pill-${tone}`}>{text}</span>;
}

export default function OwnerOverview({ onCreateBusiness, onOpenBusiness, onContinueSetup, onNavigate }) {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      setData(await callOwnerFunction("overview_data"));
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const s = data?.stats;
  const show = (value) => (loading && !data ? "…" : value ?? 0);
  const maxFunnel = Math.max(1, ...(data?.funnel ?? []).map((f) => f.count));

  return (
    <section className="owner-page">
      <div className="owner-page-heading">
        <div>
          <div className="owner-eyebrow">Platform control center</div>
          <h1>Overview</h1>
          <p>Every client business on Zella, where its setup stands, and what needs attention.</p>
        </div>
        <div className="op-heading-actions">
          <button type="button" className="owner-secondary-button" onClick={load} disabled={loading}>
            {loading ? "Loading..." : "↻ Refresh"}
          </button>
          <button type="button" className="owner-primary-button" onClick={onCreateBusiness}>
            ＋ Create business
          </button>
        </div>
      </div>

      {error && (
        <div className="owner-form-error op-gap">
          Could not load the overview: {error}{" "}
          <button type="button" className="op-link" onClick={load}>Try again</button>
        </div>
      )}

      <div className="owner-stat-grid">
        <Metric label="Businesses" value={show(s?.totalBusinesses)} note={`${show(s?.live)} live`} />
        <Metric label="Setups in progress" value={show(s?.setupsInProgress)} note={`${show(s?.setupComplete)} setup complete`} />
        <Metric label="Owner invitations" value={show(s?.pendingInvitations)} note={`Pending · ${show(s?.acceptedInvitations)} accepted`} />
        <Metric label="AI receptionists live" value={show(s?.receptionistsLive)} note="Answering calls" />
      </div>

      <div className="owner-stat-grid">
        <Metric label="Calls (30 days)" value={show(s?.callsLast30Days)} note={`${show(s?.aiCallsLast30Days)} handled by AI`} />
        <Metric label="Open support tickets" value={show(s?.openTickets)} note="Open or in progress" />
        <Metric label="Needs attention" value={show(data?.attention?.length)} note="Failed invites, errors" />
        <Metric label="Suspended / canceling" value={loading && !data ? "…" : `${s?.suspended ?? 0} / ${s?.cancelling ?? 0}`} note={`${show(s?.cancelled)} canceled`} />
      </div>

      <div className="op-grid">
        <Panel
          title="Needs attention"
          description="Problems that block a client from going live."
        >
          {data?.attention?.length ? (
            <ul className="op-list">
              {data.attention.map((item, index) => (
                <li key={`${item.kind}-${item.businessId}-${index}`}>
                  <div>
                    <Pill tone="danger">{ATTENTION_LABELS[item.kind] ?? item.kind}</Pill>
                    <strong>{item.businessName}</strong>
                    <span>{item.detail}</span>
                  </div>
                  <button type="button" className="op-link" onClick={() => onOpenBusiness(item.businessId)}>
                    Open
                  </button>
                </li>
              ))}
            </ul>
          ) : (
            <div className="op-empty">{loading && !data ? "Loading..." : "Nothing needs attention right now."}</div>
          )}
        </Panel>

        <Panel title="Setup pipeline" description="Where client businesses are in onboarding.">
          <div className="op-funnel">
            {(data?.funnel ?? []).map((stage) => (
              <div key={stage.label} className="op-funnel-row">
                <span>{stage.label}</span>
                <div className="op-funnel-bar">
                  <div style={{ width: `${(stage.count / maxFunnel) * 100}%` }} />
                </div>
                <strong>{stage.count}</strong>
              </div>
            ))}
            {!data && <div className="op-empty">{loading ? "Loading..." : "No data"}</div>}
          </div>
        </Panel>
      </div>

      <div className="op-grid">
        <Panel
          title="Setups in progress"
          description="Drafts that still need steps completed."
          action={
            <button type="button" className="owner-secondary-button" onClick={() => onNavigate("Businesses")}>
              All businesses
            </button>
          }
        >
          {data?.inProgress?.length ? (
            <ul className="op-list">
              {data.inProgress.map((b) => (
                <li key={b.id}>
                  <div>
                    <button type="button" className="op-name" onClick={() => onOpenBusiness(b.id)}>{b.name}</button>
                    <span>{b.industry} · {stageLabel(b.status)} · updated {timeAgo(b.updatedAt)}</span>
                  </div>
                  <button type="button" className="owner-secondary-button op-small" onClick={() => onContinueSetup(b.id)}>
                    Continue setup
                  </button>
                </li>
              ))}
            </ul>
          ) : (
            <div className="op-empty">{loading && !data ? "Loading..." : "No setups in progress."}</div>
          )}
        </Panel>

        <Panel
          title="Recent activity"
          description="Latest admin actions."
          action={
            <button type="button" className="owner-secondary-button" onClick={() => onNavigate("Audit Logs")}>
              Audit logs
            </button>
          }
        >
          {data?.activity?.length ? (
            <ul className="op-list op-activity">
              {data.activity.map((log) => (
                <li key={log.id}>
                  <div>
                    <strong>{actionLabel(log.action)}</strong>
                    <span>
                      {log.business_name ? `${log.business_name} · ` : ""}
                      {log.actor ?? "Unknown user"} · {timeAgo(log.created_at)}
                    </span>
                  </div>
                </li>
              ))}
            </ul>
          ) : (
            <div className="op-empty">{loading && !data ? "Loading..." : "No activity recorded yet."}</div>
          )}
        </Panel>
      </div>

      {data?.upcomingCancellations?.length > 0 && (
        <Panel title="Upcoming cancellations" description="Memberships that end when the business's current month is over.">
          <ul className="op-list">
            {data.upcomingCancellations.map((b) => (
              <li key={b.id}>
                <div>
                  <button type="button" className="op-name" onClick={() => onOpenBusiness(b.id)}>{b.name}</button>
                  <span>Stops on {formatDate(b.cancelAt)}</span>
                </div>
                <button type="button" className="op-link" onClick={() => onOpenBusiness(b.id)}>Manage</button>
              </li>
            ))}
          </ul>
        </Panel>
      )}

      <Panel title="Recently added businesses">
        {data?.recentBusinesses?.length ? (
          <div className="owner-table-wrap">
            <table className="owner-table">
              <thead>
                <tr><th>Business</th><th>Industry</th><th>Stage</th><th>Created</th><th /></tr>
              </thead>
              <tbody>
                {data.recentBusinesses.map((b) => (
                  <tr key={b.id}>
                    <td><button type="button" className="op-name" onClick={() => onOpenBusiness(b.id)}>{b.name}</button></td>
                    <td>{b.industry}</td>
                    <td><Pill tone={stageTone(b.status)}>{stageLabel(b.status)}</Pill></td>
                    <td>{formatDate(b.createdAt)}</td>
                    <td><button type="button" className="op-link" onClick={() => onOpenBusiness(b.id)}>View</button></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <div className="op-empty">
            {loading && !data ? "Loading..." : "No businesses yet."}
            {!loading && (
              <button type="button" className="owner-primary-button op-gap-top" onClick={onCreateBusiness}>
                ＋ Create your first business
              </button>
            )}
          </div>
        )}
      </Panel>
    </section>
  );
}
