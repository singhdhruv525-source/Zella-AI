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
// routing and usage limits read it. A number an admin set in call routing (not from setup) is never replaced.
export function fallbackPatch(i: { setupNumber: string | null; currentNumber: string | null; currentSource: string | null }):
  { fallback_number: string; fallback_number_source: "setup" } | null {
  const pick = toE164(i.setupNumber);
  if (!pick) return null;
  if (clean(i.currentNumber) && i.currentSource !== "setup") return null;
  if (pick === clean(i.currentNumber)) return null;
  return { fallback_number: pick, fallback_number_source: "setup" };
}
