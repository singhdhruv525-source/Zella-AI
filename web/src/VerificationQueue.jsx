import { useCallback, useEffect, useRef, useState } from "react";
import { SheetGrip } from "./navigation/SheetGrip";
import { trapTab } from "./useDialogFocus";
import { createPortal } from "react-dom";
import "./OwnerPages.css";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { Pill } from "./OwnerOverview";
import { Icon } from "./BusinessUI";
import { humanize } from "./copy/labels";
import { friendlyError } from "./admin/adminOps";
import MissingDocuments from "./MissingDocuments";

// Every business's verification documents in one place: the business registration and the owner's photo ID
// collected in the Create Business wizard. Files are private; "View" asks the server for a link that works for one
// minute and is written to the audit log. Verifying and rejecting are audited too; a rejection needs a reason, which
// the setup wizard shows next to the document.

const KIND = {
  business_registration: "Business registration",
  owner_identity: "Owner's photo ID",
  tax_registration: "Tax registration",
  professional_license: "Professional license",
};
const STATUS = {
  pending_review: ["warning", "Waiting for review"],
  verified: ["success", "Verified"],
  rejected: ["danger", "Rejected"],
};
const TABS = [["pending_review", "Waiting"], ["rejected", "Rejected"], ["verified", "Verified"], ["all", "All"], ["missing", "Missing documents"]];
const when = (v) => (v ? new Date(v).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" }) : "None");

export default function VerificationQueue({ onOpenBusiness, onOpenSetup }) {
  const [status, setStatus] = useState("pending_review");
  // BIZ-31: opened from a business's page with ?business=<id>: only that business, until "Show all"
  const [business, setBusiness] = useState(() => new URLSearchParams(window.location.search).get("business"));
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState("");
  const [notice, setNotice] = useState("");
  const [rejecting, setRejecting] = useState(null);
  const [reason, setReason] = useState("");
  // Verify asks first (B2-06): business, document, file and what will happen; one request per confirmation.
  const [verifying, setVerifying] = useState(null);
  const [dialogError, setDialogError] = useState("");
  const inFlight = useRef(false);
  const returnFocus = useRef(null);
  const heading = useRef(null);
  const dialog = useRef(null);
  const openDialog = (setter, doc) => { returnFocus.current = document.activeElement; setDialogError(""); setter(doc); };
  const closeDialog = useCallback(() => {
    setVerifying(null); setRejecting(null); setDialogError("");
    const el = returnFocus.current; returnFocus.current = null;
    if (el && typeof el.focus === "function") setTimeout(() => el.focus(), 0);
  }, []);
  useEffect(() => {
    if (!verifying && !rejecting) return undefined;
    const onKey = (e) => {
      if (e.key === "Escape" && !inFlight.current) closeDialog();
      if (e.key !== "Tab" || !dialog.current) return;
      trapTab(e, dialog.current, [...dialog.current.querySelectorAll('button:not(:disabled), input:not(:disabled), [tabindex="0"]')]);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [verifying, rejecting, closeDialog]);

  const request = useRef(0);
  const [refreshes, setRefreshes] = useState(0);   // Refresh also reloads the Missing documents list
  const load = useCallback(async () => {
    const id = ++request.current;
    setLoading(true);
    setError("");
    try {
      // Missing documents has its own list (MissingDocuments); the counts above it still come from the queue
      const queueStatus = status === "missing" ? "pending_review" : status;
      const result = await callOwnerFunction("documents_queue", business ? { status: queueStatus, businessId: business } : { status: queueStatus });
      if (id === request.current) setData(result);
    } catch (err) {
      if (id === request.current) { setData(null); setError(friendlyError(err)); }
    } finally {
      if (id === request.current) setLoading(false);
    }
  }, [status, business]);

  useEffect(() => {
    setData(null);
    load();
    return () => { ++request.current; };
  }, [load]);

  async function view(doc) {
    setError("");
    try {
      const { url } = await callOwnerFunction("document_view", { documentId: doc.id });
      window.open(url, "_blank", "noopener,noreferrer");
    } catch (err) {
      setError(friendlyError(err));
    }
  }

  async function review(doc, next, note = "") {
    if (inFlight.current) return;   // a second click while the first is still saving does nothing
    inFlight.current = true;
    setBusy(doc.id);
    setError("");
    setDialogError("");
    setNotice("");
    try {
      await callOwnerFunction("document_review", { documentId: doc.id, status: next, note });
      setNotice(`${KIND[doc.kind] ?? doc.kind} for ${doc.business_name} marked ${next}.`);
      setReason("");
      inFlight.current = false;
      returnFocus.current = heading.current;
      closeDialog();
      await load();
    } catch (err) {
      // the dialog stays open with the reason; the document's status is whatever the server still has
      setDialogError(friendlyError(err));
    } finally {
      inFlight.current = false;
      setBusy("");
    }
  }

  // One business only when the server says the answer is for it (businessId in the answer). An older server ignores
  // the filter: its list and totals are for every business, so they are not shown as this business's.
  const scopeUnsupported = Boolean(business && data?.available && data.businessId !== business);
  const docs = scopeUnsupported ? [] : data?.documents ?? [];
  const totals = scopeUnsupported ? {} : data?.totals ?? {};

  return (
    <section className="owner-page">
      <div className="owner-page-heading">
        <div>
          <div className="owner-eyebrow">Businesses</div>
          <h1 ref={heading} tabIndex={-1}>Verification</h1>
          <p>Documents that prove each business is real and that the person who registered it may act for it.</p>
        </div>
        <div className="op-heading-actions">
          <button type="button" className="owner-secondary-button" onClick={() => { setRefreshes((n) => n + 1); load(); }} disabled={loading}>{loading ? "Loading…" : <><Icon name="refresh" size="sm" />Refresh</>}</button>
        </div>
      </div>

      {data && !data.available && (
        <div className="wiz-note op-gap" title="Needs the latest Zella Voice update">
          Document review isn't switched on yet. Documents uploaded during setup appear here once it is.
        </div>
      )}
      {error && <div className="owner-form-error op-gap" role="alert">{error}</div>}
      {notice && <div className="vq-notice op-gap" role="status">{notice}</div>}
      {/* The one business filter, with Show all, on every view and also when the list failed to load, so it can always be
          cleared. The text says what is scoped: the queue and the counts, never Missing documents (every business). */}
      {business && (
        <div className="ic-notice op-gap" role="status">
          <span>{status === "missing"
            ? "The counts are for one business. Missing documents lists every business."
            : data?.available && !scopeUnsupported ? `Showing one business: ${docs[0]?.business_name ?? "this business"}.` : "Filtered to one business."}</span>{" "}
          <button type="button" className="owner-secondary-button op-small" onClick={() => {
            setBusiness(null);
            window.history.replaceState(null, "", window.location.pathname);
          }}>Show all</button>
        </div>
      )}

      {data?.available && (
        <>
          <div className="vq-stats op-gap">
            {[["pending_review", "pending_actions"], ["rejected", "block"], ["verified", "verified"]].map(([key, icon]) => (
              <button key={key} type="button" className={`vq-stat ${status === key ? "active" : ""}`} onClick={() => setStatus(key)}>
                <span className={`vq-stat-icon ${STATUS[key][0]}`}><Icon name={icon} /></span>
                <span><strong>{scopeUnsupported ? "?" : totals[key] ?? 0}</strong><small>{STATUS[key][1]}</small></span>
              </button>
            ))}
          </div>

          <div className="op-tabs" role="tablist">
            {TABS.map(([key, label]) => (
              <button key={key} type="button" role="tab" aria-selected={status === key} className={status === key ? "active" : ""} onClick={() => setStatus(key)}>{label}</button>
            ))}
          </div>

          {status === "missing" ? <MissingDocuments onOpenBusiness={onOpenBusiness} refreshKey={refreshes} /> : (
          <section className="owner-panel">
            <div className="owner-table-wrap" tabIndex={0}>
              <table className="owner-table">
                <thead><tr><th>Business</th><th>Document</th><th>Uploaded</th><th>Status</th><th aria-label="Actions" /></tr></thead>
                <tbody>
                  {docs.map((doc) => {
                    const [tone, label] = STATUS[doc.status] ?? ["neutral", doc.status];
                    return (
                      <tr key={doc.id}>
                        <td>
                          <div className="owner-business-cell">
                            <button type="button" className="vq-link" onClick={() => onOpenBusiness(doc.business_id)}>{doc.business_name}</button>
                            <span>{doc.business_status ? humanize(doc.business_status) : ""}</span>
                          </div>
                        </td>
                        <td>
                          <div className="owner-business-cell">
                            <strong>{KIND[doc.kind] ?? doc.kind}</strong>
                            <span>{doc.file_name}, {Math.max(1, Math.round(doc.size_bytes / 1024))} KB</span>
                          </div>
                        </td>
                        <td>{when(doc.created_at)}</td>
                        <td>
                          <Pill tone={tone}>{label}</Pill>
                          {doc.status === "rejected" && doc.review_note && <div className="op-muted vq-note">{doc.review_note}</div>}
                        </td>
                        <td>
                          <div className="vq-actions">
                            <button type="button" className="owner-secondary-button" onClick={() => view(doc)}>View</button>
                            {doc.status !== "verified" && <button type="button" className="owner-primary-button" disabled={busy === doc.id} onClick={() => openDialog(setVerifying, doc)}>Verify</button>}
                            {doc.status !== "rejected" && <button type="button" className="bd-danger-button" disabled={busy === doc.id} onClick={() => { openDialog(setRejecting, doc); setReason(""); }}>Reject</button>}
                            {doc.status === "rejected" && <button type="button" className="owner-secondary-button" onClick={() => onOpenSetup(doc.business_id)}>Ask for a new copy</button>}
                          </div>
                        </td>
                      </tr>
                    );
                  })}
                  {!docs.length && (
                    <tr><td colSpan={5}><div className="op-empty">{loading ? "Loading documents…" : !data ? "Couldn't load this list. Try again with Refresh, or reload the page." : scopeUnsupported ? "Showing one business's documents needs the latest Zella Voice update. Use Show all for now." : status === "pending_review" ? "Nothing waiting for review." : "No documents here."}</div></td></tr>
                  )}
                </tbody>
              </table>
            </div>
          </section>
          )}
        </>
      )}

      {rejecting && createPortal(
        <div className="owner-modal-overlay" onMouseDown={(e) => e.target === e.currentTarget && !busy && closeDialog()}>
          <div className="bd-confirm owner-modal danger" ref={dialog} tabIndex={-1} role="dialog" aria-modal="true" aria-label="Reject document">
            <SheetGrip />
            <div className="zs-dialog-head">
              <span className="zs-dialog-icon"><Icon name="gpp_bad" /></span>
              <h3>Reject {KIND[rejecting.kind] ?? "document"}?</h3>
            </div>
            <p>{rejecting.business_name} can't finish setup until a new copy is uploaded. Say what's wrong so it can be fixed.</p>
            {dialogError && <div className="owner-form-error" role="alert">{dialogError}</div>}
            <label className="owner-field">
              <span>Reason (shown in setup, kept in the audit log)</span>
              <input value={reason} maxLength={500} onChange={(e) => setReason(e.target.value)} placeholder="For example, The name doesn't match the business" autoFocus />
            </label>
            <div className="ic-actions">
              <button type="button" className="owner-secondary-button" onClick={closeDialog} disabled={Boolean(busy)}>Go back</button>
              <button type="button" className="bd-danger-button" disabled={!reason.trim() || Boolean(busy)} onClick={() => review(rejecting, "rejected", reason.trim())}>
                {busy ? "Rejecting…" : "Reject document"}
              </button>
            </div>
          </div>
        </div>,
        document.body
      )}

      {verifying && createPortal(
        <div className="owner-modal-overlay" onMouseDown={(e) => e.target === e.currentTarget && !busy && closeDialog()}>
          <div className="bd-confirm owner-modal" ref={dialog} tabIndex={-1} role="dialog" aria-modal="true" aria-labelledby="vq-verify-title" aria-describedby="vq-verify-body" data-dialog="verify">
            <SheetGrip />
            <div className="zs-dialog-head">
              <span className="zs-dialog-icon"><Icon name="verified" /></span>
              <h3 id="vq-verify-title">Mark this document verified?</h3>
            </div>
            <div id="vq-verify-body">
              <dl className="vq-confirm-facts">
                <dt>Business</dt><dd>{verifying.business_name}</dd>
                <dt>Document</dt><dd>{KIND[verifying.kind] ?? verifying.kind}</dd>
                <dt>File</dt><dd>{verifying.file_name}</dd>
                <dt>Action</dt><dd>Mark as verified{verifying.status === "rejected" ? " (replaces the earlier rejection)" : ""}</dd>
              </dl>
              <p className="op-muted">Only confirm after opening the file and checking it. This is recorded in the audit log.</p>
            </div>
            {dialogError && <div className="owner-form-error" role="alert">{dialogError}</div>}
            <div className="ic-actions">
              <button type="button" className="owner-secondary-button" onClick={closeDialog} disabled={Boolean(busy)} autoFocus>Cancel</button>
              <button type="button" className="owner-primary-button" disabled={Boolean(busy)} onClick={() => review(verifying, "verified")}>
                {busy ? "Verifying…" : "Confirm: mark verified"}
              </button>
            </div>
          </div>
        </div>,
        document.body
      )}
    </section>
  );
}
