// The business's own email address (docs/ARCHITECTURE.md §14.4): what the setup screens say, worked out from the
// database's answer (zella_business_email_status) and the business-email function's answers. Pure, so it is tested
// without a browser (businessEmailSetup.test.mjs). Every word here is read by people: no dashes or hyphens (BRD-6).

// The business-email function's short error names, in words: what happened, whether anything was saved, what to do.
const REASONS = {
  bad_address: "That isn't an email address that can send. Check it and try again. Nothing was saved.",
  free_mailbox_domain: "That's a Gmail, Outlook or other free mailbox address, so its domain can't be verified. Connect the mailbox instead, or use an address on the business's own domain. Nothing was saved.",
  platform_domain: "That's a Zella Voice address. Use the business's own address. Nothing was saved.",
  domain_taken: "Another business on Zella Voice already set up this domain. If it belongs to this business, contact Zella Voice support: when the other setup isn't verified, the Zella Voice team can remove it. Nothing was saved.",
  not_allowed: "You can't change this business's email address. Owners and admins of the business, and Zella Voice admins who manage businesses, can.",
  not_set_up: "No business domain is set up yet. Enter the business's address first.",
  provider_not_configured: "Business domains can't be checked yet: Zella Voice's email provider key isn't set up. Nothing was saved. Contact Zella Voice support.",
  provider_unavailable: "The email provider didn't answer. Nothing was saved. Try again in a minute.",
  provider_refused: "The email provider couldn't add this domain. Check the address, or contact Zella Voice support. Nothing was saved.",
  rate_limited: "Too many attempts. Wait a minute and try again.",
  sign_in_required: "Your sign in has ended. Sign in again and try once more.",
  not_configured: "Business email setup isn't available yet. Contact Zella Voice support.",
  // connecting a mailbox
  not_your_sign_in: "The mailbox wasn't connected: the sign in was started by someone else. Start it again from this page.",
  link_expired: "The mailbox wasn't connected: the sign in took too long or was already used. Start it again.",
  no_refresh_token: "The mailbox wasn't connected: the provider didn't give lasting access. Start again and allow access when asked.",
  no_account_email: "The mailbox wasn't connected: the provider didn't say which address it is. Start again.",
  access_denied: "The mailbox wasn't connected: access wasn't allowed on the provider's page.",
  invalid_grant: "The mailbox wasn't connected: the provider's sign in had expired. Start again.",
  // the "Connect your mailbox" link an admin sends the owner (owner, 27 Nov 2026)
  already_connected: "The business's mailbox is already connected, so no link was sent.",
  too_many_links: "Five links were already sent today. No link was sent. Try again tomorrow, or ask the owner to connect from Settings.",
  no_owner: "This business has no owner yet, so no link was sent. Invite the owner first.",
  no_owner_email: "The owner's sign in has no usable email address, so no link was sent.",
  business_not_active: "This business is paused or closed, so no link was sent.",
  email_not_queued: "The link was made, but its email couldn't be queued. Nothing was sent. Send a new link.",
  mailbox_link_not_found: "This link doesn't work. Ask the Zella Voice team for a new one, or connect your mailbox below.",
  mailbox_link_used: "This link was already used. You can connect your mailbox below at any time.",
  mailbox_link_replaced: "A newer link was sent after this one, so this one no longer works. Use the newest link, or connect your mailbox below.",
  mailbox_link_expired: "This link expired after 7 days. You can still connect your mailbox below, or ask the Zella Voice team for a new link.",
  mailbox_link_not_yours: "This link was sent to the business owner. Sign in as the owner to use it.",
  not_owner: "Only the business owner can use this link. Nothing was changed.",
  // removing a pending domain (owner, 27 Nov 2026)
  reason_required: "Write the reason first (at least 3 characters). Nothing was removed.",
  not_pending: "Only a domain that isn't verified can be removed this way. Nothing was removed.",
};
// where the provider sends the person back (business-email): ?mailbox=cancelled|error&reason=...
export function mailboxReturn(search) {
  let q;
  try { q = new URLSearchParams(typeof search === "string" ? search : ""); } catch { return null; }
  const outcome = q.get("mailbox"), why = q.get("reason") ?? "";
  if (outcome === "cancelled") return { tone: "warning", text: why === "access_denied" ? reasonWords("access_denied") : "The mailbox wasn't connected: the sign in was canceled." };
  if (outcome === "error") return { tone: "error", text: reasonWords(/^[a-z_]{1,40}$/.test(why) ? why : "") };
  return null;
}
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
    // pending domains expire (owner, 27 Nov 2026); the date is there only while the daily job that removes them is on
    const expires = status.domain_expires_on ? ` If it isn't verified by ${status.domain_expires_on}, it is removed from the setup and can be set up again.` : "";
    if (status.domain_status === "failed") return { badge: "Not verified", tone: "danger", text: `The DNS records for ${status.domain} didn't check out. Check them and press Verify again. Until then: ${fallback}.${expires}` };
    return { badge: "Waiting for DNS", tone: "neutral", text: `Waiting for the DNS records for ${status.domain}. Until they work: ${fallback}.${expires}` };
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

// A connected mailbox's limits (owner, 27 Nov 2026: 80% of the provider's daily limit, at most 20 a minute), from the
// status read. null when no mailbox is connected.
const TYPES = { gmail: "free Gmail", google_workspace: "Google Workspace", outlook: "Outlook.com", microsoft_365: "Microsoft 365" };
export function mailboxLimits(status) {
  if (!status || status.route !== "mailbox" || !Number.isInteger(status.mailbox_daily_cap)) return null;
  const box = status.mailbox_provider === "outlook" ? "Outlook" : "Gmail";
  const type = TYPES[status.mailbox_type] ? TYPES[status.mailbox_type] : `the type isn't known, so the lowest ${box} limit`;
  const n = (v) => Number(v).toLocaleString("en-US");
  const perMinute = Number.isInteger(status.mailbox_per_minute) ? ` and ${n(status.mailbox_per_minute)} a minute` : "";
  const today = Number.isInteger(status.mailbox_sent_today) ? ` ${n(status.mailbox_sent_today)} sent today.` : "";
  return `Up to ${n(status.mailbox_daily_cap)} emails a day (${type})${perMinute}.${today}`;
}

// The latest "Connect your mailbox" link an admin sent the owner, in words, or null when none was sent.
export function linkSummary(link) {
  if (!link || !link.status) return null;
  if (link.status === "open") return { tone: "neutral", text: `A link was sent to the owner. It works once, until ${link.expires_on}.` };
  if (link.status === "used") return { tone: "success", text: "The owner opened the link. They connect Gmail or Outlook themselves." };
  if (link.status === "expired") return { tone: "neutral", text: "The last link expired before it was used. Send a new one if the owner still needs it." };
  return { tone: "neutral", text: "A newer link replaced the last one." };
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
