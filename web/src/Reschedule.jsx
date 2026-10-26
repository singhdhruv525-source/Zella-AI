import { useEffect, useMemo, useState } from "react";
import "./OwnerDashboard.css";
import "./OwnerPages.css";
import { supabase } from "./supabase";

// Page opened from the Reschedule link in appointment texts and emails (/r/<code>).
// The customer isn't signed in. The private code in the link identifies one appointment.

async function call(token, action, extra = {}) {
  const { data, error } = await supabase.functions.invoke("reschedule-appointment", {
    body: { token, action, ...extra },
  });
  if (error) {
    // Too many tries in a minute (the link's rate limit) gets its own plain message.
    const status = error.context?.status;
    throw new Error(status === 429 ? "Too many tries. Please wait a minute and try again." : "Something went wrong. Please try again.");
  }
  return data;
}

const fmt = (value, tz, options) => new Intl.DateTimeFormat("en-US", { timeZone: tz, ...options }).format(new Date(value));
const dayKey = (value, tz) => fmt(value, tz, { year: "numeric", month: "2-digit", day: "2-digit" });
const longDay = (value, tz) => fmt(value, tz, { weekday: "long", month: "long", day: "numeric" });
const shortDay = (value, tz) => fmt(value, tz, { weekday: "short", month: "short", day: "numeric" });
const clock = (value, tz) => fmt(value, tz, { hour: "numeric", minute: "2-digit" });

const PROBLEMS = {
  invalid: {
    title: "This link isn't valid",
    body: "Please open the full link from your message, or contact the business.",
  },
  not_available: {
    title: "This appointment can't be changed here",
    body: "It may have been cancelled or already finished. Please contact the business to book a new time.",
  },
  past: {
    title: "This appointment has already passed",
    body: "Please contact the business to book a new time.",
  },
};

export default function Reschedule() {
  const token = (window.location.pathname.match(/^\/r\/([0-9a-fA-F]{64})\/?$/) || [])[1] || "";
  const [info, setInfo] = useState(null);
  const [slots, setSlots] = useState([]);
  const [problem, setProblem] = useState(token ? "" : "invalid");
  const [error, setError] = useState("");
  const [day, setDay] = useState("");
  const [picked, setPicked] = useState("");
  const [working, setWorking] = useState(false);
  const [done, setDone] = useState(null);

  useEffect(() => {
    if (!token) return;
    let active = true;
    (async () => {
      try {
        const looked = await call(token, "lookup");
        if (!active) return;
        if (!looked.ok) {
          setProblem(looked.reason || "invalid");
          if (looked.business) setInfo({ business: looked.business });
          return;
        }
        const free = await call(token, "slots");
        if (!active) return;
        setInfo(looked);
        setSlots(free.ok ? free.slots : []);
      } catch (err) {
        if (active) setError(err.message);
      }
    })();
    return () => {
      active = false;
    };
  }, [token]);

  const tz = info?.timezone || "America/New_York";
  const days = useMemo(() => {
    const map = new Map();
    for (const slot of slots) {
      const key = dayKey(slot.start, tz);
      if (!map.has(key)) map.set(key, []);
      map.get(key).push(slot);
    }
    return [...map.entries()];
  }, [slots, tz]);

  useEffect(() => {
    if (!day && days.length) setDay(days[0][0]);
  }, [days, day]);

  async function confirm() {
    setWorking(true);
    setError("");
    try {
      const res = await call(token, "confirm", { start: picked });
      if (res.ok) {
        setDone(res.new_start);
      } else if (res.reason === "slot_taken") {
        setError("Sorry, that time was just taken. Please pick another one.");
        setPicked("");
        const free = await call(token, "slots");
        if (free.ok) setSlots(free.slots);
      } else {
        setProblem(res.reason || "invalid");
      }
    } catch (err) {
      setError(err.message);
    } finally {
      setWorking(false);
    }
  }

  const stop = PROBLEMS[problem];
  const todaySlots = days.find(([key]) => key === day)?.[1] || [];

  return (
    <main className="cp-page">
      <section className="cp-card">
        {info?.business && <div className="cp-brand"><span>{info.business}</span></div>}

        {!info && !stop && !error && <p className="op-muted">Checking your link...</p>}
        {error && !info && !stop && (
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

        {done && (
          <>
            <div className="cp-icon ok">✓</div>
            <h1>You're booked for a new time</h1>
            <p>
              {longDay(done, tz)} at {clock(done, tz)}. {info.business} has been told, and you'll get a reminder
              before your visit.
            </p>
          </>
        )}

        {info?.appointment && !stop && !done && (
          <>
            <h1>{info.missed ? `${info.first_name ? `${info.first_name}, w` : "W"}e missed you` : "Pick a new time"}</h1>
            {info.missed ? (
              <p>
                Your {info.appointment.title || "appointment"} was on{" "}
                <strong>{longDay(info.appointment.start, tz)} at {clock(info.appointment.start, tz)}</strong>. Pick a new time below.
              </p>
            ) : (
              <p>
                Your {info.appointment.title || "appointment"} is now on{" "}
                <strong>{longDay(info.appointment.start, tz)} at {clock(info.appointment.start, tz)}</strong>.
              </p>
            )}

            {days.length === 0 && (
              <p>There are no free times in the next two weeks. Please contact {info.business} to find one.</p>
            )}

            {days.length > 0 && (
              <>
                <div className="rs-days" role="tablist" aria-label="Day">
                  {days.map(([key, list]) => (
                    <button
                      key={key}
                      type="button"
                      role="tab"
                      aria-selected={key === day}
                      className={`rs-chip ${key === day ? "on" : ""}`}
                      onClick={() => { setDay(key); setPicked(""); }}
                    >
                      {shortDay(list[0].start, tz)}
                    </button>
                  ))}
                </div>
                <div className="rs-times">
                  {todaySlots.map((slot) => (
                    <button
                      key={slot.start}
                      type="button"
                      className={`rs-chip ${picked === slot.start ? "on" : ""}`}
                      onClick={() => setPicked(slot.start)}
                    >
                      {clock(slot.start, tz)}
                    </button>
                  ))}
                </div>
                {error && <div className="owner-form-error">{error}</div>}
                <button type="button" className="owner-primary-button cp-button" disabled={!picked || working} onClick={confirm}>
                  {working ? "Saving..." : picked ? `Move to ${clock(picked, tz)}` : "Choose a time"}
                </button>
                <p className="cp-small">Times shown are in {info.business}'s local time.</p>
              </>
            )}
          </>
        )}
      </section>
    </main>
  );
}
