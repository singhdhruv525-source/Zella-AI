import { useState } from "react";
import { supabase } from "../../supabase";
import catalog from "../../../supabase/functions/_shared/catalog.json";
import { Banner, Card, Field, LoadState, Needs, Pill, Table, Toggle, useAsync, when } from "../SettingsKit";
import { REPEAT_CHOICES, SEVERITIES, formFrom, ruleFromForm, ruleRows, ruleSummary } from "./alertRules";

// Settings, Alert rules (SET-ALERT-RULES): one rule per alert kind, from the shared list of kinds the code raises
// (PLT-08). Rules are read with businesses.view and saved with platform.configure and a reason; every change is in the
// audit log. Urgent alerts can't be switched off or lowered, and quiet hours never delay them.
const ERR = { URGENT_PROTECTED: "This kind is always urgent: it can be rerouted, not switched off or lowered.", NOT_ALLOWED: "Your admin role can see these rules but not change them.", REASON_REQUIRED: "Give a short reason (it goes in the audit log)." };
const rpc = async (fn, args) => {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) {
    if (error.code === "PGRST202" || /could not find the function/i.test(error.message)) return { missing: true };
    const code = String(error.message ?? "").split(":")[0].trim();
    throw new Error(ERR[code] ?? (code.startsWith("INVALID_") ? "Check the values: one of them isn't accepted." : error.message));
  }
  return data;
};

export default function AlertRules({ me }) {
  const state = useAsync(() => rpc("zella_admin_alert_rules", {}), []);
  const [open, setOpen] = useState(null);
  const canEdit = Boolean(me?.permissions?.includes("platform.configure"));
  return (
    <LoadState state={state}>{(d) => {
      if (d.missing) return <Needs title="Alert rules need a database update" have="Every alert is still raised as before, with its own severity.">Once the alert rules update is applied, each kind of alert can be switched off, given a severity, sent to chosen admins, spaced out and given quiet hours.</Needs>;
      const rows = ruleRows(catalog, d);
      return (
        <>
          <Card title="Alert rules" sub="Each kind of alert the platform raises. A rule changes how it is raised and who is emailed. Urgent alerts are never switched off, lowered or held back by quiet hours.">
            <Table rowKey={(r) => r.kind} rows={rows} empty="No alert kinds found."
              columns={[["Alert", (r) => <span data-rule-kind={r.kind}><strong>{r.label}</strong>{r.protected && <> <Pill tone="danger">Always urgent</Pill></>}</span>],
                ["Rule", (r) => <span data-rule-summary={r.kind}>{ruleSummary(r)}</span>],
                ["Raised (30 days)", (r) => r.seen],
                ["Rule details", (r) => <button type="button" className="zs-link" onClick={() => setOpen(r)} aria-label={`${canEdit ? "Edit" : "View"} the rule for ${r.label}`}>{canEdit ? "Edit" : "View"}</button>]]} />
          </Card>
          {open && <RuleForm key={open.kind} row={open} canEdit={canEdit} onClose={() => setOpen(null)} onSaved={() => { setOpen(null); state.reload(); }} />}
        </>
      );
    }}</LoadState>
  );
}

function RuleForm({ row, canEdit, onClose, onSaved }) {
  const [f, setF] = useState(() => formFrom(row));
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const set = (k) => (v) => setF((x) => ({ ...x, [k]: v }));
  const save = async (rule) => {
    if (reason.trim().length < 3) return setError(ERR.REASON_REQUIRED);
    setBusy(true); setError("");
    try { await rpc("zella_admin_alert_rule_save", { p_kind: row.kind, p_rule: rule, p_reason: reason.trim() }); onSaved(); }
    catch (e) { setError(e.message); setBusy(false); }
  };
  const lock = !canEdit || busy;
  return (
    <Card title={`Rule: ${row.label}`} sub={row.rule?.updated_at ? `Last changed ${when(row.rule.updated_at)}${row.rule.updated_by ? ` by ${row.rule.updated_by}` : ""}` : "No rule yet: raised as the check decides."}>
      <div className="zs-grid" data-rule-form={row.kind}>
        <Field label="Raise this alert" hint={row.protected ? "Always on: this kind is always urgent." : "Off means the check raises nothing for this kind."}>
          <Toggle on={row.protected || f.enabled} disabled={lock || row.protected} onChange={set("enabled")} label="Raise this alert" />
        </Field>
        <Field label="Severity" hint={row.protected ? "Always urgent." : "An alert raised as urgent stays urgent."}>
          <select value={f.severity} disabled={lock} onChange={(e) => set("severity")(e.target.value)}>
            {SEVERITIES.filter(([v]) => !row.protected || v === "" || v === "urgent").map(([v, l]) => <option key={v} value={v}>{l}</option>)}
          </select>
        </Field>
        <Field label="Where it goes" hint="Every alert shows in the alerts bell.">
          <select value={f.destination} disabled={lock} onChange={(e) => set("destination")(e.target.value)}>
            <option value="bell_and_email">Bell and email</option><option value="bell">Bell only (urgent alerts are still emailed)</option>
          </select>
        </Field>
        {f.destination !== "bell" && (
          <Field label="Email to" hint="When nobody holds the permission, every admin is emailed.">
            <select value={f.email_permission} disabled={lock} onChange={(e) => set("email_permission")(e.target.value)}>
              <option value="">Every admin</option>
              {Object.entries(catalog.permissions ?? {}).map(([p, l]) => <option key={p} value={p}>{`Admins who can ${String(l).toLowerCase()}`}</option>)}
            </select>
          </Field>
        )}
        <Field label="How often" hint="After it is resolved, how long before the same alert opens again. Urgent alerts always open.">
          <select value={f.repeat_minutes ?? ""} disabled={lock} onChange={(e) => set("repeat_minutes")(e.target.value ? Number(e.target.value) : null)}>
            {REPEAT_CHOICES.map(([m, l]) => <option key={String(m)} value={m ?? ""}>{l}</option>)}
          </select>
        </Field>
        <Field label="Quiet hours for email" hint="Warning and info emails wait until they end. Urgent alerts are never delayed.">
          <Toggle on={f.quiet} disabled={lock} onChange={set("quiet")} label="Quiet hours for email" />
        </Field>
        {f.quiet && (
          <>
            <Field label="Quiet from"><input type="time" value={f.quiet_start} disabled={lock} onChange={(e) => set("quiet_start")(e.target.value)} /></Field>
            <Field label="Quiet until"><input type="time" value={f.quiet_end} disabled={lock} onChange={(e) => set("quiet_end")(e.target.value)} /></Field>
            <Field label="Time zone"><input value={f.quiet_tz} disabled={lock} onChange={(e) => set("quiet_tz")(e.target.value)} placeholder="America/New_York" /></Field>
          </>
        )}
        {canEdit && <Field label="Reason" hint="Kept in the audit log." full><input value={reason} maxLength={300} onChange={(e) => setReason(e.target.value)} placeholder="Why you're changing this rule" /></Field>}
      </div>
      <Banner tone="error">{error}</Banner>
      <div className="zs-actions">
        <button type="button" className="zs-btn" onClick={onClose} disabled={busy}>Close</button>
        {canEdit && row.rule && <button type="button" className="zs-btn" onClick={() => save(null)} disabled={busy}>Back to as raised</button>}
        {canEdit && <button type="button" className="zs-btn primary" onClick={() => save(ruleFromForm(f, row.protected))} disabled={busy}>{busy ? "Saving…" : "Save rule"}</button>}
      </div>
    </Card>
  );
}
