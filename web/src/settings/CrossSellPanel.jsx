import { useState } from "react";
import { supabase } from "../supabase";
import { Banner, Card, Field, LoadState, Pill, Table, Toggle, useAsync } from "./SettingsKit";

// "You might also need": after a service is completed, suggest another one some days later. Marketing, so it only
// goes to customers who opted in. Rules are saved with zella_cross_sell_* (sql/zella_cross_sell.sql).

const CODES = {
  NOT_ALLOWED: "Only owners, admins and managers can change suggestions.",
  INVALID_RULE: "Write both services (2 to 80 characters).",
  RULE_TEXT: "Plain words only: no links or brackets.",
  SAME_SERVICE: "Suggest a different service from the one just done.",
  INVALID_DELAY: "Pick 1 to 365 days.",
  DUPLICATE_RULE: "You already have that suggestion.",
  TOO_MANY_RULES: "That's the most suggestions one business can have (30).",
};
const say = (error) => {
  const message = error?.message?.trim() ?? String(error);
  if (/does not exist|schema cache|Could not find the/i.test(message)) return "Suggestions need the latest Zella update. Please ask the Zella team.";
  return CODES[message] ?? message;
};

function Rules({ w, data, reload }) {
  const [form, setForm] = useState({ after_service: "", suggestion: "", delay_days: 14 });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [note, setNote] = useState("");

  async function save(rule, message) {
    setBusy(true);
    setError("");
    setNote("");
    const { error: saveError } = await supabase.rpc("zella_cross_sell_save", { p_business_id: w.id, p_rule: rule });
    setBusy(false);
    if (saveError) return setError(say(saveError));
    setNote(message);
    if (!rule.id) setForm({ after_service: "", suggestion: "", delay_days: 14 });
    reload();
  }
  async function remove(rule) {
    setBusy(true);
    const { error: deleteError } = await supabase.rpc("zella_cross_sell_delete", { p_business_id: w.id, p_rule_id: rule.id });
    setBusy(false);
    if (deleteError) return setError(say(deleteError));
    setNote("Removed. Suggestions it had waiting won't be sent.");
    reload();
  }

  const columns = [
    ["After", (r) => r.after_service],
    ["Suggest", (r) => r.suggestion],
    ["When", (r) => `${r.delay_days} day${r.delay_days === 1 ? "" : "s"} later`],
    ["Last 90 days", (r) => `${r.sent} sent${r.queued ? `, ${r.queued} waiting` : ""}${r.not_sent ? `, ${r.not_sent} not sent` : ""}`],
    ["On", (r) => <Toggle on={r.active} label={`Suggest ${r.suggestion}`} disabled={!data.can_edit || busy}
      onChange={(on) => save({ ...r, active: on }, on ? "Suggestion switched on." : "Suggestion paused.")} />],
  ];
  if (data.can_edit) columns.push(["", (r) => <button type="button" className="zs-link" disabled={busy} onClick={() => remove(r)}>Remove</button>]);

  return (
    <>
      <Card title="Your suggestions" sub="When an appointment that mentions the first service is marked done, Zella sends one friendly message suggesting the second.">
        <Table columns={columns} rows={data.rules} empty="No suggestions yet. Add one below or start from an idea." />
      </Card>
      {data.can_edit && (
        <Card title="Add a suggestion">
          <div className="zs-grid">
            <Field label="After this service" hint="Matched against the appointment's name, for example “cleaning”.">
              <input value={form.after_service} maxLength={80} onChange={(e) => setForm({ ...form, after_service: e.target.value })} />
            </Field>
            <Field label="Suggest" hint="Shown to the customer, for example “teeth whitening”.">
              <input value={form.suggestion} maxLength={80} onChange={(e) => setForm({ ...form, suggestion: e.target.value })} />
            </Field>
            <Field label="Days later">
              <input type="number" min={1} max={365} value={form.delay_days} onChange={(e) => setForm({ ...form, delay_days: e.target.value })} />
            </Field>
          </div>
          <div className="zs-actions" style={{ marginTop: 12 }}>
            <button type="button" className="zs-btn primary" disabled={busy || form.after_service.trim().length < 2 || form.suggestion.trim().length < 2}
              onClick={() => save({ ...form, delay_days: Number(form.delay_days) }, "Suggestion added.")}>Add suggestion</button>
          </div>
          {data.ideas?.length > 0 && (
            <div className="zs-ideas">
              <span>Ideas for your industry:</span>
              {data.ideas.map((i) => (
                <button type="button" key={`${i.after_service}-${i.suggestion}`} className="zs-chip" disabled={busy}
                  onClick={() => save(i, `Added: after ${i.after_service}, suggest ${i.suggestion}.`)}>
                  After {i.after_service} → {i.suggestion} ({i.delay_days} days)
                </button>
              ))}
            </div>
          )}
        </Card>
      )}
      {error && <Banner tone="error">{error}</Banner>}
      {note && <Banner tone="success">{note}</Banner>}
      <Card title="Who gets these">
        <ul className="zs-plain-list">
          <li>Only customers who agreed to receive offers by text or email. Nobody else is ever sent one.</li>
          <li>At most one suggestion per visit, the same one at most every 90 days, and any suggestion at most every 14 days.</li>
          <li>Not if they already have the suggested service booked; a waiting suggestion is cancelled if they book it.</li>
          <li>Never at night, and STOP or unsubscribe stops them for good.</li>
        </ul>
        {!data.marketing_texts_allowed && <p><Pill tone="warning">Texts paused</Pill> Offer texts are switched off for all of Zella right now; email suggestions still go to people who opted in.</p>}
      </Card>
    </>
  );
}

export function CrossSellPanel({ w }) {
  const state = useAsync(async () => {
    const { data, error } = await supabase.rpc("zella_cross_sell_list", { p_business_id: w.id });
    if (error) throw new Error(say(error));
    return data;
  }, [w.id]);
  return <LoadState state={state}>{(data) => <Rules w={w} data={data} reload={state.reload} />}</LoadState>;
}
