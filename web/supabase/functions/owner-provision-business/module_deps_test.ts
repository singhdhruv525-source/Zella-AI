import { assertEquals } from "jsr:@std/assert@1";
import { businessModuleProblems, industryModuleProblems } from "./module_deps.ts";

const m = (slug: string, name: string) => ({ id: `id-${slug}`, slug, name });
const ids = (...slugs: string[]) => new Set(slugs.map((s) => `id-${s}`));

Deno.test("business modules: a dependency switched on passes", () => {
  const offered = [m("calls", "Calls"), m("ai-receptionist", "AI receptionist")];
  assertEquals(businessModuleProblems(offered, ids("calls", "ai-receptionist")), []);
  assertEquals(businessModuleProblems(offered, ids("calls")), []);
  assertEquals(businessModuleProblems(offered, new Set()), []);
});

Deno.test("business modules: a dependency switched off is refused", () => {
  const offered = [m("calls", "Calls"), m("ai-receptionist", "AI receptionist")];
  assertEquals(businessModuleProblems(offered, ids("ai-receptionist")), ["AI receptionist requires Calls"]);
});

Deno.test("business modules: a dependency the industry doesn't offer is refused, not skipped (CFG-02)", () => {
  const offered = [m("ai-receptionist", "AI receptionist"), m("ai-appointments", "AI appointments")];
  assertEquals(businessModuleProblems(offered, ids("ai-receptionist", "ai-appointments")), [
    "AI receptionist needs Calls, which this industry doesn't offer",
    "AI appointments needs Calendar, which this industry doesn't offer",
  ]);
});

Deno.test("industry modules: switching off a needed module, or keeping a module on without its dependency, is refused", () => {
  const on = (slug: string, name: string, isActive = true) => ({ slug, name, isActive });
  assertEquals(industryModuleProblems([on("calls", "Calls"), on("ai-receptionist", "AI receptionist")]), []);
  assertEquals(industryModuleProblems([on("calls", "Calls", false), on("ai-receptionist", "AI receptionist", false)]), []);
  assertEquals(industryModuleProblems([on("calls", "Calls", false), on("ai-receptionist", "AI receptionist")]), [
    "AI receptionist needs Calls, so it can't stay on while that is off",
  ]);
  assertEquals(industryModuleProblems([on("ai-sales", "AI sales")]), ["AI sales needs Calls, so it can't stay on while that is off"]);
});
