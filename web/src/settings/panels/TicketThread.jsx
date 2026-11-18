import { useState } from "react";
import { supabase } from "../../supabase";
import { friendly, orThrow } from "../../BusinessShared";
import { Banner, Card, Empty, Field, LoadState, useAsync, when } from "../SettingsKit";

// OPS-25: a support request's conversation with Zella Voice, as the business sees it (support_ticket_messages; the
// team's internal notes are never here). Owners, admins and managers can answer; the database checks that too.
// onAnswered: called after an answer is saved, so the request list shows a reopened request as open again.
// request id -> { text, id, confirmed } of the last answer sent from this page: its reference is kept until the
// composer showing it sees it confirmed or the text is edited, so a resend of the same text is always the same answer
const UNCONFIRMED = new Map();

export default function TicketThread({ ticket, businessName, canReply, onClose, onAnswered }) {
  const state = useAsync(() => supabase.from("support_ticket_messages").select("id, body, author_side, created_at").eq("ticket_id", ticket.id)
    .order("created_at", { ascending: true }).then(orThrow), [ticket.id]);
  // an answer not yet confirmed comes back to send again (a confirmed one is already in the conversation)
  const [text, setText] = useState(() => { const u = UNCONFIRMED.get(ticket.id); return u && !u.confirmed ? u.text : ""; });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  // one id per answer: sending the same answer again (after a lost response) saves it once; a new answer gets a new id.
  // Kept per request outside the thread (UNCONFIRMED), so closing and reopening it keeps an unconfirmed answer's id.
  const ref = { get current() { return UNCONFIRMED.get(ticket.id) ?? { text: null, id: null }; }, set current(v) { if (v.id) UNCONFIRMED.set(ticket.id, v); else UNCONFIRMED.delete(ticket.id); } };
  async function send() {
    const sent = text;
    // the same text as the last answer sent for this request (confirmed or not) is the same answer: same reference,
    // so the server returns the saved one; edited text is a new answer
    if (ref.current.text !== sent) ref.current = { text: sent, id: crypto.randomUUID() };
    setBusy(true);
    setError("");
    const sentRef = ref.current.id;
    const { error: e } = await supabase.rpc("zella_business_ticket_reply", { p_ticket: ticket.id, p_body: sent, p_ref: sentRef });
    setBusy(false);
    if (e) { setError(/NOT_ALLOWED/.test(e.message) ? "Only owners, admins and managers can answer support requests." : friendly(e)); return; }
    // only the reference this answer was sent with: a newer answer's (after a reopen) stays for its own retry. It is
    // marked confirmed, not forgotten, so a reopened composer still showing this text resends it as the same answer.
    const held = UNCONFIRMED.get(ticket.id);
    if (held?.id === sentRef) UNCONFIRMED.set(ticket.id, { ...held, confirmed: true });
    setText((current) => (current === sent ? "" : current));   // clear only what was sent
    state.reload();
    onAnswered?.();
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
          <Field label="Your answer" full><textarea rows={3} value={text} maxLength={4000} readOnly={busy} onChange={(e) => setText(e.target.value)} /></Field>
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
