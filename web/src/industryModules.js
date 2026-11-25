// CFG-01: switching a module off removes it at once from every business in the industry that has it on (the server's
// zella_module_on needs the module to be offered), so the Industry configuration page counts who loses it first.

export const businessWord = (n) => `${Number(n).toLocaleString("en-US")} ${n === 1 ? "business" : "businesses"}`;

// Modules this draft switches off that were offered when the page loaded, with how many businesses have them on now.
// usage is { moduleId: count } from industry_module_usage. Modules nobody has on need no confirmation.
export function modulesLosingUsers(saved, draftModules, usage) {
  return draftModules
    .filter((m) => m.id && !m.isActive && saved.some((s) => s.id === m.id && s.is_active) && (usage?.[m.id] ?? 0) > 0)
    .map((m) => ({ id: m.id, name: saved.find((s) => s.id === m.id)?.name || m.name, businesses: usage[m.id] }));
}

export function switchesOff(saved, draftModules) {
  return draftModules.some((m) => m.id && !m.isActive && saved.some((s) => s.id === m.id && s.is_active));
}

// A module's name as people read it, from its slug (the names in sql/zella_industries_seed.sql).
// An unknown slug is spelled out in words, with "AI" kept in capitals: never "Ai-receptionist".
const MODULE_NAMES = {
  calls: "Calls", sms: "Text messages", email: "Email", calendar: "Calendar", automations: "Automations",
  "ai-receptionist": "AI receptionist", "ai-appointments": "AI appointments", "ai-follow-up": "AI follow up",
  "ai-sales": "AI sales", "ai-support": "AI support",
};

export function moduleName(slug) {
  const key = String(slug ?? "").trim();
  if (!key) return "";
  if (MODULE_NAMES[key]) return MODULE_NAMES[key];
  const text = key.replace(/[-_]+/g, " ").replace(/\s+/g, " ").trim().toLowerCase().replace(/\bai\b/g, "AI");
  return text.charAt(0).toUpperCase() + text.slice(1);
}

// The industries_list answer, checked. Returns null when the server sent nothing usable (no answer, or no list),
// so the page shows "Industries didn't load." with Try again instead of a code error. Rows the page can't render (no id,
// no string name) are left out, and so are module entries that aren't objects. An empty list is a valid answer.
export function readIndustriesAnswer(data) {
  if (!data || typeof data !== "object" || !Array.isArray(data.industries)) return null;
  const industries = data.industries
    .filter((i) => i && typeof i === "object" && !Array.isArray(i) && i.id && typeof i.name === "string")
    .map((i) => ({ ...i, modules: (Array.isArray(i.modules) ? i.modules : []).filter((m) => m && typeof m === "object" && !Array.isArray(m)) }));
  return { industries, industryData: Boolean(data.industryData) };
}
