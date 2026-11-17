// The words admins see for Zella Voice's platform settings (the platform_settings table). The key is code: it is
// shown only as small help text under the label, never as the label itself. A key that isn't listed still reads as
// words (humanize), so a new setting never appears as raw code.
import { humanize } from "./labels.js";

export const SETTING_LABELS = {
  // Operational rules: timings and thresholds the scheduled checks read
  response_time_minutes: "Lead reply target (minutes)",
  task_overdue_grace_minutes: "Grace before a task is overdue (minutes)",
  task_escalate_hours: "Send overdue tasks to the owner after (hours)",
  team_summary_hour: "Daily team summary hour",
  missed_call_max_seconds: "Missed call cutoff (seconds)",
  transfer_failure_threshold: "Failed transfers a day before flagging",
  call_intel_monthly_limit: "AI call summaries per business each month",
  ai_low_confidence_questions: "Unsure answers before a call is flagged",
  knowledge_repeat_threshold: "Repeats before a question is suggested as knowledge",
  response_sample_rate: "Share of AI conversations reviewed",
  invitation_reminder_hours: "Invitation reminders after (hours)",
  setup_incomplete_after_days: "Flag an unfinished setup after (days)",
  trial_notice_days: "Tell the owner before a trial ends (days)",
};

export const settingLabel = (key) => SETTING_LABELS[key] ?? humanize(key);
