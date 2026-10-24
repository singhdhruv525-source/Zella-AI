import { useEffect, useState } from "react";
import "./OwnerDashboard.css";
import "./OwnerPages.css";
import { supabase } from "./supabase";

// Page opened from the unsubscribe link at the bottom of marketing emails (/u/<code>).
// The customer isn't signed in. The private code in the link identifies one person at one business.
export default function Unsubscribe() {
  const token = (window.location.pathname.match(/^\/u\/([0-9a-fA-F]{32})\/?$/) || [])[1] || "";
  const [state, setState] = useState(token ? "ready" : "invalid");
  const [business, setBusiness] = useState("");

  useEffect(() => {
    if (!token) return;
    supabase.rpc("zella_unsubscribe_lookup", { p_token: token }).then(({ data }) => {
      if (data?.ok) setBusiness(data.business || "");
      else setState("invalid");
    });
  }, [token]);

  async function confirm() {
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
        {state === "invalid" && (<><div className="cp-icon">!</div><h1>This link isn't valid</h1><p>Please open the full link from your email, or reply to the email and ask to be removed.</p></>)}
        {state === "error" && (<><h1>Something went wrong</h1><p>Please try again, or reply to the email and ask to be removed.</p><button type="button" className="owner-primary-button cp-button" onClick={confirm}>Try again</button></>)}
        {(state === "ready" || state === "working") && (
          <>
            <h1>Stop marketing emails?</h1>
            <p>{business ? `You will no longer get marketing emails from ${business}.` : "You will no longer get marketing emails."} Messages about your own bookings can still reach you.</p>
            <button type="button" className="owner-primary-button cp-button" disabled={state === "working"} onClick={confirm}>
              {state === "working" ? "Saving..." : "Unsubscribe"}
            </button>
          </>
        )}
        {state === "done" && (<><div className="cp-icon ok">✓</div><h1>You're unsubscribed</h1><p>{business || "The business"} won't send you marketing emails any more.</p></>)}
      </section>
    </main>
  );
}
