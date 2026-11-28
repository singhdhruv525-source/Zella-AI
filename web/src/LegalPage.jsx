import { useEffect, useState } from "react";
import "./OwnerDashboard.css";
import "./OwnerPages.css";
import { supabase } from "./supabase";

// Public /privacy and /terms pages: the version in effect (zella_legal_current, sql/zella_privacy_retention.sql). Until a
// version is published the draft is shown, clearly marked as a draft for owner and legal review.
const NAMES = { privacy: "Privacy policy", terms: "Terms of service" };

export default function LegalPage({ kind }) {
  const [state, setState] = useState({ loading: true });
  useEffect(() => {
    let live = true;
    supabase.rpc("zella_legal_current", { p_kind: kind }).then(({ data, error }) => { if (live) setState(error ? { error: true } : { data }); });
    return () => { live = false; };
  }, [kind]);
  const d = state.data;
  return (
    <main className="cp-page">
      <section className="cp-card stp-card">
        <div className="cp-brand"><span>Zella <span className="cp-ai">Voice</span></span></div>
        <h1 className="stp-h2">{d?.title ?? NAMES[kind]}</h1>
        {state.loading && <p>Loading…</p>}
        {state.error && <p>This page can't be loaded right now. Try again in a minute.</p>}
        {!state.loading && !state.error && !d && <p>The {NAMES[kind].toLowerCase()} isn't available yet.</p>}
        {d?.draft && <p className="cp-small" role="note"><strong>Draft.</strong> This version is still being reviewed and isn't in effect yet.</p>}
        {d && <div className="legal-body">{d.body}</div>}
        {d && !d.draft && d.effective_at && <p className="cp-small">In effect from {new Date(d.effective_at).toLocaleDateString(undefined, { dateStyle: "long" })}. Version {d.version}.</p>}
        <p className="cp-small"><a href="/privacy">Privacy policy</a> · <a href="/terms">Terms of service</a></p>
      </section>
    </main>
  );
}
