// Which modules need which (CFG-02): the one list, checked by the server whenever a business's modules or an industry's
// modules change. The web app reads it through setup_load (`requires` on each module) and keeps its own copy only as a
// fallback for an older function. Pure: tested in module_deps_test.ts.

export const MODULE_DEPENDENCIES: Record<string, string[]> = {
  "ai-receptionist": ["calls"],
  "ai-appointments": ["calendar"],
  "ai-follow-up": ["automations"],
  "ai-sales": ["calls"],
  "ai-support": ["calls"],
};

export type OfferedModule = { id: string; slug: string; name: string };

// A readable name for a module slug the industry doesn't offer ("calls" -> "Calls").
const nameOfSlug = (slug: string) => slug.replace(/[-_]+/g, " ").replace(/^./, (c) => c.toUpperCase());

// What is wrong with switching on `enabled` (module ids) for a business whose industry offers `offered` (its active
// modules). Each switched on module needs every module it depends on: offered by the industry AND switched on.
// A dependency the industry doesn't offer (switched off there, or never added) makes the module impossible.
export function businessModuleProblems(offered: OfferedModule[], enabled: Set<string>): string[] {
  const bySlug = new Map(offered.map((m) => [m.slug, m]));
  const out: string[] = [];
  for (const module of offered) {
    if (!enabled.has(module.id)) continue;
    for (const dependency of MODULE_DEPENDENCIES[module.slug] ?? []) {
      const required = bySlug.get(dependency);
      if (!required) out.push(`${module.name} needs ${nameOfSlug(dependency)}, which this industry doesn't offer`);
      else if (!enabled.has(required.id)) out.push(`${module.name} requires ${required.name}`);
    }
  }
  return out;
}

export type IndustryModule = { slug: string; name: string; isActive: boolean };

// What is wrong with an industry's modules as they would be after a save: an active module whose dependency would be
// switched off or missing. Saving that would leave every business of the industry with a module it can't use.
export function industryModuleProblems(next: IndustryModule[]): string[] {
  const active = new Set(next.filter((m) => m.isActive).map((m) => m.slug));
  const nameBySlug = new Map(next.map((m) => [m.slug, m.name]));
  const out: string[] = [];
  for (const module of next) {
    if (!module.isActive) continue;
    for (const dependency of MODULE_DEPENDENCIES[module.slug] ?? []) {
      if (!active.has(dependency)) {
        out.push(`${module.name} needs ${nameBySlug.get(dependency) ?? nameOfSlug(dependency)}, so it can't stay on while that is off`);
      }
    }
  }
  return out;
}
