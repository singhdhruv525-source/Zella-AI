import { useEffect, useRef, useState } from "react";
import "./OwnerDashboard.css";
import "./OwnerPages.css";
import { supabase } from "./supabase";

// Page opened from the unsubscribe link at the bottom of marketing emails (/u/<code>).
// The customer isn't signed in. The private code in the link identifies one person at one business.
export default function Unsubscribe() {
  const token = (window.location.pathname.match(/^\/u\/([0-9a-fA-F]{32})\/?$/) || [])[1] || "";
  const [state, setState] = useState(token ? "ready" : "invalid");
  const [business, setBusiness] = useState("");
  // once the person presses Unsubscribe, a late answer from the lookup must not replace the save's result
  const saving = useRef(false);

  useEffect(() => {
    if (!token) return;
    supabase.rpc("zella_unsubscribe_lookup", { p_token: token }).then(({ data, error }) => {
      if (saving.current) { if (data?.ok) setBusiness((b) => b || data.business || ""); return; }
      // Zella Voice not answering is not the same as a wrong link: the person can still unsubscribe once it answers.
      if (error) setState("unreachable");
      else if (data?.ok) setBusiness(data.business || "");
      else if (data?.reason === "busy") setState("busy");   // the link is fine; it was opened too often in a short time
      else setState("invalid");
    });
  }, [token]);

  async function confirm() {
    saving.current = true;
    setState("working");
    const { data, error } = await supabase.rpc("zella_unsubscribe_email", { p_token: token });
    if (error || !data?.ok) { setState("error"); return; }
    setBusiness(data.business || business);
    setState("done");
  }

  return (
    <main className="cp-page">
      <section className="cp-card">
        {business && <div className="cp-brand"><span>{business}</span></div>}
        {state === "invalid" && (<><div className="cp-icon">!</div><h1>This link isn't valid</h1><p>Open the full link from your email, or reply to the email and ask to be removed.</p></>)}
        {state === "unreachable" && (<><h1>We can't reach Zella Voice right now</h1><p>Your link looks fine. Try again in a few minutes, or reply to the email and ask to be removed.</p><button type="button" className="owner-primary-button cp-button" onClick={() => window.location.reload()}>Try again</button></>)}
        {state === "busy" && (<><h1>Stop marketing emails?</h1><p>This link was opened many times in a short while, so we can't show the business name right now. You can still unsubscribe.</p><button type="button" className="owner-primary-button cp-button" onClick={confirm}>Unsubscribe</button></>)}
        {state === "error" && (<><h1>We couldn't confirm that you're unsubscribed</h1><p>Try again, or reply to the email and ask to be removed.</p><button type="button" className="owner-primary-button cp-button" onClick={confirm}>Try again</button></>)}
        {(state === "ready" || state === "working") && (
          <>
            <h1>Stop marketing emails?</h1>
            <p>{business ? `You won't get marketing emails from ${business} anymore.` : "You won't get marketing emails anymore."} Messages about your own bookings can still reach you.</p>
            <button type="button" className="owner-primary-button cp-button" disabled={state === "working"} onClick={confirm}>
              {state === "working" ? "Saving…" : "Unsubscribe"}
            </button>
          </>
        )}
        {state === "done" && (<><div className="cp-icon ok">✓</div><h1>You're unsubscribed</h1><p>{business || "The business"} won't send you marketing emails anymore.</p></>)}
      </section>
    </main>
  );
}
