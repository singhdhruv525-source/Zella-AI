import { useCallback, useEffect, useState } from "react";
import { supabase } from "./supabase";
import { reasonWords, recordRows, senderSummary } from "./businessEmailSetup";

// The business's own email address, in the Create Business wizard (docs/ARCHITECTURE.md §14.4). The business adds the
// DNS records itself, step by step; Zella Voice never holds its domain or website login. Each action takes effect on
// the server at once (business-email, sql/zella_business_email.sql), so nothing here is part of the step's Save.
// Badge is the wizard's own badge component.

async function callEmail(action, payload) {
  const { data, error } = await supabase.functions.invoke("business-email", { body: { action, ...payload } });
  if (!error) return data;
  let body = null;
  try { body = await error.context?.json?.(); } catch { body = null; }
  return body && typeof body === "object" ? body : { ok: false, error: "try_again" };
}

export default function BusinessEmailSetup({ businessId, Badge }) {
  const [state, setState] = useState({ phase: "loading", status: null, error: "" });
  const [route, setRoute] = useState("");          // the way the admin chose on screen: "domain" or "mailbox"
  const [address, setAddress] = useState("");
  const [busy, setBusy] = useState("");            // "start", "verify" or "disconnect" while the server works
  const [problem, setProblem] = useState("");
  const [notice, setNotice] = useState("");
  const [asking, setAsking] = useState(false);     // the disconnect confirmation is open
  const [copied, setCopied] = useState("");

  const load = useCallback(async () => {
    if (!businessId) return;
    setState((s) => ({ ...s, phase: s.status ? "refreshing" : "loading", error: "" }));
    const { data, error } = await supabase.rpc("zella_business_email_status", { p_business_id: businessId });
    if (error || !data) {
      setState((s) => ({ ...s, phase: s.status ? "stale" : "error", error: /zella_business_email_status|PGRST202|schema cache/i.test(`${error?.code} ${error?.message}`)
        ? "Business email setup isn't installed on the server yet." : "Couldn't load the business email setup." }));
      return;
    }
    setState({ phase: "ready", status: data, error: "" });
    if (data.route) setRoute(data.route);
    if (data.route === "domain" && data.address) setAddress(data.address);
  }, [businessId]);
  useEffect(() => { load(); }, [load]);

  async function run(kind, action, payload, done) {
    setBusy(kind); setProblem(""); setNotice("");
    const answer = await callEmail(action, { business_id: businessId, ...payload });
    setBusy("");
    if (!answer?.ok) { setProblem(reasonWords(answer?.error)); return; }
    setNotice(done(answer));
    await load();
  }

  if (!businessId) return <p className="wiz-hint">Save the Business step first: the email address is set up for a saved business.</p>;
  if (state.phase === "loading") return <p className="wiz-hint" role="status">Checking the business email…</p>;
  if (state.phase === "error") {
    return (
      <div className="owner-form-error" role="alert">
        {state.error} Nothing was changed. <button type="button" className="owner-secondary-button sm" onClick={load}>Try again</button>
      </div>
    );
  }
  const status = state.status;
  const summary = senderSummary(status);
  const rows = recordRows(status.dns_records);
  const domainSet = status.route === "domain";

  return (
    <div className="wiz-email">
      {state.phase === "stale" && <div className="owner-form-error" role="alert">{state.error} Showing what was last loaded. <button type="button" className="owner-secondary-button sm" onClick={load}>Try again</button></div>}
      <div className="wiz-connection">
        <div>
          <strong>Customer emails now</strong>
          <span>{summary.text}</span>
        </div>
        <div className="wiz-connection-side"><Badge tone={summary.tone}>{summary.badge}</Badge></div>
      </div>

      <div className="wiz-choice-row" role="group" aria-label="How the business sends">
        {[
          ["domain", "The business's own domain", "The business adds a few DNS records. Works with any mail service and has no daily limit."],
          ["mailbox", "Gmail or Outlook mailbox", "The owner or an admin of the business connects it after signing in to Zella Voice: Settings, SMS, email and messages, Business email address."],
        ].map(([key, label, text]) => (
          <button type="button" key={key} className={`wiz-choice ${route === key ? "selected" : ""}`} aria-pressed={route === key} onClick={() => setRoute(key)}>
            <strong>{label}</strong>
            <span>{text}</span>
          </button>
        ))}
      </div>

      {route === "domain" && (
        <>
          <div className="owner-form-grid">
            <label className="owner-field">
              <span>Business email address</span>
              <input type="email" autoComplete="off" value={address} maxLength={254} placeholder="hello@yourbusiness.com" onChange={(e) => setAddress(e.target.value)} />
              <small className="wiz-hint">Customers see this address. Its domain is the one the business verifies.</small>
            </label>
          </div>
          <div className="wiz-email-actions">
            <button type="button" className="owner-primary-button" disabled={!!busy || !address.trim() || (domainSet && address.trim().toLowerCase() === status.address)}
              onClick={() => run("start", "domain_start", { address: address.trim() }, () => "DNS records ready. Follow the steps below.")}>
              {busy === "start" ? "Getting the records…" : domainSet ? "Use this address instead" : "Show the DNS records"}
            </button>
          </div>

          {domainSet && rows.length > 0 && (
            <ol className="wiz-email-steps">
              <li>
                <strong>Sign in where {status.domain} is managed</strong>
                <span>The business does this itself, at its domain registrar or DNS host. Zella Voice never asks for that login.</span>
              </li>
              <li>
                <strong>Add these {rows.length} records exactly as shown</strong>
                <span>Some DNS hosts add {status.domain} to the name by themselves. If yours does, enter the name as shown.</span>
                <div className="owner-table-wrap">
                  <table className="owner-table">
                    <thead><tr><th>Type</th><th>Name</th><th>Value</th><th>Priority</th><th>Checked</th><th className="col-actions" aria-label="Copy" /></tr></thead>
                    <tbody>
                      {rows.map((r) => (
                        <tr key={r.key}>
                          <td>{r.type}</td>
                          <td><span className="owner-cell-truncate" title={r.name}>{r.name}</span></td>
                          <td><span className="owner-cell-truncate wiz-email-value" title={r.value}>{r.value}</span></td>
                          <td>{r.priority || "None"}</td>
                          <td>{r.ok ? <Badge tone="success">Found</Badge> : <Badge>Not yet</Badge>}</td>
                          <td className="col-actions">
                            <button type="button" className="owner-secondary-button sm" aria-label={`Copy the ${r.type} value for ${r.name}`}
                              onClick={async () => { try { await navigator.clipboard.writeText(r.value); setCopied(r.key); } catch { setCopied(""); setProblem("Couldn't copy. Select the value and copy it by hand."); } }}>
                              {copied === r.key ? "Copied" : "Copy value"}
                            </button>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </li>
              <li>
                <strong>Press Verify</strong>
                <span>DNS changes can take from a few minutes to a day to be seen. Press Verify again later if they aren't found yet.</span>
                <div className="wiz-email-actions">
                  <button type="button" className="owner-primary-button" disabled={!!busy}
                    onClick={() => run("verify", "domain_verify", {}, (a) => a.domain_status === "verified" ? `Verified. ${status.domain} works for sending.` : a.domain_status === "failed" ? "The records didn't check out. Check them against the table and press Verify again." : "Not verified yet. The records aren't seen yet; try again later.")}>
                    {busy === "verify" ? "Checking…" : "Verify"}
                  </button>
                  {status.domain_status === "verified" && <Badge tone="success">Verified</Badge>}
                </div>
              </li>
            </ol>
          )}
        </>
      )}

      {route === "mailbox" && (
        <p className="wiz-hint">The business signs in to its own Gmail or Outlook itself, from Settings, SMS, email and messages, Business email address, once its owner has accepted the invitation. Zella Voice never asks for that password. Until then, customer emails use Zella Voice's address with replies going to the business.</p>
      )}

      {notice && <p className="wiz-hint" role="status">{notice}</p>}
      {problem && <div className="owner-form-error" role="alert">{problem}</div>}

      {status.route && (
        asking ? (
          <div className="wiz-note" role="alertdialog" aria-label="Stop using this address">
            <p>Stop sending from {status.address}? Customer emails go back to the business name at Zella Voice's address, with replies to the business email.{status.route === "domain" ? " The domain is removed from Zella Voice's email provider; the business can remove its DNS records." : ""}</p>
            <div className="wiz-email-actions">
              <button type="button" className="bd-danger-button" disabled={!!busy}
                onClick={() => run("disconnect", "disconnect", {}, (a) => (a.provider_cleanup === "not_removed" ? "Stopped. The email provider didn't confirm the domain's removal; Zella Voice support can finish it." : "Stopped. Customer emails use Zella Voice's address again.")).then(() => setAsking(false))}>
                {busy === "disconnect" ? "Stopping…" : "Stop using it"}
              </button>
              <button type="button" className="owner-secondary-button" disabled={!!busy} onClick={() => setAsking(false)}>Keep it</button>
            </div>
          </div>
        ) : (
          <div className="wiz-email-actions">
            <button type="button" className="owner-secondary-button" disabled={!!busy} onClick={() => setAsking(true)}>Stop using this address</button>
          </div>
        )
      )}
    </div>
  );
}
