// AI-TESTING: a business's last AI testing run in words. A failing run is a warning, never a block.
export function evalPill(run, cases) {
  if (!run) return cases > 0 ? ["neutral", "Not run yet"] : ["neutral", "No questions"];
  if (run.business_passes) return ["success", "Passes"];
  if (run.total < 3) return ["warning", "Too few questions"];
  return ["warning", "Warning"];
}

export function evalSummary(run) {
  if (!run) return "";
  if (!run.total) return "No test questions";
  return `${run.passed} of ${run.total} questions answered as expected`;
}
