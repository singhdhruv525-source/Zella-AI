import { useCallback, useEffect, useState } from "react";
import "./OwnerDashboard.css";
import "./OwnerPages.css";
import { supabase } from "./supabase";

// Public status page (/status): is Zella working right now. Readable without signing in. Shows only the state of each
// part and incidents a Zella admin published, in the words they wrote (zella_public_status, sql/zella_status.sql).
const STATES = {
  operational: ["ok", "Working"],
  degraded: ["warn", "Slower than usual"],
  outage: ["down", "Not working"],
  unknown: ["", "Not monitored yet"],
};
const OVERALL = {
  operational: "Everything is working",
  degraded: "Some things are slower than usual",
  outage: "Part of Zella isn't working right now",
};
const when = (v) => (v ? new Date(v).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" }) : "");

export default function StatusPage() {
  const [state, setState] = useState({ loading: true });
  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc("zella_public_status");
    setState(error ? { error: true } : { data });
  }, []);
  useEffect(() => {
    load();
    const timer = setInterval(load, 60000);
    return () => clearInterval(timer);
  }, [load]);

  const d = state.data;
  const overall = state.error ? "outage" : d?.overall;
  return (
    <main className="cp-page">
      <section className="cp-card stp-card">
        <div className="cp-brand"><span>Zella<span className="cp-ai">AI</span> status</span></div>
        {state.loading && <p>Checking…</p>}
        {(d || state.error) && (
          <div className={`stp-overall ${STATES[overall]?.[0] ?? ""}`} role="status">
            <span className="stp-dot" aria-hidden="true" />
            <strong>{state.error ? "We can't reach Zella right now" : OVERALL[overall]}</strong>
          </div>
        )}
        {state.error && <p>The app or its database isn't answering. This page checks again every minute.</p>}
        {d && (
          <>
            <ul className="stp-list">
              {d.components.map((c) => {
                const [tone, label] = STATES[c.state] ?? STATES.unknown;
                return (
                  <li key={c.key}>
                    <span>{c.label}</span>
                    <span className={`stp-state ${tone}`}><span className="stp-dot" aria-hidden="true" />{label}</span>
                  </li>
                );
              })}
            </ul>
            <h2 className="stp-h2">Incidents</h2>
            {!d.incidents.length ? <p>No incidents in the last 14 days.</p> : (
              <ul className="stp-incidents">
                {d.incidents.map((i) => (
                  <li key={`${i.started_at}-${i.title}`}>
                    <strong>{i.title}</strong>
                    <span className={`stp-state ${i.status === "open" ? "warn" : "ok"}`}>{i.status === "open" ? "Ongoing" : "Fixed"}</span>
                    {i.message && <p>{i.message}</p>}
                    <small>Started {when(i.started_at)}{i.resolved_at ? ` · fixed ${when(i.resolved_at)}` : ""}</small>
                  </li>
                ))}
              </ul>
            )}
            <p className="cp-small">Updated {when(d.generated_at)}. Checks again every minute.</p>
          </>
        )}
      </section>
    </main>
  );
}
