// Adding a lead by hand goes through the lead pipeline only (zella_staff_add_lead → zella_capture_lead): role check,
// duplicate matching, lead stage, contact deadline, follow-up task. There is deliberately no fallback that writes to the
// customers table directly: if the pipeline can't be reached, the lead isn't added and the person is told why.

const LEAD_ERRORS = [
  [/NOT_ALLOWED|permission denied|42501/i, "You don't have permission to add leads in this workspace."],
  [/MFA_REQUIRED/, "Enter the code from your authenticator app first: sign out and sign in again."],
  [/NAME_REQUIRED/, "Enter a name."],
  [/NO_CONTACT/, "Enter a phone number or email so you can follow up."],
  [/BAD_EMAIL/, "That email doesn't look right."],
  [/BUSINESS_NOT_AVAILABLE/, "This workspace is paused, so leads can't be added right now."],
  [/JWT expired|invalid JWT|refresh token|not signed in/i, "Your sign-in has expired. Sign in again and retry."],
  [/failed to fetch|network|load failed|timeout/i, "Couldn't reach Zella. Check your connection and try again. The lead wasn't added."],
  [/zella_staff_add_lead|schema cache|Could not find the function|does not exist/i, "Adding leads isn't available on this workspace yet. The lead wasn't added; please ask the Zella team."],
];

// A plain-language message; never the database's own wording.
export function leadError(error) {
  const text = `${error?.message ?? ""} ${error?.code ?? ""} ${error?.details ?? ""}`;
  for (const [re, msg] of LEAD_ERRORS) if (re.test(text)) return msg;
  return "The lead couldn't be added. Try again, or contact Zella support if it keeps happening.";
}

export function leadArgs(workspaceId, values) {
  return {
    p_business_id: workspaceId, p_first_name: values.first_name || null, p_last_name: values.last_name || null,
    p_phone: values.phone || null, p_email: values.email ? values.email.toLowerCase() : null, p_source: values.source, p_notes: values.notes || null,
  };
}

export function leadSavedMessage(result, values) {
  const who = [values.first_name, values.last_name].filter(Boolean).join(" ") || "New lead";
  return result?.result === "matched" ? `${who} is already in your list. The notes were added to their profile.`
    : result?.result === "needs_review" ? `${who} may already be in your list. Check Tasks to review the possible duplicate.`
    : `${who} was added.`;
}

// Calls the pipeline once. Resolves to { ok: true, message } or { ok: false, error }.
export async function addLead(rpc, workspaceId, values) {
  let res;
  try { res = await rpc("zella_staff_add_lead", leadArgs(workspaceId, values)); }
  catch (err) { return { ok: false, error: leadError(err) }; }
  if (res?.error) return { ok: false, error: leadError(res.error) };
  return { ok: true, message: leadSavedMessage(res?.data, values) };
}
