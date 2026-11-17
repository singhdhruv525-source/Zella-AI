// The live switches (platform_settings: sms_live, email_live, calls_live, provider_checks_live) in the words admins
// read. The key is code: pages show these phrases, and put the key only in a tooltip (switchHint) for whoever needs
// to find the setting (UI-21). Nothing here changes a switch; they are set on the server at go live.

export const LIVE_SWITCHES = {
  sms_live: { thing: "Texts", on: "Texts are live", off: "Texts are in test mode" },
  email_live: { thing: "Emails", on: "Emails are live", off: "Emails are in test mode" },
  calls_live: { thing: "Outbound AI calls", on: "Outbound AI calls are on", off: "Outbound AI calls are off" },
  provider_checks_live: { thing: "Provider checks", on: "Provider checks are on", off: "Provider checks are off" },
};

// "Texts are in test mode", "Outbound AI calls are on"; an unknown key still reads as words.
export function switchText(key, on) {
  const s = LIVE_SWITCHES[key];
  if (s) return on ? s.on : s.off;
  const name = String(key ?? "").replace(/_live$/, "").replace(/_/g, " ").trim() || "This switch";
  return `${name.charAt(0).toUpperCase()}${name.slice(1)} ${on ? "is on" : "is off"}`;
}

// The setting behind a phrase, for a title tooltip: "Setting sms_live".
export const switchHint = (key) => `Setting ${key}`;

// Several switches that are off, as one sentence: "Texts and emails are in test mode."
export function offSentence(keys) {
  const things = keys.map((k) => LIVE_SWITCHES[k]?.thing ?? switchText(k, false));
  if (!things.length) return "";
  if (things.length === 1) return `${switchText(keys[0], false)}.`;
  const list = `${things.slice(0, -1).join(", ")} and ${things.at(-1).toLowerCase()}`;
  return `${list} are in test mode.`;
}
