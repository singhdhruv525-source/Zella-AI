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

const BY_INDUSTRY_LINES = {
 "automotive": [
  "Cars in, calls handled. We've got the phones while you've got the wrenches.",
  "Under the hood is your job. Under the phone is ours.",
  "Every breakdown call gets a calm voice.",
  "Booked-in jobs, steady calls, no pile-ups at the desk."
 ],
 "beautysalon": [
  "Hands in hair? Hands off the phone. That's ours.",
  "We'll keep the bookings flowing while you keep everyone looking great.",
  "Your chairs stay full and your phone stays answered.",
  "Make them gorgeous. We'll make the calls easy."
 ],
 "childcare": [
  "Little ones first. The phone is ours.",
  "Every parent who calls gets a kind, patient voice.",
  "You look after the children. We'll look after the calls.",
  "Families feel welcome from the very first hello."
 ],
 "cleaningservices": [
  "Sparkle on the job, calm on the phone.",
  "You make homes shine. We'll make bookings smooth.",
  "Every enquiry answered while you're mid-scrub.",
  "Clean spaces, clear calendar, quiet phone worries."
 ],
 "dental": [
  "Mouths full of tools? Phones full of Zella.",
  "Patients get a friendly voice before they get the chair.",
  "You do the dentistry. We do the ringing.",
  "Recalls, bookings and nervous callers, all gently handled."
 ],
 "ecommerce": [
  "Orders ship, questions get answered. We're on the questions.",
  "Your shop never closes, and neither does our hello.",
  "Every customer query gets a warm reply.",
  "Pack the parcels. We'll take the calls."
 ],
 "education": [
  "Teach the class. We'll teach the phone some manners.",
  "Every enquiry from a student or parent gets a clear, kind answer.",
  "Learners first. Admin calls to us.",
  "Open days, enquiries and questions, handled."
 ],
 "electrical": [
  "Wires in your hands, phone in ours.",
  "Every call-out request gets a steady voice.",
  "Power up your day. We'll power the phones.",
  "Safe work on site, smooth calls back at base."
 ],
 "financialservices": [
  "Numbers are your thing. Answering is ours.",
  "Every client call gets a calm, professional hello.",
  "Focus on the figures. We'll handle the front desk.",
  "Consultations booked, questions routed, nothing lost."
 ],
 "fitness": [
  "Keep the energy up. We'll keep the phones covered.",
  "Members and trials all get a high-five hello.",
  "You train them. We'll talk to them.",
  "Classes full, calls answered, nobody on hold."
 ],
 "healthcare": [
  "Care is your focus. The phones are in calm hands.",
  "Every patient gets a patient, kind voice.",
  "You look after the patients. We'll look after the line.",
  "Bookings and questions handled gently, always."
 ],
 "homeservices": [
  "Doors to knock on, calls to leave with us.",
  "Every homeowner who calls gets a friendly hello.",
  "You fix the house. We'll fix the phone queue.",
  "Jobs booked, callers reassured, you undisturbed."
 ],
 "hospitality": [
  "Guests are welcomed, even over the phone.",
  "Reservations answered at any hour. Concierge-level calm.",
  "You host the stay. We host the call.",
  "A warm welcome starts before they arrive."
 ],
 "hvac": [
  "Cool heads on the phone, whatever the weather.",
  "Heating, cooling, calling: we cover the last one.",
  "Every no-heat call gets a calm, quick response.",
  "You keep homes comfortable. We keep callers comfortable."
 ],
 "insurance": [
  "Questions about cover? A friendly answer, every time.",
  "Every client call gets a steady, caring voice.",
  "You protect them. We'll pick up for them.",
  "Quotes, renewals and queries, all caught."
 ],
 "landscapinglawncare": [
  "Mow the lawns. We'll mow down the missed calls.",
  "Fresh quotes, fresh calls, all handled.",
  "Outdoors is your office. We're the front desk.",
  "Gardens grow, calls get answered."
 ],
 "legal": [
  "Your focus is the case. The phone is ours.",
  "Every caller gets a discreet, steady hello.",
  "Consultations booked, messages taken, confidence kept.",
  "Calm, careful, and always on the line."
 ],
 "pestcontrol": [
  "Pests get dealt with. Calls get answered.",
  "Urgent call? A calm voice picks up first.",
  "You handle the critters. We'll handle the callers.",
  "Bug-free homes, worry-free phones."
 ],
 "petcareveterinary": [
  "Paws, claws and calls. We've got the calls.",
  "Every worried pet owner gets a kind, steady voice.",
  "Cuddle the patients. We'll cuddle the phone.",
  "Bookings for the furry, answers for their humans."
 ],
 "photographyevents": [
  "You capture the moment. We capture the calls.",
  "Every enquiry for a date gets a warm reply.",
  "Behind the camera is your place. The phone is ours.",
  "Bookings and questions, snapped up."
 ],
 "plumbing": [
  "Leaks fixed on your side, calls fixed on ours.",
  "A burst-pipe call gets a calm voice right away.",
  "You stop the drips. We stop the missed calls.",
  "Every call flows straight to a friendly hello."
 ],
 "professionalservices": [
  "Deep work, uninterrupted. The phone is on us.",
  "Every prospect gets a polished first hello.",
  "You deliver the project. We'll deliver the pickup.",
  "Enquiries answered, meetings booked, focus kept."
 ],
 "propertymanagement": [
  "Keys and calls, both handled.",
  "Every tenant gets a patient, helpful voice.",
  "You manage the buildings. We'll manage the ringing.",
  "Maintenance calls caught, tenants reassured."
 ],
 "realestate": [
  "Viewings booked while you're out showing homes.",
  "Every enquiry gets an eager, friendly reply.",
  "Sell the dream. We'll answer the phone.",
  "New listings, new callers, nobody left waiting."
 ],
 "restaurant": [
  "Kitchen's hot, phones are covered.",
  "Reservations answered before the oven pings.",
  "Every guest gets a warm welcome, even down the line.",
  "You plate the dishes. We'll take the bookings."
 ],
 "spawellness": [
  "Calm in the spa, calm on the phone.",
  "Every guest hears a soothing hello.",
  "You relax them. We'll relax the diary.",
  "Bookings flow as gently as your treatments."
 ],
 "travel": [
  "Dream trips planned. Phone calls handled.",
  "Every would-be traveller gets an excited hello.",
  "You plan the adventure. We'll answer the questions.",
  "Itineraries and enquiries, all booked."
 ]
};
const industryKey = (name) => String(name ?? "").toLowerCase().replace(/[^a-z]/g, "");

export function todayNote(partOfDay, industry) {
  const own = BY_INDUSTRY_LINES[industryKey(industry)] ?? [];
  const pool = [...own, ...own, ...LINES, ...(partOfDay === "morning" ? MORNING : partOfDay === "evening" ? EVENING : AFTERNOON)];
  let seen = [];
  try { seen = JSON.parse(recall("zella.today.seen2") || "[]"); } catch { seen = []; }
  const fresh = pool.map((line, i) => i).filter((i) => !seen.includes(i));
  const options = fresh.length ? fresh : pool.map((l, i) => i).filter((i) => i !== seen[seen.length - 1]);
  const pick = options[Math.floor(Math.random() * options.length)];
  remember("zella.today.seen2", JSON.stringify(fresh.length ? [...seen, pick] : [pick]));
  return pool[pick];
}
