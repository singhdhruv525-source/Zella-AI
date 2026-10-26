import { supabase } from "./supabase";
import { Icon, Pill } from "./BusinessUI";
import { Empty, Notice, useLoad } from "./BusinessShared";

// Reports and banners computed by the database from real records
// (sql/zella_monitoring.sql, sql/zella_security_extras.sql, sql/zella_reconnect.sql).
// Each function checks the person's membership or role itself.

const words = (s) => String(s ?? "").replace(/_/g, " ").replace(/^./, (c) => c.toUpperCase());
const pct = (n, d) => (d ? `${Math.round((n / d) * 100)}%` : "—");

async function rpc(name, args) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw error;
  return data;
}

// Connections that stopped working (calendar, Facebook/Instagram). Quiet when there is nothing, or on error.
export function ReconnectBanner({ workspace, onGo, tick }) {
  const { data } = useLoad(() => rpc("zella_connections_to_reconnect", { p_business_id: workspace.id }).catch(() => []), [workspace.id, tick]);
  if (!data?.length) return null;
  const canFix = ["owner", "admin", "manager"].includes(workspace.role);
  return (
    <div className="ba-banner alert" role="alert">
      <span>
        <strong>{data.length === 1 ? `${data[0].label} needs to be connected again.` : `${data.length} connections need to be connected again.`}</strong>{" "}
        {data.map((c) => c.reason).filter(Boolean).slice(0, 2).join(" · ")}
      </span>
      {canFix
        ? <button type="button" className="ba-btn primary sm" onClick={() => onGo("integrations")}>Reconnect</button>
        : <span className="ba-muted">Ask an owner or manager to reconnect it.</span>}
    </div>
  );
}

function IntegrationHealth({ workspace, refreshKey }) {
  const { data, error, loading, reload } = useLoad(() => rpc("zella_integration_summary", { p_business_id: workspace.id }), [workspace.id, refreshKey]);
  return (
    <section className="ba-panel">
      <div className="ba-panel-head"><div className="ba-panel-title"><div><h2>Connections</h2><p>Phone, calendar, social accounts and whether today's texts and emails went out.</p></div></div>
        {data && <Pill tone={data.all_ok ? "success" : "warning"}>{data.all_ok ? "All working" : "Needs attention"}</Pill>}
      </div>
      <div className="ba-panel-body">
        <Notice error={error} onRetry={reload} />
        {loading && !data && <p className="ba-muted">Loading…</p>}
        <ul className="ba-list">
          {(data?.items ?? []).map((i) => (
            <li key={i.key} className="ba-list-row">
              <div><strong>{i.label}</strong><small>{i.detail}</small></div>
              <Icon name={i.ok ? "check_circle" : "error"} />
            </li>
          ))}
        </ul>
      </div>
    </section>
  );
}

function ResponseTimes({ workspace, days, refreshKey }) {
  const { data, error, loading, reload } = useLoad(() => rpc("zella_response_time_report", { p_business_id: workspace.id, p_days: days }), [workspace.id, days, refreshKey]);
  return (
    <section className="ba-panel">
      <div className="ba-panel-head"><div className="ba-panel-title"><div><h2>Reply speed</h2><p>How quickly incoming texts got a reply in the last {days} days.</p></div></div></div>
      <div className="ba-panel-body">
        <Notice error={error} onRetry={reload} />
        {loading && !data && <p className="ba-muted">Loading…</p>}
        {data && !data.texts_received && <Empty title="No texts yet">Reply times appear once customers start texting you.</Empty>}
        {data?.texts_received > 0 && (
          <dl className="ba-facts">
            <div><dt>Texts received</dt><dd>{data.texts_received}</dd></div>
            <div><dt>Got a reply</dt><dd>{pct(data.replied, data.texts_received)}</dd></div>
            <div><dt>Typical reply time</dt><dd>{data.median_minutes == null ? "—" : `${data.median_minutes} min`}</dd></div>
            <div><dt>Replied within an hour</dt><dd>{pct(data.replied_within_hour, data.texts_received)}</dd></div>
            <div><dt>Still waiting</dt><dd>{data.waiting ? <Pill tone="warning">{data.waiting}</Pill> : "None"}</dd></div>
          </dl>
        )}
      </div>
    </section>
  );
}

function MessageResults({ workspace, days, refreshKey }) {
  const { data, error, loading, reload } = useLoad(() => rpc("zella_workflow_effectiveness", { p_business_id: workspace.id, p_days: days }), [workspace.id, days, refreshKey]);
  return (
    <section className="ba-panel">
      <div className="ba-panel-head"><div className="ba-panel-title"><div><h2>Automatic follow-ups</h2><p>What happened to the follow-ups Zella sent in the last {days} days, and how many led to a booking within a week.</p></div></div></div>
      {error || (loading && !data) || !data?.length ? (
        <div className="ba-panel-body">
          <Notice error={error} onRetry={reload} />
          {loading && !data && <p className="ba-muted">Loading…</p>}
          {data && !data.length && <Empty title="No follow-ups yet">They appear here once automations start sending.</Empty>}
        </div>
      ) : (
        <div className="ba-table-wrap">
          <table className="ba-table">
            <thead><tr><th>Follow-up</th><th>By</th><th>Sent</th><th>Failed</th><th>Skipped</th><th>Booked within 7 days</th></tr></thead>
            <tbody>
              {data.map((r) => (
                <tr key={`${r.kind}-${r.channel}`}>
                  <td>{words(r.kind)}</td>
                  <td>{r.channel === "sms" ? "Text" : words(r.channel)}</td>
                  <td>{r.done} of {r.total}</td>
                  <td>{r.failed ? <Pill tone="danger">{r.failed}</Pill> : 0}</td>
                  <td>{r.skipped}</td>
                  <td>{r.booked_within_7_days} ({pct(r.booked_within_7_days, r.done)})</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}

export function MoreReports({ workspace, days, refreshKey }) {
  const managers = ["owner", "admin", "manager"].includes(workspace.role);
  return (
    <>
      <div className="ba-grid-2" style={{ marginTop: 16 }}>
        <IntegrationHealth workspace={workspace} refreshKey={refreshKey} />
        {managers && <ResponseTimes workspace={workspace} days={days} refreshKey={refreshKey} />}
      </div>
      <div style={{ marginTop: 16 }}><MessageResults workspace={workspace} days={days} refreshKey={refreshKey} /></div>
    </>
  );
}
