// Create business (BIZ-14): one creation key per wizard session, and the words for a possible duplicate.

// A random key in the uuid shape the server checks. The same key is sent with every retry of the first save, so a
// retry after a timeout gets the business the first try made instead of a second one.
export function newCreationKey(c = globalThis.crypto) {
  if (typeof c?.randomUUID === "function") return c.randomUUID();
  const b = c.getRandomValues(new Uint8Array(16));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

const MATCH_WORDS = { name: "name", phone: "phone number", website: "website" };

// "Same name and phone number" for the matches the server reported, in a fixed order.
export function matchedWords(matched) {
  const words = ["name", "phone", "website"].filter((k) => (matched ?? []).includes(k)).map((k) => MATCH_WORDS[k]);
  if (!words.length) return "";
  const list = words.length === 1 ? words[0] : `${words.slice(0, -1).join(", ")} and ${words[words.length - 1]}`;
  return `Same ${list}`;
}

const SETUP_WORDS = { testing: "Testing", ready: "Ready", active: "Live" };

// Where the possible duplicate stands: live, set up, or still a draft.
export function duplicateState(d) {
  if (d?.isActive) return "Live";
  return SETUP_WORDS[d?.onboardingStatus] ?? "Draft in setup";
}
