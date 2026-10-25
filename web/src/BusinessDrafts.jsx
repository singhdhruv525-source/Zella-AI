import { useState } from "react";
import { supabase } from "./supabase";
import { Field, Icon, Modal } from "./BusinessUI";
import { timeAgo } from "./businessTime";
import { Empty, Notice, PageHead, friendly, plural, useLoad } from "./BusinessShared";

// Suggested messages that wait for a person, the review link, and live notices ("full tonight").
// Every action goes through a Supabase function that checks the person's role itself.

const ERRORS = {
  NOT_ALLOWED: "You don't have permission to do this.",
  ALREADY_DECIDED: "Someone has already dealt with this message.",
  CANNOT_REACH: "This person can't be messaged. They may have opted out or have no phone or email saved.",
  NO_MARKETING_OR_PRICES: "Messages can't include prices or promotions.",
  BAD_URL: "Enter a full link that starts with https://",
  MESSAGE_REQUIRED: "Write a short message first.",
};
const say = (error) => {
  const code = Object.keys(ERRORS).find((k) => (error?.message ?? "").includes(k));
  return code ? ERRORS[code] : friendly(error);
};

/* ---------- Suggested messages ---------- */
function DraftRow({ draft, onDone, onNotice }) {
  const [text, setText] = useState(draft.body);
  const [busy, setBusy] = useState(false);

  async function decide(send) {
    setBusy(true);
    const { error } = await supabase.rpc("zella_decide_draft", { p_draft_id: draft.id, p_send: send, p_body: send ? text : null });
    setBusy(false);
    if (error) return onNotice(say(error));
    onNotice(send ? "Message queued to send." : "Dismissed. Nothing was sent.");
    onDone();
  }

  return (
    <li className="ba-draft">
      <div className="ba-draft-head">
        <strong>{draft.customer ?? "Customer"}</strong>
        <small>{draft.reason ? `${draft.reason} · ` : ""}{timeAgo(draft.created_at)}</small>
      </div>
      <textarea rows={3} maxLength={300} value={text} onChange={(e) => setText(e.target.value)} aria-label={`Message to ${draft.customer ?? "customer"}`} />
      <div className="ba-draft-foot">
        <small>{text.length}/300</small>
        <button type="button" className="ba-btn sm" disabled={busy} onClick={() => decide(false)}>Dismiss</button>
        <button type="button" className="ba-btn primary sm" disabled={busy || !text.trim()} onClick={() => decide(true)}>{busy ? "Sending…" : "Send message"}</button>
      </div>
    </li>
  );
}

export function DraftsPage({ workspace, refreshKey, onNotice }) {
  const { data, error, loading, reload } = useLoad(async () => {
    const { data: rows, error: e } = await supabase.rpc("zella_list_drafts", { p_business_id: workspace.id });
    if (e) throw e;
    return rows ?? [];
  }, [workspace.id, refreshKey]);

  return (
    <>
      <PageHead crumb="Work / Suggested messages" title="Suggested messages"
        sub="Zella writes these when a follow-up is due. Nothing is sent until you check it and press Send." />
      <Notice error={error} onRetry={reload} />
      <section className="ba-panel">
        <div className="ba-panel-head"><div className="ba-panel-title"><div><h2>Waiting for you</h2><p>{loading && !data ? "Loading…" : plural(data?.length ?? 0, "message")}</p></div></div></div>
        {!data?.length ? (
          <div className="ba-panel-body"><Empty title={loading ? "Loading…" : "Nothing to review"}>When a follow-up is due for a family, patient or client, the suggested message shows up here.</Empty></div>
        ) : (
          <ul className="ba-drafts">
            {data.map((d) => <DraftRow key={d.id} draft={d} onDone={reload} onNotice={onNotice} />)}
          </ul>
        )}
      </section>
    </>
  );
}

/* ---------- Review link (Settings) ---------- */
export function ReviewLinkPanel({ workspace }) {
  const canEdit = ["owner", "admin"].includes(workspace.role);
  const { data, error, reload } = useLoad(async () => {
    const { data: link, error: e } = await supabase.rpc("zella_get_review_link", { p_business_id: workspace.id });
    if (e) throw e;
    return link ?? "";
  }, [workspace.id]);
  const [value, setValue] = useState(null);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const shown = value ?? data ?? "";

  async function save() {
    setBusy(true); setMessage("");
    const { error: e } = await supabase.rpc("zella_set_review_link", { p_business_id: workspace.id, p_url: shown });
    setBusy(false);
    if (e) return setMessage(say(e));
    setValue(null); reload();
    setMessage(shown.trim() ? "Saved. Customers get this link two days after a visit." : "Removed. Review requests stop until you add a link.");
  }

  return (
    <section className="ba-panel">
      <div className="ba-panel-head"><div className="ba-panel-title"><div><h2>Review link</h2><p>Where happy customers leave a review, for example your Google review page.</p></div></div></div>
      <div className="ba-panel-body">
        <Notice error={error} onRetry={reload} />
        <Field label="Link" hint="Review requests are only sent when a link is saved.">
          <input type="url" inputMode="url" placeholder="https://" value={shown} disabled={!canEdit} onChange={(e) => setValue(e.target.value)} />
        </Field>
        {message && <p className="ba-muted" role="status">{message}</p>}
      </div>
      {canEdit && (
        <div className="ba-panel-foot"><span /><button type="button" className="ba-btn primary" onClick={save} disabled={busy || value === null}>{busy ? "Saving…" : "Save link"}</button></div>
      )}
    </section>
  );
}

/* ---------- Live notices ---------- */
const KINDS = [
  ["full", "Fully booked today", "We are fully booked for the rest of today."],
  ["closing_early", "Closing early", "We are closing earlier than usual today."],
  ["closed", "Closed for the day", "We are closed for the rest of today."],
  ["custom", "Something else", ""],
];

export function LiveNoticeModal({ workspace, onClose, onSaved }) {
  const [kind, setKind] = useState("full");
  const [text, setText] = useState(KINDS[0][2]);
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState("");

  const pick = (k) => { setKind(k); setText(KINDS.find((x) => x[0] === k)[2]); };
  async function save() {
    setBusy(true); setProblem("");
    const { error } = await supabase.rpc("zella_set_live_notice", { p_business_id: workspace.id, p_kind: kind, p_message: text, p_hours: null });
    setBusy(false);
    if (error) return setProblem(say(error));
    onSaved("Done. Your AI receptionist will tell callers until midnight.");
  }

  return (
    <Modal title="Tell callers something" description="Your AI receptionist mentions this on calls and stops offering times that clash with it. It clears itself at midnight." onClose={onClose} busy={busy}
      footer={<><button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button>
        <button type="button" className="ba-btn primary" onClick={save} disabled={busy || text.trim().length < 3}>{busy ? "Saving…" : "Tell callers"}</button></>}>
      <div className="ba-form">
        {problem && <div className="ba-banner error" role="alert"><span>{problem}</span></div>}
        <Field label="What's happening">
          <select value={kind} onChange={(e) => pick(e.target.value)}>{KINDS.map(([k, label]) => <option key={k} value={k}>{label}</option>)}</select>
        </Field>
        <Field label="What callers hear" hint="Keep it short and plain." full>
          <textarea rows={3} maxLength={200} value={text} onChange={(e) => setText(e.target.value)} />
        </Field>
      </div>
    </Modal>
  );
}

export function LiveNoticeBanner({ workspace, tick, canManage, onNotice }) {
  const { data, reload } = useLoad(async () => {
    const { data: rows, error } = await supabase.rpc("zella_active_notices", { p_business_id: workspace.id });
    if (error) return [];
    return rows ?? [];
  }, [workspace.id, tick]);

  async function clear(id) {
    const { error } = await supabase.rpc("zella_clear_live_notice", { p_business_id: workspace.id, p_notice_id: id });
    if (error) return onNotice(say(error));
    onNotice("Cleared. Callers will no longer hear it.");
    reload();
  }

  if (!data?.length) return null;
  return (
    <>
      {data.map((n) => (
        <div key={n.id} className="ba-banner" role="status">
          <span><Icon name="campaign" size="sm" /> <strong>Callers are being told:</strong> {n.message}</span>
          {canManage && <button type="button" className="ba-btn sm" onClick={() => clear(n.id)}>Clear</button>}
        </div>
      ))}
    </>
  );
}
