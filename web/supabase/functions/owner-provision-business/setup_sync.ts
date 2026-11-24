// Makes the setup wizard's answers reach what the AI receptionist actually reads (docs/SETUP_FIELD_TRACE_2026-11-05.md).
// Pure decisions here (setup_sync_test.ts); the writes are in index.ts (syncSetupToLive).
//
// D4 transfer number. Transfers read escalation_rules.transfer_number (or transfer_to.phone). Setup also collects a
//    "call transfer number" (Phone & integrations) and the owner's phone, which nothing used. The number to use, first
//    that is set: the receptionist step's transfer phone, the integrations step's transfer number, then - for
//    "Business owner" - the owner's phone. A number the admin set in call routing (not from setup) is never replaced.

export type TransferInputs = {
  transferType: string | null;        // escalation_rules.transfer_to.type
  transferPhone: string | null;       // escalation_rules.transfer_to.phone
  integrationsNumber: string | null;  // setup_data.integrations.transfer_number
  ownerPhone: string | null;          // setup_data.owner.phone
  currentNumber: string | null;       // escalation_rules.transfer_number
  currentSource: string | null;       // escalation_rules.transfer_number_source ("setup" when written by this)
};

const clean = (v: string | null | undefined) => (typeof v === "string" && v.trim() ? v.trim() : null);

// Returns the patch for escalation_rules, or null when nothing should change.
export function transferPatch(i: TransferInputs): { transfer_number: string | null; transfer_number_source: "setup" } | null {
  // set elsewhere (admin call routing): leave it
  if (clean(i.currentNumber) && i.currentSource !== "setup") return null;
  const pick = clean(i.transferPhone) ?? clean(i.integrationsNumber) ?? (i.transferType === "owner" ? clean(i.ownerPhone) : null);
  if (pick === clean(i.currentNumber)) return null;
  return { transfer_number: pick, transfer_number_source: "setup" };
}

// REQ-BIL-34 fallback number. Calls go there whenever the AI can't take them (paused, unavailable, minutes used up).
// Saved in E.164 so it can be dialled as written; US numbers typed with 10 or 11 digits are converted.
export function toE164(v: unknown): string | null {
  if (typeof v !== "string" || !v.trim()) return null;
  const raw = v.trim(), digits = raw.replace(/\D/g, "");
  if (raw.startsWith("+")) return /^[1-9][0-9]{7,14}$/.test(digits) ? `+${digits}` : null;
  if (/^[2-9][0-9]{9}$/.test(digits)) return `+1${digits}`;
  if (/^1[2-9][0-9]{9}$/.test(digits)) return `+${digits}`;
  return null;
}

// The fallback number from setup goes into the receptionist's rules (escalation_rules.fallback_number), where call
// routing and usage limits read it. Setup replaces the number only while it is still exactly the one setup wrote
// (fallback_number_from_setup): once an admin changes it in call routing, the two differ and setup never touches it,
// whatever the source marker says.
export function fallbackPatch(i: { setupNumber: string | null; currentNumber: string | null; currentFromSetup: string | null }):
  { fallback_number: string; fallback_number_source: "setup"; fallback_number_from_setup: string } | null {
  const pick = toE164(i.setupNumber);
  if (!pick) return null;
  const current = clean(i.currentNumber);
  if (current && current !== clean(i.currentFromSetup)) return null;   // set or changed elsewhere (admin call routing)
  if (pick === current) return null;
  return { fallback_number: pick, fallback_number_source: "setup", fallback_number_from_setup: pick };
}

// The fallback must ring a person, not the line that already forwards into Zella Voice (that would loop).
export function sameLine(a: unknown, b: unknown): boolean {
  const x = toE164(a), y = toE164(b);
  return !!x && x === y;
}

// The receptionist's voice chosen in the create business wizard (sql/zella_cartesia_voices.sql). Kept in
// voice_config.voice_id; it becomes the business_voice row through zella_setup_voice_apply only when the wizard's choice
// changes, so saving the step again never undoes a voice the owner picked later in Settings. "" = the platform default.
export const VOICE_ID_RE = /^[A-Za-z0-9_-]{2,64}$/;
export function wizardVoice(saved: unknown, input: Record<string, unknown>): { voiceId: string; changed: boolean } | { error: string } {
  const before = typeof saved === "string" ? saved.trim() : "";
  if (!("voiceId" in input)) return { voiceId: before, changed: false };
  const raw = input.voiceId;
  if (raw !== null && raw !== undefined && typeof raw !== "string") return { error: "Pick a voice from the list." };
  const voiceId = typeof raw === "string" ? raw.trim() : "";
  if (voiceId && !VOICE_ID_RE.test(voiceId)) return { error: "Pick a voice from the list." };
  return { voiceId, changed: voiceId !== before };
}

// zella_setup_voice_apply's refusals, in words for the admin
export const VOICE_REASONS: Record<string, string> = {
  NOT_ALLOWED: "You need permission to manage businesses to choose the voice.",
  NOT_FOUND: "This business no longer exists.",
  UNKNOWN_VOICE: "Pick a voice from the list.",
  MISSING: "Choosing the voice here needs the latest Zella Voice update. Leave it on the default for now.",
};
