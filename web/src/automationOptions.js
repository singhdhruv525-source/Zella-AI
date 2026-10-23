// The options an owner can change for each automation. Every value here is one
// the database accepts (see zella_clean_automation_config).
const SMS_CALL = [["sms", "Text"], ["call", "AI call"]];
const SMS_EMAIL = [["sms", "Text"], ["email", "Email"]];
const TRIES = [[1, "1 try"], [2, "2 tries"], [3, "3 tries"]];

export const AUTOMATION_OPTIONS = {
  appointment_reminder: [
    { key: "hours_before", label: "Remind them", kind: "chips", options: [[48, "2 days before"], [24, "1 day before"], [4, "4 hours before"], [2, "2 hours before"], [1, "1 hour before"], [0.5, "30 minutes before"], [0.25, "15 minutes before"]] },
    { key: "channel", label: "Send by", options: [["sms", "Text"], ["call", "AI call"], ["sms_and_call", "Text and AI call"]] },
  ],
  appointment_confirmation: [
    { key: "hours_before", label: "Ask them to confirm", options: [[24, "1 day before"], [48, "2 days before"], [72, "3 days before"]] },
    { key: "channel", label: "Send by", options: SMS_CALL },
  ],
  no_show_follow_up: [
    { key: "minutes_after", label: "Reach out after", options: [[10, "10 minutes"], [15, "15 minutes"], [30, "30 minutes"], [60, "1 hour"]] },
    { key: "channel", label: "Reach out by", options: [["call", "AI call"], ["sms", "Text"]] },
  ],
  missed_call_follow_up: [
    { key: "minutes_after", label: "Call back", options: [[0, "Immediately"], [5, "After 5 minutes"], [15, "After 15 minutes"], [30, "After 30 minutes"]] },
    { key: "max_attempts", label: "Try up to", options: TRIES },
    { key: "fallback_sms", label: "If they don't answer", kind: "check", text: "Send a text message" },
  ],
  new_lead_callback: [
    { key: "minutes_after", label: "Call new leads", options: [[0, "Immediately"], [5, "After 5 minutes"], [15, "After 15 minutes"], [60, "After 1 hour"]] },
    { key: "max_attempts", label: "Try up to", options: TRIES },
    { key: "retry_after_hours", label: "Try again after", options: [[1, "1 hour"], [4, "4 hours"], [24, "1 day"]] },
    { key: "contact_within_minutes", label: "Aim to reach them within", options: [[5, "5 minutes"], [15, "15 minutes"], [30, "30 minutes"], [60, "1 hour"]] },
    { key: "escalate_after_minutes", label: "Tell the team after", options: [[30, "30 minutes"], [60, "1 hour"], [120, "2 hours"], [240, "4 hours"]] },
    { key: "fallback_sms", label: "If they don't answer", kind: "check", text: "Send a text message" },
  ],
  post_appointment_follow_up: [
    { key: "hours_after", label: "Follow up after", options: [[2, "2 hours"], [24, "1 day"], [72, "3 days"]] },
    { key: "channel", label: "Send by", options: SMS_EMAIL },
  ],
  quote_follow_up: [
    { key: "hours_after", label: "Follow up after", options: [[24, "1 day"], [48, "2 days"], [72, "3 days"]] },
    { key: "max_attempts", label: "Try up to", options: TRIES },
    { key: "channel", label: "Send by", options: SMS_EMAIL },
  ],
  lead_reactivation: [
    { key: "days_inactive", label: "Reach out after", options: [[14, "2 weeks quiet"], [30, "30 days quiet"], [60, "60 days quiet"], [90, "90 days quiet"]] },
    { key: "channel", label: "Send by", options: SMS_EMAIL },
  ],
  waitlist_offer: [
    { key: "offers", label: "Offer to", options: [[1, "1 person"], [2, "2 people"], [3, "3 people"], [5, "5 people"]] },
    { key: "offer_minutes", label: "Each person has", options: [[15, "15 minutes"], [30, "30 minutes"], [60, "1 hour"]] },
    { key: "channel", label: "Send by", options: SMS_CALL },
  ],
  staff_unavailable: [
    { key: "channel", label: "Notify by", options: SMS_CALL },
  ],
};
