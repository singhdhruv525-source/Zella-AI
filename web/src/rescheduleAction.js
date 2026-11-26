// What the customer link's page (/r/<code>, Reschedule.jsx) is asked to do. Pure, so it is tested without a browser
// (rescheduleAction.test.mjs).
//   /r/<code>              pick a new time (the Reschedule button in texts and emails)
//   /r/<code>?do=confirm   the Confirm button in confirmation and reminder emails
//   /r/<code>?do=cancel    the Cancel button in those emails
// The page always asks first and acts only on its own button: mail scanners open links before people do (SEC-20), so
// opening a link never changes a booking (sql/zella_email_action_buttons.sql).
export function pageAction(search) {
  let value = null;
  try { value = new URLSearchParams(typeof search === "string" ? search : "").get("do"); } catch { value = null; }
  return value === "confirm" || value === "cancel" ? value : "reschedule";
}

// the reschedule-appointment action for each button
export const ATTEND_ACTION = { confirm: "attend_confirm", cancel: "attend_cancel" };

// The server's answer, in the page's terms: "confirmed", "already_confirmed", "cancelled", or a problem the page
// already explains (invalid, not_available, past). Anything else is a problem too, never a success (UX-2).
export function attendOutcome(answer) {
  if (answer?.ok === true && ["confirmed", "already_confirmed", "cancelled"].includes(answer.result)) return { done: answer.result };
  const reason = ["invalid", "not_available", "past"].includes(answer?.reason) ? answer.reason : "invalid";
  return { problem: reason };
}
