# CRM navigation and business modules

The CRM sidebar is built from configuration for each business. There is no per-industry code: every industry in
the database (and any added later) works the same way.

## Three checks, all required

| Check | Stored in | Enforced by |
| --- | --- | --- |
| Industry availability | `industry_modules` (per industry), `industry_crm_presets` (industry records) | `zella_module_on` ignores modules of another industry |
| Business enablement | `business_modules.enabled`, `crm_record_types.enabled` | Restrictive policies in `sql/zella_navigation.sql` (calls, call_insights, automations, crm_records) |
| User permission | `business_members.role` | Each page's own role checks and policies |

The sidebar hides what fails a check; the database refuses it anyway.

## Files

- `web/src/navigation/navConfig.js`: every sidebar item (id, label, icon, page or Settings address, group, order,
  module, roles, sub-items). Add a page here once it works.
- `web/src/navigation/useWorkspaceNavigation.js`: loads `zella_workspace_navigation(business)` for the open business.
  It reloads on every business switch, and shows a loading state, or an error with Try again.
- `web/src/navigation/Sidebar.jsx`: sidebar, business switcher, profile menu, AI receptionist card, Test AI Voice.
- `web/src/settings/BusinessModulesPanel.jsx`: Settings > Industry and workflows > Modules.
- `sql/zella_navigation.sql`: the navigation function, `zella_module_on`, and the module policies.

## Words and operations

- Labels such as Patients, Guests and Technicians come from `industry_configurations.terminology`, merged with the
  business's own `terminology_overrides`.
- The operations group is named by `industry_configurations.features.operations_label`, or "<Industry> operations"
  when that isn't set.
- Its items are the business's enabled `crm_record_types`.
- An industry without configuration shows a notice. It never falls back to another industry's menu.

## Not in the menu until built

Voicemails, Reviews inbox, Marketing campaigns, AI agents beyond the receptionist. The Pipeline view is on the Leads page.
