// The CRM sidebar, as configuration. One shared list of modules for every industry; what a business sees is
// decided by three independent checks, all of which must pass:
//   1. industry availability  - the module is in industry_modules for the business's industry
//   2. business enablement    - the business has it switched on (business_modules, or an enabled record type)
//   3. user permission        - the person's role is allowed (business_members.role)
// The database enforces the same rules (zella_navigation.sql and each page's own role checks); hiding an item here
// is presentation only, never the protection.
//
// Item fields
//   id        stable identifier (never shown)
//   group     navigation group id (NAV_GROUPS)
//   order     position inside the group
//   label     text, or a function of the industry's words: (term) => term("customers")
//   icon      Material Symbols name (outline)
//   page      the CRM page key it opens (routes: /app/<page>)
//   settings  instead of a page: a Settings address, "<category>/<page>"
//   module    module slug that must be available and switched on (industry_modules / business_modules)
//   roles     roles allowed to see it; omitted = every member
//   badge     live counter shown beside it ("attention")
//   children  sub-items, shown under the item when it is opened
//
// Only pages that exist and work are listed. Not built yet, so not shown: Voicemails, AI agents (beyond the
// receptionist), Marketing campaigns, Reviews inbox. The Leads page holds the Pipeline view.

export const LEAD_ROLES = ["owner", "admin", "manager"];
export const MANAGE_ROLES = ["owner", "admin"];
export const WORK_ROLES = ["owner", "admin", "manager", "staff"];

export const NAV_GROUPS = [
  { id: "workspace", label: "Workspace" },
  { id: "crm", label: "CRM" },
  { id: "operations", label: null }, // named by the industry configuration
  { id: "communications", label: "Communications" },
  { id: "ai", label: "AI & Automation" },
  { id: "growth", label: "Business Growth" },
  { id: "management", label: "Management" },
];

export const NAV_ITEMS = [
  { id: "today", group: "workspace", order: 10, label: "Today", icon: "dashboard", page: "today" },
  { id: "calendar", group: "workspace", order: 20, label: "Calendar", icon: "calendar_today", page: "calendar" },
  { id: "checkins", group: "workspace", order: 30, label: "Check-ins", icon: "how_to_reg", page: "checkins" },
  { id: "waitlist", group: "workspace", order: 40, label: "Waitlist", icon: "hourglass_top", page: "waitlist", module: "calendar" },
  { id: "tasks", group: "workspace", order: 50, label: "Tasks & Follow-ups", icon: "task_alt", page: "tasks" },

  { id: "leads", group: "crm", order: 10, label: "Leads", icon: "filter_alt", page: "leads" },
  { id: "customers", group: "crm", order: 20, label: (term) => term("customers"), icon: "group", page: "customers" },

  {
    id: "calls-messages", group: "communications", order: 10, label: "Calls & Messages", icon: "forum", badge: "attention",
    children: [
      { id: "attention", label: "Needs attention", icon: "support_agent", page: "attention", badge: "attention" },
      { id: "inbox", label: "Conversations", icon: "inbox", page: "inbox" },
      { id: "messages", label: "Messages", icon: "chat", page: "messages" },
      { id: "calls", label: "Calls", icon: "call", page: "calls", module: "calls" },
      { id: "callbacks", label: "Callbacks", icon: "phone_callback", page: "callbacks" },
      { id: "drafts", label: "Suggested messages", icon: "mark_email_unread", page: "drafts", roles: WORK_ROLES },
      { id: "failed", label: "Didn't send", icon: "error", page: "failed", roles: LEAD_ROLES },
      { id: "spam", label: "Spam protection", icon: "gpp_maybe", page: "spam", roles: LEAD_ROLES },
    ],
  },

  {
    id: "ai-receptionist", group: "ai", order: 10, label: "AI Receptionist", icon: "record_voice_over", module: "ai-receptionist",
    children: [
      { id: "receptionist", label: "Voice and setup", icon: "settings_voice", page: "receptionist" },
      { id: "transcripts", label: "Transcripts", icon: "insights", page: "transcripts", module: "calls" },
      { id: "call-rules", label: "Call handling rules", icon: "alt_route", settings: "receptionist/calls" },
    ],
  },
  { id: "knowledge", group: "ai", order: 15, label: "Knowledge base", icon: "menu_book", page: "knowledge", module: "ai-receptionist" },
  { id: "automations", group: "ai", order: 20, label: "Automations", icon: "bolt", page: "automations", module: "automations" },

  { id: "lead-sources", group: "growth", order: 10, label: "Lead sources", icon: "hub", page: "lead-sources" },
  { id: "reports", group: "growth", order: 20, label: "Reports & Analytics", icon: "monitoring", page: "reports" },

  {
    id: "team-staff", group: "management", order: 10, label: "Team & Staff", icon: "badge",
    children: [
      { id: "team", label: (term) => term("staff_plural"), icon: "groups", page: "team" },
      { id: "access", label: "Team access", icon: "admin_panel_settings", page: "access", roles: MANAGE_ROLES },
      { id: "approvals", label: "Approvals", icon: "verified_user", page: "approvals", roles: MANAGE_ROLES },
      { id: "security", label: "Security log", icon: "history", page: "security", roles: MANAGE_ROLES },
    ],
  },
  { id: "integrations", group: "management", order: 20, label: "Integrations", icon: "extension", page: "integrations" },
  { id: "notifications", group: "management", order: 30, label: "Notifications", icon: "notifications", settings: "notifications/preferences" },
  { id: "settings", group: "management", order: 40, label: "Settings", icon: "settings", page: "settings" },
];

// Turns the configuration into the sidebar for one business and one person.
//   access: { role, modules: Set of enabled module slugs, recordTypes: [...], operationsLabel, configured }
//   term:   the business's words (makeTerm)
export function buildNavigation(access, term) {
  const allowed = (item) =>
    (!item.module || access.modules.has(item.module)) && (!item.roles || item.roles.includes(access.role));
  const shape = (item) => ({ ...item, label: typeof item.label === "function" ? item.label(term) : item.label });

  const items = NAV_ITEMS.filter(allowed).map((item) => {
    if (!item.children) return shape(item);
    const children = item.children.filter(allowed).map(shape);
    return children.length ? { ...shape(item), children } : null;
  }).filter(Boolean);

  // Business Operations: this business's own industry records (crm_record_types), never another industry's.
  const operations = (access.recordTypes ?? []).filter((t) => t.enabled)
    .map((t, n) => ({ id: `rec:${t.key}`, group: "operations", order: n, label: t.plural, icon: t.icon || "folder", page: `rec:${t.key}` }));
  if (LEAD_ROLES.includes(access.role) && (operations.length || access.configured)) {
    operations.push({ id: "record-settings", group: "operations", order: 999, label: "Customise records", icon: "tune", page: "record-settings" });
  }

  return NAV_GROUPS.map((g) => {
    const groupItems = g.id === "operations" ? operations : items.filter((i) => i.group === g.id).sort((a, b) => a.order - b.order);
    const label = g.id === "operations" ? (access.operationsLabel || "Business operations") : g.label;
    const notice = g.id === "operations" && !access.configured
      ? "Your industry settings aren't set up yet. The Zella team configures them."
      : null;
    return { ...g, label, items: groupItems, notice };
  }).filter((g) => g.items.length || g.notice);
}

// Every item, sub-items included, for "is this page allowed?" and the selected state.
export const flatten = (groups) => groups.flatMap((g) => g.items.flatMap((i) => (i.children ? [i, ...i.children] : [i])));
