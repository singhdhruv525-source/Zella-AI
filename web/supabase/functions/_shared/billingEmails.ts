// Zella Voice: billing emails (docs/PAYMENTS_ARCHITECTURE.md §6.11). The billing worker renders each notice the
// database decided (billing_email_intents) with the shared catalogue, strictly (a fact the email needs and the data
// doesn't have holds that email instead of inventing a value), and queues one copy per owner in the platform outbox.
// Nothing is sent here: the platform outbox stays in test mode while email_live is off.
import * as catalogue from "./businessEmails.js";
import type { Rpc } from "./billingWorker.ts";

// the catalogue is plain JavaScript shared with the web app's preview; its data shape is the sample's, which strict mode checks at run time
const renderEmail = catalogue.renderEmail as unknown as (code: string, data: Record<string, unknown>, o: { strict: boolean }) => { subject: string; html: string; text: string };

type Intent = { id: string; business_id: string; code: string; dedupe_key: string; data: Record<string, unknown>; recipients: { user_id: string; email: string; owner: string }[] };

export async function queueBillingEmails(rpc: Rpc, limit = 20): Promise<Record<string, number>> {
  const counts: Record<string, number> = {};
  const rows = (await rpc("zella_billing_email_claim", { p_limit: limit })) as Intent[] | null;
  for (const it of rows ?? []) {
    let status = "queued", error: string | null = null;
    try {
      if (!it.recipients?.length) throw new Error("NO_RECIPIENT");
      for (const r of it.recipients) {
        // the business id lets Pay now and Update card open this business's Payments page (an invoice's own page when the data names it)
        const mail = renderEmail(it.code, { ...it.data, owner: r.owner, businessId: it.business_id }, { strict: true });
        await rpc("zella_queue_platform_email", {
          p_business: it.business_id, p_code: it.code, p_dedupe_key: `${it.dedupe_key}:${r.user_id}`, p_to: r.email,
          p_subject: mail.subject, p_html: mail.html, p_text: mail.text, p_mandatory: true, p_user: r.user_id, p_cc: [],
        });
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      // a missing fact or no owner is held for a person; anything else is tried again
      status = /^(MISSING_FIELD|UNKNOWN_EMAIL|NO_RECIPIENT)/.test(msg) ? "held" : "pending";
      error = msg.slice(0, 300);
    }
    await rpc("zella_billing_email_done", { p_id: it.id, p_status: status, p_error: error });
    counts[status] = (counts[status] ?? 0) + 1;
  }
  return counts;
}
