// The heading and the soft line under it on the Today page. These are meant to feel calm and
// kind, not like work. Each business gets its own order, and the line changes on every visit.
const recall = (name) => { try { return localStorage.getItem(name) ?? ""; } catch { return ""; } };
const remember = (name, value) => { try { localStorage.setItem(name, value); } catch { /* optional */ } };
const hash = (text) => { let h = 0; for (const ch of String(text)) h = (h * 31 + ch.charCodeAt(0)) >>> 0; return h; };

// true = "Welcome back", false = "Good morning/afternoon/evening". Alternates, never the same twice in a row.
export function welcomeStyle() {
  const last = recall("zella.today.heading");
  const next = last === "welcome" ? "time" : last === "time" ? "welcome" : Math.random() < 0.5 ? "welcome" : "time";
  remember("zella.today.heading", next);
  return next === "welcome";
}

// The line under the greeting says what is actually going on with the business and with Zella.
// Facts come from the Today page's own data, so it is always true and useful, never a quote.
const count = (n, one, many) => `${n} ${n === 1 ? one : many}`;
export function zellaNote({ loaded, live, missedOpen = 0, uncontacted = 0, waiting = 0, appointments = 0, nextTime = "", aiCalls = 0, rangeLabel = "today" }) {
  if (!loaded) return "Zella is checking on your business.";
  if (missedOpen > 0) return `${count(missedOpen, "missed call still needs", "missed calls still need")} a call back.`;
  if (uncontacted > 0) return `${count(uncontacted, "new lead hasn't", "new leads haven't")} been contacted yet.`;
  if (waiting > 0) return `${count(waiting, "conversation is", "conversations are")} waiting on a reply.`;
  if (appointments > 0) return `${count(appointments, "appointment", "appointments")} today${nextTime ? `, the next one at ${nextTime}` : ""}.`;
  if (aiCalls > 0) return `Your AI receptionist handled ${count(aiCalls, "call", "calls")} ${rangeLabel}.`;
  return live ? "Your AI receptionist is online and answering calls." : "Your AI receptionist isn't live yet. Zella connects your phone line before it goes live.";
}
