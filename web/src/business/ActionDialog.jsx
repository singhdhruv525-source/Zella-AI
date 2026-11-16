// A confirm dialog for one support action on a business's page: a title, what will happen, an optional reason (with
// its length rule), optional extra fields, and the action itself. Errors stay in the dialog.
import { useState } from "react";
import { createPortal } from "react-dom";
import { DialogFocus } from "../useDialogFocus";
import { Icon } from "../BusinessUI";
import { friendlyError } from "../admin/adminOps";

export default function ActionDialog({ title, body, button, danger, reason, children, ready = true, onRun, onDone, onClose }) {
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const min = reason?.min ?? 0;
  const short = reason && text.trim().length < min;
  async function run() {
    setBusy(true);
    setError("");
    try {
      const result = await onRun(text.trim());
      onDone?.(result);
    } catch (err) {
      setError(/Unknown action/i.test(err?.message ?? "") ? "Not available yet. The Zella Voice update with this action isn't live." : friendlyError(err));
    } finally {
      setBusy(false);
    }
  }
  return createPortal(
    <DialogFocus onClose={null} busy={busy}>
      <div className="owner-modal-overlay" onMouseDown={(e) => e.target === e.currentTarget && !busy && onClose()}>
        <div className={`bd-confirm owner-modal ${danger ? "danger" : ""}`} role="dialog" aria-modal="true" aria-label={title}>
          <div className="zs-dialog-head">
            <span className="zs-dialog-icon"><Icon name={danger ? "warning" : "task_alt"} /></span>
            <h3>{title}</h3>
          </div>
          {body && <p>{body}</p>}
          {children}
          {reason && (
            <label className="owner-field">
              <span>{reason.label ?? "Reason"} (at least {min} characters, kept in the audit log)</span>
              <textarea value={text} onChange={(e) => setText(e.target.value)} maxLength={reason.max ?? 300} rows={3} />
            </label>
          )}
          {error && <div className="owner-form-error" role="alert">{error}</div>}
          <div className="ic-actions">
            <button type="button" className="owner-secondary-button" onClick={onClose} disabled={busy}>Go back</button>
            <button type="button" className={danger ? "bd-danger-button" : "owner-primary-button"} onClick={run} disabled={busy || short || !ready}>
              {busy ? "Working…" : button}
            </button>
          </div>
        </div>
      </div>
    </DialogFocus>,
    document.body,
  );
}
