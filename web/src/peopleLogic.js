// Release 1: words and rules for the People & consent panel (sql/zella_relationships.sql). The server decides who
// may do what; this only explains it. Unit tests: web/tests/release1_unit.test.mjs.

export const KINDS = [
  ["parent", "Parent"], ["guardian", "Legal guardian"], ["proxy", "Proxy (acts for them)"], ["representative", "Representative / attorney"],
  ["household", "Household member"], ["emergency_contact", "Emergency contact"], ["authorized_contact", "Authorized contact"],
  ["tenant", "Tenant"], ["owner", "Owner"], ["vendor", "Vendor / contractor"], ["other", "Other"],
];
export const KIND_LABEL = Object.fromEntries(KINDS);

export const PERMISSIONS = [
  ["discuss", "Discuss details with them"], ["book", "Book and change appointments"], ["pickup", "Collect / pick up"],
  ["approve", "Approve and give consent"], ["receive_updates", "Receive updates and reminders"], ["documents", "Receive documents"],
];
export const PERMISSION_LABEL = Object.fromEntries(PERMISSIONS);

export const METHODS = [
  ["id_checked", "Photo ID checked in person"], ["document_on_file", "Document on file (court order, form)"],
  ["known_to_team", "Known to the team"], ["callback_verified", "Called back on a number we already had"], ["other", "Other"],
];
export const METHOD_LABEL = Object.fromEntries(METHODS);

export const CONSENT_KINDS = [
  ["treatment", "Treatment or service"], ["medication", "Medication"], ["emergency_care", "Emergency care"], ["photo_media", "Photos and media"],
  ["data_sharing", "Sharing information"], ["recording", "Call recording"], ["pickup_change", "Pickup arrangements"], ["terms", "Terms and policies"],
  ["other", "Other"],
];
export const CONSENT_LABEL = Object.fromEntries(CONSENT_KINDS);

// A relationship's or consent's state, as the server computed it, in words and a tone.
export const STATE = {
  active: ["success", "Verified"], unverified: ["warning", "Not verified: grants nothing yet"], expired: ["danger", "Expired"],
  revoked: ["neutral", "Revoked"], refused: ["danger", "Refused"],
};
export const CONSENT_STATE = { active: ["success", "Given"], refused: ["danger", "Refused"], expired: ["danger", "Expired"], revoked: ["neutral", "Withdrawn"] };

export const personLabel = (p) => (p ? [p.first_name, p.last_name].filter(Boolean).join(" ") || p.phone || p.email || "Unnamed" : "");

// Suggested kinds first, by what the subject is (all kinds stay available).
export function suggestedKinds(subject) {
  const key = String(subject?.typeKey ?? "").toLowerCase();
  const order = /child|student|enrol|pupil/.test(key) ? ["parent", "guardian", "authorized_contact", "emergency_contact"]
    : /pet|animal/.test(key) ? ["owner", "authorized_contact", "emergency_contact"]
    : /unit|propert|lease/.test(key) ? ["tenant", "owner", "vendor", "authorized_contact"]
    : /polic|claim|matter|account/.test(key) ? ["authorized_contact", "representative", "household"]
    : ["household", "parent", "guardian", "proxy", "emergency_contact", "authorized_contact"];
  return [...order.map((k) => [k, KIND_LABEL[k]]), ...KINDS.filter(([k]) => !order.includes(k))];
}

// Who could give consent, as far as the screen knows: the person themselves, a record's primary contact, and verified
// links allowed to approve. The server checks again (NOT_AUTHORIZED_GIVER).
export function consentGivers(panel, subject) {
  const out = [];
  if (subject?.customer) out.push({ id: subject.customer.id, label: `${personLabel(subject.customer)} (themselves)` });
  if (panel?.primary_contact) out.push({ id: panel.primary_contact.id, label: `${personLabel(panel.primary_contact)} (primary contact)` });
  for (const r of panel?.relationships ?? []) {
    if (r.state === "active" && (r.permissions ?? []).includes("approve") && !out.some((o) => o.id === r.person.id)) {
      out.push({ id: r.person.id, label: `${personLabel(r.person)} (${(KIND_LABEL[r.kind] ?? r.kind).toLowerCase()})` });
    }
  }
  return out;
}

const ERRORS = [
  [/NOT_AUTHORIZED_GIVER/, "That person can't give consent here. Only the person themselves, the primary contact, or a verified contact allowed to approve can."],
  [/SAME_PERSON/, "A person can't be linked to themselves."],
  [/BAD_DATE/, "The date can't be in the past."],
  [/BAD_METHOD/, "Choose how they were verified."],
  [/NOTE_TOO_LONG/, "The note is too long (500 characters at most)."],
  [/23505|duplicate key|one_active/, "This person already has an active link of that kind. Edit it, or revoke it first."],
  [/customer_relationships_kind|customer_consents_kind/, "Choose one of the listed kinds."],
  [/customer_relationships_permissions/, "Choose from the listed permissions."],
  [/NOT_FOUND/, "That item has changed or was revoked. Refresh and try again."],
  [/NOT_VALID/, "That person or record isn't part of this business, or the record is archived."],
  [/NOT_ALLOWED|permission denied|42501/, "You don't have permission to do that here."],
  [/MFA_REQUIRED/, "Enter the code from your authenticator app first: sign out and sign in again."],
  [/failed to fetch|network|load failed/i, "Couldn't reach Zella. Nothing was changed; try again."],
  [/zella_people_panel|zella_relationship|zella_consent|schema cache|Could not find the function/, "People & consent isn't available on this workspace yet. Ask the Zella team."],
];
export function peopleError(error) {
  const text = `${error?.message ?? ""} ${error?.code ?? ""} ${error?.details ?? ""}`;
  for (const [re, msg] of ERRORS) if (re.test(text)) return msg;
  return "That didn't work. Try again, or contact Zella support if it keeps happening.";
}
