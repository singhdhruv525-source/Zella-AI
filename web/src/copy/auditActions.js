// The words admins see for each audit_logs action, on a business's Activity tab (BIZ-25). The labels come from the one
// shared list, web/supabase/functions/_shared/catalog.json (PLT-08), whose drift test fails when SQL or an edge
// function writes an action that isn't listed there. This file only adds what a single row needs on top:
// the database's own change records (privileged_*) name the table they changed, and anything unknown still reads as
// words (humanize), never as raw code.
import catalog from "../../supabase/functions/_shared/catalog.json" with { type: "json" };
import { humanize } from "./labels.js";

export const ACTION_LABELS = Object.freeze({ ...catalog.audit_actions });

// What each table is called in the automatic change records written by zella_audit_privileged (privileged_*).
const TABLE_WORDS = {
  businesses: "business", business_members: "member", ai_agents: "AI receptionist", automations: "automation",
  platform_settings: "platform setting", platform_admins: "platform admin",
};
const OPERATION_WORDS = { insert: "Added", update: "Changed", delete: "Removed" };

// The label for one audit row. entityType (audit_logs.entity_type) names the table for system records.
export function actionLabel(action, entityType) {
  const key = String(action ?? "");
  const system = /^privileged_(insert|update|delete)$/.exec(key);
  if (system && entityType) {
    const table = TABLE_WORDS[entityType] ?? humanize(entityType).toLowerCase();
    return `${OPERATION_WORDS[system[1]]} ${table} (system record)`;
  }
  if (Object.hasOwn(ACTION_LABELS, key)) return ACTION_LABELS[key];
  return humanize(key) || "Unknown action";
}
