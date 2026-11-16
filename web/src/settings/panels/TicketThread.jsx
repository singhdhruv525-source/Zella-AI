import { useState } from "react";
import { supabase } from "../../supabase";
import { friendly, orThrow } from "../../BusinessShared";
import { Banner, Card, Empty, Field, LoadState, useAsync, when } from "../SettingsKit";

// OPS-25: a support request's conversation with Zella Voice, as the business sees it (support_ticket_messages; the
// team's internal notes are never here). Owners, admins and managers can answer; the database checks that too.
export default function TicketThread({ ticket, businessName, canReply, onClose }) {
  const state = useAsync(() => supabase.from("support_ticket_messages").select("id, body, author_side, created_at").eq("ticket_id", ticket.id)
    .order("created_at", { ascending: true }).then(orThrow), [ticket.id]);
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  async function send() {
    setBusy(true);
    setError("");
    const { error: e } = await supabase.rpc("zella_business_ticket_reply", { p_ticket: ticket.id, p_body: text });
    setBusy(false);
    if (e) { setError(/NOT_ALLOWED/.test(e.message) ? "Only owners, admins and managers can answer support requests." : friendly(e)); return; }
    setText("");
    state.reload();
  }
  return (
    <Card title={ticket.subject} sub={`Opened ${when(ticket.created_at)}`}
      actions={<button type="button" className="zs-btn sm" onClick={onClose}>Close</button>}>
      <LoadState state={state}>{(rows) => rows.length ? (
        <ul aria-label="Conversation" style={{ listStyle: "none", padding: 0, margin: "0 0 var(--zella-space-5)", display: "grid", gap: "var(--zella-space-2)" }}>
          {rows.map((m) => (
            <li key={m.id} style={{ padding: "var(--zella-space-3) var(--zella-space-4)", borderRadius: "var(--zella-radius-md)", background: m.author_side === "zella" ? "var(--zella-alt)" : "var(--zella-card)", border: "1px solid var(--zella-border)" }}>
              <strong style={{ fontWeight: 600 }}>{m.author_side === "zella" ? "Zella Voice support" : businessName}</strong> <span className="zs-muted" style={{ fontSize: "var(--zella-text-xs)" }}>{when(m.created_at)}</span>
              <p style={{ margin: "4px 0 0", whiteSpace: "pre-wrap", fontSize: "var(--zella-text-sm)", lineHeight: 1.5 }}>{m.body}</p>
            </li>
          ))}
        </ul>
      ) : <Empty>No replies yet. Zella Voice support replies here.</Empty>}</LoadState>
      {canReply ? (
        <>
          <Field label="Your answer" full><textarea rows={3} value={text} maxLength={4000} onChange={(e) => setText(e.target.value)} /></Field>
          <Banner tone="error">{error}</Banner>
          <div className="zs-savebar">
            <span className="zs-savebar-state" />
            <button type="button" className="zs-btn primary" disabled={busy || !text.trim()} onClick={send}>{busy ? "Sending…" : "Send answer"}</button>
          </div>
        </>
      ) : <p className="zs-muted">Owners, admins and managers can answer.</p>}
    </Card>
  );
}
