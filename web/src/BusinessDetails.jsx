import { VoicePanel } from "./settings/VoicePanel";
import { useCallback, useEffect, useState } from "react";
import { createPortal } from "react-dom";
import "./OwnerPages.css";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { supabase } from "./supabase";
import { Icon } from "./BusinessUI";
import { Pill } from "./OwnerOverview";
import AutomationOverview from "./AutomationOverview";
import { BusinessModulesCard, BusinessRecordsCard } from "./BusinessAdminControls";
import {
  actionLabel, businessState, formatDate, formatDateTime, timeAgo, formatDuration,
} from "./ownerFormat";
import { friendlyError } from "./admin/adminOps";

const TABS = [
  "Overview", "Configuration", "People", "AI receptionist",
  "Phone & integrations", "Automations", "Calls", "Activity",
];

const TERM_ROWS = [
  ["customer", "customers", "Customers"],
  ["staff", "staff_plural", "Staff"],
  ["service", "services", "Services"],
  ["appointment", "appointments", "Appointments"],
  ["job", "jobs", "Jobs"],
  ["visit", "visits", "Visits"],
];

const DAYS = [
  ["mon", "Monday"], ["tue", "Tuesday"], ["wed", "Wednesday"], ["thu", "Thursday"],
  ["fri", "Friday"], ["sat", "Saturday"], ["sun", "Sunday"],
];

const LABELS = {
  answer_questions: "Answer questions", answer_calls: "Answer calls", handle_sms: "Reply to texts",
  send_emails: "Send emails", book_appointments: "Book appointments",
  reschedule_appointments: "Reschedule appointments", cancel_appointments: "Cancel appointments",
  collect_customer_info: "Collect customer details", follow_up_leads: "Follow up with leads",
  take_messages: "Take messages",
  customer_requests_human: "Customer asks for a person", unknown_answer: "AI doesn't know the answer",
  upset_customer: "Customer is upset", emergency: "Emergency", sensitive_issue: "Sensitive issue",
  complex_request: "Complex request", billing_question: "Billing question",
  owner: "Business owner", manager: "Manager", team_member: "Team member", phone_number: "Phone number",
  "en-US": "English", "es-US": "Spanish", "en-US+es-US": "English and Spanish",
  new_number: "New Zella number", call_forwarding: "Call forwarding", existing_number: "Call forwarding",
  always: "All calls", no_answer: "When nobody answers", busy_or_no_answer: "When busy or nobody answers",
  after_hours: "After business hours",
  google: "Google", outlook: "Outlook", gmail: "Gmail", none: "None",
};

const label = (key) => LABELS[key] ?? key;

const POLICY_LABELS = {
  cancellation: "Cancellation", refund: "Refund", payment: "Payment",
  emergency: "Emergency", appointment: "Appointment", other: "Other information",
};

const beforeText = (h) => (h < 1 ? `${Math.round(h * 60)} min` : `${h} h`);

function describeSettings(settings = {}) {
  const parts = [];
  if (Array.isArray(settings.hours_before)) {
    parts.push(settings.hours_before.length ? `${settings.hours_before.map(beforeText).join(", ")} before` : "no reminder times");
  } else if (settings.hours_before) parts.push(`${beforeText(settings.hours_before)} before`);
  if (settings.hours_after) parts.push(`${settings.hours_after} h after`);
  if (settings.minutes_after != null) parts.push(settings.minutes_after === 0 ? "immediately" : `after ${settings.minutes_after} min`);
  if (settings.max_attempts) parts.push(`up to ${settings.max_attempts} tries`);
  if (settings.retry_after_hours) parts.push(`retry after ${settings.retry_after_hours} h`);
  if (settings.channel) parts.push(`by ${settings.channel.replace("sms_and_call", "text and call").replace("sms", "text")}`);
  if (settings.fallback_sms) parts.push("text if unanswered");
  return parts.join(" · ") || "Default settings";
}

// Small, Medium or Large: set by a Zella admin, never guessed from the industry. Offers can target it.
function BusinessSizeCard({ businessId, size, onSaved }) {
  const [value, setValue] = useState(size ?? "");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState("");
  useEffect(() => setValue(size ?? ""), [size]);
  async function save() {
    setBusy(true);
    setMsg("");
    const { error } = await supabase.rpc("zella_set_business_size", { p_business_id: businessId, p_size: value || null });
    setBusy(false);
    if (error) { setMsg("Couldn't save the size. Please try again."); return; }
    setMsg("Saved.");
    onSaved();
  }
  return (
    <Card title="Business size" description="Used to decide which offers this business can get.">
      <div className="bd-inline">
        <select value={value} onChange={(e) => setValue(e.target.value)} aria-label="Business size">
          <option value="">Not set</option>
          <option value="small">Small</option>
          <option value="medium">Medium</option>
          <option value="large">Large</option>
        </select>
        <button type="button" className="owner-secondary-button op-small" onClick={save} disabled={busy || value === (size ?? "")}>
          {busy ? "Saving..." : "Save size"}
        </button>
        {msg && <span className="op-muted">{msg}</span>}
      </div>
    </Card>
  );
}

function Facts({ items }) {
  return (
    <dl className="op-facts">
      {items.map(([term, value]) => (
        <div key={term}>
          <dt>{term}</dt>
          <dd>{value || <span className="op-muted">Not set</span>}</dd>
        </div>
      ))}
    </dl>
  );
}

function Card({ title, description, action, children }) {
  return (
    <section className="owner-panel op-card">
      <div className="owner-panel-heading">
        <div>
          <h2>{title}</h2>
          {description && <p>{description}</p>}
        </div>
        {action}
      </div>
      <div className="op-card-body">{children}</div>
    </section>
  );
}

function Empty({ children }) {
  return <div className="op-empty">{children}</div>;
}

function Check({ ok, later, title, detail }) {
  return (
    <li className="op-check">
      <span className={`op-check-dot ${ok ? "ok" : later ? "later" : "missing"}`}>{ok ? "✓" : later ? "–" : "!"}</span>
      <div>
        <strong>{title}</strong>
        <span>{detail}</span>
      </div>
    </li>
  );
}

export default function BusinessDetails({ businessId, onBack, onOpenSetup }) {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [tab, setTab] = useState("Overview");
  const [pending, setPending] = useState(null);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState("");

  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      setData(await callOwnerFunction("business_detail", { businessId }));
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setLoading(false);
    }
  }, [businessId]);

  useEffect(() => {
    load();
  }, [load]);

  // Escape closes the confirm box unless it is busy saving.
  useEffect(() => {
    if (!pending || busy) return undefined;
    const onKey = (event) => {
      if (event.key === "Escape") { setPending(null); setReason(""); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [pending, busy]);

  async function runAction(action, success) {
    setBusy(true);
    setError("");
    setNotice("");
    try {
      const result = await callOwnerFunction(action, { businessId, reason });
      setNotice(success(result));
      setPending(null);
      setReason("");
      await load();
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  if (loading && !data) {
    return <section className="owner-page"><Empty>Loading business...</Empty></section>;
  }

  if (error && !data) {
    return (
      <section className="owner-page">
        <button type="button" className="op-back" onClick={onBack}>← Businesses</button>
        <div className="owner-form-error">Could not load this business: {error}</div>
        <button type="button" className="owner-secondary-button op-gap-top" onClick={load}>Try again</button>
      </section>
    );
  }

  const b = data.business;
  const setupData = b.setup_data || {};
  const r = data.receptionist;
  const kb = r.knowledgeBase || {};
  const esc = r.escalationRules || {};
  const voice = r.voiceConfig || {};
  const terms = data.terminology;
  const invitation = data.invitation;
  const phone = setupData.integrations?.phone;
  const enabledModules = data.modules.filter((m) => m.enabled);
  const enabledAutomations = data.automations.filter((a) => a.status !== "disabled");
  const setupDone = ["testing", "ready", "active"].includes(b.onboarding_status);
  const state = businessState(b);
  const isCancelled = Boolean(b.cancelled_at);
  const isSuspended = Boolean(b.suspended_at);

  const ACTIONS = {
    suspend: {
      title: "Suspend this business now?",
      body: "The workspace, AI receptionist and running automations stop immediately. Reactivating restores exactly what was running.",
      button: "Suspend now",
      danger: true,
      reason: true,
      run: () => runAction("business_suspend", () => `${b.name} is suspended.`),
    },
    reactivate: {
      title: "Reactivate this business?",
      body: "Everything that was running before the suspension starts again.",
      button: "Reactivate",
      run: () => runAction("business_reactivate", () => `${b.name} is active again.`),
    },
    cancel: {
      title: "Cancel this business's membership?",
      body: "Nothing changes until the end of their current month. The owner is emailed a link to continue their plan. If they don't, on that date the workspace is deactivated, the AI receptionist is turned off, automations stop and any subscription is canceled. You can undo this until then.",
      button: "Cancel at end of month",
      danger: true,
      reason: true,
      run: () => runAction("business_cancel", (r) =>
        `${b.name} will be canceled on ${formatDate(r.cancelAt)}. ` +
        (r.emailSent
          ? `The "continue my plan" email was handed to n8n for ${invitation?.email ?? "the owner"}.`
          : `The owner was not emailed: ${r.emailError}.`)
      ),
    },
    undo: {
      title: "Keep this business?",
      body: "The scheduled cancellation is removed and nothing will stop.",
      button: "Undo cancellation",
      run: () => runAction("business_undo_cancel", () => `Cancellation removed. ${b.name} will keep running.`),
    },
    resend: {
      title: "Resend the owner invitation?",
      body: `A new invitation email goes to ${invitation?.email ?? "the owner"}.`,
      button: "Resend invitation",
      run: () => runAction("invitation_resend", (r) =>
        r.invitationStatus === "sent" ? `Invitation resent to ${r.email}.` : `Invitation not sent: ${r.invitationError}`
      ),
    },
  };
  const action = pending ? ACTIONS[pending] : null;
  const telnyx = data.integrations.find(
    (i) => i.provider?.toLowerCase() === "telnyx" && i.status === "active"
  );
  const hoursSet = DAYS.some(([day]) => kb.hours?.[day]?.closed || kb.hours?.[day]?.open);
  const address = [b.address_line_1, b.address_line_2, b.city, b.state, b.postal_code, b.country]
    .filter(Boolean).join(", ");

  const term = (key) => terms.overrides?.[key] || terms.industry?.[key] || key;

  return (
    <section className="owner-page">
      <button type="button" className="op-back" onClick={onBack}>← Businesses</button>

      <div className="owner-page-heading">
        <div>
          <div className="owner-eyebrow">{data.industryName}</div>
          <h1>{b.name}</h1>
          <div className="op-header-pills">
            <Pill tone={state.tone}>{state.label}</Pill>
            <Pill tone={b.is_active ? "success" : "neutral"}>Workspace {b.is_active ? "active" : "inactive"}</Pill>
            <Pill tone={r.status === "active" ? "success" : "neutral"}>AI receptionist {r.status === "active" ? "live" : "off"}</Pill>
          </div>
        </div>
        <div className="op-heading-actions">
          <button type="button" className="owner-secondary-button" onClick={load} disabled={loading}>
            {loading ? "Loading..." : "↻ Refresh"}
          </button>
          {!isCancelled && (
            <button type="button" className="owner-primary-button" onClick={() => onOpenSetup(b.id)}>
              {setupDone ? "Edit setup" : "Continue setup"}
            </button>
          )}
        </div>
      </div>

      {notice && <div className="ic-notice" role="status">{notice}</div>}
      {error && <div className="owner-form-error op-gap">{error}</div>}

      {isSuspended && !isCancelled && (
        <div className="ic-warning op-gap">
          <span>
            Suspended {formatDateTime(b.suspended_at)}{b.suspension_reason ? `: ${b.suspension_reason}` : ""}.
            The workspace, receptionist and automations are stopped.
          </span>
          <div>
            <button type="button" className="owner-primary-button op-small" onClick={() => setPending("reactivate")} disabled={busy}>
              Reactivate
            </button>
          </div>
        </div>
      )}
      {b.cancel_at && !isCancelled && (
        <div className="ic-warning op-gap">
          <span>
            Cancels on {formatDate(b.cancel_at)}{b.cancellation_reason ? `: ${b.cancellation_reason}` : ""}.
            Everything keeps working until then.
          </span>
          <div>
            <button type="button" className="owner-secondary-button op-small" onClick={() => setPending("undo")} disabled={busy}>
              Undo cancellation
            </button>
          </div>
        </div>
      )}
      {isCancelled && (
        <div className="wiz-note op-gap">
          Canceled on {formatDate(b.cancelled_at)}{b.cancellation_reason ? `: ${b.cancellation_reason}` : ""}.
          This business's data is kept, but its workspace, receptionist and automations are off.
        </div>
      )}

      {action && createPortal(
        <div
          className="owner-modal-overlay"
          onMouseDown={(event) => event.target === event.currentTarget && !busy && (setPending(null), setReason(""))}
        >
          <div className={`bd-confirm owner-modal ${action.danger ? "danger" : ""}`} role="dialog" aria-modal="true" aria-label={action.title}>
            <div className="zs-dialog-head">
              <span className="zs-dialog-icon"><Icon name={action.danger ? "warning" : "task_alt"} /></span>
              <h3>{action.title}</h3>
            </div>
            <p>{action.body}</p>
            {action.reason && (
              <label className="owner-field">
                <span>Reason (optional, kept in the audit log)</span>
                <input value={reason} onChange={(e) => setReason(e.target.value)} maxLength={500} />
              </label>
            )}
            <div className="ic-actions">
              <button type="button" className="owner-secondary-button" onClick={() => { setPending(null); setReason(""); }} disabled={busy}>
                Go back
              </button>
              <button type="button" className={action.danger ? "bd-danger-button" : "owner-primary-button"} onClick={action.run} disabled={busy}>
                {busy ? "Working..." : action.button}
              </button>
            </div>
          </div>
        </div>,
        document.body
      )}

      <div className="op-tabs" role="tablist">
        {TABS.map((name) => (
          <button
            key={name}
            type="button"
            role="tab"
            aria-selected={tab === name}
            className={tab === name ? "active" : ""}
            onClick={() => setTab(name)}
          >
            {name}
          </button>
        ))}
      </div>

      {tab === "Overview" && (
        <div className="op-grid">
          <Card title="Verification" description="The business's registration and the owner's photo ID."
            action={<button type="button" className="owner-secondary-button" onClick={() => onOpenSetup(businessId)}>{data.documents?.length ? "Review" : "Upload"}</button>}>
            {data.documentsAvailable === false ? (
              <Empty>Document storage isn't set up yet (apply sql/zella_onboarding.sql).</Empty>
            ) : (
              <ul className="op-checks">
                {[["business_registration", "Business registration"], ["owner_identity", "Owner's photo ID"]].map(([kind, label]) => {
                  const doc = (data.documents ?? []).find((d) => d.kind === kind);
                  const state = !doc ? "Not uploaded" : doc.status === "verified" ? "Verified" : doc.status === "rejected" ? `Rejected: ${doc.review_note ?? "no reason given"}` : "Waiting for review";
                  return <Check key={kind} ok={doc?.status === "verified"} title={label} detail={state} />;
                })}
              </ul>
            )}
          </Card>
          <Card title="Setup progress" description="What's done and what's left before this business goes live.">
            <ul className="op-checks">
              <Check ok title="Business details" detail={`${data.industryName} · ${b.timezone}`} />
              <Check
                ok={Boolean(invitation)}
                title="Owner"
                detail={invitation ? `${invitation.owner_name} · invitation ${invitation.status}` : "Owner not added"}
              />
              <Check ok={enabledModules.length > 0} title="Modules" detail={`${enabledModules.length} of ${data.modules.length} enabled`} />
              <Check
                ok={(kb.services?.length || 0) + (kb.faqs?.length || 0) > 0}
                later
                title="AI receptionist knowledge"
                detail={`${kb.services?.length || 0} ${term("services").toLowerCase()} · ${kb.faqs?.length || 0} FAQs · hours ${hoursSet ? "set" : "not set"}`}
              />
              <Check ok={Boolean(phone)} later title="Phone setup choice" detail={phone ? label(phone.mode) : "Not chosen"} />
              <Check
                ok={Boolean(telnyx)}
                later
                title="Phone number connected"
                detail={telnyx ? `Connected${telnyx.account_email ? ` · ${telnyx.account_email}` : ""}` : "Not connected yet"}
              />
              <Check ok={r.status === "active"} later title="AI receptionist live" detail={r.status === "active" ? "Answering calls" : "Off until phone and voice agent are connected"} />
              <Check ok={invitation?.status === "accepted"} later title="Owner accepted invitation" detail={invitation?.status === "accepted" ? `Accepted ${formatDate(invitation.accepted_at)}` : "Not yet"} />
            </ul>
          </Card>

          <Card title="Business information">
            <Facts items={[
              ["Business name", b.name],
              ["Legal name", b.legal_name],
              ["Industry", data.industryName],
              ["Timezone", b.timezone],
              ["Business email", b.email],
              ["Business phone", b.phone],
              ["Website", b.website],
              ["Address", address],
              ["Created", formatDate(b.created_at)],
              ["Calls recorded", String(data.callCount)],
              ["Support tickets", String(data.tickets.length)],
            ]} />
          </Card>

          <BusinessSizeCard businessId={businessId} size={b.business_size} onSaved={load} />

          {!isCancelled && (
            <Card title="Manage business" description="Stop a business now, or end its membership when its month is over.">
              <div className="bd-manage">
                {isSuspended ? (
                  <div>
                    <strong>Reactivate</strong>
                    <span>Start everything that was running before the suspension.</span>
                    <button type="button" className="owner-secondary-button op-small" onClick={() => setPending("reactivate")} disabled={busy}>Reactivate</button>
                  </div>
                ) : (
                  <div>
                    <strong>Suspend now</strong>
                    <span>Stops the workspace, receptionist and automations immediately. For example, a payment problem.</span>
                    <button type="button" className="owner-secondary-button op-small" onClick={() => setPending("suspend")} disabled={busy}>Suspend</button>
                  </div>
                )}
                {b.cancel_at ? (
                  <div>
                    <strong>Undo cancellation</strong>
                    <span>Currently cancels on {formatDate(b.cancel_at)}.</span>
                    <button type="button" className="owner-secondary-button op-small" onClick={() => setPending("undo")} disabled={busy}>Undo</button>
                  </div>
                ) : (
                  <div>
                    <strong>Cancel membership</strong>
                    <span>Keeps working until the end of their current month, then stops automatically.</span>
                    <button type="button" className="wiz-link-danger bd-inline" onClick={() => setPending("cancel")} disabled={busy}>Cancel at end of month</button>
                  </div>
                )}
              </div>
            </Card>
          )}
        </div>
      )}

      {tab === "Configuration" && (
        <div className="op-grid">
          <Card title="Terminology" description="How this business's CRM names things.">
            <div className="owner-table-wrap">
              <table className="owner-table">
                <thead><tr><th>Term</th><th>Used here</th><th>Industry default</th></tr></thead>
                <tbody>
                  {TERM_ROWS.map(([singular, plural, name]) => {
                    const custom = terms.overrides?.[singular] || terms.overrides?.[plural];
                    return (
                      <tr key={singular}>
                        <td>{name}</td>
                        <td>
                          <strong className="op-strong">{term(singular)} / {term(plural)}</strong>
                          {custom && <Pill tone="info">Custom</Pill>}
                        </td>
                        <td>{terms.industry?.[singular] || "—"} / {terms.industry?.[plural] || "—"}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          </Card>

          <Card title="Modules" description={`${enabledModules.length} of ${data.modules.length} switched on. Only modules its industry offers are listed.`}>
            <BusinessModulesCard key={data.modules.map((m) => `${m.id}${m.enabled}`).join()} businessId={businessId} modules={data.modules} onSaved={load} />
          </Card>

          <Card title="Industry records" description="Record types from its industry, such as tables, recalls or vehicles. Switching one off hides it; records are kept.">
            <BusinessRecordsCard businessId={businessId} />
          </Card>
        </div>
      )}

      {tab === "People" && (
        <div className="op-stack">
          <Card title="Members" description="People with access to this business's workspace.">
            {data.members.length ? (
              <div className="owner-table-wrap">
                <table className="owner-table">
                  <thead><tr><th>Name</th><th>Email</th><th>Role</th><th>Status</th><th>Added</th></tr></thead>
                  <tbody>
                    {data.members.map((m) => (
                      <tr key={m.user_id}>
                        <td>{m.name || "—"}</td>
                        <td>{m.email || "—"}</td>
                        <td className="op-cap">{m.role}</td>
                        <td><Pill tone={m.status === "active" ? "success" : "neutral"}>{m.status}</Pill></td>
                        <td>{formatDate(m.created_at)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            ) : (
              <Empty>No members yet. The owner is added when their invitation is sent.</Empty>
            )}
          </Card>

          <Card
            title="Invitations"
            action={
              invitation && invitation.status !== "accepted" && !isCancelled && (
                <button type="button" className="owner-secondary-button op-small" onClick={() => setPending("resend")} disabled={busy}>
                  Resend invitation
                </button>
              )
            }
          >
            {data.invitations.length ? (
              <div className="owner-table-wrap">
                <table className="owner-table">
                  <thead><tr><th>Owner</th><th>Email</th><th>Status</th><th>Sent</th><th>Expires</th><th>Last error</th></tr></thead>
                  <tbody>
                    {data.invitations.map((i) => (
                      <tr key={i.id}>
                        <td>{i.owner_name}</td>
                        <td>{i.email}</td>
                        <td>
                          <Pill tone={i.status === "accepted" ? "success" : i.status === "failed" || i.status === "expired" ? "danger" : "neutral"}>
                            {i.status}
                          </Pill>
                        </td>
                        <td>{formatDateTime(i.invited_at)}</td>
                        <td>{formatDate(i.expires_at)}</td>
                        <td className="op-muted">{i.last_error || "—"}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            ) : (
              <Empty>No invitations yet.</Empty>
            )}
          </Card>
        </div>
      )}

      {tab === "AI receptionist" && (
        <div className="op-stack">
          <div className="op-grid">
            <Card title="Identity & voice">
              <Facts items={[
                ["Status", r.status === "active" ? "Live" : "Off (not connected)"],
                ["Name", r.name],
                ["Personality", r.personality ? r.personality[0].toUpperCase() + r.personality.slice(1) : ""],
                ["Language", voice.language ? label(voice.language) : ""],
                ["Greeting", voice.greeting],
                ["Extra instructions", r.tone],
              ]} />
            </Card>
            <Card title="About & hours">
              <Facts items={[
                ["Description", kb.about],
                ["Service area", kb.service_area],
                ...DAYS.map(([day, name]) => {
                  const h = kb.hours?.[day];
                  return [name, h?.closed ? "Closed" : h?.open ? `${h.open} – ${h.close}` : ""];
                }),
              ]} />
            </Card>
          </div>

          <div className="zs ao-embed"><VoicePanel businessId={businessId} /></div>

          <Card title={term("services")} description={`${kb.services?.length || 0} added`}>
            {kb.services?.length ? (
              <div className="owner-table-wrap">
                <table className="owner-table">
                  <thead><tr><th>Name</th><th>Price</th><th>Duration</th><th>Description</th></tr></thead>
                  <tbody>
                    {kb.services.map((s, i) => (
                      <tr key={i}><td><strong className="op-strong">{s.name}</strong></td><td>{s.price || "—"}</td><td>{s.duration || "—"}</td><td>{s.description || "—"}</td></tr>
                    ))}
                  </tbody>
                </table>
              </div>
            ) : <Empty>No {term("services").toLowerCase()} added yet.</Empty>}
          </Card>

          <Card title="FAQs" description={`${kb.faqs?.length || 0} added`}>
            {kb.faqs?.length ? (
              <div className="op-faqs">
                {kb.faqs.map((f, i) => (
                  <details key={i}>
                    <summary>{f.question}</summary>
                    <p>{f.answer}</p>
                  </details>
                ))}
              </div>
            ) : <Empty>No FAQs added yet.</Empty>}
          </Card>

          <div className="op-grid">
            <Card title="Policies">
              {Object.keys(kb.policies || {}).length ? (
                <Facts items={Object.entries(kb.policies).map(([k, v]) => [POLICY_LABELS[k] ?? k, v])} />
              ) : <Empty>No policies added yet.</Empty>}
            </Card>
            <Card title="Rules">
              <div className="op-rule-block">
                <h4>Can do</h4>
                {r.capabilities?.length ? (
                  <ul className="op-tag-list">{r.capabilities.map((c) => <li key={c} className="on">{label(c)}</li>)}</ul>
                ) : <p className="op-muted">Nothing selected</p>}
              </div>
              <div className="op-rule-block">
                <h4>Hands over to a person when</h4>
                {esc.triggers?.length ? (
                  <ul className="op-tag-list">{esc.triggers.map((t) => <li key={t}>{label(t)}</li>)}</ul>
                ) : <p className="op-muted">Nothing selected</p>}
                <p className="op-muted">
                  Transfers to {label(esc.transfer_to?.type || "owner")}
                  {esc.transfer_to?.name ? ` (${esc.transfer_to.name})` : ""}
                  {esc.transfer_to?.phone ? ` at ${esc.transfer_to.phone}` : ""}
                </p>
              </div>
              <div className="op-rule-block">
                <h4>Must never</h4>
                {kb.restrictions?.length ? (
                  <ul className="op-bullets">{kb.restrictions.map((x, i) => <li key={i}>{x}</li>)}</ul>
                ) : <p className="op-muted">No restrictions added</p>}
              </div>
            </Card>
          </div>
        </div>
      )}

      {tab === "Phone & integrations" && (
        <div className="op-stack">
          <Card title="Setup choices" description="What the business asked for during setup.">
            {setupData.integrations ? (
              <Facts items={[
                ["Phone setup", label(phone?.mode)],
                ...(phone?.mode !== "new_number"
                  ? [["Forward from", phone?.forward_from || phone?.existing_number], ["Forward when", label(phone?.forward_when)]]
                  : []),
                ["Preferred area code", phone?.area_code],
                ["Call transfer number", setupData.integrations.transfer_number],
                ["Calendar", label(setupData.integrations.calendar)],
                ["Email", label(setupData.integrations.email)],
                ["Lead sources", Object.entries(setupData.integrations.lead_sources || {})
                  .filter(([, on]) => on).map(([k]) => ({ meta: "Meta", website: "Website", google: "Google" })[k]).join(", ")],
              ]} />
            ) : <Empty>Phone & integrations step not completed yet.</Empty>}
          </Card>

          <Card title="Live connections" description="Services actually connected and verified for this business.">
            {data.integrations.length ? (
              <div className="owner-table-wrap">
                <table className="owner-table">
                  <thead><tr><th>Provider</th><th>Type</th><th>Status</th><th>Account</th><th>Last sync</th><th>Error</th></tr></thead>
                  <tbody>
                    {data.integrations.map((i) => (
                      <tr key={i.id}>
                        <td className="op-cap">{i.provider}</td>
                        <td>{i.integration_type}</td>
                        <td><Pill tone={i.status === "active" ? "success" : i.status === "error" ? "danger" : "neutral"}>{i.status}</Pill></td>
                        <td>{i.account_email || "—"}</td>
                        <td>{formatDateTime(i.last_synced_at)}</td>
                        <td className="op-muted">{i.error_message || "—"}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            ) : <Empty>Nothing connected yet. Telnyx, Vapi, calendar and lead sources appear here once connected.</Empty>}
          </Card>
        </div>
      )}

      {tab === "Automations" && (
        <Card title="Automations" description="Run by n8n. Paused automations start when the business goes live.">
          <AutomationOverview rows={data.automations} industryName={data.industryName} appointmentWord={String(term("appointment")).toLowerCase()} describeSettings={describeSettings} />
          {enabledAutomations.length > 0 && <p className="op-muted op-gap-top">{enabledAutomations.length} turned on.</p>}
        </Card>
      )}

      {tab === "Calls" && (
        <Card title="Recent calls" description={`${data.callCount} calls recorded`}>
          {data.calls.length ? (
            <div className="owner-table-wrap">
              <table className="owner-table">
                <thead><tr><th>When</th><th>Direction</th><th>From</th><th>To</th><th>Duration</th><th>Handled by</th><th>Status</th></tr></thead>
                <tbody>
                  {data.calls.map((c) => (
                    <tr key={c.id}>
                      <td>{formatDateTime(c.started_at || c.created_at)}</td>
                      <td className="op-cap">{c.direction}</td>
                      <td>{c.from_number || "—"}</td>
                      <td>{c.to_number || "—"}</td>
                      <td>{formatDuration(c.duration_seconds)}</td>
                      <td>{c.ai_handled ? "AI" : "Team"}</td>
                      <td className="op-cap">{c.status}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : <Empty>No calls yet. Calls appear once the phone number and AI receptionist are connected.</Empty>}
        </Card>
      )}

      {tab === "Activity" && (
        <Card title="Activity" description="Admin actions on this business.">
          {data.activity.length ? (
            <ul className="op-list op-activity">
              {data.activity.map((log) => (
                <li key={log.id}>
                  <div>
                    <strong>{actionLabel(log.action)}</strong>
                    <span>{log.actor ?? "Unknown user"} · {formatDateTime(log.created_at)} ({timeAgo(log.created_at)})</span>
                  </div>
                </li>
              ))}
            </ul>
          ) : <Empty>No activity recorded yet.</Empty>}
        </Card>
      )}
    </section>
  );
}
