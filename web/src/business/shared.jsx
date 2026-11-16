// Pieces every tab of one business's page uses (BusinessDetails.jsx and business/*Tab.jsx).
export const TERM_ROWS = [
  ["customer", "customers", "Customers"],
  ["staff", "staff_plural", "Staff"],
  ["service", "services", "Services"],
  ["appointment", "appointments", "Appointments"],
  ["job", "jobs", "Jobs"],
  ["visit", "visits", "Visits"],
];

export const DAYS = [
  ["mon", "Monday"], ["tue", "Tuesday"], ["wed", "Wednesday"], ["thu", "Thursday"],
  ["fri", "Friday"], ["sat", "Saturday"], ["sun", "Sunday"],
];

export const LABELS = {
  answer_questions: "Answer questions", answer_calls: "Answer calls", handle_sms: "Reply to texts",
  send_emails: "Send emails", book_appointments: "Book appointments",
  reschedule_appointments: "Reschedule appointments", cancel_appointments: "Cancel appointments",
  collect_customer_info: "Collect customer details", follow_up_leads: "Follow up with leads",
  take_messages: "Take messages",
  customer_requests_human: "Customer asks for a person", unknown_answer: "AI doesn't know the answer",
  upset_customer: "Customer is upset", emergency: "Emergency", sensitive_issue: "Sensitive issue",
  complex_request: "Complex request", billing_question: "Billing question",
  owner: "Business owner", manager: "Manager", team_member: "Team member", phone_number: "Phone number",
  "en-US": "English", "es-US": "Spanish", "en-US+es-US": "English and Spanish",
  new_number: "New Zella Voice number", call_forwarding: "Call forwarding", existing_number: "Call forwarding",
  always: "All calls", no_answer: "When nobody answers", busy_or_no_answer: "When busy or nobody answers",
  after_hours: "After business hours",
  google: "Google", outlook: "Outlook", gmail: "Gmail", none: "None",
};

export const label = (key) => LABELS[key] ?? key;

export const POLICY_LABELS = {
  cancellation: "Cancellation", refund: "Refund", payment: "Payment",
  emergency: "Emergency", appointment: "Appointment", other: "Other information",
};

const beforeText = (h) => (h < 1 ? `${Math.round(h * 60)} min` : `${h} h`);

export function describeSettings(settings = {}) {
  const parts = [];
  if (Array.isArray(settings.hours_before)) {
    parts.push(settings.hours_before.length ? `${settings.hours_before.map(beforeText).join(", ")} before` : "no reminder times");
  } else if (settings.hours_before) parts.push(`${beforeText(settings.hours_before)} before`);
  if (settings.hours_after) parts.push(`${settings.hours_after} h after`);
  if (settings.minutes_after != null) parts.push(settings.minutes_after === 0 ? "immediately" : `after ${settings.minutes_after} min`);
  if (settings.max_attempts) parts.push(`up to ${settings.max_attempts} tries`);
  if (settings.retry_after_hours) parts.push(`retry after ${settings.retry_after_hours} h`);
  if (settings.channel) parts.push(`by ${settings.channel.replace("sms_and_call", "text and call").replace("sms", "text")}`);
  if (settings.fallback_sms) parts.push("text if unanswered");
  return parts.join(" · ") || "Default settings";
}

export function Facts({ items }) {
  return (
    <dl className="op-facts">
      {items.map(([term, value]) => (
        <div key={term}>
          <dt>{term}</dt>
          <dd>{value || <span className="op-muted">Not set</span>}</dd>
        </div>
      ))}
    </dl>
  );
}

export function Card({ title, description, action, children }) {
  return (
    <section className="owner-panel op-card">
      <div className="owner-panel-heading">
        <div>
          <h2>{title}</h2>
          {description && <p>{description}</p>}
        </div>
        {action}
      </div>
      <div className="op-card-body">{children}</div>
    </section>
  );
}

export function Empty({ children }) {
  return <div className="op-empty">{children}</div>;
}

export function Check({ ok, later, title, detail }) {
  return (
    <li className="op-check">
      <span className={`op-check-dot ${ok ? "ok" : later ? "later" : "missing"}`} role="img"
        aria-label={ok ? "Done" : later ? "Not yet, can wait" : "Needed"}>{ok ? "✓" : later ? "…" : "!"}</span>
      <div>
        <strong>{title}</strong>
        <span>{detail}</span>
      </div>
    </li>
  );
}
