import "./operationalRules.css";
import { useRef } from "react";
import { callOwnerFunction } from "../../CreateBusinessWizard";
import { Icon } from "../../BusinessUI";
import { Banner, Card, LoadState, Pill, useAsync, useForm, when } from "../SettingsKit";

// Operational rules (Settings, Platform): timings and thresholds the scheduled checks read from
// platform_settings. Saved by a Zella Voice owner; the admin function checks each value before it is stored, and the
// jobs pick it up on their next run. One row per setting (label and help on the left, the value on the right), one
// save bar per section that appears only with unsaved changes, and the setting keys in a Technical details disclosure.
const call = (action, fields = {}) => callOwnerFunction(action, fields);

// [key, label, help, kind]: kind "number" is a short whole number input, "list" a short comma separated list
const OPERATIONAL = [
  ["Leads and tasks", [
    ["response_time_minutes", "Reply to a new lead within", "Minutes. Late replies show on reports and in alerts.", "number"],
    ["task_overdue_grace_minutes", "Grace before a task is overdue", "Extra minutes before a task counts as overdue.", "number"],
    ["task_escalate_hours", "Escalate overdue tasks after", "Hours. Overdue tasks then go to the business owner.", "number"],
    ["team_summary_hour", "Daily team summary at", "Hour of the day in business time, 0 to 23.", "number"],
  ]],
  ["Calls", [
    ["missed_call_max_seconds", "Missed call if shorter than", "Seconds. These calls count as missed and get a callback.", "number"],
    ["transfer_failure_threshold", "Flag a business after", "Failed transfers to a person in one day.", "number"],
    ["call_intel_monthly_limit", "AI call summaries per month", "Calls per business per month that the AI summarizes.", "number"],
  ]],
  ["AI quality and knowledge", [
    ["ai_low_confidence_questions", "Flag a call for review after", "Unsure answers in one call.", "number"],
    ["knowledge_repeat_threshold", "Suggest new knowledge after", "Times the same question is asked.", "number"],
    ["response_sample_rate", "Quality review sample", "Share of AI conversations picked for review: 0.1 is one in ten.", "number"],
  ]],
  ["Onboarding and trials", [
    ["invitation_reminder_hours", "Invitation reminders at", "Hours after an owner invitation, for example 24, 72.", "list"],
    ["setup_incomplete_after_days", "Flag an unfinished setup after", "Days after the business was created.", "number"],
    ["trial_notice_days", "Trial ending notices at", "Days before a trial ends, for example 7, 3, 1.", "list"],
    ["draft_abandon_days", "Draft shows as Abandoned after", "Days without any change before a draft business shows as Abandoned on Business onboarding, with one alert. Nothing is deleted automatically.", "number"],
  ]],
];

// Settings the server reads with a default when no row exists yet (lane B, draft clean up).
const UNSET_DEFAULTS = { draft_abandon_days: 30 };

const NUMBER_WORDS = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"];
const countWord = (n) => NUMBER_WORDS[n] ?? String(n);
const asText = (v) => (typeof v === "string" ? v : Array.isArray(v) ? v.join(", ") : v === null || v === undefined ? "" : JSON.stringify(v));

export default function OperationalRules({ me }) {
  const state = useAsync(() => call("platform_settings_list"), []);
  return (
    <LoadState state={state}>{(s) => {
      const byKey = new Map(s.settings.map((x) => [x.key, x]));
      // a setting the server reads with a built in default shows that default until it is stored; saving stores it
      for (const [k, v] of Object.entries(UNSET_DEFAULTS)) if (!byKey.has(k)) byKey.set(k, { key: k, value: v });
      const missing = OPERATIONAL.flatMap(([, keys]) => keys).filter(([k]) => !byKey.has(k));
      return (
        <div className="or-page">
          {me?.role !== "zella_owner" && <Banner tone="warn">Only a Zella Voice owner can change these. You can see the current values.</Banner>}
          {missing.length > 0 && (
            <div className="or-banner" role="status" data-missing-settings={missing.length}>
              <Icon name="info" />
              <div>
                <strong>{countWord(missing.length)} {missing.length === 1 ? "setting is" : "settings are"} waiting for a database update.</strong>{" "}
                <span>{missing.length === 1 ? "It shows" : "They show"} here once the update that adds {missing.length === 1 ? "it" : "them"} is applied: {missing.map(([, label]) => label).join(", ")}.</span>
              </div>
            </div>
          )}
          {OPERATIONAL.map(([group, keys]) => <Section key={group} me={me} group={group} keys={keys} byKey={byKey} />)}
        </div>
      );
    }}</LoadState>
  );
}

function Section({ me, group, keys, byKey }) {
  const owner = me?.role === "zella_owner";
  const present = keys.filter(([k]) => byKey.has(k));
  const initial = Object.fromEntries(present.map(([k]) => [k, asText(byKey.get(k).value)]));
  const form = useForm(initial);
  // the values last saved, so Save sends only the settings that changed (one checked save per setting)
  const base = useRef(initial);
  const changed = present.filter(([k]) => form.values[k] !== base.current[k]).length;
  // Each setting saves on its own; if one fails, the ones already stored are reported back (err.acknowledged), so they
  // stop showing as unsaved and Discard only reverts the rest (useForm in SettingsKit).
  const save = () => form.save(async (v) => {
    const acknowledged = {};
    for (const [k] of present) {
      if (v[k] !== base.current[k]) {
        try {
          await call("platform_setting_save", { key: k, value: v[k] });
        } catch (err) {
          if (Object.keys(acknowledged).length) err.acknowledged = acknowledged;
          throw err;
        }
        acknowledged[k] = v[k];
        base.current = { ...base.current, [k]: v[k] };
      }
    }
  });
  const discard = () => { form.cancel(); };
  return (
    <Card title={group}>
      <div className="or-rows">
        {keys.map(([k, label, help, kind]) => {
          const row = byKey.get(k);
          const id = `or-${k}`;
          return (
            <div key={k} className="zs-row or-row" data-setting={k}>
              <div className="or-label">
                <label htmlFor={row ? id : undefined}>{label}</label>
                <small>{help}</small>
              </div>
              <div className="or-control">
                {row
                  ? <input id={id} className={`zs-input or-input${kind === "number" ? " num" : ""}`} inputMode={kind === "number" ? "decimal" : "text"}
                    value={form.values[k] ?? ""} onChange={form.set(k)} disabled={!owner || form.busy} />
                  : <Pill>Not available yet</Pill>}
              </div>
            </div>
          );
        })}
      </div>
      <details className="or-tech">
        <summary>Technical details</summary>
        <dl>
          {keys.map(([k, label]) => {
            const row = byKey.get(k);
            return <div key={k}><dt>{label}</dt><dd><code>{k}</code>{row ? `, changed ${when(row.updated_at)}` : ", not in the database yet"}</dd></div>;
          })}
        </dl>
      </details>
      {owner && (form.dirty || form.status.text || form.status.error) && (
        <div className="or-savebar" role="region" aria-label={`${group}: unsaved changes`}>
          <span className="or-savebar-state">
            {form.status.error ? <span className="zs-error-text" role="alert">{form.status.error}</span>
              : form.dirty ? `${countWord(changed)} unsaved ${changed === 1 ? "change" : "changes"}`
                : <span role="status">{form.status.text}</span>}
          </span>
          {form.dirty && (
            <>
              <button type="button" className="zs-btn" onClick={discard} disabled={form.busy}>Discard</button>
              <button type="button" className="zs-btn primary" onClick={save} disabled={form.busy}>{form.busy ? "Saving…" : "Save"}</button>
            </>
          )}
        </div>
      )}
    </Card>
  );
}
