import { useEffect, useState } from "react";
import "./OwnerDashboard.css";
import "./OwnerPages.css";
import { supabase } from "./supabase";

// Page opened from the "continue my plan" email. The owner isn't signed in;
// the signed token in the link identifies the business and cancellation.

async function callContinue(token, action) {
  const { data, error } = await supabase.functions.invoke("continue-plan", {
    body: { token, action },
  });
  if (error) {
    let message = "Something went wrong. Please try again.";
    try {
      const body = await error.context?.json();
      if (body?.error) message = body.error;
    } catch {
      // Keep the default message.
    }
    throw new Error(message);
  }
  return data;
}

function formatDay(value) {
  return new Date(value).toLocaleDateString(undefined, {
    weekday: "long", month: "long", day: "numeric", year: "numeric",
  });
}

const MESSAGES = {
  continued: (name) => ({
    title: "Your plan continues",
    body: `Thanks for staying with Zella. ${name} will keep running as normal, including your AI receptionist.`,
  }),
  already_continued: (name) => ({
    title: "You're all set",
    body: `${name} isn't scheduled to stop, so there's nothing more to do.`,
  }),
  ended: (name) => ({
    title: "This plan has already ended",
    body: `${name}'s membership has ended. To start again, reply to the email or contact the Zella team.`,
  }),
  outdated: () => ({
    title: "This link is out of date",
    body: "There's a newer email about your plan. Please use the link in that email.",
  }),
  invalid: () => ({
    title: "This link isn't valid",
    body: "Please check you opened the full link from your email, or contact the Zella team.",
  }),
};

export default function ContinuePlan() {
  const token = new URLSearchParams(window.location.search).get("token") || "";
  const [state, setState] = useState({ status: token ? "loading" : "invalid" });
  const [working, setWorking] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    if (!token) return;
    let active = true;
    callContinue(token, "preview")
      .then((data) => active && setState(data))
      .catch((err) => active && setState({ status: "error", message: err.message }));
    return () => {
      active = false;
    };
  }, [token]);

  async function confirm() {
    setWorking(true);
    setError("");
    try {
      setState(await callContinue(token, "continue"));
    } catch (err) {
      setError(err.message);
    } finally {
      setWorking(false);
    }
  }

  const done = MESSAGES[state.status]?.(state.businessName);

  return (
    <main className="cp-page">
      <section className="cp-card">
        <div className="cp-brand">
          <div className="owner-brand-mark">Z</div>
          <span>zella<span className="cp-ai">ai</span></span>
        </div>

        {state.status === "loading" && <p className="op-muted">Checking your link...</p>}

        {state.status === "error" && (
          <>
            <h1>Something went wrong</h1>
            <p>{state.message}</p>
          </>
        )}

        {state.status === "scheduled" && (
          <>
            <div className="owner-eyebrow">YOUR ZELLA PLAN</div>
            <h1>Keep {state.businessName} running?</h1>
            <p>
              Your plan is set to end on <strong>{formatDay(state.cancelAt)}</strong>. After that, your AI
              receptionist stops answering calls and automations stop.
            </p>
            {error && <div className="owner-form-error">{error}</div>}
            <button type="button" className="owner-primary-button cp-button" onClick={confirm} disabled={working}>
              {working ? "Saving..." : "Continue my plan"}
            </button>
            <p className="cp-small">Don't want to continue? You don't need to do anything. Your plan ends on the date above.</p>
          </>
        )}

        {done && (
          <>
            <div className={`cp-icon ${state.status === "continued" || state.status === "already_continued" ? "ok" : ""}`}>
              {state.status === "continued" || state.status === "already_continued" ? "✓" : "!"}
            </div>
            <h1>{done.title}</h1>
            <p>{done.body}</p>
          </>
        )}
      </section>
    </main>
  );
}
