import { useEffect, useMemo, useState } from "react";
import { supabase } from "./supabase";
import { Field, Icon, Pill, initials, personName } from "./BusinessUI";
import { formatDay, formatTime, timeAgo, todayInput, zonedDateTime } from "./businessTime";
import { Empty, Notice, PageHead, Segment, clock, explain, loadPeople, orThrow, plural, useLoad } from "./BusinessShared";
import { EscalationControls, Transcript, isOpenEscalation } from "./BusinessProfile";
import { Assignee, useRoster } from "./BusinessLeads";

/* One place for every conversation: a list on the left, the thread on the right.
   Texts and emails can be answered here; calls show their summary and next steps. */

const PRIORITY_TONE = { urgent: "danger", high: "warning", normal: "" };
const CHANNEL = { sms: ["sms", "Text"], email: ["mail", "Email"], webchat: ["forum", "Chat"], other: ["forum", "Message"], call: ["call", "Call"] };

export const isUnread = (c) => Boolean(c.last_inbound_at) && (!c.last_read_at || new Date(c.last_inbound_at) > new Date(c.last_read_at));
export const needsHuman = (item) => item.kind === "call"
  ? isOpenEscalation(item.call)
  : !item.convo.ai_handled && Boolean(item.convo.handover_at) && item.convo.status !== "closed";

export function buildItems(calls, convos, lastText) {
  const callConvos = new Set(calls.map((c) => c.conversation_id).filter(Boolean));
  return [
    ...calls.map((x) => ({ key: `c${x.id}`, kind: "call", at: x.started_at ?? x.created_at, customer_id: x.customer_id, call: x })),
    ...convos.filter((x) => x.channel !== "call" && !callConvos.has(x.id))
      .map((x) => ({ key: `v${x.id}`, kind: "convo", at: x.last_message_at ?? x.created_at, customer_id: x.customer_id, convo: x, snippet: lastText[x.id] })),
  ].filter((i) => i.at).sort((a, b) => new Date(b.at) - new Date(a.at));
}

function connected(integrations, channel) {
  const rows = integrations.filter((i) => i.status === "active").map((i) => (i.provider ?? "").toLowerCase());
  if (channel === "sms") return rows.some((p) => p.includes("telnyx"));
  if (channel === "email") return rows.some((p) => /email|smtp|sendgrid|resend|gmail/.test(p));
  return false;
}

function Bubble({ m, tz }) {
  if (m.sender_type === "system") return <p className="ba-msg-system">{m.content}</p>;
  const mine = m.sender_type !== "customer";
  return (
    <div className={`ba-msg ${mine ? "mine" : ""} ${m.sender_type}`}>
      <b>{m.sender_type === "customer" ? "Customer" : m.sender_type === "ai" ? "AI receptionist" : "Team"}</b>
      <p>{m.content}</p>
      <small>{formatDay(m.created_at, tz)} · {formatTime(m.created_at, tz)}{m.metadata?.delivery === "queued" ? " · queued to send" : ""}</small>
    </div>
  );
}

function ConversationPane({ item, person, workspace, roster, integrations, onChanged, onNotice, onOpenPerson, onBack }) {
  const tz = workspace.timezone;
  const c = item.convo;
  const [body, setBody] = useState("");
  const [subject, setSubject] = useState("");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState("");
  const [error, setError] = useState("");

  const { data, reload } = useLoad(async () => {
    const [msgs, notes, sms, mail] = await Promise.all([
      supabase.from("conversation_messages").select("*").eq("conversation_id", c.id).order("created_at").limit(300),
      supabase.from("conversation_notes").select("*").eq("conversation_id", c.id).order("created_at").limit(100),
      supabase.from("sms_messages").select("*").eq("conversation_id", c.id).order("created_at").limit(300),
      supabase.from("email_messages").select("*").eq("conversation_id", c.id).order("created_at").limit(100),
    ]);
    let messages = msgs.error ? [] : msgs.data ?? [];
    if (!messages.length) {
      // Older conversations only have the provider-level records.
      messages = [
        ...(sms.error ? [] : sms.data ?? []).map((m) => ({ id: m.id, sender_type: m.direction === "inbound" ? "customer" : "agent", content: m.message_body, created_at: m.created_at })),
        ...(mail.error ? [] : mail.data ?? []).map((m) => ({ id: m.id, sender_type: m.direction === "inbound" ? "customer" : "agent", content: [m.subject, m.body_text].filter(Boolean).join("\n"), created_at: m.created_at })),
      ].sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
    }
    return { messages, notes: notes.error ? [] : notes.data ?? [] };
  }, [c.id]);

  // Opening a conversation reads it.
  useEffect(() => {
    if (isUnread(c)) supabase.rpc("zella_inbox_mark_read", { p_conversation_id: c.id, p_read: true }).then(() => onChanged());
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [c.id]);

  async function run(key, work, message, after) {
    setBusy(key);
    setError("");
    const { error: failure } = await work();
    setBusy("");
    if (failure) { setError(explain(failure)); return false; }
    if (message) onNotice(message);
    onChanged();
    reload();
    after?.();
    return true;
  }
  const update = (extra, message) => run("update", () => supabase.rpc("zella_inbox_update", { p_conversation_id: c.id, ...extra }), message);

  const channel = c.channel;
  const optedOut = Boolean(person?.do_not_contact || (channel === "sms" && person?.do_not_sms) || (channel === "email" && person?.do_not_email));
  const canReply = ["sms", "email"].includes(channel);
  const isConnected = connected(integrations, channel);
  const recipient = channel === "sms" ? person?.phone : person?.email;
  let blockedWhy = "";
  if (!canReply) blockedWhy = "Replies aren't available for this kind of conversation.";
  else if (!person) blockedWhy = "This conversation isn't linked to a person yet.";
  else if (optedOut) blockedWhy = "This person asked not to be contacted this way.";
  else if (!recipient) blockedWhy = `Add ${channel === "sms" ? "a phone number" : "an email address"} to their profile first.`;
  else if (!isConnected) blockedWhy = `${channel === "sms" ? "Text messaging" : "Email"} isn't connected yet. Connect it under Integrations to reply from here.`;

  const send = (event) => {
    event.preventDefault();
    if (!body.trim()) return;
    run("send", () => supabase.rpc("zella_inbox_reply", { p_conversation_id: c.id, p_body: body.trim(), p_subject: channel === "email" ? subject.trim() || null : null }), "Reply queued to send.", () => setBody(""));
  };
  const addNote = (event) => {
    event.preventDefault();
    if (!note.trim()) return;
    run("note", () => supabase.rpc("zella_inbox_add_note", { p_conversation_id: c.id, p_body: note.trim() }), "Note added.", () => setNote(""));
  };
  const name = personName(person) ?? "Unknown contact";
  const [icon, channelName] = CHANNEL[channel] ?? CHANNEL.other;

  return (
    <div className="ba-inbox-pane">
      <header className="ba-inbox-head">
        <button type="button" className="ba-btn sm ba-inbox-back" onClick={onBack}><Icon name="arrow_back" size="sm" />Back</button>
        <div>
          <strong>{person ? <button type="button" className="ba-namebtn strong" onClick={() => onOpenPerson(person.id)}>{name}</button> : name}</strong>
          <small><Icon name={icon} size="sm" />{channelName}{c.subject ? ` · ${c.subject}` : ""}</small>
        </div>
        <div className="ba-kn-head">
          {c.ai_handled ? <Pill tone="indigo">AI is handling this</Pill> : <Pill tone="warning">A person is handling this</Pill>}
          <button type="button" className="ba-btn sm" disabled={Boolean(busy)}
            onClick={() => run("handover", () => supabase.rpc("zella_inbox_handover", { p_conversation_id: c.id, p_to_ai: !c.ai_handled }), c.ai_handled ? "You took over from the AI receptionist." : "Handed back to the AI receptionist.")}>
            {c.ai_handled ? "Take over from AI" : "Hand back to AI"}
          </button>
        </div>
      </header>
      {error && <p className="ba-error" role="alert">{error}</p>}

      <div className="ba-inbox-controls">
        <label className="ba-select"><span>Assigned to</span>
          <select value={c.assigned_to ?? ""} disabled={Boolean(busy)} onChange={(e) => update(e.target.value ? { p_assign_to: e.target.value } : { p_unassign: true }, "Assignment saved.")}>
            <option value="">Unassigned</option>
            {roster.list.map((m) => <option key={m.user_id} value={m.user_id}>{m.name}</option>)}
          </select>
        </label>
        <label className="ba-select"><span>Priority</span>
          <select value={c.priority ?? "normal"} disabled={Boolean(busy)} onChange={(e) => update({ p_priority: e.target.value }, "Priority saved.")}>
            <option value="normal">Normal</option><option value="high">High</option><option value="urgent">Urgent</option>
          </select>
        </label>
        <label className="ba-select"><span>Status</span>
          <select value={c.status} disabled={Boolean(busy)} onChange={(e) => update({ p_status: e.target.value }, "Status saved.")}>
            <option value="open">Open</option><option value="pending">Waiting on them</option><option value="closed">Closed</option>
          </select>
        </label>
        <button type="button" className="ba-btn sm" disabled={Boolean(busy)}
          onClick={() => run("unread", () => supabase.rpc("zella_inbox_mark_read", { p_conversation_id: c.id, p_read: false }), "Marked unread.")}>Mark unread</button>
      </div>

      <div className="ba-thread">
        {!data?.messages.length ? <p className="ba-muted">No messages yet.</p> : data.messages.map((m) => <Bubble key={m.id} m={m} tz={tz} />)}
      </div>

      {data?.notes.length > 0 && (
        <ul className="ba-internal">
          {data.notes.map((n) => <li key={n.id}><b>{n.author_name ?? "Team"}</b> <small>{formatDay(n.created_at, tz)} · {formatTime(n.created_at, tz)}</small><p>{n.body}</p></li>)}
        </ul>
      )}

      <form className="ba-composer" onSubmit={send}>
        {blockedWhy ? <p className="ba-muted ba-blocked">{blockedWhy}</p> : (
          <>
            {channel === "email" && <input value={subject} onChange={(e) => setSubject(e.target.value)} placeholder={c.subject ?? "Subject"} aria-label="Subject" />}
            <textarea rows={3} value={body} onChange={(e) => setBody(e.target.value)} placeholder={`Reply by ${channelName.toLowerCase()} to ${name}`} aria-label="Reply" />
            <div className="ba-form-actions">
              <button type="submit" className="ba-btn primary sm" disabled={!body.trim() || Boolean(busy)}><Icon name="send" size="sm" />{busy === "send" ? "Sending…" : "Send reply"}</button>
              <span className="ba-muted">{c.ai_handled ? "Replying also takes over from the AI." : ""}</span>
            </div>
          </>
        )}
      </form>
      <form className="ba-inline-form ba-note-form" onSubmit={addNote}>
        <input value={note} onChange={(e) => setNote(e.target.value)} placeholder="Internal note (customers never see this)" aria-label="Internal note" />
        <button type="submit" className="ba-btn sm" disabled={!note.trim() || Boolean(busy)}>Add note</button>
      </form>
    </div>
  );
}

function CallPane({ item, person, workspace, onChanged, onNotice, onOpenPerson, onBack }) {
  const tz = workspace.timezone;
  const call = item.call;
  const [cb, setCb] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const missed = call.status === "missed";
  const phone = person?.phone ?? call.from_number;

  async function schedule(event) {
    event.preventDefault();
    if (!phone) return setError("There's no number to call back.");
    setBusy(true);
    setError("");
    const { error: failure } = await supabase.rpc("zella_staff_create_callback", {
      p_business_id: workspace.id, p_contact_number: phone, p_customer_id: person?.id ?? call.customer_id ?? null,
      p_summary: call.summary ?? null, p_preferred_at: zonedDateTime(cb.date, cb.time, tz).toISOString(), p_priority: "normal",
    });
    setBusy(false);
    if (failure) return setError(explain(failure));
    onNotice("Callback scheduled.");
    setCb(null);
    onChanged();
  }

  return (
    <div className="ba-inbox-pane">
      <header className="ba-inbox-head">
        <button type="button" className="ba-btn sm ba-inbox-back" onClick={onBack}><Icon name="arrow_back" size="sm" />Back</button>
        <div>
          <strong>{person ? <button type="button" className="ba-namebtn strong" onClick={() => onOpenPerson(person.id)}>{personName(person)}</button> : call.from_number ?? "Unknown caller"}</strong>
          <small><Icon name={missed ? "phone_missed" : "call"} size="sm" />{missed ? "Missed call" : `${call.ai_handled ? "AI answered" : "Team answered"} · ${clock(call.duration_seconds)}`} · {formatDay(item.at, tz)} · {formatTime(item.at, tz)}</small>
        </div>
        <div className="ba-kn-head">
          {isOpenEscalation(call) && <Pill tone="danger">Needs a human</Pill>}
          {phone && <a className="ba-btn sm" href={`tel:${phone}`}><Icon name="call" size="sm" />Call</a>}
          <button type="button" className="ba-btn sm" onClick={() => setCb({ date: todayInput(tz), time: "10:00" })}>Schedule callback</button>
          {person && <button type="button" className="ba-btn sm" onClick={() => onOpenPerson(person.id)}>Open profile</button>}
        </div>
      </header>
      {error && <p className="ba-error" role="alert">{error}</p>}
      {cb && (
        <form className="ba-form-grid ba-finish" onSubmit={schedule}>
          <Field label="Day"><input type="date" min={todayInput(tz)} value={cb.date} onChange={(e) => setCb({ ...cb, date: e.target.value })} required /></Field>
          <Field label="Time"><input type="time" value={cb.time} onChange={(e) => setCb({ ...cb, time: e.target.value })} required /></Field>
          <div className="full ba-form-actions"><button type="submit" className="ba-btn primary sm" disabled={busy}>Schedule</button><button type="button" className="ba-btn sm" onClick={() => setCb(null)}>Cancel</button></div>
        </form>
      )}
      {isOpenEscalation(call) && <EscalationControls call={call} onChanged={onChanged} onNotice={onNotice} />}
      {call.summary && <section><h3 className="ba-sub">Summary</h3><p className="ba-item-text">{call.summary}</p></section>}
      {call.recording_url && <section><h3 className="ba-sub">Recording</h3><audio controls preload="none" src={call.recording_url} style={{ width: "100%" }} /></section>}
      {call.transcript && <section><h3 className="ba-sub">Transcript</h3><Transcript transcript={call.transcript} /></section>}
      {!call.summary && !call.transcript && <p className="ba-muted">No summary or transcript for this call.</p>}
    </div>
  );
}

const FILTERS = [["all", "All"], ["unread", "Unread"], ["calls", "Calls"], ["sms", "Texts"], ["email", "Email"], ["missed", "Missed calls"], ["human", "Human handover"]];

export function InboxPage({ workspace, refreshKey, onNotice, onOpenPerson }) {
  const tz = workspace.timezone;
  const [filter, setFilter] = useState("all");
  const [selected, setSelected] = useState(null);
  const roster = useRoster(workspace);
  const { data, error, loading, reload } = useLoad(async () => {
    const [calls, convos, ints] = await Promise.all([
      supabase.from("calls_view").select("*").eq("business_id", workspace.id).order("created_at", { ascending: false }).limit(150),
      supabase.from("conversations").select("*").eq("business_id", workspace.id).order("last_message_at", { ascending: false, nullsFirst: false }).limit(200),
      supabase.from("integrations").select("provider, status").eq("business_id", workspace.id),
    ]);
    const c = orThrow(calls);
    const v = orThrow(convos);
    const ids = v.map((x) => x.id);
    const msgs = ids.length ? await supabase.from("conversation_messages").select("conversation_id, content, created_at").in("conversation_id", ids).order("created_at", { ascending: false }).limit(600) : { data: [] };
    const lastText = {};
    (msgs.data ?? []).forEach((m) => { if (!lastText[m.conversation_id]) lastText[m.conversation_id] = m.content; });
    const people = await loadPeople([...c, ...v].map((x) => x.customer_id));
    const flagIds = [...new Set(v.map((x) => x.customer_id).filter(Boolean))];
    const flags = flagIds.length ? await supabase.from("customers").select("id, do_not_contact, do_not_sms, do_not_email").in("id", flagIds) : { data: [] };
    (flags.data ?? []).forEach((f) => { if (people[f.id]) Object.assign(people[f.id], f); });
    return { items: buildItems(c, v, lastText), people, integrations: ints.error ? [] : ints.data ?? [] };
  }, [workspace.id, refreshKey]);

  const all = data?.items ?? [];
  const unreadCount = all.filter((i) => i.kind === "convo" && isUnread(i.convo)).length;
  const rows = useMemo(() => all.filter((i) => {
    if (filter === "unread") return i.kind === "convo" && isUnread(i.convo);
    if (filter === "calls") return i.kind === "call";
    if (filter === "sms") return i.kind === "convo" && i.convo.channel === "sms";
    if (filter === "email") return i.kind === "convo" && i.convo.channel === "email";
    if (filter === "missed") return i.kind === "call" && i.call.status === "missed";
    if (filter === "human") return needsHuman(i);
    return true;
  }), [all, filter]);

  const current = selected ? all.find((i) => i.key === selected) : null;
  const person = current ? data.people[current.customer_id] : null;

  return (
    <>
      <PageHead crumb="Calls & Messages / Conversations" title="Unified inbox"
        sub={unreadCount ? `${plural(unreadCount, "conversation")} unread.` : "Every call, text and email in one place."} />
      <Notice error={error} onRetry={reload} />
      <div className="ba-inbox-filters">
        <Segment label="Inbox filter" value={filter} onChange={setFilter}
          options={FILTERS.map(([k, l]) => [k, k === "unread" && unreadCount ? `${l} (${unreadCount})` : l])} />
      </div>
      <div className={`ba-inbox ${current ? "has-open" : ""}`}>
        <aside className="ba-inbox-list" aria-label="Conversations">
          {loading && !data ? <p className="ba-muted ba-pad">Loading…</p> : !rows.length ? (
            <div className="ba-pad"><Empty title="Nothing here">{filter === "all" ? "Calls and messages appear as soon as your phone line and messaging are live." : "No conversations match this filter."}</Empty></div>
          ) : rows.slice(0, 200).map((i) => {
            const p = data.people[i.customer_id];
            const isCall = i.kind === "call";
            const missed = isCall && i.call.status === "missed";
            const unread = !isCall && isUnread(i.convo);
            const ch = isCall ? "call" : i.convo.channel;
            const label = personName(p) ?? (isCall ? i.call.from_number ?? "Unknown caller" : "Unknown contact");
            const priority = !isCall ? i.convo.priority : null;
            return (
              <button key={i.key} type="button" className={`ba-inbox-row ${selected === i.key ? "active" : ""} ${unread ? "unread" : ""}`} onClick={() => setSelected(i.key)}>
                <span className={`ba-thread-icon ${missed ? "bad" : ""}`}><Icon name={missed ? "phone_missed" : (CHANNEL[ch] ?? CHANNEL.other)[0]} size="sm" /></span>
                <span className="ba-inbox-text">
                  <span className="ba-inbox-line"><strong>{label}</strong><time title={`${formatDay(i.at, tz)} ${formatTime(i.at, tz)}`}>{timeAgo(i.at)}</time></span>
                  <small>{isCall ? (missed ? "Missed call" : i.call.summary || `${i.call.ai_handled ? "AI answered" : "Team answered"} · ${clock(i.call.duration_seconds)}`) : i.snippet || i.convo.subject || `${(CHANNEL[ch] ?? CHANNEL.other)[1]} conversation`}</small>
                  <span className="ba-inbox-tags">
                    {unread && <i className="ba-dot" aria-label="Unread" />}
                    {needsHuman(i) && <Pill tone="danger">Needs a person</Pill>}
                    {priority && priority !== "normal" && <Pill tone={PRIORITY_TONE[priority]}>{priority === "urgent" ? "Urgent" : "High"}</Pill>}
                    {!isCall && i.convo.ai_handled && <Pill tone="indigo">AI</Pill>}
                    {!isCall && i.convo.assigned_to && <Assignee id={i.convo.assigned_to} nameOf={roster.nameOf} />}
                  </span>
                </span>
              </button>
            );
          })}
        </aside>
        <section className="ba-inbox-detail">
          {!current ? <div className="ba-pad"><Empty title="Choose a conversation">Select one on the left to read it, reply, assign it or add a note.</Empty></div>
            : current.kind === "call"
              ? <CallPane key={current.key} item={current} person={person} workspace={workspace} onChanged={reload} onNotice={onNotice} onOpenPerson={onOpenPerson} onBack={() => setSelected(null)} />
              : <ConversationPane key={current.key} item={current} person={person} workspace={workspace} roster={roster} integrations={data.integrations}
                onChanged={reload} onNotice={onNotice} onOpenPerson={onOpenPerson} onBack={() => setSelected(null)} />}
        </section>
      </div>
    </>
  );
}
