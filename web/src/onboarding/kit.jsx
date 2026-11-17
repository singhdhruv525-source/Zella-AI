import { useRef, useState } from "react";
import { Icon } from "../BusinessUI";
import { errorWords } from "./steps";

// Small parts every onboarding screen shares: the loading, error, not ready and empty states, each in words, and a
// button that runs a server call and shows what went wrong.

export function Loading({ text = "Loading…" }) {
  return <div className="zob-state" role="status"><span className="zob-spinner" aria-hidden="true" /><span>{text}</span></div>;
}

export function NotReady({ onRetry, children }) {
  return (
    <div className="zob-state zob-state-box" role="status">
      <Icon name="construction" />
      <div>
        <strong>This step isn't ready yet</strong>
        <p>{children ?? "The Zella Voice team is still finishing this part. Choose Finish later and we'll pick up right here when it's ready."}</p>
        {onRetry && <button type="button" className="ba-btn sm" onClick={onRetry}>Check again</button>}
      </div>
    </div>
  );
}

export function Failed({ error, onRetry, title = "Something didn't load" }) {
  return (
    <div className="zob-state zob-state-box error" role="alert">
      <Icon name="error" />
      <div>
        <strong>{title}</strong>
        <p>{errorWords(error)}</p>
        {onRetry && <button type="button" className="ba-btn sm" onClick={onRetry}>Try again</button>}
      </div>
    </div>
  );
}

export function EmptyNote({ title, children }) {
  return (
    <div className="zob-state zob-state-box" role="status">
      <Icon name="hourglass_empty" />
      <div><strong>{title}</strong>{children && <p>{children}</p>}</div>
    </div>
  );
}

// Runs one server call at a time and keeps its error in words. run(fn) returns true when it worked.
export function useAction() {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const last = useRef(null);
  async function run(fn) {
    if (busy) return false;
    setBusy(true); setError(""); last.current = null;
    try { await fn(); return true; }
    catch (err) { last.current = err; setError(errorWords(err)); return false; }
    finally { setBusy(false); }
  }
  return { busy, error, setError, run, get lastError() { return last.current; } };
}

// Several reads of the same status can overlap (a timer and Check again): start() numbers each one, and only the
// latest one's answer may be shown, so an older answer that arrives last never overwrites a newer one.
export function useLatest() {
  const n = useRef(0);
  return { start: () => ++n.current, isLatest: (ticket) => ticket === n.current };
}

export function ErrorText({ children }) {
  return children ? <p className="ba-error" role="alert">{children}</p> : null;
}

// The main button row at the foot of a screen.
export function Actions({ children }) {
  return <div className="zob-actions">{children}</div>;
}
