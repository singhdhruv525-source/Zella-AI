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
// and never a to-do list. A different line every visit; none repeats until every line has been shown.
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
  "Every caller gets a hello that sounds like you.",
  "We're the calm voice on the other end.",
  "Your phone has a new best friend.",
  "The ringing is our job now.",
  "Not a single hello left hanging.",
  "While you're busy, we're being brilliant on the phone.",
  "Customers feel heard, even before you pick up.",
  "We keep the door open and the welcome warm.",
  "You do the doing. We do the answering.",
  "Think of us as your never-late receptionist.",
  "Messages taken, callers calmed, you undisturbed.",
  "We'll tell you what matters and handle what doesn't.",
  "No hold music. Just a friendly voice.",
  "Your callers will never feel like they called the wrong place.",
  "Lunch break? Take it. We're covering.",
  "We've memorised your business so you can forget the phone.",
  "A great first impression, every single call.",
  "We're quietly making your business look good.",
  "Late calls, early calls, odd-hour calls. All ours.",
  "Rest your voice. Ours is warmed up.",
  "You've got one less thing to remember.",
  "Calls come in. Calm comes out.",
  "We answer like we've worked here for years.",
  "Your reputation is safe on our line.",
  "If it rings, we're already on it.",
  "You'll hear about it only when it matters.",
  "Everyone who calls leaves feeling looked after.",
  "Sit tight. The easy part is us.",
  "No stress on the line today.",
  "We're sorting the calls so you can sort the day.",
  "A friendly pick-up, every single time.",
  "Your customers won't wait. We won't let them.",
  "Think of this as your phone's day off.",
  "We carry the calls so you can carry on.",
  "Nothing to chase. We're on the chase.",
  "You go be the boss. We'll be the front desk.",
  "The phone can't surprise you when we're on it.",
  "A steady voice for a busy business.",
  "We're good at this, and we love it.",
  "Whatever the day throws, the phones are covered.",
  "You're never off the hook alone. We're on it with you.",
  "Peace of mind, one answered call at a time.",
  "Customers say hello. We say welcome.",
  "We turn missed calls into done deals.",
  "Everything that rings finds a friendly answer.",
  "You built the business. We'll mind the phone.",
  "Leave it with Zella.",
  "Your callers are in the nicest hands.",
  "Call comes in, care goes out.",
  "The phone is handled. Go enjoy your day.",
  "Zella: the only thing on your phone that never goes to voicemail.",
  "We're the reason nobody gets a busy signal.",
  "Smooth calls, happy customers, quiet mind.",
  "We've got today's calls. You've got today's wins.",
  "Say less. We'll handle the talking.",
  "One less ring to worry about.",
  "Easy mornings start with an answered phone.",
  "Take a deep breath. Everything's being answered.",
  "We're on call so you don't have to be.",
  "The best part of your day: we're already on it.",
  "A little help goes a long way. We're a lot of help.",
  "Smile. Your phone is in expert hands.",
  "Every caller matters here. We make sure they feel it.",
  "You can switch off now. The line stays on.",
  "No call too small, no hour too late.",
  "We give every caller the same warm welcome.",
  "It's all under control, and we'd like to keep it that way.",
  "Business as usual, minus the phone stress.",
  "Behind every happy customer, a very friendly Zella.",
  "We'll be the first to say hello, and the last to hang up.",
  "Let the phone ring. We love that sound.",
];

const MORNING = ["A fresh day, and the phones are already covered.", "Morning. The line is open and we're smiling at it."];
const AFTERNOON = ["Afternoon rush? Send it our way.", "Halfway through the day, and we're still fresh on the phones."];
const EVENING = ["Winding down? We'll keep the phones warm.", "Close up when you're ready. We'll catch the late calls."];

export function todayNote(partOfDay) {
  const pool = [...LINES, ...(partOfDay === "morning" ? MORNING : partOfDay === "evening" ? EVENING : AFTERNOON)];
  let seen = [];
  try { seen = JSON.parse(recall("zella.today.seen2") || "[]"); } catch { seen = []; }
  const fresh = pool.map((line, i) => i).filter((i) => !seen.includes(i));
  const options = fresh.length ? fresh : pool.map((l, i) => i).filter((i) => i !== seen[seen.length - 1]);
  const pick = options[Math.floor(Math.random() * options.length)];
  remember("zella.today.seen2", JSON.stringify(fresh.length ? [...seen, pick] : [pick]));
  return pool[pick];
}
