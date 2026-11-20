import { useRef, useState } from "react";
import { Facts, Pill, Select, friendlyError, rpc, whenText, words } from "./adminOps";
import { lookupProblem } from "../contactLookup";

// Messaging > Consent & opt outs (COM-29): why one number or address of one business gets no messages. A business,
// at least 4 digits or a full email address and a reason are required; the answer is masked (last 4 digits, first
// letter and domain) and every lookup is audited. Needs comms.manage; the database checks it again.

export default function ContactLookup({ options, optionsLoading = false, optionsProblem = "", onRetryOptions }) {
  const [business, setBusiness] = useState(null);
  const [query, setQuery] = useState("");
  const [reason, setReason] = useState("");
  const [result, setResult] = useState(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const latest = useRef(0);   // a lookup started before the business changed never shows its answer
  const businesses = options?.businesses ?? [];
  const nameOf = (id) => businesses.find((b) => b.id === id)?.name ?? "the business";
  function choose(id) { latest.current += 1; setBusiness(id); setResult(null); setBusy(false); setError(""); }
  async function look(e) {
    e.preventDefault();
    const problem = lookupProblem({ business, query, reason });
    if (problem) { setError(problem); return; }
    const ticket = ++latest.current, searched = business;
    setBusy(true); setError(""); setResult(null);
    try {
      const r = await rpc("zella_admin_contact_lookup", { p_business: searched, p_query: query.trim(), p_reason: reason.trim() });
      if (ticket === latest.current) setResult({ ...r, business: searched, businessName: nameOf(searched) });
    } catch (err) { if (ticket === latest.current) setError(friendlyError(err)); }
    finally { if (ticket === latest.current) setBusy(false); }
  }
  const flags = (c) => [c.do_not_contact && "Do not contact", c.do_not_sms && "Do not text", c.do_not_call && "Do not call", c.do_not_email && "Do not email",
    c.email_suppressed_at && `Email suppressed${c.email_suppressed_reason ? `: ${c.email_suppressed_reason}` : ""}`].filter(Boolean);
  return (
    <section className="ao-lookup" aria-label="Look up one contact">
      <h3 className="ao-h3">Why does one contact get no messages?</h3>
      <p className="op-muted">For one business. Shows masked results only, and the lookup goes in the audit log with your reason.</p>
      <form onSubmit={look}>
        <Select label="Business" value={business} any={optionsLoading ? "Loading businesses…" : "Choose a business"} disabled={optionsLoading || Boolean(optionsProblem)} onChange={choose} options={businesses.map((b) => [b.id, b.name])} />
        {optionsLoading && <p className="op-muted" role="status">Loading the list of businesses…</p>}
        {optionsProblem && <div className="owner-form-error" role="alert">{optionsProblem} <button type="button" className="ba-link" onClick={onRetryOptions}>Try again</button></div>}
        <label className="owner-field"><span>Phone (at least the last 4 digits) or full email</span>
          <input value={query} onChange={(e) => setQuery(e.target.value)} autoComplete="off" /></label>
        <label className="owner-field"><span>Reason</span>
          <input value={reason} maxLength={300} onChange={(e) => setReason(e.target.value)} placeholder="Why you're looking" /></label>
        {error && <div className="owner-form-error" role="alert">{error}</div>}
        <div className="ao-drawer-actions"><button type="submit" className="owner-primary-button" disabled={busy}>{busy ? "Looking…" : "Look up"}</button></div>
      </form>
      {result && (
        <div className="ao-lookup-result" role="status">
          <Facts rows={[
            ["Business", result.businessName],
            ["Searched for", result.query],
            ["Customer records", result.contacts.length ? result.contacts.map((c) => `${c.contact}: ${flags(c).join(", ") || "no blocks"}`).join("; ") : "None"],
            ["Consent", result.consents.length ? result.consents.map((k) => `${words(k.channel)} ${words(k.purpose)}: ${k.status === "opted_out" ? "opted out" : "opted in"} (${words(k.source)}, ${whenText(k.recorded_at)})`).map((t, i) => (result.consents[i].contact ? `${result.consents[i].contact}, ${t}` : t)).join("; ") : "No consent record"],
            ["Block and allow lists", result.lists.length ? result.lists.map((s) => `${s.list === "block" ? "Blocked" : "Allowed"} ${words(s.channel)}${s.platform_wide ? " (every business)" : ""}${s.reason ? `: ${s.reason}` : ""}`).join("; ") : "Not listed"],
            ["Last blocked message", result.last_blocked ? `${result.last_blocked.channel === "sms" ? "Text" : "Email"}, ${whenText(result.last_blocked.created_at)}${result.last_blocked.reason ? `: ${words(result.last_blocked.reason)}` : ""}` : "None"],
          ]} />
          {!result.contacts.length && !result.consents.length && !result.lists.length && (result.last_blocked
            ? <Pill tone="warning">No block on record now, but a message to this contact was blocked before (see above)</Pill>
            : <Pill>Nothing on record blocks this contact</Pill>)}
        </div>
      )}
    </section>
  );
}
