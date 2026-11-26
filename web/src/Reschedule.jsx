import { useEffect, useMemo, useState } from "react";
import "./OwnerDashboard.css";
import "./OwnerPages.css";
import { supabase } from "./supabase";
import { ATTEND_ACTION, attendOutcome, pageAction } from "./rescheduleAction";

// Page opened from the Reschedule link in appointment texts and emails (/r/<code>), and from the Confirm and Cancel
// buttons in confirmation and reminder emails (/r/<code>?do=confirm, ?do=cancel; rescheduleAction.js). The customer
// isn't signed in. The private code in the link identifies one appointment. Confirm and Cancel ask first: opening the
// link changes nothing.

async function call(token, action, extra = {}) {
  const { data, error } = await supabase.functions.invoke("reschedule-appointment", {
    body: { token, action, ...extra },
  });
  if (error) {
    // Too many tries in a minute (the link's rate limit) gets its own plain message; otherwise the function's own
    // customer-facing message when it sent one (for example "This link can't be used right now").
    const status = error.context?.status;
    if (status === 429) throw new Error("Too many tries. Please wait a minute and try again.");
    const body = await error.context?.json?.().catch(() => null);
    throw new Error(typeof body?.error === "string" && body.error.length < 200 ? body.error : "Something went wrong. Please try again.");
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
    body: "It may have been canceled or already finished. Please contact the business to book a new time.",
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
  // a failed lookup of free times is not "no free times"
  const [slotsFailed, setSlotsFailed] = useState(false);
  const [problem, setProblem] = useState(token ? "" : "invalid");
  const [error, setError] = useState("");
  const [day, setDay] = useState("");
  const [picked, setPicked] = useState("");
  const [working, setWorking] = useState(false);
  const [done, setDone] = useState(null);
  // "confirm" or "cancel" from an email button, until the customer chooses to pick a new time instead
  const [mode, setMode] = useState(() => pageAction(typeof window === "undefined" ? "" : window.location.search));
  const [attended, setAttended] = useState(null);   // "confirmed", "already_confirmed" or "cancelled", once the server says so

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
        setInfo(looked);
        // the free times are only needed to pick a new time
        if (mode !== "reschedule") return;
        const free = await call(token, "slots");
        if (!active) return;
        setSlots(free.ok ? free.slots : []);
        setSlotsFailed(!free.ok);
      } catch (err) {
        if (active) setError(err.message);
      }
    })();
    return () => {
      active = false;
    };
  }, [token, mode]);

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

  async function retrySlots() {
    setWorking(true);
    try {
      const free = await call(token, "slots");
      if (free.ok) { setSlots(free.slots); setSlotsFailed(false); } else setSlotsFailed(true);
    } catch { setSlotsFailed(true); } finally { setWorking(false); }
  }

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
        if (free.ok) { setSlots(free.slots); setSlotsFailed(false); }
      } else {
        setProblem(res.reason || "invalid");
      }
    } catch (err) {
      setError(err.message);
    } finally {
      setWorking(false);
    }
  }

  async function attend() {
    setWorking(true);
    setError("");
    try {
      const outcome = attendOutcome(await call(token, ATTEND_ACTION[mode]));
      if (outcome.done) setAttended(outcome.done);
      else setProblem(outcome.problem);
    } catch (err) {
      setError(err.message);
    } finally {
      setWorking(false);
    }
  }

  function pickInstead() {
    setError("");
    setMode("reschedule");
    window.history.replaceState(null, "", window.location.pathname);
  }

  const stop = PROBLEMS[problem];
  const todaySlots = days.find(([key]) => key === day)?.[1] || [];

  return (
    <main className="cp-page">
      <section className="cp-card">
        {info?.business && <div className="cp-brand"><span>{info.business}</span></div>}

        {!info && !stop && !error && <p className="op-muted">Checking your link…</p>}
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

        {attended && (
          <>
            <div className="cp-icon ok">✓</div>
            <h1>{attended === "cancelled" ? "Your visit is canceled" : attended === "already_confirmed" ? "Your visit was already confirmed" : "Your visit is confirmed"}</h1>
            <p>
              {attended === "cancelled"
                ? <>{info.business} has been told. To book again, please contact {info.business}.</>
                : <>See you on {longDay(info.appointment.start, tz)} at {clock(info.appointment.start, tz)}. {info.business} can see you confirmed.</>}
            </p>
          </>
        )}

        {info?.appointment && !stop && !done && !attended && mode !== "reschedule" && (
          <>
            <h1>{mode === "cancel" ? "Cancel your visit?" : "Confirm your visit"}</h1>
            <p>
              Your {info.appointment.title || "appointment"} with {info.business} is on{" "}
              <strong>{longDay(info.appointment.start, tz)} at {clock(info.appointment.start, tz)}</strong>.
              {mode === "cancel" && <> {info.business} will be told, and the time may be offered to someone else.</>}
            </p>
            {error && <div className="owner-form-error" role="alert">{error}</div>}
            <button type="button" className={`${mode === "cancel" ? "bd-danger-button" : "owner-primary-button"} cp-button`} disabled={working} onClick={attend}>
              {working ? "Saving…" : mode === "cancel" ? "Cancel my visit" : "Confirm my visit"}
            </button>
            <p className="cp-small">
              Need a different time? <button type="button" className="ba-link" onClick={pickInstead} disabled={working}>Pick a new time instead</button>
            </p>
          </>
        )}

        {info?.appointment && !stop && !done && !attended && mode === "reschedule" && (
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

            {slotsFailed && days.length === 0 && (
              <p>We couldn't load the free times just now. <button type="button" className="ba-link" onClick={retrySlots} disabled={working}>Try again</button></p>
            )}
            {!slotsFailed && days.length === 0 && (
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
                  {working ? "Saving…" : picked ? `Move to ${clock(picked, tz)}` : "Choose a time"}
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
