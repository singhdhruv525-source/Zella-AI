import { useEffect, useState } from "react";
import { supabase } from "./supabase";
import { Field, Icon, Pill, initials, personName } from "./BusinessUI";
import { formatDay, formatTime, timeAgo, todayInput, zonedDateTime } from "./businessTime";
import { Empty, Notice, PageHead, Pager, Segment, clock, explain, loadPeople, plural, useLoad, callResult, isAnswered } from "./BusinessShared";
import { useServerPages } from "./crm/paging";
import { inboxItem, replyBlock, supportProblems } from "./crm/inbox";
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

/**
 * Display a conversation and its reply, assignment, and note controls; opening an unread
 * conversation marks it read. Replies require contact and integration checks to allow them.
 * Message reads fall back to provider records when no conversation messages are available;
 * failures of all message sources show a retry notice, and note failures use an empty list.
 */
function ConversationPane({ item, person, personStatus, workspace, roster, integrations, onChanged, onNotice, onOpenPerson, onBack, onRetrySupport }) {
  const tz = workspace.timezone;
  const c = item.convo;
  const [body, setBody] = useState("");
  const [subject, setSubject] = useState("");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState("");
  const [error, setError] = useState("");

  const { data, error: threadError, reload } = useLoad(async () => {
    const [msgs, notes, sms, mail] = await Promise.all([
      supabase.from("conversation_messages").select("*").eq("conversation_id", c.id).order("created_at").limit(300),
      supabase.from("conversation_notes").select("*").eq("conversation_id", c.id).order("created_at").limit(100),
      supabase.from("sms_messages").select("*").eq("conversation_id", c.id).order("created_at").limit(300),
      supabase.from("email_messages").select("*").eq("conversation_id", c.id).order("created_at").limit(100),
    ]);
    // B3-06: a thread that couldn't be read says so, instead of looking empty
    if (msgs.error && sms.error && mail.error) throw msgs.error;
    let messages = msgs.error ? [] : msgs.data ?? [];
    if (!messages.length) {
      // Older conversations only have the provider-level records.
      messages = [
        ...(sms.error ? [] : sms.data ?? []).map((m) => ({ id: m.id, sender_type: m.direction === "inbound" ? "customer" : "agent", content: m.message_body, created_at: m.created_at })),
        ...(mail.error ? [] : mail.data ?? []).map((m) => ({ id: m.id, sender_type: m.direction === "inbound" ? "customer" : "agent", content: [m.subject, m.body_text].filter(Boolean).join("\n"), created_at: m.created_at })),
      ].sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
    }
    return { messages, notes: notes.error ? [] : notes.data ?? [], partial: Boolean(msgs.error || notes.error), notesFailed: Boolean(notes.error) };
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
  // B3-06: a reply needs the person's contact preferences and the channel's connection to be known. If either lookup
  // failed, replying waits for a retry instead of guessing (the server refuses opted-out people in any case).
  const blockedWhy = replyBlock({ channel, person, personStatus, integrations });
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
      {threadError && <Notice error={`Couldn't load this conversation's messages. ${threadError}`} onRetry={reload} />}
      {data?.partial && <Notice error={data.notesFailed ? "Some messages or internal notes couldn't be loaded." : "Some messages couldn't be loaded."} onRetry={reload} />}

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
        {threadError && !data ? <p className="ba-muted">Messages unavailable.</p> : !data ? <p className="ba-muted">Loading…</p>
          : !data.messages.length ? <p className="ba-muted">No messages yet.</p> : data.messages.map((m) => <Bubble key={m.id} m={m} tz={tz} />)}
      </div>

      {data?.notes.length > 0 && (
        <ul className="ba-internal">
          {data.notes.map((n) => <li key={n.id}><b>{n.author_name ?? "Team"}</b> <small>{formatDay(n.created_at, tz)} · {formatTime(n.created_at, tz)}</small><p>{n.body}</p></li>)}
        </ul>
      )}

      <form className="ba-composer" onSubmit={send}>
        {blockedWhy ? (
          <p className="ba-muted ba-blocked">{blockedWhy.text}{blockedWhy.retry && <> <button type="button" className="ba-btn sm" onClick={onRetrySupport}>Try again</button></>}</p>
        ) : (
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

/**
 * Display a selected call and callback controls, fetching its full details from calls_view.
 * Retain the list row while details load or fail, and offer a retry for detail failures.
 * Scheduled callback times are interpreted in the workspace timezone.
 */
function CallPane({ item, person, workspace, onChanged, onNotice, onOpenPerson, onBack }) {
  const tz = workspace.timezone;
  // the list row has no transcript or recording link; the opened call is read in full, under calls_view's rules
  const full = useLoad(async () => {
    const res = await supabase.from("calls_view").select("*").eq("business_id", workspace.id).eq("id", item.call.id).maybeSingle();
    if (res.error) throw res.error;
    return res.data;
  }, [workspace.id, item.call.id, item.call.updated_at]);
  const call = full.data ?? item.call;
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
          {isOpenEscalation(call) && <Pill tone="danger">Needs a person</Pill>}
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
      {full.error && <Notice error={`Couldn't load this call's summary and transcript. ${full.error}`} onRetry={full.reload} />}
      {isOpenEscalation(call) && <EscalationControls call={call} onChanged={onChanged} onNotice={onNotice} />}
      {call.summary && <section><h3 className="ba-sub">Summary</h3><p className="ba-item-text">{call.summary}</p></section>}
      {call.recording_url && <section><h3 className="ba-sub">Recording</h3><audio controls preload="none" src={call.recording_url} style={{ width: "100%" }} /></section>}
      {call.transcript && <section><h3 className="ba-sub">Transcript</h3><Transcript transcript={call.transcript} /></section>}
      {full.data && !call.summary && !call.transcript && <p className="ba-muted">No summary or transcript for this call.</p>}
    </div>
  );
}

const FILTERS = [["all", "All"], ["unread", "Unread"], ["calls", "Calls"], ["sms", "Texts"], ["email", "Email"], ["missed", "Missed calls"], ["human", "Needs a person"]];
const INBOX_PAGE = 50;

/**
 * Show calls and conversations in one server-paged inbox, retaining the selected item
 * across page changes. Previews, contacts, and integrations load separately and expose
 * retryable failures; unavailable contact or integration checks pause replies.
 */
export function InboxPage({ workspace, refreshKey, onNotice, onOpenPerson }) {
  const tz = workspace.timezone;
  const [filter, setFilter] = useState("all");
  const [selected, setSelected] = useState(null);   // the open item; kept when the list moves to another page
  const roster = useRoster(workspace);

  // B3-02: calls and conversations merged, filtered and paged by the server (zella_inbox_page), newest activity first
  const list = useServerPages("zella_inbox_page", { p_business_id: workspace.id, p_filter: filter }, INBOX_PAGE);
  const { reload } = list;
  useEffect(() => { if (refreshKey) reload(); }, [refreshKey, reload]);
  const items = list.rows.map(inboxItem);

  // B3-06: what supports the list is loaded separately, for this page only; each can fail on its own and says so
  const convoIds = items.filter((i) => i.kind === "convo").map((i) => i.convo.id);
  // the open conversation's person too: it stays open when the list moves to a page it isn't on
  const peopleIds = [...new Set([...items.map((i) => i.customer_id), selected?.customer_id].filter(Boolean))].sort();
  const previews = useLoad(async () => {
    if (!convoIds.length) return {};
    const res = await supabase.rpc("zella_inbox_previews", { p_business_id: workspace.id, p_conversation_ids: convoIds });
    if (res.error) throw res.error;
    return Object.fromEntries((res.data ?? []).map((r) => [r.conversation_id, r.preview]));
  }, [workspace.id, convoIds.join(","), list.data]);
  const people = useLoad(async () => loadPeople(peopleIds), [peopleIds.join(","), list.data]);
  const ints = useLoad(async () => {
    const res = await supabase.from("integrations").select("provider, status").eq("business_id", workspace.id);
    if (res.error) throw res.error;
    return res.data ?? [];
  }, [workspace.id, refreshKey]);
  const problems = supportProblems({ previews, people, integrations: ints });
  const retrySupport = () => { if (previews.error) previews.reload(); if (people.error) people.reload(); if (ints.error) ints.reload(); };
  const integrations = { status: ints.error ? "failed" : ints.loading && !ints.data ? "loading" : "ok", rows: ints.data ?? [] };
  // while this page's people are loading, an earlier page's map can't answer for them (no "not linked" flash)
  const personStatus = people.error ? "failed" : people.loading ? "loading" : "ok";
  const peopleMap = people.data ?? {};

  const unreadCount = Number(list.data?.unread_total) || 0;
  const current = selected ? items.find((i) => i.key === selected.key) ?? selected : null;
  const person = current ? peopleMap[current.customer_id] ?? null : null;
  const listError = list.status === "stale" ? `${list.error} Showing the last list loaded.` : list.error;

  return (
    <>
      <PageHead crumb="Calls & messages / Inbox" title="Inbox"
        sub={unreadCount ? `${plural(unreadCount, "conversation")} unread.` : "Every call, text and email in one place."} />
      <Notice error={listError} onRetry={reload} />
      {problems && <div className="ba-banner" role="status" data-partial="inbox"><span>{problems}</span><button type="button" className="ba-btn sm" onClick={retrySupport}>Try again</button></div>}
      <div className="ba-inbox-filters">
        <Segment label="Inbox filter" value={filter} onChange={setFilter}
          options={FILTERS.map(([k, l]) => [k, k === "unread" && unreadCount ? `${l} (${unreadCount})` : l])} />
      </div>
      <div className={`ba-inbox ${current ? "has-open" : ""}`}>
        <aside className="ba-inbox-list" aria-label="Conversations">
          {list.loading && !list.data ? <p className="ba-muted ba-pad">Loading…</p> : list.status === "failed" ? <p className="ba-muted ba-pad">The inbox couldn't be loaded.</p> : !items.length ? (
            <div className="ba-pad"><Empty title="Nothing here">{filter === "all" ? "Calls and messages appear as soon as your phone line and messaging are live." : "No conversations match this filter."}</Empty></div>
          ) : items.map((i) => {
            const p = peopleMap[i.customer_id];
            const isCall = i.kind === "call";
            const missed = isCall && i.call.status === "missed";
            const unread = !isCall && isUnread(i.convo);
            const ch = isCall ? "call" : i.convo.channel;
            const label = personName(p) ?? (isCall ? i.call.from_number ?? "Unknown caller" : people.error && i.customer_id ? "Name unavailable" : "Unknown contact");
            const priority = !isCall ? i.convo.priority : null;
            const snippet = !isCall && previews.data ? previews.data[i.convo.id] : undefined;
            return (
              <button key={i.key} type="button" className={`ba-inbox-row ${selected?.key === i.key ? "active" : ""} ${unread ? "unread" : ""}`} onClick={() => setSelected(i)}>
                <span className={`ba-thread-icon ${missed ? "bad" : ""}`}><Icon name={missed ? "phone_missed" : (CHANNEL[ch] ?? CHANNEL.other)[0]} size="sm" /></span>
                <span className="ba-inbox-text">
                  <span className="ba-inbox-line"><strong>{label}</strong><time title={`${formatDay(i.at, tz)} ${formatTime(i.at, tz)}`}>{timeAgo(i.at)}</time></span>
                  <small>{isCall ? (missed ? "Missed call" : i.call.summary || (isAnswered(i.call.status) ? `${i.call.ai_handled ? "AI answered" : "Team answered"} · ${clock(i.call.duration_seconds)}` : `Call ${callResult(i.call.status).label.toLowerCase()}`))
                    : snippet || (previews.error ? "Preview unavailable" : i.convo.subject || `${(CHANNEL[ch] ?? CHANNEL.other)[1]} conversation`)}</small>
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
          {list.data && (list.total > INBOX_PAGE || list.page > 0) && (
            <Pager page={list.page} pages={list.pages} total={list.total} hasNext={list.hasNext} busy={list.loading} size={INBOX_PAGE}
              onPage={(n) => (n > list.page ? list.next() : list.prev())} noun="item" />
          )}
        </aside>
        <section className="ba-inbox-detail">
          {!current ? <div className="ba-pad"><Empty title="Choose a conversation">Select one on the left to read it, reply, assign it or add a note.</Empty></div>
            : current.kind === "call"
              ? <CallPane key={current.key} item={current} person={person} workspace={workspace} onChanged={reload} onNotice={onNotice} onOpenPerson={onOpenPerson} onBack={() => setSelected(null)} />
              : <ConversationPane key={current.key} item={current} person={person} personStatus={current.customer_id ? personStatus : "ok"} workspace={workspace} roster={roster} integrations={integrations}
                onChanged={reload} onNotice={onNotice} onOpenPerson={onOpenPerson} onBack={() => setSelected(null)} onRetrySupport={retrySupport} />}
        </section>
      </div>
    </>
  );
}
