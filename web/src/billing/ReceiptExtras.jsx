import { useId } from "react";
import { Icon } from "../BusinessUI";
import { formatMoney } from "./checkoutMachine";
import { addonAbout, addonName, addonShort, groupOffer } from "./addons.js";
import { TERMS_PREFIX } from "../../supabase/functions/_shared/paymentConsent.js";

// The pieces the glass checkout's receipt and Pay button add for the owner decisions of 27 Nov 2026 (docs/DESIGN_SYSTEM.md,
// Glass checkout): the add ons as tick box rows under the receipt, the required "I agree" box above Pay, and, on Pay
// now, each add on's progress once the plan payment is confirmed.

// Add ons: a real checkbox per row, its label the whole row (name, one line description, "$29 one time"), grouped by
// type. Ticking adds a receipt line and changes the total (announced politely by the receipt).
export function AddonPicker({ offer, selected, onChange, locked = false, note }) {
  const groups = groupOffer(offer);
  const base = useId();
  if (!groups.length) return null;
  return (
    <section className="zgc-addons" aria-labelledby={`${base}-t`}>
      <h4 id={`${base}-t`}>Add ons</h4>
      <p className="zgc-addons-note">One time, for this month.</p>
      {groups.map((g) => (
        <fieldset key={g.resource} className="zgc-addon-group" disabled={locked}>
          <legend>{g.title}</legend>
          {g.items.map((a) => {
            const id = `${base}-${a.code}`;
            const on = selected.includes(a.code);
            return (
              <label key={a.code} htmlFor={id} className={`zgc-addon${on ? " is-on" : ""}`}>
                <input id={id} type="checkbox" checked={on} onChange={(e) => onChange(a.code, e.target.checked)} aria-describedby={`${id}-d`} />
                <span className="zgc-addon-box" aria-hidden="true"><Icon name="check" size="sm" /></span>
                <span className="zgc-addon-text">
                  <span className="zgc-addon-name">{addonName(a)}</span>
                  <span className="zgc-addon-about" id={`${id}-d`}>{addonAbout(a)}</span>
                </span>
                <span className="zgc-addon-price">{formatMoney(a.price_cents, "usd")} one time</span>
              </label>
            );
          })}
        </fieldset>
      ))}
    </section>
  );
}

// "I agree": a real, labelled checkbox, unticked by default. The words are the server's figures, built by
// paymentConsent.js; "Terms" and "Privacy Policy" open in a new tab. The sha256 of exactly these words goes to the server.
export function ConsentBox({ text, agreed, onChange, error, id }) {
  if (!text) return null;
  const rest = text.startsWith(TERMS_PREFIX) ? text.slice(TERMS_PREFIX.length) : null;
  return (
    <div className={`zgc-consent${error ? " has-error" : ""}`}>
      <input id={id} type="checkbox" checked={agreed} onChange={(e) => onChange(e.target.checked)} aria-describedby={error ? `${id}-e` : undefined} aria-invalid={error ? "true" : undefined} />
      <label htmlFor={id}>
        {rest === null ? text : <>I agree to the <a className="ba-link" href="/terms" target="_blank" rel="noopener noreferrer">Terms<span className="zob-sr"> (opens in a new tab)</span></a> and <a className="ba-link" href="/privacy" target="_blank" rel="noopener noreferrer">Privacy Policy<span className="zob-sr"> (opens in a new tab)</span></a>{rest}</>}
      </label>
      {/* role alert: the live region that announces pressing Pay without ticking */}
      <p className="zgc-consent-error" id={`${id}-e`} role="alert">{error || ""}</p>
    </div>
  );
}

// Pay now, after the server confirmed the plan payment: each add on bought separately, its own state, and Try again for
// that pack only. The plan payment is never charged again.
const STEP_WORDS = { todo: "Adding", adding: "Adding", added: "Added" };
export function AddonProgress({ items, onRetry, busy }) {
  if (!items?.length) return null;
  const failed = items.filter((a) => a.step === "failed");
  return (
    <section className="zgc-addon-progress" aria-labelledby="zgc-addon-progress-t">
      <h3 id="zgc-addon-progress-t">Add ons</h3>
      <p className="zob-sr" aria-live="polite" role="status">{failed.length ? `Plan paid. ${failed.map((a) => addonShort(a)).join(" and ")} not added.` : items.every((a) => a.step === "added") ? "Your add ons are added." : ""}</p>
      <ul className="zgc-addon-steps">
        {items.map((a) => (
          <li key={a.code} className={`zgc-addon-step is-${a.step}`}>
            <span className="ba-icon" aria-hidden="true">{a.step === "added" ? "task_alt" : a.step === "failed" ? "error" : "hourglass_top"}</span>
            <div>
              <strong>{a.step === "failed" ? `Plan paid. ${addonShort(a)} not added` : `${addonName(a)}: ${STEP_WORDS[a.step]}`}</strong>
              <span className="zob-hint">{a.step === "failed" ? (a.words ?? "You weren't charged for this add on. Your plan is paid.") : `${formatMoney(a.price_cents, "usd")} one time`}</span>
            </div>
            {a.step === "failed" && <button type="button" className="ba-btn sm" disabled={busy} onClick={() => onRetry(a)}>Try again</button>}
          </li>
        ))}
      </ul>
    </section>
  );
}
