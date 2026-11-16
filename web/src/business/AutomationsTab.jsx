// One business's page, Automations tab. Moved from BusinessDetails.jsx unchanged (BIZ-30); the page shell passes
// what it worked out from business_detail.
import AutomationOverview from "../AutomationOverview";
import { Card, describeSettings } from "./shared";

export default function AutomationsTab({ data, term, enabledAutomations }) {
  return (
    <Card title="Automations" description="Run by n8n. Paused automations start when the business goes live.">
      <AutomationOverview rows={data.automations} industryName={data.industryName} appointmentWord={String(term("appointment")).toLowerCase()} describeSettings={describeSettings} />
      {enabledAutomations.length > 0 && <p className="op-muted op-gap-top">{enabledAutomations.length} turned on.</p>}
    </Card>
  );
}
