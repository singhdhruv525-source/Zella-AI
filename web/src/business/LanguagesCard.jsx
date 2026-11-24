import { supabase } from "../supabase";
import { Banner, Card, Field, LoadState, SaveBar, useAsync, useForm } from "../settings/SettingsKit";
import { languageError, languageNames, planMessage, planRefusal, planSummary } from "./languagePlan";

// The receptionist's languages on the admin business page (AI receptionist tab). Only Zella Voice admins change them
// (sql/zella_admin_languages.sql: zella_business_language_save needs businesses.manage, or the zella_owner and
// super_admin roles), within the business's plan; owners see them read only in Settings > Languages. Every save is
// audited by the database. onSaved lets the page reload the voice list, which follows the languages.

function Editor({ businessId, data, onSaved }) {
  const form = useForm({ primary: data.primary, extras: data.extras ?? [], greeting: data.greeting ?? "" });
  const v = form.values;
  const catalog = data.catalog ?? [];
  const plan = data.plan ?? null;
  const canEdit = data.can_edit === true;
  const refusal = planRefusal(plan, v.primary, v.extras, catalog);
  // what a chip would add, checked against the plan before it is offered
  const blocked = (code) => planRefusal(plan, v.primary, [...v.extras, code], catalog);
  const toggle = (code) => form.setValues((f) => ({
    ...f, extras: f.extras.includes(code) ? f.extras.filter((c) => c !== code) : f.extras.length >= 3 ? f.extras : [...f.extras, code],
  }));

  async function save() {
    await form.save(async (values) => {
      const extras = values.extras.filter((c) => c !== values.primary);
      const { error } = await supabase.rpc("zella_business_language_save", {
        p_business_id: businessId, p_primary: values.primary, p_extras: extras, p_greeting: values.greeting.trim() || null,
      });
      if (error) throw new Error(languageError(error, plan));
      onSaved?.();
      return { extras, greeting: values.greeting.trim() };
    }, "Saved and recorded in the audit log. Calls use it once the phone line's settings are updated. A saved voice that doesn't speak these languages is replaced by the Zella Voice default.");
  }

  return (
    <Card title="Languages" sub="The language the receptionist answers in, and up to three it switches to when a caller speaks them. Only the Zella Voice team changes these; the owner sees them in Settings.">
      <Banner tone={plan?.source === "none" ? "warn" : ""}>{planSummary(plan)}</Banner>
      {data.within_plan === false && <Banner tone="warn">The saved languages are more than the plan includes. {planMessage(plan)}</Banner>}
      <div className="zs-grid">
        <Field label="Main language">
          <select value={v.primary} disabled={!canEdit} onChange={(e) => { const primary = e.target.value; form.setValues((f) => ({ ...f, primary, extras: f.extras.filter((c) => c !== primary) })); }}>
            {catalog.map((l) => <option key={l.code} value={l.code}>{l.label}</option>)}
          </select>
        </Field>
        <Field label="Greeting (optional)" hint="Empty uses the standard greeting for the main language. Write {name} for the business name.">
          <input value={v.greeting} maxLength={200} disabled={!canEdit} onChange={form.set("greeting")} />
        </Field>
      </div>
      <div className="zs-lang-picks" role="group" aria-label="Other languages">
        {catalog.filter((l) => l.code !== v.primary).map((l) => {
          const on = v.extras.includes(l.code);
          const why = on ? null : blocked(l.code);
          return (
            <button type="button" key={l.code} className={`zs-chip ${on ? "on" : ""}`} aria-pressed={on} title={why ?? undefined}
              disabled={!canEdit || (!on && (v.extras.length >= 3 || Boolean(why)))} onClick={() => toggle(l.code)}>{l.label}</button>
          );
        })}
      </div>
      {refusal && <Banner tone="warn">{refusal}</Banner>}
      {!refusal && plan?.allowance === 1 && canEdit && <p className="zs-muted">{planMessage(plan)}</p>}
      {canEdit
        ? <SaveBar form={form} onSave={save} disabled={Boolean(refusal)} />
        : <Banner>Now: {languageNames([v.primary, ...v.extras], catalog).join(", ")}. Changing languages needs permission to manage businesses.</Banner>}
    </Card>
  );
}

export function LanguagesCard({ businessId, onSaved }) {
  const state = useAsync(async () => {
    const { data, error } = await supabase.rpc("zella_business_language_get", { p_business_id: businessId });
    if (error) throw new Error(languageError(error));
    return data;
  }, [businessId]);
  return <LoadState state={state}>{(data) => <Editor key={data.updated_at ?? "new"} businessId={businessId} data={data} onSaved={onSaved} />}</LoadState>;
}
