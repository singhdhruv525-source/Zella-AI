// The business's own email address (docs/ARCHITECTURE.md §14.4): what the setup screens say, worked out from the
// database's answer (zella_business_email_status) and the business-email function's answers. Pure, so it is tested
// without a browser (businessEmailSetup.test.mjs). Every word here is read by people: no dashes or hyphens (BRD-6).

// The business-email function's short error names, in words: what happened, whether anything was saved, what to do.
const REASONS = {
  bad_address: "That isn't an email address that can send. Check it and try again. Nothing was saved.",
  free_mailbox_domain: "That's a Gmail, Outlook or other free mailbox address, so its domain can't be verified. Connect the mailbox instead, or use an address on the business's own domain. Nothing was saved.",
  platform_domain: "That's a Zella Voice address. Use the business's own address. Nothing was saved.",
  domain_taken: "Another business on Zella Voice already set up this domain. If it belongs to this business, contact Zella Voice support. Nothing was saved.",
  not_allowed: "You can't change this business's email address. Owners and admins of the business, and Zella Voice admins who manage businesses, can.",
  not_set_up: "No business domain is set up yet. Enter the business's address first.",
  provider_not_configured: "Business domains can't be checked yet: Zella Voice's email provider key isn't set up. Nothing was saved. Contact Zella Voice support.",
  provider_unavailable: "The email provider didn't answer. Nothing was saved. Try again in a minute.",
  provider_refused: "The email provider couldn't add this domain. Check the address, or contact Zella Voice support. Nothing was saved.",
  rate_limited: "Too many attempts. Wait a minute and try again.",
  sign_in_required: "Your sign in has ended. Sign in again and try once more.",
  not_configured: "Business email setup isn't available yet. Contact Zella Voice support.",
};
export function reasonWords(code) {
  return REASONS[code] ?? "That didn't work, and nothing was changed. Check your connection and try again.";
}

// One line for "who sends now", with a badge: the setup page and the review step both use it.
export function senderSummary(status) {
  if (!status) return null;
  const name = status.fallback?.from_name || "The business";
  const replies = status.fallback?.reply_to ? `replies go to ${status.fallback.reply_to}` : "replies have nowhere to go until the business email is set";
  const fallback = `${name} at Zella Voice's address; ${replies}`;
  if (status.route === "domain") {
    if (status.domain_status === "verified") {
      return status.active_route === "domain"
        ? { badge: "Verified", tone: "success", text: `Customer emails come from ${status.address}.` }
        : { badge: "Verified", tone: "success", text: `Verified. Customer emails come from ${status.address} once the Zella Voice team switches business addresses on. Until then: ${fallback}.` };
    }
    if (status.domain_status === "failed") return { badge: "Not verified", tone: "danger", text: `The DNS records for ${status.domain} didn't check out. Check them and press Verify again. Until then: ${fallback}.` };
    return { badge: "Waiting for DNS", tone: "neutral", text: `Waiting for the DNS records for ${status.domain}. Until they work: ${fallback}.` };
  }
  if (status.route === "mailbox") {
    const box = status.mailbox_provider === "outlook" ? "Outlook" : "Gmail";
    if (status.mailbox_status !== "connected") return { badge: "Reconnect needed", tone: "danger", text: `${box} (${status.mailbox_account}) no longer lets Zella Voice send. Reconnect it. Until then: ${fallback}.` };
    if (status.active_route === "mailbox") return { badge: "Connected", tone: "success", text: `Customer emails come from ${status.mailbox_account} through ${box}.` };
    if (status.cap_reached_today) return { badge: "Daily limit reached", tone: "neutral", text: `${box} reached its daily sending limit. The rest of today: ${fallback}.` };
    return { badge: "Connected", tone: "success", text: `Connected. Customer emails come from ${status.mailbox_account} once the Zella Voice team switches mailboxes on. Until then: ${fallback}.` };
  }
  return { badge: "Not set up", tone: "neutral", text: `Customer emails come from ${fallback}.` };
}

// The DNS records to add, in the order Resend gives them, as the table shows them. Some DNS hosts add the domain to
// the name themselves, so the name is shown as Resend gives it (relative to the domain).
export function recordRows(records) {
  return (Array.isArray(records) ? records : []).filter((r) => r && r.type && r.name && r.value).map((r, i) => ({
    key: `${i}:${String(r.type).toUpperCase()}:${r.name}`,
    type: String(r.type).toUpperCase(),
    name: String(r.name),
    value: String(r.value),
    priority: Number.isInteger(r.priority) ? String(r.priority) : "",
    ok: r.status === "verified",
  }));
}
