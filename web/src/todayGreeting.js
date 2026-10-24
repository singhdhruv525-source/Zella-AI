// The heading and the soft line under it on the Today page. These are meant to feel calm and
// kind, not like work. Each business gets its own order, and the line changes on every visit.
const ANYTIME = [
  "Take a breath. Everything is in good hands.",
  "You don't have to do it all at once.",
  "Small steps still count.",
  "Be easy on yourself today.",
  "The phone is covered. You can relax.",
  "Good things take time. You're doing fine.",
  "Take your time. Zella has the rest.",
  "Nothing here needs to be rushed.",
  "A little calm goes a long way.",
  "You've got this, and you've got help.",
  "Breathe in. Let the day come to you.",
  "Steady wins. Keep going at your pace.",
];
const MORNING = [
  "A fresh start. Take it slowly.",
  "Coffee first, everything else after.",
  "Let the morning be gentle.",
  "A new day, plenty of time.",
];
const AFTERNOON = [
  "Halfway there. A good moment for a pause.",
  "Stretch, sip some water, carry on.",
  "The day is going well. Keep your pace.",
];
const EVENING = [
  "You've done enough for today.",
  "Time to slow down. Zella is still here.",
  "Rest well. The phone is handled.",
  "Let the evening be quiet.",
];

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

// partOfDay: "morning" | "afternoon" | "evening". businessKey keeps each business on its own path through the list.
export function todayNote(partOfDay, businessKey) {
  const pool = [...ANYTIME, ...(partOfDay === "morning" ? MORNING : partOfDay === "evening" ? EVENING : AFTERNOON)];
  const offset = hash(businessKey) % pool.length;
  const visit = Number(recall("zella.today.visit") || 0) + 1;
  remember("zella.today.visit", String(visit));
  return pool[(offset + visit * 5) % pool.length];
}
