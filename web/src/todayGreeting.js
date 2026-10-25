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

// The soft line under the greeting. It is Zella speaking: reassuring, about Zella handling things, never a quote
// and never a to-do list. A different line each visit, never one of the last few shown.
const LINES = [
  "Hands full. Phone handled.",
  "Sit back. The phone is ours today.",
  "Your calls are in good hands. Ours.",
  "Go do the work you love. We'll pick up.",
  "Every ring answered, every caller looked after.",
  "No call goes unanswered on our watch.",
  "Breathe out. Zella's on the line.",
  "We're minding the phones, so you can mind the business.",
  "Missed calls aren't a thing around here.",
  "Your front desk never sleeps. Neither do we.",
  "Take your coffee slow. We've got the phones.",
  "Customers get a warm hello, even when you're busy.",
  "We answer, we listen, we pass on what matters.",
  "Busy day? Perfect. We'll handle the ringing.",
  "Leave the follow-ups to us.",
  "Small business, big front desk. That's the deal.",
  "We'll keep every caller feeling looked after.",
  "Zella is on the line, so you don't have to be.",
  "Quiet inbox, calm mind. We're on it.",
  "You focus on your customers. We'll focus on their calls.",
  "Nothing slips through while we're here.",
  "Relax. Somebody friendly just picked up.",
  "Your business, our best hello.",
  "We take the calls. You take the credit.",
];

const MORNING = ["A fresh day, and the phones are already covered.", "Morning. The line is open and we're smiling at it."];
const AFTERNOON = ["Afternoon rush? Send it our way.", "Halfway through the day, and we're still fresh on the phones."];
const EVENING = ["Winding down? We'll keep the phones warm.", "Close up when you're ready. We'll catch the late calls."];

export function todayNote(partOfDay) {
  const pool = [...LINES, ...(partOfDay === "morning" ? MORNING : partOfDay === "evening" ? EVENING : AFTERNOON)];
  let seen = [];
  try { seen = JSON.parse(recall("zella.today.seen2") || "[]"); } catch { seen = []; }
  const fresh = pool.map((line, i) => i).filter((i) => !seen.includes(i));
  const options = fresh.length ? fresh : pool.map((l, i) => i);
  const pick = options[Math.floor(Math.random() * options.length)];
  remember("zella.today.seen2", JSON.stringify([...seen, pick].slice(-10)));
  return pool[pick];
}
