// What Settings shows for staff access to transcripts and recordings, from the industry check's answer:
//   null  the check couldn't run: say so and offer Try again (never claim access is off)
//   true  the industry handles sensitive details: staff can't be given access
//   false the owner or an admin chooses
export function callAccessState(sensitive) {
  if (sensitive === null || sensitive === undefined) return "unknown";
  return sensitive ? "blocked" : "choose";
}
export const CALL_ACCESS_UNKNOWN = "We couldn't check whether staff can be given access. Nothing was changed.";
