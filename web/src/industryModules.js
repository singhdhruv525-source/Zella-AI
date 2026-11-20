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
