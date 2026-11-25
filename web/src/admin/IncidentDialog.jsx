import { useState } from "react";
import { SheetGrip } from "../navigation/SheetGrip";
import { createPortal } from "react-dom";
import { Icon } from "../BusinessUI";
import { useDialogFocus } from "../useDialogFocus";

// OPS-11: the incident panel's confirmations and questions, in a dialog instead of window.confirm / window.prompt.
// With `field`, the person writes text (nothing prefilled) of at least field.min characters, passed to onConfirm.
// onConfirm may return a string to keep the dialog open, showing that message when it is not empty (an empty string keeps it open to show what changed, for example a similar open incident).
export default function IncidentDialog({ title, icon = "campaign", children, field, confirmLabel = "Confirm", onConfirm, onClose }) {
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const dialogRef = useDialogFocus(onClose, busy);
  async function go() {
    if (field && text.trim().length < (field.min ?? 1)) return setError(field.tooShort ?? "Write a little more.");
    setBusy(true); setError("");
    try {
      const keep = await onConfirm(text.trim());
      if (typeof keep === "string") { setError(keep); setBusy(false); return; }
      onClose();
    } catch (e) { setError(e?.message ?? String(e)); setBusy(false); }
  }
  return createPortal(
    <div className="owner-modal-overlay" onMouseDown={(e) => e.target === e.currentTarget && !busy && onClose()}>
      <div ref={dialogRef} tabIndex={-1} className="bd-confirm owner-modal" role="dialog" aria-modal="true" aria-label={title}>
        <SheetGrip />
        <div className="ao-dialog-head">
          <span className="ao-dialog-icon"><Icon name={icon} /></span>
          <h3>{title}</h3>
        </div>
        <div className="ao-dialog-body">{children}</div>
        {field && (
          <label className="owner-field ao-reason">
            <span>{field.label}</span>
            <textarea rows={3} value={text} maxLength={field.max ?? 500} onChange={(e) => setText(e.target.value)} placeholder={field.placeholder ?? ""} autoFocus />
          </label>
        )}
        {error && <div className="owner-form-error" role="alert">{error}</div>}
        <div className="ic-actions">
          <button type="button" className="owner-secondary-button" onClick={onClose} disabled={busy}>Cancel</button>
          <button type="button" className="owner-primary-button" onClick={go} disabled={busy}>{busy ? "Working…" : confirmLabel}</button>
        </div>
      </div>
    </div>,
    document.body,
  );
}
