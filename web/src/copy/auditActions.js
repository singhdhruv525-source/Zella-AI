// The words admins see for each audit_logs action, on a business's Activity tab and on Audit logs (BIZ-25).
// Every action Zella Voice writes has a label here; web/tests/auditActions.test.mjs scans sql/*.sql and the admin
// function for action names and fails when one is missing. An action built at run time ("offer." + kind) is labelled
// by its family below. Anything else still reads as words (humanize), never as raw code.
import { humanize } from "./labels.js";

export const ACTION_LABELS = {
  // business setup (owner-provision-business)
  "business.draft_created": "Created business draft",
  "business.updated": "Updated business details",
  "business.industry_changed": "Changed industry",
  "owner.saved": "Saved business owner",
  "terminology.updated": "Updated terminology",
  "modules.updated": "Updated modules",
  "ai_receptionist.updated": "Updated AI receptionist",
  "integrations.preferences_updated": "Updated phone & integrations",
  "automations.updated": "Updated automations",
  "invitation.sent": "Finished setup · invitation sent",
  "invitation.failed": "Finished setup · invitation failed",
  "setup.finished": "Finished setup",
  "business.size_changed": "Changed business size",
  "business.record_types_updated": "Changed record types",
  "business.team_updated": "Updated team",
  "business.operations_updated": "Updated business operations",
  "business.document_uploaded": "Uploaded verification document",
  "business.document_viewed": "Viewed verification document",

  // lifecycle and invitations
  "business.suspended": "Suspended business",
  "business.reactivated": "Reactivated business",
  "business.cancellation_scheduled": "Scheduled cancellation",
  "business.cancellation_undone": "Undid cancellation",
  "business.cancelled": "Business canceled (end of month)",
  "business.continued_by_owner": "Owner continued their plan (email link)",
  "business.viewed": "Opened business (support access)",
  "invitation.resent": "Resent owner invitation",
  "invitation.revoked": "Canceled owner invitation",
  "invitation.accepted": "Invitation accepted",
  "staff_invitation.sent": "Sent team invitation",
  "member.suspended": "Deactivated member",
  "member.reactivated": "Reactivated member",
  "member.mfa_reset": "Reset member two step sign in",
  "support.contacts_revealed": "Revealed contact details",

  // platform and admins
  "industry.created": "Created industry",
  "industry.updated": "Updated industry configuration",
  "industry.records_created": "Added industry record types",
  "industry.records_updated": "Updated industry record types",
  "admin.added": "Added platform admin",
  "admin.reactivated": "Reactivated platform admin",
  "admin.updated": "Changed platform admin access",
  "admin.call_content_viewed": "Viewed call transcript or recording",
  "admin.message_content_viewed": "Viewed message content",
  "ticket.created": "Created support ticket",
  "ticket.updated": "Updated support ticket",
  "plan.created": "Created plan",
  "plan.updated": "Updated plan",
  "plan.entitlements_updated": "Updated plan allowances",
  "platform.setting_updated": "Changed platform setting",
  "platform.maintenance_updated": "Changed maintenance mode",
  "platform.profile_updated": "Updated platform profile",
  "platform.roles_updated": "Changed role permissions",
  "platform.spam_automation_updated": "Changed spam automation",
  "platform.spam_policy_updated": "Changed spam policy",
  "platform.spam_rule_added": "Added spam rule",
  "platform.spam_rule_removed": "Removed spam rule",
  "audit_write_failed": "Audit record failed to save",
  "session.revoked": "Signed out a session",

  // billing
  "billing.voice_pricing_added": "Added voice pricing",
  "billing.pack_granted": "Granted an allowance pack",
  "billing.plan_saved": "Saved business plan",
  "billing.auto_reload_updated": "Changed automatic top up",
  "billing.usage_preferences_updated": "Changed usage preferences",
  "billing.usage_retry": "Retried usage recording",

  // phone and messages
  "telephony.number_assigned": "Assigned phone number",
  "telephony.number_released": "Released phone number",
  "telephony.number_status": "Changed phone number status",
  "telephony.routing_updated": "Changed call routing",
  "comms.message_retried": "Retried message",
  "comms.template_updated": "Updated message template",
  "template.saved": "Saved message template",

  // automations
  "automation.paused": "Paused automation",
  "automation.resumed": "Resumed automation",
  "automation.archived": "Turned off automation",
  "automation.business_paused": "Paused all automations",
  "automation.changed": "Changed automation",
  "automation.dead_letter_dismissed": "Dismissed failed automation event",
  "automation.dead_letter_retried": "Retried failed automation event",
  "automation.defaults_applied": "Applied default automations",
  "automation.failure_reviewed": "Reviewed automation failure",
  "automation.run_retried": "Retried automation run",
  "industry_rules.changed": "Changed industry rules",
  "assignment_rules.updated": "Changed assignment rules",

  // the business's own changes (business app)
  "business.closure_added": "Added a closure",
  "business.closure_removed": "Removed a closure",
  "business.hours_updated": "Changed business hours",
  "business.logo_updated": "Changed logo",
  "business.profile_updated": "Updated business profile",
  "business.terminology_updated": "Updated terminology",
  "receptionist.services_changed": "Changed receptionist services",
  "receptionist.voice_changed": "Changed receptionist voice",
  "website_form.updated": "Updated website form",
  "legal.accepted": "Accepted legal terms",
  "legal.draft_created": "Created legal draft",
  "legal.draft_updated": "Updated legal draft",
  "spam.settings_updated": "Changed spam settings",
  "spam.list_added": "Added to spam list",
  "spam.list_removed": "Removed from spam list",
  "call.escalated": "Escalated a call",
  "call.escalation_resolved": "Resolved a call escalation",
  "call.followed_up": "Followed up a call",
  "call.updated": "Updated a call",
  "customer.added": "Added customer",
  "customer.merged": "Merged customers",
  "customer.updated": "Updated customer",
  "inbox.handover": "Handed conversation to the team",
  "inbox.returned_to_ai": "Returned conversation to the AI",
  "inbox.updated": "Updated conversation",
  "lead.plan_changed": "Changed lead plan",
  "offer_rule.updated": "Changed offer rule",
};

// What each table is called in the automatic change records written by the database (privileged_*).
const TABLE_WORDS = {
  businesses: "business", business_members: "member", ai_agents: "AI receptionist", automations: "automation",
  platform_settings: "platform setting", platform_admins: "platform admin",
};
const OPERATION_WORDS = { insert: "Added", update: "Changed", delete: "Removed" };

// Families: actions whose last part is chosen at run time. [prefix, (rest, entityType) => label]
export const ACTION_FAMILIES = [
  ["privileged_", (op, table) => `${OPERATION_WORDS[op] ?? humanize(op)} ${TABLE_WORDS[table] ?? (table ? humanize(table).toLowerCase() : "record")} (system record)`],
  ["business.document_", (status) => `Verification document ${humanize(status).toLowerCase()}`],
  ["business.request_", (kind) => `Business request: ${humanize(kind).toLowerCase()}`],
  ["platform.alert_", (status) => `Platform alert ${humanize(status).toLowerCase()}`],
  ["spam.incident_", (status) => `Spam incident ${humanize(status).toLowerCase()}`],
  ["automation.", (rest) => `Automation ${humanize(rest).toLowerCase()}`],
  ["integration.", (rest) => `Integration ${humanize(rest).toLowerCase()}`],
  ["offer.", (rest) => `Offer ${humanize(rest).toLowerCase()}`],
  ["legal.", (rest) => `Legal document ${humanize(rest).toLowerCase()}`],
  ["attendance.", (rest) => `Attendance ${humanize(rest).toLowerCase()}`],
  ["call_insight.", (rest) => `Call insight ${humanize(rest).toLowerCase()}`],
  ["approval_", (rest) => `Approval ${humanize(rest).toLowerCase()}`],
  ["charge_", (rest) => `Charge ${humanize(rest).toLowerCase()}`],
  ["workflow_", (rest) => `Workflow ${humanize(rest).toLowerCase()}`],
];

// The label for one audit row. entityType (audit_logs.entity_type) names the table for system records.
export function actionLabel(action, entityType) {
  const key = String(action ?? "");
  if (Object.hasOwn(ACTION_LABELS, key)) return ACTION_LABELS[key];
  for (const [prefix, word] of ACTION_FAMILIES) {
    if (key.startsWith(prefix) && key.length > prefix.length) return word(key.slice(prefix.length), entityType);
  }
  return humanize(key) || "Unknown action";
}
