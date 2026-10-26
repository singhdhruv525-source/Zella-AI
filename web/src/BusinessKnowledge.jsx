import { useState } from "react";
import { supabase } from "./supabase";
import { Field, Icon, Modal, Pill } from "./BusinessUI";
import { timeAgo } from "./businessTime";
import { Empty, Notice, PageHead, Segment, friendly, orThrow, plural, useLoad } from "./BusinessShared";

// What the AI receptionist is allowed to say. An answer is only used once it
// says "Ready": every change is checked and sent to your assistant first.

const KINDS = [["faq", "FAQ"], ["service", "Service"], ["policy", "Policy"], ["hours", "Opening hours"], ["other", "Other"]];
const KIND_LABEL = Object.fromEntries(KINDS);
const STATUS = {
  ready: ["Ready", "success"],
  processing: ["Checking", "warning"],
  draft: ["Draft", ""],
  failed: ["Needs attention", "danger"],
  archived: ["Archived", ""],
};

function AnswerModal({ title, description, initial, askKind, submitLabel, onClose, onSubmit }) {
  const [form, setForm] = useState({
    title: initial?.title ?? "", kind: initial?.kind ?? "faq", question: initial?.question ?? "", answer: initial?.answer ?? "",
  });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const set = (k) => (e) => setForm({ ...form, [k]: e.target.value });

  async function submit(event) {
    event.preventDefault();
    if (!form.answer.trim()) return setError("Write the answer Zella should give.");
    if (askKind && !form.title.trim()) return setError("Give this a short title.");
    setBusy(true);
    setError("");
    const message = await onSubmit({ ...form, title: form.title.trim(), answer: form.answer.trim(), question: form.question.trim() });
    setBusy(false);
    if (message) setError(message);
  }

  return (
    <Modal
      title={title}
      description={description}
      onClose={onClose}
      busy={busy}
      footer={
        <>
          <button type="button" className="ba-btn" onClick={onClose} disabled={busy}>Cancel</button>
          <button type="submit" form="ba-knowledge" className="ba-btn primary" disabled={busy}>{busy ? "Saving…" : submitLabel}</button>
        </>
      }
    >
      <form id="ba-knowledge" className="ba-modal-body" onSubmit={submit}>
        {error && <p className="ba-error" role="alert">{error}</p>}
        <div className="ba-form-grid">
          {askKind && (
            <>
              <Field label="Title"><input value={form.title} onChange={set("title")} autoFocus placeholder="e.g. Accepted insurance" /></Field>
              <Field label="Type">
                <select value={form.kind} onChange={set("kind")}>{KINDS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
              </Field>
              <Field label="Question callers ask" full hint="Optional. Helps Zella match the right answer.">
                <input value={form.question} onChange={set("question")} />
              </Field>
            </>
          )}
          <Field label="Answer Zella should give" full>
            <textarea rows={5} value={form.answer} onChange={set("answer")} autoFocus={!askKind} />
          </Field>
        </div>
      </form>
    </Modal>
  );
}

export function KnowledgePage({ workspace, refreshKey, onNotice }) {
  const [tab, setTab] = useState("gaps");
  const [gapFilter, setGapFilter] = useState("open");
  const [modal, setModal] = useState(null);
  const [working, setWorking] = useState(null);
  const [actionError, setActionError] = useState("");

  const { data, error, loading, reload } = useLoad(async () => {
    const [gaps, items] = await Promise.all([
      supabase.from("knowledge_gaps").select("*").eq("business_id", workspace.id).order("last_asked_at", { ascending: false }).limit(200),
      supabase.from("knowledge_items").select("*").eq("business_id", workspace.id).neq("status", "archived").order("updated_at", { ascending: false }).limit(500),
    ]);
    return { gaps: orThrow(gaps), items: orThrow(items) };
  }, [workspace.id, refreshKey]);

  const gaps = data?.gaps ?? [];
  const items = data?.items ?? [];
  const openGaps = gaps.filter((g) => g.status === "open");
  const shownGaps = gapFilter === "open" ? openGaps : gaps.filter((g) => g.status !== "open");
  const waiting = items.filter((i) => i.status === "processing").length;

  async function run(key, work, message) {
    setWorking(key);
    setActionError("");
    const { error: failure } = await work();
    setWorking(null);
    if (failure) return setActionError(friendly(failure));
    onNotice?.(message);
    reload();
  }

  const answerGap = (gap) => setModal({
    kind: "answer", gap,
    submit: async (v) => {
      const { error: failure } = await supabase.rpc("zella_answer_knowledge_gap", { p_gap_id: gap.id, p_answer: v.answer, p_kind: v.kind, p_title: v.title });
      if (failure) return friendly(failure);
      setModal(null);
      onNotice?.("Submitted. Zella will use it once it has been checked.");
      reload();
      return "";
    },
  });

  const dismissGap = (gap) => run(`d-${gap.id}`, () => supabase.rpc("zella_dismiss_knowledge_gap", { p_gap_id: gap.id }), "Question dismissed.");

  const addItem = () => setModal({
    kind: "add",
    submit: async (v) => {
      const { error: failure } = await supabase.from("knowledge_items").insert({
        business_id: workspace.id, kind: v.kind, title: v.title, question: v.question || null, answer: v.answer, status: "processing",
      });
      if (failure) return friendly(failure);
      setModal(null);
      onNotice?.("Added. Zella will use it once it has been checked.");
      reload();
      return "";
    },
  });

  const editItem = (item) => setModal({
    kind: "edit", item,
    submit: async (v) => {
      const { error: failure } = await supabase.from("knowledge_items")
        .update({ title: v.title, kind: v.kind, question: v.question || null, answer: v.answer }).eq("id", item.id);
      if (failure) return friendly(failure);
      setModal(null);
      onNotice?.("Saved. Zella keeps using nothing for this until the new version is checked.");
      reload();
      return "";
    },
  });

  const retry = (item) => run(`r-${item.id}`, () => supabase.from("knowledge_items").update({ status: "processing" }).eq("id", item.id), "Checking again.");
  const archive = (item) => run(`a-${item.id}`, () => supabase.from("knowledge_items").update({ status: "archived" }).eq("id", item.id), "Removed. Zella will stop using it.");

  return (
    <>
      <PageHead
        crumb="AI Receptionist / Knowledge base"
        title="Knowledge"
        sub="What your AI receptionist is allowed to say. It only uses an answer once it shows Ready."
      >
        <button type="button" className="ba-btn primary" onClick={addItem}><Icon name="add" size="sm" />Add an answer</button>
        <Segment label="Knowledge view" value={tab} onChange={setTab} options={[["gaps", `Questions to review (${openGaps.length})`], ["items", `Approved answers (${items.length})`]]} />
      </PageHead>
      <Notice error={error || actionError} onRetry={reload} />
      {waiting > 0 && tab === "items" && <p className="ba-muted">{plural(waiting, "answer")} being checked. Zella can't use {waiting === 1 ? "it" : "them"} yet.</p>}

      {loading && !data ? <p className="ba-muted">Loading…</p> : tab === "gaps" ? (
        <>
          <div className="ba-page-tools">
            <Segment label="Review filter" value={gapFilter} onChange={setGapFilter} options={[["open", "Waiting"], ["done", "Resolved"]]} />
          </div>
          {!shownGaps.length ? (
            <Empty title={gapFilter === "open" ? "No questions to review" : "Nothing resolved yet"}>
              {gapFilter === "open" ? "When a caller asks something Zella can't answer, the question shows up here for you to approve an answer." : "Answered and dismissed questions are kept here."}
            </Empty>
          ) : (
            <div className="ba-stack">
              {shownGaps.map((g) => (
                <article key={g.id} className="ba-panel">
                  <div className="ba-panel-body">
                    <strong>{g.question}</strong>
                    <p className="ba-muted">
                      Asked {plural(g.times_asked, "time")} · last {timeAgo(g.last_asked_at)}
                      {g.status !== "open" && ` · ${g.status === "answered" ? "answered" : "dismissed"} ${timeAgo(g.resolved_at)}`}
                    </p>
                    {g.status === "open" && g.suggested_answer && (
                      <div className="ba-draft">
                        <p className="ba-draft-label">
                          Zella's draft{g.suggestion_source ? ` · from ${g.suggestion_source}` : ""}
                          {g.suggestion_confidence === "low" && <Pill tone="warning">Check the facts</Pill>}
                        </p>
                        <p className="ba-item-text">{g.suggested_answer}</p>
                      </div>
                    )}
                    {g.status === "open" && !g.suggested_answer && (
                      <p className="ba-muted">{g.suggested_at ? "Zella couldn't find this in your information, so it needs your answer." : "Zella is drafting an answer…"}</p>
                    )}
                    {g.status === "open" && (
                      <div className="ba-form-actions">
                        <button type="button" className="ba-btn primary sm" disabled={working === `d-${g.id}`} onClick={() => answerGap(g)}>{g.suggested_answer ? "Check and submit" : "Write the answer"}</button>
                        <button type="button" className="ba-btn sm" disabled={working === `d-${g.id}`} onClick={() => dismissGap(g)}>Dismiss</button>
                      </div>
                    )}
                  </div>
                </article>
              ))}
            </div>
          )}
        </>
      ) : !items.length ? (
        <Empty title="No approved answers yet">Add the questions your callers ask most, plus your services and policies. Zella answers from these and nothing else.</Empty>
      ) : (
        <div className="ba-stack">
          {items.map((i) => {
            const [label, tone] = STATUS[i.status] ?? [i.status, ""];
            return (
              <article key={i.id} className="ba-panel">
                <div className="ba-panel-body">
                  <div className="ba-kn-head">
                    <strong>{i.title}</strong>
                    <Pill tone={tone}>{label}</Pill>
                    <Pill>{KIND_LABEL[i.kind] ?? i.kind}</Pill>
                  </div>
                  {i.question && <p className="ba-muted">{i.question}</p>}
                  <p className="ba-item-text">{i.answer}</p>
                  {i.status === "failed" && <p className="ba-error">{i.error || "This couldn't be checked."} Edit it or try again.</p>}
                  <p className="ba-muted">Version {i.version} · updated {timeAgo(i.updated_at)}</p>
                  <div className="ba-form-actions">
                    <button type="button" className="ba-btn sm" onClick={() => editItem(i)}>Edit</button>
                    {i.status === "failed" && <button type="button" className="ba-btn sm" disabled={working === `r-${i.id}`} onClick={() => retry(i)}>Try again</button>}
                    <button type="button" className="ba-btn sm danger-outline" disabled={working === `a-${i.id}`} onClick={() => archive(i)}>Remove</button>
                  </div>
                </div>
              </article>
            );
          })}
        </div>
      )}

      {modal?.kind === "answer" && (
        <AnswerModal title={modal.gap.suggested_answer ? "Check Zella's draft" : "Answer this question"} description={modal.gap.suggested_answer ? `${modal.gap.question} Edit anything that isn't right, then submit.` : modal.gap.question} askKind submitLabel="Submit answer"
          initial={{ title: modal.gap.suggested_title || modal.gap.question.slice(0, 60), kind: modal.gap.suggested_kind || "faq", question: modal.gap.question, answer: modal.gap.suggested_answer || "" }} onClose={() => setModal(null)} onSubmit={modal.submit} />
      )}
      {modal?.kind === "add" && (
        <AnswerModal title="Add an answer" description="Zella will use this once it has been checked." askKind submitLabel="Add answer" onClose={() => setModal(null)} onSubmit={modal.submit} />
      )}
      {modal?.kind === "edit" && (
        <AnswerModal title="Edit answer" description="Zella stops using the old version until the new one is checked." askKind initial={modal.item} submitLabel="Save changes" onClose={() => setModal(null)} onSubmit={modal.submit} />
      )}
    </>
  );
}
