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
