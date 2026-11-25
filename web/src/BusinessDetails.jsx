import { DialogFocus } from "./useDialogFocus";
import { SheetGrip } from "./navigation/SheetGrip";
import { useCallback, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import "./OwnerPages.css";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Icon } from "./BusinessUI";
import { Pill } from "./OwnerOverview";
import { businessState, formatDate, formatDateTime, setupDone as isSetupDone } from "./ownerFormat";
import { friendlyError } from "./admin/adminOps";
import { DAYS, Empty } from "./business/shared";
import { DEFAULT_TAB, DETAIL_TABS, tabKeyTarget } from "./business/tabs";
import OverviewTab from "./business/OverviewTab";
import ConfigurationTab from "./business/ConfigurationTab";
import PeopleTab from "./business/PeopleTab";
import ReceptionistTab from "./business/ReceptionistTab";
import PhoneTab from "./business/PhoneTab";
import AutomationsTab from "./business/AutomationsTab";
import CallsTab from "./business/CallsTab";
import ActivityTab from "./business/ActivityTab";
import "./business/businessDetail.css";

const TAB_COMPONENTS = {
  overview: OverviewTab, configuration: ConfigurationTab, people: PeopleTab, receptionist: ReceptionistTab,
  phone: PhoneTab, automations: AutomationsTab, calls: CallsTab, activity: ActivityTab,
};


// can(permission): what the signed in admin may do (hasPermission in adminPermissions.js). Write buttons show only with
// businesses.manage (setup, documents, invitations, size, modules, record types) or businesses.lifecycle (suspend,
// reactivate, cancel); the server checks the same permission again. Without it, nothing is offered (fails closed).
// tab: the tab slug from the address (business/tabs.js); onTab(slug) changes the address. Without them (an older
// shell) the page keeps its own tab.
export default function BusinessDetails({ businessId, onBack, onOpenSetup, can = () => false, tab: routeTab, onTab }) {
  const canManage = can("businesses.manage");
  const canLifecycle = can("businesses.lifecycle");
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [ownTab, setOwnTab] = useState(DEFAULT_TAB);
  const tab = routeTab ?? ownTab;
  const setTab = onTab ?? setOwnTab;
  const tabRefs = useRef([]);
  // On a phone the tab row scrolls: keep the open tab in view (UI-34).
  useEffect(() => {
    document.getElementById(`bd-tab-${tab}`)?.scrollIntoView?.({ block: "nearest", inline: "nearest" });
  }, [tab, data]);
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
      // BIZ-17: the change happened, but its audit row didn't save; the team was alerted
      setNotice(success(result) + (result?.auditWarning ? ` ${result.auditWarning}` : ""));
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
    return <section className="owner-page"><Empty>Loading business…</Empty></section>;
  }

  if (error && !data) {
    return (
      <section className="owner-page">
        <button type="button" className="op-back" onClick={onBack}><Icon name="arrow_back" size="sm" />Businesses</button>
        <div className="owner-form-error">This business didn't load. {error}</div>
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
  const setupDone = isSetupDone(b.onboarding_status);   // the same rule as the Businesses list (BIZ-24)
  const state = businessState(b);
  const isCancelled = Boolean(b.cancelled_at);
  const isSuspended = Boolean(b.suspended_at);
  const isLive = b.onboarding_status === "active" && !isSuspended && !isCancelled;

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
        // emailSent: the email workflow accepted the request (the send itself happens there)
        (r.emailSent
          ? `The "continue my plan" email was handed to the email service for ${invitation?.email ?? "the owner"}.`
          : `The owner was not emailed: ${r.emailError}.`)
      ),
    },
    undo: {
      title: "Keep this business?",
      body: "The scheduled cancellation is removed and nothing will stop.",
      button: "Undo cancellation",
      run: () => runAction("business_undo_cancel", () => `Cancellation removed. ${b.name} will keep running.`),
    },
    editLive: {
      title: "Edit a live business?",
      body: "This business is live. What you save in setup, including the AI receptionist, applies from its next call.",
      button: "Open setup",
      run: () => { setPending(null); onOpenSetup(b.id); },
    },
    resend: {
      title: "Resend the owner invitation?",
      body: `A new invitation email goes to ${invitation?.email ?? "the owner"}.`,
      button: "Resend invitation",
      run: () => runAction("invitation_resend", (r) =>
        r.invitationStatus === "sent"
          ? (r.existingAccount ? `${r.email} already has a Zella Voice account, so a sign in link was sent instead. Signing in through it adds this business.` : `Invitation resent to ${r.email}.`)
          : `Invitation not sent: ${r.invitationError}`
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
  // BIZ-04: Activity only when this admin has audit.view now AND the server said so for this response (fails closed;
  // the server checks again on its own).
  const tabs = DETAIL_TABS.filter((t) => t.slug !== "activity" || (can("audit.view") && data.activityAllowed === true));
  const shown = tabs.some((t) => t.slug === tab) ? tab : DEFAULT_TAB;
  const Panel = TAB_COMPONENTS[shown] ?? OverviewTab;
  // every way into setup from this page asks first for a live business (the header and the tabs alike)
  const openSetup = (id = b.id) => (isLive ? setPending("editLive") : onOpenSetup(id));
  const panelProps = {
    data, b, setupData, r, kb, esc, voice, terms, term, invitation, phone, enabledModules, enabledAutomations, isCancelled,
    isSuspended, canManage, canLifecycle, busy, setPending, onOpenSetup: openSetup, businessId, load, telnyx, hoursSet, address, setupDone, can,
  };

  return (
    <section className="owner-page">
      <button type="button" className="op-back" onClick={onBack}><Icon name="arrow_back" size="sm" />Businesses</button>

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
            {loading ? "Loading…" : <><Icon name="refresh" size="sm" />Refresh</>}
          </button>
          {!isCancelled && canManage && (
            // BIZ-06: setup can't be finished while suspended (the server refuses too). COM-04 option B: on a live
            // business, changes reach the next call, so the admin confirms first.
            <button type="button" className="owner-primary-button" disabled={isSuspended && !setupDone}
              title={isSuspended && !setupDone ? "Reactivate the business before finishing setup" : undefined}
              onClick={() => openSetup()}>
              {setupDone ? "Edit setup" : "Continue setup"}
            </button>
          )}
        </div>
      </div>
      {!isCancelled && canManage && isSuspended && !setupDone && (
        <p className="op-muted bd-hint">Continue setup is off while this business is suspended. Reactivate it first.</p>
      )}

      {notice && <div className="ic-notice" role="status">{notice}</div>}
      {error && <div className="owner-form-error op-gap">{error}</div>}

      {isSuspended && !isCancelled && (
        <div className="ic-warning op-gap">
          <span>
            Suspended {formatDateTime(b.suspended_at)}{b.suspension_reason ? `: ${b.suspension_reason}` : ""}.
            The workspace, receptionist and automations are stopped.
          </span>
          {canLifecycle && (
            <div>
              <button type="button" className="owner-primary-button op-small" onClick={() => setPending("reactivate")} disabled={busy}>
                Reactivate
              </button>
            </div>
          )}
        </div>
      )}
      {b.cancel_at && !isCancelled && (
        <div className="ic-warning op-gap">
          <span>
            Cancels on {formatDate(b.cancel_at)}{b.cancellation_reason ? `: ${b.cancellation_reason}` : ""}.
            Everything keeps working until then.
          </span>
          {canLifecycle && (
            <div>
              <button type="button" className="owner-secondary-button op-small" onClick={() => setPending("undo")} disabled={busy}>
                Undo cancellation
              </button>
            </div>
          )}
        </div>
      )}
      {isCancelled && (
        <div className="wiz-note op-gap">
          Canceled on {formatDate(b.cancelled_at)}{b.cancellation_reason ? `: ${b.cancellation_reason}` : ""}.
          This business's data is kept, but its workspace, receptionist and automations are off.
        </div>
      )}

      {action && createPortal(
        <DialogFocus onClose={null} busy={busy}><div
          className="owner-modal-overlay"
          onMouseDown={(event) => event.target === event.currentTarget && !busy && (setPending(null), setReason(""))}
        >
          <div className={`bd-confirm owner-modal ${action.danger ? "danger" : ""}`} role="dialog" aria-modal="true" aria-label={action.title}>
            <SheetGrip />
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
                {busy ? "Working…" : action.button}
              </button>
            </div>
          </div>
        </div></DialogFocus>,
        document.body
      )}

      {/* Tabs (WAI-ARIA): arrow keys, Home and End move between them, one tab stop, each panel labelled by its tab. */}
      <div className="bd-tabs-wrap">
        <div className="op-tabs bd-tabs" role="tablist" aria-label="Business sections">
          {tabs.map((t, i) => (
            <button
              key={t.slug}
              ref={(el) => { tabRefs.current[i] = el; }}
              id={`bd-tab-${t.slug}`}
              type="button"
              role="tab"
              aria-selected={shown === t.slug}
              aria-controls={`bd-panel-${t.slug}`}
              tabIndex={shown === t.slug ? 0 : -1}
              className={shown === t.slug ? "active" : ""}
              onClick={() => setTab(t.slug)}
              onKeyDown={(event) => {
                const next = tabKeyTarget(event.key, i, tabs.length);
                if (next === null) return;
                event.preventDefault();
                setTab(tabs[next].slug);
                tabRefs.current[next]?.focus();
              }}
            >
              {t.label}
            </button>
          ))}
        </div>
      </div>

      {/* a panel for every tab (each tab's aria-controls has a target); only the open one is shown and mounted, so the
          others start no reads. The panel is a tab stop, so a panel with no controls can still be reached. */}
      {tabs.map((t) => (
        <div key={t.slug} role="tabpanel" id={`bd-panel-${t.slug}`} aria-labelledby={`bd-tab-${t.slug}`} tabIndex={0} hidden={t.slug !== shown}>
          {t.slug === shown && <Panel {...panelProps} />}
        </div>
      ))}
    </section>
  );
}
