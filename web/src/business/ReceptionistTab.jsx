// One business's page, AI receptionist tab. Moved from BusinessDetails.jsx unchanged (BIZ-30); the page shell passes
// what it worked out from business_detail.
import { VoicePanel } from "../settings/VoicePanel";
import { Card, Facts, Empty, label, DAYS, POLICY_LABELS } from "./shared";

export default function ReceptionistTab({ r, kb, esc, voice, term, businessId }) {
  return (
    <div className="op-stack">
      <div className="op-grid">
        <Card title="Identity & voice">
          <Facts items={[
            ["Status", r.status === "active" ? "Live" : "Off (not connected)"],
            ["Name", r.name],
            ["Personality", r.personality ? r.personality[0].toUpperCase() + r.personality.slice(1) : ""],
            ["Language", voice.language ? label(voice.language) : ""],
            ["Greeting", voice.greeting],
            ["Extra instructions", r.tone],
          ]} />
        </Card>
        <Card title="About & hours">
          <Facts items={[
            ["Description", kb.about],
            ["Service area", kb.service_area],
            ...DAYS.map(([day, name]) => {
              const h = kb.hours?.[day];
              return [name, h?.closed ? "Closed" : h?.open ? `${h.open} to ${h.close}` : ""];
            }),
          ]} />
        </Card>
      </div>

      <div className="zs ao-embed"><VoicePanel businessId={businessId} /></div>

      <Card title={term("services")} description={`${kb.services?.length || 0} added`}>
        {kb.services?.length ? (
          <div className="owner-table-wrap" tabIndex={0}>
            <table className="owner-table">
              <thead><tr><th>Name</th><th>Price</th><th>Duration</th><th>Description</th></tr></thead>
              <tbody>
                {kb.services.map((s, i) => (
                  <tr key={i}><td><strong className="op-strong">{s.name}</strong></td><td>{s.price || "None"}</td><td>{s.duration || "None"}</td><td>{s.description || "None"}</td></tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : <Empty>No {term("services").toLowerCase()} added yet.</Empty>}
      </Card>

      <Card title="FAQs" description={`${kb.faqs?.length || 0} added`}>
        {kb.faqs?.length ? (
          <div className="op-faqs">
            {kb.faqs.map((f, i) => (
              <details key={i}>
                <summary>{f.question}</summary>
                <p>{f.answer}</p>
              </details>
            ))}
          </div>
        ) : <Empty>No FAQs added yet.</Empty>}
      </Card>

      <div className="op-grid">
        <Card title="Policies">
          {Object.keys(kb.policies || {}).length ? (
            <Facts items={Object.entries(kb.policies).map(([k, v]) => [POLICY_LABELS[k] ?? k, v])} />
          ) : <Empty>No policies added yet.</Empty>}
        </Card>
        <Card title="Rules">
          <div className="op-rule-block">
            <h4>Can do</h4>
            {r.capabilities?.length ? (
              <ul className="op-tag-list">{r.capabilities.map((c) => <li key={c} className="on">{label(c)}</li>)}</ul>
            ) : <p className="op-muted">Nothing selected</p>}
          </div>
          <div className="op-rule-block">
            <h4>Hands over to a person when</h4>
            {esc.triggers?.length ? (
              <ul className="op-tag-list">{esc.triggers.map((t) => <li key={t}>{label(t)}</li>)}</ul>
            ) : <p className="op-muted">Nothing selected</p>}
            <p className="op-muted">
              Transfers to {label(esc.transfer_to?.type || "owner")}
              {esc.transfer_to?.name ? ` (${esc.transfer_to.name})` : ""}
              {esc.transfer_to?.phone ? ` at ${esc.transfer_to.phone}` : ""}
            </p>
          </div>
          <div className="op-rule-block">
            <h4>Must never</h4>
            {kb.restrictions?.length ? (
              <ul className="op-bullets">{kb.restrictions.map((x, i) => <li key={i}>{x}</li>)}</ul>
            ) : <p className="op-muted">No restrictions added</p>}
          </div>
        </Card>
      </div>
    </div>
  );
}
