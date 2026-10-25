// The heading and the soft line under it on the Today page. These are meant to feel calm and
// kind, not like work. Each business gets its own order, and the line changes on every visit.
const ANYTIME = [
  "We're here. Whatever comes up, you're not on your own.",
  "Zella is with you. Always.",
  "Still here. Still listening.",
  "You're in good company.",
  "The line is open, and we're holding it for you.",
  "Think of us as the friendly voice in your corner.",
  "We've got your back. Really.",
  "No need to hold your breath. We're holding the door.",
  "Somebody warm is always at the desk. That's us.",
  "You brought us on to feel less alone. We take that seriously.",
  "Quiet on your side means we're listening on ours.",
  "We remember so you can rest.",
  "Whenever you turn around, we'll be right there.",
  "You built something good. We're here to look after the front door.",
  "You can lean on us. That's what we're for.",
  "Consider this your reminder that we're here.",
  "Every hello starts with us, so yours can be easy.",
  "We're a small voice with a big promise: we're here.",
  "Hello from Zella. We never really leave.",
  "Whatever today needs, we're by your side.",
  "A friendly voice is always on the line.",
  "Zella, reporting for company duty. We're right here.",
  "You say the word. We're already listening.",
  "We keep the lights on and the welcome warm.",
];
const MORNING = [
  "Good to see you. We've been keeping your place warm.",
  "Morning. We're awake and glad you're here.",
  "A new day, and we're in it with you.",
  "We were here before you arrived, and we'll be here after.",
];
const AFTERNOON = [
  "Welcome back. We never left.",
  "Right on time. We were hoping you'd stop by.",
  "Hello again. Zella is with you all afternoon.",
];
const EVENING = [
  "You made it. We'll keep the light on.",
  "Evening. You can switch off. We're still here.",
  "Rest easy. We're not going anywhere.",
  "Settle in. We'll keep you company.",
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

// partOfDay: "morning" | "afternoon" | "evening". A different line each visit, never one of the last few shown.
// businessKey makes two businesses start from different places in the list.
export function todayNote(partOfDay, businessKey) {
  const pool = [...ANYTIME, ...(partOfDay === "morning" ? MORNING : partOfDay === "evening" ? EVENING : AFTERNOON)];
  let seen = [];
  try { seen = JSON.parse(recall("zella.today.seen") || "[]"); } catch { seen = []; }
  const fresh = pool.map((line, i) => i).filter((i) => !seen.includes(i));
  const options = fresh.length ? fresh : pool.map((l, i) => i);
  const start = hash(businessKey) % options.length;
  const pickIndex = options[(start + Math.floor(Math.random() * options.length)) % options.length];
  remember("zella.today.seen", JSON.stringify([...seen, pickIndex].slice(-8)));
  return pool[pickIndex];
}
