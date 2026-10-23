import { useEffect, useState } from "react";
import "./OwnerDashboard.css";
import "./OwnerPages.css";
import { supabase } from "./supabase";

// Page opened from the "Book it here" link in a waitlist text (/w/<code>).
// The customer isn't signed in. The private code identifies one offer, and the calendar
// re-checks the time when they accept, so a time that was taken is never double-booked.

async function call(token, action) {
  const { data, error } = await supabase.functions.invoke("reschedule-appointment", { body: { token, action } });
  if (error) throw new Error("Something went wrong. Please try again.");
  return data;
}

const fmt = (value, tz, options) => new Intl.DateTimeFormat("en-US", { timeZone: tz, ...options }).format(new Date(value));
const longDay = (value, tz) => fmt(value, tz, { weekday: "long", month: "long", day: "numeric" });
const clock = (value, tz) => fmt(value, tz, { hour: "numeric", minute: "2-digit" });

const PROBLEMS = {
  invalid: { title: "This link isn't valid", body: "Please open the full link from your message, or contact the business." },
  gone: { title: "This time is no longer available", body: "It may have been taken, or the offer ran out. You're still on the waiting list, and we'll text you if another time opens." },
  booked: { title: "You're already booked", body: "This time has already been booked for you." },
};

export default function WaitlistOffer() {
  const token = (window.location.pathname.match(/^\/w\/([0-9a-fA-F]{64})\/?$/) || [])[1] || "";
  const [info, setInfo] = useState(null);
  const [problem, setProblem] = useState(token ? "" : "invalid");
  const [error, setError] = useState("");
  const [working, setWorking] = useState(false);
  const [done, setDone] = useState(null);

  useEffect(() => {
    if (!token) return;
    let active = true;
    call(token, "offer_lookup")
      .then((res) => {
        if (!active) return;
        if (res.ok) setInfo(res);
        else {
          setProblem(res.reason || "invalid");
          if (res.business) setInfo({ business: res.business });
        }
      })
      .catch((err) => active && setError(err.message));
    return () => {
      active = false;
    };
  }, [token]);

  async function answer(accept) {
    setWorking(true);
    setError("");
    try {
      const res = await call(token, accept ? "offer_accept" : "offer_decline");
      if (res.ok) setDone(res.result);
      else setProblem(res.reason || "invalid");
    } catch (err) {
      setError(err.message);
    } finally {
      setWorking(false);
    }
  }

  const tz = info?.timezone || "America/New_York";
  const stop = PROBLEMS[problem];

  return (
    <main className="cp-page">
      <section className="cp-card">
        {info?.business && <div className="cp-brand"><span>{info.business}</span></div>}
        {!info && !stop && !error && <p className="op-muted">Checking your link...</p>}
        {error && !info?.offer && (
          <>
            <h1>Something went wrong</h1>
            <p>{error}</p>
          </>
        )}
        {stop && (
          <>
            <div className="cp-icon">!</div>
            <h1>{stop.title}</h1>
            <p>{stop.body}</p>
          </>
        )}
        {done === "booked" && (
          <>
            <div className="cp-icon ok">✓</div>
            <h1>You're booked</h1>
            <p>{info.business} will see you on {longDay(info.offer.start, tz)} at {clock(info.offer.start, tz)}. You'll get a reminder before your visit.</p>
          </>
        )}
        {done === "declined" && (
          <>
            <div className="cp-icon ok">✓</div>
            <h1>No problem</h1>
            <p>You're still on the waiting list, and we'll text you if another time opens.</p>
          </>
        )}
        {info?.offer && !stop && !done && (
          <>
            <h1>A time just opened</h1>
            <p>
              {info.offer.title}: <strong>{longDay(info.offer.start, tz)} at {clock(info.offer.start, tz)}</strong>.
              We're holding it for you until {clock(info.offer.expires_at, tz)}.
            </p>
            {error && <div className="owner-form-error">{error}</div>}
            <button type="button" className="owner-primary-button cp-button" disabled={working} onClick={() => answer(true)}>
              {working ? "Saving..." : "Book this time"}
            </button>
            <button type="button" className="rs-chip" style={{ width: "100%", marginTop: 10 }} disabled={working} onClick={() => answer(false)}>
              No thanks
            </button>
          </>
        )}
      </section>
    </main>
  );
}
