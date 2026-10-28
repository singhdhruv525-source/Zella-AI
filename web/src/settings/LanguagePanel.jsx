import { supabase } from "../supabase";
import { Banner, Card, Field, LoadState, SaveBar, useAsync, useForm } from "./SettingsKit";

// AI receptionist languages: the one it greets in and up to three more it switches to when a caller speaks them.
// Saved with zella_business_language_save (sql/zella_languages.sql); the Vapi assistant is built from it.

const CODES = {
  NOT_ALLOWED: "Only owners, admins and managers can change languages.",
  UNKNOWN_LANGUAGE: "Pick languages from the list.",
  TOO_MANY_LANGUAGES: "Up to three extra languages.",
  GREETING_LENGTH: "The greeting needs 5 to 200 characters.",
  GREETING_TEXT: "The greeting can't contain links, brackets or placeholders other than {name}.",
};
const say = (error) => {
  const message = error?.message?.trim() ?? String(error);
  if (/does not exist|schema cache|Could not find the/i.test(message)) return "Languages need the latest Zella update. Please ask the Zella team.";
  return CODES[message] ?? message;
};

function Editor({ w, data }) {
  const form = useForm({ primary: data.primary, extras: data.extras ?? [], greeting: data.greeting ?? "" });
  const v = form.values;
  const catalog = data.catalog ?? [];
  const byCode = Object.fromEntries(catalog.map((l) => [l.code, l]));
  const main = byCode[v.primary];
  const other = !main?.english || v.extras.some((c) => !byCode[c]?.english);
  const defaultGreeting = (main?.greeting ?? "").replace("{name}", w.name);
  const toggle = (code) => form.setValues((f) => ({
    ...f, extras: f.extras.includes(code) ? f.extras.filter((c) => c !== code) : f.extras.length >= 3 ? f.extras : [...f.extras, code],
  }));

  async function save() {
    await form.save(async (values) => {
      const { error } = await supabase.rpc("zella_business_language_save", {
        p_business_id: w.id, p_primary: values.primary, p_extras: values.extras.filter((c) => c !== values.primary), p_greeting: values.greeting.trim() || null,
      });
      if (error) throw new Error(say(error));
      return { extras: values.extras.filter((c) => c !== values.primary), greeting: values.greeting.trim() };
    }, "Saved. The Zella team updates your phone assistant with it.");
  }

  return (
    <>
      <Card title="Main language" sub="Your receptionist answers every call in this language.">
        <div className="zs-grid">
          <Field label="Language">
            <select value={v.primary} disabled={!data.can_edit} onChange={(e) => form.set("primary")(e.target.value)}>
              {catalog.map((l) => <option key={l.code} value={l.code}>{l.label}</option>)}
            </select>
          </Field>
        </div>
      </Card>
      <Card title="Other languages it can switch to" sub="When a caller speaks one of these, the receptionist answers in it for the rest of the call. Up to three.">
        <div className="zs-lang-picks" role="group" aria-label="Other languages">
          {catalog.filter((l) => l.code !== v.primary).map((l) => {
            const on = v.extras.includes(l.code);
            return (
              <button type="button" key={l.code} className={`zs-chip ${on ? "on" : ""}`} aria-pressed={on}
                disabled={!data.can_edit || (!on && v.extras.length >= 3)} onClick={() => toggle(l.code)}>{l.label}</button>
            );
          })}
        </div>
      </Card>
      <Card title="Greeting" sub="The first thing callers hear. Leave it empty to use the standard greeting for the main language.">
        <Field label="Greeting (optional)" full hint={`Standard: “${defaultGreeting}” Write {name} for your business name.`}>
          <input value={v.greeting} maxLength={200} disabled={!data.can_edit} onChange={form.set("greeting")} placeholder={defaultGreeting} />
        </Field>
      </Card>
      {other && (
        <Banner tone="warn">
          Other languages need a transcriber that understands them. The Zella team switches your line over and makes a test call in each language before it goes live.
          Booking times, names and texts you send stay as they are; texts and emails are still sent in English.
        </Banner>
      )}
      {data.can_edit ? <SaveBar form={form} onSave={save} /> : <Banner>Only owners, admins and managers can change languages.</Banner>}
    </>
  );
}

export function LanguagePanel({ w }) {
  const state = useAsync(async () => {
    const { data, error } = await supabase.rpc("zella_business_language_get", { p_business_id: w.id });
    if (error) throw new Error(say(error));
    return data;
  }, [w.id]);
  return <LoadState state={state}>{(data) => <Editor w={w} data={data} />}</LoadState>;
}
