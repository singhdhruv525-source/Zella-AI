// Labels and money formatting for Admin > Plans & subscriptions > Payments (BillingRecords.jsx). Amounts arrive as
// integer cents from the database; this only formats them for display.
// A missing or blank amount is "Not available", never $0.00; an explicit 0 is $0.00.
export const usd = (cents) => (cents === null || cents === undefined || String(cents).trim() === "" || !Number.isFinite(Number(cents))
  ? "Not available" : (Number(cents) / 100).toLocaleString("en-US", { style: "currency", currency: "USD" }));

export const INVOICE_STATUS = { draft: ["Draft", "neutral"], open: ["Open", "info"], paid: ["Paid", "success"], payment_failed: ["Payment failed", "danger"],
  void: ["Canceled", "neutral"], uncollectible: ["Not collected", "warning"] };
export const REFUND_STATUS = { requested: ["Waiting for approval", "warning"], sending: ["Sending", "info"], processed: ["Refunded", "success"],
  failed: ["Failed", "danger"], rejected: ["Declined", "neutral"], uncertain: ["Held for a person", "warning"] };
export const DISPUTE_STATUS = { open: ["Open", "danger"], won: ["Won", "success"], lost: ["Lost", "danger"], warning_closed: ["Closed, no chargeback", "neutral"], closed: ["Closed", "neutral"] };
export const REFUND_KIND = { guarantee: "30 day guarantee", setup_fee: "Setup fee", pack: "Unused pack", annual: "Yearly renewal", error: "Charged in error", outside: "Made in Stripe" };

