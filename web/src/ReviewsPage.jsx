import { useState } from "react";
import { supabase } from "./supabase";
import { Field, Icon, Modal, Pill } from "./BusinessUI";
import { Empty, PageHead, Segment, friendly, useLoad } from "./BusinessShared";
import { formatDay, timeAgo } from "./businessTime";

// Reviews: every review gets a reply draft at once (a short standard reply, or an AI rewrite when switched on).
// Nothing is posted until an owner, admin or manager approves the exact words. Google reviews come in and approved
// replies go out through the Review Replies workflow; reviews from other sites are pasted in and the approved reply
// copied back by hand. Database: sql/zella_reviews.sql (zella_reviews_list, zella_review_decide, zella_review_add).

const TABS = [["drafted", "To reply"], ["approved", "Approved"], ["posted", "Posted"], ["skipped", "Skipped"], ["all", "All"]];
const STATUS = {
  drafted: ["warning", "New"], approved: ["info", "Approved"], posting: ["info", "Posting"], posted: ["success", "Posted"],
  skipped: ["", "Skipped"], failed: ["danger", "Failed"], replied_elsewhere: ["success", "Answered"],
};
const CODES = {
  ALREADY_DECIDED: "Someone already decided this one. The list has been refreshed.",
  REPLY_LENGTH: "The reply needs 2 to 4,000 characters.",
  REPLY_TEXT: "Replies are plain text. Remove the code or tags.",
  INVALID_RATING: "Pick 1 to 5 stars.",
  REVIEW_TOO_LONG: "That review is longer than 5,000 characters.",
  TOO_MANY_REVIEWS: "That's 50 reviews added today. Try again tomorrow.",
  INVALID_GOOGLE_IDS: "The account and location ids are the numbers from Google Business Profile.",
};
const say = (error) => CODES[error?.message?.trim()] ?? friendly(error);
const missing = (e) => e && (e.code === "PGRST202" || /could not find|does not exist/i.test(e.message ?? ""));

function Stars({ value }) {
  return (
    <span className="rv-stars" role="img" aria-label={`${value} out of 5 stars`}>
      {[1, 2, 3, 4, 5].map((n) => <span key={n} className={n <= value ? "on" : ""}>★</span>)}
    </span>
  );
}

function AddReview({ workspace, onClose, onSaved }) {
  const [form, setForm] = useState({ site: "", author: "", rating: 5, body: "" });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const set = (key) => (e) => setForm({ ...form, [key]: e.target.value });
  async function save(event) {
    event.preventDefault();
    setBusy(true);
    setError("");
    const { error: addError } = await supabase.rpc("zella_review_add", {
      p_business_id: workspace.id, p_site: form.site, p_author: form.author, p_rating: Number(form.rating), p_body: form.body,
    });
    setBusy(false);
    if (addError) return setError(say(addError));
    onSaved("Review added with a reply draft.");
  }
  return (
    <Modal icon="rate_review" title="Add a review" busy={busy} onClose={onClose}
      description="For reviews on Facebook, Yelp or anywhere else. You'll get a reply draft to check, then copy it back to the site.">
      <form className="ba-form-grid ba-modal-body" onSubmit={save}>
        {error && <div className="ba-banner error full">{error}</div>}
        <Field label="Site"><input value={form.site} maxLength={40} onChange={set("site")} placeholder="For example: Yelp" /></Field>
        <Field label="Reviewer's name"><input value={form.author} maxLength={120} onChange={set("author")} placeholder="As shown on the review" /></Field>
        <Field label="Stars">
          <select value={form.rating} onChange={set("rating")}>{[5, 4, 3, 2, 1].map((n) => <option key={n} value={n}>{n} star{n > 1 ? "s" : ""}</option>)}</select>
        </Field>
        <Field label="What they wrote" full><textarea rows={4} maxLength={5000} value={form.body} onChange={set("body")} /></Field>
        <div className="full ba-form-actions">
          <button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button>
          <button type="submit" className="ba-btn primary" disabled={busy}>{busy ? "Adding…" : "Add review"}</button>
        </div>
      </form>
    </Modal>
  );
}

function GoogleSetup({ workspace, source, onClose, onSaved }) {
  const [form, setForm] = useState({ account: source?.account_id ?? "", location: source?.location_id ?? "" });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  async function save(event, disconnect = false) {
    event?.preventDefault();
    setBusy(true);
    setError("");
    const { error: saveError } = await supabase.rpc("zella_review_source_save", {
      p_business_id: workspace.id, p_account_id: disconnect ? null : form.account.trim(), p_location_id: disconnect ? null : form.location.trim(), p_active: true,
    });
    setBusy(false);
    if (saveError) return setError(say(saveError));
    onSaved(disconnect ? "Google reviews disconnected." : "Google Business Profile connected. Reviews are read every 6 hours once the Zella team switches syncing on.");
  }
  return (
    <Modal icon="storefront" title="Connect Google reviews" busy={busy} onClose={onClose}
      description="First add Zella's Google account as a manager of your Google Business Profile (the Zella team sends you the address). Then enter the two numbers from your profile.">
      <form className="ba-form-grid ba-modal-body" onSubmit={save}>
        {error && <div className="ba-banner error full">{error}</div>}
        <Field label="Account id"><input inputMode="numeric" value={form.account} onChange={(e) => setForm({ ...form, account: e.target.value })} required /></Field>
        <Field label="Location id"><input inputMode="numeric" value={form.location} onChange={(e) => setForm({ ...form, location: e.target.value })} required /></Field>
        <div className="full ba-form-actions">
          {source && <button type="button" className="ba-btn danger-outline" onClick={() => save(null, true)} disabled={busy}>Disconnect</button>}
          <button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button>
          <button type="submit" className="ba-btn primary" disabled={busy}>{busy ? "Saving…" : "Connect"}</button>
        </div>
      </form>
    </Modal>
  );
}

function ReviewCard({ review, workspace, onChanged, onNotice }) {
  const [text, setText] = useState(review.reply ?? review.draft ?? "");
  const [busy, setBusy] = useState(false);
  const tz = workspace.timezone;
  const [tone, label] = STATUS[review.status] ?? ["", review.status];

  async function decide(action) {
    setBusy(true);
    const { data, error } = await supabase.rpc("zella_review_decide", { p_review_id: review.id, p_action: action, p_reply: action === "approve" ? text : null });
    setBusy(false);
    if (error) { onNotice(say(error)); return onChanged(); }
    if (data === "copy_and_post") {
      try { await navigator.clipboard.writeText(text); onNotice("Approved and copied. Paste it as your reply on " + (review.site || "the review site") + "."); }
      catch { onNotice("Approved. Copy the reply and post it on " + (review.site || "the review site") + "."); }
    } else if (data === "will_post") onNotice("Approved. It will be posted on Google in the next few minutes.");
    else if (data === "waiting_for_google") onNotice("Approved. It will be posted once Google reviews are connected and switched on.");
    else onNotice(action === "skip" ? "Skipped. No reply will be posted." : "Moved back to To reply.");
    onChanged();
  }

  const editable = review.status === "drafted" || review.status === "failed";
  return (
    <li className="rv-card">
      <div className="rv-head">
        <Stars value={review.rating} />
        <strong>{review.author_name || "A customer"}</strong>
        <small>{review.site || (review.provider === "google" ? "Google" : "Other site")} · {formatDay(review.reviewed_at, tz)}</small>
        <Pill tone={tone}>{label}</Pill>
      </div>
      {review.body ? <p className="rv-body">{review.body}</p> : <p className="rv-body muted">No written review, just stars.</p>}
      {review.existing_reply && review.status !== "posted" && (
        <div className="rv-existing"><Icon name="reply" size="sm" /><span>{review.existing_reply}</span></div>
      )}
      {review.status !== "replied_elsewhere" && (
        <div className="rv-reply">
          <label>
            <span>
              {editable ? "Your reply" : "Reply"}
              {editable && review.draft_source === "ai" && <Pill tone="indigo">AI draft</Pill>}
              {editable && review.ai_status === "pending" && <small> · AI is improving this draft…</small>}
            </span>
            <textarea rows={3} maxLength={4000} value={text} readOnly={!editable} onChange={(e) => setText(e.target.value)} />
          </label>
          {review.post_error && <small className="rv-error">Last try: {review.post_error}</small>}
          <div className="rv-actions">
            {editable && <button type="button" className="ba-btn primary sm" disabled={busy || text.trim().length < 2} onClick={() => decide("approve")}>
              <Icon name="check" size="sm" /><span>{review.provider === "manual" ? "Approve and copy" : "Approve and post"}</span>
            </button>}
            {(editable || review.status === "approved") && <button type="button" className="ba-btn sm" disabled={busy} onClick={() => decide("skip")}>Don't reply</button>}
            {["skipped", "approved", "failed"].includes(review.status) && <button type="button" className="ba-btn sm" disabled={busy} onClick={() => decide("reopen")}>Edit again</button>}
            {review.posted_at && <small>Posted {timeAgo(review.posted_at)}</small>}
          </div>
        </div>
      )}
    </li>
  );
}

export default function ReviewsPage({ workspace, onNotice }) {
  const [tab, setTab] = useState("drafted");
  const [modal, setModal] = useState(null);
  const canConnect = ["owner", "admin"].includes(workspace.role);
  const { data, error, loading, reload } = useLoad(async () => {
    const { data: result, error: loadError } = await supabase.rpc("zella_reviews_list", { p_business_id: workspace.id, p_status: tab === "all" ? null : tab });
    if (loadError) { if (missing(loadError)) return { missing: true }; throw new Error(say(loadError)); }
    return result;
  }, [workspace.id, tab]);

  const head = (
    <PageHead crumb="Business growth / Reviews" title="Reviews"
      sub="Reply to every review in a minute. Each one gets a draft; nothing is posted until you approve the words.">
      {canConnect && !data?.missing && <button type="button" className="ba-btn" onClick={() => setModal("google")}><Icon name="storefront" size="sm" /><span>{data?.source ? "Google settings" : "Connect Google"}</span></button>}
      {!data?.missing && <button type="button" className="ba-btn primary" onClick={() => setModal("add")}><Icon name="add" size="sm" /><span>Add a review</span></button>}
    </PageHead>
  );
  if (data?.missing) {
    return <>{head}<Empty icon="rate_review" title="Reviews aren't set up yet">The Zella team needs to apply its latest database update.</Empty></>;
  }
  const counts = data?.counts ?? {};
  const source = data?.source;
  return (
    <>
      {head}
      {error && <div className="ba-banner error"><span>{error}</span><button type="button" className="ba-btn sm" onClick={reload}>Try again</button></div>}
      <div className="rv-summary">
        <div><strong>{counts.to_reply ?? 0}</strong><span>to reply</span></div>
        <div><strong>{counts.average ?? "—"}</strong><span>average stars</span></div>
        <div><strong>{counts.total ?? 0}</strong><span>reviews</span></div>
        <div className="rv-source">
          <Icon name="storefront" size="sm" />
          <span>
            {!source ? "Google not connected: add reviews by hand, or connect Google."
              : source.status === "error" ? "Google stopped syncing. Check Zella is still a manager of your profile."
                : !data.live ? "Google connected. Syncing starts when the Zella team switches it on."
                  : source.last_fetched_at ? `Google checked ${timeAgo(source.last_fetched_at)}.` : "Google connected. First check soon."}
          </span>
        </div>
      </div>
      <Segment value={tab} onChange={setTab} options={TABS} label="Which reviews" />
      <section className="ba-panel ba-gap">
        {loading && !data ? <div className="ba-panel-body"><p className="ba-muted">Loading…</p></div>
          : !(data?.reviews ?? []).length ? (
            <div className="ba-panel-body">
              <Empty icon="rate_review" title={tab === "drafted" ? "No reviews waiting for a reply" : "Nothing here"}>
                {tab === "drafted" ? "New reviews show up here with a reply ready to check." : "Try another tab."}
              </Empty>
            </div>
          ) : (
            <ul className="rv-list">
              {data.reviews.map((r) => (
                <ReviewCard key={`${r.id}-${r.status}-${r.draft_source}`} review={r} workspace={workspace} onChanged={reload} onNotice={onNotice} />
              ))}
            </ul>
          )}
      </section>
      {modal === "add" && <AddReview workspace={workspace} onClose={() => setModal(null)} onSaved={(m) => { setModal(null); onNotice(m); reload(); }} />}
      {modal === "google" && <GoogleSetup workspace={workspace} source={source} onClose={() => setModal(null)} onSaved={(m) => { setModal(null); onNotice(m); reload(); }} />}
    </>
  );
}
