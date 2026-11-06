// Batch 3 inbox helpers (B3-02, B3-06). Pure, unit-tested in tests/batch3_unit.test.mjs.

// one row of zella_inbox_page -> the item the inbox renders
export function inboxItem(r) {
  const row = r?.row ?? {};
  const isCall = r?.kind === "call";
  return { key: `${isCall ? "c" : "v"}${r?.id}`, kind: isCall ? "call" : "convo", at: r?.at, customer_id: row.customer_id ?? null,
    ...(isCall ? { call: row } : { convo: row }) };
}

// whether texting or email is connected; null when the lookup failed (unknown is not "not connected")
/**
 * Return whether an active provider matches SMS or email, or null unless the lookup
 * status is "ok" (including while loading). Unsupported channels return false after a successful lookup.
 */
export function connected(integrations, channel) {
  if (!integrations || integrations.status !== "ok") return null;
  const rows = (integrations.rows ?? []).filter((i) => i.status === "active").map((i) => (i.provider ?? "").toLowerCase());
  if (channel === "sms") return rows.some((p) => p.includes("telnyx"));
  if (channel === "email") return rows.some((p) => /email|smtp|sendgrid|resend|gmail/.test(p));
  return false;
}

// Why a reply can't be written now, or null. Fails closed: if the person's contact preferences or the channel's
// connection couldn't be checked, the reply waits for a retry. { text, retry } - retry: a lookup failed.
export function replyBlock({ channel, person, personStatus, integrations }) {
  const name = channel === "sms" ? "Text messaging" : "Email";
  if (!["sms", "email"].includes(channel)) return { text: "Replies aren't available for this kind of conversation." };
  if (personStatus === "failed") return { text: "Couldn't check this person's contact preferences, so replying is paused.", retry: true };
  if (personStatus === "loading") return { text: "Checking contact preferences…" };
  if (!person) return { text: "This conversation isn't linked to a person yet." };
  if (person.do_not_contact || (channel === "sms" && person.do_not_sms) || (channel === "email" && person.do_not_email)) {
    return { text: "This person asked not to be contacted this way." };
  }
  if (!(channel === "sms" ? person.phone : person.email)) return { text: `Add ${channel === "sms" ? "a phone number" : "an email address"} to their profile first.` };
  const isConnected = connected(integrations, channel);
  if (integrations?.status === "loading") return { text: `Checking whether ${name.toLowerCase()} is connected…` };
  if (isConnected === null) return { text: `Couldn't check whether ${name.toLowerCase()} is connected, so replying is paused.`, retry: true };
  if (!isConnected) return { text: `${name} isn't connected yet. Connect it under Integrations to reply from here.` };
  return null;
}

// the partial-data warning when the list loaded but something that supports it didn't (no message content in it)
export function supportProblems({ previews, people, integrations }) {
  const failed = [previews?.error && "message previews", people?.error && "names and contact preferences", integrations?.error && "connected channels"].filter(Boolean);
  if (!failed.length) return "";
  const list = failed.length === 1 ? failed[0] : `${failed.slice(0, -1).join(", ")} and ${failed[failed.length - 1]}`;
  return `Some details couldn't be loaded: ${list}. The list is complete; replies wait until contact details can be checked.`;
}
