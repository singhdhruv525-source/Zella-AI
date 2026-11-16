import { useEffect, useId, useRef, useState } from "react";
import { Icon } from "../BusinessUI";
import { Actions, EmptyNote, ErrorText, useAction } from "./kit";
import { detailsDone, nextOpenSection, sectionRows, sectionState, sectionTitle } from "./steps";

// Screen 3, Check your details: what the Zella Voice team filled in, one section at a time, each with Looks right or
// Change. In this version of the contract (§5.4) Change sends a note to the Zella Voice team; they make the change, and
// the section comes back as "Changed, check again". Only Looks right on every section finishes the step.

export function DetailsScreen({ api, state, onState, onComplete }) {
  const sections = Array.isArray(state.details?.sections) ? state.details.sections : [];
  const [openKey, setOpenKey] = useState(() => nextOpenSection(sections) ?? sections[0]?.key ?? null);
  const finish = useAction();
  const sectionHeading = useRef(null);
  const first = useRef(true);
  // moving to another section moves focus to its name (not on the first render: the step heading has it then)
  useEffect(() => { if (first.current) { first.current = false; return; } sectionHeading.current?.focus(); }, [openKey]);

  if (!sections.length) return <EmptyNote title="Nothing to check yet">The Zella Voice team is still setting up your details. Choose Finish later and we'll pick up here.</EmptyNote>;

  const open = sections.find((s) => s.key === openKey) ?? sections[0];
  const done = detailsDone(state.details);
  const waiting = sections.filter((s) => sectionState(s).key === "change_requested").length;
  const left = sections.filter((s) => !sectionState(s).done).length;

  function answered(next, key) {
    onState(next);
    const list = next.details?.sections ?? [];
    const following = nextOpenSection(list, key);
    if (following) setOpenKey(following);
  }

  return (
    <>
      <p className="zob-lead">The Zella Voice team set these up for you. Check each part. If anything is wrong, choose Change and tell us what to fix.</p>
      <ol className="zob-sections" aria-label="Parts to check">
        {sections.map((s) => {
          const st = sectionState(s);
          return (
            <li key={s.key}>
              <button type="button" className={`zob-section-tab ${s.key === open.key ? "on" : ""}`} aria-current={s.key === open.key ? "step" : undefined} onClick={() => setOpenKey(s.key)}>
                <Icon name={st.done ? "check_circle" : st.key === "change_requested" ? "schedule" : "radio_button_unchecked"} size="sm" />
                <span>{sectionTitle(s.key)}</span>
                <span className="zob-sr">, {st.label}</span>
              </button>
            </li>
          );
        })}
      </ol>
      <SectionCard key={open.key} api={api} businessId={state.business_id} section={open} index={sections.indexOf(open)} total={sections.length}
        headingRef={sectionHeading} onAnswered={answered} />
      {done
        ? <div className="zob-done-note" role="status"><Icon name="task_alt" /><span>Every part looks right. Thank you.</span></div>
        : waiting > 0 && left === waiting && <p className="zob-muted" role="status">We're making the changes you asked for. When they're done, the part shows "Changed, check again". You can choose Finish later meanwhile; we'll keep your place.</p>}
      <ErrorText>{finish.error}</ErrorText>
      <Actions>
        <button type="button" className="ba-btn primary" disabled={!done || finish.busy} onClick={() => finish.run(() => onComplete("details"))}
          aria-describedby={done ? undefined : "zob-details-left"}>{finish.busy ? "One moment…" : "Continue"}</button>
        {!done && <span className="zob-hint" id="zob-details-left">{left} of {sections.length} parts still to confirm</span>}
      </Actions>
    </>
  );
}

function SectionCard({ api, businessId, section, index, total, headingRef, onAnswered }) {
  const st = sectionState(section);
  const [writing, setWriting] = useState(false);
  const action = useAction();
  const rows = sectionRows(section.key, section.data);
  const answer = (decision, note) => action.run(async () => {
    const res = await api.answerSection(businessId, section.key, decision, note);
    setWriting(false);
    onAnswered(res.state, section.key);
  });
  return (
    <section className="zob-card zob-section" aria-labelledby={`zob-sec-${section.key}`}>
      <div className="zob-section-head">
        <div>
          <span className="zob-kicker">Part {index + 1} of {total}</span>
          <h2 id={`zob-sec-${section.key}`} ref={headingRef} tabIndex={-1}>{sectionTitle(section.key)}</h2>
        </div>
        <span className={`zob-chip tone-${st.tone}`}>{st.label}</span>
      </div>
      {st.key === "updated" && section.admin_note && <p className="zob-quote"><strong>From the Zella Voice team:</strong> {section.admin_note}</p>}
      {rows.length ? (
        <dl className="zob-facts">
          {rows.map(([label, value]) => (
            <div key={label}>
              <dt>{label}</dt>
              <dd>{Array.isArray(value) ? <ul className="zob-list">{value.map((v, i) => <li key={i}>{v}</li>)}</ul> : value}</dd>
            </div>
          ))}
        </dl>
      ) : <p className="zob-muted">Nothing set up here yet.</p>}
      {st.key === "change_requested" && section.note && <p className="zob-quote"><strong>You asked:</strong> {section.note}</p>}
      {writing ? (
        <NoteForm initial={section.note ?? ""} busy={action.busy} error={action.error} onCancel={() => { setWriting(false); action.setError(""); }}
          onSend={(note) => answer("change", note)} />
      ) : (
        <>
          <ErrorText>{action.error}</ErrorText>
          <div className="zob-section-actions">
            <button type="button" className="ba-btn primary" disabled={action.busy || st.key === "looks_right"} onClick={() => answer("looks_right")}>
              <Icon name="check" size="sm" /> {action.busy ? "Saving…" : st.key === "change_requested" ? "Looks right after all" : "Looks right"}
            </button>
            <button type="button" className="ba-btn" disabled={action.busy} onClick={() => { action.setError(""); setWriting(true); }}>
              <Icon name="edit" size="sm" /> {st.key === "change_requested" ? "Change my note" : "Change"}
            </button>
          </div>
        </>
      )}
    </section>
  );
}

function NoteForm({ initial, busy, error, onCancel, onSend }) {
  const [note, setNote] = useState(initial);
  const id = useId();
  const hintId = useId();
  const area = useRef(null);
  useEffect(() => { area.current?.focus(); }, []);
  return (
    <form className="ba-form zob-form" onSubmit={(e) => { e.preventDefault(); if (note.trim()) onSend(note.trim()); }}>
      <div className="ba-field">
        <label htmlFor={id}>What should change?</label>
        <textarea id={id} ref={area} value={note} maxLength={1000} aria-describedby={hintId} onChange={(e) => setNote(e.target.value)} placeholder="For example: we close at 18:00 on Fridays" />
        <small id={hintId}>The Zella Voice team reads this and makes the change for you. {1000 - note.length} characters left.</small>
      </div>
      <ErrorText>{error}</ErrorText>
      <div className="zob-section-actions">
        <button type="submit" className="ba-btn primary" disabled={busy || !note.trim()}>{busy ? "Sending…" : "Send to the Zella Voice team"}</button>
        <button type="button" className="ba-btn" disabled={busy} onClick={onCancel}>Cancel</button>
      </div>
    </form>
  );
}
