import { useEffect, useRef, useState } from "react";
import { supabase } from "../../supabase";
import { friendly, orThrow } from "../../BusinessShared";
import { Banner, Card, Empty, Field, LoadState, useAsync, when } from "../SettingsKit";

// OPS-25: a support request's conversation with Zella Voice, as the business sees it (support_ticket_messages; the
// team's internal notes are never here). Owners, admins and managers can answer; the database checks that too.
// onAnswered: called after an answer is saved, so the request list shows a reopened request as open again.
// request id -> { text, id } of the last answer sent from this page and not yet confirmed: a thread reopened before the
// answer is confirmed restores it with its id, so sending it again is the same answer (the server returns the saved one)
const UNCONFIRMED = new Map();
// request id -> the open threads of that request, each told when an answer to it is saved (whichever thread sent it)
const OPEN = new Map();
const tell = (ticketId, sent) => { for (const fn of OPEN.get(ticketId) ?? []) fn(sent); };

export default function TicketThread({ ticket, businessName, canReply, onClose, onAnswered }) {
  const state = useAsync(() => supabase.from("support_ticket_messages").select("id, body, author_side, created_at").eq("ticket_id", ticket.id)
    .order("created_at", { ascending: true }).then(orThrow), [ticket.id]);
  // this composer's answer and its id: a restored one keeps the id it was sent with; a new draft gets a new id when it
  // is sent, even with the same text as an earlier answer; the id is cleared once this composer sees it saved
  const [text, setText] = useState(() => UNCONFIRMED.get(ticket.id)?.text ?? "");
  const submission = useRef(UNCONFIRMED.get(ticket.id) ?? null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const reload = state.reload;
  useEffect(() => {
    const fn = (sent) => {
      reload();
      setText((current) => (current === sent.text ? "" : current));   // clear only what was sent
      if (submission.current?.id === sent.id) submission.current = null;
    };
    const set = OPEN.get(ticket.id) ?? new Set();
    set.add(fn); OPEN.set(ticket.id, set);
    return () => { set.delete(fn); if (!set.size) OPEN.delete(ticket.id); };
  }, [ticket.id, reload]);
  async function send() {
    const sent = text;
    if (submission.current?.text !== sent) submission.current = { text: sent, id: crypto.randomUUID() };
    const mine = submission.current;
    UNCONFIRMED.set(ticket.id, mine);
    setBusy(true);
    setError("");
    const { error: e } = await supabase.rpc("zella_business_ticket_reply", { p_ticket: ticket.id, p_body: sent, p_ref: mine.id });
    setBusy(false);
    if (e) { setError(/NOT_ALLOWED/.test(e.message) ? "Only owners, admins and managers can answer support requests." : friendly(e)); return; }
    // saved: no longer needed for a retry (unless a newer answer took its place), and every open thread of this
    // request shows it, also one reopened while this was on its way
    if (UNCONFIRMED.get(ticket.id)?.id === mine.id) UNCONFIRMED.delete(ticket.id);
    tell(ticket.id, mine);
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
