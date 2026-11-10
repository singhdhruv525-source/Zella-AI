import { supabase } from "../supabase";
import { NAV_ITEMS } from "../navigation/navConfig";
import { Banner, Card, Facts, LinkRows, LoadState, Needs, Pill, Table, useAsync, words } from "./SettingsKit";

// Settings > Industry and workflows > Modules. Shows the three checks the sidebar uses, for this business only:
// does the industry support the module, has the business switched it on, and may this person open its pages.
// Read from zella_workspace_navigation, the same function the sidebar reads. Shared modules are set by the Zella team
// for the industry and plan; a business's own operations (record types) are switched on and off in Customise records.

const ABOUT = {
  "ai-receptionist": "Answers calls, takes messages and hands over to a person",
  "ai-appointments": "Lets the receptionist book, move and cancel bookings",
  "ai-follow-up": "Lets the receptionist follow up on missed calls and leads",
  "ai-sales": "Lets the receptionist answer pricing and service questions",
  "ai-support": "Lets the receptionist answer common questions",
  calls: "Call history, recordings and transcripts",
  automations: "Reminders, follow-ups and other automatic steps",
  calendar: "Waitlist, and booking from the receptionist",
  sms: "Text messages to and from customers",
  email: "Email to and from customers",
};

// Pages each module opens in the sidebar, taken from the sidebar's own configuration.
function pagesFor(slug, role) {
  const out = [];
  for (const item of NAV_ITEMS) {
    for (const node of [item, ...(item.children ?? [])]) {
      const needs = node.module ?? (node !== item ? item.module : undefined);
      if (needs !== slug) continue;
      const label = typeof node.label === "function" ? null : node.label;
      if (!label || node.children) continue;
      out.push({ label, allowed: !node.roles || node.roles.includes(role) });
    }
  }
  return out;
}

export function BusinessModulesPanel({ w, onGo }) {
  const state = useAsync(async () => {
    const { data, error } = await supabase.rpc("zella_workspace_navigation", { p_business_id: w.id });
    if (error) throw new Error(error.message);
    return data;
  }, [w.id]);
  return (
    <LoadState state={state}>{(n) => {
      const rows = (n.modules ?? []).map((m) => ({ ...m, pages: pagesFor(m.slug, n.role) }));
      const types = n.record_types ?? [];
      return (
        <>
          {!n.configured && <Banner tone="warn">This business's industry isn't fully set up, so only shared CRM pages are shown. The Zella team sets the industry.</Banner>}
          <Card title="Your industry" sub="Decides the words the CRM uses and which modules can be offered.">
            <Facts rows={[["Industry", n.industry?.name ?? "Not set"], ["Operations menu", n.operations_label ?? "—"],
              ["Customers are called", n.terminology?.customers ?? "Customers"], ["Bookings are called", n.terminology?.appointments ?? "Appointments"],
              ["Your access", words(n.role)]]} />
          </Card>
          <Card title="Shared modules" sub="Supported by your industry. On or off is set by the Zella team for your plan.">
            <Table rowKey={(m) => m.slug} rows={rows} empty="No modules are defined for this industry yet." columns={[
              ["Module", (m) => <><strong>{m.name ?? words(m.slug)}</strong><br /><small className="zs-muted">{ABOUT[m.slug] ?? ""}</small></>],
              ["Industry", (m) => (m.available ? <Pill tone="success">Supported</Pill> : <Pill>Not offered</Pill>)],
              ["This business", (m) => (m.enabled ? <Pill tone="success">On</Pill> : <Pill tone="warning">Off</Pill>)],
              ["Pages", (m) => (m.pages.length ? m.pages.map((p) => `${p.label}${p.allowed ? "" : " (not with your role)"}`).join(", ") : "Works inside the receptionist")],
            ]} />
          </Card>
          <Card title={n.operations_label ?? "Business operations"} sub="Records for your kind of business. Owners, admins and managers switch them on or off.">
            <Table rowKey={(t) => t.key} rows={types} empty="None yet. They're added from your industry the first time the CRM opens." columns={[
              ["Record", (t) => t.plural], ["State", (t) => (t.enabled ? <Pill tone="success">In the menu</Pill> : <Pill>Off</Pill>)],
              ["From", (t) => (t.preset ? "Your industry's starting set" : "Added by your team")]]} />
            {["owner", "admin", "manager"].includes(n.role) && (
              <LinkRows rows={[{ title: "Switch records on or off, or add your own", detail: "Customize records", onClick: () => onGo("record-settings") }]} />
            )}
          </Card>
          <Needs title="Switching shared modules here isn't available" have="Ask the Zella team (Help and support) and they'll change it for your plan.">
            Changing a shared module from here needs the plan's list of optional modules, checked on the server, so nothing is switched on outside your plan.
          </Needs>
          <Card title="Not built yet" sub="Not shown in your menu until they work.">
            <Facts rows={[["Voicemails", "Calls with a recording are in Calls"], ["Reviews inbox", "Send your review link from SMS, email and messages"],
              ["Marketing campaigns", "Lead sources shows where leads come from"], ["AI agents beyond the receptionist", "—"]]} />
          </Card>
        </>
      );
    }}</LoadState>
  );
}
